//
//  SystemAppearanceMonitor.swift
//  rootshell
//
//  The single OS-level source of the system light/dark appearance.
//
//  Nothing else in the app may read `userInterfaceStyle` for theme purposes.
//  In particular the app's own windows are not a valid source: the Appearance
//  setting stamps `overrideUserInterfaceStyle` on every window (and pins
//  `NSApplication.appearance` on Mac Catalyst), so a window trait reports the
//  user's override, not the OS. This monitor reads above the window:
//
//  - iOS/iPadOS: the window scene's `UIScreen` trait collection, observed with
//    `registerForTraitChanges`. The screen sits above the window and is not
//    affected by window-level overrides.
//  - Mac Catalyst: the `AppleInterfaceStyle` global default (present and equal
//    to "Dark" in dark mode, absent in light mode; NSGlobalDomain is readable
//    from the sandbox) plus the `AppleInterfaceThemeChangedNotification`
//    distributed notification the system posts on every flip, including the
//    scheduled Auto transitions.
//
//  An unknown value is `nil`, never "light". Consumers defer until the first
//  trustworthy read and keep the last known value across momentary gaps.
//

import Combine
import Foundation
import os
import UIKit

@MainActor
final class SystemAppearanceMonitor: ObservableObject {
    typealias Style = AppearanceResolver.Style

    static let shared = SystemAppearanceMonitor()

    /// The OS appearance, or `nil` until something trustworthy was observed.
    @Published private(set) var osStyle: Style?

    /// Emits only on an actual change of the OS value.
    let osStyleDidChange = PassthroughSubject<Style, Never>()

    private static let logger = Logger(subsystem: "com.rootshell", category: "SystemAppearance")

    private var started = false
    private var notificationObservers: [NSObjectProtocol] = []
    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    private var screenRegistrations: [ObjectIdentifier: any UITraitChangeRegistration] = [:]
    #endif

    private init() {}

    /// Attach the OS-level sources and perform the first read. Idempotent:
    /// SwiftUI runs `.task` once per window, and several managers may start
    /// the monitor; later calls only re-evaluate.
    func start() {
        guard !started else {
            reevaluate()
            return
        }
        started = true

        #if targetEnvironment(macCatalyst)
        let themeChanged = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in SystemAppearanceMonitor.shared.reevaluate() }
        }
        notificationObservers.append(themeChanged)
        #elseif os(visionOS)
        // No OS-level light/dark source is wired up here: `UIScreen` (this
        // file's iOS/iPadOS source) is API_UNAVAILABLE(visionos), and
        // visionOS has no equivalent system light/dark setting exposed the
        // same way. readOSStyle() below returns nil unconditionally on this
        // platform, so callers defer to AppearanceResolver's existing
        // unknown-value handling (explicit override, or the last known
        // value) rather than getting a wrong answer. Deliberately minimal:
        // visionOS is out of scope for the MacPorts Mac Catalyst Standalone
        // port (D5, ADR-0007), which never builds this platform; this is
        // just enough to keep the shared, upstream-candidate source
        // compiling for rootshell-AppStore's xros/xrsimulator targets.
        #else
        for scene in Self.windowScenes() { attachScreenObserver(to: scene.screen) }
        let sceneConnected = NotificationCenter.default.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: .main
        ) { notification in
            nonisolated(unsafe) let notification = notification
            Task { @MainActor in
                if let scene = notification.object as? UIWindowScene {
                    SystemAppearanceMonitor.shared.attachScreenObserver(to: scene.screen)
                }
                SystemAppearanceMonitor.shared.reevaluate()
            }
        }
        notificationObservers.append(sceneConnected)
        #endif

        // Re-read whenever the app could have missed a flip: returning from the
        // background, a scene activating, or the device unlocking after a
        // background launch that started before protected data was readable.
        for name in [UIApplication.willEnterForegroundNotification, UIScene.didActivateNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in SystemAppearanceMonitor.shared.reevaluate() }
            }
            notificationObservers.append(observer)
        }
        ProtectedDataGuard.whenAvailable { SystemAppearanceMonitor.shared.reevaluate() }

        reevaluate()
    }

    /// Read every source now. Keeps the last known value when nothing
    /// trustworthy is available (for example before the first scene connects).
    func reevaluate() {
        guard let style = Self.readOSStyle() else {
            Self.logger.debug("OS appearance unavailable; keeping \(String(describing: self.osStyle))")
            return
        }
        guard style != osStyle else { return }
        Self.logger.info("OS appearance is now \(style == .light ? "light" : "dark")")
        osStyle = style
        osStyleDidChange.send(style)
    }

    // MARK: - Sources

    /// The current OS appearance without side effects, or `nil` if unknown.
    static func readOSStyle() -> Style? {
        #if targetEnvironment(macCatalyst)
        // Absent means light; the system only writes the key for dark mode.
        let value = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return value?.caseInsensitiveCompare("Dark") == .orderedSame ? .dark : .light
        #elseif os(visionOS)
        // See start()'s visionOS branch: no wired-up source, deliberately.
        return nil
        #else
        for scene in windowScenes() {
            switch scene.screen.traitCollection.userInterfaceStyle {
            case .dark: return .dark
            case .light: return .light
            case .unspecified: continue
            @unknown default: continue
            }
        }
        return nil
        #endif
    }

    private static func windowScenes() -> [UIWindowScene] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    #if !targetEnvironment(macCatalyst) && !os(visionOS)
    private func attachScreenObserver(to screen: UIScreen) {
        let key = ObjectIdentifier(screen)
        guard screenRegistrations[key] == nil else { return }
        let registration = screen.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (_: UIScreen, _: UITraitCollection) in
            Task { @MainActor in SystemAppearanceMonitor.shared.reevaluate() }
        }
        screenRegistrations[key] = registration
    }
    #endif
}
