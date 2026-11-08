#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// INSERT_WINDOW_BAR_METRICS

// Minimal host views let the production layout run after a guest stops invoking
// scene update blocks, without launching an extension or a private UIKit scene.
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
static const UIEdgeInsets UIEdgeInsetsZero = {0, 0, 0, 0};
static CGRect UIEdgeInsetsInsetRect(CGRect rect, UIEdgeInsets insets) {
    return CGRectMake(rect.origin.x + insets.left, rect.origin.y + insets.top,
                      rect.size.width - insets.left - insets.right,
                      rect.size.height - insets.top - insets.bottom);
}
static BOOL UIInterfaceOrientationIsLandscape(NSInteger orientation) { return orientation >= 3; }
enum { UIUserInterfaceIdiomPad = 1 };

@interface UIDevice : NSObject
@property NSInteger userInterfaceIdiom;
+ (instancetype)currentDevice;
@end
@implementation UIDevice
+ (instancetype)currentDevice { static UIDevice *device; if (!device) device = [self new]; return device; }
@end

@interface WindowScene : NSObject
@property NSInteger interfaceOrientation;
@end
@implementation WindowScene
@end

@interface NSUserDefaults (LiveContainer)
+ (instancetype)lcSharedDefaults;
@end
@implementation NSUserDefaults (LiveContainer)
+ (instancetype)lcSharedDefaults { return NSUserDefaults.standardUserDefaults; }
@end

@interface NSLayoutConstraint : NSObject
@property CGFloat constant;
+ (void)activateConstraints:(NSArray *)constraints;
+ (void)deactivateConstraints:(NSArray *)constraints;
@end
@implementation NSLayoutConstraint
+ (void)activateConstraints:(NSArray *)constraints {}
+ (void)deactivateConstraints:(NSArray *)constraints {}
@end

@interface Anchor : NSObject
- (NSLayoutConstraint *)constraintEqualToAnchor:(Anchor *)anchor;
- (NSLayoutConstraint *)constraintEqualToAnchor:(Anchor *)anchor constant:(CGFloat)constant;
- (NSLayoutConstraint *)constraintEqualToConstant:(CGFloat)constant;
@end
@implementation Anchor
- (NSLayoutConstraint *)constraintEqualToAnchor:(Anchor *)anchor { return [self constraintEqualToConstant:0]; }
- (NSLayoutConstraint *)constraintEqualToAnchor:(Anchor *)anchor constant:(CGFloat)constant { return [self constraintEqualToConstant:constant]; }
- (NSLayoutConstraint *)constraintEqualToConstant:(CGFloat)constant {
    NSLayoutConstraint *constraint = [NSLayoutConstraint new];
    constraint.constant = constant;
    return constraint;
}
@end

@class UIWindow;
@interface UIView : NSObject
@property CGRect frame, bounds;
@property CGPoint center;
@property CGAffineTransform transform;
@property UIEdgeInsets safeAreaInsets;
@property UIWindow *window;
@property UIView *superview;
@property NSArray<UIView *> *subviews;
@property id controller;
@property BOOL hidden, needsLayout;
@property CGFloat alpha;
@property(readonly) Anchor *topAnchor, *bottomAnchor, *heightAnchor;
- (id)_viewDelegate;
- (void)layoutIfNeeded;
- (void)setNeedsLayout;
- (void)layoutSubviews;
- (void)safeAreaInsetsDidChange;
- (CGRect)convertRect:(CGRect)rect fromView:(UIView *)view;
+ (void)animateWithDuration:(double)duration animations:(void (^)(void))animations;
@end
@implementation UIView
- (instancetype)init { self = [super init]; _transform = CGAffineTransformIdentity; return self; }
- (Anchor *)topAnchor { return [Anchor new]; }
- (Anchor *)bottomAnchor { return [Anchor new]; }
- (Anchor *)heightAnchor { return [Anchor new]; }
- (id)_viewDelegate { return self.controller; }
- (void)layoutIfNeeded {}
- (void)setNeedsLayout { self.needsLayout = YES; }
- (void)layoutSubviews {}
- (void)safeAreaInsetsDidChange {}
- (CGRect)convertRect:(CGRect)rect fromView:(UIView *)view {
    return CGRectOffset(rect, -self.frame.origin.x, -self.frame.origin.y);
}
+ (void)animateWithDuration:(double)duration animations:(void (^)(void))animations { animations(); }
@end

@interface UIWindow : UIView
@property WindowScene *windowScene;
@end
@implementation UIWindow
@end

@interface UIMutableApplicationSceneSettings : NSObject
@property UIEdgeInsets peripheryInsets, safeAreaInsetsPortrait;
@end
@implementation UIMutableApplicationSceneSettings
@end

