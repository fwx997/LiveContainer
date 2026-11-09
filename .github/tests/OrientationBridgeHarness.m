#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

// CoreGraphics can load QuartzCore on macOS; keep the test double's runtime
// class distinct from the real CALayer while production calls remain verbatim.
#define CALayer LCOrientationTestLayer

// UIKit and animations are test dependencies. The host policy and window
// lifecycle methods below are extracted verbatim from the production sources.
typedef NS_ENUM(NSInteger, UIInterfaceOrientation) {
    UIInterfaceOrientationUnknown = 0,
    UIInterfaceOrientationPortrait = 1,
    UIInterfaceOrientationPortraitUpsideDown = 2,
    UIInterfaceOrientationLandscapeLeft = 3,
    UIInterfaceOrientationLandscapeRight = 4,
};
typedef NS_OPTIONS(NSUInteger, UIInterfaceOrientationMask) {
    UIInterfaceOrientationMaskPortrait = 1UL << UIInterfaceOrientationPortrait,
    UIInterfaceOrientationMaskPortraitUpsideDown = 1UL << UIInterfaceOrientationPortraitUpsideDown,
    UIInterfaceOrientationMaskLandscapeLeft = 1UL << UIInterfaceOrientationLandscapeLeft,
    UIInterfaceOrientationMaskLandscapeRight = 1UL << UIInterfaceOrientationLandscapeRight,
    UIInterfaceOrientationMaskLandscape = UIInterfaceOrientationMaskLandscapeLeft | UIInterfaceOrientationMaskLandscapeRight,
    UIInterfaceOrientationMaskAllButUpsideDown = UIInterfaceOrientationMaskPortrait | UIInterfaceOrientationMaskLandscape,
    UIInterfaceOrientationMaskAll = UIInterfaceOrientationMaskAllButUpsideDown | UIInterfaceOrientationMaskPortraitUpsideDown,
};
enum { UIUserInterfaceIdiomPhone, UIUserInterfaceIdiomPad };
enum { UISceneActivationStateForegroundActive, UISceneActivationStateForegroundInactive, UISceneActivationStateBackground };
enum { UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground };
enum { UIViewAnimationOptionCurveEaseInOut, UIViewAnimationOptionTransitionCurlUp };
enum { UIViewAutoresizingFlexibleWidth = 1, UIViewAutoresizingFlexibleHeight = 2 };
enum { NSLineBreakByWordWrapping, NSTextAlignmentCenter, UIImageSymbolWeightMedium };
static BOOL UIInterfaceOrientationIsLandscape(UIInterfaceOrientation orientation) { return orientation == 3 || orientation == 4; }
typedef double CFTimeInterval;
static CFTimeInterval fixtureClock;
static CFTimeInterval CACurrentMediaTime(void) { return fixtureClock; }
static NSMutableArray *scheduledChecks;
static void scheduleCheck(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    if (!scheduledChecks) scheduledChecks = [NSMutableArray new];
    [scheduledChecks addObject:[block copy]];
}
#define dispatch_after scheduleCheck
// INSERT_REPLY_HELPERS
@class DecoratedAppSceneViewController;
// INSERT_TRANSACTION
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
static CGRect UIEdgeInsetsInsetRect(CGRect rect, UIEdgeInsets insets) {
    return CGRectMake(rect.origin.x + insets.left, rect.origin.y + insets.top,
                      rect.size.width - insets.left - insets.right,
                      rect.size.height - insets.top - insets.bottom);
}

static void require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"%@", message); exit(1); }
}

// Tests explicitly choose when recorded UIKit failure callbacks arrive. Running
// the main-queue work immediately keeps those arrival orders deterministic.
static void runMainQueueWork(dispatch_queue_t queue, dispatch_block_t block) { block(); }
#define dispatch_async runMainQueueWork

@interface UIDevice : NSObject
@property NSInteger userInterfaceIdiom;
+ (instancetype)currentDevice;
@end
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *device; if (!device) device = [self new]; return device; }
@end

@interface UIApplication : NSObject
@property NSInteger applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication *app; if (!app) app = [self new]; return app; }
@end

@interface UIWindowSceneGeometryPreferencesIOS : NSObject
@property UIInterfaceOrientationMask interfaceOrientations;
- (instancetype)initWithInterfaceOrientations:(UIInterfaceOrientationMask)orientations;
@end
@implementation UIWindowSceneGeometryPreferencesIOS
- (instancetype)initWithInterfaceOrientations:(UIInterfaceOrientationMask)orientations {
    self = [super init];
    _interfaceOrientations = orientations;
    return self;
}
@end

