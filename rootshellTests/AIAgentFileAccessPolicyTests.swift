#if !CHINA_BUILD
import XCTest

final class AIAgentFileAccessPolicyTests: XCTestCase {
    private var root: String!
    private var home: String!
    private var scratch: String!
    private var project: String!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-policy-\(UUID().uuidString)").path
        root = AIAgentFileAccessPolicy.canonical(base)
        home = root + "/home"
        scratch = root + "/scratch"
        project = home + "/proj"
        for dir in [home!, scratch!, project!, home + "/.ssh", home + "/other"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: home + "/.ssh/id_ed25519", contents: Data("k".utf8))
        FileManager.default.createFile(atPath: home + "/other/notes.txt", contents: Data("n".utf8))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func policy(grants: [String] = []) -> AIAgentFileAccessPolicy {
        AIAgentFileAccessPolicy(home: home, scratch: scratch, grants: grants)
    }

    func testWorkingDirectoryScratchAndGrantsAreAllowed() {
        let sut = policy(grants: [home + "/other"])
        XCTAssertEqual(sut.decide(resolvedPath: project + "/a.txt", workingDirectory: project), .allowed)
        XCTAssertEqual(sut.decide(resolvedPath: scratch + "/t.txt", workingDirectory: project), .allowed)
        XCTAssertEqual(sut.decide(resolvedPath: home + "/other/notes.txt", workingDirectory: project), .allowed)
    }

    func testSiblingOfAllowedRootIsNotInsideIt() {
        // "/proj-evil" shares a string prefix with "/proj" but is a different folder.
        let decision = policy().decide(resolvedPath: home + "/proj-evil/a.txt", workingDirectory: project)
        guard case .needsGrant = decision else { return XCTFail("\(decision)") }
    }

    func testHomeAsWorkingDirectoryDoesNotOpenHome() {
        // A new terminal usually starts in $HOME; that must not make all of $HOME reachable.
        let decision = policy().decide(resolvedPath: home + "/other/notes.txt", workingDirectory: home)
        guard case .needsGrant(let request) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(request.folder, home + "/other")
        XCTAssertTrue(request.canGrantAlways)
    }

    func testAncestorOfHomeAsWorkingDirectoryDoesNotOpenAnything() {
        for ancestor in ["/", (home as NSString).deletingLastPathComponent] {
            let decision = policy().decide(resolvedPath: project + "/a.txt", workingDirectory: ancestor)
            guard case .needsGrant = decision else { return XCTFail("cwd \(ancestor): \(decision)") }
        }
    }

    func testHomeCannotBeGrantedPermanentlyAndAGrantOfHomeIsIgnored() {
        let decision = policy(grants: [home]).decide(resolvedPath: home + "/a.txt", workingDirectory: "")
        guard case .needsGrant(let request) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(request.folder, home)
        XCTAssertFalse(request.canGrantAlways)
    }

    func testCredentialLocationsAreRefusedEvenInsideAGrant() {
        let sut = policy(grants: [home + "/.ssh", home])
        let paths = [home + "/.ssh/id_ed25519", home + "/.ssh/new_key", home + "/.gnupg/x", home + "/.aws/credentials"]
        for path in paths {
            guard case .denied = sut.decide(resolvedPath: path, workingDirectory: project) else {
                return XCTFail("\(path) should be refused")
            }
        }
    }

    func testSymlinkFromAllowedFolderIntoProtectedFolderIsRefused() throws {
        try FileManager.default.createSymbolicLink(atPath: project + "/link", withDestinationPath: home + "/.ssh")
        let decision = policy().decide(resolvedPath: project + "/link/id_ed25519", workingDirectory: project)
        guard case .denied = decision else {
            return XCTFail("symlink escape was allowed: \(decision)")
        }
    }

    func testSymlinkFromAllowedFolderToUngrantedFolderNeedsAGrant() throws {
        try FileManager.default.createSymbolicLink(atPath: project + "/out", withDestinationPath: home + "/other")
        let decision = policy().decide(resolvedPath: project + "/out/notes.txt", workingDirectory: project)
        guard case .needsGrant(let request) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(request.resolvedPath, home + "/other/notes.txt")
    }

    func testNewFileUnderSymlinkedParentIsResolvedThroughTheParent() throws {
        try FileManager.default.createSymbolicLink(atPath: project + "/out", withDestinationPath: home + "/other")
        // write_file target does not exist yet; its symlinked parent still decides.
        let decision = policy().decide(resolvedPath: project + "/out/new/created.txt", workingDirectory: project)
        guard case .needsGrant(let request) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(request.resolvedPath, home + "/other/new/created.txt")
    }

    func testDotDotCannotEscapeTheWorkingDirectory() {
        let decision = policy().decide(resolvedPath: project + "/../other/notes.txt", workingDirectory: project)
        guard case .needsGrant = decision else { return XCTFail("\(decision)") }
    }
}
#endif
