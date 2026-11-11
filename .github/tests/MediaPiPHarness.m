#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <dispatch/dispatch.h>

static void require(BOOL value, NSString *message) {
    if (!value) { NSLog(@"%@", message); exit(1); }
}
static void runMain(dispatch_queue_t queue, dispatch_block_t block) { block(); }
static NSMutableArray<dispatch_block_t> *deadlines;
static void deferDeadline(dispatch_time_t time, dispatch_queue_t queue, dispatch_block_t block) {
    if (!deadlines) deadlines = [NSMutableArray new];
    [deadlines addObject:[block copy]];
}
static void fireDeadlines(void) {
    NSArray<dispatch_block_t> *pending = [deadlines copy];
    [deadlines removeAllObjects];
    for (dispatch_block_t block in pending) block();
}
#define dispatch_async runMain
#define dispatch_after deferDeadline
static CFTimeInterval clockTime;
static CFTimeInterval CACurrentMediaTime(void) { return clockTime; }

typedef NS_OPTIONS(NSUInteger, AVAudioSessionCategoryOptions) {
    AVAudioSessionCategoryOptionMixWithOthers = 1,
};
static NSString * const AVAudioSessionCategoryPlayback = @"playback";
static NSString * const AVAudioSessionModeDefault = @"default";
@interface AVAudioSession : NSObject
@property AVAudioSessionCategoryOptions options;
@property NSUInteger activations;
@property BOOL rejectActivation;
+ (instancetype)sharedInstance;
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)error;
- (BOOL)setActive:(BOOL)active error:(NSError **)error;
@end
@implementation AVAudioSession
+ (instancetype)sharedInstance {
    static AVAudioSession *session;
    if (!session) session = [AVAudioSession new];
    return session;
}
- (BOOL)setCategory:(NSString *)category mode:(NSString *)mode options:(AVAudioSessionCategoryOptions)options error:(NSError **)error {
    self.options = options;
    return YES;
}
- (BOOL)setActive:(BOOL)active error:(NSError **)error {
    require(self.options == AVAudioSessionCategoryOptionMixWithOthers, @"PiP activates only after configuring mix-with-others");
    if (active) ++self.activations;
    return !self.rejectActivation;
}
@end

@interface AVURLAsset : NSObject
@property NSURL *URL;
@property NSDictionary *options;
+ (instancetype)URLAssetWithURL:(NSURL *)url options:(NSDictionary *)options;
@end
@implementation AVURLAsset
+ (instancetype)URLAssetWithURL:(NSURL *)url options:(NSDictionary *)options {
    AVURLAsset *asset = [AVURLAsset new];
    asset.URL = url;
    asset.options = options;
    return asset;
}
@end
typedef NS_ENUM(NSInteger, AVPlayerItemStatus) {
    AVPlayerItemStatusUnknown, AVPlayerItemStatusReadyToPlay, AVPlayerItemStatusFailed,
};
@interface AVPlayerItem : NSObject
@property AVPlayerItemStatus status;
@property AVURLAsset *asset;
@property BOOL canUseNetworkResourcesForLiveStreamingWhilePaused;
+ (instancetype)playerItemWithAsset:(AVURLAsset *)asset;
@end
@implementation AVPlayerItem
+ (instancetype)playerItemWithAsset:(AVURLAsset *)asset {
    AVPlayerItem *item = [AVPlayerItem new];
    item.asset = asset;
    return item;
}
@end
typedef NS_ENUM(NSInteger, AVPlayerTimeControlStatus) {
    AVPlayerTimeControlStatusPaused, AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate, AVPlayerTimeControlStatusPlaying,
};
@interface AVPlayer : NSObject
@property float rate, volume;
@property BOOL automaticallyWaitsToMinimizeStalling, holdSeek;
@property AVPlayerItem *currentItem;
@property CMTime currentTime, lastSeek;
@property AVPlayerTimeControlStatus timeControlStatus;
@property NSUInteger playCalls, pauseCalls, replacements;
@property(copy) void (^pendingSeek)(BOOL finished);
- (void)play;
- (void)pause;
- (void)prerollAtRate:(float)rate completionHandler:(void (^)(BOOL))completion;
- (void)cancelPendingPrerolls;
- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item;
- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completion;
- (void)completeSeek:(BOOL)finished;
@end
@implementation AVPlayer
- (void)play { ++self.playCalls; self.timeControlStatus = AVPlayerTimeControlStatusPlaying; self.rate = 1; }
- (void)pause { ++self.pauseCalls; self.timeControlStatus = AVPlayerTimeControlStatusPaused; self.rate = 0; }
- (void)prerollAtRate:(float)rate completionHandler:(void (^)(BOOL))completion { completion(YES); }
- (void)cancelPendingPrerolls {}
- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    ++self.replacements;
    self.currentItem = item;
    self.currentTime = kCMTimeZero;
}
- (void)seekToTime:(CMTime)time completionHandler:(void (^)(BOOL))completion {
    self.lastSeek = time;
    if (self.holdSeek) { self.pendingSeek = completion; return; }
    self.currentTime = time;
    completion(YES);
}
- (void)completeSeek:(BOOL)finished {
    void (^completion)(BOOL) = self.pendingSeek;
    self.pendingSeek = nil;
    if (finished) self.currentTime = self.lastSeek;
    if (completion) completion(finished);
}
@end

