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

// Main-thread bridge shared by the three separately loaded applications.
@class UIMenu;
@interface LCCompanionBridge : NSObject
+ (NSString *)currentAppIdentifier;
+ (NSString *)switchBlockReason;
+ (NSArray<NSDictionary<NSString *, NSString *> *> *)availableApps;
+ (BOOL)openApp:(NSString *)identifier NS_SWIFT_NAME(openApp(_:));
+ (BOOL)openApp:(NSString *)identifier URL:(NSURL * _Nullable)url NS_SWIFT_NAME(openApp(_:url:));
+ (BOOL)handleCompanionURL:(NSURL *)url NS_SWIFT_NAME(handleCompanionURL(_:));
+ (UIMenu *)navigationMenu;
+ (void)installNavigationMenus;
+ (void)setActivity:(NSString *)identifier reason:(NSString * _Nullable)reason NS_SWIFT_NAME(setActivity(_:reason:));
@end