@interface UIWindowScene : NSObject
@property NSInteger activationState;
@property UIInterfaceOrientation interfaceOrientation;
@property NSMutableArray<NSNumber *> *requests;
@property NSMutableArray *failures;
@property BOOL holdGeometry;
- (void)requestGeometryUpdateWithPreferences:(UIWindowSceneGeometryPreferencesIOS *)preferences errorHandler:(void (^)(NSError *))handler;
- (void)failRequest:(NSUInteger)index;
@end
@implementation UIWindowScene
- (instancetype)init {
    self = [super init];
    _interfaceOrientation = UIInterfaceOrientationPortrait;
    _requests = [NSMutableArray new];
    _failures = [NSMutableArray new];
    return self;
}
- (void)requestGeometryUpdateWithPreferences:(UIWindowSceneGeometryPreferencesIOS *)preferences errorHandler:(void (^)(NSError *))handler {
    [self.requests addObject:@(preferences.interfaceOrientations)];
    [self.failures addObject:[handler copy]];
    if (self.holdGeometry) return;
    if (preferences.interfaceOrientations & (1UL << self.interfaceOrientation)) return;
    for (NSInteger orientation = 1; orientation <= 4; ++orientation) {
        if (!(preferences.interfaceOrientations & (1UL << orientation))) continue;
        self.interfaceOrientation = orientation;
        break;
    }
}
- (void)failRequest:(NSUInteger)index {
    void (^failure)(NSError *) = self.failures[index];
    failure([NSError errorWithDomain:@"TestGeometry" code:1 userInfo:nil]);
}
@end

@interface CALayer : NSObject
@property CGFloat borderWidth;
@property BOOL masksToBounds;
@end
@implementation CALayer
@end

@class UIWindow;
@interface UIView : NSObject
@property CGRect frame, bounds;
@property CGAffineTransform transform;
@property UIEdgeInsets safeAreaInsets;
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, weak) UIView *superview;
@property(nonatomic, weak) id controller;
@property(nonatomic) NSMutableArray<UIView *> *subviews;
@property CALayer *layer;
@property BOOL hidden, needsLayout;
@property CGFloat alpha;
@property NSUInteger autoresizingMask;
- (instancetype)initWithFrame:(CGRect)frame;
- (id)_viewDelegate;
- (void)addSubview:(UIView *)view;
- (void)insertSubview:(UIView *)view atIndex:(NSUInteger)index;
- (void)bringSubviewToFront:(UIView *)view;
- (void)sendSubviewToBack:(UIView *)view;
- (void)didAddSubview:(UIView *)view;
- (void)willRemoveSubview:(UIView *)view;
- (void)removeFromSuperview;
- (void)layoutSubviews;
- (void)layoutIfNeeded;
- (void)setNeedsLayout;
+ (void)animateWithDuration:(double)duration delay:(double)delay options:(NSUInteger)options animations:(void (^)(void))animations completion:(void (^)(BOOL))completion;
+ (void)transitionWithView:(UIView *)view duration:(double)duration options:(NSUInteger)options animations:(void (^)(void))animations completion:(void (^)(BOOL))completion;
+ (void)performWithoutAnimation:(void (^)(void))actions;
@end
@implementation UIView
- (instancetype)init {
    self = [super init];
    _alpha = 1;
    _transform = CGAffineTransformIdentity;
    _subviews = [NSMutableArray new];
    _layer = [CALayer new];
    return self;
}
- (instancetype)initWithFrame:(CGRect)frame { self = [self init]; self.frame = self.bounds = frame; return self; }
- (UIWindow *)window { return _window ?: self.superview.window; }
- (id)_viewDelegate { return self.controller; }
- (void)addSubview:(UIView *)view { [self insertSubview:view atIndex:self.subviews.count]; }
- (void)insertSubview:(UIView *)view atIndex:(NSUInteger)index {
    [view removeFromSuperview];
    view.superview = self;
    [self.subviews insertObject:view atIndex:index];
    [self didAddSubview:view];
}
- (void)bringSubviewToFront:(UIView *)view {
    if (view.superview != self) return;
    [self.subviews removeObject:view];
    [self.subviews addObject:view];
}
- (void)sendSubviewToBack:(UIView *)view {
    if (view.superview != self) return;
    [self.subviews removeObject:view];
    [self.subviews insertObject:view atIndex:0];
}
- (void)didAddSubview:(UIView *)view {}
- (void)willRemoveSubview:(UIView *)view {}
- (void)removeFromSuperview {
    [self.superview willRemoveSubview:self];
    [self.superview.subviews removeObject:self];
    self.superview = nil;
}
- (void)layoutSubviews {}
- (void)layoutIfNeeded {}
- (void)setNeedsLayout { self.needsLayout = YES; }
+ (void)performWithoutAnimation:(void (^)(void))actions { actions(); }
+ (void)animateWithDuration:(double)duration delay:(double)delay options:(NSUInteger)options animations:(void (^)(void))animations completion:(void (^)(BOOL))completion {
    animations();
    if (completion) completion(YES);
}
+ (void)transitionWithView:(UIView *)view duration:(double)duration options:(NSUInteger)options animations:(void (^)(void))animations completion:(void (^)(BOOL))completion {
    animations();
    if (completion) completion(YES);
}
@end

