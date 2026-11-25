//
//  SideStoreClient.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import OSLog

enum SideStoreIntentError: LocalizedError {
    case typeNotFound(String)
    case typeIsNotAppIntent(String)

    var errorDescription: String? {
        switch self {
        case .typeNotFound(let name):
            return "SideStore refresh intent type was not found: \(name)"
        case .typeIsNotAppIntent(let name):
            return "SideStore type is not an AppIntent: \(name)"
        }
    }
}

@available(iOS 17.0, *)
private func resolveType(_ mangledTypeName: String) throws -> any Any.Type {
    let bytes = Array(mangledTypeName.utf8)
    let resolvedType: Any.Type? = bytes.withUnsafeBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else {
            return nil
        }

        // Swift exposes the runtime symbol swift_getTypeByMangledNameInContext
        // as _getTypeByMangledNameInContext. The name intentionally omits
        // the "$s" prefix, which is the form accepted for this module.
        return _getTypeByMangledNameInContext(
            baseAddress,
            UInt(buffer.count),
            genericContext: nil,
            genericArguments: nil
        )
    }

    guard let resolvedType else {
        throw SideStoreIntentError.typeNotFound(mangledTypeName)
    }

    return resolvedType
}

@available(iOS 17.0, *)
struct SideStoreIntentCaller {
    static let shared = SideStoreIntentCaller()

    func callTrackedRefresh(requestIdentifier: String, bounded: Bool = false,
                            progressCallback: (Progress) -> Void) async throws {
        let completion = RefreshCompletion()
        let timer: Task<Void, Never>? = bounded ? Task {
            do { try await Task.sleep(nanoseconds: 27_000_000_000) }
            catch { return }
            completion.finish(.failure(ShortcutRefreshResult.pendingError(message: ShortcutRefreshResult.localized("Refresh is preparing or still running. Keep the VPN connected until its final result is available."))))
        } : nil
        defer { timer?.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await completion.wait {
                let progress = startSideStoreTrackedRefresh(requestIdentifier) { error in
                    completion.finish(error.map { .failure($0) } ?? .success(()))
                }
                if let progress { progressCallback(progress) }
            }
        } onCancel: {
            // The app's execution and durable receipt outlive this observer.
            completion.finish(.failure(CancellationError()))
        }
    }

    func callRequestedRefresh(identifier: String, mangledTypeName: String, requestIdentifier: String,
                              progressCallback: (Progress) -> Void) async throws {
        if identifier == "RefreshAllIntent" {
            try await callTrackedRefresh(requestIdentifier: requestIdentifier, progressCallback: progressCallback)
        } else {
            try await callRefreshIntent2(identifier: identifier, mangledTypeName: mangledTypeName, progressCallback: progressCallback)
        }
    }
    
    // call this when a IntentContext already exists (when sidestore is loaded in LiveContainer itself)
    func callRefreshIntent(mangledTypeName: String) async throws {
        let resolvedType = try resolveType(mangledTypeName)
        guard let intentType = resolvedType as? any ProgressReportingIntent.Type else {
            throw SideStoreIntentError.typeIsNotAppIntent(mangledTypeName)
        }
        
        let intent = intentType.init()
        let _ = try await intent.perform()
    }
    
    // call this when no IntentContext exists (when sidestore is loaded in LiveProcess)
    func callRefreshIntent2(identifier: String, mangledTypeName: String, progressCallback: (Progress)->Void ) async throws {
        let completion = RefreshCompletion()
        try await completion.wait {
            let parent = PrivateIntentRunner.run(
                        identifier: identifier,
                        mangledTypeName: mangledTypeName
                    ) { result, error in
                        print("performAction result=\(String(describing: result)), " +
                              "error=\(String(describing: error))")
                        if let error {
                            completion.finish(.failure(error))
                        } else {
                            completion.finish(.success(()))
                        }
                    }
            if let parent {
                progressCallback(parent)
            }
        }
    }
}

@available(iOS 17.0, *)
@objc extension SideStoreClient {
    @objc(performRefreshForRealWithIdentifier:mangledTypeName:requestIdentifier:server:)
    func performRefreshForReal(identifier: String, mangledTypeName: String, requestIdentifier: String, server: any RefreshServer) {
        Task {
            var obs: NSKeyValueObservation? = nil
            defer { obs?.invalidate() }
            do {
                try await SideStoreIntentCaller.shared.callRequestedRefresh(identifier: identifier, mangledTypeName: mangledTypeName,
                                                                           requestIdentifier: requestIdentifier) { progress in
                    obs = observeRefreshProgress(progress, server: server)
                }
                server.finish(nil, requestIdentifier: requestIdentifier)
            } catch {
                server.finish(ShortcutRefreshResult.transportError(error), requestIdentifier: requestIdentifier)
            }
        }
    }

}

private func observeRefreshProgress(_ progress: Progress, server: any RefreshServer) -> NSKeyValueObservation {
    progress.observe(\.fractionCompleted, options: [.new]) { _, change in
        guard let value = change.newValue else { return }
        server.updateProgress(value)
    }
}
