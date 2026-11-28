#import <UIKit/UIKit.h>

@interface LCCompanionBridge : NSObject
+ (NSArray *)availableApps;
+ (NSString *)currentAppIdentifier;
+ (NSString *)switchBlockReason;
+ (UIImage *)navigationIconForApp:(NSString *)identifier;
+ (void)presentNavigationMenuFromView:(UIView *)sourceView;
+ (BOOL)openApp:(NSString *)identifier;
@end

// INSERT_PICKER

@implementation LCCompanionBridge
+ (NSArray *)availableApps {
    return @[@{@"identifier": @"ui", @"name": @"LiveContainer"},
             @{@"identifier": @"builtinSideStore", @"name": @"SideStore"},
             @{@"identifier": @"builtinSideInstaller", @"name": @"SideInstaller"}];
}
+ (NSString *)currentAppIdentifier {
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
// INSERT_PRESENTATION
@end

@interface PreviewDelegate : UIResponder <UIApplicationDelegate, UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
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
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[LCCompanionBridge navigationIconForApp:LCCompanionBridge.currentAppIdentifier] forState:UIControlStateNormal];
    [NSLayoutConstraint activateConstraints:@[[button.widthAnchor constraintEqualToConstant:44],
                                               [button.heightAnchor constraintEqualToConstant:44]]];
    UIView *space = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 1)];
    UIBarButtonItem *spacing = [[UIBarButtonItem alloc] initWithCustomView:space];
    if (@available(iOS 26.0, *)) spacing.hidesSharedBackground = YES;
    root.navigationItem.leftBarButtonItems = @[spacing, [[UIBarButtonItem alloc] initWithCustomView:button]];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:root];
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [LCCompanionBridge presentNavigationMenuFromView:button];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self recordLayout];
        });
    });
}

- (void)recordLayout {
    LCCompanionPicker *picker = (LCCompanionPicker *)self.window.rootViewController.presentedViewController;
    NSMutableArray *rows = [NSMutableArray array];
    NSUInteger separators = 0;
    for (UITableViewCell *cell in picker.tableView.visibleCells) {
        [cell layoutIfNeeded];
        UIStackView *row = (UIStackView *)cell.contentView.subviews.firstObject;
        UILabel *name = (UILabel *)row.arrangedSubviews.lastObject;
        CGRect nameFrame = [name convertRect:name.bounds toView:cell.contentView];
        [rows addObject:@{@"title": name.text, @"height": @(cell.bounds.size.height), @"titleX": @(nameFrame.origin.x),
                         @"leftMargin": @(row.frame.origin.x), @"rightMargin": @(cell.contentView.bounds.size.width - CGRectGetMaxX(row.frame))}];
        for (UIView *view in cell.contentView.subviews) {
            if ([view.accessibilityIdentifier isEqualToString:@"lc.companion.separator"]) separators++;
        }
    }
    NSDictionary *result = @{
        @"rows": rows,
        @"headerHeight": @(picker.tableView.tableHeaderView.bounds.size.height),
        @"footerHeight": @(picker.tableView.tableFooterView.bounds.size.height),
        @"contentHeight": @(picker.preferredContentSize.height),
        @"topInset": @(picker.tableView.contentInset.top),
        @"adjustedTopInset": @(picker.tableView.adjustedContentInset.top),
        @"separatorX": @(picker.tableView.separatorInset.left),
        @"separatorCount": @(separators),
        @"nativePopoverBackground": @(picker.popoverPresentationController.popoverBackgroundViewClass == Nil),
        @"tableBackgroundAlpha": @(CGColorGetAlpha(picker.tableView.backgroundColor.CGColor)),
        @"arrowDirection": @(picker.popoverPresentationController.arrowDirection),
        @"sourceRect": NSStringFromCGRect(picker.popoverPresentationController.sourceRect),
        @"popover": @([picker.presentationController isKindOfClass:UIPopoverPresentationController.class]),
        @"pickerFrame": NSStringFromCGRect([picker.view convertRect:picker.view.bounds toView:self.window])
    };
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
        writeToURL:[documents URLByAppendingPathComponent:@"layout.json"] atomically:YES];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(PreviewDelegate.class)); }
}
