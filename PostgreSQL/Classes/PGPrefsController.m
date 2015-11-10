//
//  PostgrePrefsDelegate.m
//  PostgreSQL
//
//  Created by Francis McKenzie on 18/12/11.
//  Copyright (c) 2015 Macca Tech Ltd. All rights reserved.
//

#import "PGPrefsController.h"

#pragma mark - Inlines

// Get the next object in the array
CG_INLINE id
ObjectAfter(id object, NSArray *array)
{
    if (array.count < 2) return nil;
    if (object == array.lastObject) return nil;
    
    NSUInteger index = [array indexOfObject:object];
    if (index == NSNotFound) return nil;
    
    return index < array.count-1 ? array[index+1] : nil;
}
// Get the preceeding object in the array
CG_INLINE id
ObjectBefore(id object, NSArray *array)
{
    if (array.count < 2) return nil;
    if (object == array.firstObject) return nil;
    
    NSUInteger index = [array indexOfObject:object];
    if (index == NSNotFound) return nil;
    
    return index == 0 ? nil : array[index-1];
}



#pragma mark - Interfaces

@interface PGPrefsController()

@property (nonatomic, strong, readwrite) PGServerController *serverController;
@property (nonatomic, strong, readwrite) PGSearchController *searchController;
@property (nonatomic, strong, readwrite) PGServerDataStore *dataStore;
@property (nonatomic, strong, readwrite) PGServer *server;
@property (nonatomic, strong, readwrite) NSArray *servers;
@property (nonatomic, readwrite) AuthorizationRef authorization;
/// Used to start/stop all monitor threads. To stop all threads, set this key to nil. When a monitor thread runs, it compares its key to this one. If the keys are different, the monitor thread stops running.
@property (nonatomic, strong) id serversMonitorKey;

/**
 * If already authorized, returns the stored authorization. Otherwise, triggers user to authorize.
 *
 * @return nil if user cancelled
 */
- (AuthorizationRef)authorize;

@end



#pragma mark - PGPrefsController

@implementation PGPrefsController

#pragma mark Lifecycle

- (id)init
{
    return [self initWithViewController:nil];
}
- (id)initWithViewController:(id<PGPrefsViewController>)viewController
{
    self = [super init];
    if (self) {
        self.viewController = viewController;
        self.serverController = [[PGServerController alloc] init];
        self.searchController = [[PGSearchController alloc] init];
        self.dataStore = [[PGServerDataStore alloc] init];
        self.serverController.delegate = self;
        self.searchController.delegate = self;
        self.searchController.serverController = self.serverController;
        self.dataStore.serverController = self.serverController;
        self.authorization = nil;
    }
    return self;
}
- (void)viewDidLoad
{
    DLog(@"Loaded");
    
    [self.viewController prefsController:self didChangeServers:nil];
    [self.viewController prefsController:self didChangeSelectedServer:nil];
    
    // Load servers from plist
    [self.dataStore loadServers];
    self.servers = self.dataStore.servers;
    self.server = self.servers.firstObject;
    
    [self.viewController prefsController:self didChangeServers:self.servers];
    [self.viewController prefsController:self didChangeSelectedServer:self.server];
}
- (void)viewWillAppear
{
    // Do nothing
}
- (void)viewDidAppear
{
    // Start periodic server monitoring
    [self startMonitoringServers];
}
- (void)viewWillDisappear
{
    // Ensure saved preferences are written to disk
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    [self.viewController deauthorize];
    
    // Stop periodic server monitoring
    [self stopMonitoringServers];
}
- (void)viewDidDisappear
{
    DLog(@"didUnselect");
}
- (void)viewDidAuthorize:(AuthorizationRef)authorization
{
    self.authorization = authorization;
}
//
// DidDauthorize method will be called in any of following situations:
// 1. User clicked to close lock
// 2. User clicked show all
// 3. Sometimes called after PrefsDidLoad! <-- IMPORTANT
//
- (void)viewDidDeauthorize
{
    DLog(@"Deauthorized");
    
    self.authorization = nil;
}
- (PGRights *)rights
{
    return self.serverController.rights;
}



#pragma mark Servers

