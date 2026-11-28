#import "LCSharedUtils.h"
#import "FoundationPrivate.h"
#import "UIKitPrivate.h"
#import "utils.h"
#import <objc/message.h>
@import MachO;

extern NSUserDefaults *lcUserDefaults;
extern NSString *lcAppUrlScheme;
extern NSBundle *lcMainBundle;

NSString* FBSOpenApplicationOptionKeyActivateAsClassic = @"__ActivateAsClassic";
NSString* FBSOpenApplicationOptionKeyPayloadURL = @"__PayloadURL";

@implementation LCSharedUtils

+ (NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)builtInApps {
    return @{
        @"builtinSideStore": @{@"name": @"SideStore", @"framework": @"SideStoreApp.framework", @"directory": @"SideStore", @"scheme": @"sidestore"},
        @"builtinSideInstaller": @{@"name": @"SideInstaller", @"framework": @"SideInstallerApp.framework", @"directory": @"SideInstaller", @"scheme": @"sideinstaller"}
    };
}

+ (NSBundle *)hostAppBundle {
    NSBundle *bundle = NSUserDefaults.lcMainBundle ?: NSBundle.mainBundle;
    if ([bundle.bundleURL.pathExtension isEqualToString:@"appex"]) {
        NSURL *url = bundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        return [NSBundle bundleWithURL:url];
    }
    return bundle;
}

+ (NSURL *)builtInAppURL:(NSString *)identifier {
    if (!identifier.length) return nil;
    NSString *framework = [self builtInApps][identifier][@"framework"];
    if (!framework) return nil;
    return [[self.hostAppBundle.bundleURL URLByAppendingPathComponent:@"Frameworks"] URLByAppendingPathComponent:framework];
}

+ (BOOL)builtInAppExists:(NSString *)identifier {
    NSURL *url = [self builtInAppURL:identifier];
    if (!url) return NO;
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    return bundle.executablePath.length && [NSFileManager.defaultManager fileExistsAtPath:bundle.executablePath];
}

+ (BOOL)handleSideStoreCellularCallback:(NSURL*)url {
    if (![url.scheme.lowercaseString isEqualToString:lcAppUrlScheme.lowercaseString] ||
        ![url.host.lowercaseString isEqualToString:@"cellular-refresh"]) {
        return NO;
    }

    Class bridge = NSClassFromString(@"SSCellularRefreshBridge");
    SEL selector = NSSelectorFromString(@"handleCallback:");
    if ([bridge respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL, NSURL*))objc_msgSend)(bridge, selector, url)) {
        return YES;
    }

    Class appSceneClass = NSClassFromString(@"AppSceneViewController");
    selector = NSSelectorFromString(@"deliverSideStoreCellularCallback:");
    if ([appSceneClass respondsToSelector:selector]) {
        ((BOOL (*)(id, SEL, NSURL*))objc_msgSend)(appSceneClass, selector, url);
    }

    // A guest scene delivers asynchronously. Also notify the background client;
    // only the SideStore instance with the matching one-use token accepts it.
    // A cold callback is consumed without launching another refresh; SideStore keeps
    // its recovery marker until the user next opens SideStore in the foreground.
    Class refreshHandler = NSClassFromString(@"LCRefreshHandler");
    selector = NSSelectorFromString(@"handleCellularCallback:");
    if ([refreshHandler respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSURL*))objc_msgSend)(refreshHandler, selector, url);
    }
    return YES;
}

