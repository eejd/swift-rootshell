//
//  ProtectedDataGuard.swift
//  rootshell
//
//  Guards against reading/writing UserDefaults before the device is unlocked.
//  On iPadOS 26+, background launches (VPN, Live Activities, CloudKit push)
//  can start the app process before protected data is available, causing
//  UserDefaults to return empty values and overwrite real settings.
//

import UIKit
import os.log

enum ProtectedDataGuard {
    private nonisolated static let logger = Logger(subsystem: "com.rootshell", category: "ProtectedDataGuard")
    private nonisolated static let protectedDataQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.rootshell.protectedDataGuard"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    /// Whether the device is unlocked and protected data (including UserDefaults) is readable.
    @MainActor
    static var isAvailable: Bool {
        UIApplication.shared.isProtectedDataAvailable
    }

    /// Runs `action` once protected data is available.
    ///
    /// This is intentionally not gated on foreground activation: protected-data
    /// work such as migrations, push registration, and CloudKit maintenance must
    /// still run during background launches/unlocks.
    @MainActor
    static func whenAvailable(_ action: @MainActor @escaping @Sendable () -> Void) {
        if isAvailable {
            runWhenProtectedDataAvailable(action, reason: "available")
            return
        }
        logger.warning("Protected data NOT available — deferring initialization")
        final class TokenHolder: @unchecked Sendable {
            var token: NSObjectProtocol?
            // Accessed only by the MainActor task below. The notification
            // queue only retains the holder; it never mutates it.
            var didRun = false
        }
        let holder = TokenHolder()
        holder.token = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: protectedDataQueue
        ) { _ in
            Task { @MainActor in
                // A notification is not a proof that the receiving process
                // can read its protected preferences yet. Keep the observer
                // armed until the MainActor confirms availability; otherwise
                // a lock/unlock race permanently drops this caller's work.
                guard !holder.didRun, UIApplication.shared.isProtectedDataAvailable else {
                    logger.warning("Protected data notification arrived before data was readable; keeping observer armed")
                    return
                }
                holder.didRun = true
                if let token = holder.token {
                    NotificationCenter.default.removeObserver(token)
                    holder.token = nil
                }
                _ = runWhenProtectedDataAvailable(action, reason: "unlock")
            }
        }
    }

    @MainActor
    private static func runWhenProtectedDataAvailable(
        _ action: @MainActor @escaping @Sendable () -> Void,
        reason: String
    ) -> Bool {
        guard UIApplication.shared.isProtectedDataAvailable else {
            logger.warning("Protected data notification fired but protected data is unavailable")
            return false
        }

        logger.info("Protected data available")

        // This method is MainActor-isolated. Running synchronously avoids a
        // second lock transition in the former DispatchQueue.main.async gap.
        LifecycleDebugLogger.shared.checkpoint("ProtectedData.run", ms: nil, [
            ("reason", reason),
            ("appState", String(describing: UIApplication.shared.applicationState)),
        ])
        action()
        return true
    }
}
