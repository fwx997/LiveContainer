#import <UIKit/UIKit.h>

@interface LCCompanionBridge : NSObject
+ (NSArray *)availableApps;
+ (NSString *)currentAppIdentifier;
+ (NSString *)switchBlockReason;
+ (UIImage *)navigationIconForApp:(NSString *)identifier;
+ (UIImage *)currentNavigationIcon;
+ (UIButton *)navigationButton;
+ (UIMenu *)navigationMenu;
+ (BOOL)openApp:(NSString *)identifier;
@end

static NSString *const LCCompanionMenuID = @"lc.companion.switch";

@implementation LCCompanionBridge
+ (NSArray *)availableApps {
    return @[@{@"identifier": @"ui", @"name": @"LiveContainer"},
             @{@"identifier": @"builtinSideStore", @"name": @"SideStore"},
             @{@"identifier": @"builtinSideInstaller", @"name": @"SideInstaller"}];
}
+ (NSString *)currentAppIdentifier {
    if ([NSProcessInfo.processInfo.arguments containsObject:@"grouped"]) return @"ui";
    return [NSProcessInfo.processInfo.arguments containsObject:@"dark"] ? @"builtinSideInstaller" : @"builtinSideStore";
}
+ (NSString *)switchBlockReason { return nil; }
+ (BOOL)openApp:(NSString *)identifier { return YES; }
+ (UIImage *)navigationIconForApp:(NSString *)identifier {
    UIImage *source = [UIImage imageNamed:identifier];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(26, 26)];
    return [[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 26, 26) cornerRadius:6] addClip];
        [source drawInRect:CGRectMake(0, 0, 26, 26)];
    }] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}
// INSERT_MENU
@end

@interface PreviewDelegate : UIResponder <UIApplicationDelegate, UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIButton *switchButton;
@property(nonatomic, strong) UIButton *installButton;
@end

@implementation PreviewDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    return YES;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    BOOL dark = [NSProcessInfo.processInfo.arguments containsObject:@"dark"];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = dark ? [UIColor colorWithRed:0 green:0.06 blue:0.22 alpha:1] : UIColor.whiteColor;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(20, 175, 800, 250)];
    card.backgroundColor = dark ? UIColor.systemBlueColor : UIColor.systemCyanColor;
    card.layer.cornerRadius = 30;
    [root.view addSubview:card];
    UILabel *background = [[UILabel alloc] initWithFrame:CGRectMake(50, 220, 600, 90)];
    background.text = @"LiveContainer";
    background.textColor = UIColor.whiteColor;
    background.font = [UIFont boldSystemFontOfSize:40];
    [root.view addSubview:background];
    UIButton *button = [LCCompanionBridge navigationButton];
    self.switchButton = button;
    BOOL grouped = [NSProcessInfo.processInfo.arguments containsObject:@"grouped"];
    UIBarButtonItem *switcher = [[UIBarButtonItem alloc] initWithCustomView:button];
    root.navigationItem.leftBarButtonItems = @[switcher];
    if (grouped) {
        self.installButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.installButton setImage:[UIImage systemImageNamed:@"plus"] forState:UIControlStateNormal];
        [NSLayoutConstraint activateConstraints:@[[self.installButton.widthAnchor constraintEqualToConstant:44],
                                                   [self.installButton.heightAnchor constraintEqualToConstant:44]]];
        UIBarButtonItem *install = [[UIBarButtonItem alloc] initWithCustomView:self.installButton];
        root.navigationItem.leftBarButtonItems = @[install, switcher];
    }
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:root];
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [button performPrimaryAction];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self recordLayout];
        });
    });
}

- (void)recordLayout {
    NSMutableArray<UIView *> *pending = [self.window.windowScene.windows mutableCopy];
    NSMutableArray *labels = [NSMutableArray array];
    NSMutableArray *classes = [NSMutableArray array];
    NSUInteger images = 0;
    while (pending.count) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];
        [pending addObjectsFromArray:view.subviews];
        if (view.hidden || view.alpha == 0) continue;
        [classes addObject:NSStringFromClass(view.class)];
        if ([view isKindOfClass:UILabel.class] && ((UILabel *)view).text.length) [labels addObject:((UILabel *)view).text];
        if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) images++;
    }
    CGRect buttonFrame = [self.switchButton convertRect:self.switchButton.bounds toView:self.window];
    CGRect installFrame = self.installButton ? [self.installButton convertRect:self.installButton.bounds toView:self.window] : CGRectZero;
    NSDictionary *result = @{
        @"systemMenu": @(self.switchButton.showsMenuAsPrimaryAction && self.switchButton.contextMenuInteraction != nil),
        @"menuTitle": self.switchButton.menu.title,
        @"currentApp": LCCompanionBridge.currentAppIdentifier,
        @"visibleLabels": labels,
        @"viewClasses": classes,
        @"imageViews": @(images),
        @"buttonFrame": NSStringFromCGRect(buttonFrame),
        @"installButtonFrame": NSStringFromCGRect(installFrame),
        @"grouped": @(self.installButton != nil),
        @"buttonGap": @(self.installButton ? CGRectGetMinX(buttonFrame) - CGRectGetMaxX(installFrame) : 0)
    };
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[documents URLByAppendingPathComponent:@"layout.json"] atomically:YES];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PreviewDelegate.class)); }
}