+ (void)recoverPendingSideStoreCellularData {
    Class bridge = NSClassFromString(@"SSCellularRefreshBridge");
    SEL selector = NSSelectorFromString(@"recoverPendingData");
    if ([bridge respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(bridge, selector);
        return;
    }

    Class refreshHandler = NSClassFromString(@"LCRefreshHandler");
    selector = NSSelectorFromString(@"recoverPendingCellularData");
    if ([refreshHandler respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(refreshHandler, selector);
    }
}

+ (NSString*) teamIdentifier {
    static NSString* ans = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
#if !TARGET_OS_SIMULATOR
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFErrorRef error = NULL;
        CFTypeRef cfans = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.developer.team-identifier"), &error);
        if(cfans && CFGetTypeID(cfans) == CFStringGetTypeID()) {
            ans = (__bridge NSString*)cfans;
        }
        CFRelease(taskSelf);
#endif
        if(!ans) {
            // the above seems not to work if the device is jailbroken by Palera1n, so we use the public api one as backup
            // https://stackoverflow.com/a/11841898
            NSString *tempAccountName = @"bundleSeedID";
            NSDictionary *query = @{
                (__bridge NSString *)kSecClass : (__bridge NSString *)kSecClassGenericPassword,
                (__bridge NSString *)kSecAttrAccount : tempAccountName,
                (__bridge NSString *)kSecAttrService : @"",
                (__bridge NSString *)kSecReturnAttributes: (__bridge NSNumber *)kCFBooleanTrue,
            };
            CFDictionaryRef result = nil;
            OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecItemNotFound)
                status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
            if (status == errSecSuccess) {
                status = SecItemDelete((__bridge CFDictionaryRef)query); // remove temp item
                NSDictionary *dict = (__bridge_transfer NSDictionary *)result;
                NSString *accessGroup = dict[(__bridge NSString *)kSecAttrAccessGroup];
                NSArray *components = [accessGroup componentsSeparatedByString:@"."];
                NSString *bundleSeedID = [[components objectEnumerator] nextObject];
                ans = bundleSeedID;
            }
        }
    });
    return ans;
}

+ (NSString *)appGroupID {
    static dispatch_once_t once;
    static NSString *appGroupID = @"Unknown";
    dispatch_once(&once, ^{
        NSArray* possibleAppGroups = @[
            [@"group.com.SideStore.SideStore" stringByAppendingPathExtension:[self teamIdentifier]],
            [@"group.com.rileytestut.AltStore" stringByAppendingPathExtension:[self teamIdentifier]]
        ];
        
        // we prefer app groups with "Apps" in it, which indicate this app group is actually used by the store.
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            NSURL *bundlePath = [path URLByAppendingPathComponent:@"Apps"];
            if ([NSFileManager.defaultManager fileExistsAtPath:bundlePath.path]) {
                // This will fail if LiveContainer is installed in both stores, but it should never be the case
                appGroupID = group;
                return;
            }
        }
        
        // if no "Apps" is found, we choose a valid group
        for (NSString *group in possibleAppGroups) {
            NSURL *path = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
            if(!path) {
                continue;
            }
            appGroupID = group;
            return;
        }
        
        // if no possibleAppGroup is found, we detect app group from entitlement file
        // Cache app group after importing cert so we don't have to analyze executable every launch
        NSString *cached = [lcUserDefaults objectForKey:@"LCAppGroupID"];
        if (cached && [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:cached]) {
            appGroupID = cached;
            return;
        }
        CFErrorRef error = NULL;
        void* taskSelf = SecTaskCreateFromSelf(NULL);
        CFTypeRef value = SecTaskCopyValueForEntitlement(taskSelf, CFSTR("com.apple.security.application-groups"), &error);
        CFRelease(taskSelf);
        
        if(!value) {
            return;
        }
        NSArray* appGroups = (__bridge NSArray *)value;
        if(appGroups.count > 0) {
            appGroupID = [appGroups firstObject];
        }
    });
    return appGroupID;
}

+ (NSURL*) appGroupPath {
    static NSURL *appGroupPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        appGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]];
    });
    return appGroupPath;
}

+ (NSString *)certificatePassword {
    NSUserDefaults* nud = NSUserDefaults.lcSharedDefaults ?: NSUserDefaults.standardUserDefaults;
    return [nud objectForKey:@"LCCertificatePassword"];
}

