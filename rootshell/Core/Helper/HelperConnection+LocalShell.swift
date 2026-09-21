//
//  HelperConnection+LocalShell.swift
//  rootshell
//
//  "Can a local shell be opened?" as a question separate from "is the helper
//  running?". They are the same question in every flavor except NATIVE, which
//  spawns local shells itself (NativeLocalShellSpawner) and so never has to
//  wait for, or fall back on, rootshell-helper to open one.
//
//  Features that genuinely need the helper (piped processes, command
//  execution, multiplexer recovery) keep calling ensureHelperRunning().
//

#if targetEnvironment(macCatalyst)

import Foundation

extension HelperConnection {
    /// Synchronous fast-path check used on window/tab open.
    var localShellsKnownAvailable: Bool {
        #if NATIVE
        true
        #else
        isKnownRunning
        #endif
    }

    /// Makes local shells available, launching the helper when the flavor
    /// needs it. Returns false when a local shell cannot be opened.
    func ensureLocalShellsAvailable() async -> Bool {
        #if NATIVE
        true
        #else
        await ensureHelperRunning()
        #endif
    }
}

#endif // targetEnvironment(macCatalyst)
