#if !CHINA_BUILD
//
//  AIAgentFileGrants.swift
//  rootshell
//
//  Folders the user has granted the AI agent's file tools (Mac). Stored per
//  device: the paths only mean something on this machine. Also owns the
//  agent's transient scratch directory.
//

import Foundation

enum AIAgentFileGrants {
    /// Granted folders, canonical, in the order they were added.
    static var all: [String] {
        guard let data = SettingsStore.shared.get(Settings.AI.fileGrants),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    /// Adds `folder` unless it is too broad or protected. Returns whether it is now granted.
    @discardableResult
    static func add(_ folder: String) -> Bool {
        let canonical = AIAgentFileAccessPolicy.canonical(folder)
        let policy = makePolicy(grants: [])
        guard !policy.isTooBroad(canonical),
              !policy.protectedPaths.contains(where: { AIAgentFileAccessPolicy.isInside(canonical, of: $0) })
        else { return false }
        var list = all
        if !list.contains(canonical) { list.append(canonical) }
        save(list)
        return true
    }

    static func remove(_ folder: String) {
        save(all.filter { $0 != folder })
    }

    private static func save(_ list: [String]) {
        let data = list.isEmpty ? nil : try? JSONEncoder().encode(list)
        SettingsStore.shared.set(Settings.AI.fileGrants, data)
    }

    // MARK: - Scratch directory

    /// Transient working area for agent sessions with no terminal directory.
    static var scratchDirectory: String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RootShellAgent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    static func makePolicy(grants: [String]? = nil) -> AIAgentFileAccessPolicy {
        AIAgentFileAccessPolicy(
            home: NSHomeDirectory(),
            scratch: scratchDirectory,
            grants: grants ?? all
        )
    }
}
#endif
