import AppIntents
import Foundation

@available(iOS 17.4, *)
@MainActor
enum SIShortcutClient {
    private static func configuration() throws -> (SIShortcutMailbox, String) {
        guard let host = LCSharedUtils.hostAppBundle(), let identifier = host.bundleIdentifier,
              let group = LCSharedUtils.appGroupPath(), LCSharedUtils.builtInAppExists("builtinSideInstaller"),
              let types = host.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
              let scheme = types.flatMap({ $0["CFBundleURLSchemes"] as? [String] ?? [] }).first else {
            throw SIShortcutFailure("此动作需要完整三合一安装包及其快捷指令扩展，请保留全部扩展重新安装。")
        }
        return (try SIShortcutMailbox(group: group, hostBundleID: identifier), scheme)
    }

    static func cached(action: String, parameters: [String: Any] = [:]) throws -> [String: Any] {
        try configuration().0.cached(action: action, parameters: parameters)
    }

    static func perform(action: String, parameters: [String: Any] = [:]) async throws -> [String: Any] {
        try Task.checkCancellation()
        let (mailbox, scheme) = try configuration()
        let identifier = UUID().uuidString
        let folder = try mailbox.requestFolder(identifier)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var finished = false
        defer {
            if finished { try? FileManager.default.removeItem(at: folder) }
            else { try? Data().write(to: folder.appendingPathComponent("cancelled"), options: .atomic) }
        }
        let input = try copyInputFiles(parameters, to: folder)
        _ = try mailbox.create(identifier: identifier, action: action, parameters: input)
        try heartbeat(folder)
        let url = try launchURL(scheme: scheme, identifier: identifier)
        // This intent runs in its own extension process while LC restarts into SI.
        try await LaunchAppExtension().openURL(launchOptions: ["url": url])
        let started = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            if let result = try mailbox.response(identifier: identifier) {
                finished = true
                return result
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let acknowledged = FileManager.default.fileExists(atPath: folder.appendingPathComponent("started").path)
            if !acknowledged && elapsed >= 30 {
                throw SIShortcutFailure("SideInstaller 未接收动作。请先结束当前操作、打开 SI，再重试快捷指令。")
            }
            if elapsed >= 600 { throw SIShortcutFailure("等待 SideInstaller 执行结果超时，请在 SI 查看当前状态。") }
            try heartbeat(folder)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private static func heartbeat(_ folder: URL) throws {
        try Data().write(to: folder.appendingPathComponent("heartbeat"), options: .atomic)
    }

    private static func launchURL(scheme: String, identifier: String) throws -> URL {
        var guest = URLComponents()
        guest.scheme = "sideinstaller"
        guest.host = "shortcut"
        guest.queryItems = [URLQueryItem(name: "request", value: identifier)]
        guard let guestURL = guest.url else { throw SIShortcutFailure("无法创建 SI 动作链接。") }
        var host = URLComponents()
        host.scheme = scheme
        host.host = "livecontainer-launch"
        host.queryItems = [URLQueryItem(name: "bundle-name", value: "builtinSideInstaller"),
                           URLQueryItem(name: "open-url", value: Data(guestURL.absoluteString.utf8).base64EncodedString())]
        guard let url = host.url else { throw SIShortcutFailure("无法创建三合一启动链接。") }
        return url
    }

    private static func copyInputFiles(_ parameters: [String: Any], to folder: URL) throws -> [String: Any] {
        var values = parameters
        guard let file = parameters["file"] as? IntentFile else { return values }
        let input = folder.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let name = (file.filename as NSString).lastPathComponent
        let suffix = (name as NSString).pathExtension.filter { $0.isASCII && $0.isLetter }
        let filename = UUID().uuidString + (suffix.isEmpty ? "" : "." + suffix)
        let output = input.appendingPathComponent(filename)
        if let source = file.fileURL {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: output)
        } else {
            try file.data.write(to: output, options: .atomic)
        }
        values["file"] = ["filename": name.isEmpty ? filename : name, "relativePath": "input/" + filename]
        return values
    }
}
