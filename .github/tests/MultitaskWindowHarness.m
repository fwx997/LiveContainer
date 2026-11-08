#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Minimal host views let the production layout run after a guest stops invoking
// scene update blocks, without launching an extension or a private UIKit scene.
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;
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
@property UIView *view, *navigationBar;
@property AppSceneViewController *appSceneVC;
@property BOOL isMaximized, hasAppTerminated;
@property NSArray<NSLayoutConstraint *> *activatedVerticalConstraints;
@end
@implementation DecoratedAppSceneViewController
// INSERT_MAXIMIZED_FRAME
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
        vc.appSceneVC = [AppSceneViewController new];
        vc.appSceneVC.view = [UIView new];
        vc.isMaximized = YES;
        host.subviews = @[vc.view];

        MultitaskDockManager.shared.isCollapsed = YES;
        [vc updateVerticalConstraints];
        require(vc.navigationBar.hidden, @"A running maximized app should still hide its bar with the dock");
        require(CGRectEqualToRect(vc.view.frame, CGRectMake(0, -24, 1024, 768)), @"Running fullscreen geometry changed");

        vc.hasAppTerminated = YES;
        [vc updateVerticalConstraints];
        require(!vc.navigationBar.hidden && vc.navigationBar.alpha == 1, @"Terminated app lost its close controls");
        require(vc.activatedVerticalConstraints.lastObject.constant == 44, @"Terminated controls lost their tap height");
        require(CGRectEqualToRect(vc.view.frame, CGRectMake(0, 0, 1024, 724)), @"Terminated controls overlap the status bar or home indicator");

        [NSUserDefaults.lcSharedDefaults setBool:YES forKey:@"LCMultitaskBottomWindowBar"];
        [vc updateVerticalConstraints];
        require(!vc.navigationBar.hidden && CGRectGetMaxY(vc.view.frame) == 724, @"Bottom controls overlap the home indicator");

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
        puts("Terminated guest window controls and host geometry regression passed");
    }
    return 0;
}
