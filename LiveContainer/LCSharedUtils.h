@import Foundation;

@interface LCSharedUtils : NSObject
+ (NSString*) teamIdentifier;
+ (NSString *)appGroupID;
+ (NSURL*) appGroupPath;
+ (NSString *)certificatePassword;
+ (BOOL)launchToGuestAppWithClassicMode:(NSUInteger)classicMode;
+ (BOOL)launchToGuestAppWithURL:(NSURL *)url;
+ (void)setWebPageUrlForNextLaunch:(NSString*)urlString;
+ (BOOL)isLCSchemeInUse:(NSString*)lc;
+ (NSString*)getContainerUsingLCSchemeWithFolderName:(NSString*)folderName;
+ (void)setContainerUsingByLC:(NSString*)lc folderName:(NSString*)folderName auditToken:(uint64_t)val57;
+ (void)moveSharedAppFolderBack;
+ (NSBundle*)findBundleWithBundleId:(NSString*)bundleId isSharedAppOut:(bool*)isSharedAppOut;
+ (void)dumpPreferenceToPath:(NSString*)plistLocationTo dataUUID:(NSString*)dataUUID;
+ (NSString*)findDefaultContainerWithBundleId:(NSString*)bundleId;
+ (NSArray<NSString*>*)lcUnorderedUrlSchemes;
+ (NSArray<NSString*>*)lcUrlSchemes;
+ (BOOL)handleSideStoreCellularCallback:(NSURL*)url;
+ (void)recoverPendingSideStoreCellularData;
+ (NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)builtInApps;
+ (NSBundle *)hostAppBundle;
+ (NSURL *)builtInAppURL:(NSString *)identifier;
+ (BOOL)builtInAppExists:(NSString *)identifier;
@end

// Recovery files live in the host's shared container, including during self update.
@interface LCRecoveryBackup : NSObject
+ (NSDictionary<NSString *, id> * _Nonnull)status NS_SWIFT_NAME(status());
+ (BOOL)configureDirectory:(NSURL * _Nonnull)directory error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(configureDirectory(_:));
+ (void)setAutomatic:(BOOL)enabled NS_SWIFT_NAME(setAutomatic(_:));
+ (BOOL)captureIPA:(NSURL * _Nonnull)ipa bundleURL:(NSURL * _Nonnull)bundleURL error:(NSError * _Nullable * _Nullable)error;
+ (void)saveWithCompletion:(void (^ _Nonnull)(NSError * _Nullable error))completion NS_SWIFT_NAME(saveWithCompletion(_:));
+ (void)saveAutomaticallyForBuild:(NSString * _Nonnull)build completion:(void (^ _Nonnull)(NSError * _Nullable error))completion NS_SWIFT_NAME(saveAutomatically(forBuild:completion:));
@end

// Main-thread bridge shared by the three separately loaded applications.
@class UIMenu, UIImage, UIButton;
@interface LCCompanionBridge : NSObject
+ (NSString *)currentAppIdentifier;
+ (NSString *)switchBlockReason;
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)availableApps;
+ (BOOL)openApp:(NSString *)identifier NS_SWIFT_NAME(openApp(_:));
+ (BOOL)openApp:(NSString *)identifier URL:(NSURL * _Nullable)url NS_SWIFT_NAME(openApp(_:url:));
+ (BOOL)handleCompanionURL:(NSURL *)url NS_SWIFT_NAME(handleCompanionURL(_:));
+ (UIImage *)currentNavigationIcon;
+ (UIImage *)navigationIconForApp:(NSString *)identifier NS_SWIFT_NAME(navigationIcon(forApp:));
+ (UIButton *)navigationButton NS_SWIFT_NAME(makeNavigationButton());
+ (UIMenu *)navigationMenu;
+ (void)installNavigationMenus;
+ (void)setActivity:(NSString *)identifier reason:(NSString * _Nullable)reason NS_SWIFT_NAME(setActivity(_:reason:));
@end