@interface UIViewController : NSObject
@property UIView *view;
@property UIViewController *presentedViewController;
@property NSUInteger orientationUpdates;
@property(readonly) UIView *viewIfLoaded;
- (void)setNeedsUpdateOfSupportedInterfaceOrientations;
@end
@implementation UIViewController
- (UIView *)viewIfLoaded { return self.view; }
- (void)setNeedsUpdateOfSupportedInterfaceOrientations { ++self.orientationUpdates; }
@end

@interface UIWindow : UIView
@property UIWindowScene *windowScene;
@property UIViewController *rootViewController;
@property BOOL isKeyWindow;
@end
@implementation UIWindow
@end

@interface UIImageConfiguration : NSObject
@end
@implementation UIImageConfiguration
@end
@interface UIImageSymbolConfiguration : UIImageConfiguration
+ (instancetype)configurationWithPointSize:(CGFloat)size weight:(NSInteger)weight;
@end
@implementation UIImageSymbolConfiguration
+ (instancetype)configurationWithPointSize:(CGFloat)size weight:(NSInteger)weight { return [self new]; }
@end
@interface UIImage : NSObject
+ (instancetype)systemImageNamed:(NSString *)name;
- (UIImage *)imageWithConfiguration:(UIImageConfiguration *)configuration;
@end
@implementation UIImage
+ (instancetype)systemImageNamed:(NSString *)name { return [self new]; }
- (UIImage *)imageWithConfiguration:(UIImageConfiguration *)configuration { return self; }
@end
@interface UIBarButtonItem : NSObject
@property UIImage *image;
@end
@implementation UIBarButtonItem
@end
@interface UILabel : UIView
@property NSString *text;
@property NSInteger lineBreakMode, numberOfLines, textAlignment;
@end
@implementation UILabel
@end

@interface NSUserDefaults (OrientationTests)
+ (instancetype)lcSharedDefaults;
@end
@implementation NSUserDefaults (OrientationTests)
+ (instancetype)lcSharedDefaults { return NSUserDefaults.standardUserDefaults; }
@end

@interface UIMutableApplicationSceneSettings : NSObject
@end
@implementation UIMutableApplicationSceneSettings
@end
@interface AppSceneViewController : NSObject
@property BOOL isAppRunning, shouldIgnoreSceneUpdates, terminationRequested;
@property NSString *bundleId;
@property UIView *view, *contentView;
- (void)terminate;
- (void)updateSettingsWithBlock:(void (^)(UIMutableApplicationSceneSettings *))block;
@end
@implementation AppSceneViewController
- (void)terminate { self.terminationRequested = YES; }
- (void)updateSettingsWithBlock:(void (^)(UIMutableApplicationSceneSettings *))block { if (block) block([UIMutableApplicationSceneSettings new]); }
@end

@interface MultitaskDockManager : NSObject
+ (instancetype)shared;
- (void)removeRunningApp:(NSString *)identifier;
@end
@implementation MultitaskDockManager
+ (instancetype)shared { static MultitaskDockManager *dock; if (!dock) dock = [self new]; return dock; }
- (void)removeRunningApp:(NSString *)identifier {}
@end
@interface MultitaskRelaunchManager : NSObject
+ (void)scheduleRelaunchIfNeededWithBundleId:(NSString *)bundleId dataUUID:(NSString *)dataUUID isManualTermination:(BOOL)manual;
@end
@implementation MultitaskRelaunchManager
+ (void)scheduleRelaunchIfNeededWithBundleId:(NSString *)bundleId dataUUID:(NSString *)dataUUID isManualTermination:(BOOL)manual {}
@end

@interface DecoratedAppSceneViewController : UIViewController
@property AppSceneViewController *appSceneVC;
@property BOOL isMaximized, hasAppTerminated, isAppTerminationRequested;
@property NSString *dataUUID;
@property CGRect originalFrame;
@property UIView *resizeHandle;
@property UIBarButtonItem *maximizeButton;
- (void)releaseHostOrientation;
- (void)appSceneVC:(AppSceneViewController *)vc didRequestInterfaceOrientations:(UIInterfaceOrientationMask)orientations;
- (void)appSceneVC:(AppSceneViewController *)vc didRequestInterfaceOrientations:(UIInterfaceOrientationMask)orientations fullscreen:(BOOL)fullscreen reply:(void (^)(NSDictionary *))reply;
- (void)appSceneVCOrientationConnectionDidInvalidate:(AppSceneViewController *)vc;
- (void)closeWindow;
- (void)minimizeWindow;
- (void)minimizeWindowPiP;
- (void)maximizeWindow;
- (void)appSceneVCAppDidExit:(AppSceneViewController *)vc;
- (void)updateOriginalFrame;
- (void)updateVerticalConstraints;
- (void)updateMaximizedFrame;
- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings;
- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings;
@end

