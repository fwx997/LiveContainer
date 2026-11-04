#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *lcAppUrlScheme = @"livecontainer2";
static NSUInteger directCalls;
static NSUInteger foregroundCalls;
static NSUInteger backgroundCalls;
static BOOL sceneRunning;
static BOOL directAccepts;

@interface LCSharedUtils : NSObject
+ (BOOL)handleSideStoreCellularCallback:(NSURL*)url;
@end

@implementation LCSharedUtils
// INSERT_PRODUCTION_ROUTER
@end

static BOOL handleDirect(id object, SEL selector, NSURL *url) {
    directCalls++;
    return directAccepts;
}

static BOOL handleForeground(id object, SEL selector, NSURL *url) {
    foregroundCalls++;
    return sceneRunning;
}

static void handleBackground(id object, SEL selector, NSURL *url) {
    backgroundCalls++;
}

static void registerHandler(const char *name, const char *selector, IMP implementation, const char *encoding) {
    Class type = objc_allocateClassPair(NSObject.class, name, 0);
    class_addMethod(object_getClass(type), sel_registerName(selector), implementation, encoding);
    objc_registerClassPair(type);
}

static void require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"%@", message);
        exit(1);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *scenario = [NSString stringWithUTF8String:argv[1]];
        BOOL cold = [scenario isEqualToString:@"cold"];
        BOOL direct = [scenario hasPrefix:@"direct"];
        directAccepts = [scenario isEqualToString:@"direct"];
        sceneRunning = [scenario isEqualToString:@"foreground"];
        if (direct) {
            registerHandler("SSCellularRefreshBridge", "handleCallback:", (IMP)handleDirect, "B@:@");
        }
        if (!cold) {
            registerHandler("AppSceneViewController", "deliverSideStoreCellularCallback:", (IMP)handleForeground, "B@:@");
            registerHandler("LCRefreshHandler", "handleCellularCallback:", (IMP)handleBackground, "v@:@");
        }

        NSString *urlString = @"livecontainer2://cellular-refresh/success?token=test";
        BOOL wrongScheme = [scenario isEqualToString:@"wrong-scheme"];
        BOOL wrongHost = [scenario isEqualToString:@"wrong-host"];
        if (wrongScheme) { urlString = @"livecontainer://cellular-refresh/success?token=test"; }
        if (wrongHost) { urlString = @"livecontainer2://refresh-all"; }
        BOOL handled = [LCSharedUtils handleSideStoreCellularCallback:[NSURL URLWithString:urlString]];
        BOOL invalid = wrongScheme || wrongHost;
        require(handled != invalid, @"Unexpected callback consumption");
        require(directCalls == (direct && !invalid ? 1 : 0), @"Wrong direct bridge route");
        require(foregroundCalls == (!cold && !directAccepts && !invalid ? 1 : 0), @"Wrong foreground guest route");
        require(backgroundCalls == (!cold && !directAccepts && !invalid ? 1 : 0), @"Wrong background route");
    }
    return 0;
}
