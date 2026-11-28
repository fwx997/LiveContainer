#import <Foundation/Foundation.h>
#import "LCSharedUtils.h"

static NSURL *TestRoot;
static NSBundle *TestBundle;
static NSString *TestDefaults;

@implementation LCSharedUtils
+ (NSURL *)appGroupPath { return TestRoot; }
+ (NSString *)appGroupID { return TestDefaults; }
+ (NSBundle *)hostAppBundle { return TestBundle; }
@end

// INSERT_RECOVERY_SOURCE

static void expect(BOOL result, NSString *label) {
    if (!result) { NSLog(@"FAILED: %@", label); exit(1); }
}

static void fixtureWrite(NSString *text, NSURL *url) {
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    expect([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil], @"write fixture");
}

static NSURL *fixture(NSString *name) {
    return [TestRoot URLByAppendingPathComponent:name];
}

static void makeBundle(void) {
    NSURL *bundle = fixture(@"Fixture.app");
    fixtureWrite(@"core", [bundle URLByAppendingPathComponent:@"Recovery/siboot-aarch64"]);
    fixtureWrite(@"__BUILD__ __IPA_SHA256__ __CORE_SHA256__", [bundle URLByAppendingPathComponent:@"Recovery/install.sh"]);
    fixtureWrite(@"local entry", [bundle URLByAppendingPathComponent:@"Recovery/install-local.sh"]);
    for (NSString *path in @[@"Frameworks/SideStoreApp.framework", @"Frameworks/SideInstallerApp.framework", @"PlugIns/LiveProcess.appex", @"PlugIns/SideInstallerLiveActivity.appex"]) {
        NSURL *child = [bundle URLByAppendingPathComponent:path];
        fixtureWrite(@"binary", [child URLByAppendingPathComponent:@"Executable"]);
        [@{@"CFBundleExecutable": @"Executable"} writeToURL:[child URLByAppendingPathComponent:@"Info.plist"] error:nil];
    }
    fixtureWrite(@"binary", [bundle URLByAppendingPathComponent:@"Executable"]);
    NSDictionary *info = @{@"CFBundleIdentifier": @"com.livecontainer.recovery-test", @"CFBundleVersion": @"20261128.88", @"CFBundleExecutable": @"Executable",
        @"LCEmbeddedApps": @[@"SideStore", @"SideInstaller"],
        @"LCRecoveryBootstrapSHA256": LCRecoveryHash([bundle URLByAppendingPathComponent:@"Recovery/siboot-aarch64"], nil)};
    expect([info writeToURL:[bundle URLByAppendingPathComponent:@"Info.plist"] error:nil], @"bundle info");
    TestBundle = [NSBundle bundleWithURL:bundle];
}

static void cacheScenarios(void) {
    NSError *error = nil;
    NSURL *root = LCRecoveryRoot(&error);
    NSURL *ipa = fixture(@"download.ipa");
    fixtureWrite(@"download A", ipa);
    expect(LCRecoveryCache(ipa, TestBundle.bundleURL, root, &error), @"capture raw package");
    NSURL *cached = [root URLByAppendingPathComponent:@"cache/LiveContainer+SideStore+SideInstaller.ipa"];
    NSString *first = LCRecoveryHash(cached, nil);
    for (int iteration = 0; iteration < 8; iteration++) {
        fixtureWrite([NSString stringWithFormat:@"download %d", iteration], ipa);
        error = nil;
        expect(LCRecoveryCache(ipa, TestBundle.bundleURL, root, &error), @"replace current cache");
        expect(![NSFileManager.defaultManager fileExistsAtPath:[root URLByAppendingPathComponent:@"cache-pending"].path], @"no cache staging remains");
    }
    expect(![first isEqualToString:LCRecoveryHash(cached, nil)], @"current package replaced");
    NSString *latest = LCRecoveryHash(cached, nil);
    fixtureWrite(@"corrupt core", [TestBundle.bundleURL URLByAppendingPathComponent:@"Recovery/siboot-aarch64"]);
    error = nil;
    expect(!LCRecoveryCache(ipa, TestBundle.bundleURL, root, &error), @"reject corrupt core");
    expect([latest isEqualToString:LCRecoveryHash(cached, nil)], @"keep previous valid cache on failure");
    fixtureWrite(@"core", [TestBundle.bundleURL URLByAppendingPathComponent:@"Recovery/siboot-aarch64"]);
    expect([[LCRecoveryBackup status][@"cacheBuild"] isEqualToString:@"20261128.88"], @"report cached version");
}

static void sanitationScenarios(void) {
    NSURL *bundle = fixture(@"Sanitize.app");
    fixtureWrite(@"secret", [bundle URLByAppendingPathComponent:@"ALTCertificate.p12"]);
    fixtureWrite(@"pairing", [bundle URLByAppendingPathComponent:@"Frameworks/A.framework/ALTPairingFile.dat"]);
    fixtureWrite(@"ordinary resource", [bundle URLByAppendingPathComponent:@"Resources/resource.dat"]);
    [@{@"ALTCertificateID": @"secret-id", @"LCCombinedBootstrapCertificatePassword": @"secret-password", @"CFBundleVersion": @"7"}
        writeToURL:[bundle URLByAppendingPathComponent:@"Info.plist"] error:nil];
    expect(LCRecoveryContainsSensitive(bundle), @"detect embedded credentials");
    NSError *error = nil;
    expect(LCRecoverySanitizeBundle(bundle, &error), @"sanitize installed fallback");
    expect(!LCRecoveryContainsSensitive(bundle), @"no credentials remain");
    expect([NSFileManager.defaultManager fileExistsAtPath:[bundle URLByAppendingPathComponent:@"Resources/resource.dat"].path], @"keep application resources");
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[bundle URLByAppendingPathComponent:@"Info.plist"]];
    expect(info[@"ALTCertificateID"] == nil && info[@"LCCombinedBootstrapCertificatePassword"] == nil, @"remove credential hints");
    expect([info[@"CFBundleVersion"] isEqualToString:@"7"], @"keep version metadata");
}