@interface VirtualWindowsHostView : UIView
@property(nonatomic, weak) DecoratedAppSceneViewController *orientationOwner;
@property(nonatomic, weak) DecoratedAppSceneViewController *fullscreenMaximizedController;
@property UIInterfaceOrientationMask requestedOrientations, restorationOrientations;
@property NSUInteger orientationGeneration;
+ (UIInterfaceOrientationMask)defaultInterfaceOrientations;
+ (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindow:(UIWindow *)window;
- (DecoratedAppSceneViewController *)frontmostController;
- (BOOL)isOrientationOwnerEligible:(DecoratedAppSceneViewController *)controller;
- (BOOL)canControlOrientation:(DecoratedAppSceneViewController *)controller;
- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations forController:(DecoratedAppSceneViewController *)controller;
- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations forController:(DecoratedAppSceneViewController *)controller fullscreen:(BOOL)fullscreen reply:(void (^)(NSDictionary *))reply;
- (NSString *)fullscreenRejectionForController:(DecoratedAppSceneViewController *)controller;
- (NSDictionary *)orientationStateForController:(DecoratedAppSceneViewController *)controller accepted:(BOOL)accepted applied:(BOOL)applied reason:(NSString *)reason;
- (void)finishOrientationTransaction:(LCOrientationTransaction *)request applied:(BOOL)applied reason:(NSString *)reason;
- (void)failOrientationTransaction:(LCOrientationTransaction *)request reason:(NSString *)reason;
- (void)checkOrientationTransaction:(LCOrientationTransaction *)request;
- (void)releaseOrientationForController:(DecoratedAppSceneViewController *)controller;
- (void)restoreHostOrientationIfNeeded;
- (void)validateOrientationOwner;
- (void)hostSceneDidActivate:(NSNotification *)notification;
@end
@implementation VirtualWindowsHostView
// INSERT_PRODUCTION_HOST_METHODS
@end

@implementation DecoratedAppSceneViewController
// INSERT_PRODUCTION_DECORATED_METHODS
- (void)updateOriginalFrame {}
- (void)updateVerticalConstraints {}
- (void)updateMaximizedFrame {}
- (void)updateWindowedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {}
- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings {}
@end

@interface Fixture : NSObject
@property UIWindow *window;
@property VirtualWindowsHostView *host;
@property DecoratedAppSceneViewController *guest;
@property NSMutableArray *retainedObjects;
@end
@implementation Fixture
@end

static DecoratedAppSceneViewController *addGuest(Fixture *fixture, NSString *identifier) {
    DecoratedAppSceneViewController *controller = [DecoratedAppSceneViewController new];
    controller.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    controller.view.controller = controller;
    controller.dataUUID = identifier;
    controller.isMaximized = YES;
    controller.appSceneVC = [AppSceneViewController new];
    controller.appSceneVC.view = controller.view;
    controller.appSceneVC.contentView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 390, 788)];
    controller.appSceneVC.isAppRunning = YES;
    controller.resizeHandle = [UIView new];
    controller.maximizeButton = [UIBarButtonItem new];
    controller.originalFrame = CGRectMake(0, 0, 320, 480);
    [fixture.retainedObjects addObject:controller];
    [fixture.host addSubview:controller.view];
    return controller;
}

static Fixture *fixture(void) {
    fixtureClock = 0;
    scheduledChecks = [NSMutableArray new];
    UIDevice.currentDevice.userInterfaceIdiom = UIUserInterfaceIdiomPhone;
    UIApplication.sharedApplication.applicationState = UIApplicationStateActive;
    [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCSkipTerminatedScreen"];
    Fixture *fixture = [Fixture new];
    fixture.retainedObjects = [NSMutableArray new];
    fixture.window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, 390, 844)];
    fixture.window.window = fixture.window;
    fixture.window.isKeyWindow = YES;
    fixture.window.windowScene = [UIWindowScene new];
    fixture.window.rootViewController = [UIViewController new];
    fixture.window.rootViewController.view = [UIView new];
    fixture.window.rootViewController.view.window = fixture.window;
    fixture.host = [VirtualWindowsHostView new];
    [fixture.window.rootViewController.view addSubview:fixture.host];
    fixture.guest = addGuest(fixture, @"A");
    return fixture;
}

