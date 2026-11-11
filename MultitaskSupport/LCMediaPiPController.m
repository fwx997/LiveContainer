#import "LCMediaPiPController.h"
#include <math.h>

static void *LCMediaRateContext = &LCMediaRateContext;
static void *LCMediaItemContext = &LCMediaItemContext;

BOOL LCActivatePictureInPictureAudio(void) {
    AVAudioSession *audio = AVAudioSession.sharedInstance;
    NSError *error = nil;
    BOOL configured = [audio setCategory:AVAudioSessionCategoryPlayback
                                  mode:AVAudioSessionModeDefault
                               options:AVAudioSessionCategoryOptionMixWithOthers error:&error];
    return configured && [audio setActive:YES error:&error];
}

@interface LCMediaPiPController ()
@property(nonatomic, strong) AVPlayer *player;
@property(nonatomic, strong) AVPlayerLayer *layer;
@property(nonatomic, strong) AVPlayerItem *observedItem;
@property(nonatomic, strong) AVPictureInPictureController *controller;
@property(nonatomic, copy) NSDictionary *descriptor;
@property(nonatomic, copy) NSString *loadedURL;
@property(nonatomic, copy) NSDictionary *loadedHeaders;
@property(nonatomic, copy) NSString *mediaLease;
@property(nonatomic, strong) NSTimer *startTimer;
@property(nonatomic) CFTimeInterval startDeadline;
@property(nonatomic) NSUInteger itemGeneration, refreshRequest, failedItems;
@property(nonatomic) BOOL invalidated, started, starting, handoffReady;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL desiredPlaying, loading, positioning, refreshing, updatingPlayer;
@property(nonatomic) double replacementPosition;
@property(nonatomic, copy) NSString *playbackError;
@end

@implementation LCMediaPiPController

+ (NSDictionary *)validatedDescriptor:(NSDictionary *)value {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"version"] isEqual:@1]) return nil;
    // Flutter's StandardMessageCodec uses NSNull for absent optional values.
    // In particular, there cannot be a handoff lease before a host owns PiP.
    NSMutableDictionary *fields = [value mutableCopy];
    for (NSString *key in @[@"headers", @"position", @"volume", @"refreshRequest",
                            @"playing", @"live", @"handoffReady", @"refreshFailed", @"handoffLease"]) {
        if (fields[key] == NSNull.null) [fields removeObjectForKey:key];
    }
    value = fields;
    NSString *session = value[@"session"];
    NSNumber *revision = value[@"revision"];
    if (![session isKindOfClass:NSString.class] || session.length == 0 || session.length > 128) return nil;
    if (![revision isKindOfClass:NSNumber.class] || !isfinite(revision.doubleValue) || revision.longLongValue < 0) return nil;
    if (![value[@"available"] isEqual:@YES]) {
        return @{@"version": @1, @"session": session, @"revision": revision, @"available": @NO};
    }
    NSString *address = value[@"url"];
    if (![address isKindOfClass:NSString.class]) return nil;
    NSURL *url = [NSURL URLWithString:address];
    if (!url.host.length || ![@[@"https", @"http"] containsObject:url.scheme.lowercaseString]) return nil;
    NSDictionary *headers = value[@"headers"] ?: @{};
    if (![headers isKindOfClass:NSDictionary.class]) return nil;
    for (id key in headers) {
        if (![key isKindOfClass:NSString.class] || ![headers[key] isKindOfClass:NSString.class]) return nil;
    }
    for (NSString *key in @[@"position", @"volume", @"refreshRequest"]) {
        id number = value[key];
        if (number && (![number isKindOfClass:NSNumber.class] || !isfinite([number doubleValue]))) return nil;
    }
    for (NSString *key in @[@"playing", @"live", @"handoffReady", @"refreshFailed"]) {
        if (value[key] && ![value[key] isKindOfClass:NSNumber.class]) return nil;
    }
    if (value[@"handoffLease"] && ![value[@"handoffLease"] isKindOfClass:NSString.class]) return nil;
    if ([value[@"refreshRequest"] longLongValue] < 0) return nil;
    NSMutableDictionary *normalized = [value mutableCopy];
    normalized[@"headers"] = [headers copy];
    normalized[@"volume"] = value[@"volume"] ?: @1;
    normalized[@"live"] = value[@"live"] ?: @YES;
    return normalized;
}