- (void)userDidSelectServer:(PGServer *)server
{
    self.server = server;
    
    [self.viewController prefsController:self didChangeSelectedServer:self.server];
}
- (void)userDidAddServer
{
    PGServer *server = [self.dataStore addServer];
    if (!server) return;
    
    // Get the new servers list after add
    self.servers = self.dataStore.servers;
    
    // Select the new server
    self.server = server;
    
    // Start monitoring
    [self startMonitoringServer:server];
    
    [self.viewController prefsController:self didChangeServers:self.servers];
    [self.viewController prefsController:self didChangeSelectedServer:self.server];
    
    // Start editing
    [self userWillEditSettings];
}
- (void)userDidDeleteServer
{
    if (!self.server) return;
    
    // Internal
    if (!self.server.external || [self.server.domain isEqualToString:PGPrefsAppIDVersion1]) {
        [self deleteServerAndDeleteFile:YES];
    
    // External
    } else {
        // Daemon file exists
        if (self.server.daemonFileExists) {
            [self.viewController prefsController:self willConfirmDeleteServer:self.server];
            
        // Daemon file not found
        } else {
            [self deleteServerAndDeleteFile:NO];
        }
    }
}
- (BOOL)userCanRenameServer:(NSString *)name
{
    return [self.dataStore serverWithName:name] == nil;
}
- (void)userDidRenameServer:(NSString *)name
{
    PGServer *server = self.server;
    if (!server) return;
    
    AuthorizationRef authorization = [self authorize];
    if (!authorization) return;
    
    PGServerAction finalAction = server.started ? PGServerStart : PGServerCreate;
    BackgroundThread(^{
        // First stop and delete the existing server
        [self.serverController runAction:PGServerDelete server:server authorization:authorization succeeded:^{
            
            MainThread(^{
                // Backup existing
                NSString *oldName = server.name;
                NSString *newName = name;

                // Apply the change
                BOOL succeeded = [self.serverController setName:newName forServer:server];
                
                // Save
                if (succeeded) succeeded = [self.dataStore saveServer:server];
                
                // Save failed - restore backup
                if (!succeeded) {
                    [self.serverController setName:oldName forServer:server];
                    return;
                }
            
                [self.viewController prefsController:self didChangeServers:self.servers];
            });
            
            // Create and start (if needed) the new server
            [self.serverController runAction:finalAction server:server authorization:authorization succeeded:^{
                
                MainThread(^{ [self.viewController prefsController:self didApplyServerSettings:server]; });
                
                [self checkStatus:server];

            } failed:nil];
        } failed:nil];
    });
}
- (void)userDidCancelRenameServer
{
    // Do nothing
}
- (void)userDidDuplicateServer
{
    if (!self.server) return;
    
    // Create the server and copy over the settings
    PGServer *server = [self.dataStore addServerWithName:self.server.shortName settings:self.server.settings];
    if (!server) return;
    
    // Get the new servers list after add
    self.servers = self.dataStore.servers;
    
    // Select the new server
    self.server = server;
    
    // Start monitoring
    [self startMonitoringServer:server];
    
    // Update view
    [self.viewController prefsController:self didChangeServers:self.servers];
    [self.viewController prefsController:self didChangeSelectedServer:self.server];
}
- (void)userDidRefreshServers
{
    [self startMonitoringServers];
}



#pragma mark Delete Confirmation

- (void)userDidDeleteServerShowInFinder
{
    if (!self.server.daemonFileExists) return;
    
    NSString *source = [NSString stringWithFormat:@""
                        "tell application \"Finder\"\n"
                        "reveal POSIX file \"%@\"\n"
                        "activate\n"
                        "end tell", [self.server.daemonFile stringByExpandingTildeInPath]];
    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:nil];
}
- (void)userDidCancelDeleteServer
{
    // Do nothing
}
- (void)userDidDeleteServerKeepFile
{
    [self deleteServerAndDeleteFile:NO];
}
- (void)userDidDeleteServerDeleteFile
{
    [self deleteServerAndDeleteFile:YES];
}



#pragma mark Start/Stop

- (void)userDidStartStopServer
{
    if (!self.server) return;
    
    // Determine action based on current status
    PGServerAction action;
    switch (self.server.status) {
        case PGServerStarted: // Fall through
        case PGServerRetrying: action = PGServerStop; break;
        case PGServerStopped: action = PGServerStart; break;
        default: action = PGServerCheckStatus;
    }
    
    // Start/Stop
    if (action == PGServerStart || action == PGServerStop) {
        
        AuthorizationRef authorization = [self authorize];
        if (!authorization) return;
        
        PGServer *server = self.server;
        BackgroundThread(^{
            [self.serverController runAction:action server:server authorization:authorization succeeded:^{
                BackgroundThreadAfterDelay(0.2, ^{
                    [self checkStatus:server];
                });
            } failed:nil];
        });
        
    // Check Status
    } else {
        [self checkStatus:self.server];
    }
}



#pragma mark Settings