static void request(Fixture *fixture, UIInterfaceOrientationMask mask) {
    [fixture.guest appSceneVC:fixture.guest.appSceneVC didRequestInterfaceOrientations:mask];
}
static void acceptLandscape(Fixture *fixture) {
    request(fixture, UIInterfaceOrientationMaskLandscape);
    require(fixture.host.orientationOwner == fixture.guest, @"Foreground maximized guest did not become orientation owner");
    require(fixture.window.windowScene.requests.lastObject.unsignedIntegerValue == UIInterfaceOrientationMaskLandscape, @"Host did not receive the guest landscape mask");
}
static void requireReleased(Fixture *fixture) {
    require(!fixture.host.orientationOwner && !fixture.host.requestedOrientations, @"Window lifecycle left an orientation owner behind");
    require(fixture.window.windowScene.requests.lastObject.unsignedIntegerValue == UIInterfaceOrientationMaskPortrait, @"Window lifecycle did not restore the original portrait orientation");
    require([VirtualWindowsHostView supportedInterfaceOrientationsForWindow:fixture.window] == UIInterfaceOrientationMaskAllButUpsideDown, @"Released phone host did not restore its normal supported directions");
}
static void setBackground(Fixture *fixture, BOOL background) {
    fixture.window.windowScene.activationState = background ? UISceneActivationStateBackground : UISceneActivationStateForegroundActive;
    UIApplication.sharedApplication.applicationState = background ? UIApplicationStateBackground : UIApplicationStateActive;
}
static void activate(Fixture *fixture, UIWindowScene *scene) {
    [fixture.host hostSceneDidActivate:[NSNotification notificationWithName:@"active" object:scene]];
}

static void directions(void) {
    Fixture *f = fixture();
    acceptLandscape(f);
    require([VirtualWindowsHostView supportedInterfaceOrientationsForWindow:f.window] == UIInterfaceOrientationMaskLandscape, @"App delegate policy failed to keep the accepted landscape constraint");
    request(f, UIInterfaceOrientationMaskPortrait);
    require(f.window.windowScene.interfaceOrientation == UIInterfaceOrientationPortrait, @"Explicit portrait request was lost");
    require(f.host.restorationOrientations == UIInterfaceOrientationMaskPortrait, @"Repeated requests replaced the original host orientation");
    request(f, UIInterfaceOrientationMaskAll);
    require(f.host.requestedOrientations == UIInterfaceOrientationMaskAllButUpsideDown, @"iPhone accepted unsupported upside-down orientation");
    [f.guest releaseHostOrientation];
    requireReleased(f);
}

static void ipad(void) {
    Fixture *f = fixture();
    UIDevice.currentDevice.userInterfaceIdiom = UIUserInterfaceIdiomPad;
    require([VirtualWindowsHostView supportedInterfaceOrientationsForWindow:f.window] == UIInterfaceOrientationMaskAll, @"Idle iPad lost upside-down support");
    request(f, UIInterfaceOrientationMaskPortraitUpsideDown);
    require(f.host.requestedOrientations == UIInterfaceOrientationMaskPortraitUpsideDown, @"iPad upside-down request was discarded");
    [f.guest releaseHostOrientation];
    require([VirtualWindowsHostView supportedInterfaceOrientationsForWindow:f.window] == UIInterfaceOrientationMaskAll, @"Released iPad retained a guest restriction");
}

static void invalidMasks(void) {
    Fixture *f = fixture();
    for (NSNumber *mask in @[@0, @1, @(1UL << 9), @(UIInterfaceOrientationMaskPortrait | (1UL << 9)), @(UIInterfaceOrientationMaskPortraitUpsideDown)]) {
        request(f, mask.unsignedIntegerValue);
    }
    require(!f.host.orientationOwner && !f.window.windowScene.requests.count, @"Invalid or unsupported orientation masks rotated the phone");
}

