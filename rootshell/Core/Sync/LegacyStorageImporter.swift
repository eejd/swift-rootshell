//
//  LegacyStorageImporter.swift
//  rootshell
//
//  Conservative, non-destructive copying of legacy on-disk state into the
//  current storage locations. Foundation-only so the hostless test target
//  compiles the same code the Mac Catalyst app runs.
//
//  Rules shared by every entry point here:
//    * Sources are never modified, renamed or removed.
//    * Existing destination files always win; a collision is reported as a
//      conflict and both copies stay as they are.
//    * Symbolic links (and other non-regular files) are never followed or
//      copied; they are reported as failures.
//    * A missing source is "nothing to import". A permission or I/O error is
//      a failure and is never mistaken for absence.
//

import Foundation
import os.log

nonisolated struct LegacyStorageImportResult: Sendable {
    nonisolated struct Failure: Sendable {
        /// Legacy source path that could not be imported.
        let path: String
        let message: String
    }

    /// Absolute destination paths of regular files copied by this operation.
    var copiedPaths: [String] = []
    /// Absolute legacy source paths kept because a destination already exists.
    var conflictPaths: [String] = []
    var failures: [Failure] = []

    var isEmpty: Bool { copiedPaths.isEmpty && conflictPaths.isEmpty && failures.isEmpty }

    mutating func merge(_ other: LegacyStorageImportResult) {
        copiedPaths += other.copiedPaths
        conflictPaths += other.conflictPaths
        failures += other.failures
    }
}

nonisolated enum LegacyStorageImporter {
    private enum Kind {
        case missing, file, directory, symlink, other
    }

    /// Copies every regular file under `source` that does not yet exist under
    /// `destination`, merging real directories recursively.
    static func copyMissing(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) -> LegacyStorageImportResult {
        var result = LegacyStorageImportResult()
        copy(source, to: destination, fileManager: fileManager, into: &result)
        return result
    }

    /// Explicit, user-initiated import of the pre-Application-Support Documents
    /// layout. Only these four known sources are touched.
    static func importDocuments(
        from documents: URL,
        storageDirectory: URL,
        overrideDirectory: URL,
        fileManager: FileManager = .default
    ) -> LegacyStorageImportResult {
        let mappings: [(URL, URL)] = [
            (documents.appendingPathComponent(".ghostty", isDirectory: true), storageDirectory),
            (documents.appendingPathComponent("AgentDetectionRules.json"),
             overrideDirectory.appendingPathComponent("AgentDetectionRules.json")),
            (documents.appendingPathComponent("TaskDetectionRules.json"),
             overrideDirectory.appendingPathComponent("TaskDetectionRules.json")),
            (documents.appendingPathComponent("incoming", isDirectory: true),
             storageDirectory.appendingPathComponent("incoming", isDirectory: true))
        ]
        var result = LegacyStorageImportResult()
        for (source, destination) in mappings {
            result.merge(copyMissing(from: source, to: destination, fileManager: fileManager))
        }
        return result
    }

    // MARK: - Implementation

    private static func kind(of url: URL, fileManager: FileManager) throws -> Kind {
        do {
            // lstat semantics: a symlink reports .typeSymbolicLink.
            let raw = try fileManager.attributesOfItem(atPath: url.path)
            guard let type = raw[.type] as? FileAttributeType else { return .other }
            switch type {
            case .typeRegular: return .file
            case .typeDirectory: return .directory
            case .typeSymbolicLink: return .symlink
            default: return .other
            }
        } catch let error as NSError where isNoSuchFile(error) {
            return .missing
        }
    }

    private static func isNoSuchFile(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
    }

    private static func isFileExists(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileWriteFileExistsError { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EEXIST)
        }
        return error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST)
    }

    private static func fail(_ source: URL, _ message: String, into result: inout LegacyStorageImportResult) {
        result.failures.append(.init(path: source.path, message: message))
    }

    private static func copy(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager,
        into result: inout LegacyStorageImportResult
    ) {
        let sourceKind: Kind
        do {
            sourceKind = try kind(of: source, fileManager: fileManager)
        } catch {
            fail(source, error.localizedDescription, into: &result)
            return
        }

        switch sourceKind {
        case .missing:
            return
        case .symlink:
            fail(source, "Symbolic links are not imported", into: &result)
        case .other:
            fail(source, "Unsupported file type", into: &result)
        case .file:
            copyFile(source, to: destination, fileManager: fileManager, into: &result)
        case .directory:
            mergeDirectory(source, to: destination, fileManager: fileManager, into: &result)
        }
    }

    private static func mergeDirectory(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager,
        into result: inout LegacyStorageImportResult
    ) {
        do {
            switch try kind(of: destination, fileManager: fileManager) {
            case .missing:
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            case .directory:
                break
            case .symlink:
                fail(source, "Destination \(destination.path) is a symbolic link", into: &result)
                return
            case .file, .other:
                result.conflictPaths.append(source.path)
                return
            }
        } catch {
            fail(source, error.localizedDescription, into: &result)
            return
        }

        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: source.path).sorted()
        } catch {
            fail(source, error.localizedDescription, into: &result)
            return
        }
        for name in names {
            copy(
                source.appendingPathComponent(name),
                to: destination.appendingPathComponent(name),
                fileManager: fileManager,
                into: &result
            )
        }
    }

    private static func copyFile(
        _ source: URL,
        to destination: URL,
        fileManager: FileManager,
        into result: inout LegacyStorageImportResult
    ) {
        do {
            switch try kind(of: destination, fileManager: fileManager) {
            case .missing:
                break
            case .file, .directory, .other:
                result.conflictPaths.append(source.path)
                return
            case .symlink:
                fail(source, "Destination \(destination.path) is a symbolic link", into: &result)
                return
            }
        } catch {
            fail(source, error.localizedDescription, into: &result)
            return
        }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".rootshell-import-\(UUID().uuidString)", isDirectory: true)
        var stagingCreated = false
        defer {
            if stagingCreated { try? fileManager.removeItem(at: staging) }
        }

        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
            stagingCreated = true
            let staged = staging.appendingPathComponent(destination.lastPathComponent)
            try fileManager.copyItem(at: source, to: staged)
            // moveItem refuses to replace an existing destination, so a file
            // created concurrently is reported rather than overwritten.
            try fileManager.moveItem(at: staged, to: destination)
            result.copiedPaths.append(destination.path)
        } catch let error as NSError where isFileExists(error) {
            result.conflictPaths.append(source.path)
        } catch {
            fail(source, error.localizedDescription, into: &result)
        }
    }
}

