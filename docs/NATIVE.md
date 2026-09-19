# The NATIVE flavor

`NATIVE` is a third build flavor alongside `STANDALONE` and `APPSTORE`. It is
for Mac builds that have **no Apple-issued provisioning profile**: ad-hoc
signing, a free Personal Team, or a package-manager build (MacPorts) that
signs as an anonymous build user.

    xcodebuild -scheme rootshell-Native -configuration ReleaseNative \
        -destination 'generic/platform=macOS,variant=Mac Catalyst' build

The Standalone, AppStore and China flavors are not affected by anything
described here: every divergence is a new file or sits behind `#if NATIVE`.

## Why it exists

The Mac app is a Mac Catalyst binary. Two things it needs do not work for a
Catalyst process that lacks a provisioning profile:

| Need | Why it fails | NATIVE's answer |
|---|---|---|
| Keychain | A Catalyst process only has the data protection keychain (Apple TN3137). That keychain needs `application-identifier` / `keychain-access-groups`, which the OS honours only with a provisioning profile. Every `SecItem*` call returns `errSecMissingEntitlement` (-34018) regardless of who signed the app; adding the entitlement without a profile stops the app launching. | A native macOS tool, `rootshell-keychain`, embedded in `Contents/Helpers`. A native process uses the login keychain under any signature. |
| Local shells | Standalone reaches the PTY through `rootshell-helper`, which validates its peer by Team ID. With no team the helper must be told to trust an ad-hoc peer by bundle identifier. | The unsandboxed app opens the PTY and spawns `login(1)` itself. |

NATIVE is still the Catalyst app: the UI is UIKit. It is "native" in that the
blocked operations run as genuine macOS code.

## The pieces

- `Configuration/Native.xcconfig` (+ `Debug-`/`Release-Native.xcconfig`):
  Standalone plus `-D NATIVE`, the `-` keychain-group sentinel, no iCloud
  container, no Sparkle feed, and `Native-MacCatalyst.entitlements`
  (Standalone's entitlements minus everything that needs a profile).
- `scripts/add-native-flavor.py`: adds the `DebugNative`/`ReleaseNative`
  configurations, the `rootshell-keychain` target, its embedding (excluded
  from every non-Native configuration) and the `rootshell-Native` scheme.
  Idempotent and fail-closed; re-run it after an upstream merge that
  regenerates `project.pbxproj`.
- `rootshell/Core/Security/NativeSecItemShim.swift`: module-level
  `SecItemAdd/CopyMatching/Update/Delete`. Swift resolves the app module's
  declarations ahead of Security's, so every existing call site is rerouted
  with no source change.
- `rootshell-keychain/Sources/main.swift`: the proxy. Length-prefixed binary
  plists over stdin/stdout; secrets never appear in argv or the environment.
- `rootshell/Features/LocalShell/NativeLocalShellSpawner.swift` and the
  `#if NATIVE` branches in `CatalystLocalShellSession.swift`.
- `rootshell/Core/Helper/HelperConnection+LocalShell.swift`: "can a local
  shell be opened?" as a question separate from "is the helper running?".

## Keychain semantics under NATIVE

The tool replays the app's query against the login keychain after removing
the attributes that only mean something to the data protection keychain:
`kSecAttrAccessGroup`, `kSecAttrSynchronizable`, `kSecAttrAccessible`,
`kSecAttrAccessControl`, `kSecUseDataProtectionKeychain`.

- **No iCloud Keychain sync.** The `iCloudSync` storage level is stored
  locally. (CloudKit sync is unavailable too: both need the iCloud
  entitlement, which no unpaid account can obtain.)
- **Biometric / passcode protection is enforced by the app, not the OS.**
  The login keychain has no `SecAccessControl`. Items saved with one are
  marked, and reading a marked item requires a successful
  `LAContext.evaluatePolicy(.deviceOwnerAuthentication)` in the app first.
- **Object-reference queries return `errSecUnimplemented`.** A `SecKey`,
  `SecCertificate` or `SecIdentity` cannot cross a process boundary. Today
  that is only the Kubernetes client-certificate identity.
- Only the app module is rerouted. Code in other modules still calls
  Security directly and keeps failing with -34018: the RootshellPushKit
  package and the VPN extension (neither feature is available without a
  profile anyway), and the rootshell-vnc package's
  `LastConnectionCredentialStore` (VNC "last connection" credentials are not
  remembered; passwords saved through `VNCPasswordManager` are).

### Trust model

The login keychain trusts `rootshell-keychain`'s code identity, so the tool
decides who may drive it. It refuses to run unless it is inside
`<App>.app/Contents/Helpers`, its parent process is that bundle's main
executable with a valid signature and the bundle's identifier, and either
both carry the same Team ID or neither file is writable by the invoking user
(a root-owned install).

With no Team ID these checks raise the bar but cannot fully authenticate the
caller against malware already running as the same user. Re-signing the
bundle with a stable identity (any Apple Development certificate) closes that
gap and also stops the Keychain access prompts from recurring after each
rebuild, since an ad-hoc identity is the binary's hash.

## Local shells under NATIVE

Same `login -flp USER /bin/bash --noprofile --norc -c "exec -l SHELL"` command
line, from-scratch environment and shell-integration injection as the helper.
TCC prompts for programs run in the shell are attributed to rootshell itself.

Still helper-only: piped processes, one-shot command execution (AI agent,
session discovery, remote exec probe), local multiplexer recovery and the
herdr local channel. They keep calling `ensureHelperRunning()` and degrade as
they already do when the helper is absent.
