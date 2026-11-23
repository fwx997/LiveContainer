"""Execute the production SI mailbox/client with host and AppIntents adapters."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


ADAPTERS = r'''
import Foundation

struct IntentFile {
    var data: Data
    var filename: String
    var fileURL: URL? = nil
}

#if os(Linux)
extension URL {
    func startAccessingSecurityScopedResource() -> Bool { false }
    func stopAccessingSecurityScopedResource() { }
}
#endif

struct HarnessFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() { return }
    throw HarnessFailure(description: message)
}

final class HostBundle {
    var bundleIdentifier: String? = "com.kdt.livecontainer"
    var schemes = ["livecontainer"]
    func object(forInfoDictionaryKey key: String) -> Any? {
        key == "CFBundleURLTypes" ? [["CFBundleURLSchemes": schemes]] : nil
    }
}

@MainActor enum LCSharedUtils {
    static func hostAppBundle() -> HostBundle? { Fixture.hasHost ? Fixture.host : nil }
    static func appGroupPath() -> URL? { Fixture.hasGroup ? Fixture.group : nil }
    static func built(inAppExists identifier: String) -> Bool {
        Fixture.hasSideInstaller && identifier == "builtinSideInstaller"
    }
}

@MainActor struct LaunchAppExtension {
    func openURL(launchOptions: [String: Any]) async throws {
        try Fixture.launch(launchOptions)
    }
}

@MainActor enum Fixture {
    enum Mode: Equatable {
        case success, applicationError, mismatchedID, mismatchedHost, missingValue
        case unacknowledged, acknowledged, cancellation, launchError
    }
    static let group = FileManager.default.temporaryDirectory
        .appendingPathComponent("si-shortcut-harness-" + UUID().uuidString, isDirectory: true)
    static let host = HostBundle()
    static var hasHost = true
    static var hasGroup = true
    static var hasSideInstaller = true
    static var mode = Mode.success
    static var uptime: TimeInterval = 0
    static var launches = 0
    static var polls = 0
    static var request: [String: Any] = [:]
    static var requestFolder: URL?
    static var copiedFile: Data?
    static var launchScheme: String?

    static func mailbox() throws -> SIShortcutMailbox {
        try SIShortcutMailbox(group: group, hostBundleID: host.bundleIdentifier!)
    }

    static func launch(_ options: [String: Any]) throws {
        launches += 1
        guard let url = options["url"] as? URL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw HarnessFailure(description: "The host did not receive a launch URL")
        }
        launchScheme = components.scheme
        try require(components.host == "livecontainer-launch", "The host launch route changed")
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        try require(values["bundle-name"] == "builtinSideInstaller", "The wrong guest would launch")
        guard let encoded = values["open-url"], let data = Data(base64Encoded: encoded),
              let guest = String(data: data, encoding: .utf8),
              let nested = URLComponents(string: guest),
              let identifier = nested.queryItems?.first(where: { $0.name == "request" })?.value else {
            throw HarnessFailure(description: "The nested request URL could not be decoded")
        }
        try require(nested.scheme == "sideinstaller" && nested.host == "shortcut", "The guest request route changed")
        let mailbox = try mailbox()
        let folder = try mailbox.requestFolder(identifier)
        requestFolder = folder
        request = try SIShortcutMailbox.read(folder.appendingPathComponent("request.json"))
        try require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("heartbeat").path),
                    "The consumer would not see the caller heartbeat")
        try require(request["id"] as? String == identifier, "The launch and request IDs differ")
        if let file = (request["parameters"] as? [String: Any])?["file"] as? [String: String],
           let relative = file["relativePath"] {
            let input = folder.appendingPathComponent(relative).standardizedFileURL
            let expectedRoot = folder.appendingPathComponent("input", isDirectory: true).standardizedFileURL.path + "/"
            try require(input.path.hasPrefix(expectedRoot), "An imported file escaped its request folder")
            try require(!relative.contains(".."), "An imported file kept traversal components")
            copiedFile = try Data(contentsOf: input)
        }
        if mode == .launchError { throw SIShortcutFailure("The host refused to launch SI") }
        if mode == .acknowledged {
            try Data().write(to: folder.appendingPathComponent("started"))
        }
        if [.unacknowledged, .acknowledged, .cancellation].contains(mode) { return }
        var reply: [String: Any] = [
            "version": 1, "id": identifier, "hostBundleID": mailbox.hostBundleID,
            "value": ["confirmed": true, "coordinate": ["latitude": 31.2, "longitude": 121.5]],
        ]
        switch mode {
        case .applicationError: reply["error"] = "The device rejected this action"
        case .mismatchedID: reply["id"] = UUID().uuidString
        case .mismatchedHost: reply["hostBundleID"] = "com.kdt.livecontainer2"
        case .missingValue: reply.removeValue(forKey: "value")
        default: break
        }
        try SIShortcutMailbox.write(reply, to: folder.appendingPathComponent("response.json"))
    }

    static func poll() async throws {
        polls += 1
        uptime += mode == .acknowledged ? 300 : 15
        if mode == .cancellation { withUnsafeCurrentTask { $0?.cancel() } }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
'''


SCENARIOS = r'''
@main struct Runner {
    @MainActor static func main() async throws {
        try FileManager.default.createDirectory(at: Fixture.group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: Fixture.group) }
        let scenario = CommandLine.arguments[1]
        switch scenario {
        case "namespace": try namespace()
        case "invalid-identifiers": try invalidIdentifiers()
        case "response-validation": try responseValidation()
        case "payload": try await payload()
        case "memory-file": try await inputFile(fromURL: false)
        case "url-file": try await inputFile(fromURL: true)
        case "cache": try cache()
        case "empty-cache": try emptyCache()
        case "bad-cache": try badCache()
        case "pre-cancelled": try await preCancelled()
        case "cancelled": try await failedClient(.cancellation, cancellation: true)
        case "unacknowledged": try await failedClient(.unacknowledged, contains: "未接收")
        case "acknowledged": try await failedClient(.acknowledged, contains: "超时")
        case "application-error": try await failedClient(.applicationError, contains: "device rejected")
        case "mismatched-id": try await failedClient(.mismatchedID, contains: "不匹配")
        case "mismatched-host": try await failedClient(.mismatchedHost, contains: "不匹配")
        case "missing-value": try await failedClient(.missingValue, contains: "没有返回")
        case "launch-error": try await failedClient(.launchError, contains: "refused")
        case "missing-companion": try await missingCompanion()
        default: throw HarnessFailure(description: "Unknown scenario " + scenario)
        }
        print("SI shortcut scenario passed: " + scenario)
    }

    @MainActor static func namespace() throws {
        let first = try Fixture.mailbox()
        let second = try SIShortcutMailbox(group: Fixture.group, hostBundleID: "com.kdt.livecontainer2")
        let identifier = UUID().uuidString
        let one = try first.create(identifier: identifier, action: "SetLocation", parameters: ["latitude": 31.2])
        let two = try second.create(identifier: identifier, action: "ResetLocation", parameters: [:])
        try require(one != two, "LC and LC2 share a request namespace")
        try SIShortcutMailbox.write(["version": 1, "id": identifier, "hostBundleID": first.hostBundleID, "value": true],
                                    to: one.appendingPathComponent("response.json"))
        try require(try first.response(identifier: identifier) != nil, "LC could not read its own reply")
        try require(try second.response(identifier: identifier) == nil, "LC2 read LC's reply")
        let secondRequest = try SIShortcutMailbox.read(two.appendingPathComponent("request.json"))
        try require(secondRequest["action"] as? String == "ResetLocation", "LC2's request was overwritten")
    }

    @MainActor static func invalidIdentifiers() throws {
        for host in ["", ".", "..", "../../escape", "bad\\host"] {
            var rejected = false
            do { _ = try SIShortcutMailbox(group: Fixture.group, hostBundleID: host) } catch { rejected = true }
            try require(rejected, "An invalid host namespace was accepted")
        }
        let mailbox = try Fixture.mailbox()
        for identifier in ["", "../escape", "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"] {
            var rejected = false
            do { _ = try mailbox.requestFolder(identifier) } catch { rejected = true }
            try require(rejected, "An invalid request identifier was accepted")
        }
    }

    @MainActor static func responseValidation() throws {
        let mailbox = try Fixture.mailbox()
        let identifier = UUID().uuidString
        let folder = try mailbox.create(identifier: identifier, action: "DeviceInfo", parameters: [:])
        let cases: [[String: Any]] = [
            ["version": 2, "id": identifier, "hostBundleID": mailbox.hostBundleID, "value": true],
            ["version": 1, "id": identifier, "hostBundleID": mailbox.hostBundleID],
            ["version": 1, "id": identifier, "hostBundleID": mailbox.hostBundleID, "error": "device failure", "value": true],
        ]
        for reply in cases {
            try SIShortcutMailbox.write(reply, to: folder.appendingPathComponent("response.json"))
            var rejected = false
            do { _ = try mailbox.response(identifier: identifier) } catch { rejected = true }
            try require(rejected, "An invalid or failed response became success")
        }
    }

    @MainActor static func payload() async throws {
        Fixture.host.bundleIdentifier = "com.kdt.livecontainer2"
        Fixture.host.schemes = ["livecontainer2", "sidestore"]
        let parameters: [String: Any] = ["latitude": 31.2, "longitude": 121.5, "name": "上海 & /?",
                                          "enabled": true, "bundleIDs": ["com.example.one", "com.example.two"]]
        let result = try await SIShortcutClient.perform(action: "SetLocation", parameters: parameters)
        let input = Fixture.request["parameters"] as? [String: Any] ?? [:]
        try require(input["latitude"] as? Double == 31.2 && input["longitude"] as? Double == 121.5,
                    "Coordinate values or types changed in transit")
        try require(input["name"] as? String == "上海 & /?" && input["enabled"] as? Bool == true,
                    "Text or Boolean parameters changed in transit")
        try require(input["bundleIDs"] as? [String] == ["com.example.one", "com.example.two"] && input.count == 5,
                    "Application list or parameter keys changed in transit")
        try require(Fixture.request["action"] as? String == "SetLocation", "The action changed in transit")
        try require(Fixture.request["hostBundleID"] as? String == "com.kdt.livecontainer2", "LC2 lost its identity")
        try require(Fixture.launchScheme == "livecontainer2", "The client opened the wrong installed LC")
        let created = Fixture.request["createdAt"] as? Double ?? 0
        let expires = Fixture.request["expiresAt"] as? Double ?? 0
        try require(expires - created == 600, "The consumer did not receive a bounded request lifetime")
        try require((result["value"] as? [String: Any])?["confirmed"] as? Bool == true, "The real response was not returned")
        try require(Fixture.launches == 1, "One action launched the guest repeatedly")
        try require(!FileManager.default.fileExists(atPath: Fixture.requestFolder!.path), "Successful input files were not removed")
    }

    @MainActor static func inputFile(fromURL: Bool) async throws {
        let contents = Data("<gpx><wpt lat=\"31.2\" lon=\"121.5\"/></gpx>".utf8)
        let outside = Fixture.group.appendingPathComponent("outside.gpx")
        let sentinel = Data("keep this file".utf8)
        try sentinel.write(to: outside)
        var file = IntentFile(data: contents, filename: "../../../outside.gpx")
        var source: URL?
        if fromURL {
            source = Fixture.group.appendingPathComponent("original.gpx")
            try contents.write(to: source!)
            file.fileURL = source
            file.data = Data("do not use this fallback".utf8)
        }
        _ = try await SIShortcutClient.perform(action: "PlayRoute", parameters: ["file": file, "speed": "walk"])
        try require(Fixture.copiedFile == contents, "The supplied file bytes were not copied")
        let values = Fixture.request["parameters"] as? [String: Any] ?? [:]
        let copied = values["file"] as? [String: String] ?? [:]
        try require(copied["filename"] == "outside.gpx", "The file metadata retained a path")
        try require(copied["relativePath"]?.hasPrefix("input/") == true, "The file was not scoped to this request")
        try require(copied["relativePath"]?.hasSuffix(".gpx") == true, "The file lost its GPX extension")
        try require(try Data(contentsOf: outside) == sentinel, "A filename overwrote a file outside the request")
        if let source { try require(try Data(contentsOf: source) == contents, "The supplied source file was moved or removed") }
        try require(!FileManager.default.fileExists(atPath: Fixture.requestFolder!.path), "Successful file input leaked")
    }

    @MainActor static func writeCache(_ entries: [[String: Any]], action: String, mailbox: SIShortcutMailbox) throws {
        let folder = mailbox.root.appendingPathComponent("caches", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SIShortcutMailbox.write(["value": entries], to: folder.appendingPathComponent(action + ".json"))
    }

    @MainActor static func cache() throws {
        let mailbox = try Fixture.mailbox()
        let other = try SIShortcutMailbox(group: Fixture.group, hostBundleID: "com.kdt.livecontainer2")
        let entries: [[String: Any]] = [["id": "1", "name": "Home"], ["id": "2", "name": "Work"]]
        try writeCache(entries, action: "SavedPlaceQuery", mailbox: mailbox)
        try writeCache([["id": "3", "name": "Other host"]], action: "SavedPlaceQuery", mailbox: other)
        let result = try SIShortcutClient.cached(action: "SavedPlaceQuery", parameters: ["identifiers": ["1", "2"], "matching": "HOME"])
        let found = result["value"] as? [[String: Any]] ?? []
        try require(found.count == 1 && found.first?["id"] as? String == "1", "Entity query filtering or host isolation failed")
        try require(Fixture.launches == 0, "An entity query launched an application")
        try require(!FileManager.default.fileExists(atPath: mailbox.root.appendingPathComponent("requests").path), "An entity query created a request")
    }

    @MainActor static func emptyCache() throws {
        let result = try SIShortcutClient.cached(action: "SideloadedAppQuery")
        try require((result["value"] as? [[String: Any]])?.isEmpty == true, "A missing cache must be an empty list")
        try require(Fixture.launches == 0, "A missing cache launched an application")
    }

    @MainActor static func badCache() throws {
        let mailbox = try Fixture.mailbox()
        let folder = mailbox.root.appendingPathComponent("caches", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SIShortcutMailbox.write(["value": "not a list"], to: folder.appendingPathComponent("SavedPlaceQuery.json"))
        for action in ["SavedPlaceQuery", "InstallIPA"] {
            var rejected = false
            do { _ = try SIShortcutClient.cached(action: action) } catch { rejected = true }
            try require(rejected, "A corrupt or unsupported entity query was accepted")
        }
        try require(Fixture.launches == 0, "A failed entity query launched an application")
    }

    @MainActor static func failedClient(_ mode: Fixture.Mode, contains fragment: String = "", cancellation: Bool = false) async throws {
        Fixture.mode = mode
        var failure: Error?
        do { _ = try await SIShortcutClient.perform(action: "DeviceInfo") } catch { failure = error }
        guard let failure else { throw HarnessFailure(description: "The client reported false success") }
        if cancellation { try require(failure is CancellationError, "Cancellation lost its error type") }
        else { try require(failure.localizedDescription.contains(fragment), "The client lost the failure: \(failure)") }
        let folder = Fixture.requestFolder!
        try require(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cancelled").path),
                    "The consumer was not told to abandon the request")
        try require(Fixture.launches == 1, "A failed action was relaunched")
        if mode == .unacknowledged { try require(Fixture.polls == 2, "The unacknowledged deadline was not enforced") }
        if mode == .acknowledged { try require(Fixture.polls == 2, "The acknowledged deadline was not enforced") }
    }

    @MainActor static func preCancelled() async throws {
        let task = Task { try await SIShortcutClient.perform(action: "DeviceInfo") }
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch is CancellationError { cancelled = true }
        try require(cancelled, "A cancelled action ran")
        try require(Fixture.launches == 0, "A pre-cancelled action launched SI")
    }

    @MainActor static func missingCompanion() async throws {
        Fixture.hasSideInstaller = false
        var rejected = false
        do { _ = try await SIShortcutClient.perform(action: "DeviceInfo") } catch { rejected = true }
        try require(rejected, "A two-app package accepted a SideInstaller action")
        try require(Fixture.launches == 0, "An unavailable companion was launched")
    }
}
'''


def production_harness():
    mailbox = (ROOT / "LaunchAppExtension/SIShortcutMailbox.swift").read_text(encoding="utf-8")
    client = (ROOT / "LaunchAppExtension/SIShortcutClient.swift").read_text(encoding="utf-8")
    substitutions = {
        "import AppIntents": "// AppIntents file input is adapted by the harness.",
        "ProcessInfo.processInfo.systemUptime": "Fixture.uptime",
        "try await Task.sleep(nanoseconds: 250_000_000)": "try await Fixture.poll()",
    }
    for original, replacement in substitutions.items():
        if original not in client:
            raise AssertionError("Production client adapter no longer matches: " + original)
        client = client.replace(original, replacement)
    return "\n".join([ADAPTERS, mailbox, client, SCENARIOS])


class SideInstallerHarnessGenerationTests(unittest.TestCase):
    def test_production_sources_generate_a_portable_harness(self):
        generated = production_harness()
        self.assertNotIn("import AppIntents", generated)
        self.assertNotIn("ProcessInfo.processInfo.systemUptime", generated)
        self.assertIn("struct SIShortcutMailbox", generated)
        self.assertIn("enum SIShortcutClient", generated)


@unittest.skipUnless(shutil.which("swiftc"), "swiftc is required for production shortcut execution")
class SideInstallerShortcutExecutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="lc-si-shortcuts-")
        cls.addClassCleanup(cls.temporary.cleanup)
        source = Path(cls.temporary.name) / "Shortcuts.swift"
        cls.binary = Path(cls.temporary.name) / "Shortcuts"
        source.write_text(production_harness(), encoding="utf-8")
        subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(cls.binary)],
                       check=True, timeout=120)

    def scenarios(self, *names):
        for name in names:
            with self.subTest(scenario=name):
                subprocess.run([str(self.binary), name], check=True, timeout=15)

    def test_host_namespace_and_request_identity(self):
        self.scenarios("namespace", "invalid-identifiers", "response-validation")

    def test_actual_parameters_and_files_cross_the_mailbox(self):
        self.scenarios("payload", "memory-file", "url-file")

    def test_entity_queries_only_read_the_host_cache(self):
        self.scenarios("cache", "empty-cache", "bad-cache")

    def test_cancellation_and_both_deadlines_never_report_success(self):
        self.scenarios("pre-cancelled", "cancelled", "unacknowledged", "acknowledged")

    def test_failed_or_mismatched_responses_never_report_success(self):
        self.scenarios("application-error", "mismatched-id", "mismatched-host", "missing-value", "launch-error")

    def test_unavailable_companion_does_not_launch(self):
        self.scenarios("missing-companion")


if __name__ == "__main__":
    unittest.main()
