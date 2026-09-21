//
//  NativeSecItemShim.swift
//  rootshell
//
//  NATIVE flavor only: routes the app's SecItem calls to the login keychain
//  through the embedded native `rootshell-keychain` tool.
//
//  A Mac Catalyst process can only reach the data protection keychain
//  (TN3137). Without an Apple-issued provisioning profile every SecItem call
//  it makes fails with errSecMissingEntitlement (-34018), whatever identity
//  signed it. A native macOS process uses the login keychain instead, so the
//  calls are replayed there.
//
//  The seam is these four module-level functions. Swift resolves an
//  unqualified `SecItemAdd(...)` to the app module's declaration before the
//  one imported from Security, so every existing call site in this module is
//  rerouted with no edits. Other flavors do not compile this file and keep
//  calling Security directly.
//
//  Not proxied (returns errSecUnimplemented): queries that pass or return
//  object references (SecKey / SecCertificate / SecIdentity), which cannot
//  cross a process boundary. Today that is only the Kubernetes client
//  certificate identity in KubernetesAuthConfig.
//

#if NATIVE && targetEnvironment(macCatalyst)

import Foundation
import LocalAuthentication
import os.log
import Security

// swiftlint:disable identifier_name

nonisolated func SecItemAdd(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    NativeKeychainProxy.shared.perform(op: "add", query: attributes, attributes: nil, result: result)
}

nonisolated func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    NativeKeychainProxy.shared.perform(op: "copy", query: query, attributes: nil, result: result)
}

nonisolated func SecItemUpdate(_ query: CFDictionary, _ attributesToUpdate: CFDictionary) -> OSStatus {
    NativeKeychainProxy.shared.perform(op: "update", query: query, attributes: attributesToUpdate, result: nil)
}

nonisolated func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    NativeKeychainProxy.shared.perform(op: "delete", query: query, attributes: nil, result: nil)
}

// swiftlint:enable identifier_name

