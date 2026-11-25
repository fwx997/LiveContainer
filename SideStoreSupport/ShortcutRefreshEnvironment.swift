import Foundation

enum ShortcutRefreshEnvironment {
    static func store() throws -> ShortcutRefreshResultStore {
        guard let host = LCSharedUtils.hostAppBundle(), let hostID = host.bundleIdentifier,
              let group = LCSharedUtils.appGroupPath() else {
            throw NSError(domain: "SideStore.ShortcutRefreshStorage", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The refresh result App Group is unavailable. No refresh was started."])
        }
        return try ShortcutRefreshResultStore(group: group, hostBundleID: hostID)
    }
}
