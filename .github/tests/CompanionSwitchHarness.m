#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSInteger const UIApplicationStateActive = 0;
static NSString *const UIApplicationDidBecomeActiveNotification = @"active";
static NSString *currentBuiltIn;
static NSString *guestIdentifier;
static NSString *activityReason;
static NSString *refreshReason;
static BOOL liveProcess;
static BOOL showingSheet;
static BOOL bridgeReady = YES;
static NSUInteger restartCount;
static NSString *lastMessage;
static NSMutableSet *installed;
static NSMutableDictionary *values;
static NSMutableDictionary<NSString *, NSString *> *LCCompanionActivities;
static BOOL LCCompanionSwitchPending;
static NSDictionary *LCCompanionPendingLink;

@interface MemoryDefaults : NSUserDefaults
@end
@implementation MemoryDefaults
- (void)setObject:(id)value forKey:(NSString *)key {
    if (value) values[key] = value;
    else [values removeObjectForKey:key];
}
- (void)removeObjectForKey:(NSString *)key { [values removeObjectForKey:key]; }
- (BOOL)synchronize { return YES; }
@end

@interface NSUserDefaults (CompanionFixture)
+ (BOOL)isLiveProcess;
+ (NSString *)builtInAppIdentifier;
+ (NSString *)lcGuestAppId;
+ (NSString *)lcAppUrlScheme;
+ (NSUserDefaults *)lcUserDefaults;
@end
@implementation NSUserDefaults (CompanionFixture)
+ (BOOL)isLiveProcess { return liveProcess; }
+ (NSString *)builtInAppIdentifier { return currentBuiltIn; }
+ (NSString *)lcGuestAppId { return guestIdentifier; }
+ (NSString *)lcAppUrlScheme { return @"livecontainer"; }
+ (NSUserDefaults *)lcUserDefaults { return [MemoryDefaults new]; }
@end

@interface FakeApplication : NSObject
@property NSInteger applicationState;
@property NSURL *openedURL;
+ (instancetype)sharedApplication;
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(id)completion;
@end
@implementation FakeApplication
+ (instancetype)sharedApplication { static id app; if (!app) app = [self new]; return app; }
- (void)openURL:(NSURL *)url options:(NSDictionary *)options completionHandler:(id)completion { self.openedURL = url; }
@end

@interface LCCompanionActivityBridge : NSObject
+ (NSString *)switchBlockReason;
@end
@implementation LCCompanionActivityBridge
+ (NSString *)switchBlockReason { return activityReason; }
@end
@interface SSCompanionActivityBridge : LCCompanionActivityBridge
@end
@implementation SSCompanionActivityBridge
+ (BOOL)respondsToSelector:(SEL)selector { return bridgeReady && [super respondsToSelector:selector]; }
@end
@interface SICompanionBridge : SSCompanionActivityBridge
@end
@implementation SICompanionBridge
@end
@interface LCRefreshHandler : NSObject
+ (NSString *)companionSwitchBlockReason;
@end
@implementation LCRefreshHandler
+ (NSString *)companionSwitchBlockReason { return refreshReason; }
@end

static BOOL LCCompanionHasPresentedSheet(void) { return showingSheet; }
static void LCShowCompanionMessage(NSString *message) { lastMessage = message; }

@interface LCSharedUtils : NSObject
+ (NSDictionary *)builtInApps;
+ (BOOL)builtInAppExists:(NSString *)identifier;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)mode;
@end
@implementation LCSharedUtils
// INSERT_REGISTRY
+ (BOOL)builtInAppExists:(NSString *)identifier { return identifier && [installed containsObject:identifier]; }
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)mode { restartCount++; return YES; }
@end

@interface LCCompanionBridge : NSObject
+ (NSString *)currentAppIdentifier;
+ (NSString *)switchBlockReason;
+ (BOOL)openApp:(NSString *)identifier URL:(NSURL *)url;
+ (BOOL)handleCompanionURL:(NSURL *)url;
@end
@implementation LCCompanionBridge
// INSERT_BRIDGE
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAILED: %@", message); exit(1); }
}
static void reset(void) {
    currentBuiltIn = @"builtinSideStore";
    guestIdentifier = @"com.SideStore.SideStore";
    liveProcess = NO;
    showingSheet = NO;
    bridgeReady = YES;
    activityReason = nil;
    refreshReason = nil;
    restartCount = 0;
    lastMessage = nil;
    LCCompanionSwitchPending = NO;
    LCCompanionPendingLink = nil;
    LCCompanionActivities = [NSMutableDictionary dictionary];
    values = [@{@"selectedContainer": @"old-container", @"LCOpenSideStore": @YES,
                 @"launchAppUrlScheme": @"stale-url", @"webPageToOpen": @"stale-web"} mutableCopy];
    installed = [NSMutableSet setWithArray:@[@"builtinSideStore", @"builtinSideInstaller"]];
    FakeApplication.sharedApplication.applicationState = UIApplicationStateActive;
    FakeApplication.sharedApplication.openedURL = nil;
}

