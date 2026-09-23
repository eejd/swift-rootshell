//
//  GhosttyStorageLocation.swift
//  rootshell
//
//  Base directory for sync/backup/config state that several managers store
//  as loose files (SyncableFileStore, CloudKitSyncManager's legacy queue,
//  CloudKitOfflineQueue, UserDefaultsBackup, KeybindManager's imported
//  config). Distinct from ConfigOverlayLocation, which covers the single
//  user-facing text config file and deliberately stays under ~/.config --
//  that's a different data class (human-editable) from the opaque
//  per-record state this file covers.
//
//  Three generations of base directory on STANDALONE, oldest to newest:
//    1. Documents/.ghostty      -- the original, TCC-gated location (see
//                                   preHive4LegacyBaseDirectory's comment)
//    2. .config/rootshell       -- gen 2 (hive4), matched
//                                   ConfigOverlayLocation's precedent,
//                                   since superseded
//    3. Library/Application Support/RootShell -- current (hive5). Matches
//                                   this overlay's other Xcode-built app
//                                   port (aqua/nativ keeps its analytics
//                                   SQLite under Application Support/Nativ,
//                                   see docs/lessons/swift-app-ports.md) --
//                                   the better-precedented choice for
//                                   opaque app state nobody hand-edits.
//                                   Neither #2 nor #3 is TCC-protected;
//                                   that was never what distinguished them.
//

import Foundation
import os.log

nonisolated enum GhosttyStorageLocation {
    #if STANDALONE && targetEnvironment(macCatalyst)
    /// Non-sandboxed Mac. See the file-header comment for why this is
    /// Application Support and not Documents (TCC) or .config (precedent
    /// mismatch -- see gen 2 there).
    private static var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RootShell", isDirectory: true)
    }

    /// Gen 2 (hive4): ~/.config/rootshell. Superseded by baseDirectory, but
    /// still a migration source for any install that already moved off
    /// Documents under hive4 before this change shipped.
    private static var hive4LegacyBaseDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/rootshell", isDirectory: true)
    }

    /// Gen 1: the original TCC-gated Documents/.ghostty location.
    /// `~/Documents` is TCC-protected on macOS -- unlike on iOS, where a
    /// sandboxed app's `.documentDirectory` resolves inside its own private
    /// container and is never TCC-gated.
    private static var preHive4LegacyBaseDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ghostty", isDirectory: true)
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "GhosttyStorageLocation")

    /// Resolve a relative path under the current base, migrating it from
    /// whichever legacy generation it's found under (checked newest-legacy
    /// first) the first time it's asked for. One-time and per-path -- each
    /// caller only knows its own subpath, so this never has to enumerate a
    /// whole legacy tree.
    static func url(forRelativePath relativePath: String) -> URL {
        let new = baseDirectory.appendingPathComponent(relativePath)
        let fm = FileManager.default
        if !fm.fileExists(atPath: new.path) {
            let legacyCandidates = [hive4LegacyBaseDirectory, preHive4LegacyBaseDirectory]
            for legacyBase in legacyCandidates {
                let legacy = legacyBase.appendingPathComponent(relativePath)
                guard fm.fileExists(atPath: legacy.path) else { continue }
                do {
                    try fm.createDirectory(
                        at: new.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fm.moveItem(at: legacy, to: new)
                } catch {
                    // Data isn't lost -- it's still at `legacy` -- but a
                    // failed migration otherwise looks identical to "never
                    // had any data", which is worth being able to diagnose.
                    logger.error("Failed to migrate \(relativePath) from \(legacyBase.path): \(error.localizedDescription)")
                }
                break
            }
        }
        return new
    }
    #else
    /// Sandboxed builds (iOS): unchanged, Documents/.ghostty is private to
    /// the app's own container and never TCC-gated.
    static func url(forRelativePath relativePath: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent(relativePath)
    }
    #endif
}
