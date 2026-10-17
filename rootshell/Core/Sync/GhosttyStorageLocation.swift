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
//    1. Documents/.ghostty      -- the original, TCC-gated location. Never
//                                   read automatically; copied only by the
//                                   explicit Settings import.
//    2. .config/rootshell       -- gen 2 (hive4), matched
//                                   ConfigOverlayLocation's precedent,
//                                   since superseded; adopted automatically
//                                   by copying missing files.
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

    /// Adopts missing `.config/rootshell` files, once per path per process.
    /// Documents/.ghostty (gen 1) is TCC-protected and is deliberately never
    /// consulted here; Settings → Import from Documents copies it on request
    /// (see `LegacyStorageImporter.importDocuments`).
    private static let resolver = LegacyStorageResolver(
        destinationBase: baseDirectory,
        legacyBase: hive4LegacyBaseDirectory
    )

    /// Resolve a relative path under the current base, copying any missing
    /// files for it from `.config/rootshell` the first time it's asked for.
    /// Per-path -- each caller only knows its own subpath, so this never has
    /// to enumerate a whole legacy tree. For a nested path (`sync/x`) its
    /// top-level folder is adopted first, as a whole, so the order in which
    /// sibling stores resolve cannot strand the rest of a legacy folder.
    /// Callers pass program-owned relative paths without `..`.
    static func url(forRelativePath relativePath: String) -> URL {
        resolver.resolve(relativePath)
    }

    /// The directory itself, for callers that create it and place several
    /// files under it (loggers, caches). Not migrated here: callers that
    /// have legacy data use `url(forRelativePath:)` for that file or folder.
    static var rootDirectory: URL { baseDirectory }
    #else
    /// Sandboxed builds (iOS): unchanged, Documents/.ghostty is private to
    /// the app's own container and never TCC-gated.
    static func url(forRelativePath relativePath: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ghostty", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    /// The directory itself, for callers that create it and place several
    /// files under it (loggers, caches). Documents/.ghostty on sandboxed builds.
    static var rootDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(".ghostty", isDirectory: true)
    }
    #endif
}