@interface AVPlayerLayer : NSObject
@property AVPlayer *player;
@property CGRect frame;
@property NSString *videoGravity;
@property CGColorRef backgroundColor;
@property BOOL readyForDisplay, removed;
+ (instancetype)playerLayerWithPlayer:(AVPlayer *)player;
- (void)removeFromSuperlayer;
@end
static NSString * const AVLayerVideoGravityResizeAspect = @"aspect";
@implementation AVPlayerLayer
+ (instancetype)playerLayerWithPlayer:(AVPlayer *)player {
    AVPlayerLayer *layer = [AVPlayerLayer new];
    layer.player = player;
    layer.readyForDisplay = YES;
    return layer;
}
- (void)removeFromSuperlayer { self.removed = YES; }
@end
@interface ViewLayer : NSObject
- (void)addSublayer:(AVPlayerLayer *)layer;
@end
@implementation ViewLayer
- (void)addSublayer:(AVPlayerLayer *)layer {}
@end
@interface UIView : NSObject
@property CGRect bounds;
@property ViewLayer *layer;
@end
@implementation UIView
- (instancetype)init {
    self = [super init];
    _bounds = CGRectMake(0, 0, 640, 360);
    _layer = [ViewLayer new];
    return self;
}
@end
@interface UIColor : NSObject
@property(readonly) CGColorRef CGColor;
+ (instancetype)blackColor;
@end
@implementation UIColor
+ (instancetype)blackColor { return [UIColor new]; }
- (CGColorRef)CGColor { return NULL; }
@end
@protocol AVPictureInPictureControllerDelegate <NSObject>
@end
@interface AVPictureInPictureController : NSObject
@property id<AVPictureInPictureControllerDelegate> delegate;
@property BOOL requiresLinearPlayback, isPictureInPicturePossible;
@property NSUInteger startCalls, stopCalls;
- (instancetype)initWithPlayerLayer:(AVPlayerLayer *)layer;
- (void)startPictureInPicture;
- (void)stopPictureInPicture;
@end
@implementation AVPictureInPictureController
- (instancetype)initWithPlayerLayer:(AVPlayerLayer *)layer {
    self = [super init];
    _isPictureInPicturePossible = YES;
    return self;
}
- (void)startPictureInPicture { ++self.startCalls; }
- (void)stopPictureInPicture { ++self.stopCalls; }
@end

// INSERT_HEADER
// INSERT_IMPLEMENTATION

static NSMutableDictionary *descriptor(NSString *session, NSUInteger revision, BOOL live, BOOL playing, NSUInteger request) {
    return [@{@"version": @1, @"session": session, @"revision": @(revision), @"available": @YES,
              @"url": @"https://example.invalid/live.m3u8", @"headers": @{@"Referer": @"https://example.invalid/"},
              @"playing": @(playing), @"live": @(live), @"position": @120000, @"volume": @0.6,
              @"refreshRequest": @(request), @"handoffReady": @NO} mutableCopy];
}
static LCMediaPiPController *makeMedia(BOOL live, BOOL playing, NSUInteger request) {
    NSDictionary *value = [LCMediaPiPController validatedDescriptor:descriptor(@"channel", 1, live, playing, request)];
    return [[LCMediaPiPController alloc] initWithView:[UIView new] descriptor:value delegate:nil];
}
static NSMutableDictionary *ack(LCMediaPiPController *media, NSUInteger revision, NSUInteger request) {
    NSMutableDictionary *value = [media.descriptor mutableCopy];
    value[@"revision"] = @(revision);
    value[@"handoffReady"] = @YES;
    value[@"handoffLease"] = media.mediaLease;
    value[@"refreshRequest"] = @(request);
    return value;
}
static void makeReady(LCMediaPiPController *media) { media.player.currentItem.status = AVPlayerItemStatusReadyToPlay; }

