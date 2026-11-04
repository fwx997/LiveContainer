import Foundation

protocol RefreshServer: AnyObject {
    func updateProgress(_ value: Double)
    func finish(_ error: String?, requestIdentifier: String)
    func onConnection(_ connection: FakeConnection!)
    func finishedLaunching()
}

protocol RefreshClient: AnyObject {
    func refreshAllApps(withIdentifier identifier: String, mangledTypeName: String, requestIdentifier: String)
    func handleCellularCallback(_ url: URL)
    func recoverPendingCellularData()
}

enum HarnessError: Error { case interrupted }

@MainActor
enum Fixture {
    static var reporter: RefreshServer?
    static var noListener = false
    static var noBundle = false
    static var noExtension = false
    static var noClient = false
    static var noBookmark = false
    static var noLaunchCallback = false
    static var interruptLaunching = false
    static var cancelLaunching = false
    static var finishImmediately = true
    static var requests: [String] = []
    static var extensionKilled = 0

    static func reset() {
        reporter = nil
        noListener = false
        noBundle = false
        noExtension = false
        noClient = false
        noBookmark = false
        noLaunchCallback = false
        interruptLaunching = false
        cancelLaunching = false
        finishImmediately = true
        requests = []
        extensionKilled = 0
    }
}

final class FakeBundle {
    var builtInPlugInsURL: URL? { URL(fileURLWithPath: "/tmp") }
    var bundleIdentifier: String? { "test.LiveProcess" }
    init(for type: AnyClass) {}
    init() {}
    @MainActor init?(url: URL) {
        if Fixture.noBundle { return nil }
    }
    func localizedString(forKey key: String, value: String?, table: String?) -> String { value ?? key }
}

extension UserDefaults {
    static func lcMainBundle() -> FakeBundle { FakeBundle() }
}

final class FakeListener {
    let endpoint = "endpoint"
}

@MainActor
func startAnonymousListener(_ reporter: RefreshServer) -> FakeListener? {
    Fixture.reporter = reporter
    return Fixture.noListener ? nil : FakeListener()
}

@MainActor
func bookmarkForURL(_ url: URL) -> Data? { Fixture.noBookmark ? nil : Data([1]) }

final class FakeExtensionItem {
    var userInfo: [String: Any]?
}

final class FakeInterface {
    init(with type: Any.Type) {}
}

final class FakeConnection: @unchecked Sendable {
    var remoteObjectInterface: FakeInterface?
    var interruptionHandler: (() -> Void)?
    var invalidationHandler: (() -> Void)?
    var client: RefreshClient?
    init(client: RefreshClient?) { self.client = client }
    func remoteObjectProxyWithErrorHandler(_ callback: @escaping (Error) -> Void) -> Any? { client }
    func invalidate() { invalidationHandler?() }
}

@MainActor
final class FakeExtension {
    private var interruption: ((UUID) -> Void)?
    private var cancellation: ((UUID, Error?) -> Void)?
    init?(identifier: String?) throws {
        if Fixture.noExtension { return nil }
    }
    func setRequestInterruptionBlock(_ callback: @escaping (UUID) -> Void) { interruption = callback }
    func setRequestCancellationBlock(_ callback: @escaping (UUID, Error?) -> Void) { cancellation = callback }
    func beginRequest(withInputItems items: [FakeExtensionItem]) async -> UUID {
        let identifier = UUID()
        if Fixture.interruptLaunching {
            interruption?(identifier)
            return identifier
        }
        if Fixture.cancelLaunching {
            cancellation?(identifier, NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Extension cancelled"]))
            return identifier
        }
        guard !Fixture.noLaunchCallback else { return identifier }
        let client = Fixture.noClient ? nil : TestClient()
        Fixture.reporter?.onConnection(FakeConnection(client: client))
        Fixture.reporter?.finishedLaunching()
        // Exercise finishedLaunching arriving before beginRequest returns its PID.
        await Task.yield()
        return identifier
    }
    func pid(forRequestIdentifier identifier: UUID) -> Int32 { ProcessInfo.processInfo.processIdentifier }
    func _kill(_ signal: Int32) { Fixture.extensionKilled += 1 }
}

final class TestClient: RefreshClient {
    func refreshAllApps(withIdentifier identifier: String, mangledTypeName: String, requestIdentifier: String) {
        MainActor.assumeIsolated {
            Fixture.requests.append(requestIdentifier)
            if Fixture.finishImmediately {
                Fixture.reporter?.finish(nil, requestIdentifier: requestIdentifier)
            }
        }
    }
    func handleCellularCallback(_ url: URL) {}
    func recoverPendingCellularData() {}
}

final class FakeNotificationRequest {}
final class FakeNotificationCenter {
    static func current() -> FakeNotificationCenter { FakeNotificationCenter() }
    func add(_ request: FakeNotificationRequest, completionHandler: (Error?) -> Void) { completionHandler(nil) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
}

// INSERT_PRODUCTION_COORDINATOR

@main
enum Regression {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    @MainActor
    static func refresh(_ handler: RefreshHandler) async throws {
        try await handler.startRefresh(identifier: "RefreshAllIntent", mangledName: "test", progress: Progress(totalUnitCount: 100))
    }

