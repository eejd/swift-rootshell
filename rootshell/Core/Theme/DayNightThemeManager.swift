//
//  DayNightThemeManager.swift
//  rootshell
//
//  Switches the terminal theme between a day/night pair from the app's single
//  resolved appearance: the OS setting (read only by SystemAppearanceMonitor)
//  when the Appearance mode is Automatic, or the user's explicit Light/Dark
//  override. The decision itself lives in AppearanceResolver so it can be
//  tested outside Xcode.
//

import Combine
import Foundation
import os
import UIKit

/// Manages automatic day/night theme switching based on the resolved appearance
@MainActor
final class DayNightThemeManager: ObservableObject {
    static let shared = DayNightThemeManager()

    typealias Style = AppearanceResolver.Style

    // MARK: - UserDefaults Keys

    private static let ownedKeys: Set<String> = [
        Settings.Theme.dayNightEnabled.name, Settings.Theme.dayNightDay.name, Settings.Theme.dayNightNight.name,
    ]

    /// True while `reload(keys:)` re-assigns properties from the store.
    private var isReloading = false

    // MARK: - Published Properties

    /// Whether day/night theme switching is enabled
    @Published var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            persist(Settings.Theme.dayNightEnabled, enabled)
            handleEnabledChange(wasEnabled: oldValue)
        }
    }

    /// Theme to use during light mode
    @Published var dayTheme: String {
        didSet {
            guard oldValue != dayTheme else { return }
            persist(Settings.Theme.dayNightDay, dayTheme)
            resolveAndApply()
        }
    }

    /// Theme to use during dark mode
    @Published var nightTheme: String {
        didSet {
            guard oldValue != nightTheme else { return }
            persist(Settings.Theme.dayNightNight, nightTheme)
            resolveAndApply()
        }
    }

    /// The resolved appearance the pair currently follows; `nil` until the
    /// first trustworthy OS read (or an explicit override) has been applied.
    @Published private(set) var resolvedStyle: Style?

    /// Whether the resolved appearance is light. Unknown counts as light for
    /// display purposes only; nothing is applied from this value.
    var isCurrentlyLight: Bool { resolvedStyle != .dark }

    // MARK: - Private Properties

    /// Theme to revert to when feature is disabled
    private var defaultTheme: String

    private var cancellables = Set<AnyCancellable>()

    /// Owned keys whose writes were skipped while protected data was unavailable.
    private var pendingPersistence: Set<String> = []
    private var unlockFlushScheduled = false

    private static let logger = Logger(subsystem: "com.rootshell", category: "DayNightTheme")

    // MARK: - Initialization

    private init() {
        // Load saved settings
        let store = SettingsStore.shared
        self.enabled = store.get(Settings.Theme.dayNightEnabled)
        self.dayTheme = store.get(Settings.Theme.dayNightDay)
        self.nightTheme = store.get(Settings.Theme.dayNightNight)
        // deviceOnly restore point for the pre-day/night theme
        self.defaultTheme = store.get(Settings.Theme.dayNightDefault) ?? ThemeManager.shared.currentTheme

        SettingsRefreshHub.shared.register(keys: Self.ownedKeys) { [weak self] keys in
            self?.reload(keys: keys)
        }

        // Both inputs of the resolver: the OS value and the explicit override.
        SystemAppearanceMonitor.shared.osStyleDidChange
            .sink { [weak self] _ in self?.resolveAndApply() }
            .store(in: &cancellables)
        AppearanceManager.shared.appearanceModeDidChange
            .sink { [weak self] _ in self?.resolveAndApply() }
            .store(in: &cancellables)

        if enabled {
            SystemAppearanceMonitor.shared.start()
            resolveAndApply()
        }
    }

    // MARK: - Settings persistence

    /// Write an owned key now, or once the device unlocks. The in-memory value
    /// is always applied immediately; only the UserDefaults write waits.
    private func persist<V: SettingValue>(_ key: SettingKey<V>, _ value: V) {
        guard !isReloading else { return }
        if ProtectedDataGuard.isAvailable {
            SettingsStore.shared.set(key, value)
            return
        }
        pendingPersistence.insert(key.name)
        guard !unlockFlushScheduled else { return }
        unlockFlushScheduled = true
        ProtectedDataGuard.whenAvailable { [weak self] in self?.flushPendingPersistence() }
    }

    private func flushPendingPersistence() {
        unlockFlushScheduled = false
        let pending = pendingPersistence
        pendingPersistence.removeAll()
        let store = SettingsStore.shared
        if pending.contains(Settings.Theme.dayNightEnabled.name) { store.set(Settings.Theme.dayNightEnabled, enabled) }
        if pending.contains(Settings.Theme.dayNightDay.name) { store.set(Settings.Theme.dayNightDay, dayTheme) }
        if pending.contains(Settings.Theme.dayNightNight.name) { store.set(Settings.Theme.dayNightNight, nightTheme) }
        if pending.contains(Settings.Theme.dayNightDefault.name) { store.set(Settings.Theme.dayNightDefault, defaultTheme) }
    }

    /// Re-reads owned keys after an external batch (iCloud, restore, config file).
    func reload(keys: Set<String>) {
        isReloading = true
        defer { isReloading = false }
        let store = SettingsStore.shared
        if keys.contains(Settings.Theme.dayNightDay.name) { dayTheme = store.get(Settings.Theme.dayNightDay) }
        if keys.contains(Settings.Theme.dayNightNight.name) { nightTheme = store.get(Settings.Theme.dayNightNight) }
        if keys.contains(Settings.Theme.dayNightEnabled.name) { enabled = store.get(Settings.Theme.dayNightEnabled) }
    }

    // MARK: - Resolution

    private func handleEnabledChange(wasEnabled: Bool) {
        if enabled && !wasEnabled {
            // Feature was just enabled — capture current theme for reversion
            defaultTheme = ThemeManager.shared.currentTheme
            persist(Settings.Theme.dayNightDefault, defaultTheme)
            SystemAppearanceMonitor.shared.start()
            resolveAndApply()
        } else if !enabled && wasEnabled {
            // Feature was just disabled — revert to the explicit theme
            Self.logger.info("Reverting to default theme: \(self.defaultTheme)")
            resolvedStyle = nil
            ThemeManager.shared.currentTheme = defaultTheme
        }
    }

    /// Re-read the OS and apply the resolved theme. Safe to call at any time,
    /// including from a background launch: the monitor keeps re-evaluating on
    /// unlock, foreground, and scene activation, and every one of those lands
    /// back here through `osStyleDidChange`.
    func recheckAppearance() {
        guard enabled else { return }
        SystemAppearanceMonitor.shared.reevaluate()
        resolveAndApply()
    }

    private static func mode(_ mode: AppearanceManager.AppearanceMode) -> AppearanceResolver.Mode {
        switch mode {
        case .automatic: return .automatic
        case .light: return .light
        case .dark: return .dark
        }
    }

    private func resolveAndApply() {
        let decision = AppearanceResolver.decide(AppearanceResolver.Input(
            osStyle: SystemAppearanceMonitor.shared.osStyle,
            appearanceMode: Self.mode(AppearanceManager.shared.currentAppearanceMode),
            dayNightEnabled: enabled,
            dayTheme: dayTheme,
            nightTheme: nightTheme,
            protectedDataAvailable: ProtectedDataGuard.isAvailable,
            lastKnown: resolvedStyle
        ))

        switch decision {
        case .noop:
            return
        case .deferred(let reason):
            Self.logger.info("Deferring day/night theme: \(reason)")
        case .apply(let theme, let style, _):
            if resolvedStyle != style {
                Self.logger.info("Resolved appearance is \(style == .light ? "light" : "dark")")
                resolvedStyle = style
            }
            // ThemeManager propagates the change immediately and defers its own
            // persistence while protected data is unavailable.
            if ThemeManager.shared.currentTheme != theme {
                Self.logger.info("Applying \(style == .light ? "day" : "night") theme: \(theme)")
                ThemeManager.shared.currentTheme = theme
            }
        }
    }
}
