//
//  NativeLocalShellSpawner.swift
//  rootshell
//
//  NATIVE flavor only: starts local login shells directly from the app.
//
//  Standalone routes local shells through rootshell-helper, which opens the
//  PTY, forks the shell and passes the master descriptor back over a socket.
//  That indirection exists for the sandboxed flavors; an unsandboxed app can
//  open the PTY and spawn the shell itself. Doing so drops the helper from
//  the local-shell path, and with it the need for the helper to trust an
//  ad-hoc-signed peer.
//
//  Mirrors rootshell-helper's ProcessSpawner.m and EnvironmentBuilder.swift
//  (both after ghostty/src/termio/Exec.zig): same login(1) command line, same
//  from-scratch environment, same shell-integration injection.
//
//  Not covered here (still helper-only): piped processes, one-shot command
//  execution, local multiplexer recovery.
//

#if NATIVE && targetEnvironment(macCatalyst)

import Foundation
import os

nonisolated enum NativeLocalShellSpawner {
    struct Session {
        let pid: pid_t
        let masterFD: Int32
    }

    struct Request {
        var rows: UInt16
        var cols: UInt16
        var workingDirectory: String?
        var shell: String?
        var enableShellIntegration: Bool
        var paneToken: String?
        var resourcesDir: String?
        var sshAuthSock: String?
        var termType: String?
        var version: String
        var versionWithBuild: String
    }

    enum SpawnError: LocalizedError {
        case pty(String)
        case spawn(Int32)

        var errorDescription: String? {
            switch self {
            case .pty(let step): return "Failed to open a terminal (\(step))"
            case .spawn(let code): return "Failed to start the shell: \(String(cString: strerror(code)))"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.rootshell", category: "NativeLocalShellSpawner")
    private static let fallbackShell = "/bin/zsh"
    /// Carries the starting directory to the bootstrap script, which unsets it.
    private static let initialDirectoryVariable = "ROOTSHELL_INITIAL_DIRECTORY"

    // MARK: - Spawn

    static func spawn(_ request: Request) throws -> Session {
        let masterFD = posix_openpt(O_RDWR | O_NOCTTY)
        guard masterFD >= 0 else { throw SpawnError.pty("posix_openpt") }
        var keepMaster = false
        defer { if !keepMaster { close(masterFD) } }

        guard grantpt(masterFD) == 0 else { throw SpawnError.pty("grantpt") }
        guard unlockpt(masterFD) == 0 else { throw SpawnError.pty("unlockpt") }
        guard let slaveName = ptsname(masterFD) else { throw SpawnError.pty("ptsname") }
        let slavePath = String(cString: slaveName)
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)

        // The window size only sticks once the slave side is open, so hold it
        // open across the spawn; the shell must not start at 0x0.
        let slaveFD = open(slavePath, O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard slaveFD >= 0 else { throw SpawnError.pty("open slave") }
        defer { close(slaveFD) }
        var size = winsize(ws_row: request.rows, ws_col: request.cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(slaveFD, TIOCSWINSZ, &size)

        var environment = buildEnvironment(request)
        var shell = validatedShell(request.shell) ?? defaultShell()
        if request.enableShellIntegration,
           let resourcesDir = request.resourcesDir,
           let integrationDir = existingDirectory(resourcesDir + "/shell-integration") {
            environment["GHOSTTY_SHELL_INTEGRATION_DIR"] = integrationDir
            shell = injectShellIntegration(shell: shell, integrationDir: integrationDir, environment: &environment)
        }

        let home = environment["HOME"] ?? NSHomeDirectory()
        // posix_spawn_file_actions_addchdir_np is unavailable to Catalyst, so
        // the bootstrap script changes directory before it execs the shell
        // (login -l leaves the working directory alone).
        environment[initialDirectoryVariable] = existingDirectory(request.workingDirectory) ?? home
        let arguments = loginCommand(user: environment["USER"] ?? NSUserName(), shell: shell, home: home)

        // The child becomes a session leader (POSIX_SPAWN_SETSID); opening the
        // slave without O_NOCTTY as its first terminal then makes that PTY its
        // controlling terminal, which is what fork + setsid + TIOCSCTTY did.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // The app's signal mask and handlers must not leak into the shell: a
        // blocked SIGINT would never reach it even with ISIG set on the PTY.
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, &attributes, &argv, &envp)
        guard result == 0 else {
            logger.error("posix_spawn(\(arguments[0], privacy: .public)) failed: \(result)")
            throw SpawnError.spawn(result)
        }

        keepMaster = true
        logger.info("Started local shell pid \(pid) on \(slavePath, privacy: .public)")
        return Session(pid: pid, masterFD: masterFD)
    }

    // MARK: - Session control

    static func resize(masterFD: Int32, rows: UInt16, cols: UInt16) -> Bool {
        var size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        return ioctl(masterFD, TIOCSWINSZ, &size) == 0
    }

    /// Signals the shell's whole session, then reaps it off the main thread.
    static func terminate(pid: pid_t, signal: Int32) {
        guard pid > 0 else { return }
        // The shell is a session and process-group leader, so -pid reaches
        // its foreground jobs too.
        if kill(-pid, signal) != 0 { kill(pid, signal) }
        reap(pid: pid)
    }

    /// Collects the exit status so the shell does not linger as a zombie.
    static func reap(pid: pid_t, completion: (@Sendable (Int32) -> Void)? = nil) {
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
            let exited = (status & 0x7f) == 0
            completion?(result == pid && exited ? (status >> 8) & 0xff : -1)
        }
    }

    // MARK: - Command line

    /// `/usr/bin/login [-q] -flp USER /bin/bash --noprofile --norc -c "exec -l SHELL"`
    private static func loginCommand(user: String, shell: String, home: String) -> [String] {
        var arguments = ["/usr/bin/login"]
        if FileManager.default.fileExists(atPath: home + "/.hushlogin") { arguments.append("-q") }
        // -f: skip authentication, -l: keep the working directory, -p: keep the environment.
        arguments += ["-flp", user, "/bin/bash", "--noprofile", "--norc", "-c"]
        // exec -l replaces bash with the shell as a login shell; execfail keeps
        // bash alive only if that exec fails, so the fallback still gets a turn.
        // Each token is single-quoted: validatedShell admits no quote character,
        // so a token cannot end its quoting or add shell syntax.
        let quotedShell = quoted(shell)
        let quotedFallback = quoted(fallbackShell)
        arguments.append("""
            cd -- "$\(initialDirectoryVariable)" 2>/dev/null
            unset \(initialDirectoryVariable)
            shopt -s execfail
            exec -l \(quotedShell)
            exec -l \(quotedFallback)
            exit 127
            """)
        return arguments
    }

    private static func quoted(_ command: String) -> String {
        command.split(separator: " ").map { "'\($0)'" }.joined(separator: " ")
    }

    private static func defaultShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return validatedShell(String(cString: shell)) ?? fallbackShell
        }
        return fallbackShell
    }

    /// The command is interpolated into a bash script, so accept only an
    /// absolute path to an executable followed by plain arguments.
    private static func validatedShell(_ candidate: String?) -> String? {
        guard let command = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty, command.count <= 1024 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-+=:, "))
        guard command.unicodeScalars.allSatisfy(allowed.contains) else {
            logger.warning("Ignoring shell command with unsupported characters")
            return nil
        }
        let executable = String(command.split(separator: " ", maxSplits: 1)[0])
        var isDirectory: ObjCBool = false
        guard executable.hasPrefix("/"),
              FileManager.default.fileExists(atPath: executable, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        return command
    }

    private static func injectShellIntegration(
        shell: String,
        integrationDir: String,
        environment: inout [String: String]
    ) -> String {
        let executable = String(shell.split(separator: " ", maxSplits: 1)[0])
        switch (executable as NSString).lastPathComponent {
        case "zsh":
            if let existing = environment["ZDOTDIR"] { environment["GHOSTTY_ZSH_ZDOTDIR"] = existing }
            environment["ZDOTDIR"] = integrationDir + "/zsh"
            return shell
        case "bash":
            // The script needs bash 4+; the system /bin/bash is 3.2.
            let script = integrationDir + "/bash/ghostty.bash"
            guard executable != "/bin/bash", FileManager.default.isReadableFile(atPath: script) else { return shell }
            if let existing = environment["ENV"] { environment["GHOSTTY_BASH_ENV"] = existing }
            environment["ENV"] = script
            environment["GHOSTTY_BASH_INJECT"] = "1"
            if environment["HISTFILE"] == nil {
                environment["HISTFILE"] = (environment["HOME"] ?? NSHomeDirectory()) + "/.bash_history"
                environment["GHOSTTY_BASH_UNEXPORT_HISTFILE"] = "1"
            }
            return shell + " --posix"
        case "fish", "elvish":
            let existing = environment["XDG_DATA_DIRS"] ?? ""
            environment["XDG_DATA_DIRS"] = existing.isEmpty ? integrationDir : "\(integrationDir):\(existing)"
            environment["GHOSTTY_SHELL_INTEGRATION_XDG_DIR"] = integrationDir
            return shell
        default:
            return shell
        }
    }

    // MARK: - Environment

    /// Built from scratch rather than inherited: the app's own environment
    /// carries iOS/Xcode variables that break tools run from the shell. The
    /// login shell fills in the rest from /etc/profile and the user's dotfiles.
    private static func buildEnvironment(_ request: Request) -> [String: String] {
        var env: [String: String] = [:]
        if let entry = getpwuid(getuid()) {
            if let home = entry.pointee.pw_dir { env["HOME"] = String(cString: home) }
            if let user = entry.pointee.pw_name {
                env["USER"] = String(cString: user)
                env["LOGNAME"] = String(cString: user)
            }
            if let shell = entry.pointee.pw_shell { env["SHELL"] = String(cString: shell) }
        }
        env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if let tmpDir = darwinUserTempDir() { env["TMPDIR"] = tmpDir }

        let terminfo = request.resourcesDir.flatMap { existingDirectory($0 + "/terminfo") }
        if let termType = request.termType, !termType.isEmpty {
            env["TERM"] = termType
            if let terminfo { env["TERMINFO"] = terminfo }
        } else if let terminfo {
            env["TERM"] = "xterm-ghostty"
            env["TERMINFO"] = terminfo
        } else {
            env["TERM"] = "xterm-256color"
        }
        env["COLORTERM"] = "truecolor"
        env["LANG"] = LocaleHelper.posixLocale
        if let preferredLanguages = LocaleHelper.preferredLanguages { env["LANGUAGE"] = preferredLanguages }

        if request.enableShellIntegration, let resourcesDir = request.resourcesDir {
            env["GHOSTTY_RESOURCES_DIR"] = resourcesDir
            env["GHOSTTY_SHELL_FEATURES"] = "path,sudo,title"
        }
        env["TERM_PROGRAM"] = "ghostty"
        env["TERM_PROGRAM_VERSION"] = request.version
        env["LC_TERMINAL"] = "rootshell"
        env["LC_TERMINAL_VERSION"] = request.versionWithBuild
        if let paneToken = request.paneToken, !paneToken.isEmpty { env["LC_ROOTSHELL_PANE"] = paneToken }
        if let workingDirectory = existingDirectory(request.workingDirectory) { env["PWD"] = workingDirectory }
        if let sshAuthSock = request.sshAuthSock, !sshAuthSock.isEmpty { env["SSH_AUTH_SOCK"] = sshAuthSock }
        return env
    }

    private static func darwinUserTempDir() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func existingDirectory(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
    }
}

#endif // NATIVE && targetEnvironment(macCatalyst)
