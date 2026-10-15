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
    /// False when `folder` is too broad to ever grant (home, an ancestor of home, "/").
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
    }

    func decide(resolvedPath: String, workingDirectory: String) -> Decision {
        let path = Self.canonical(resolvedPath)

        if let hit = protectedPaths.first(where: { Self.isInside(path, of: $0) }) {
            return .denied(reason: "\(hit) holds credentials or app secrets and is never available to the agent")
        }

        var roots = grants.filter { !isTooBroad($0) }
        roots.append(scratch)
        let cwd = Self.canonical(workingDirectory)
        if !workingDirectory.isEmpty, !isTooBroad(cwd) { roots.append(cwd) }

        if roots.contains(where: { Self.isInside(path, of: $0) }) { return .allowed }

        let folder = Self.grantFolder(for: path)
        return .needsGrant(AIAgentFileScopeRequest(
            resolvedPath: path,
            folder: folder,
            canGrantAlways: !isTooBroad(folder) && !protectedPaths.contains(where: { Self.isInside(folder, of: $0) })
        ))
    }

    /// Home itself, an ancestor of home ("/", "/Users"), or a system root can't
    /// be an implicit or granted root: that would re-open everything under it.
    func isTooBroad(_ folder: String) -> Bool {
        let folderPath = Self.canonical(folder)
        if folderPath == "/" || folderPath == home { return true }
        if Self.isInside(home, of: folderPath) { return true }
        let systemRoots = [
            "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/private", "/Applications", "/Volumes"
        ]
        return systemRoots.contains(folderPath)
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

    /// Collapse `.`/`..` and resolve symlinks. A path that does not exist yet
    /// (write_file creating a file) is resolved through its longest existing
    /// ancestor so a symlinked parent can't be used to escape a root.
    static func canonical(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard !standardized.isEmpty else { return standardized }
        let fileManager = FileManager.default
        var existing = standardized
        var tail: [String] = []
        while existing != "/", !fileManager.fileExists(atPath: existing) {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/"; break }
        }
        var resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        for component in tail { resolved = (resolved as NSString).appendingPathComponent(component) }
        return resolved
    }

    /// Whole-component prefix test: "/a/bc" is not inside "/a/b".
    static func isInside(_ path: String, of root: String) -> Bool {
        if path == root { return true }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix)
    }
}
#endif