- (void)userWillEditSettings
{
    [self.searchController findInstalledServers];
    
    [self.serverController clean:self.server];
    
    [self.viewController prefsController:self willEditServerSettings:self.server];
}
- (void)userDidSelectSearchServer:(PGServer *)server
{
    [self.serverController setDirtySettings:server.settings forServer:self.server];
    
    [self.viewController prefsController:self didChangeServerSettings:self.server];
}
- (void)userDidChangeSetting:(NSString *)setting value:(NSString *)value
{
    [self.serverController setDirtySetting:setting value:value forServer:self.server];
    
    [self.viewController prefsController:self didChangeServerSetting:setting server:self.server];
}
- (void)userDidCancelSettings
{
    [self.serverController clean:self.server];
    
    [self.viewController prefsController:self didRevertServerSettings:self.server];
}
- (void)userDidRevertSettings
{
    [self.serverController clean:self.server];
    
    [self.viewController prefsController:self didRevertServerSettings:self.server];
}
- (void)userDidApplySettings
{
    PGServer *server = self.server;
    if (server.external) return;
    
    AuthorizationRef authorization = [self authorize];
    if (!authorization) return;
    
    PGServerAction finalAction = server.started ? PGServerStart : PGServerCreate;
    BackgroundThread(^{
        if (!server.dirtySettings) return;
        
        // First stop and delete the existing server
        [self.serverController runAction:PGServerDelete server:self.server authorization:authorization succeeded:^{

            MainThread(^{
                // Backup existing
                PGServerSettings *oldSettings = server.settings;
                PGServerSettings *newSettings = server.dirtySettings;
                
                // Apply the change
                [self.serverController setSettings:newSettings forServer:server];
                
                // Save
                BOOL succeeded = [self.dataStore saveServer:server];
                
                // Save failed - restore backup
                if (!succeeded) {
                    [self.serverController setSettings:oldSettings forServer:server];
                    return;
                }
                
                // Clear dirty settings
                [self.serverController clean:server];
            });
            
            // Create and start (if needed) the new server
            [self.serverController runAction:finalAction server:server authorization:authorization succeeded:^{
                
                MainThread(^{ [self.viewController prefsController:self didApplyServerSettings:server]; });
                
                [self checkStatus:server];
                
            } failed:nil];
        } failed:nil];
    });
}
- (void)userDidChangeServerStartup:(NSString *)startup
{
    PGServer *server = self.server;
    if (server.external) return;
    
    // Revert startup in GUI if user cancelled authorization
    AuthorizationRef authorization = [self authorize];
    if (!authorization) {
        [self.viewController prefsController:self didRevertServerStartup:server];
        return;
    }
    
    // Backup existing
    PGServerStartup oldStartup = server.settings.startup;
    PGServerStartup newStartup = ToServerStartup(startup);
    
    // Apply the change
    BOOL succeeded = [self.serverController setStartup:newStartup forServer:server];
    
    // Save
    if (succeeded) succeeded = [self.dataStore saveServer:server];
    
    // Save failed - restore backup
    if (!succeeded) {
        [self.serverController setStartup:oldStartup forServer:server];
        [self.viewController prefsController:self didRevertServerStartup:server];
        return;
    }
    
    // Run script
    BackgroundThread(^{
        [self.serverController runAction:PGServerCreate server:server authorization:authorization succeeded:^{
            
            [self checkStatus:server];
            
        } failed:nil];
    });
}



#pragma mark Log

- (void)userDidViewLog
{
    if (!self.server.daemonLogExists) return;

    NSString *source = [NSString stringWithFormat:@""
                        "tell application \"Console\"\n"
                        "activate\n"
                        "open \"%@\"\n"
                        "end tell", [self.server.daemonLog stringByExpandingTildeInPath]];
    [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:nil];
}



#pragma mark PGServerDelegate

- (void)postgreServer:(PGServer *)server willRunAction:(PGServerAction)action
{
    MainThread(^{
        [self.viewController prefsController:self didChangeServerStatus:server];
    });
}
- (void)postgreServer:(PGServer *)server didSucceedAction:(PGServerAction)action
{
    MainThread(^{
        [self.viewController prefsController:self didChangeServerStatus:server];
    });
}
- (void)postgreServer:(PGServer *)server didFailAction:(PGServerAction)action error:(NSString *)error
{
    MainThread(^{
        [self.viewController prefsController:self didChangeServerStatus:server];
    });
}
- (void)postgreServer:(PGServer *)server didRunAction:(PGServerAction)action
{
    // Do nothing
}



#pragma mark PGSearchDelegate

- (void)didFindMoreServers:(PGSearchController *)search
{
    [self.viewController prefsController:self didChangeSearchServers:search.servers];
}



#pragma mark Private

- (AuthorizationRef)authorize
{
    if (self.authorization) return self.authorization;
    else return [self.viewController authorize];
}

- (void)checkStatus:(PGServer *)server
{
    BackgroundThread(^{
        [self.serverController runAction:PGServerCheckStatus server:server authorization:self.authorization];
    });
}

