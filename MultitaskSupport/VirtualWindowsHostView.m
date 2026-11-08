//
//  VirtualWindowsHostView.m
//  LiveContainer
//
//  Created by Duy Tran on 22/2/26.
//
#import "DecoratedAppSceneViewController.h"
#import "VirtualWindowsHostView.h"

@interface VirtualWindowsHostView ()
@property(nonatomic, weak) DecoratedAppSceneViewController *orientationOwner;
@property(nonatomic) UIInterfaceOrientationMask requestedOrientations;
@property(nonatomic) UIInterfaceOrientationMask restorationOrientations;
@property(nonatomic) NSUInteger orientationGeneration;
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
