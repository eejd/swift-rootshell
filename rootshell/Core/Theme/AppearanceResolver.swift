//
//  AppearanceResolver.swift
//  rootshell
//
//  Pure decision logic for the app's single appearance state.
//
//  The app resolves exactly one appearance: the OS windowing setting when the
//  user's Appearance mode is Automatic, or the explicit Light/Dark override
//  otherwise. Window chrome, the Day/Night terminal theme pair, and the
//  semantic light/dark scheme reported to every terminal surface all derive
//  from that one resolved style. Nothing reads the style back through a
//  window, so a forced chrome can never masquerade as the OS setting.
//
//  This file is Foundation-only so `scripts/test-theme-delivery.sh` can
//  compile it with a bare `swiftc`, outside Xcode and without UIKit.
//

import Foundation

enum AppearanceResolver {
    /// A trustworthy light/dark value. There is deliberately no `.unspecified`
    /// case: an unknown OS state is `nil`, never silently "light".
    enum Style: Equatable, Sendable {
        case light
        case dark
    }

    /// The user's Appearance mode. Mirrors `AppearanceManager.AppearanceMode`
    /// without importing SwiftUI/UIKit.
    enum Mode: Equatable, Sendable {
        case automatic
        case light
        case dark
    }

    struct Input: Equatable, Sendable {
        /// The OS windowing appearance as read by `SystemAppearanceMonitor`,
        /// or `nil` when nothing trustworthy has been observed yet.
        var osStyle: Style?
        /// The user's explicit override, if any.
        var appearanceMode: Mode
        /// Whether Match System Theme (the Day/Night pair) is enabled.
        var dayNightEnabled: Bool
        var dayTheme: String
        var nightTheme: String
        /// Whether protected data (UserDefaults) is currently readable.
        var protectedDataAvailable: Bool
        /// The last style the caller acted on, used only while the OS value is
        /// temporarily unknown (e.g. before the first scene connects).
        var lastKnown: Style?
    }

    enum Decision: Equatable, Sendable {
        /// Apply `theme`; `persist` is false while protected data is unavailable
        /// so the caller propagates the change now and saves it on unlock.
        case apply(theme: String, style: Style, persist: Bool)
        /// Nothing trustworthy to act on yet; re-run when the monitor reports.
        case deferred(reason: String)
        /// Day/Night is off: the fixed theme is itself an explicit override.
        case noop
    }

    /// The single resolved appearance. An explicit override wins outright;
    /// Automatic follows the OS, falling back to the last known value.
    static func effectiveStyle(os: Style?, mode: Mode, lastKnown: Style?) -> Style? {
        switch mode {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return os ?? lastKnown
        }
    }

    static func decide(_ input: Input) -> Decision {
        guard input.dayNightEnabled else { return .noop }
        guard let style = effectiveStyle(
            os: input.osStyle,
            mode: input.appearanceMode,
            lastKnown: input.lastKnown
        ) else {
            return .deferred(reason: "OS appearance not yet observed")
        }
        let theme = style == .light ? input.dayTheme : input.nightTheme
        return .apply(theme: theme, style: style, persist: input.protectedDataAvailable)
    }
}