static void checkDescriptorValidation(void) {
    NSMutableDictionary *value = descriptor(@"channel", 1, YES, YES, 0);
    require([LCMediaPiPController validatedDescriptor:value] != nil, @"valid stream is accepted");
    value[@"url"] = @"file:///etc/passwd";
    require([LCMediaPiPController validatedDescriptor:value] == nil, @"non-network media is rejected");
    value[@"url"] = @"http://127.0.0.1:40123/token/live.m3u8";
    require([LCMediaPiPController validatedDescriptor:value] != nil, @"guest local relay remains supported");
    value[@"volume"] = @"loud";
    require([LCMediaPiPController validatedDescriptor:value] == nil, @"wrong numeric types are rejected");
    value[@"volume"] = @(NAN);
    require([LCMediaPiPController validatedDescriptor:value] == nil, @"non-finite volume is rejected");
    value[@"volume"] = @1;
    value[@"handoffLease"] = @3;
    require([LCMediaPiPController validatedDescriptor:value] == nil, @"lease must be a string");
    value[@"available"] = @NO;
    require([LCMediaPiPController validatedDescriptor:value] != nil, @"clear does not need valid media parameters");
}

static void checkLeaseAndPauseIntent(void) {
    NSUInteger activations = AVAudioSession.sharedInstance.activations;
    LCMediaPiPController *media = makeMedia(YES, YES, 7);
    require(media.refreshRequest == 7, @"new PiP inherits the page request counter");
    [media start];
    require(AVAudioSession.sharedInstance.activations == activations && media.player.currentItem == nil,
            @"preparing PiP does not steal audio before guest acknowledgement");
    NSMutableDictionary *value = ack(media, 2, 7);
    value[@"handoffLease"] = @"expired-lease";
    [media updateDescriptor:value];
    require(!media.handoffReady && media.player.currentItem == nil, @"late lease cannot authorize a new PiP player");
    value = ack(media, 3, 7);
    value[@"playing"] = @NO;
    [media updateDescriptor:value];
    require([media.playbackState[@"mediaReady"] boolValue] && !media.desiredPlaying, @"first valid ACK preserves a recent guest pause");
    makeReady(media);
    require(media.player.rate == 0 && media.player.playCalls == 0, @"paused guest is not auto-played by native preparation");
    [media attemptStart];
    [media attemptStart];
    require(media.controller.startCalls == 1, @"system PiP starts only once");
    [media didStart];
    [media.player play];
    require(media.refreshing && media.refreshRequest == 8 && media.player.rate == 0, @"system play requests a fresh live source and keeps stale frames paused");
    [media.player play];
    require(media.refreshRequest == 8 && media.player.rate == 0, @"repeated play during refresh cannot restart stale video");
    value = ack(media, 4, 7);
    [media updateDescriptor:value];
    require(media.refreshing && media.player.replacements == 1, @"older refresh acknowledgement is ignored");
    value = ack(media, 5, 8);
    value[@"handoffLease"] = @"expired-lease";
    value[@"url"] = @"https://example.invalid/fresh.m3u8";
    [media updateDescriptor:value];
    require(media.refreshing && media.player.replacements == 1, @"another lease cannot acknowledge the current refresh");
    value = ack(media, 6, 8);
    [media updateDescriptor:value];
    require(!media.refreshing && media.player.replacements == 2, @"valid refresh replaces the actual loaded source despite a stale cached ACK");
    [media.player pause];
    makeReady(media);
    require(!media.desiredPlaying && media.player.rate == 0, @"pause during loading survives the ready callback");
    value = ack(media, 7, 8);
    value[@"playing"] = @YES;
    [media updateDescriptor:value];
    require(!media.desiredPlaying, @"ordinary snapshot echo cannot undo system pause");
    [media invalidate];
    [media invalidate];
    require(media.layer.removed, @"native layer is detached on cleanup");
}

static void checkTimeoutAndBuffering(void) {
    LCMediaPiPController *media = makeMedia(YES, YES, 0);
    [media updateDescriptor:ack(media, 2, 0)];
    makeReady(media);
    [media didStart];
    media.player.timeControlStatus = AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate;
    media.player.rate = 0;
    require(media.desiredPlaying, @"buffer waiting is not reported as a user's pause");
    [media.player pause];
    require(!media.desiredPlaying, @"explicit pause remains authoritative");
    [media.player play];
    NSUInteger request = media.refreshRequest;
    fireDeadlines();
    require(!media.refreshing && !media.desiredPlaying && media.player.rate == 0, @"refresh timeout remains paused");
    NSMutableDictionary *late = ack(media, 3, request);
    late[@"url"] = @"https://example.invalid/late.m3u8";
    [media updateDescriptor:late];
    makeReady(media);
    require(!media.desiredPlaying && media.player.rate == 0, @"late refresh after timeout cannot auto-play");
    [media.player play];
    require(media.refreshRequest == request + 1, @"user can explicitly retry a failed refresh");
    late = ack(media, 4, media.refreshRequest);
    late[@"refreshFailed"] = @YES;
    [media updateDescriptor:late];
    require(!media.desiredPlaying && !media.refreshing, @"resolver failure keeps system PiP paused");
    [media invalidate];
}