+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode {
    void (^completionHandler)(BOOL) = ^(BOOL success) {
        // syscall(SYS_ptrace, PT_DENY_ATTACH, 0, 0, 0);
        __asm__ __volatile__ (
                              "mov x0, #31\n"
                              "mov x16, #26\n"
                              "svc #0x80"
                              );
        raise(SIGKILL);
    };
    
    if (!self.certificatePassword) {
        NSString *urlScheme = nil;
        NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
        if (!access(tsPath.UTF8String, F_OK)) {
            urlScheme = @"apple-magnifier://enable-jit?bundle-id=%@";
        }
        
        if(urlScheme) {
            NSURL *launchURL = [NSURL URLWithString:[NSString stringWithFormat:urlScheme, NSBundle.mainBundle.bundleIdentifier]];
            UIApplication *application = [NSClassFromString(@"UIApplication") sharedApplication];
            [application openURL:launchURL options:@{} completionHandler:completionHandler];
            return YES;
        }
    }

    int tries = 2;
    _LSOpenConfiguration *configuration = [[PrivClass(_LSOpenConfiguration) alloc] init];
    if(classicMode) {
        NSMutableDictionary* dict = [NSMutableDictionary new];
        dict[FBSOpenApplicationOptionKeyActivateAsClassic] = @(classicMode);
        configuration.frontBoardOptions = dict;
    }
    LSApplicationWorkspace* workspace = [PrivClass(LSApplicationWorkspace) defaultWorkspace];
    
    for (int i = 0; i < tries; i++) {
        [workspace openApplicationWithBundleIdentifier:NSUserDefaults.lcMainBundle.bundleIdentifier
                                         configuration:configuration
                                     completionHandler:^(BOOL success, NSError* error) {
            completionHandler(success);
        }];
    }
    return YES;
}

+ (BOOL)launchToGuestAppWithURL:(NSURL *)url {
    NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![components.host isEqualToString:@"livecontainer-launch"]) return NO;

    NSString* launchBundleId = nil;
    NSString* openUrl = nil;
    NSString* containerFolderName = nil;
    for (NSURLQueryItem* queryItem in components.queryItems) {
        if ([queryItem.name isEqualToString:@"bundle-name"]) {
            launchBundleId = queryItem.value;
        } else if ([queryItem.name isEqualToString:@"open-url"]){
            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:queryItem.value options:0];
            openUrl = [[NSString alloc] initWithData:decodedData encoding:NSUTF8StringEncoding];
        } else if ([queryItem.name isEqualToString:@"container-folder-name"]) {
            containerFolderName = queryItem.value;
        }
    }
    if ([launchBundleId isEqualToString:@"ui"] || (launchBundleId.length && [self builtInApps][launchBundleId])) {
        return [LCCompanionBridge openApp:launchBundleId URL:openUrl.length ? [NSURL URLWithString:openUrl] : nil];
    }
    if(launchBundleId) {
        if (openUrl) {
            [lcUserDefaults setObject:openUrl forKey:@"launchAppUrlScheme"];
        }
        
        // Attempt to restart LiveContainer with the selected guest app
        [lcUserDefaults setObject:launchBundleId forKey:@"selected"];
        [lcUserDefaults setObject:containerFolderName forKey:@"selectedContainer"];
        bool isSharedApp = false;
        NSBundle *appBundle = [self findBundleWithBundleId:launchBundleId isSharedAppOut:&isSharedApp];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
            [appBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        NSUInteger classicMode = [appInfo[@"classicMode"] boolValue]
            ? [appInfo[@"LCClassicModeCache"][@"defaultClassicMode"] unsignedIntegerValue]
            : 0;
        return [self launchToGuestAppWithClassicMode:classicMode];
    }
    
    return NO;
}

+ (void)setWebPageUrlForNextLaunch:(NSString*) urlString {
    [lcUserDefaults setObject:urlString forKey:@"webPageToOpen"];
}

+ (NSURL*)containerLockPath {
    static dispatch_once_t once;
    static NSURL *infoPath;
    
    dispatch_once(&once, ^{
        infoPath = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer/containerLock.plist"];
    });
    return infoPath;
}

+ (BOOL)isLCSchemeInUse:(NSString*)lc {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return NO;
    }
    
    NSNumber* num57 = info[lc];
    if(![num57 isKindOfClass:NSNumber.class]) {
        return NO;
    }
    
    uint64_t val57 = [num57 longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno != ESRCH;
}

+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName {
    NSURL* infoPath = [self containerLockPath];
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        return nil;
    }
    
    NSDictionary* appUsageInfo = info[folderName];
    if (!appUsageInfo) {
        return nil;
    }
    uint64_t val57 = [appUsageInfo[@"auditToken57"] longLongValue];
    audit_token_t token;
    token.val[5] = val57 >> 32;
    token.val[7] = val57 & 0xffffffff;
    
    errno = 0;
    csops_audittoken(token.val[5], 0, NULL, 0, &token);
    return errno==ESRCH ? nil : appUsageInfo[@"runningLC"];
}

