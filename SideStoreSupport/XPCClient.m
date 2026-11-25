//
//  XPCClient.m
//  AltStore
//
//  Created by s s on 2025/7/20.
//  Copyright © 2025 SideStore. All rights reserved.
//
#include "XPCServer.h"
#include "../LiveContainer/utils.h"
#include "../LiveContainer/LCSharedUtils.h"
#include <objc/message.h>
@import UIKit;

@interface SideStoreClient(Swift)
- (void)performRefreshForRealWithIdentifier:(NSString*)identifier
                            mangledTypeName:(NSString*)mangledTypeName
                          requestIdentifier:(NSString*)requestIdentifier
                                     server:(id <RefreshServer> _Nonnull)server;

@end

static LiveProcessSideStoreHandler* handler = nil;
void installSideStoreHooks(void);

NSProgress *startSideStoreTrackedRefresh(NSString *requestIdentifier, void (^completion)(NSError *error)) {
    Class bridge = NSClassFromString(@"SSBackgroundRefreshBridge");
    SEL selector = NSSelectorFromString(@"startRefreshWithRequestIdentifier:completion:");
    if ([bridge respondsToSelector:selector]) {
        typedef NSProgress *(*StartRefresh)(id, SEL, NSString *, void (^)(NSError *));
        return ((StartRefresh)objc_msgSend)(bridge, selector, requestIdentifier, completion);
    }
    completion([NSError errorWithDomain:@"SideStore.ShortcutRefreshBridge" code:1
                              userInfo:@{NSLocalizedDescriptionKey: @"The built-in SideStore refresh bridge is missing. Reinstall the complete updated package. No refresh was started."}]);
    return nil;
}

@implementation SideStoreClient

+ (SideStoreClient*)shared {
    static SideStoreClient* sharedClient = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedClient = [SideStoreClient new];
    });

    return sharedClient;
}

+ (void)load {
    if(!NSUserDefaults.isSideStore) return;
    
    installSideStoreHooks();
    
    if(!NSUserDefaults.isLiveProcess) return;
    
    handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    installSideStoreNotificationHooks();
    handler.connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(RefreshClient)];
    handler.connection.exportedObject = SideStoreClient.shared;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidFinishLaunching:)
                                                 name:UIApplicationDidFinishLaunchingNotification
                                               object:nil];
}

// Implement the callback method
+ (void)appDidFinishLaunching:(NSNotification *)notification {
    NSDictionary *launchOptions = notification.userInfo;
    [handler.server finishedLaunching];
}

- (void) relaunchLC {
    [LCSharedUtils launchToGuestAppWithClassicMode:0];
}

- (void)refreshAllAppsWithIdentifier:(NSString*)identifier mangledTypeName:(NSString *)mangledTypeName requestIdentifier:(NSString*)requestIdentifier {
    if(!handler) {
        return;
    }
    [self performRefreshForRealWithIdentifier:identifier mangledTypeName:mangledTypeName requestIdentifier:requestIdentifier server:handler.server];
}

- (void)handleCellularCallback:(NSURL*)url {
    Class bridge = NSClassFromString(@"SSCellularRefreshBridge");
    SEL selector = NSSelectorFromString(@"handleCallback:");
    if ([bridge respondsToSelector:selector]) {
        ((BOOL (*)(id, SEL, NSURL*))objc_msgSend)(bridge, selector, url);
    }
}

- (void)recoverPendingCellularData {
    Class bridge = NSClassFromString(@"SSCellularRefreshBridge");
    SEL selector = NSSelectorFromString(@"recoverPendingData");
    if ([bridge respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(bridge, selector);
    }
}

@end