@interface AppSceneViewController : NSObject
@property UIView *view;
@property BOOL shouldSkipDebounceOnce;
@end
@implementation AppSceneViewController
- (void)updateSettingsWithBlock:(void (^)(UIMutableApplicationSceneSettings *))block {
    // A terminated scene never invokes this block. Host layout must still work.
}
@end

@interface MultitaskDockManager : NSObject
@property BOOL isCollapsed;
+ (instancetype)shared;
@end
@implementation MultitaskDockManager
+ (instancetype)shared { static MultitaskDockManager *dock; if (!dock) dock = [self new]; return dock; }
@end

@interface DecoratedAppSceneViewController : NSObject
@property UIView *view, *navigationBar, *windowBarView;
@property NSLayoutConstraint *navigationBarTopConstraint;
@property AppSceneViewController *appSceneVC;
@property BOOL isMaximized, hasAppTerminated;
@property CGRect originalFrame;
@property NSArray<NSLayoutConstraint *> *activatedVerticalConstraints;
@end
@implementation DecoratedAppSceneViewController
// INSERT_WINDOW_BAR_HEIGHT
// INSERT_INITIAL_WINDOW_FRAME
// INSERT_MAXIMIZED_FRAME
// INSERT_WINDOWED_FRAME
// INSERT_VERTICAL_CONSTRAINTS
- (void)updateMaximizedFrameWithSettings:(UIMutableApplicationSceneSettings *)settings { [self updateMaximizedFrame]; }
@end

@interface VirtualWindowsHostView : UIView
@end
@implementation VirtualWindowsHostView
// INSERT_HOST_LAYOUT
// INSERT_HOST_ACTIVATION
// INSERT_SAFE_AREA_CHANGE
@end

static void require(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"%@", message); exit(1); }
}