// lc can be something like livecontainer or livecontainer2.liveprocess, such that one LC can jump to another LC hosting the multitask app when user presses run while it's running
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57 {
    NSURL* infoPath = [self containerLockPath];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfFile:infoPath.path];
    if (!info) {
        info = [NSMutableDictionary new];
    }
    
    if(val57 == 0) {
        audit_token_t token;
        mach_msg_type_number_t size = TASK_AUDIT_TOKEN_COUNT;
        
        kern_return_t kr = task_info(mach_task_self(), TASK_AUDIT_TOKEN, (task_info_t)&token, &size);
        if (kr != KERN_SUCCESS) {
            NSLog(@"Error getting task audit_token");
        }
        val57 = token.val[7] | ((uint64_t)token.val[5] << 32);
    }
    info[folderName] = @{
        @"runningLC": lc,
        @"auditToken57": @(val57)
    };
    
    info[lc] = @(val57);

    [info writeBinToFile:infoPath.path atomically:YES];
}

// move app data to private folder to prevent 0xdead10cc https://forums.developer.apple.com/forums/thread/126438
// This method is here for backward compatability, 0xdead10cc is already resolved.
+ (void)moveSharedAppFolderBack {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *libraryPathUrl = [fm URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *docPathUrl = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject;
    NSURL *appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSError *error;
    NSString *sharedAppDataFolderPath = [libraryPathUrl.path stringByAppendingPathComponent:@"SharedDocuments"];
    if(![fm fileExistsAtPath:sharedAppDataFolderPath]){
        return;
    }
    // move all apps in shared folder back
    NSArray<NSString *> * sharedDataFoldersToMove = [fm contentsOfDirectoryAtPath:sharedAppDataFolderPath error:&error];
    
    // something went wrong with app group
    if(!appGroupFolder && sharedDataFoldersToMove.count > 0) {
        [lcUserDefaults setObject:@"LiveContainer was unable to move the data of shared app back because LiveContainer cannot access app group. Please check JITLess diagnose page in LiveContainer settings for more information." forKey:@"error"];
        return;
    }
    
    for(int i = 0; i < [sharedDataFoldersToMove count]; ++i) {
        NSString* destPath = [appGroupFolder.path stringByAppendingPathComponent:[NSString stringWithFormat:@"Data/Application/%@", sharedDataFoldersToMove[i]]];
        if([fm fileExistsAtPath:destPath]) {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:[docPathUrl.path stringByAppendingPathComponent:[NSString stringWithFormat:@"FOLDER_EXISTS_AT_APP_GROUP_%@", sharedDataFoldersToMove[i]]]
             error:&error
            ];
            
        } else {
            [fm
             moveItemAtPath:[sharedAppDataFolderPath stringByAppendingPathComponent:sharedDataFoldersToMove[i]]
             toPath:destPath
             error:&error
            ];
        }
    }
    
}

+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut {
    NSURL *builtInURL = [self builtInAppURL:bundleId];
    if (builtInURL) {
        if (isSharedAppOut) *isSharedAppOut = false;
        return [NSBundle bundleWithURL:builtInURL];
    }
    NSString *docPath = [NSString stringWithFormat:@"%s/Documents", getenv("LC_HOME_PATH")];
    
    NSURL *appGroupFolder = nil;
    
    NSString *bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", docPath, bundleId];
    NSBundle *appBundle;
    if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
        appBundle = [[NSBundle alloc] initWithPath:bundlePath];
    }

    // not found locally, let's look for the app in shared folder
    if (!appBundle) {
        appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
        
        bundlePath = [NSString stringWithFormat:@"%@/Applications/%@", appGroupFolder.path, bundleId];
        if([NSFileManager.defaultManager fileExistsAtPath:bundlePath]) {
            appBundle = [[NSBundle alloc] initWithPath:bundlePath];
        }
        if(appBundle) {
            *isSharedAppOut = true;
        }
    } else {
        *isSharedAppOut = false;
    }
    return appBundle;
}