int main(void) {
    @autoreleasepool {
        reset();
        NSDictionary *registry = LCSharedUtils.builtInApps;
        check([registry[@"builtinSideInstaller"][@"directory"] isEqual:@"SideInstaller"], @"independent SI home");
        check([registry[@"builtinSideInstaller"][@"framework"] isEqual:@"SideInstallerApp.framework"], @"SI framework registry");
        check([LCCompanionBridge openApp:@"builtinSideInstaller" URL:nil], @"SS switches directly to SI");
        check(restartCount == 1 && [values[@"selected"] isEqual:@"builtinSideInstaller"], @"one target and one restart");
        check(!values[@"selectedContainer"] && !values[@"LCOpenSideStore"] && !values[@"launchAppUrlScheme"] && !values[@"webPageToOpen"], @"stale launch state removed");
        check(![LCCompanionBridge openApp:@"ui" URL:nil] && restartCount == 1, @"duplicate taps cannot queue a second switch");

        reset();
        currentBuiltIn = @"builtinSideInstaller";
        NSURL *callback = [NSURL URLWithString:@"sidestore://my-apps"];
        check([LCCompanionBridge handleCompanionURL:callback], @"SI forwards SS URLs");
        check(restartCount == 1 && [values[@"selected"] isEqual:@"builtinSideStore"] && [values[@"launchAppUrlScheme"] isEqual:callback.absoluteString], @"callback payload survives direct switch");

        reset();
        check([LCCompanionBridge openApp:@"ui" URL:nil] && [values[@"selected"] isEqual:@"ui"], @"explicit LC target");
        reset();
        check([LCCompanionBridge openApp:@"builtinSideStore" URL:callback] && restartCount == 0, @"same app URL needs no restart");
        check([FakeApplication.sharedApplication.openedURL isEqual:callback], @"same app receives callback");
        check(![LCCompanionBridge handleCompanionURL:callback], @"current app URLs pass through");
        check(![LCCompanionBridge handleCompanionURL:[NSURL URLWithString:@"https://example.com"]], @"unrelated URLs pass through");
        reset();
        currentBuiltIn = nil;
        guestIdentifier = nil;
        check([LCCompanionBridge handleCompanionURL:[NSURL URLWithString:@"livecontainer://livecontainer-launch?bundle-name=builtinSideInstaller"]], @"LC host links route to SI");
        check(restartCount == 1 && [values[@"selected"] isEqual:@"builtinSideInstaller"] && !values[@"launchAppUrlScheme"], @"host control URL is not forwarded as an app payload");

        reset();
        [installed removeObject:@"builtinSideInstaller"];
        check(![LCCompanionBridge openApp:@"builtinSideInstaller" URL:nil] && restartCount == 0 && !values[@"selected"], @"missing companion cannot mutate pending target");
        reset();
        activityReason = @"installing";
        check(![LCCompanionBridge openApp:@"builtinSideInstaller" URL:nil] && restartCount == 0, @"active signing task protected");
        activityReason = nil;
        refreshReason = @"background refresh";
        check(![LCCompanionBridge openApp:@"ui" URL:nil], @"background SideStore refresh protected");
        reset();
        bridgeReady = NO;
        check(![LCCompanionBridge openApp:@"ui" URL:nil], @"missing activity bridge fails closed");
        reset();
        liveProcess = YES;
        check(![LCCompanionBridge openApp:@"ui" URL:nil] && restartCount == 0, @"LiveProcess cannot terminate host");
        reset();
        showingSheet = YES;
        check(![LCCompanionBridge openApp:@"ui" URL:nil], @"editing sheet protected");

        reset();
        FakeApplication.sharedApplication.applicationState = 2;
        check(![LCCompanionBridge openApp:@"ui" URL:nil], @"background switch refused");
        check([LCCompanionBridge handleCompanionURL:[NSURL URLWithString:@"sideinstaller://pairingFile?value=test"]] && restartCount == 0, @"cold callback waits for foreground");
        FakeApplication.sharedApplication.applicationState = UIApplicationStateActive;
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
        check(restartCount == 1 && [values[@"selected"] isEqual:@"builtinSideInstaller"], @"foreground callback switches once");
        NSLog(@"Companion switching behavior passed");
    }
    return 0;
}
