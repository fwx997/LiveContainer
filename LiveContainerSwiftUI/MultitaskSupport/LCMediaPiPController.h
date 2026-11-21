#pragma once

@import AVKit;
@import UIKit;

// A cooperating guest supplies its active stream over its own XPC connection.
// AVPlayer PiP provides the system play/pause controls that app-view PiP lacks.
API_AVAILABLE(ios(16.0))
@interface LCMediaPiPController : NSObject
@property(nonatomic, readonly) AVPictureInPictureController *controller;
@property(nonatomic, readonly) NSString *sessionIdentifier;
@property(nonatomic, readonly) NSString *mediaLease;
@property(nonatomic, readonly) NSDictionary *playbackState;
@property(nonatomic, copy) void (^stateDidChange)(void);
@property(nonatomic, copy) void (^failedToStart)(NSError *error);
+ (NSDictionary *)validatedDescriptor:(NSDictionary *)descriptor;
- (instancetype)initWithView:(UIView *)view descriptor:(NSDictionary *)descriptor
                    delegate:(id<AVPictureInPictureControllerDelegate>)delegate;
- (void)start;
- (void)didStart;
- (void)willStop;
- (void)updateDescriptor:(NSDictionary *)descriptor;
- (void)invalidate;
@end

// Configure mixing before activation so the first PiP request does not interrupt
// a guest's audio session. Native media handoff separately silences the guest.
BOOL LCActivatePictureInPictureAudio(void);