// This method is here for backward compatability, preferences is direcrly saved to app's preference folder.
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID {
    NSFileManager* fm = [[NSFileManager alloc] init];
    NSError* error1;
    
    NSDictionary* preferences = [lcUserDefaults objectForKey:dataUUID];
    if(!preferences) {
        return;
    }
    
    [fm createDirectoryAtPath:plistLocationTo withIntermediateDirectories:YES attributes:@{} error:&error1];
    for(NSString* identifier in preferences) {
        NSDictionary* preference = preferences[identifier];
        NSString *itemPath = [plistLocationTo stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.plist", identifier]];
        if([preference count] == 0) {
            // Attempt to delete the file
            [fm removeItemAtPath:itemPath error:&error1];
            continue;
        }
        [preference writeToFile:itemPath atomically:YES];
    }
    [lcUserDefaults removeObjectForKey:dataUUID];
}

+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId {
    NSURL *builtInURL = [self builtInAppURL:bundleId];
    if (builtInURL) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[builtInURL URLByAppendingPathComponent:@"LCAppInfo.plist"]];
        return info[@"LCDataUUID"];
    }
    // find app's default container
    NSURL* appGroupFolder = [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer"];
    
    NSString* bundleInfoPath = [NSString stringWithFormat:@"%@/Applications/%@/LCAppInfo.plist", appGroupFolder.path, bundleId];
    NSDictionary* infoDict = [NSDictionary dictionaryWithContentsOfFile:bundleInfoPath];
    return infoDict[@"LCDataUUID"];
}

+ (NSArray<NSString*>*)lcUnorderedUrlSchemes {
    NSArray<NSString *> *defaultSchemes = @[@"livecontainer", @"livecontainer2", @"livecontainer3"];
    return defaultSchemes;
}

+ (NSArray<NSString*>*)lcUrlSchemes {
    NSArray<NSString *> *defaultSchemes = [self lcUnorderedUrlSchemes];
    NSSet<NSString *> *allowedSchemes = [NSSet setWithArray:defaultSchemes];
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    id savedValue = [NSUserDefaults.lcSharedDefaults objectForKey:@"LCMultiLaunchPriority"];
    if([savedValue isKindOfClass:NSArray.class]) {
        for(id value in (NSArray *)savedValue) {
            if(![value isKindOfClass:NSString.class]) {
                continue;
            }

            NSString *scheme = [(NSString *)value lowercaseString];
            if(![allowedSchemes containsObject:scheme] || [result containsObject:scheme]) {
                continue;
            }

            [result addObject:scheme];
        }
    }

    for(NSString *scheme in defaultSchemes) {
        if(![result containsObject:scheme]) {
            [result addObject:scheme];
        }
    }

    return result;
}
@end

static NSMutableDictionary<NSString *, NSString *> *LCCompanionActivities;
static BOOL LCCompanionSwitchPending;
static NSDictionary *LCCompanionPendingLink;
static NSString *const LCCompanionMenuID = @"lc.companion.switch";
static NSString *const LCCompanionSpacingID = @"lc.companion.spacing";

static UIViewController *LCForegroundController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindow *window = ((UIWindowScene *)scene).keyWindow;
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController) controller = controller.presentedViewController;
        if (controller) return controller;
    }
    return nil;
}

static BOOL LCCompanionHasPresentedSheet(void) {
    UIViewController *controller = LCForegroundController();
    if (!controller.presentingViewController) return NO;
    if ([controller isKindOfClass:UIAlertController.class]) return YES;
    if ([controller.presentationController isKindOfClass:UISheetPresentationController.class]) return YES;
    return controller.modalPresentationStyle == UIModalPresentationFullScreen;
}

