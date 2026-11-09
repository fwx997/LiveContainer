//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"
#import "../LiveContainer/LCOrientationBridge.h"
#import <QuartzCore/QuartzCore.h>

@interface LCOrientationTransaction : NSObject
@property(nonatomic, weak) DecoratedAppSceneViewController *controller;
@property(nonatomic, copy) LCOrientationReply reply;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) UIInterfaceOrientationMask orientations;
@property(nonatomic) BOOL completed, restoreFloatingWindow;
@property(nonatomic) CFTimeInterval deadline;
@end
@implementation LCOrientationTransaction
@end

@interface VirtualWindowsHostView ()
@property(nonatomic, weak) DecoratedAppSceneViewController *orientationOwner;
@property(nonatomic) UIInterfaceOrientationMask requestedOrientations;
@property(nonatomic) UIInterfaceOrientationMask restorationOrientations;
@property(nonatomic) NSUInteger orientationGeneration;
@property(nonatomic, weak) DecoratedAppSceneViewController *fullscreenMaximizedController;
@end

@implementation VirtualWindowsHostView
- (instancetype)init {
    CGRect frame = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).keyWindow.bounds;
    self = [super initWithFrame:frame];
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.shouldForwardTapAction = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(hostSceneDidActivate:) name:UISceneDidActivateNotification object:nil];
    return self;
}
- (void)hostSceneDidActivate:(NSNotification *)notification {
    if (notification.object == self.window.windowScene) {
        [self validateOrientationOwner];
        [self restoreHostOrientationIfNeeded];
        [self setNeedsLayout];
    }
}
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self validateOrientationOwner];
    [self restoreHostOrientationIfNeeded];
    for (UIView *view in self.subviews) {
        DecoratedAppSceneViewController *controller = (id)view._viewDelegate;
        if ([controller isKindOfClass:DecoratedAppSceneViewController.class]) {
            // Guest scene callbacks stop after termination; host layout must not.
            [controller updateMaximizedFrame];
        }
    }
}

+ (UIInterfaceOrientationMask)defaultInterfaceOrientations {
    return UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad
        ? UIInterfaceOrientationMaskAll : UIInterfaceOrientationMaskAllButUpsideDown;
}

+ (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    for (UIView *view in window.rootViewController.viewIfLoaded.subviews) {
        if (![view isKindOfClass:self]) continue;
        VirtualWindowsHostView *host = (id)view;
        if ([host isOrientationOwnerEligible:host.orientationOwner] && !window.rootViewController.presentedViewController) {
            return host.requestedOrientations;
        }
    }
    return [self defaultInterfaceOrientations];
}

- (DecoratedAppSceneViewController *)frontmostController {
    for (UIView *view in self.subviews.reverseObjectEnumerator) {
        if (view.hidden || view.alpha <= 0.01) continue;
        id controller = view._viewDelegate;
        if ([controller isKindOfClass:DecoratedAppSceneViewController.class]) return controller;
    }
    return nil;
}

- (BOOL)isOrientationOwnerEligible:(DecoratedAppSceneViewController *)controller {
    UIWindow *window = self.window;
    if (!controller || !window || self.hidden || self.alpha <= 0.01) return NO;
    if (controller.view.superview != self || controller.view.window != window) return NO;
    return controller.isMaximized && controller.appSceneVC.isAppRunning &&
        !controller.appSceneVC.shouldIgnoreSceneUpdates && [self frontmostController] == controller;
}

- (BOOL)canControlOrientation:(DecoratedAppSceneViewController *)controller {
    if (![self isOrientationOwnerEligible:controller]) return NO;
    return self.window.isKeyWindow &&
        self.window.windowScene.activationState == UISceneActivationStateForegroundActive &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive &&
        !self.window.rootViewController.presentedViewController;
}