- (void)deleteServerAndDeleteFile:(BOOL)delete
{
    AuthorizationRef authorization = [self authorize];
    if (!authorization) return;
    
    PGServerAction action = delete ? PGServerDelete : PGServerStop;
    
    // Run script
    PGServer *server = self.server;
    BackgroundThread(^{
        [self.serverController runAction:action server:server authorization:authorization succeeded:^{
            
            MainThread(^{ [self removeServer:server]; });
        } failed:nil];
    });
}

- (void)removeServer:(PGServer *)server
{
    if (![self.servers containsObject:server]) return;
    
    DLog(@"%@", server);
    
    // Calculate which server to select after delete
    PGServer *nextServer = ObjectAfter(server, self.servers);
    if (!nextServer) nextServer = ObjectBefore(server, self.servers);
    
    // Delete the server
    [self.dataStore removeServer:server];
    
    // Get the new servers list after delete
    self.servers = self.dataStore.servers;
    
    // Tell view controller to update servers list
    [self.viewController prefsController:self didChangeServers:self.servers];
    
    // Select the next server
    if (!self.server || self.server == server || self.servers.count == 0) {
        self.server = nextServer;
        [self.viewController prefsController:self didChangeSelectedServer:self.server];
    }
}

- (void)startMonitoringServers
{
    self.serversMonitorKey = [NSDate date];
    for (PGServer *server in self.servers) [self startMonitoringServer:server];
    
    [self startMonitoringLaunchd];
}
- (void)stopMonitoringServers
{
    self.serversMonitorKey = nil;
    
}
- (void)startMonitoringServer:(PGServer *)server
{
    BackgroundThread(^{ [self pollServer:server key:self.serversMonitorKey]; });
}
- (void)pollServer:(PGServer *)server key:(id)key
{
    if (!key) return;

    // Ensure not stopped
    if (key != self.serversMonitorKey) return;
    
    // Ensure server not deleted
    __block BOOL serverExists = YES;
    MainThread(^{ serverExists = [self.servers containsObject:server]; });
    if (!serverExists) return;
    
    // Run check status
    [self checkStatus:server];
    
    // If stopped external server with no daemon file, delete it
    if (server.external && server.status == PGServerStopped && !server.daemonFileExists) {
        MainThread(^{ [self removeServer:server]; });
    }
    
    // Ensure not stopped
    if (key != self.serversMonitorKey) return;
    
    // Global disable auto-monitoring
    if (!PGPrefsMonitorServersEnabled) return;
    
    // Schedule re-run
    BackgroundThreadAfterDelay(PGServersPollTime, ^{ [self pollServer:server key:key]; });
}
- (void)startMonitoringLaunchd
{
    BackgroundThread(^{ [self detectExternalServers:self.serversMonitorKey]; });
}
- (void)detectExternalServers:(id)key
{
    if (!key) return;
    
    // Ensure not stopped
    if (key != self.serversMonitorKey) return;
    
    // Add any new external servers
    NSArray *loadedServers = [self.searchController startedServers];
    if (loadedServers.count > 0) {
        
        // Get existing servers by name
        NSArray *existingServers = self.dataStore.servers;
        NSMutableDictionary *existingLookup = existingServers.count == 0 ? nil : [NSMutableDictionary dictionaryWithCapacity:existingServers.count];
        for (PGServer *server in existingServers) {
            if (!NonBlank(server.name) || !server.external) continue;
            existingLookup[server.name] = server;
        }
        
        // Calculcate servers to add
        NSMutableArray *toAdd = [NSMutableArray arrayWithCapacity:loadedServers.count];
        for (PGServer *server in loadedServers) {
            if (!NonBlank(server.name)) continue;
            if (existingLookup[server.name]) continue;
            [toAdd addObject:server];
            
            // If server's daemon file exists, get more information from that
            if (!server.daemonFileExists) continue;
            PGServer *serverFromFile = [self.serverController serverFromDaemonFile:server.daemonFile];
            if (![serverFromFile.daemonName isEqualToString:server.daemonName]) continue;
            
            // Replace settings with file settings (because they're always more complete!)
            [self.serverController setSettings:serverFromFile.settings forServer:server];
        }
        
        // Add servers
        if (toAdd.count > 0) {
            MainThread(^{
                for (PGServer *server in toAdd) {
                    [self.dataStore saveServer:server];
                    [self startMonitoringServer:server];
                }
                
                self.servers = self.dataStore.servers;
                [self.viewController prefsController:self didChangeServers:self.servers];
                if (!self.server) {
                    self.server = self.servers.firstObject;
                    [self.viewController prefsController:self didChangeSelectedServer:self.server];
                }
            });
        }
    }
    
    // Ensure not stopped
    if (key != self.serversMonitorKey) return;
    
    // Global disable auto-monitoring
    if (!PGPrefsMonitorServersEnabled) return;
    
    // Schedule re-run
    BackgroundThreadAfterDelay(PGServersPollTime, ^{ [self detectExternalServers:key]; });
}

@end
