//
//  SideStore.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import UserNotifications

@available(iOS 17.0, *)
func performIntentRefresh(identifier: String, mangledTypeName: String, intentProgress: Progress) async throws {
    intentProgress.totalUnitCount = 100
    if UserDefaults.isSideStore() {
        try await SideStoreIntentCaller.shared.callRefreshIntent(mangledTypeName: mangledTypeName)
    } else {
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName, progress: intentProgress)
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    public static var openAppWhenRun: Bool { false }
    
    public init() {}
    
    public func perform() async throws -> some IntentResult
    {
        try await performIntentRefresh(identifier: "RefreshAllAppsWidgetIntent", mangledTypeName: "9SideStore26RefreshAllAppsWidgetIntentV", intentProgress: progress)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    public static let intentClassName = "RefreshAllIntent"
    public static var openAppWhenRun: Bool { false }
    
    public static var title: LocalizedStringResource = "Refresh All Apps"
    public static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    public init() {}
    
    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    public func perform() async throws -> some IntentResult & ProvidesDialog
    {
        try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: progress)
        return .result(dialog: "All apps have been refreshed.")
    }
    
}


// A reply can arrive synchronously, before wait() starts, or after an interruption.
// Keep the first result and resume its waiter exactly once in all three cases.
final class RefreshCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(isolation: isolated (any Actor)? = #isolation, start: () -> Void = {}) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
            start()
        }
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

private func refreshError(_ message: String) -> NSError {
    let description = Bundle(for: RefreshHandler.self).localizedString(forKey: message, value: message, table: nil)
    return NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
}

@MainActor
@objc(LCRefreshHandler)
class RefreshHandler: NSObject, RefreshServer {
    private var completion: RefreshCompletion?
    private var launchCompletion: RefreshCompletion?
    private var requestIdentifier: String?
    private var didFinishLaunching = false
    var progress: Progress? = nil
    var listener: NSXPCListener? = nil
    var sideStorePid: Int32 = 0
    var client: RefreshClient? = nil
    var connection: NSXPCConnection? = nil
    var ext: NSExtension? = nil
    
    static var shared = RefreshHandler()

    @objc(handleCellularCallback:)
    nonisolated static func handleCellularCallback(_ url: URL) {
        Task { @MainActor in
            shared.client?.handleCellularCallback(url)
        }
    }

    @objc(recoverPendingCellularData)
    nonisolated static func recoverPendingCellularData() {
        Task { @MainActor in
            shared.client?.recoverPendingCellularData()
        }
    }
    
