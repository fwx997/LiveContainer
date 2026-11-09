//
//  VirtualWindowsHostView.h
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
@import UIKit;

@class DecoratedAppSceneViewController;

API_AVAILABLE(ios(16.0))
@interface VirtualWindowsHostView: UIView
@property(nonatomic) BOOL shouldForwardTapAction;
- (BOOL)handleStatusBarTapAction:(UIAction *)action;
+ (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindow:(UIWindow *)window;
- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations forController:(DecoratedAppSceneViewController *)controller;
- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations
                       forController:(DecoratedAppSceneViewController *)controller
                           fullscreen:(BOOL)fullscreen
                                reply:(void (^)(NSDictionary *state))reply;
- (void)releaseOrientationForController:(DecoratedAppSceneViewController *)controller;
@end