static void automaticCacheScenarios(void) {
    NSError *error = nil;
    NSURL *root = LCRecoveryRoot(&error);
    NSURL *cache = [root URLByAppendingPathComponent:@"cache" isDirectory:YES];
    NSURL *exported = fixture(@"ExistingExport/livecontainer/LiveContainer-triple-local.zip");
    fixtureWrite(@"last complete recovery package", exported);
    NSData *bookmark = [exported.URLByDeletingLastPathComponent bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    expect(bookmark != nil, @"configure existing recovery folder");
    [LCRecoveryDefaults() setObject:bookmark forKey:LCRecoveryBookmarkKey];
    NSString *original = LCRecoveryHash(exported, nil);
    expect(LCRecoveryValidateAutomaticCache(root, @"20261128.88", &error), @"accept this update's intact cached package");
    expect(!LCRecoverySave(root, @"20261128.89", &error), @"reject another update's cached build before export");
    expect([error.localizedDescription containsString:@"备份缓存已变化"], @"reject precisely the build mismatch");
    expect([original isEqualToString:LCRecoveryHash(exported, nil)], @"wrong build does not replace existing export");
    fixtureWrite(@"damaged IPA", [cache URLByAppendingPathComponent:LCRecoveryIPA]);
    error = nil;
    expect(!LCRecoverySave(root, @"20261128.88", &error), @"corrupt automatic cache never falls back to installed bundle");
    expect([error.localizedDescription containsString:@"备份缓存校验失败"], @"report corruption rather than trying installed fallback");
    expect([original isEqualToString:LCRecoveryHash(exported, nil)], @"damaged cache leaves previous recovery untouched");
    expect([LCRecoveryHash([cache URLByAppendingPathComponent:LCRecoveryIPA], nil) isEqualToString:LCRecoveryHash(fixture(@"download.ipa"), nil)] == NO,
        @"failed auto-save did not replace the damaged cache with another input");
    error = nil;
    expect(LCRecoveryCache(fixture(@"download.ipa"), TestBundle.bundleURL, root, &error), @"later verified download repairs cache");
}

static void publicationScenarios(void) {
    NSURL *stage = fixture(@"Export");
    NSURL *destination = fixture(@"External/livecontainer");
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *name in @[LCRecoveryIPA, @"install-local.sh", @"recovery.json", LCRecoveryZIP]) fixtureWrite([@"new " stringByAppendingString:name], [stage URLByAppendingPathComponent:name]);
    fixtureWrite(@"old complete ZIP", [destination URLByAppendingPathComponent:LCRecoveryZIP]);
    NSURL *lock = [destination URLByAppendingPathComponent:@".livecontainer-write-lock"];
    [manager createDirectoryAtURL:lock withIntermediateDirectories:NO attributes:nil error:nil];
    NSError *error = nil;
    expect(!LCRecoveryPublish(stage, destination, &error), @"reject simultaneous folder writer");
    expect([manager fileExistsAtPath:lock.path], @"do not steal the other writer lock");
    expect([[NSString stringWithContentsOfURL:[destination URLByAppendingPathComponent:LCRecoveryZIP] encoding:NSUTF8StringEncoding error:nil] isEqualToString:@"old complete ZIP"], @"old ZIP survived lock rejection");
    [manager removeItemAtURL:lock error:nil];
    NSURL *stale = [destination URLByAppendingPathComponent:@".livecontainer-pending-app/partial"];
    fixtureWrite(@"aborted export", stale);
    error = nil;
    expect(LCRecoveryPublish(stage, destination, &error), @"publish complete package");
    expect(![manager fileExistsAtPath:lock.path] && ![manager fileExistsAtPath:stale.path], @"current task leftovers reclaimed");
    NSString *latest = LCRecoveryHash([destination URLByAppendingPathComponent:LCRecoveryZIP], nil);
    [manager removeItemAtURL:[stage URLByAppendingPathComponent:LCRecoveryZIP] error:nil];
    error = nil;
    expect(!LCRecoveryPublish(stage, destination, &error), @"reject incomplete export");
    expect([latest isEqualToString:LCRecoveryHash([destination URLByAppendingPathComponent:LCRecoveryZIP], nil)], @"previous complete ZIP retained on copy failure");
}

int main(int argc, char **argv) {
    @autoreleasepool {
        TestRoot = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
        TestDefaults = [@"com.livecontainer.recovery-tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        makeBundle();
        cacheScenarios();
        automaticCacheScenarios();
        sanitationScenarios();
        publicationScenarios();
        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:TestDefaults];
        printf("Recovery production cache, export, locking and credential checks passed.\n");
    }
    return 0;
}
