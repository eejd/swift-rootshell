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

    private static let newlyProtected = [
        ".netrc", ".git-credentials", ".config/gh/hosts.yml", ".docker/config.json", ".kube/config",
        ".config/gcloud/credentials.db", ".azure/accessTokens.json",
        ".bash_history", ".zsh_history", ".config/fish/fish_history", ".local/share/fish/fish_history",
        "Library/Cookies/Cookies.binarycookies", "Library/Mail/V10/x", "Library/Messages/chat.db",
        "Library/Safari/History.db"
    ]

    func testCredentialAndPrivateDataStoresAreRefusedEvenWithParentAndWorkingDirectoryGrants() {
        let sut = policy(grants: [home, home + "/.config", home + "/Library", home + "/.docker", home + "/Library/Mail"])
        for relative in Self.newlyProtected {
            for workingDirectory in [project!, home + "/.config", home + "/Library", home + "/.docker"] {
                guard case .denied = sut.decide(resolvedPath: home + "/" + relative, workingDirectory: workingDirectory) else {
                    return XCTFail("\(relative) should be refused with working directory \(workingDirectory)")
                }
            }
        }
    }

    func testProtectedMatchingIgnoresCaseForNewEntries() {
        let sut = policy()
        for relative in ["/.NETRC", "/.Config/GH/hosts.yml", "/library/mail/x", "/LIBRARY/SAFARI/y"] {
            guard case .denied = sut.decide(resolvedPath: home + relative, workingDirectory: project) else {
                return XCTFail("\(relative) should be refused")
            }
        }
    }

    func testSymlinkAliasesOfNewProtectedStoresAreRefused() throws {
        try FileManager.default.createDirectory(atPath: home + "/.kube", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project + "/kube", withDestinationPath: home + "/.kube")
        let decision = policy().decide(resolvedPath: project + "/kube/config", workingDirectory: project)
        guard case .denied = decision else { return XCTFail("alias escaped protection: \(decision)") }
    }

    func testBroadHomeContainersCannotBeGrantsOrWorkingDirectories() {
        let broad = [
            "Library", "Library/Application Support", "Library/Containers", "Library/Group Containers",
            ".config", ".local", ".local/share", ".cache", "LIBRARY", ".CONFIG"
        ]
        let sut = policy(grants: broad.map { home + "/" + $0 })
        for relative in broad {
            let folder = home + "/" + relative
            XCTAssertFalse(sut.canGrant(folder), "\(relative) should not be grantable")
            guard case .needsGrant(let request) = sut.decide(
                resolvedPath: folder + "/Unrelated/file.txt", workingDirectory: folder
            ) else { return XCTFail("\(relative) opened its children") }
            XCTAssertEqual(request.folder, (folder + "/Unrelated"))
        }
    }

    func testSpecificChildOfBroadContainerIsGrantable() {
        let child = home + "/Library/ExampleProject"
        let file = child + "/x"
        let sut = policy()
        XCTAssertTrue(sut.canGrant(child))
        guard case .needsGrant(let request) = sut.decide(resolvedPath: file, workingDirectory: "") else {
            return XCTFail("expected a prompt")
        }
        XCTAssertTrue(request.canGrantAlways)
        XCTAssertEqual(policy(grants: [child]).decide(resolvedPath: file, workingDirectory: ""), .allowed)
    }

    func testCanGrantRejectsProtectedFoldersAndTheirAliasesByCase() {
        let sut = policy()
        XCTAssertFalse(sut.canGrant(home + "/.SSH"))
        XCTAssertFalse(sut.canGrant(home + "/.config/gh"))
        XCTAssertFalse(sut.canGrant(home + "/.config/gh/nested"))
        XCTAssertTrue(sut.canGrant(home + "/.config/unrelated-tool"))
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

    func testDotDotAfterASymlinkMeansTheParentOfTheTarget() throws {
        // project/link -> home/.ssh, so "link/../.aws/credentials" is home/.aws/credentials,
        // not project/.aws/credentials. The path judged must be the one the kernel opens.
        try FileManager.default.createSymbolicLink(atPath: project + "/link", withDestinationPath: home + "/.ssh")
        let judged = AIAgentFileAccessPolicy.canonical(project + "/link/../.aws/credentials")
        XCTAssertEqual(judged, home + "/.aws/credentials")
        guard case .denied = policy().decide(
            resolvedPath: project + "/link/../.aws/credentials", workingDirectory: project
        ) else { return XCTFail("lexical .. collapse let a protected path through") }
    }

    func testCanonicalIsIdempotentAndFollowsDanglingSymlinks() throws {
        try FileManager.default.createSymbolicLink(atPath: project + "/dangling", withDestinationPath: home + "/.ssh/new")
        let once = AIAgentFileAccessPolicy.canonical(project + "/dangling")
        XCTAssertEqual(once, home + "/.ssh/new")
        XCTAssertEqual(AIAgentFileAccessPolicy.canonical(once), once)
    }

    func testProtectedPathsMatchRegardlessOfCase() {
        let sut = policy(grants: [home + "/other"])
        for path in [home + "/.SSH/id_ed25519", home + "/library/KEYCHAINS/login.keychain-db", home + "/.Aws/x"] {
            guard case .denied = sut.decide(resolvedPath: path, workingDirectory: project) else {
                return XCTFail("\(path) should be refused")
            }
        }
    }

    func testHomeCannotBeGrantedByAnAliasOrDifferentCase() {
        let upper = home.uppercased()
        XCTAssertTrue(policy().isTooBroad(upper))
        XCTAssertTrue(policy().isTooBroad("/System/Volumes/Data" + home))
    }

    func testFirmlinkPrefixIsRemoved() {
        XCTAssertEqual(AIAgentFileAccessPolicy.canonical("/System/Volumes/Data/Users/x/y"), "/Users/x/y")
    }

    func testCaseVariantFirmlinkPrefixCannotBypassProtectionOrBreadth() {
        let alias = "/system/volumes/data" + home
        let sut = policy()
        guard case .denied = sut.decide(resolvedPath: alias + "/.ssh/id_ed25519", workingDirectory: project) else {
            return XCTFail("case-variant firmlink alias bypassed the protected list")
        }
        XCTAssertFalse(sut.canGrant(alias))
        XCTAssertFalse(sut.canGrant(alias + "/Library"))
    }

    func testSystemFoldersAreNotUsableWorkingDirectories() {
        for cwd in ["/etc/ssh", "/private/var/root", "/usr/local", "/tmp", "/private/tmp"] {
            let decision = policy().decide(resolvedPath: cwd + "/a.txt", workingDirectory: cwd)
            guard case .needsGrant = decision else { return XCTFail("cwd \(cwd): \(decision)") }
        }
    }
}
#endif
