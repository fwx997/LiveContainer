#import "LCSharedUtils.h"
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>

@interface NSObject (LCRecoveryArchiver)
- (NSData *)zippedDataForURL:(NSURL *)url;
@end

static NSString *const LCRecoveryIPA = @"LiveContainer+SideStore+SideInstaller.ipa";
static NSString *const LCRecoveryZIP = @"LiveContainer-triple-local.zip";
static NSString *const LCRecoveryErrorDomain = @"LCRecoveryBackup";
static NSString *const LCRecoveryBookmarkKey = @"LCRecoveryDirectoryBookmark";
static NSString *const LCRecoveryAutomaticKey = @"LCRecoveryAutomatic";
static NSString *const LCRecoveryStatusKey = @"LCRecoveryStatus";
static BOOL LCRecoveryBusy;

static NSError *LCRecoveryError(NSString *message) {
    return [NSError errorWithDomain:LCRecoveryErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSUserDefaults *LCRecoveryDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:LCSharedUtils.appGroupID];
}

static dispatch_queue_t LCRecoveryQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.livecontainer.recovery", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static NSURL *LCRecoveryRoot(NSError **error) {
    NSURL *group = LCSharedUtils.appGroupPath;
    if (!group) { if (error) *error = LCRecoveryError(@"无法访问本地备份缓存。"); return nil; }
    NSURL *root = [group URLByAppendingPathComponent:@"LiveContainer/RecoveryBackup" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    [root setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return root;
}

static NSString *LCRecoveryHash(NSURL *url, NSError **error) {
    NSInputStream *stream = [NSInputStream inputStreamWithURL:url];
    [stream open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t bytes[65536];
    NSInteger count;
    while ((count = [stream read:bytes maxLength:sizeof(bytes)]) > 0) CC_SHA256_Update(&context, bytes, (CC_LONG)count);
    NSError *readError = stream.streamError;
    [stream close];
    if (count < 0 || readError) { if (error) *error = readError ?: LCRecoveryError(@"无法读取备份文件。"); return nil; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *result = [NSMutableString stringWithCapacity:64];
    for (NSUInteger index = 0; index < sizeof(digest); index++) [result appendFormat:@"%02x", digest[index]];
    return result;
}

static BOOL LCRecoveryWriteJSON(NSDictionary *value, NSURL *url, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}

static NSDictionary *LCRecoveryReadJSON(NSURL *url) {
    NSData *data = [NSData dataWithContentsOfURL:url];
    id result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : @{};
}

static void LCRecoveryRecord(NSDictionary *changes) {
    NSUserDefaults *defaults = LCRecoveryDefaults();
    NSMutableDictionary *status = [[defaults dictionaryForKey:LCRecoveryStatusKey] mutableCopy] ?: [NSMutableDictionary new];
    [status addEntriesFromDictionary:changes];
    [defaults setObject:status forKey:LCRecoveryStatusKey];
}

static BOOL LCRecoveryValidBuild(NSString *build) {
    if (![build isKindOfClass:NSString.class] || !build.length) return NO;
    return [build rangeOfString:@"^[0-9]+(\\.[0-9]+){0,2}$" options:NSRegularExpressionSearch].location != NSNotFound;
}

static BOOL LCRecoverySensitive(NSURL *file) {
    NSString *name = file.lastPathComponent.lowercaseString;
    return [name hasSuffix:@".p12"] || [name hasSuffix:@".pfx"] || [name hasSuffix:@".mobiledevicepairing"]
        || [name isEqualToString:@"altpairingfile.dat"] || [name hasPrefix:@"pairingfile_"]
        || [name isEqualToString:@"rp_pairing_file.plist"] || [name isEqualToString:@"combined_pairing_file.plist"];
}

static BOOL LCRecoveryContainsSensitive(NSURL *bundle) {
    NSDirectoryEnumerator *files = [NSFileManager.defaultManager enumeratorAtURL:bundle includingPropertiesForKeys:nil options:0 errorHandler:nil];
    for (NSURL *file in files) if (LCRecoverySensitive(file)) return YES;
    return NO;
}

static BOOL LCRecoverySanitizeBundle(NSURL *bundle, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray *files = [[manager enumeratorAtURL:bundle includingPropertiesForKeys:nil options:0 errorHandler:nil] allObjects];
    for (NSURL *file in files) {
        if (LCRecoverySensitive(file) && ![manager removeItemAtURL:file error:error]) return NO;
        if (![file.lastPathComponent isEqualToString:@"Info.plist"]) continue;
        NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfURL:file] mutableCopy];
        if (!info) continue;
        for (NSString *key in @[@"ALTCertificateID", @"LCCombinedBootstrapCertificatePassword", @"LCCombinedBootstrapCertificateSerial", @"LCCombinedSelfSignReceipt"]) [info removeObjectForKey:key];
        if (![info writeToURL:file error:error]) return NO;
    }
    return YES;
}

static BOOL LCRecoveryArchive(NSURL *directory, NSURL *output, NSError **error) {
    dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_LAZY);
    id archiver = [NSClassFromString(@"PKZipArchiver") new];
    if (![archiver respondsToSelector:@selector(zippedDataForURL:)]) {
        if (error) *error = LCRecoveryError(@"系统无法创建本地恢复包。");
        return NO;
    }
    NSData *archive = [archiver zippedDataForURL:directory];
    if (!archive.length) { if (error) *error = LCRecoveryError(@"创建本地恢复包失败。"); return NO; }
    return [archive writeToURL:output options:NSDataWritingAtomic error:error];
}