/// Automatic, once-per-path adoption of data from one non-TCC legacy base
/// directory into the current base. Absence and failure are both remembered
/// for the lifetime of the process so hot-path lookups never re-probe the
/// legacy tree; a failed adoption is logged and retried on the next launch.
///
/// Invariant: `lock` guards both `attempted` and the whole synchronous copy,
/// so concurrent callers for the same path can neither copy twice nor observe
/// a half-merged directory. It is never held across an await or actor hop.
nonisolated final class LegacyStorageResolver: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.rootshell", category: "LegacyStorageResolver")

    private let destinationBase: URL
    private let legacyBase: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var attempted = Set<String>()

    init(destinationBase: URL, legacyBase: URL, fileManager: FileManager = .default) {
        self.destinationBase = destinationBase
        self.legacyBase = legacyBase
        self.fileManager = fileManager
    }

    /// Resolve a relative path under the current base, first adopting any
    /// missing legacy files for it. For a nested path its top-level folder is
    /// adopted first so sibling resolution order cannot strand legacy files.
    func resolve(_ relativePath: String) -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        precondition(
            !relativePath.hasPrefix("/") && !components.contains(".."),
            "Expected a relative storage path without '..'"
        )

        lock.lock()
        defer { lock.unlock() }
        if components.count > 1 {
            adoptIfNeeded(String(components[0]))
        }
        if !components.isEmpty {
            adoptIfNeeded(components.joined(separator: "/"))
        }
        return destinationBase.appendingPathComponent(relativePath)
    }

    private func adoptIfNeeded(_ relativePath: String) {
        guard attempted.insert(relativePath).inserted else { return }
        let result = LegacyStorageImporter.copyMissing(
            from: legacyBase.appendingPathComponent(relativePath),
            to: destinationBase.appendingPathComponent(relativePath),
            fileManager: fileManager
        )
        for failure in result.failures {
            Self.logger.error("Failed to migrate \(failure.path): \(failure.message)")
        }
        for conflict in result.conflictPaths {
            Self.logger.notice("Kept both copies; current file wins over legacy \(conflict)")
        }
    }
}