    func startRefresh(identifier: String, mangledName: String, progress: Progress) async throws {
        guard requestIdentifier == nil else {
            throw refreshError("Another refresh task is in progress.")
        }
        let requestIdentifier = UUID().uuidString
        self.requestIdentifier = requestIdentifier
        self.progress = progress
        let completion = RefreshCompletion()
        self.completion = completion
        defer {
            self.requestIdentifier = nil
            self.completion = nil
            self.progress = nil
        }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await prepareRefresh()
            try Task.checkCancellation()
            guard let client else {
                throw refreshError("Built-in SideStore did not establish its background connection.")
            }
            try await completion.wait {
                client.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName, requestIdentifier: requestIdentifier)
            }
        } onCancel: {
            Task { @MainActor in
                guard self.requestIdentifier == requestIdentifier else { return }
                self.failRefresh(CancellationError())
            }
        }
    }

    private func prepareRefresh() async throws {
        
        if listener == nil {
            guard let listener = startAnonymousListener(self) else {
                throw refreshError("The SideStore background connection could not be created.")
            }
            self.listener = listener
        }
        guard let listener = self.listener else {
            throw refreshError("The SideStore background connection could not be created.")
        }

        // launch SideStore if it's not running
        if sideStorePid <= 0 || getpgid(sideStorePid) <= 0 {
            resetConnection()
            guard let lcHomePath = getenv("LC_HOME_PATH") else {
                throw refreshError("Unable to access SideStore's data container for background refresh.")
            }
            let lcHome = String(cString: lcHomePath)
            let sideStoreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/SideStore")
            guard let bookmarkData = bookmarkForURL(sideStoreHomeURL) else {
                throw refreshError("Unable to access SideStore's data container for background refresh.")
            }

            // start LiveProcess
            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinSideStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                  let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw refreshError("Background refresh needs LiveProcess. Reinstall LiveContainer+SideStore and keep its app extensions.")
            }
            
            var ext : NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw refreshError("LiveProcess could not start. Reinstall LiveContainer+SideStore and keep its app extensions.")
            }
            guard let ext else {
                throw refreshError("Built-in SideStore failed to start in reasonable time")
            }
            self.ext = ext
            let launchCompletion = RefreshCompletion()
            self.launchCompletion = launchCompletion
            
            ext.setRequestInterruptionBlock { [weak self, weak ext] _ in
                Task { @MainActor in
                    guard let self, let ext, self.ext === ext else { return }
                    self.failRefresh(refreshError("Built-in SideStore quit unexpectedly"))
                }
            }
            ext.setRequestCancellationBlock { [weak self, weak ext] _, error in
                Task { @MainActor in
                    guard let self, let ext, self.ext === ext else { return }
                    self.failRefresh(error ?? refreshError("Built-in SideStore quit unexpectedly"))
                }
            }
            scheduleLaunchTimeout(for: ext, completion: launchCompletion)
            try await launchCompletion.wait {
                Task { @MainActor in
                    await self.beginSideStoreRequest(ext, item: extensionItem)
                }
            }
            self.launchCompletion = nil
        }
    }

    private func beginSideStoreRequest(_ ext: NSExtension, item: NSExtensionItem) async {
        guard self.ext === ext, launchCompletion != nil else { return }
        let uuid = await ext.beginRequest(withInputItems: [item])
        guard self.ext === ext else {
            ext._kill(9)
            return
        }
        sideStorePid = ext.pid(forRequestIdentifier: uuid)
        guard sideStorePid > 0 else {
            failRefresh(refreshError("Built-in SideStore quit unexpectedly"))
            return
        }
        completeLaunchIfReady()
    }

    private func scheduleLaunchTimeout(for ext: NSExtension, completion: RefreshCompletion) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self, weak ext] in
            guard let self, let ext, self.ext === ext, self.launchCompletion === completion else { return }
            let error = refreshError("Built-in SideStore failed to start in reasonable time")
            guard completion.finish(.failure(error)) else { return }
            self.failRefresh(error)
        }
    }

    private func completeLaunchIfReady() {
        guard didFinishLaunching, sideStorePid > 0, client != nil else { return }
        launchCompletion?.finish(.success(()))
    }

    private func resetConnection() {
        didFinishLaunching = false
        sideStorePid = 0
        client = nil
        connection?.interruptionHandler = nil
        connection?.invalidationHandler = nil
        connection?.invalidate()
        connection = nil
        let oldExtension = ext
        ext = nil
        oldExtension?._kill(9)
    }

    private func failRefresh(_ error: Error) {
        launchCompletion?.finish(.failure(error))
        completion?.finish(.failure(error))
        launchCompletion = nil
        resetConnection()
    }

    nonisolated func updateProgress(_ value: Double) {
        Task { @MainActor in
            guard value.isFinite else { return }
            self.progress?.completedUnitCount = Int64(min(max(value, 0), 1) * 100)
        }
    }

    nonisolated func finish(_ error: String?, requestIdentifier: String) {
        Task { @MainActor in
            guard self.requestIdentifier == requestIdentifier else { return }
            let result: Result<Void, Error> = error.map { .failure(refreshError($0)) } ?? .success(())
            self.completion?.finish(result)
        }
    }

    nonisolated func onConnection(_ connection: NSXPCConnection!) {
        guard let connection else { return }
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        Task { @MainActor in
            self.acceptConnection(connection)
        }
    }

    private func acceptConnection(_ connection: NSXPCConnection) {
        guard requestIdentifier != nil, ext != nil else {
            connection.invalidate()
            return
        }
        self.connection = connection
        let connectionFailed: (Error) -> Void = { [weak self, weak connection] error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.failRefresh(error)
            }
        }
        connection.interruptionHandler = {
            connectionFailed(refreshError("Built-in SideStore quit unexpectedly"))
        }
        connection.invalidationHandler = connection.interruptionHandler
        let client = connection.remoteObjectProxyWithErrorHandler(connectionFailed) as? RefreshClient
        self.client = client
        guard client != nil else {
            failRefresh(refreshError("Built-in SideStore did not establish its background connection."))
            return
        }
        completeLaunchIfReady()
    }

    nonisolated func finishedLaunching() {
        Task { @MainActor in
            guard self.ext != nil else { return }
            self.didFinishLaunching = true
            self.completeLaunchIfReady()
        }
    }

    nonisolated func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add SideStore notification: \(error)")
            }
        }
    }

    nonisolated func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
}