static BOOL LCRecoveryHasExecutable(NSURL *bundle) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[bundle URLByAppendingPathComponent:@"Info.plist"]];
    NSString *name = info[@"CFBundleExecutable"];
    if (![name isKindOfClass:NSString.class] || !name.length || ![name isEqualToString:name.lastPathComponent]) return NO;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[bundle URLByAppendingPathComponent:name].path error:nil];
    return [attributes[NSFileType] isEqualToString:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] > 0;
}

static NSDictionary *LCRecoveryBundleInfo(NSURL *bundle, NSError **error) {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[bundle URLByAppendingPathComponent:@"Info.plist"]];
    NSArray *apps = info[@"LCEmbeddedApps"];
    if (![apps isKindOfClass:NSArray.class] || ![apps containsObject:@"SideStore"] || ![apps containsObject:@"SideInstaller"]
        || !LCRecoveryValidBuild(info[@"CFBundleVersion"]) || !LCRecoveryHasExecutable(bundle)) {
        if (error) *error = LCRecoveryError(@"只能备份完整的三合一安装包。");
        return nil;
    }
    for (NSString *path in @[@"Frameworks/SideStoreApp.framework", @"Frameworks/SideInstallerApp.framework", @"PlugIns/LiveProcess.appex", @"PlugIns/SideInstallerLiveActivity.appex"]) {
        if (!LCRecoveryHasExecutable([bundle URLByAppendingPathComponent:path])) {
            if (error) *error = LCRecoveryError(@"安装包的内置应用或扩展不完整，原备份未被替换。");
            return nil;
        }
    }
    for (NSString *path in @[@"Recovery/install.sh", @"Recovery/install-local.sh", @"Recovery/siboot-aarch64"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[bundle URLByAppendingPathComponent:path].path]) {
            if (error) *error = LCRecoveryError(@"当前安装包缺少离线恢复文件，请先安装完整新版。");
            return nil;
        }
    }
    NSString *expected = info[@"LCRecoveryBootstrapSHA256"];
    NSString *actual = LCRecoveryHash([bundle URLByAppendingPathComponent:@"Recovery/siboot-aarch64"], error);
    if (![expected isKindOfClass:NSString.class] || expected.length != 64 || ![expected isEqualToString:actual]) {
        if (error && !*error) *error = LCRecoveryError(@"本地安装器校验失败。");
        return nil;
    }
    return info;
}

static BOOL LCRecoveryCopyVerified(NSURL *source, NSURL *destination, NSString *expected, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager copyItemAtURL:source toURL:destination error:error]) return NO;
    NSString *actual = LCRecoveryHash(destination, error);
    if (actual && [actual isEqualToString:expected]) return YES;
    if (error && !*error) *error = LCRecoveryError(@"复制后的文件校验失败，原备份未被替换。");
    return NO;
}

static BOOL LCRecoveryReplace(NSURL *source, NSURL *destination, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager fileExistsAtPath:destination.path]) return [manager moveItemAtURL:source toURL:destination error:error];
    return [manager replaceItemAtURL:destination withItemAtURL:source backupItemName:nil options:0 resultingItemURL:nil error:error];
}