    @MainActor
    static func expectFailure(_ configure: () -> Void, containing message: String) async {
        Fixture.reset()
        configure()
        do {
            try await refresh(RefreshHandler())
            fatalError("Expected failure: \(message)")
        } catch {
            require(error.localizedDescription.contains(message), "Wrong error: \(error)")
        }
    }

    static func completionRegressions() async throws {
        let immediate = RefreshCompletion()
        try await immediate.wait { require(immediate.finish(.success(())), "Initial reply rejected") }
        require(!immediate.finish(.failure(HarnessError.interrupted)), "Duplicate reply accepted")

        let early = RefreshCompletion()
        early.finish(.success(()))
        try await early.wait { fatalError("Started an already completed operation") }

        let interrupted = RefreshCompletion()
        interrupted.finish(.failure(HarnessError.interrupted))
        do {
            try await interrupted.wait()
            fatalError("Early interruption was lost")
        } catch HarnessError.interrupted {}

        let raced = RefreshCompletion()
        let winners = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 { group.addTask { raced.finish(.success(())) } }
            var count = 0
            for await accepted in group { count += accepted ? 1 : 0 }
            return count
        }
        require(winners == 1, "Concurrent completion resumed more than once")
        try await raced.wait()
    }

    @MainActor
    static func coordinatorRegressions() async throws {
        Fixture.reset()
        let handler = RefreshHandler()
        try await refresh(handler)
        require(Fixture.requests.count == 1, "Synchronous launch/refresh reply was lost")
        try await Task.sleep(nanoseconds: 300_000_000)
        require(Fixture.extensionKilled == 0, "Stale launch timeout killed a completed launch")
        try await refresh(handler)
        require(Fixture.requests.count == 2, "Existing connection could not be reused")

        await expectFailure({ Fixture.noListener = true }, containing: "background connection could not be created")
        await expectFailure({ Fixture.noClient = true }, containing: "did not establish its background connection")
        await expectFailure({ Fixture.noBundle = true }, containing: "needs LiveProcess")
        await expectFailure({ Fixture.noExtension = true }, containing: "failed to start")
        await expectFailure({ Fixture.noBookmark = true }, containing: "data container")
        await expectFailure({ Fixture.interruptLaunching = true }, containing: "quit unexpectedly")
        await expectFailure({ Fixture.cancelLaunching = true }, containing: "Extension cancelled")
        await expectFailure({ Fixture.noLaunchCallback = true }, containing: "failed to start")
    }

    @MainActor
    static func requestIdentityRegression() async throws {
        Fixture.reset()
        let handler = RefreshHandler()
        try await refresh(handler)
        let oldIdentifier = Fixture.requests[0]
        Fixture.finishImmediately = false
        var finished = false
        let pending = Task { @MainActor in
            try await refresh(handler)
            finished = true
        }
        while Fixture.requests.count < 2 { await Task.yield() }
        handler.finish(nil, requestIdentifier: oldIdentifier)
        for _ in 0..<20 { await Task.yield() }
        require(!finished, "An old request completed the new refresh")
        do {
            try await refresh(handler)
            fatalError("Concurrent refresh was accepted")
        } catch {
            require(error.localizedDescription.contains("Another refresh"), "Wrong busy error")
        }
        handler.finish(nil, requestIdentifier: Fixture.requests[1])
        try await pending.value
        require(finished, "Current request did not finish")
    }

    @MainActor
    static func cancellationRegression() async throws {
        Fixture.reset()
        Fixture.noLaunchCallback = true
        let handler = RefreshHandler()
        let pending = Task { @MainActor in try await refresh(handler) }
        while handler.ext == nil { await Task.yield() }
        pending.cancel()
        do {
            try await pending.value
            fatalError("Cancellation returned success")
        } catch is CancellationError {}
        Fixture.noLaunchCallback = false
        try await refresh(handler)
    }

    @MainActor
    static func main() async throws {
        setenv("LC_HOME_PATH", "/tmp", 1)
        try await completionRegressions()
        try await coordinatorRegressions()
        try await requestIdentityRegression()
        try await cancellationRegression()
        print("Refresh lifecycle regressions passed")
    }
}
