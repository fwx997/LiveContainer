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
@property BOOL isPictureInPictureActive;
@property id delegate;
- (void)stopPictureInPicture;
@end
@implementation AVPictureInPictureController
- (void)stopPictureInPicture { self.isPictureInPictureActive = NO; }
@end
@interface PlaybackMediaController : NSObject
@property NSDictionary *playbackState;
@property BOOL started, stopping, invalidated;
- (void)didStart;
- (void)willStop;
- (void)invalidate;
@end
@implementation PlaybackMediaController
- (void)didStart { self.started = YES; }
- (void)willStop { self.stopping = YES; }
- (void)invalidate { self.invalidated = YES; }
@end
@interface PlaybackDecoration : NSObject
@property BOOL minimized, prepared;
- (void)prepareWindowForPictureInPicture;
- (void)minimizeWindowPiP;
- (void)unminimizeWindowPiP;
- (void)updateVerticalConstraints;
- (void)restoreFullscreenAfterPictureInPicture;
@end
@implementation PlaybackDecoration
- (void)prepareWindowForPictureInPicture { self.prepared = YES; }
- (void)minimizeWindowPiP { self.minimized = YES; }
- (void)unminimizeWindowPiP { self.minimized = NO; }
- (void)updateVerticalConstraints {}
- (void)restoreFullscreenAfterPictureInPicture {}
@end

@class LCOrientationRequestReceiver;
@interface AppSceneViewController : NSObject
@property BOOL isAppRunning, usesHostingControllerAPI, shouldIgnoreSceneUpdates, backgroundNotifications;
@property PlaybackView *view, *contentView;
@property LCOrientationRequestReceiver *orientationReceiver;
@property NSDictionary *containerMediaPlayback;
@property NSInteger backgroundEnables, backgroundDisables;
- (void)setContainerPictureInPictureActive:(BOOL)active;
- (void)setContainerMediaPlaybackState:(NSDictionary *)state pictureInPictureActive:(BOOL)active;
- (void)setBackgroundNotificationEnabled:(bool)enabled;
@end
@interface LCOrientationRequestReceiver : NSObject
@property BOOL invalidated, observingPlayback, pictureInPictureActive, hostActive;
@property AppSceneViewController *sceneViewController;
@property PlaybackConnection *connection;
@property NSDictionary *mediaState;
- (void)publishPlaybackState;
@end
@implementation LCOrientationRequestReceiver
// INSERT_RECEIVER
@end
@implementation AppSceneViewController
- (instancetype)init { self = [super init]; _view = [PlaybackView new]; _contentView = [PlaybackView new]; return self; }
- (void)setBackgroundNotificationEnabled:(bool)enabled {
    self.backgroundNotifications = enabled;
    if (enabled) ++self.backgroundEnables;
    else ++self.backgroundDisables;
}
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
@property BOOL containerPiPActive, scenePlaybackProtected;
@property NSUInteger startGeneration;
@property PlaybackMediaController *mediaController;
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
        NSUInteger beforeNil = sink.states.count;
        [pip pictureInPictureControllerDidStopPictureInPicture:nil];
        require(beforeNil == sink.states.count, @"nil PiP callback cannot revoke a live session");
        PlaybackMediaController *media = [PlaybackMediaController new];
        media.playbackState = @{@"mediaSession": @"video", @"mediaLease": @"lease-2", @"mediaActive": @YES,
                                @"mediaReady": @YES, @"mediaPlaying": @NO, @"mediaPosition": @120000};
        scene.containerMediaPlayback = @{@"session": @"video", @"available": @YES};
        pip.mediaController = media;
        pip.pipController = [AVPictureInPictureController new];
        pip.displayingVC = scene;
        [scene setContainerMediaPlaybackState:media.playbackState pictureInPictureActive:NO];
        NSInteger enableCount = scene.backgroundEnables;
        [pip pictureInPictureControllerWillStartPictureInPicture:pip.pipController];
        [pip pictureInPictureControllerWillStartPictureInPicture:pip.pipController];
        require(pip.displayingDecoratedVC.prepared && !pip.displayingDecoratedVC.minimized &&
                !scene.shouldIgnoreSceneUpdates && ![sink.states.lastObject[@"active"] boolValue],
                @"media start animation must keep its inline source visible until DidStart");
        [pip pictureInPictureControllerDidStartPictureInPicture:pip.pipController];
        require(pip.containerPiPActive && media.started, @"native PiP is active during native callbacks");
        require(pip.displayingDecoratedVC.minimized && scene.shouldIgnoreSceneUpdates,
                @"successful media PiP hides and protects its guest only after DidStart");
        require(pip.pipVideoCallViewController.view.layer.observers == 0, @"native media does not move the guest view or observe its bounds");
        [pip pictureInPictureControllerWillStopPictureInPicture:pip.pipController];
        require(media.stopping, @"native stop suppresses delayed player controls");
        [pip pictureInPictureControllerDidStopPictureInPicture:pip.pipController];
        require(media.invalidated && pip.mediaController == nil && !pip.containerPiPActive, @"native cleanup releases its controller");
        require(![sink.states.lastObject[@"mediaActive"] boolValue] &&
                ![sink.states.lastObject[@"mediaPlaying"] boolValue] &&
                [sink.states.lastObject[@"mediaLease"] isEqual:@"lease-2"], @"native media cleanup returns the same paused session");
        require(scene.backgroundEnables == enableCount + 1, @"duplicate willStart restores background observers only once");
        pip.displayingVC = scene;
        pip.pipController = [AVPictureInPictureController new];
        pip.mediaController = [PlaybackMediaController new];
        pip.mediaController.playbackState = media.playbackState;
        enableCount = scene.backgroundEnables;
        [pip stopPiP];
        require(pip.mediaController == nil && pip.pipController == nil, @"pending native PiP can be cancelled");
        require(scene.backgroundEnables == enableCount, @"cancel before willStart does not duplicate background observers");
        pip.displayingVC = scene;
        pip.pipController = [AVPictureInPictureController new];
        PlaybackMediaController *failedMedia = [PlaybackMediaController new];
        failedMedia.playbackState = media.playbackState;
        pip.mediaController = failedMedia;
        [scene setContainerMediaPlaybackState:media.playbackState pictureInPictureActive:NO];
        [pip pictureInPictureControllerWillStartPictureInPicture:pip.pipController];
        [pip pictureInPictureController:pip.pipController failedToStartPictureInPictureWithError:
            [NSError errorWithDomain:@"AVKitErrorDomain" code:1 userInfo:nil]];
        require(failedMedia.invalidated && !pip.displayingDecoratedVC.minimized &&
                ![sink.states.lastObject[@"mediaActive"] boolValue] &&
                [sink.states.lastObject[@"mediaError"] isEqual:@"media_system_failed"],
                @"system startup failure must release native media, restore the guest and report an error");
        require(scene.backgroundEnables == enableCount,
                @"failed media start must not restore observers that it never disabled");
        [scene setContainerMediaPlaybackState:media.playbackState pictureInPictureActive:NO];
        scene.containerMediaPlayback = @{@"session": @"replacement", @"available": @YES};
        [receiver publishPlaybackState];
        require(![sink.states.lastObject[@"mediaActive"] boolValue], @"old media session cannot retain the replacement's audio grant");
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