- (instancetype)initWithView:(UIView *)view descriptor:(NSDictionary *)descriptor
                    delegate:(id<AVPictureInPictureControllerDelegate>)delegate {
    self = [super init];
    if (!self) return nil;
    _descriptor = [descriptor copy];
    _mediaLease = NSUUID.UUID.UUIDString;
    _refreshRequest = [descriptor[@"refreshRequest"] unsignedIntegerValue];
    _replacementPosition = MAX(0, [descriptor[@"position"] doubleValue] / 1000);
    _desiredPlaying = [descriptor[@"playing"] boolValue];
    _playbackError = @"";
    _player = [AVPlayer new];
    _player.automaticallyWaitsToMinimizeStalling = YES;
    _layer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _layer.frame = view.bounds;
    _layer.videoGravity = AVLayerVideoGravityResizeAspect;
    _layer.backgroundColor = UIColor.blackColor.CGColor;
    [view.layer addSublayer:_layer];
    _controller = [[AVPictureInPictureController alloc] initWithPlayerLayer:_layer];
    _controller.delegate = delegate;
    _controller.requiresLinearPlayback = [descriptor[@"live"] boolValue];
    [_player addObserver:self forKeyPath:@"rate" options:NSKeyValueObservingOptionNew context:LCMediaRateContext];
    return self;
}

- (NSString *)sessionIdentifier {
    return self.descriptor[@"session"];
}

- (NSDictionary *)playbackState {
    double position = CMTimeGetSeconds(self.player.currentTime) * 1000;
    if (!self.handoffReady || self.loading || self.positioning || [self.playbackError isEqual:@"media_seek_failed"]) {
        position = self.replacementPosition * 1000;
    }
    if (!isfinite(position) || position < 0) position = [self.descriptor[@"position"] doubleValue];
    return @{
        @"mediaActive": @(!self.invalidated), @"mediaSession": self.sessionIdentifier,
        @"mediaLease": self.mediaLease,
        @"mediaReady": @(self.handoffReady),
        @"mediaPlaying": @(self.desiredPlaying), @"mediaLive": @([self.descriptor[@"live"] boolValue]),
        @"mediaPosition": @(MAX(0, position)), @"mediaRequest": @(self.refreshRequest),
        @"mediaError": self.playbackError ?: @"",
    };
}

- (void)start {
    if (self.invalidated || self.stopping || self.started || self.startTimer) return;
    self.startDeadline = CACurrentMediaTime() + 15;
    __weak typeof(self) weakSelf = self;
    self.startTimer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf attemptStart];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.startTimer forMode:NSRunLoopCommonModes];
    [self attemptStart];
}

- (void)attemptStart {
    if (self.invalidated || self.stopping || self.started) return;
    if (CACurrentMediaTime() >= self.startDeadline) {
        [self failStart:@"media_start_timeout"];
        return;
    }
    if (self.starting || !self.handoffReady || self.loading || self.positioning || !self.layer.readyForDisplay) return;
    if (!self.controller.isPictureInPicturePossible) return;
    self.starting = YES;
    [self.controller startPictureInPicture];
}

- (void)didStart {
    if (self.invalidated || self.stopping) return;
    self.started = YES;
    [self.startTimer invalidate];
    self.startTimer = nil;
}

- (void)willStop {
    self.stopping = YES;
    [self.startTimer invalidate];
    self.startTimer = nil;
}

