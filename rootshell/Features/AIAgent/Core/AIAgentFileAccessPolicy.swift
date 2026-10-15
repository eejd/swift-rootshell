#if !CHINA_BUILD
//
//  AIAgentFileAccessPolicy.swift
//  rootshell
//
//  Which paths the AI agent's file tools (read_file / write_file / edit_file /
//  list_files) may touch on the unsandboxed Mac build. Restrictive by default:
//  nothing is reachable until it is the session's working directory, a folder
//  the user granted, or the agent's temp scratch directory. $HOME itself is
//  never an implicit or grantable root, and a short list of credential
//  locations is refused no matter what has been granted.
//
//  Pure logic with explicit inputs so it is testable off-device; the
//  Catalyst-only wiring lives in AIAgentFileToolHandler / AIAgentFileGrants.
//

import Foundation

/// A file-tool call that reached outside the allowed folders and is waiting
/// for the user (Allow once / Always allow / Deny).
struct AIAgentFileScopeRequest: Equatable, Sendable {
    /// Canonical path the call wants to touch.
    let resolvedPath: String
    /// Canonical folder an "always allow" grant would add.
    let folder: String
    /// False when `folder` is too broad to ever grant (home, an ancestor of home, a system folder).
    let canGrantAlways: Bool
}

nonisolated struct AIAgentFileAccessPolicy: Sendable {
    enum Decision: Equatable, Sendable {
        case allowed
        case needsGrant(AIAgentFileScopeRequest)
        case denied(reason: String)
    }

    /// Canonical home directory.
    let home: String
    /// Canonical scratch directory (always allowed).
    let scratch: String
    /// Canonical granted folders.
    let grants: [String]
    /// Canonical locations refused even when inside a grant.
    let protectedPaths: [String]
    /// System locations that can't be an implicit or granted root.
    private let systemFolders: [String]
    /// Shared folders that can't be a root themselves (their children can).
    private let sharedFolders: [String]

    init(home: String, scratch: String, grants: [String], extraProtected: [String] = []) {
        self.home = Self.canonical(home)
        self.scratch = Self.canonical(scratch)
        self.grants = grants.map(Self.canonical)
        let homePath = self.home
        let defaults = [
            homePath + "/.ssh",
            homePath + "/.gnupg",
            homePath + "/.aws",
            homePath + "/Library/Keychains",
            homePath + "/Library/Application Support/RootShell"
        ]
        self.protectedPaths = (defaults + extraProtected).map(Self.canonical)
        self.systemFolders = [
            "/System", "/usr", "/bin", "/sbin", "/etc", "/Library", "/var/root", "/var/db"
        ].map(Self.canonical)
        self.sharedFolders = [
            "/", "/private", "/var", "/tmp", "/Applications", "/Volumes", "/Users"
        ].map(Self.canonical)
    }

    func decide(resolvedPath: String, workingDirectory: String) -> Decision {
        let path = Self.canonical(resolvedPath)

        if let hit = protectedPaths.first(where: { Self.isInside(path, of: $0, caseInsensitive: true) }) {
            return .denied(reason: "\(hit) holds credentials or app secrets and is never available to the agent")
        }

        var roots = grants.filter { !isTooBroad($0) }
        roots.append(scratch)
        if !workingDirectory.isEmpty {
            let cwd = Self.canonical(workingDirectory)
            if !isTooBroad(cwd) { roots.append(cwd) }
        }

        if roots.contains(where: { Self.isInside(path, of: $0) }) { return .allowed }

        let folder = Self.grantFolder(for: path)
        return .needsGrant(AIAgentFileScopeRequest(
            resolvedPath: path,
            folder: folder,
            canGrantAlways: !isTooBroad(folder)
                && !protectedPaths.contains(where: { Self.isInside(folder, of: $0, caseInsensitive: true) })
        ))
    }

    /// Home itself, an ancestor of home, a system folder or a shared top-level folder can't
    /// be an implicit or granted root: that would re-open everything under it. Compared
    /// case-insensitively because the default APFS volume is.
    func isTooBroad(_ folder: String) -> Bool {
        let folderPath = Self.canonical(folder)
        if Self.isInside(home, of: folderPath, caseInsensitive: true) { return true }
        if sharedFolders.contains(where: { $0.caseInsensitiveCompare(folderPath) == .orderedSame }) { return true }
        return systemFolders.contains(where: { Self.isInside(folderPath, of: $0, caseInsensitive: true) })
    }

    // MARK: - Path helpers

    /// Directory an "always allow" would grant: the path itself when it is an
    /// existing directory, otherwise its parent.
    static func grantFolder(for canonicalPath: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDir), isDir.boolValue {
            return canonicalPath
        }
        return (canonicalPath as NSString).deletingLastPathComponent
    }

    /// Resolve a path the way the kernel would: component by component, following each
    /// symlink where it is met, so `link/../x` means the parent of the link's *target*.
    /// Components that do not exist yet (write_file creating a file) are kept as-is. Result
    /// is absolute, free of `.`/`..`/symlinks, and has the APFS firmlink prefix removed.
    /// Idempotent, so a handler that opens the result opens exactly what was judged.
    static func canonical(_ path: String) -> String {
        let fileManager = FileManager.default
        var queue = components(path)
        var resolved: [String] = []
        var hops = 0
        while !queue.isEmpty {
            let component = queue.removeFirst()
            if component == "." { continue }
            if component == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                if hops > 40 { return candidate } // symlink loop: leave unresolved; it will not match a root
                if target.hasPrefix("/") { resolved = [] }
                queue.insert(contentsOf: components(target), at: 0)
            } else {
                resolved.append(component)
            }
        }
        // Data volume firmlink: /System/Volumes/Data/Users/x is /Users/x.
        if resolved.count >= 3, resolved[0] == "System", resolved[1] == "Volumes", resolved[2] == "Data" {
            resolved.removeFirst(3)
        }
        return "/" + resolved.joined(separator: "/")
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whole-component prefix test: "/a/bc" is not inside "/a/b".
    static func isInside(_ path: String, of root: String, caseInsensitive: Bool = false) -> Bool {
        let (lhs, rhs) = caseInsensitive ? (path.lowercased(), root.lowercased()) : (path, root)
        if lhs == rhs { return true }
        let prefix = rhs.hasSuffix("/") ? rhs : rhs + "/"
        return lhs.hasPrefix(prefix)
    }
}
#endif