static BOOL LCRecoveryCache(NSURL *ipa, NSURL *bundle, NSURL *root, NSError **error) {
    NSDictionary *info = LCRecoveryBundleInfo(bundle, error);
    if (!info) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *stage = [root URLByAppendingPathComponent:@"cache-pending" isDirectory:YES];
    [manager removeItemAtURL:stage error:nil];
    if (![manager createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSURL *destination = [stage URLByAppendingPathComponent:LCRecoveryIPA];
    BOOL copied = NO;
    if (ipa && !LCRecoveryContainsSensitive(bundle)) {
        copied = [manager copyItemAtURL:ipa toURL:destination error:error];
    } else {
        NSURL *payload = [stage URLByAppendingPathComponent:@"archive/Payload/LiveContainer.app" isDirectory:YES];
        copied = [manager createDirectoryAtURL:payload.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]
            && [manager copyItemAtURL:bundle toURL:payload error:error]
            && LCRecoverySanitizeBundle(payload, error)
            && LCRecoveryArchive(payload.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent, destination, error);
        [manager removeItemAtURL:[stage URLByAppendingPathComponent:@"archive"] error:nil];
    }
    NSString *hash = copied ? LCRecoveryHash(destination, error) : nil;
    if (!hash) { [manager removeItemAtURL:stage error:nil]; return NO; }
    NSDictionary *receipt = @{@"build": info[@"CFBundleVersion"], @"ipaSHA256": hash,
        @"bootstrapSHA256": info[@"LCRecoveryBootstrapSHA256"], @"kind": ipa ? @"download" : @"installed-bundle"};
    BOOL saved = LCRecoveryWriteJSON(receipt, [stage URLByAppendingPathComponent:@"receipt.json"], error);
    for (NSString *name in @[@"install.sh", @"install-local.sh"]) {
        if (!saved) break;
        saved = [manager copyItemAtURL:[bundle URLByAppendingPathComponent:[@"Recovery/" stringByAppendingString:name]]
                                toURL:[stage URLByAppendingPathComponent:name] error:error];
    }
    if (saved) saved = LCRecoveryReplace(stage, [root URLByAppendingPathComponent:@"cache" isDirectory:YES], error);
    if (!saved) [manager removeItemAtURL:stage error:nil];
    if (saved) LCRecoveryRecord(@{@"cacheBuild": info[@"CFBundleVersion"], @"error": @""});
    return saved;
}

static BOOL LCRecoveryEnsureCache(NSURL *root, NSError **error) {
    NSURL *cache = [root URLByAppendingPathComponent:@"cache" isDirectory:YES];
    NSDictionary *receipt = LCRecoveryReadJSON([cache URLByAppendingPathComponent:@"receipt.json"]);
    NSString *hash = receipt[@"ipaSHA256"];
    NSString *build = receipt[@"build"];
    NSString *installed = [LCSharedUtils.hostAppBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    BOOL current = LCRecoveryValidBuild(build) && [build compare:installed options:NSNumericSearch] != NSOrderedAscending;
    if (current && hash.length == 64 && [hash isEqualToString:LCRecoveryHash([cache URLByAppendingPathComponent:LCRecoveryIPA], nil)]) return YES;
    return LCRecoveryCache(nil, LCSharedUtils.hostAppBundle.bundleURL, root, error);
}

static NSURL *LCRecoveryResolveDirectory(NSError **error) {
    NSUserDefaults *defaults = LCRecoveryDefaults();
    NSData *bookmark = [defaults dataForKey:LCRecoveryBookmarkKey];
    if (!bookmark) { if (error) *error = LCRecoveryError(@"请先选择保存文件夹。"); return nil; }
    BOOL stale = NO;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&stale error:error];
    if (!url) { if (error) *error = LCRecoveryError(@"保存位置不可用，请重新选择文件夹。"); return nil; }
    if (stale) {
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSData *renewed = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:error];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (!renewed) return nil;
        [defaults setObject:renewed forKey:LCRecoveryBookmarkKey];
    }
    return url;
}

static BOOL LCRecoveryPrepareExport(NSURL *root, NSURL *stage, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *cache = [root URLByAppendingPathComponent:@"cache" isDirectory:YES];
    NSDictionary *receipt = LCRecoveryReadJSON([cache URLByAppendingPathComponent:@"receipt.json"]);
    NSURL *zipRoot = [stage URLByAppendingPathComponent:@"content/siboot-local" isDirectory:YES];
    NSURL *assets = [zipRoot URLByAppendingPathComponent:@"assets" isDirectory:YES];
    if (![manager createDirectoryAtURL:assets withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (!LCRecoveryCopyVerified([cache URLByAppendingPathComponent:LCRecoveryIPA], [stage URLByAppendingPathComponent:LCRecoveryIPA], receipt[@"ipaSHA256"], error)) return NO;
    if (![manager copyItemAtURL:[stage URLByAppendingPathComponent:LCRecoveryIPA] toURL:[assets URLByAppendingPathComponent:LCRecoveryIPA] error:error]) return NO;
    NSString *script = [NSString stringWithContentsOfURL:[cache URLByAppendingPathComponent:@"install.sh"] encoding:NSUTF8StringEncoding error:error];
    if (!script) return NO;
    NSDictionary *tokens = @{@"__BUILD__": receipt[@"build"], @"__IPA_SHA256__": receipt[@"ipaSHA256"], @"__CORE_SHA256__": receipt[@"bootstrapSHA256"]};
    for (NSString *token in tokens) script = [script stringByReplacingOccurrencesOfString:token withString:tokens[token]];
    if (![script writeToURL:[zipRoot URLByAppendingPathComponent:@"install.sh"] atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    NSURL *entry = [cache URLByAppendingPathComponent:@"install-local.sh"];
    if (![manager copyItemAtURL:entry toURL:[stage URLByAppendingPathComponent:@"install-local.sh"] error:error]
        || ![manager copyItemAtURL:entry toURL:[zipRoot URLByAppendingPathComponent:@"install-local.sh"] error:error]) return NO;
    NSString *installerHash = LCRecoveryHash([zipRoot URLByAppendingPathComponent:@"install.sh"], error);
    NSString *checksums = [NSString stringWithFormat:@"%@  install.sh\n%@  assets/%@\n", installerHash, receipt[@"ipaSHA256"], LCRecoveryIPA];
    if (!installerHash || ![checksums writeToURL:[zipRoot URLByAppendingPathComponent:@"SHA256SUMS"] atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    if (!LCRecoveryArchive(zipRoot.URLByDeletingLastPathComponent, [stage URLByAppendingPathComponent:LCRecoveryZIP], error)) return NO;
    [manager removeItemAtURL:zipRoot.URLByDeletingLastPathComponent error:nil];
    NSMutableDictionary *exportReceipt = [receipt mutableCopy];
    exportReceipt[@"zipSHA256"] = LCRecoveryHash([stage URLByAppendingPathComponent:LCRecoveryZIP], error);
    if (!exportReceipt[@"zipSHA256"]) return NO;
    return LCRecoveryWriteJSON(exportReceipt, [stage URLByAppendingPathComponent:@"recovery.json"], error);
}

static BOOL LCRecoveryPublish(NSURL *stage, NSURL *directory, NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *lock = [directory URLByAppendingPathComponent:@".livecontainer-write-lock" isDirectory:YES];
    if (mkdir(lock.path.fileSystemRepresentation, 0700) != 0) {
        if (error) *error = LCRecoveryError(@"保存位置正在被使用。如上次保存已中断，请删除文件夹内的 .livecontainer-write-lock 后重试。");
        return NO;
    }
    LCRecoveryWriteJSON(@{@"kind": @"app", @"id": NSUUID.UUID.UUIDString,
        @"created": [NSISO8601DateFormatter.new stringFromDate:NSDate.date]}, [lock URLByAppendingPathComponent:@"owner.json"], nil);
    NSURL *pending = [directory URLByAppendingPathComponent:@".livecontainer-pending-app" isDirectory:YES];
    [manager removeItemAtURL:pending error:nil];
    BOOL success = [manager createDirectoryAtURL:pending withIntermediateDirectories:NO attributes:nil error:error];
    NSArray *files = @[LCRecoveryIPA, @"install-local.sh", @"recovery.json", LCRecoveryZIP];
    for (NSString *name in files) {
        if (!success) break;
        NSURL *source = [stage URLByAppendingPathComponent:name];
        NSString *hash = LCRecoveryHash(source, error);
        success = hash && LCRecoveryCopyVerified(source, [pending URLByAppendingPathComponent:name], hash, error);
    }
    // The ZIP is the commit point. Its checked installer never reads the loose IPA.
    for (NSString *name in files) {
        if (!success) break;
        success = LCRecoveryReplace([pending URLByAppendingPathComponent:name], [directory URLByAppendingPathComponent:name], error);
    }
    [manager removeItemAtURL:pending error:nil];
    [manager removeItemAtURL:lock error:nil];
    return success;
}

static BOOL LCRecoveryValidateAutomaticCache(NSURL *root, NSString *expectedBuild, NSError **error) {
    NSURL *cache = [root URLByAppendingPathComponent:@"cache" isDirectory:YES];
    NSDictionary *receipt = LCRecoveryReadJSON([cache URLByAppendingPathComponent:@"receipt.json"]);
    id cachedBuild = receipt[@"build"];
    if (!LCRecoveryValidBuild(expectedBuild) || ![cachedBuild isKindOfClass:NSString.class] || ![cachedBuild isEqualToString:expectedBuild]) {
        if (error) *error = LCRecoveryError(@"本次更新的备份缓存已变化，自动保存未完成，原恢复包未被替换。");
        return NO;
    }
    NSString *expectedHash = receipt[@"ipaSHA256"];
    NSString *actualHash = LCRecoveryHash([cache URLByAppendingPathComponent:LCRecoveryIPA], error);
    if (![expectedHash isKindOfClass:NSString.class] || expectedHash.length != 64 || ![expectedHash isEqualToString:actualHash]) {
        if (error && !*error) *error = LCRecoveryError(@"本次更新的备份缓存校验失败，原恢复包未被替换。");
        return NO;
    }
    return YES;
}

static BOOL LCRecoverySave(NSURL *root, NSString *expectedBuild, NSError **error) {
    BOOL valid = expectedBuild ? LCRecoveryValidateAutomaticCache(root, expectedBuild, error) : LCRecoveryEnsureCache(root, error);
    if (!valid) return NO;
    NSURL *directory = LCRecoveryResolveDirectory(error);
    if (!directory) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *stage = [root URLByAppendingPathComponent:@"export-pending" isDirectory:YES];
    [manager removeItemAtURL:stage error:nil];
    BOOL prepared = [manager createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:error]
        && LCRecoveryPrepareExport(root, stage, error);
    if (!prepared) { [manager removeItemAtURL:stage error:nil]; return NO; }
    BOOL scoped = [directory startAccessingSecurityScopedResource];
    __block BOOL success = NO;
    __block NSError *writeError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateWritingItemAtURL:directory options:NSFileCoordinatorWritingForMerging error:error byAccessor:^(NSURL *target) {
        success = LCRecoveryPublish(stage, target, &writeError);
    }];
    if (scoped) [directory stopAccessingSecurityScopedResource];
    [manager removeItemAtURL:stage error:nil];
    if (!success) { if (error && !*error) *error = writeError ?: LCRecoveryError(@"无法保存到所选文件夹，原完整恢复包仍可使用。"); return NO; }
    NSDictionary *receipt = LCRecoveryReadJSON([[root URLByAppendingPathComponent:@"cache"] URLByAppendingPathComponent:@"receipt.json"]);
    LCRecoveryRecord(@{@"exportBuild": receipt[@"build"], @"lastSaved": [NSISO8601DateFormatter.new stringFromDate:NSDate.date], @"error": @""});
    return YES;
}

static BOOL LCRecoveryPerform(BOOL (^operation)(NSURL *, NSError **), NSError **error) {
    NSError *failure = nil;
    NSURL *root = LCRecoveryRoot(&failure);
    int descriptor = root ? open([[root URLByAppendingPathComponent:@"operation.lock"].path fileSystemRepresentation], O_CREAT | O_RDWR, 0600) : -1;
    if (descriptor < 0 || flock(descriptor, LOCK_EX | LOCK_NB) != 0) {
        if (!failure) failure = LCRecoveryError(@"另一个备份任务正在运行，请稍后重试。");
    }
    BOOL success = NO;
    if (!failure) success = operation(root, &failure);
    if (descriptor >= 0) { flock(descriptor, LOCK_UN); close(descriptor); }
    if (!success && !failure) failure = LCRecoveryError(@"保存失败，请重试。");
    if (failure) LCRecoveryRecord(@{@"error": failure.localizedDescription});
    if (error) *error = failure;
    return success;
}

@implementation LCRecoveryBackup

+ (NSDictionary<NSString *, id> *)status {
    NSUserDefaults *defaults = LCRecoveryDefaults();
    NSMutableDictionary *status = [[defaults dictionaryForKey:LCRecoveryStatusKey] mutableCopy] ?: [NSMutableDictionary new];
    status[@"configured"] = @([defaults dataForKey:LCRecoveryBookmarkKey] != nil);
    status[@"automatic"] = @([defaults boolForKey:LCRecoveryAutomaticKey]);
    @synchronized (self) { status[@"busy"] = @(LCRecoveryBusy); }
    for (NSString *key in @[@"directoryName", @"cacheBuild", @"exportBuild", @"lastSaved", @"error"]) if (!status[key]) status[key] = @"";
    return status;
}

+ (BOOL)configureDirectory:(NSURL *)directory error:(NSError **)error {
    __block NSError *failure = nil;
    __block BOOL success = NO;
    dispatch_sync(LCRecoveryQueue(), ^{
        BOOL scoped = [directory startAccessingSecurityScopedResource];
        NSURL *target = [directory.lastPathComponent isEqualToString:@"livecontainer"] ? directory
            : [directory URLByAppendingPathComponent:@"livecontainer" isDirectory:YES];
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateWritingItemAtURL:target options:NSFileCoordinatorWritingForMerging error:&failure byAccessor:^(NSURL *url) {
            NSFileManager *manager = NSFileManager.defaultManager;
            if (![manager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:nil error:&failure]) return;
            NSURL *probe = [url URLByAppendingPathComponent:[@".lc-probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            if (![[NSData data] writeToURL:probe options:NSDataWritingAtomic error:&failure]) return;
            [manager removeItemAtURL:probe error:nil];
            NSData *bookmark = [target bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:&failure];
            if (!bookmark) return;
            NSUserDefaults *defaults = LCRecoveryDefaults();
            [defaults setObject:bookmark forKey:LCRecoveryBookmarkKey];
            if (![defaults objectForKey:LCRecoveryAutomaticKey]) [defaults setBool:YES forKey:LCRecoveryAutomaticKey];
            LCRecoveryRecord(@{@"directoryName": target.lastPathComponent, @"exportBuild": @"", @"lastSaved": @"", @"error": @""});
            success = YES;
        }];
        if (scoped) [directory stopAccessingSecurityScopedResource];
    });
    if (failure) LCRecoveryRecord(@{@"error": failure.localizedDescription});
    if (error) *error = failure;
    return success;
}

+ (void)setAutomatic:(BOOL)enabled {
    [LCRecoveryDefaults() setBool:enabled forKey:LCRecoveryAutomaticKey];
}

+ (BOOL)captureIPA:(NSURL *)ipa bundleURL:(NSURL *)bundleURL error:(NSError **)error {
    __block BOOL success = NO;
    __block NSError *failure = nil;
    dispatch_sync(LCRecoveryQueue(), ^{
        @synchronized (self) { LCRecoveryBusy = YES; }
        success = LCRecoveryPerform(^BOOL(NSURL *root, NSError **operationError) {
            return LCRecoveryCache(ipa, bundleURL, root, operationError);
        }, &failure);
        @synchronized (self) { LCRecoveryBusy = NO; }
    });
    if (error) *error = failure;
    return success;
}

+ (void)saveWithCompletion:(void (^)(NSError *))completion {
    dispatch_async(LCRecoveryQueue(), ^{
        @synchronized (self) { LCRecoveryBusy = YES; }
        NSError *failure;
        LCRecoveryPerform(^BOOL(NSURL *root, NSError **error) { return LCRecoverySave(root, nil, error); }, &failure);
        @synchronized (self) { LCRecoveryBusy = NO; }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(failure); });
    });
}

+ (void)saveAutomaticallyForBuild:(NSString *)build completion:(void (^)(NSError *))completion {
    NSUserDefaults *defaults = LCRecoveryDefaults();
    if (![defaults boolForKey:LCRecoveryAutomaticKey] || ![defaults dataForKey:LCRecoveryBookmarkKey]) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSString *expectedBuild = [build isKindOfClass:NSString.class] ? [build copy] : @"";
    dispatch_async(LCRecoveryQueue(), ^{
        @synchronized (self) { LCRecoveryBusy = YES; }
        NSError *failure;
        LCRecoveryPerform(^BOOL(NSURL *root, NSError **error) { return LCRecoverySave(root, expectedBuild, error); }, &failure);
        @synchronized (self) { LCRecoveryBusy = NO; }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(failure); });
    });
}
@end