- (void)updateDescriptor:(NSDictionary *)descriptor {
    if (self.invalidated || self.stopping || ![descriptor[@"session"] isEqual:self.sessionIdentifier]) return;
    if ([descriptor[@"revision"] longLongValue] <= [self.descriptor[@"revision"] longLongValue]) return;
    BOOL sourceChanged = ![descriptor[@"url"] isEqual:self.loadedURL] ||
                         ![(descriptor[@"headers"] ?: @{}) isEqual:(self.loadedHeaders ?: @{})];
    self.descriptor = [descriptor copy];
    self.player.volume = MIN(1, MAX(0, [descriptor[@"volume"] floatValue]));
    if (![descriptor[@"handoffLease"] isEqual:self.mediaLease]) return;
    if (![descriptor[@"handoffReady"] boolValue]) return;
    self.controller.requiresLinearPlayback = [descriptor[@"live"] boolValue];
    if (!self.handoffReady) {
        self.handoffReady = YES;
        self.desiredPlaying = [descriptor[@"playing"] boolValue];
        [self replacePlayerItem];
        if (self.stateDidChange) self.stateDidChange();
        return;
    }
    if (self.refreshing && [descriptor[@"refreshRequest"] unsignedIntegerValue] == self.refreshRequest) {
        if ([descriptor[@"refreshFailed"] boolValue]) {
            [self failRefresh:@"media_refresh_failed"];
            return;
        }
        self.refreshing = NO;
        self.playbackError = @"";
        [self replacePlayerItem];
        return;
    }
    if (sourceChanged && !self.refreshing) [self replacePlayerItem];
}

- (void)replacePlayerItem {
    if (self.invalidated || self.stopping) return;
    double position = CMTimeGetSeconds(self.player.currentTime);
    if (!self.started || !isfinite(position) || position < 0) position = [self.descriptor[@"position"] doubleValue] / 1000;
    self.replacementPosition = MAX(0, position);
    [self removeItemObserver];
    self.itemGeneration++;
    self.loading = YES;
    self.positioning = NO;
    self.updatingPlayer = YES;
    [self.player pause];
    [self.player cancelPendingPrerolls];
    NSURL *url = [NSURL URLWithString:self.descriptor[@"url"]];
    self.loadedURL = self.descriptor[@"url"];
    self.loadedHeaders = self.descriptor[@"headers"] ?: @{};
    NSDictionary *options = @{@"AVURLAssetHTTPHeaderFieldsKey": self.loadedHeaders};
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:options];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    self.observedItem = item;
    [self.player replaceCurrentItemWithPlayerItem:item];
    self.controller.requiresLinearPlayback = [self.descriptor[@"live"] boolValue];
    [item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:LCMediaItemContext];
    self.updatingPlayer = NO;
}

- (void)itemStatusChanged:(AVPlayerItem *)item generation:(NSUInteger)generation {
    if (self.invalidated || self.stopping || self.refreshing || generation != self.itemGeneration || item != self.player.currentItem) return;
    if (item.status == AVPlayerItemStatusFailed) {
        if (!self.started) { [self failStart:@"media_source_failed"]; return; }
        if (++self.failedItems <= 1 && self.desiredPlaying) [self requestLatestPlayback];
        else [self failRefresh:@"media_source_failed"];
        return;
    }
    if (item.status != AVPlayerItemStatusReadyToPlay || !self.loading) return;
    self.loading = NO;
    if (!LCActivatePictureInPictureAudio()) { [self failStart:@"media_audio_failed"]; return; }
    double position = self.replacementPosition;
    if (![self.descriptor[@"live"] boolValue] && position > 0) {
        self.positioning = YES;
        __weak typeof(self) weakSelf = self;
        [self.player seekToTime:CMTimeMakeWithSeconds(position, 1000) completionHandler:^(BOOL finished) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf finishPositioning:finished generation:generation];
            });
        }];
        return;
    }
    [self applyDesiredPlayback];
}

- (void)finishPositioning:(BOOL)finished generation:(NSUInteger)generation {
    if (self.invalidated || self.stopping || self.itemGeneration != generation) return;
    self.positioning = NO;
    if (finished) { [self applyDesiredPlayback]; return; }
    if (self.started) [self failRefresh:@"media_seek_failed"];
    else [self failStart:@"media_seek_failed"];
}