static void rejected(NSString *reason) {
    Fixture *f = fixture();
    DecoratedAppSceneViewController *cover;
    UIView *otherParent;
    UIWindow *otherWindow;
    if ([reason isEqual:@"background"]) setBackground(f, YES);
    else if ([reason isEqual:@"inactive-scene"]) f.window.windowScene.activationState = UISceneActivationStateForegroundInactive;
    else if ([reason isEqual:@"inactive-app"]) UIApplication.sharedApplication.applicationState = UIApplicationStateInactive;
    else if ([reason isEqual:@"floating"]) f.guest.isMaximized = NO;
    else if ([reason isEqual:@"hidden"]) f.guest.view.hidden = YES;
    else if ([reason isEqual:@"transparent"]) f.guest.view.alpha = 0;
    else if ([reason isEqual:@"host-hidden"]) f.host.hidden = YES;
    else if ([reason isEqual:@"host-transparent"]) f.host.alpha = 0;
    else if ([reason isEqual:@"detached-host"]) [f.host removeFromSuperview];
    else if ([reason isEqual:@"terminated"]) f.guest.appSceneVC.isAppRunning = NO;
    else if ([reason isEqual:@"pip"]) f.guest.appSceneVC.shouldIgnoreSceneUpdates = YES;
    else if ([reason isEqual:@"covered"]) cover = addGuest(f, @"B");
    else if ([reason isEqual:@"modal"]) f.window.rootViewController.presentedViewController = [UIViewController new];
    else if ([reason isEqual:@"non-key-window"]) f.window.isKeyWindow = NO;
    else if ([reason isEqual:@"detached"]) { otherParent = [UIView new]; [f.retainedObjects addObject:otherParent]; f.guest.view.superview = otherParent; }
    else if ([reason isEqual:@"other-window"]) { otherWindow = [UIWindow new]; [f.retainedObjects addObject:otherWindow]; f.guest.view.window = otherWindow; }
    else require(NO, @"Unknown rejection scenario");
    request(f, UIInterfaceOrientationMaskLandscape);
    require(!f.host.orientationOwner && !f.window.windowScene.requests.count, [@"Ineligible request was accepted: " stringByAppendingString:reason]);
    (void)cover; (void)otherParent; (void)otherWindow;
}

static void hiddenCover(void) {
    Fixture *f = fixture();
    DecoratedAppSceneViewController *cover = addGuest(f, @"B");
    cover.view.hidden = YES;
    acceptLandscape(f);
    cover.view.hidden = NO;
    cover.view.alpha = 0.001;
    require([f.host frontmostController] == f.guest, @"An invisible window blocked the visible guest");
}

static void ownership(void) {
    Fixture *f = fixture();
    acceptLandscape(f);
    DecoratedAppSceneViewController *second = addGuest(f, @"B");
    requireReleased(f);
    [second appSceneVC:second.appSceneVC didRequestInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight];
    NSUInteger requests = f.window.windowScene.requests.count;
    [f.window.windowScene failRequest:0];
    [f.guest releaseHostOrientation];
    require(f.host.orientationOwner == second && f.host.requestedOrientations == UIInterfaceOrientationMaskLandscapeRight, @"A stale failure or release from A cleared B's orientation");
    require(f.window.windowScene.requests.count == requests, @"A stale callback issued a restoration over B");
    [second releaseHostOrientation];
    requireReleased(f);
}

static void failure(void) {
    Fixture *f = fixture();
    acceptLandscape(f);
    [f.window.windowScene failRequest:0];
    require(!f.host.orientationOwner && !f.host.requestedOrientations, @"Rejected rotation left the host permanently constrained");
    require([VirtualWindowsHostView supportedInterfaceOrientationsForWindow:f.window] == UIInterfaceOrientationMaskAllButUpsideDown, @"Failed geometry kept a guest-supported mask");
    request(f, UIInterfaceOrientationMaskPortrait);
    require(f.host.orientationOwner == f.guest, @"A failed geometry request blocked future explicit requests");
}

static void stackChange(NSString *operation) {
    Fixture *f = fixture();
    DecoratedAppSceneViewController *second = addGuest(f, @"B");
    second.view.hidden = YES;
    acceptLandscape(f);
    if ([operation isEqual:@"front"]) { second.view.hidden = NO; [f.host bringSubviewToFront:second.view]; }
    else if ([operation isEqual:@"back"]) { second.view.hidden = NO; [f.host sendSubviewToBack:f.guest.view]; }
    else if ([operation isEqual:@"remove"]) [f.guest.view removeFromSuperview];
    else if ([operation isEqual:@"layout"]) { f.guest.isMaximized = NO; [f.host layoutSubviews]; }
    else require(NO, @"Unknown stack scenario");
    requireReleased(f);
}

static void lifecycle(NSString *operation) {
    Fixture *f = fixture();
    acceptLandscape(f);
    if ([operation isEqual:@"restore"]) { [f.guest maximizeWindow]; require(!f.guest.isMaximized, @"Restore button did not leave maximized mode"); }
    else if ([operation isEqual:@"minimize"]) [f.guest minimizeWindow];
    else if ([operation isEqual:@"pip"]) [f.guest minimizeWindowPiP];
    else if ([operation isEqual:@"close"]) { [f.guest closeWindow]; require(f.guest.appSceneVC.terminationRequested, @"Close no longer terminates the guest"); }
    else if ([operation isEqual:@"exit"]) { f.guest.appSceneVC.isAppRunning = NO; [f.guest appSceneVCAppDidExit:f.guest.appSceneVC]; }
    else if ([operation isEqual:@"disconnect"]) [f.guest appSceneVCOrientationConnectionDidInvalidate:f.guest.appSceneVC];
    else require(NO, @"Unknown window lifecycle scenario");
    requireReleased(f);
}

