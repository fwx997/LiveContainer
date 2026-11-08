#pragma once

#import <Foundation/Foundation.h>

static NSString * const LCOrientationEndpointKey = @"LCOrientationEndpoint";

@protocol LCOrientationHost
- (void)requestInterfaceOrientations:(NSUInteger)orientations;
@end