- (void)applyDesiredPlayback {
    if (self.invalidated || self.stopping || self.refreshing) return;
    self.updatingPlayer = YES;
    if (self.desiredPlaying) [self.player play];
    else {
        [self.player pause];
        [self.player prerollAtRate:1 completionHandler:^(BOOL finished) {}];
    }
    self.updatingPlayer = NO;
    if (self.stateDidChange) self.stateDidChange();
}

- (void)rateChanged:(float)rate internal:(BOOL)internal generation:(NSUInteger)generation {
    if (self.invalidated || self.stopping || internal || generation != self.itemGeneration || !self.started) return;
    if (self.refreshing) {
        if (rate > 0) [self pausePlayer];
        return;
    }
    BOOL playing = rate > 0;
    // A stalled live stream may temporarily have rate zero while it is waiting
    // for data. That is not the user's pause command.
    if (!playing && self.player.timeControlStatus == AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate) return;
    if (playing == self.desiredPlaying) return;
    self.desiredPlaying = playing;
    self.playbackError = @"";
    if (playing && [self.descriptor[@"live"] boolValue]) {
        self.failedItems = 0;
        [self requestLatestPlayback];
        return;
    }
    if (self.stateDidChange) self.stateDidChange();
}

- (void)requestLatestPlayback {
    if (self.invalidated || self.stopping || self.refreshing) return;
    self.refreshing = YES;
    self.desiredPlaying = YES;
    NSUInteger request = ++self.refreshRequest;
    [self pausePlayer];
    if (self.stateDidChange) self.stateDidChange();
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (weakSelf.refreshing && weakSelf.refreshRequest == request) [weakSelf failRefresh:@"media_refresh_timeout"];
    });
}

- (void)pausePlayer {
    self.updatingPlayer = YES;
    [self.player pause];
    self.updatingPlayer = NO;
}

- (void)failRefresh:(NSString *)reason {
    if (self.invalidated || self.stopping) return;
    self.refreshing = NO;
    self.desiredPlaying = NO;
    self.playbackError = reason;
    [self pausePlayer];
    if (self.stateDidChange) self.stateDidChange();
}

- (void)failStart:(NSString *)reason {
    if (self.invalidated || self.stopping) return;
    self.playbackError = reason;
    [self.startTimer invalidate];
    self.startTimer = nil;
    NSError *error = [NSError errorWithDomain:@"LCMediaPiP" code:1 userInfo:@{NSLocalizedDescriptionKey: reason}];
    if (self.failedToStart) self.failedToStart(error);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                      change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (self.invalidated) return;
    NSUInteger generation = self.itemGeneration;
    if (context == LCMediaRateContext) {
        BOOL internal = self.updatingPlayer;
        float rate = [change[NSKeyValueChangeNewKey] floatValue];
        dispatch_async(dispatch_get_main_queue(), ^{ [self rateChanged:rate internal:internal generation:generation]; });
        return;
    }
    if (context == LCMediaItemContext) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self itemStatusChanged:object generation:generation]; });
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)removeItemObserver {
    if (!self.observedItem) return;
    [self.observedItem removeObserver:self forKeyPath:@"status" context:LCMediaItemContext];
    self.observedItem = nil;
}

- (void)invalidate {
    if (self.invalidated) return;
    self.invalidated = YES;
    [self.startTimer invalidate];
    self.startTimer = nil;
    self.controller.delegate = nil;
    [self.controller stopPictureInPicture];
    [self removeItemObserver];
    [self.player removeObserver:self forKeyPath:@"rate" context:LCMediaRateContext];
    [self pausePlayer];
    [self.player cancelPendingPrerolls];
    [self.layer removeFromSuperlayer];
    self.stateDidChange = nil;
    self.failedToStart = nil;
}

- (void)dealloc {
    [self invalidate];
}
@end
