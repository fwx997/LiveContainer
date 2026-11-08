#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

static void require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"%@", message); exit(1); }
}
static void runMain(dispatch_queue_t queue, dispatch_block_t block) { block(); }
#define dispatch_async runMain
static NSString * const UIApplicationDidBecomeActiveNotification = @"didBecomeActive";

@protocol LCContainerPlaybackGuest
- (void)containerPlaybackStateDidChange:(NSDictionary *)state;
@end

@interface PlaybackSink : NSObject <LCContainerPlaybackGuest>
@property NSMutableArray<NSDictionary *> *states;
@end
@implementation PlaybackSink
- (instancetype)init { self = [super init]; _states = [NSMutableArray new]; return self; }
- (void)containerPlaybackStateDidChange:(NSDictionary *)state { [self.states addObject:state]; }
@end

@interface PlaybackConnection : NSObject
@property id<LCContainerPlaybackGuest> guest;
+ (instancetype)currentConnection;
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *))error;
@end
static PlaybackConnection *currentConnection;
@implementation PlaybackConnection
+ (instancetype)currentConnection { return currentConnection; }
- (id)remoteObjectProxyWithErrorHandler:(void (^)(NSError *))error { return self.guest; }
@end
#define NSXPCConnection PlaybackConnection

@interface PlaybackLayer : NSObject
@property NSInteger observers;
- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)key options:(NSKeyValueObservingOptions)options context:(void *)context;
- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)key;
@end
@implementation PlaybackLayer
- (void)addObserver:(NSObject *)observer forKeyPath:(NSString *)key options:(NSKeyValueObservingOptions)options context:(void *)context { ++self.observers; }
- (void)removeObserver:(NSObject *)observer forKeyPath:(NSString *)key { --self.observers; }
@end
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
@interface PlaybackView : NSObject
@property CGRect frame, bounds;
@property UIEdgeInsets safeAreaInsets;
@property CGAffineTransform transform;
@property PlaybackLayer *layer;
- (void)addSubview:(PlaybackView *)view;
- (void)insertSubview:(PlaybackView *)view atIndex:(NSInteger)index;
@end
@implementation PlaybackView
- (instancetype)init { self = [super init]; _layer = [PlaybackLayer new]; return self; }
- (void)addSubview:(PlaybackView *)view {}
- (void)insertSubview:(PlaybackView *)view atIndex:(NSInteger)index {}
@end
@interface PlaybackContentController : NSObject
@property PlaybackView *view;
@property CGSize preferredContentSize;
@property UIEdgeInsets additionalSafeAreaInsets;
@end
@implementation PlaybackContentController
- (instancetype)init { self = [super init]; _view = [PlaybackView new]; return self; }
@end
@interface AVPictureInPictureController : NSObject
@end
@implementation AVPictureInPictureController
@end
@interface PlaybackDecoration : NSObject
@property BOOL minimized;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)updateVerticalConstraints;
@end
@implementation PlaybackDecoration
- (void)minimizeWindowPiP { self.minimized = YES; }
- (void)unminimizeWindowPiP { self.minimized = NO; }
- (void)updateVerticalConstraints {}
@end

@class LCOrientationRequestReceiver;
@interface AppSceneViewController : NSObject
@property BOOL isAppRunning, usesHostingControllerAPI, shouldIgnoreSceneUpdates, backgroundNotifications;
@property PlaybackView *view, *contentView;
@property LCOrientationRequestReceiver *orientationReceiver;
- (void)setContainerPictureInPictureActive:(BOOL)active;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
@end
@interface LCOrientationRequestReceiver : NSObject
@property BOOL invalidated, observingPlayback, pictureInPictureActive, hostActive;
@property AppSceneViewController *sceneViewController;
@property PlaybackConnection *connection;
- (void)publishPlaybackState;
@end
@implementation LCOrientationRequestReceiver
// INSERT_RECEIVER
@end
@implementation AppSceneViewController
- (instancetype)init { self = [super init]; _view = [PlaybackView new]; _contentView = [PlaybackView new]; return self; }
- (void)setBackgroundNotificationEnabled:(bool)enabled { self.backgroundNotifications = enabled; }
// INSERT_SCENE
@end

@interface NSUserDefaults (PlaybackTestDefaults)
+ (instancetype)lcSharedDefaults;
@end
@implementation NSUserDefaults (PlaybackTestDefaults)
+ (instancetype)lcSharedDefaults { return self.standardUserDefaults; }
@end

@interface PiPManager : NSObject
@property AVPictureInPictureController *pipController;
@property AppSceneViewController *displayingVC;
@property PlaybackDecoration *displayingDecoratedVC;
@property PlaybackView *pipVideoCallContentView;
@property PlaybackContentController *pipVideoCallViewController;
@property BOOL observingBounds;
@end
@implementation PiPManager
// INSERT_PIP
@end

