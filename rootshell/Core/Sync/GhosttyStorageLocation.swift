//
//  GhosttyStorageLocation.swift
//  rootshell
//
//  Base directory for sync/backup/config state that several managers store
//  as loose files (SyncableFileStore, CloudKitSyncManager's legacy queue,
//  CloudKitOfflineQueue, UserDefaultsBackup, KeybindManager's imported
//  config). Distinct from ConfigOverlayLocation, which covers the single
//  user-facing text config file.
//

import Foundation

nonisolated enum GhosttyStorageLocation {
    #if STANDALONE && targetEnvironment(macCatalyst)
    /// Non-sandboxed Mac. `~/Documents` is TCC-protected on macOS -- unlike
    /// on iOS, where a sandboxed app's `.documentDirectory` resolves inside
    /// its own private container and is never TCC-gated. `~/.config` is
    /// not, matching the choice ConfigOverlayLocation already makes for the
    /// user-facing text config file. Using it here means none of this
    /// state requires a Full Disk Access / Documents Folder grant.
    private static var baseDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/rootshell", isDirectory: true)
    }

    private static var legacyBaseDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ghostty", isDirectory: true)
    }

    /// Resolve a relative path under the new base, migrating it from the
    /// legacy Documents/.ghostty location the first time it's asked for.
    /// One-time and per-path -- each caller only knows its own subpath, so
    /// this never has to enumerate the whole legacy tree.
    static func url(forRelativePath relativePath: String) -> URL {
        let new = baseDirectory.appendingPathComponent(relativePath)
        let fm = FileManager.default
        if !fm.fileExists(atPath: new.path) {
            let legacy = legacyBaseDirectory.appendingPathComponent(relativePath)
            if fm.fileExists(atPath: legacy.path) {
                try? fm.createDirectory(
                    at: new.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? fm.moveItem(at: legacy, to: new)
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
