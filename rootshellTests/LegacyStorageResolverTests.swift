import XCTest

/// Records every path the resolver asks the file system about.
private final class SpyFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var failingListings: Set<String> = []

    var touchedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func resetTouched() {
        lock.lock(); defer { lock.unlock() }
        recorded.removeAll()
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(path)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        record(path)
        return try super.attributesOfItem(atPath: path)
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        record(path)
        if failingListings.contains(path) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        return try super.contentsOfDirectory(atPath: path)
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        record(srcURL.path)
        try super.copyItem(at: srcURL, to: dstURL)
    }
}

final class LegacyStorageResolverTests: XCTestCase {
    private var root: URL!
    private var current: URL!
    private var legacy: URL!
    private var documents: URL!
    private let spy = SpyFileManager()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("legacy-resolver-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        current = root.appendingPathComponent("AppSupport/RootShell", isDirectory: true)
        legacy = root.appendingPathComponent("home/.config/rootshell", isDirectory: true)
        documents = root.appendingPathComponent("home/Documents/.ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func makeResolver() -> LegacyStorageResolver {
        LegacyStorageResolver(destinationBase: current, legacyBase: legacy, fileManager: spy)
    }

    func testAbsentPathIsProbedOncePerProcessAndNeverAgain() {
        let resolver = makeResolver()
        _ = resolver.resolve("sync/profiles")
        let first = spy.touchedPaths.count
        XCTAssertGreaterThan(first, 0)

        for _ in 0..<50 { _ = resolver.resolve("sync/profiles") }

        XCTAssertEqual(spy.touchedPaths.count, first)
    }

    func testFailureIsRememberedForTheProcessAndRetriedByANewResolver() throws {
        try write("data", to: legacy.appendingPathComponent("sync/a.json"))
        spy.failingListings = [legacy.appendingPathComponent("sync").path]
        let resolver = makeResolver()

        _ = resolver.resolve("sync")
        let afterFailure = spy.touchedPaths.count
        _ = resolver.resolve("sync")
        XCTAssertEqual(spy.touchedPaths.count, afterFailure)
        XCTAssertNil(read(current.appendingPathComponent("sync/a.json")))

        spy.failingListings = []
        _ = resolver.resolve("sync")
        XCTAssertNil(read(current.appendingPathComponent("sync/a.json")), "same process must not retry")

        _ = makeResolver().resolve("sync")
        XCTAssertEqual(read(current.appendingPathComponent("sync/a.json")), "data")
    }

    func testTopLevelFolderIsAdoptedWholeBeforeNestedPath() throws {
        try write("a", to: legacy.appendingPathComponent("sync/profiles/a.json"))
        try write("b", to: legacy.appendingPathComponent("sync/hosts/b.json"))

        let url = makeResolver().resolve("sync/profiles")

        XCTAssertEqual(url, current.appendingPathComponent("sync/profiles"))
        XCTAssertEqual(read(current.appendingPathComponent("sync/profiles/a.json")), "a")
        XCTAssertEqual(read(current.appendingPathComponent("sync/hosts/b.json")), "b")
    }

    func testMergesIntoExistingDestinationDirectoryWithoutOverwriting() throws {
        try write("legacy-old", to: legacy.appendingPathComponent("sync/old.json"))
        try write("legacy-extra", to: legacy.appendingPathComponent("sync/extra.json"))
        try write("current-old", to: current.appendingPathComponent("sync/old.json"))

        _ = makeResolver().resolve("sync")

        XCTAssertEqual(read(current.appendingPathComponent("sync/old.json")), "current-old")
        XCTAssertEqual(read(current.appendingPathComponent("sync/extra.json")), "legacy-extra")
        XCTAssertEqual(read(legacy.appendingPathComponent("sync/extra.json")), "legacy-extra", "source stays")
    }

    func testResolutionOnlyProbesTheSuppliedBases() throws {
        try write("old", to: legacy.appendingPathComponent("known_hosts.json"))
        let resolver = makeResolver()

        for path in ["sync", "sync/profiles", "known_hosts.json", "fonts", "incoming"] {
            _ = resolver.resolve(path)
        }

        XCTAssertFalse(spy.touchedPaths.isEmpty)
        XCTAssertTrue(spy.touchedPaths.allSatisfy { $0.hasPrefix(legacy.path) || $0.hasPrefix(current.path) })
        XCTAssertEqual(read(current.appendingPathComponent("known_hosts.json")), "old")
    }

    func testConcurrentResolutionOfOnePathCopiesOnceAndAllCallersSeeIt() throws {
        try write("payload", to: legacy.appendingPathComponent("sync/one.json"))
        let resolver = makeResolver()
        let results = LockedBox<[URL]>([])

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            let url = resolver.resolve("sync/one.json")
            results.mutate { $0.append(url) }
        }

        XCTAssertEqual(results.value.count, 32)
        XCTAssertEqual(Set(results.value), [current.appendingPathComponent("sync/one.json")])
        XCTAssertEqual(read(current.appendingPathComponent("sync/one.json")), "payload")
        let copies = spy.touchedPaths.filter { $0 == legacy.appendingPathComponent("sync/one.json").path }
        // One copy plus the attribute probes of the single top-level and exact-path adoption.
        XCTAssertLessThanOrEqual(copies.count, 3)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&stored)
    }
}
