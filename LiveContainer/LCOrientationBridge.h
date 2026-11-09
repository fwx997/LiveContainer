#pragma once

#import <Foundation/Foundation.h>

static NSString * const LCOrientationEndpointKey = @"LCOrientationEndpoint";
static NSString * const LCOrientationBridgeVersionKey = @"LCOrientationBridgeVersion";
static NSString * const LCContainerPlaybackVersionKey = @"LCContainerPlaybackVersion";
static NSString * const LCContainerPlaybackStateDidChange = @"LCContainerPlaybackStateDidChange";
static const NSUInteger LCOrientationBridgeVersion = 2;

typedef void (^LCOrientationReply)(NSDictionary *state);

// Both host and guest complete requests on the main queue. A timeout, an XPC
// failure and a late geometry callback must never invoke the same reply twice.
static inline LCOrientationReply LCOrientationReplyOnce(LCOrientationReply reply) {
    __block BOOL completed = NO;
    return [^(NSDictionary *state) {
        if (completed) return;
        completed = YES;
        if (reply) reply(state);
    } copy];
}

static inline NSDictionary *LCOrientationFailure(NSString *reason, BOOL supported) {
    return @{@"version": @(LCOrientationBridgeVersion), @"supported": @(supported),
             @"accepted": @NO, @"applied": @NO, @"reason": reason,
             @"orientation": @0, @"width": @0, @"height": @0};
}

@protocol LCContainerPlaybackGuest
- (void)containerPlaybackStateDidChange:(NSDictionary *)state;
@end

@protocol LCOrientationHost
- (void)requestInterfaceOrientations:(NSUInteger)orientations;
- (void)requestInterfaceOrientations:(NSUInteger)orientations
                          fullscreen:(BOOL)fullscreen
                              reply:(LCOrientationReply)reply;
- (void)observeContainerPlaybackState;
@end