static void LCShowCompanionMessage(NSString *message) {
    UIViewController *controller = LCForegroundController();
    if (!controller || [controller isKindOfClass:UIAlertController.class]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"切换应用" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

@interface UIViewController (LCCompanionNavigation)
- (void)lc_companionViewDidAppear:(BOOL)animated;
- (void)lc_companionViewDidLayoutSubviews;
@end

@implementation LCCompanionBridge

+ (NSString *)currentAppIdentifier {
    return NSUserDefaults.builtInAppIdentifier ?: (NSUserDefaults.lcGuestAppId ?: @"ui");
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)availableApps {
    NSMutableArray *apps = [NSMutableArray arrayWithObject:@{@"identifier": @"ui", @"name": @"LiveContainer", @"shortName": @"LC"}];
    for (NSString *identifier in @[@"builtinSideStore", @"builtinSideInstaller"]) {
        if (![LCSharedUtils builtInAppExists:identifier]) continue;
        NSString *name = [LCSharedUtils builtInApps][identifier][@"name"];
        [apps addObject:@{@"identifier": identifier, @"name": name, @"shortName": [identifier isEqualToString:@"builtinSideStore"] ? @"SS" : @"SI"}];
    }
    return apps;
}

+ (UIImage *)navigationIconForApp:(NSString *)identifier {
    NSURL *url = [LCSharedUtils builtInAppURL:identifier] ?: LCSharedUtils.hostAppBundle.bundleURL;
    static NSCache<NSString *, UIImage *> *icons;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ icons = [NSCache new]; });
    UIImage *cached = [icons objectForKey:url.path];
    if (cached) return cached;
    NSBundle *bundle = [NSBundle bundleWithURL:url];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Info.plist"]];
    NSArray *names = info[@"CFBundleIcons"][@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] ?: info[@"CFBundleIconFiles"];
    UIImage *source = nil;
    for (NSString *name in names) {
        source = [UIImage imageNamed:name inBundle:bundle compatibleWithTraitCollection:nil];
        if (source) break;
    }
    if (!source) source = [UIImage imageNamed:@"AppIcon60x60" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!source) source = [UIImage imageNamed:@"LiveContainerIcon" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!source) source = [UIImage imageNamed:@"DefaultIcon" inBundle:bundle compatibleWithTraitCollection:nil];
    if (!source) return [UIImage systemImageNamed:@"app"];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(26, 26)];
    UIImage *image = [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 26, 26) cornerRadius:6] addClip];
        [source drawInRect:CGRectMake(0, 0, 26, 26)];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    [icons setObject:image forKey:url.path];
    return image;
}

+ (UIImage *)currentNavigationIcon {
    return [self navigationIconForApp:[self currentAppIdentifier]];
}

+ (UIButton *)navigationButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[self currentNavigationIcon] forState:UIControlStateNormal];
    button.menu = [self navigationMenu];
    button.showsMenuAsPrimaryAction = YES;
    button.accessibilityIdentifier = LCCompanionMenuID;
    button.accessibilityLabel = @"切换 LiveContainer、SideStore 或 SideInstaller";
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:44], [button.heightAnchor constraintEqualToConstant:44]
    ]];
    return button;
}

+ (void)setActivity:(NSString *)identifier reason:(NSString *)reason {
    if (!NSThread.isMainThread) {
        dispatch_sync(dispatch_get_main_queue(), ^{ [self setActivity:identifier reason:reason]; });
        return;
    }
    if (!LCCompanionActivities) LCCompanionActivities = [NSMutableDictionary dictionary];
    if (reason.length) LCCompanionActivities[identifier] = reason;
    else [LCCompanionActivities removeObjectForKey:identifier];
}

+ (NSString *)switchBlockReason {
    if (!NSThread.isMainThread || NSUserDefaults.isLiveProcess) return @"请回到主应用切换。";
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return @"请在前台切换应用。";
    if (LCCompanionSwitchPending) return @"正在切换应用，请稍候。";
    if (LCCompanionHasPresentedSheet()) return @"请先完成或关闭当前弹窗，再切换应用。";
    if (LCCompanionActivities.count) return LCCompanionActivities.allValues.firstObject;
    Class refresh = NSClassFromString(@"LCRefreshHandler");
    SEL refreshSelector = NSSelectorFromString(@"companionSwitchBlockReason");
    NSString *refreshReason = [refresh respondsToSelector:refreshSelector] ? ((id (*)(id, SEL))objc_msgSend)(refresh, refreshSelector) : nil;
    if (refreshReason.length) return refreshReason;
    NSString *identifier = [self currentAppIdentifier];
    NSString *className = @"LCCompanionActivityBridge";
    if ([identifier isEqualToString:@"builtinSideStore"]) className = @"SSCompanionActivityBridge";
    if ([identifier isEqualToString:@"builtinSideInstaller"]) className = @"SICompanionBridge";
    Class activity = NSClassFromString(className);
    SEL selector = NSSelectorFromString(@"switchBlockReason");
    if ([activity respondsToSelector:selector]) return ((id (*)(id, SEL))objc_msgSend)(activity, selector);
    if (NSUserDefaults.builtInAppIdentifier) return @"应用正在准备，请稍后再切换。";
    return nil;
}

