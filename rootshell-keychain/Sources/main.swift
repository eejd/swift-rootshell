//
//  main.swift
//  rootshell-keychain
//
//  Native macOS Keychain proxy for the NATIVE flavor.
//
//  A Mac Catalyst process can only reach the data protection keychain
//  (TN3137), which needs entitlements backed by an Apple-issued provisioning
//  profile. A native macOS process has no such restriction: it uses the
//  user's login keychain under any signature, ad-hoc included. The Catalyst
//  app therefore spawns this tool and replays its SecItem calls through it.
//
//  Wire format, both directions, over stdin/stdout: a 4-byte big-endian
//  length followed by a binary property list. Secrets never appear in argv
//  or the environment. See NativeSecItemShim.swift for the client.
//
//  Request:  { op: add|copy|update|delete, query: {..}, attrs: {..}?,
//              authRequired: Bool?, authorized: Bool? }
//  Response: { status: OSStatus, result: plist?, needsAuth: Bool? }
//

import Foundation
import Security

// MARK: - Caller validation

/// Refuses to serve anything but the app bundle this tool is embedded in.
///
/// The login keychain trusts *this tool's* code identity, so whoever can
/// drive the tool can read the items. Checks, in order:
///   1. the tool runs from `<App>.app/Contents/Helpers/`;
///   2. the parent process is that bundle's main executable;
///   3. the parent's code signature is valid and carries the bundle's
///      identifier, plus this tool's Team ID when it has one;
///   4. unless both are Team-signed, the tool and the parent executable are
///      not writable by the invoking user (root-owned install, e.g. under
///      /Applications/MacPorts), so a same-user process cannot stand up a
///      look-alike bundle around a copy of this tool.
///
/// Limitation: with no Team ID these checks raise the bar but cannot fully
/// authenticate the caller against same-user malware (a process can spawn the
/// tool and then exec the real app). Sign with a stable identity to close it.
enum CallerValidation {
    static func validate() -> String? {
        guard let selfPath = realPath(Bundle.main.executablePath) else { return "cannot resolve own path" }
        let helpersDir = (selfPath as NSString).deletingLastPathComponent
        let contentsDir = (helpersDir as NSString).deletingLastPathComponent
        guard (helpersDir as NSString).lastPathComponent == "Helpers",
              (contentsDir as NSString).lastPathComponent == "Contents" else {
            return "not embedded in an app bundle"
        }
        let infoURL = URL(fileURLWithPath: contentsDir).appendingPathComponent("Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              let executable = info["CFBundleExecutable"] as? String,
              let bundleID = info["CFBundleIdentifier"] as? String else {
            return "enclosing bundle has no usable Info.plist"
        }
        let expectedParent = (contentsDir as NSString).appendingPathComponent("MacOS/\(executable)")

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getppid(), &buffer, UInt32(buffer.count)) > 0,
              let parentPath = realPath(String(cString: buffer)) else {
            return "cannot resolve parent process"
        }
        guard parentPath == realPath(expectedParent) else { return "parent is not the enclosing app" }

        var parentCode: SecCode?
        let attrs = [kSecGuestAttributePid: getppid()] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &parentCode) == errSecSuccess,
              let parentCode else { return "cannot obtain parent code object" }

        let ownTeam = ownTeamIdentifier()
        var requirementText = "identifier \"\(bundleID)\""
        if let ownTeam {
            requirementText += " and anchor apple generic and certificate leaf[subject.OU] = \"\(ownTeam)\""
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              SecCodeCheckValidity(parentCode, [], requirement) == errSecSuccess else {
            return "parent failed code signature validation"
        }

        if ownTeam == nil {
            for path in [selfPath, parentPath] where !isProtectedFromInvokingUser(path) {
                return "\(path) is writable by the invoking user and no Team ID is present"
            }
        }
        return nil
    }

    private static func realPath(_ path: String?) -> String? {
        guard let path, let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func ownTeamIdentifier() -> String? {
        var own: SecCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func isProtectedFromInvokingUser(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        #if DEBUG
        // DEBUG builds weaken caller validation and must never be distributed.
        return true
        #else
        return st.st_uid != getuid() && (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
        #endif
    }
}

// MARK: - Framing

enum Framing {
    static func read() -> [String: Any]? {
        guard let header = readExactly(4) else { return nil }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= 64 * 1024 * 1024, let body = readExactly(length) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any]
    }

    static func write(_ response: [String: Any]) {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: response, format: .binary, options: 0) else {
            // Never leave the client waiting for a reply it will not get.
            if response["status"] as? Int == Int(errSecInternalError) { return }
            write(["status": Int(errSecInternalError)])
            return
        }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if errno != EINTR { return }
            }
        }
    }

    private static func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let n = data.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress! + offset, count - offset) }
            if n > 0 { offset += n } else if n == 0 { return nil } else if errno != EINTR { return nil }
        }
        return data
    }
}

// MARK: - Query translation

enum Translation {
    /// Marks items the app saved with a biometric/passcode requirement. The
    /// login keychain cannot enforce SecAccessControl, so the app gates reads
    /// of marked items with LocalAuthentication itself.
    static let authMarker = "rootshell:auth-required"

    /// Attributes that only mean something to the data protection keychain.
    private static let dataProtectionOnly: [String] = [
        kSecAttrAccessGroup as String,
        kSecAttrSynchronizable as String,
        kSecAttrAccessible as String,
        kSecAttrAccessControl as String,
        kSecUseDataProtectionKeychain as String,
    ]

