import Foundation

struct SIShortcutFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Each installed host owns a namespace, including when LC2 shares its app group.
struct SIShortcutMailbox {
    let hostBundleID: String
    let root: URL

    init(group: URL, hostBundleID: String) throws {
        guard !hostBundleID.isEmpty, hostBundleID != ".", hostBundleID != "..",
              !hostBundleID.contains("/"), !hostBundleID.contains("\\") else {
            throw SIShortcutFailure("无法识别三合一应用，请重新安装完整包。")
        }
        self.hostBundleID = hostBundleID
        root = group.appendingPathComponent("LiveContainer/SideInstallerShortcuts", isDirectory: true)
            .appendingPathComponent(hostBundleID, isDirectory: true)
    }

    func requestFolder(_ identifier: String) throws -> URL {
        guard UUID(uuidString: identifier)?.uuidString == identifier else {
            throw SIShortcutFailure("快捷指令请求编号无效。")
        }
        return root.appendingPathComponent("requests", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
    }

    func create(identifier: String, action: String, parameters: [String: Any], now: Date = Date()) throws -> URL {
        let folder = try requestFolder(identifier)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request: [String: Any] = ["version": 1, "id": identifier, "hostBundleID": hostBundleID,
                                      "action": action, "parameters": parameters,
                                      "createdAt": now.timeIntervalSince1970,
                                      "expiresAt": now.addingTimeInterval(600).timeIntervalSince1970]
        try Self.write(request, to: folder.appendingPathComponent("request.json"))
        return folder
    }

    func response(identifier: String) throws -> [String: Any]? {
        let path = try requestFolder(identifier).appendingPathComponent("response.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let result = try Self.read(path)
        guard result["version"] as? Int == 1, result["id"] as? String == identifier,
              result["hostBundleID"] as? String == hostBundleID else {
            throw SIShortcutFailure("SideInstaller 返回的请求信息不匹配。")
        }
        if let message = result["error"] as? String { throw SIShortcutFailure(message) }
        guard result["value"] != nil else { throw SIShortcutFailure("SideInstaller 没有返回执行结果。") }
        return result
    }

    func cached(action: String, parameters: [String: Any]) throws -> [String: Any] {
        guard ["SavedPlaceQuery", "SideloadedAppQuery"].contains(action) else {
            throw SIShortcutFailure("不支持此快捷指令查询。")
        }
        let path = root.appendingPathComponent("caches", isDirectory: true).appendingPathComponent(action + ".json")
        guard FileManager.default.fileExists(atPath: path.path) else { return ["value": [[String: Any]]()] }
        var result = try Self.read(path)
        guard var entries = result["value"] as? [[String: Any]] else {
            throw SIShortcutFailure("SideInstaller 的列表缓存损坏，请打开 SI 更新列表。")
        }
        if let identifiers = parameters["identifiers"] as? [String] {
            let selected = Set(identifiers)
            entries = entries.filter { ($0["id"] as? String).map(selected.contains) ?? false }
        }
        if let query = parameters["matching"] as? String, !query.isEmpty {
            entries = entries.filter { ($0["name"] as? String)?.localizedCaseInsensitiveContains(query) == true }
        }
        result["value"] = entries
        return result
    }

    static func read(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SIShortcutFailure("快捷指令数据格式无效。")
        }
        return object
    }

    static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