+ (BOOL)openApp:(NSString *)identifier {
    return [self openApp:identifier URL:nil];
}

+ (BOOL)openApp:(NSString *)identifier URL:(NSURL *)url {
    if (!NSThread.isMainThread) return NO;
    if (!url && [[self currentAppIdentifier] isEqualToString:identifier]) return YES;
    BOOL isUI = [identifier isEqualToString:@"ui"];
    if (!isUI && ![LCSharedUtils builtInAppExists:identifier]) {
        LCShowCompanionMessage(@"内置应用文件缺失，请重新安装完整组合包。");
        return NO;
    }
    NSString *reason = [self switchBlockReason];
    if (reason.length) {
        LCShowCompanionMessage(reason);
        return NO;
    }
    if ([[self currentAppIdentifier] isEqualToString:identifier]) {
        if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
        return YES;
    }
    NSUserDefaults *defaults = NSUserDefaults.lcUserDefaults;
    [defaults removeObjectForKey:@"LCOpenSideStore"];
    [defaults removeObjectForKey:@"selectedContainer"];
    [defaults removeObjectForKey:@"webPageToOpen"];
    [defaults setObject:url.absoluteString forKey:@"launchAppUrlScheme"];
    [defaults setObject:identifier forKey:@"selected"];
    [defaults synchronize];
    LCCompanionSwitchPending = YES;
    return [LCSharedUtils launchToGuestAppWithClassicMode:0];
}

+ (BOOL)handleCompanionURL:(NSURL *)url {
    if (!NSThread.isMainThread || NSUserDefaults.isLiveProcess) return NO;
    NSString *target = nil;
    NSURL *forwardURL = url;
    for (NSString *identifier in [LCSharedUtils builtInApps]) {
        NSString *scheme = [LCSharedUtils builtInApps][identifier][@"scheme"];
        if ([url.scheme.lowercaseString isEqualToString:scheme]) target = identifier;
    }
    BOOL hostLink = [url.scheme.lowercaseString isEqualToString:NSUserDefaults.lcAppUrlScheme.lowercaseString];
    if (hostLink && [url.host isEqualToString:@"livecontainer-launch"]) {
        forwardURL = nil;
        NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in parts.queryItems) {
            if ([item.name isEqualToString:@"bundle-name"]) target = item.value;
            if ([item.name isEqualToString:@"open-url"]) {
                NSData *data = [[NSData alloc] initWithBase64EncodedString:item.value options:0];
                NSString *decoded = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                forwardURL = decoded.length ? [NSURL URLWithString:decoded] : nil;
            }
        }
    }
    BOOL knownTarget = [target isEqualToString:@"ui"] || [LCSharedUtils builtInAppExists:target];
    if (!knownTarget || [[self currentAppIdentifier] isEqualToString:target]) return NO;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
        [self openApp:target URL:forwardURL];
        return YES;
    }
    LCCompanionPendingLink = @{@"target": target, @"url": forwardURL ?: NSNull.null, @"date": NSDate.date};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            NSDictionary *link = LCCompanionPendingLink;
            LCCompanionPendingLink = nil;
            NSURL *payload = [link[@"url"] isKindOfClass:NSURL.class] ? link[@"url"] : nil;
            if (link && -[link[@"date"] timeIntervalSinceNow] < 30) [self openApp:link[@"target"] URL:payload];
        }];
    });
    return YES;
}

+ (UIMenu *)navigationMenu {
    UIDeferredMenuElement *choices = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
        NSString *reason = [self switchBlockReason];
        NSString *current = [self currentAppIdentifier];
        for (NSDictionary *app in [self availableApps]) {
            NSString *identifier = app[@"identifier"];
            UIAction *action = [UIAction actionWithTitle:app[@"name"] image:[self navigationIconForApp:identifier] identifier:identifier handler:^(__kindof UIAction *action) {
                [self openApp:identifier];
            }];
            action.state = [identifier isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
            action.attributes = reason.length ? UIMenuElementAttributesDisabled : 0;
            [items addObject:action];
        }
        if (reason.length) {
            UIAction *message = [UIAction actionWithTitle:reason image:nil identifier:nil handler:^(__kindof UIAction *action) {}];
            message.attributes = UIMenuElementAttributesDisabled;
            [items addObject:message];
        }
        completion(items);
    }];
    return [UIMenu menuWithTitle:@"" children:@[choices]];
}