static void backgroundOwner(void) {
    Fixture *f = fixture();
    acceptLandscape(f);
    setBackground(f, YES);
    [f.host layoutSubviews];
    request(f, UIInterfaceOrientationMaskPortrait);
    require(f.host.orientationOwner == f.guest && f.host.requestedOrientations == UIInterfaceOrientationMaskLandscape, @"Normal backgrounding revoked an already accepted fullscreen direction");
    require(f.window.windowScene.requests.count == 1, @"A new background request rotated the host");
    setBackground(f, NO);
    activate(f, f.window.windowScene);
    require(f.host.orientationOwner == f.guest && f.window.windowScene.requests.count == 1, @"Returning to a still-fullscreen guest unexpectedly restored portrait");
}

static void backgroundExit(void) {
    Fixture *f = fixture();
    acceptLandscape(f);
    setBackground(f, YES);
    f.guest.appSceneVC.isAppRunning = NO;
    [f.guest appSceneVCAppDidExit:f.guest.appSceneVC];
    require(!f.host.orientationOwner && f.host.restorationOrientations == UIInterfaceOrientationMaskPortrait, @"Background termination lost the pending original direction");
    require(f.window.windowScene.requests.count == 1, @"Background termination tried to rotate an inactive host scene");
    setBackground(f, NO);
    activate(f, [UIWindowScene new]);
    require(f.window.windowScene.requests.count == 1, @"Another scene's activation restored this window");
    activate(f, f.window.windowScene);
    requireReleased(f);
    activate(f, f.window.windowScene);
    require(f.window.windowScene.requests.count == 2, @"Repeated activation replayed a consumed restoration");
}

static void deferredOwner(void) {
    Fixture *f = fixture();
    acceptLandscape(f);
    setBackground(f, YES);
    [f.guest releaseHostOrientation];
    DecoratedAppSceneViewController *second = addGuest(f, @"B");
    setBackground(f, NO);
    [second appSceneVC:second.appSceneVC didRequestInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight];
    activate(f, f.window.windowScene);
    require(f.host.orientationOwner == second && f.window.windowScene.requests.count == 2, @"A pending restoration overrode the new foreground owner");
    [second releaseHostOrientation];
    requireReleased(f);
}