- (NSString *)fullscreenRejectionForController:(DecoratedAppSceneViewController *)controller {
    UIWindow *window = self.window;
    if (!controller || !window || self.hidden || self.alpha <= 0.01 || window.hidden) return @"host_not_visible";
    if (controller.view.superview != self || controller.view.window != window) return @"guest_not_attached";
    if (controller.view.hidden || controller.view.alpha <= 0.01) return @"guest_not_visible";
    if (!controller.appSceneVC.isAppRunning) return @"guest_terminated";
    if (controller.appSceneVC.shouldIgnoreSceneUpdates) return @"picture_in_picture";
    if ([self frontmostController] != controller) return @"guest_not_frontmost";
    if (window.windowScene.activationState != UISceneActivationStateForegroundActive ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return @"host_inactive";
    if (window.rootViewController.presentedViewController) return @"host_modal";
    // A hosted guest may own keyboard focus. Its authenticated, explicit action
    // must not depend on UIApplication.keyWindow being the host's normal window.
    return nil;
}

- (NSDictionary *)orientationStateForController:(DecoratedAppSceneViewController *)controller
                                       accepted:(BOOL)accepted applied:(BOOL)applied reason:(NSString *)reason {
    CGSize size = controller.appSceneVC.contentView.bounds.size;
    if (size.width <= 0 || size.height <= 0) size = controller.appSceneVC.view.bounds.size;
    return @{@"version": @(LCOrientationBridgeVersion), @"supported": @YES, @"container": @YES,
             @"accepted": @(accepted), @"applied": @(applied), @"reason": reason,
             @"orientation": @(self.window.windowScene.interfaceOrientation),
             @"width": @(size.width), @"height": @(size.height)};
}

- (void)finishOrientationTransaction:(LCOrientationTransaction *)request applied:(BOOL)applied reason:(NSString *)reason {
    if (request.completed) return;
    request.completed = YES;
    request.reply([self orientationStateForController:request.controller accepted:YES applied:applied reason:reason]);
}

- (void)failOrientationTransaction:(LCOrientationTransaction *)request reason:(NSString *)reason {
    if (request.completed) return;
    if (self.orientationGeneration == request.generation && self.orientationOwner == request.controller) {
        BOOL restoreFloatingWindow = self.fullscreenMaximizedController == request.controller;
        self.fullscreenMaximizedController = nil;
        self.orientationOwner = nil;
        self.requestedOrientations = 0;
        ++self.orientationGeneration;
        [self.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
        [self restoreHostOrientationIfNeeded];
        if (restoreFloatingWindow && request.controller.isMaximized) {
            [UIView performWithoutAnimation:^{ [request.controller maximizeWindow]; }];
        }
    }
    [self finishOrientationTransaction:request applied:NO reason:reason];
}

- (void)checkOrientationTransaction:(LCOrientationTransaction *)request {
    if (request.completed) return;
    if (request.generation != self.orientationGeneration) {
        [self finishOrientationTransaction:request applied:NO reason:@"superseded"];
        return;
    }
    NSString *rejection = [self fullscreenRejectionForController:request.controller];
    if (rejection) {
        [self failOrientationTransaction:request reason:rejection];
        return;
    }
    [request.controller updateMaximizedFrame];
    [request.controller.view layoutIfNeeded];
    // The hosting view can receive geometry after UIKit has already rotated
    // the host. Wait for both instead of treating dispatch as rotation success.
    NSDictionary *state = [self orientationStateForController:request.controller accepted:YES applied:NO reason:@"pending"];
    UIInterfaceOrientation orientation = self.window.windowScene.interfaceOrientation;
    CGSize hostSize = self.window.bounds.size;
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    BOOL hostMatches = landscape ? hostSize.width > hostSize.height : hostSize.height > hostSize.width;
    BOOL guestMatches = landscape ? [state[@"width"] doubleValue] > [state[@"height"] doubleValue]
                                 : [state[@"height"] doubleValue] > [state[@"width"] doubleValue];
    if (orientation >= UIInterfaceOrientationPortrait && orientation <= UIInterfaceOrientationLandscapeRight &&
        (request.orientations & (1UL << orientation)) && hostMatches && guestMatches) {
        if (request.restoreFloatingWindow && request.controller.isMaximized) {
            [UIView performWithoutAnimation:^{ [request.controller maximizeWindow]; }];
        }
        [self finishOrientationTransaction:request applied:YES reason:@"applied"];
        return;
    }
    if (CACurrentMediaTime() >= request.deadline) {
        [self failOrientationTransaction:request reason:@"geometry_timeout"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        VirtualWindowsHostView *host = weakSelf;
        if (host) [host checkOrientationTransaction:request];
        else request.reply(LCOrientationFailure(@"host_unavailable", YES));
    });
}

- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations
                       forController:(DecoratedAppSceneViewController *)controller
                           fullscreen:(BOOL)fullscreen reply:(void (^)(NSDictionary *))reply {
    LCOrientationReply finish = LCOrientationReplyOnce(reply);
    if (!orientations || (orientations & ~UIInterfaceOrientationMaskAll)) {
        finish(LCOrientationFailure(@"invalid_orientations", YES));
        return;
    }
    orientations &= [VirtualWindowsHostView defaultInterfaceOrientations];
    if (!orientations) {
        finish(LCOrientationFailure(@"unsupported_orientation", YES));
        return;
    }
    if (!fullscreen && self.orientationOwner != controller) {
        finish([self orientationStateForController:controller accepted:NO applied:NO reason:@"not_orientation_owner"]);
        return;
    }
    NSString *rejection = [self fullscreenRejectionForController:controller];
    if (rejection) {
        if (!fullscreen) [self releaseOrientationForController:controller];
        finish([self orientationStateForController:controller accepted:NO applied:NO reason:rejection]);
        return;
    }
    // Returning from fullscreen restores the actual entry direction, which may
    // already have been landscape. A guest's portrait default must not replace it.
    if (!fullscreen && self.restorationOrientations) orientations = self.restorationOrientations;
    LCOrientationTransaction *request = [LCOrientationTransaction new];
    request.controller = controller;
    request.reply = finish;
    request.orientations = orientations;
    request.deadline = CACurrentMediaTime() + 2.0;
    if (fullscreen && !controller.isMaximized) {
        self.fullscreenMaximizedController = controller;
        [UIView performWithoutAnimation:^{ [controller maximizeWindow]; }];
    }
    if (!fullscreen) {
        request.restoreFloatingWindow = self.fullscreenMaximizedController == controller;
        self.fullscreenMaximizedController = nil;
        self.orientationOwner = nil;
        self.requestedOrientations = 0;
        self.restorationOrientations = 0;
    } else {
        if (!self.orientationOwner && !self.restorationOrientations) {
            UIInterfaceOrientation original = self.window.windowScene.interfaceOrientation;
            self.restorationOrientations = (1UL << original) & [VirtualWindowsHostView defaultInterfaceOrientations];
        }
        self.orientationOwner = controller;
        self.requestedOrientations = orientations;
    }
    request.generation = ++self.orientationGeneration;
    [self.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:orientations];
    __weak typeof(self) weakSelf = self;
    [self.window.windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VirtualWindowsHostView *host = weakSelf;
            if (!host || request.completed || host.orientationGeneration != request.generation) return;
            NSLog(@"[LCOrientation] Explicit geometry request failed: %@", error);
            [host failOrientationTransaction:request reason:@"geometry_rejected"];
        });
    }];
    [self checkOrientationTransaction:request];
}

- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations forController:(DecoratedAppSceneViewController *)controller {
    // A floating/background guest must never rotate every other app on stage.
    if (![self canControlOrientation:controller]) return;
    if (orientations & ~UIInterfaceOrientationMaskAll) return;
    orientations &= [VirtualWindowsHostView defaultInterfaceOrientations];
    if (!orientations) return;
    if (!self.orientationOwner && !self.restorationOrientations) {
        UIInterfaceOrientation original = self.window.windowScene.interfaceOrientation;
        self.restorationOrientations = (1UL << original) & [VirtualWindowsHostView defaultInterfaceOrientations];
    }
    self.orientationOwner = controller;
    self.requestedOrientations = orientations;
    NSUInteger generation = ++self.orientationGeneration;
    [self.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:orientations];
    __weak typeof(self) weakSelf = self;
    [self.window.windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            VirtualWindowsHostView *host = weakSelf;
            if (!host || host.orientationGeneration != generation) return;
            NSLog(@"[LCOrientation] Host rotation rejected: %@", error);
            host.orientationOwner = nil;
            host.requestedOrientations = 0;
            host.restorationOrientations = 0;
            [host.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
        });
    }];
}

- (void)releaseOrientationForController:(DecoratedAppSceneViewController *)controller {
    if (!controller || self.orientationOwner != controller) return;
    self.fullscreenMaximizedController = nil;
    self.orientationOwner = nil;
    self.requestedOrientations = 0;
    ++self.orientationGeneration;
    [self.window.rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    [self restoreHostOrientationIfNeeded];
}

- (void)restoreHostOrientationIfNeeded {
    if (self.orientationOwner || !self.restorationOrientations) return;
    if (self.window.windowScene.activationState != UISceneActivationStateForegroundActive ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    UIInterfaceOrientationMask restore = self.restorationOrientations;
    self.restorationOrientations = 0;
    UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:restore];
    [self.window.windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
        NSLog(@"[LCOrientation] Host orientation restoration rejected: %@", error);
    }];
}

- (void)validateOrientationOwner {
    if (self.orientationOwner && ![self isOrientationOwnerEligible:self.orientationOwner]) {
        [self releaseOrientationForController:self.orientationOwner];
    }
}

- (void)bringSubviewToFront:(UIView *)view {
    [super bringSubviewToFront:view];
    [self validateOrientationOwner];
}

- (void)didAddSubview:(UIView *)view {
    [super didAddSubview:view];
    [self validateOrientationOwner];
}

- (void)sendSubviewToBack:(UIView *)view {
    [super sendSubviewToBack:view];
    [self validateOrientationOwner];
}

- (void)willRemoveSubview:(UIView *)view {
    if (view == self.orientationOwner.view) {
        [self releaseOrientationForController:self.orientationOwner];
    }
    [super willRemoveSubview:view];
}

- (BOOL)handleStatusBarTapAction:(UIAction *)action {
    if(!self.shouldForwardTapAction) return NO;
    // grab the frontmost app window, if it's visible pass this event to it
    UIView *frontmostView = self.subviews.lastObject;
    if(!frontmostView.hidden) {
        DecoratedAppSceneViewController *decoratedVC = (id)frontmostView._viewDelegate;
        [decoratedVC.appSceneVC handleStatusBarTapAction:action];
    }
    return !frontmostView.hidden;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView* hitView = [super hitTest:point withEvent:event];
    if(hitView == self) {
        self.shouldForwardTapAction = NO;
        return nil;
    } else {
        self.shouldForwardTapAction = YES;
        return hitView;
    }
}
@end