    static func native(_ query: [String: Any], adding: Bool = false) -> [String: Any] {
        var out = query
        for key in dataProtectionOnly { out.removeValue(forKey: key) }
        #if DEBUG
        if let keychain = TestKeychain.shared {
            out[(adding ? kSecUseKeychain : kSecMatchSearchList) as String] = adding ? keychain : [keychain]
        }
        #endif
        return out
    }

    /// Reduces a SecItem result to property-list types.
    static func plistSafe(_ value: Any) -> Any? {
        switch value {
        case let v as String: return v
        case let v as Data: return v
        case let v as Date: return v
        case let v as NSNumber: return v
        case let v as [Any]: return v.compactMap(plistSafe)
        case let v as [String: Any]:
            var out: [String: Any] = [:]
            for (key, item) in v { if let safe = plistSafe(item) { out[key] = safe } }
            return out
        default: return nil
        }
    }
}

#if DEBUG
/// Test-only: redirects every operation to a throwaway keychain so the proxy
/// can be exercised without touching (or unlocking) the login keychain.
enum TestKeychain {
    static let shared: SecKeychain? = {
        guard let path = ProcessInfo.processInfo.environment["ROOTSHELL_KEYCHAIN_TEST_PATH"] else { return nil }
        var keychain: SecKeychain?
        return SecKeychainOpen(path, &keychain) == errSecSuccess ? keychain : nil
    }()
}
#endif

// MARK: - Operations

enum Operations {
    static func handle(_ request: [String: Any]) -> [String: Any] {
        guard let op = request["op"] as? String, let rawQuery = request["query"] as? [String: Any] else {
            return ["status": Int(errSecParam)]
        }
        let query = Translation.native(rawQuery)
        switch op {
        case "add":
            var item = Translation.native(rawQuery, adding: true)
            if request["authRequired"] as? Bool == true {
                item[kSecAttrComment as String] = Translation.authMarker
            }
            return ["status": Int(SecItemAdd(item as CFDictionary, nil))]
        case "update":
            guard let attrs = request["attrs"] as? [String: Any] else { return ["status": Int(errSecParam)] }
            let status = SecItemUpdate(query as CFDictionary, Translation.native(attrs) as CFDictionary)
            return ["status": Int(status)]
        case "delete":
            return ["status": Int(SecItemDelete(query as CFDictionary))]
        case "copy":
            return copy(query, authorized: request["authorized"] as? Bool == true)
        default:
            return ["status": Int(errSecParam)]
        }
    }

    private static func copy(_ query: [String: Any], authorized: Bool) -> [String: Any] {
        let wantsData = query[kSecReturnData as String] as? Bool == true
        let wantsAttributes = query[kSecReturnAttributes as String] as? Bool == true
        let matchAll = (query[kSecMatchLimit as String] as? String) == (kSecMatchLimitAll as String)

        // Always fetch attributes so the auth marker is visible; the login
        // keychain rejects kSecReturnData with kSecMatchLimitAll, so secrets
        // for a match-all query are fetched per item below.
        var lookup = query
        lookup[kSecReturnAttributes as String] = true
        if matchAll { lookup.removeValue(forKey: kSecReturnData as String) }

        var raw: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &raw)
        guard status == errSecSuccess else { return ["status": Int(status)] }

        let items: [[String: Any]]
        if let many = raw as? [[String: Any]] { items = many } else if let one = raw as? [String: Any] { items = [one] } else {
            return ["status": Int(errSecSuccess)]
        }

        if wantsData, !authorized,
           items.contains(where: { ($0[kSecAttrComment as String] as? String) == Translation.authMarker }) {
            return ["status": Int(errSecInteractionRequired), "needsAuth": true]
        }

        var shaped: [Any] = []
        for var item in items {
            if wantsData, matchAll { item[kSecValueData as String] = secret(for: item, in: query) }
            if wantsData, !wantsAttributes {
                if let data = item[kSecValueData as String] as? Data { shaped.append(data) }
            } else if wantsAttributes {
                if !wantsData { item.removeValue(forKey: kSecValueData as String) }
                if let safe = Translation.plistSafe(item) { shaped.append(safe) }
            }
        }
        guard wantsData || wantsAttributes else { return ["status": Int(errSecSuccess)] }
        if matchAll { return ["status": Int(errSecSuccess), "result": shaped] }
        guard let first = shaped.first else { return ["status": Int(errSecItemNotFound)] }
        return ["status": Int(errSecSuccess), "result": first]
    }

    private static func secret(for item: [String: Any], in query: [String: Any]) -> Data? {
        var single: [String: Any] = [
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        for key in [kSecClass, kSecMatchSearchList] where query[key as String] != nil {
            single[key as String] = query[key as String]
        }
        for key in [kSecAttrService, kSecAttrAccount, kSecAttrServer, kSecAttrApplicationTag] {
            if let value = item[key as String] ?? query[key as String] { single[key as String] = value }
        }
        var raw: CFTypeRef?
        guard SecItemCopyMatching(single as CFDictionary, &raw) == errSecSuccess else { return nil }
        return raw as? Data
    }
}

// MARK: - Entry point

#if DEBUG
let skipCallerCheck = ProcessInfo.processInfo.environment["ROOTSHELL_KEYCHAIN_TEST_PATH"] != nil
#else
let skipCallerCheck = false
#endif

if !skipCallerCheck, let reason = CallerValidation.validate() {
    FileHandle.standardError.write(Data("rootshell-keychain: refusing to run: \(reason)\n".utf8))
    exit(EXIT_FAILURE)
}

signal(SIGPIPE, SIG_IGN)
while let request = Framing.read() {
    Framing.write(Operations.handle(request))
}