/// Client for the `rootshell-keychain` tool. One long-lived child process,
/// one request at a time; the child is respawned if it goes away.
nonisolated final class NativeKeychainProxy: @unchecked Sendable {
    static let shared = NativeKeychainProxy()

    private static let logger = Logger(subsystem: "com.rootshell", category: "NativeKeychainProxy")

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var toChild: Int32 = -1
    private var fromChild: Int32 = -1

    private init() {}

    // MARK: - SecItem entry point

    func perform(
        op: String,
        query: CFDictionary,
        attributes: CFDictionary?,
        result: UnsafeMutablePointer<CFTypeRef?>?
    ) -> OSStatus {
        guard let rawQuery = query as? [String: Any] else { return errSecParam }
        let sanitized = Self.sanitize(rawQuery)
        guard !sanitized.usesObjectReferences else { return errSecUnimplemented }

        var request: [String: Any] = ["op": op, "query": sanitized.plist]
        if sanitized.hadAccessControl { request["authRequired"] = true }
        if let attributes {
            guard let rawAttributes = attributes as? [String: Any] else { return errSecParam }
            request["attrs"] = Self.sanitize(rawAttributes).plist
        }

        guard var response = exchange(request) else { return errSecNotAvailable }

        // The login keychain cannot enforce SecAccessControl, so items saved
        // with a biometric/passcode requirement are gated here instead.
        if response["needsAuth"] as? Bool == true {
            let status = Self.authenticate(using: sanitized.authenticationContext)
            guard status == errSecSuccess else { return status }
            request["authorized"] = true
            guard let retried = exchange(request) else { return errSecNotAvailable }
            response = retried
        }

        let status = OSStatus(truncatingIfNeeded: response["status"] as? Int ?? Int(errSecInternalError))
        if status == errSecSuccess, let result, let value = response["result"] {
            result.pointee = value as CFTypeRef
        }
        return status
    }

    // MARK: - Query sanitising

    private enum Keys {
        static let accessControl = kSecAttrAccessControl as String
        static let authenticationContext = kSecUseAuthenticationContext as String
        static let itemClass = kSecClass as String
        static let objectReferences: Set<String> = [
            kSecValueRef as String, kSecReturnRef as String,
            kSecReturnPersistentRef as String, kSecValuePersistentRef as String,
        ]
        static let referenceClasses: Set<String> = [
            kSecClassKey as String, kSecClassCertificate as String, kSecClassIdentity as String,
        ]
    }

    private struct Sanitized {
        var plist: [String: Any] = [:]
        var hadAccessControl = false
        var usesObjectReferences = false
        var authenticationContext: LAContext?
    }

    /// Keeps the property-list-representable part of a query and records what
    /// was dropped. SecAccessControl and LAContext are live objects that cannot
    /// be serialised; both are handled by the in-app authentication gate.
    private static func sanitize(_ query: [String: Any]) -> Sanitized {
        var out = Sanitized()
        for (key, value) in query {
            if key == Keys.accessControl {
                out.hadAccessControl = true
            } else if key == Keys.authenticationContext {
                out.authenticationContext = value as? LAContext
            } else if Keys.objectReferences.contains(key) {
                out.usesObjectReferences = true
            } else if let safe = plistSafe(value) {
                if key == Keys.itemClass, let itemClass = safe as? String, Keys.referenceClasses.contains(itemClass) {
                    out.usesObjectReferences = true
                }
                out.plist[key] = safe
            }
        }
        return out
    }

    private static func plistSafe(_ value: Any) -> Any? {
        switch value {
        case let v as String: return v
        case let v as Data: return v
        case let v as Date: return v
        case let v as NSNumber: return v
        case let v as [Any]: return v.compactMap(plistSafe)
        case let v as [String: Any]: return v.compactMapValues(plistSafe)
        default: return nil
        }
    }

    // MARK: - Authentication gate

    private static func authenticate(using provided: LAContext?) -> OSStatus {
        let context = provided ?? LAContext()
        let reason = String(localized: "Access a protected key")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: OSStatus = errSecAuthFailed
        // The reply arrives on a private queue, so waiting here is safe even
        // when SecItem was called on the main thread (as the Keychain's own
        // authentication prompt would also block the caller).
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
            if success {
                outcome = errSecSuccess
            } else if let code = (error as? LAError)?.code, code == .userCancel || code == .appCancel || code == .systemCancel {
                outcome = errSecUserCanceled
            }
            done.signal()
        }
        done.wait()
        return outcome
    }

    // MARK: - Child process

    private func exchange(_ request: [String: Any]) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        // One retry covers a child that exited since the previous request.
        for _ in 0..<2 {
            guard ensureChild() else { return nil }
            if let response = roundTrip(request) { return response }
            teardownChild()
        }
        Self.logger.error("rootshell-keychain did not answer")
        return nil
    }

    private func roundTrip(_ request: [String: Any]) -> [String: Any]? {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: request, format: .binary, options: 0) else {
            return nil
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        guard Self.writeAll(toChild, frame),
              let header = Self.readExactly(fromChild, 4) else { return nil }
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 64 * 1024 * 1024, let payload = Self.readExactly(fromChild, count) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil)) as? [String: Any]
    }

    private func ensureChild() -> Bool {
        if pid > 0, kill(pid, 0) == 0 { return true }
        teardownChild()

        let toolPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/rootshell-keychain").path
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            Self.logger.error("rootshell-keychain is missing from the app bundle: \(toolPath, privacy: .public)")
            return false
        }

        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0 else { return false }
        guard pipe(&stdoutPipe) == 0 else {
            close(stdinPipe[0]); close(stdinPipe[1])
            return false
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        // Close every descriptor the file actions did not set up explicitly.
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(toolPath), nil]
        var envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        var child: pid_t = 0
        let rc = posix_spawn(&child, toolPath, &actions, &attrs, &argv, &envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attrs)
        for pointer in argv + envp where pointer != nil { free(pointer) }
        close(stdinPipe[0])
        close(stdoutPipe[1])

        guard rc == 0 else {
            Self.logger.error("posix_spawn(rootshell-keychain) failed: \(rc)")
            close(stdinPipe[1]); close(stdoutPipe[0])
            return false
        }
        pid = child
        toChild = stdinPipe[1]
        fromChild = stdoutPipe[0]
        // A dead child must surface as a write error, not SIGPIPE.
        _ = fcntl(toChild, F_SETNOSIGPIPE, 1)
        return true
    }

    private func teardownChild() {
        if toChild >= 0 { close(toChild) }
        if fromChild >= 0 { close(fromChild) }
        toChild = -1
        fromChild = -1
        if pid > 0 {
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGTERM)
                waitpid(pid, &status, 0)
            }
        }
        pid = 0
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if errno != EINTR { return false }
            }
            return true
        }
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if n > 0 { offset += n } else if n == 0 { return nil } else if errno != EINTR { return nil }
        }
        return data
    }
}

#endif // NATIVE && targetEnvironment(macCatalyst)