int main(void) {
    @autoreleasepool {
        [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCMultitaskBottomWindowBar"];
        UIDevice.currentDevice.userInterfaceIdiom = UIUserInterfaceIdiomPad;
        UIWindow *window = [UIWindow new];
        window.bounds = CGRectMake(0, 0, 1024, 768);
        window.frame = CGRectMake(90, 70, 1024, 768); // Stage Manager window origin.
        window.safeAreaInsets = (UIEdgeInsets){24, 0, 20, 0};
        window.windowScene = [WindowScene new];
        VirtualWindowsHostView *host = [VirtualWindowsHostView new];
        host.frame = CGRectMake(0, 24, 1024, 744);
        host.window = window;
        DecoratedAppSceneViewController *vc = [DecoratedAppSceneViewController new];
        vc.view = [UIView new];
        vc.view.window = window;
        vc.view.superview = host;
        vc.view.controller = vc;
        vc.navigationBar = [UIView new];
        vc.windowBarView = [UIView new];
        vc.navigationBarTopConstraint = [NSLayoutConstraint new];
        vc.appSceneVC = [AppSceneViewController new];
        vc.appSceneVC.view = [UIView new];
        vc.isMaximized = YES;
        host.subviews = @[vc.view];

        MultitaskDockManager.shared.isCollapsed = YES;
        [vc updateVerticalConstraints];
        require(vc.navigationBar.hidden && vc.windowBarView.hidden, @"A collapsed dock must hide the complete window header");
        require(CGRectEqualToRect(vc.view.frame, CGRectMake(0, -24, 1024, 768)), @"Running fullscreen geometry changed");

        vc.hasAppTerminated = YES;
        [vc updateVerticalConstraints];
        require(!vc.navigationBar.hidden && vc.navigationBar.alpha == 1, @"Terminated app lost its close controls");
        require(!vc.windowBarView.hidden && vc.windowBarView.alpha == 1, @"Terminated app lost its opaque header");
        require(vc.activatedVerticalConstraints.lastObject.constant == 56, @"Top header must cover an additional 12pt");
        require(vc.navigationBarTopConstraint.constant == 6, @"Top controls must retain 6pt below them");
        require(CGRectEqualToRect(vc.view.frame, CGRectMake(0, -12, 1024, 736)), @"Header must extend upward while preserving the bottom edge");
        require(vc.view.frame.origin.y + [vc windowBarHeight] == 44, @"Header extension moved the guest content down");

        [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCMultitaskBottomWindowBar"];
        [vc updateVerticalConstraints];
        require(!vc.navigationBar.hidden && CGRectGetMaxY(vc.view.frame) == 724, @"Bottom controls overlap the home indicator");
        require([vc windowBarHeight] == 44 && vc.navigationBarTopConstraint.constant == 0, @"Bottom bar dimensions changed");

        window.bounds = CGRectMake(0, 0, 768, 1024);
        window.safeAreaInsets = (UIEdgeInsets){28, 8, 20, 8};
        host.frame = CGRectMake(0, 28, 768, 996);
        [host hostSceneDidActivate:[NSNotification notificationWithName:@"active" object:window.windowScene]];
        require(host.needsLayout, @"Returning to the host must request layout without guest callbacks");
        [host layoutSubviews];
        require(CGRectEqualToRect(vc.view.frame, CGRectMake(8, 0, 752, 976)), @"Dead app geometry did not follow rotation and safe area changes");
        host.needsLayout = NO;
        [host hostSceneDidActivate:[NSNotification notificationWithName:@"active" object:[WindowScene new]]];
        require(!host.needsLayout, @"Another window scene changed this host");
        [host safeAreaInsetsDidChange];
        require(host.needsLayout, @"Safe area changes must request a new host layout");

        [NSUserDefaults.lcSharedDefaults setBool:NO forKey:@"LCMultitaskBottomWindowBar"];
        UIDevice.currentDevice.userInterfaceIdiom = 0;
        window.bounds = window.frame = CGRectMake(0, 0, 390, 844);
        window.safeAreaInsets = (UIEdgeInsets){59, 0, 34, 0};
        host.frame = CGRectMake(0, 59, 390, 785);
        vc.hasAppTerminated = NO;
        MultitaskDockManager.shared.isCollapsed = NO;
        [vc updateVerticalConstraints];
        require(CGRectEqualToRect(vc.view.frame, CGRectMake(0, -12, 390, 797)), @"Phone header did not cover the exposed top edge");
        require(host.frame.origin.y + vc.view.frame.origin.y + [vc windowBarHeight] == 103, @"Phone guest content moved below its previous top edge");
        require(vc.view.frame.origin.y + vc.navigationBarTopConstraint.constant == -6, @"Phone title and controls did not move up 6pt");

        window.bounds = window.frame = CGRectMake(0, 0, 844, 390);
        window.safeAreaInsets = (UIEdgeInsets){0, 59, 21, 59};
        window.windowScene.interfaceOrientation = 3;
        host.frame = window.bounds;
        [host layoutSubviews];
        require(CGRectEqualToRect(vc.view.frame, window.bounds), @"Header must not extend beyond a landscape screen");

        window.bounds = window.frame = CGRectMake(0, 0, 390, 844);
        window.safeAreaInsets = (UIEdgeInsets){59, 0, 34, 0};
        window.windowScene.interfaceOrientation = 0;
        host.frame = window.bounds;
        host.bounds = window.bounds;
        vc.isMaximized = NO;
        CGRect floatingFrame = [vc initialWindowFrame];
        require(CGRectEqualToRect(floatingFrame, CGRectMake(35, 148, 320, 536)), @"A new floating window must grow upward by 12pt");
        require(floatingFrame.origin.y + [vc windowBarHeight] == 204, @"A new floating window moved the original guest content edge");
        require(CGRectGetMaxY(floatingFrame) == 684, @"A new floating window moved the original bottom edge");
        vc.originalFrame = CGRectMake(0, 0, 320, 536);
        vc.view.center = CGPointMake(195, 250);
        [vc updateWindowedFrameWithSettings:[UIMutableApplicationSceneSettings new]];
        require(CGRectEqualToRect(vc.view.frame, CGRectMake(35, 47, 320, 536)), @"A floating top header must be allowed to cover the same 12pt edge");
        [vc updateVerticalConstraints];
        require([vc windowBarHeight] == 56 && vc.navigationBarTopConstraint.constant == 6, @"Floating windows lost the padded header");
        [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCMultitaskBottomWindowBar"];
        [vc updateWindowedFrameWithSettings:[UIMutableApplicationSceneSettings new]];
        [vc updateVerticalConstraints];
        require(vc.view.frame.origin.y == 59 && [vc windowBarHeight] == 44, @"Floating bottom bars changed their safe area or height");
        require(CGRectEqualToRect([vc initialWindowFrame], CGRectMake(35, 160, 320, 524)), @"A new floating bottom bar must keep the original centered frame");

        CGRect restoredFrame = CGRectMake(30, 40, 320, 524);
        vc.isMaximized = NO;
        vc.view.frame = restoredFrame;
        [host layoutSubviews];
        require(CGRectEqualToRect(vc.view.frame, restoredFrame), @"Restored window snapped back to maximized");
        vc.isMaximized = YES;
        vc.view.transform = CGAffineTransformMakeScale(0.1, 0.1);
        [host layoutSubviews];
        require(CGRectEqualToRect(vc.view.frame, restoredFrame), @"Layout interfered with the minimize animation");
        vc.view.transform = CGAffineTransformIdentity;
        vc.view.window = nil;
        [host layoutSubviews];
        require(CGRectEqualToRect(vc.view.frame, restoredFrame), @"Detached window geometry was destroyed");
        [NSUserDefaults.lcSharedDefaults removeObjectForKey:@"LCMultitaskBottomWindowBar"];
        puts("Guest window header coverage, spacing, and host geometry regressions passed");
    }
    return 0;
}
