#pragma once

#import <Foundation/Foundation.h>

static NSString * const LCOrientationEndpointKey = @"LCOrientationEndpoint";
static NSString * const LCContainerPlaybackVersionKey = @"LCContainerPlaybackVersion";
static NSString * const LCContainerPlaybackStateDidChange = @"LCContainerPlaybackStateDidChange";

@protocol LCContainerPlaybackGuest
- (void)containerPlaybackStateDidChange:(NSDictionary *)state;
@end

@protocol LCOrientationHost
- (void)requestInterfaceOrientations:(NSUInteger)orientations;
- (void)observeContainerPlaybackState;
@end