static void checkFiniteRenewalAndLateSeek(void) {
    LCMediaPiPController *media = makeMedia(NO, YES, 0);
    [media updateDescriptor:ack(media, 2, 0)];
    makeReady(media);
    [media didStart];
    require(CMTimeGetSeconds(media.player.lastSeek) == 120, @"finite media enters at the guest position");
    media.player.currentTime = CMTimeMakeWithSeconds(185, 1000);
    NSMutableDictionary *renewed = ack(media, 3, 0);
    renewed[@"url"] = @"https://example.invalid/renewed.mp4";
    renewed[@"position"] = @120000;
    [media updateDescriptor:renewed];
    media.player.holdSeek = YES;
    makeReady(media);
    require(media.positioning && CMTimeGetSeconds(media.player.lastSeek) == 185, @"finite renewal preserves the native playhead instead of the paused guest's stale position");
    NSUInteger calls = media.player.playCalls;
    [media willStop];
    [media.player completeSeek:YES];
    [media applyDesiredPlayback];
    require(media.player.playCalls == calls, @"late finite seek cannot restart audio after willStop");
    [media invalidate];

    media = makeMedia(NO, YES, 0);
    __block BOOL failed = NO;
    media.failedToStart = ^(NSError *error) { failed = YES; };
    [media updateDescriptor:ack(media, 2, 0)];
    media.player.holdSeek = YES;
    makeReady(media);
    [media.player completeSeek:NO];
    require(failed && media.player.playCalls == 0 && [media.playbackState[@"mediaPosition"] doubleValue] == 120000,
            @"failed initial seek returns the original playhead without playing the wrong position");
    [media invalidate];
}

static void checkSystemTransportControls(void) {
    LCMediaPiPController *media = makeMedia(NO, YES, 0);
    require(!media.controller.requiresLinearPlayback, @"finite video must allow system backward, play/pause and forward controls");
    [media updateDescriptor:ack(media, 2, 0)];
    makeReady(media);
    [media didStart];
    require(!media.controller.requiresLinearPlayback, @"preparing finite media disabled the system seek controls");
    NSUInteger replacements = media.player.replacements;
    __block NSUInteger seeks = 0;
    [media.player seekToTime:CMTimeMakeWithSeconds(105, 1000) completionHandler:^(BOOL finished) {
        require(finished, @"system backward seek was rejected");
        ++seeks;
    }];
    require([media.playbackState[@"mediaPosition"] doubleValue] == 105000, @"system backward seek was not reflected in playback state");
    [media.player pause];
    require(!media.desiredPlaying && media.player.rate == 0, @"system pause did not pause finite playback");
    [media.player play];
    require(media.desiredPlaying && media.player.rate > 0 && !media.refreshing && media.refreshRequest == 0,
            @"system play treated finite video as a live refresh");
    [media.player seekToTime:CMTimeMakeWithSeconds(120, 1000) completionHandler:^(BOOL finished) {
        require(finished, @"system forward seek was rejected");
        ++seeks;
    }];
    require(seeks == 2 && [media.playbackState[@"mediaPosition"] doubleValue] == 120000 && media.player.replacements == replacements,
            @"system seek controls replaced the finite player or lost its position");
    NSMutableDictionary *live = ack(media, 3, 0);
    live[@"live"] = @YES;
    [media updateDescriptor:live];
    require(media.controller.requiresLinearPlayback, @"switching to live media must disable time-shift controls");
    [media invalidate];

    media = makeMedia(YES, YES, 0);
    require(media.controller.requiresLinearPlayback, @"live media must request linear system playback from initialization");
    [media updateDescriptor:ack(media, 2, 0)];
    makeReady(media);
    require(media.controller.requiresLinearPlayback, @"ready live media lost linear playback");
    NSMutableDictionary *finite = ack(media, 3, 0);
    finite[@"live"] = @NO;
    [media updateDescriptor:finite];
    require(!media.controller.requiresLinearPlayback, @"switching to finite media left system seeking disabled");
    [media invalidate];
}

int main(void) {
    @autoreleasepool {
        checkDescriptorValidation();
        checkLeaseAndPauseIntent();
        checkTimeoutAndBuffering();
        checkFiniteRenewalAndLateSeek();
        checkSystemTransportControls();
        fireDeadlines();
        NSLog(@"Native media PiP production checks passed: lease, ownership, pause, refresh, buffering, timeout, finite seek, system transport controls and teardown");
    }
    return 0;
}