static void guestRouting(void) {
    Fixture *f = fixture();
    AppSceneViewController *stranger = [AppSceneViewController new];
    [f.guest appSceneVC:stranger didRequestInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
    require(!f.host.orientationOwner, @"A callback for another guest reached this window");
    acceptLandscape(f);
    [f.guest appSceneVCOrientationConnectionDidInvalidate:stranger];
    require(f.host.orientationOwner == f.guest, @"Another guest's disconnected connection released this owner");
}

static void flushChecks(void) {
    NSArray *checks = scheduledChecks.copy;
    [scheduledChecks removeAllObjects];
    for (dispatch_block_t check in checks) check();
}

static void setGeometry(Fixture *f, BOOL landscape) {
    f.window.bounds = CGRectMake(0, 0, landscape ? 844 : 390, landscape ? 390 : 844);
    f.guest.appSceneVC.contentView.bounds = CGRectMake(0, 0, landscape ? 844 : 390, landscape ? 334 : 788);
    f.window.windowScene.interfaceOrientation = landscape ? UIInterfaceOrientationLandscapeLeft : UIInterfaceOrientationPortrait;
}

static void explicitScenario(NSString *scenario) {
    Fixture *f = fixture();
    __block NSDictionary *result;
    __block NSUInteger replies = 0;
    LCOrientationReply reply = ^(NSDictionary *state) { result = state; ++replies; };
    if ([scenario isEqual:@"v2-once"]) {
        LCOrientationReply finish = LCOrientationReplyOnce(reply);
        finish(@{@"first": @YES}); finish(@{@"first": @NO});
        require(replies == 1 && [result[@"first"] boolValue], @"Reply was completed more than once");
        return;
    }
    if ([scenario isEqual:@"v2-denials"]) {
        setBackground(f, YES);
        [f.host requestInterfaceOrientations:UIInterfaceOrientationMaskLandscape forController:f.guest fullscreen:YES reply:reply];
        require([result[@"reason"] isEqual:@"host_inactive"] && ![result[@"accepted"] boolValue], @"Explicit background request was not denied");
        setBackground(f, NO);
        f.window.rootViewController.presentedViewController = [UIViewController new];
        [f.host requestInterfaceOrientations:UIInterfaceOrientationMaskLandscape forController:f.guest fullscreen:YES reply:reply];
        require([result[@"reason"] isEqual:@"host_modal"] && !f.window.windowScene.requests.count, @"Modal did not block explicit rotation");
        return;
    }
    if ([scenario isEqual:@"v2-non-key"]) f.window.isKeyWindow = NO;
    if ([scenario isEqual:@"v2-floating"]) f.guest.isMaximized = NO;
    if ([scenario isEqual:@"v2-restore-landscape"]) {
        setGeometry(f, YES);
        [f.guest appSceneVC:f.guest.appSceneVC didRequestInterfaceOrientations:UIInterfaceOrientationMaskLandscape fullscreen:YES reply:reply];
        require([result[@"applied"] boolValue], @"Already-landscape entry failed");
        [f.host requestInterfaceOrientations:UIInterfaceOrientationMaskPortrait forController:f.guest fullscreen:NO reply:reply];
        require(replies == 2 && [result[@"applied"] boolValue] && !f.host.orientationOwner, @"Exit did not restore original landscape");
        require(f.window.windowScene.requests.lastObject.unsignedIntegerValue == UIInterfaceOrientationMaskLandscapeLeft, @"Guest portrait default replaced original host direction");
        return;
    }
    [f.guest appSceneVC:f.guest.appSceneVC didRequestInterfaceOrientations:UIInterfaceOrientationMaskLandscape fullscreen:YES reply:reply];
    require(!result && f.host.orientationOwner == f.guest, @"Request reported success before host and guest geometry changed");
    if ([scenario isEqual:@"v2-timeout"]) {
        fixtureClock = 2.1;
        flushChecks();
        require(replies == 1 && [result[@"reason"] isEqual:@"geometry_timeout"] && !f.host.orientationOwner, @"Timeout left a stuck owner or lied about success");
        [f.window.windowScene failRequest:0];
        require(replies == 1, @"Late geometry error completed timed out request twice");
        return;
    }
    if ([scenario isEqual:@"v2-stale"]) {
        DecoratedAppSceneViewController *other = addGuest(f, @"B");
        [other appSceneVC:other.appSceneVC didRequestInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight];
        flushChecks();
        [f.window.windowScene failRequest:0];
        require([result[@"reason"] isEqual:@"superseded"] && f.host.orientationOwner == other, @"Stale transaction overwrote new owner");
        return;
    }
    setGeometry(f, YES);
    flushChecks();
    require(replies == 1 && [result[@"applied"] boolValue] && f.guest.isMaximized, @"Explicit foreground fullscreen did not apply");
    require([result[@"width"] doubleValue] > [result[@"height"] doubleValue], @"Successful receipt reported portrait geometry");
    if ([scenario isEqual:@"v2-release"] || [scenario isEqual:@"v2-floating"]) {
        result = nil;
        [f.host requestInterfaceOrientations:UIInterfaceOrientationMaskPortrait forController:f.guest fullscreen:NO reply:reply];
        require(!f.host.orientationOwner && !result, @"Exit did not release ownership or replied before portrait geometry");
        setGeometry(f, NO);
        flushChecks();
        require(replies == 2 && [result[@"applied"] boolValue] && !f.host.requestedOrientations, @"Explicit exit did not finish in portrait");
        if ([scenario isEqual:@"v2-floating"]) require(!f.guest.isMaximized, @"Explicit exit lost original floating window mode");
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        require(argc == 2, @"Expected an orientation scenario");
        NSString *scenario = @(argv[1]);
        if ([scenario isEqual:@"directions"]) directions();
        else if ([scenario isEqual:@"ipad"]) ipad();
        else if ([scenario isEqual:@"invalid-masks"]) invalidMasks();
        else if ([scenario hasPrefix:@"reject-"]) rejected([scenario substringFromIndex:7]);
        else if ([scenario isEqual:@"hidden-cover"]) hiddenCover();
        else if ([scenario isEqual:@"ownership"]) ownership();
        else if ([scenario isEqual:@"failure"]) failure();
        else if ([scenario hasPrefix:@"stack-"]) stackChange([scenario substringFromIndex:6]);
        else if ([scenario hasPrefix:@"lifecycle-"]) lifecycle([scenario substringFromIndex:10]);
        else if ([scenario isEqual:@"background-owner"]) backgroundOwner();
        else if ([scenario isEqual:@"background-exit"]) backgroundExit();
        else if ([scenario isEqual:@"deferred-owner"]) deferredOwner();
        else if ([scenario isEqual:@"guest-routing"]) guestRouting();
        else if ([scenario hasPrefix:@"v2-"]) explicitScenario(scenario);
        else require(NO, @"Unknown orientation scenario");
        printf("Orientation scenario passed: %s\n", argv[1]);
    }
    return 0;
}