+ (BOOL)isPrimaryNavigation:(UINavigationController *)navigation {
    if (!navigation || navigation.isNavigationBarHidden) return NO;
    UIViewController *root = navigation.view.window.rootViewController;
    UIViewController *owner = navigation;
    while (owner && owner != root) {
        if (owner.presentingViewController) return NO;
        owner = owner.parentViewController;
    }
    return root && owner == root && !navigation.presentingViewController;
}

+ (NSArray<UIBarButtonItem *> *)withoutSwitcher:(NSArray<UIBarButtonItem *> *)items {
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(UIBarButtonItem *item, NSDictionary *bindings) {
        return ![item.accessibilityIdentifier isEqualToString:LCCompanionMenuID]
            && ![item.accessibilityIdentifier isEqualToString:LCCompanionSpacingID];
    }];
    return [items filteredArrayUsingPredicate:predicate] ?: @[];
}

+ (void)updateNavigationForController:(UIViewController *)controller {
    UINavigationController *navigation = controller.navigationController;
    if (![self isPrimaryNavigation:navigation] || self.availableApps.count < 2) return;
    UIViewController *top = navigation.topViewController;
    if (!top || top.presentedViewController) return;
    BOOL isRoot = navigation.viewControllers.firstObject == top;
    // The host tabs compose the switcher with their own SwiftUI toolbar items.
    if (isRoot && !NSUserDefaults.builtInAppIdentifier) return;
    UINavigationItem *item = top.navigationItem;
    NSArray *expectedItems = isRoot ? item.leftBarButtonItems : item.rightBarButtonItems;
    for (UIBarButtonItem *existing in expectedItems) {
        if (![existing.accessibilityIdentifier isEqualToString:LCCompanionMenuID]) continue;
        if ([existing.customView isKindOfClass:UIButton.class]) {
            [(UIButton *)existing.customView setImage:[self currentNavigationIcon] forState:UIControlStateNormal];
        }
        return;
    }
    NSArray *left = [self withoutSwitcher:item.leftBarButtonItems];
    NSArray *right = [self withoutSwitcher:item.rightBarButtonItems];
    UIButton *button = [self navigationButton];
    UIBarButtonItem *switcher = [[UIBarButtonItem alloc] initWithCustomView:button];
    switcher.accessibilityIdentifier = LCCompanionMenuID;
    switcher.accessibilityLabel = @"切换 LiveContainer、SideStore 或 SideInstaller";
    UIView *space = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 1)];
    UIBarButtonItem *spacing = [[UIBarButtonItem alloc] initWithCustomView:space];
    spacing.accessibilityIdentifier = LCCompanionSpacingID;
    if (@available(iOS 26.0, *)) spacing.hidesSharedBackground = YES;
    if (isRoot || left.count != item.leftBarButtonItems.count) {
        item.leftBarButtonItems = isRoot ? [left arrayByAddingObjectsFromArray:@[spacing, switcher]] : left;
    }
    if (!isRoot || right.count != item.rightBarButtonItems.count) {
        item.rightBarButtonItems = isRoot ? right : [right arrayByAddingObject:switcher];
    }
}

+ (void)installNavigationMenus {
    if (NSUserDefaults.isLiveProcess) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        swizzle(UIViewController.class, @selector(viewDidAppear:), @selector(lc_companionViewDidAppear:));
        swizzle(UIViewController.class, @selector(viewDidLayoutSubviews), @selector(lc_companionViewDidLayoutSubviews));
    });
}
@end

@implementation UIViewController (LCCompanionNavigation)
- (void)lc_companionViewDidLayoutSubviews {
    [self lc_companionViewDidLayoutSubviews];
    if (self.viewIfLoaded.window) [LCCompanionBridge updateNavigationForController:self];
}
- (void)lc_companionViewDidAppear:(BOOL)animated {
    [self lc_companionViewDidAppear:animated];
    [LCCompanionBridge updateNavigationForController:self];
    __weak UIViewController *controller = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (controller.viewIfLoaded.window) [LCCompanionBridge updateNavigationForController:controller];
    });
}
@end
