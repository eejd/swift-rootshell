import XCTest

/// FileManager whose chosen source paths fail the way a TCC denial would.
private final class FailingFileManager: FileManager, @unchecked Sendable {
    var deniedListings: Set<String> = []
    var deniedCopies: Set<String> = []
    var deniedStats: Set<String> = []

    private func denied(_ path: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                userInfo: [NSFilePathErrorKey: path])
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if deniedListings.contains(path) { throw denied(path) }
        return try super.contentsOfDirectory(atPath: path)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if deniedStats.contains(path) { throw denied(path) }
        return try super.attributesOfItem(atPath: path)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        if deniedCopies.contains(srcURL.path) { throw denied(srcURL.path) }
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

final class LegacyStorageImporterTests: XCTestCase {
    private var root: URL!
    private var documents: URL!
    private var storage: URL!
    private var overrides: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = try XCTUnwrap(
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("legacy-import-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
        )
        documents = root.appendingPathComponent("Documents", isDirectory: true)
        storage = root.appendingPathComponent("AppSupport/RootShell", isDirectory: true)
        overrides = root.appendingPathComponent("config/rootshell", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Helpers

    private func write(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func importDocuments(_ manager: FileManager? = nil) -> LegacyStorageImportResult {
        LegacyStorageImporter.importDocuments(
            from: documents, storageDirectory: storage, overrideDirectory: overrides,
            fileManager: manager ?? fileManager
        )
    }

    // MARK: - Tests

    func testNestedMergeIntoPopulatedDestinationKeepsCurrentFilesAndPreservesSources() throws {
        let legacy = documents.appendingPathComponent(".ghostty")
        try write("old", to: legacy.appendingPathComponent("sync/old.json"))
        try write("legacy-only", to: legacy.appendingPathComponent("sync/profiles/a.json"))
        try write("current", to: storage.appendingPathComponent("sync/old.json"))
        try write("keep", to: storage.appendingPathComponent("sync/current-only.json"))

        let result = importDocuments()

        XCTAssertEqual(read(storage.appendingPathComponent("sync/old.json")), "current")
        XCTAssertEqual(read(storage.appendingPathComponent("sync/profiles/a.json")), "legacy-only")
        XCTAssertEqual(read(storage.appendingPathComponent("sync/current-only.json")), "keep")
        XCTAssertEqual(result.copiedPaths, [storage.appendingPathComponent("sync/profiles/a.json").path])
        XCTAssertEqual(result.conflictPaths, [legacy.appendingPathComponent("sync/old.json").path])
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(read(legacy.appendingPathComponent("sync/old.json")), "old")
        XCTAssertEqual(read(legacy.appendingPathComponent("sync/profiles/a.json")), "legacy-only")
    }

    func testOverridesAndIncomingLandAtTheirDestinations() throws {
        try write("agent", to: documents.appendingPathComponent("AgentDetectionRules.json"))
        try write("task", to: documents.appendingPathComponent("TaskDetectionRules.json"))
        try write("report", to: documents.appendingPathComponent("incoming/report.txt"))

        let result = importDocuments()

        XCTAssertEqual(read(overrides.appendingPathComponent("AgentDetectionRules.json")), "agent")
        XCTAssertEqual(read(overrides.appendingPathComponent("TaskDetectionRules.json")), "task")
        XCTAssertEqual(read(storage.appendingPathComponent("incoming/report.txt")), "report")
        XCTAssertEqual(result.copiedPaths.count, 3)
        XCTAssertTrue(result.failures.isEmpty && result.conflictPaths.isEmpty)
    }

    func testUnrelatedDocumentsContentsAreNotImported() throws {
        try write("x", to: documents.appendingPathComponent("Taxes/2024.pdf"))
        try write("x", to: documents.appendingPathComponent("rootshell.conf"))

        let result = importDocuments()

        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: storage.path))
        XCTAssertFalse(fileManager.fileExists(atPath: overrides.path))
    }

    func testSecondImportNeverOverwritesAndCopiesNothingNew() throws {
        try write("v1", to: documents.appendingPathComponent("AgentDetectionRules.json"))
        _ = importDocuments()
        try write("edited-by-user", to: overrides.appendingPathComponent("AgentDetectionRules.json"))
        try write("v2", to: documents.appendingPathComponent("AgentDetectionRules.json"))

        let second = importDocuments()

        XCTAssertEqual(read(overrides.appendingPathComponent("AgentDetectionRules.json")), "edited-by-user")
        XCTAssertTrue(second.copiedPaths.isEmpty)
        XCTAssertEqual(second.conflictPaths, [documents.appendingPathComponent("AgentDetectionRules.json").path])
    }

    func testMissingSourceIsEmptyButPermissionFailureIsReported() throws {
        XCTAssertTrue(importDocuments().isEmpty)

        let legacy = documents.appendingPathComponent(".ghostty")
        try write("x", to: legacy.appendingPathComponent("a.json"))
        let manager = FailingFileManager()
        manager.deniedStats = [legacy.path]

        let result = importDocuments(manager)

        XCTAssertEqual(result.failures.map(\.path), [legacy.path])
        XCTAssertTrue(result.copiedPaths.isEmpty)
        XCTAssertFalse(result.isEmpty)
    }

    func testFailureOnOneItemDoesNotBlockIndependentSiblings() throws {
        let legacy = documents.appendingPathComponent(".ghostty")
        try write("a", to: legacy.appendingPathComponent("a-first/one.json"))
        try write("b", to: legacy.appendingPathComponent("b-denied/two.json"))
        try write("c", to: legacy.appendingPathComponent("c-last/three.json"))
        try write("agent", to: documents.appendingPathComponent("AgentDetectionRules.json"))
        let manager = FailingFileManager()
        manager.deniedCopies = [legacy.appendingPathComponent("b-denied/two.json").path]

        let result = importDocuments(manager)

        XCTAssertEqual(read(storage.appendingPathComponent("a-first/one.json")), "a")
        XCTAssertEqual(read(storage.appendingPathComponent("c-last/three.json")), "c")
        XCTAssertEqual(read(overrides.appendingPathComponent("AgentDetectionRules.json")), "agent")
        XCTAssertFalse(fileManager.fileExists(atPath: storage.appendingPathComponent("b-denied/two.json").path))
        XCTAssertEqual(result.failures.map(\.path), [legacy.appendingPathComponent("b-denied/two.json").path])
        XCTAssertEqual(result.copiedPaths.count, 3)
        // No staging directory is left behind by the failed copy.
        let leftovers = try fileManager.contentsOfDirectory(atPath: storage.appendingPathComponent("b-denied").path)
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
        // Retrying after the failure clears picks up the missing file.
        let retry = importDocuments()
        XCTAssertEqual(read(storage.appendingPathComponent("b-denied/two.json")), "b")
        XCTAssertEqual(retry.copiedPaths.count, 1)
    }

    func testSourceSymlinkIsRefusedAndNotFollowed() throws {
        let outside = root.appendingPathComponent("outside")
        try write("secret", to: outside.appendingPathComponent("secret.txt"))
        let legacy = documents.appendingPathComponent(".ghostty")
        try write("ok", to: legacy.appendingPathComponent("real.json"))
        try fileManager.createSymbolicLink(
            at: legacy.appendingPathComponent("linked-dir"), withDestinationURL: outside)
        try fileManager.createSymbolicLink(
            at: legacy.appendingPathComponent("linked-file"),
            withDestinationURL: outside.appendingPathComponent("secret.txt"))

        let result = importDocuments()

        XCTAssertEqual(read(storage.appendingPathComponent("real.json")), "ok")
        XCTAssertFalse(fileManager.fileExists(atPath: storage.appendingPathComponent("linked-dir").path))
        XCTAssertFalse(fileManager.fileExists(atPath: storage.appendingPathComponent("linked-file").path))
        XCTAssertEqual(
            Set(result.failures.map(\.path)),
            [legacy.appendingPathComponent("linked-dir").path, legacy.appendingPathComponent("linked-file").path]
        )
    }

    func testDestinationSymlinkAncestorIsNeverWrittenThrough() throws {
        let outside = root.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: storage, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: storage.appendingPathComponent("sync"), withDestinationURL: outside)
        let legacy = documents.appendingPathComponent(".ghostty")
        try write("x", to: legacy.appendingPathComponent("sync/old.json"))

        let result = importDocuments()

        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(result.failures.map(\.path), [legacy.appendingPathComponent("sync").path])
        XCTAssertTrue(result.copiedPaths.isEmpty)
    }

    func testDestinationRootSymlinkIsRefused() throws {
        let outside = root.appendingPathComponent("outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: storage, withDestinationURL: outside)
        try write("x", to: documents.appendingPathComponent(".ghostty/a.json"))

        let result = importDocuments()

        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testFileDirectoryTypeCollisionIsAConflictNotAnOverwrite() throws {
        let legacy = documents.appendingPathComponent(".ghostty")
        try write("file", to: legacy.appendingPathComponent("thing"))
        try write("dirchild", to: storage.appendingPathComponent("thing/child"))
        try write("dir", to: legacy.appendingPathComponent("other/x"))
        try write("current-file", to: storage.appendingPathComponent("other"))

        let result = importDocuments()

        XCTAssertEqual(read(storage.appendingPathComponent("thing/child")), "dirchild")
        XCTAssertEqual(read(storage.appendingPathComponent("other")), "current-file")
        XCTAssertEqual(
            Set(result.conflictPaths),
            [legacy.appendingPathComponent("thing").path, legacy.appendingPathComponent("other").path]
        )
        XCTAssertTrue(result.copiedPaths.isEmpty && result.failures.isEmpty)
    }
}