static NSXPCConnection *LCGuestOrientationConnection;
static NSDictionary *lastGuestState;
static void LCSetGuestPlaybackState(NSDictionary *state) { lastGuestState = state; }
@interface LCGuestPlaybackObserver : NSObject
@property NSXPCConnection *connection;
@end
@implementation LCGuestPlaybackObserver
// INSERT_GUEST
@end

int main(void) {
    @autoreleasepool {
        PlaybackSink *sink = [PlaybackSink new];
        PlaybackConnection *connection = [PlaybackConnection new];
        connection.guest = sink;
        currentConnection = connection;
        AppSceneViewController *scene = [AppSceneViewController new];
        LCOrientationRequestReceiver *receiver = [LCOrientationRequestReceiver new];
        scene.isAppRunning = YES;
        scene.orientationReceiver = receiver;
        receiver.sceneViewController = scene;
        receiver.connection = connection;
        receiver.hostActive = YES;
        [receiver observeContainerPlaybackState];
        require([sink.states.lastObject[@"hostActive"] boolValue], @"initial host state");
        require(![sink.states.lastObject[@"active"] boolValue], @"no PiP grant before start");
        PiPManager *pip = [PiPManager new];
        pip.pipController = [AVPictureInPictureController new];
        pip.displayingVC = scene;
        pip.displayingDecoratedVC = [PlaybackDecoration new];
        pip.pipVideoCallContentView = [PlaybackView new];
        pip.pipVideoCallViewController = [PlaybackContentController new];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"LCAutoEndPiP"];
        for (NSNumber *hosting in @[@NO, @YES]) {
            scene.usesHostingControllerAPI = hosting.boolValue;
            [pip pictureInPictureControllerWillStartPictureInPicture:pip.pipController];
            [pip pictureInPictureControllerDidStartPictureInPicture:pip.pipController];
            require([sink.states.lastObject[@"active"] boolValue], @"PiP entered");
            [receiver hostActivityChanged:[NSNotification notificationWithName:@"background" object:nil]];
            require(![sink.states.lastObject[@"hostActive"] boolValue] && [sink.states.lastObject[@"active"] boolValue], @"background PiP retains grant");
            NSUInteger count = sink.states.count;
            [pip pictureInPictureControllerDidStopPictureInPicture:[AVPictureInPictureController new]];
            require(count == sink.states.count, @"stale controller cannot revoke current PiP");
            [pip pictureInPictureControllerWillStopPictureInPicture:pip.pipController];
            require([sink.states.lastObject[@"active"] boolValue], @"stop animation remains protected");
            [pip pictureInPictureControllerDidStopPictureInPicture:pip.pipController];
            require(![sink.states.lastObject[@"active"] boolValue] && ![sink.states.lastObject[@"hostActive"] boolValue], @"background close revokes playback");
            require(!scene.shouldIgnoreSceneUpdates && scene.backgroundNotifications, @"close restores scene policy");
            require(pip.pipVideoCallViewController.view.layer.observers == 0, @"close releases bounds observer");
            [receiver hostActivityChanged:[NSNotification notificationWithName:UIApplicationDidBecomeActiveNotification object:nil]];
            require([sink.states.lastObject[@"hostActive"] boolValue], @"return to host");
            [pip pictureInPictureControllerWillStartPictureInPicture:pip.pipController];
            [pip pictureInPictureController:pip.pipController failedToStartPictureInPictureWithError:[NSError errorWithDomain:@"test" code:1 userInfo:nil]];
            require(![sink.states.lastObject[@"active"] boolValue], @"failed start revokes grant");
            require(!pip.displayingDecoratedVC.minimized && !scene.shouldIgnoreSceneUpdates, @"failed start restores window");
            require(pip.pipVideoCallViewController.view.layer.observers == 0, @"failed start releases observer");
        }
        [scene setContainerPictureInPictureActive:YES];
        scene.isAppRunning = NO;
        [receiver publishPlaybackState];
        require(![sink.states.lastObject[@"active"] boolValue], @"terminated app gets no grant");
        NSUInteger count = sink.states.count;
        receiver.invalidated = YES;
        [receiver publishPlaybackState];
        require(count == sink.states.count, @"invalidated bridge sends nothing");
        receiver.invalidated = NO;
        receiver.observingPlayback = NO;
        currentConnection = [PlaybackConnection new];
        [receiver observeContainerPlaybackState];
        require(!receiver.observingPlayback, @"wrong connection cannot subscribe");
        LCGuestPlaybackObserver *guest = [LCGuestPlaybackObserver new];
        guest.connection = connection;
        LCGuestOrientationConnection = connection;
        [guest containerPlaybackStateDidChange:@{@"version": @1, @"active": @YES}];
        require([lastGuestState[@"active"] boolValue], @"matching guest callback accepted");
        LCGuestOrientationConnection = [PlaybackConnection new];
        [guest containerPlaybackStateDidChange:@{@"version": @1, @"active": @NO}];
        require([lastGuestState[@"active"] boolValue], @"stale guest callback ignored");
        NSLog(@"Container playback production lifecycle checks passed (legacy and hosting paths)");
    }
    return 0;
}
