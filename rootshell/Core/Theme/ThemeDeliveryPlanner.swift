//
//  ThemeDeliveryPlanner.swift
//  rootshell
//
//  Pure theme precedence and surface-association state shared by the app and
//  the standalone regression test.
//

import Foundation

struct ThemeDeliveryPlanner {
    enum Source: Equatable {
        case global
        case window
        case tab
    }

    struct Resolution: Equatable {
        let themeName: String
        let source: Source
    }

    struct Delivery<Artifacts> {
        let resolution: Resolution
        let artifacts: Artifacts
    }

    static func resolve(
        globalTheme: String,
        windowTheme: String?,
        tabTheme: String?
    ) -> Resolution {
        if let tabTheme {
            return Resolution(themeName: tabTheme, source: .tab)
        }
        if let windowTheme {
            return Resolution(themeName: windowTheme, source: .window)
        }
        return Resolution(themeName: globalTheme, source: .global)
    }

    /// Load a complete set of renderer artifacts for the effective theme. An
    /// invalid override falls back to a complete global set; a partial result
    /// is never returned, so callers cannot pair one theme's config with
    /// another theme's semantic light/dark scheme.
    static func delivery<Artifacts>(
        effective: Resolution,
        globalTheme: String,
        load: (Resolution) -> Artifacts?
    ) -> Delivery<Artifacts>? {
        if let artifacts = load(effective) {
            return Delivery(resolution: effective, artifacts: artifacts)
        }
        guard effective.source != .global else { return nil }

        let fallback = Resolution(themeName: globalTheme, source: .global)
        guard let artifacts = load(fallback) else { return nil }
        return Delivery(resolution: fallback, artifacts: artifacts)
    }
}

protocol SurfaceThemeContextRetargeting {
    func retargetThemeContext(toWindowID windowID: String, tabID: UUID?)
}

enum SurfaceThemeRetargetCoordinator {
    /// Production funnel for a live pane move. Window and tab ownership are
    /// delivered together so there is no intermediate refresh using half of
    /// the old context.
    static func retarget<T: SurfaceThemeContextRetargeting>(
        _ surface: T,
        toWindowID windowID: String,
        tabID: UUID?
    ) {
        surface.retargetThemeContext(toWindowID: windowID, tabID: tabID)
    }
}

struct SurfaceThemeAssociations {
    struct Context: Equatable {
        let tabID: UUID?
        let windowID: String?
    }

    private var tabs: [Int: UUID] = [:]
    private var windows: [Int: String] = [:]

    mutating func setTab(_ tabID: UUID?, for surfaceID: Int) {
        tabs[surfaceID] = tabID
    }

    mutating func setWindow(_ windowID: String?, for surfaceID: Int) {
        windows[surfaceID] = windowID
    }

    mutating func removeSurface(_ surfaceID: Int) {
        tabs.removeValue(forKey: surfaceID)
        windows.removeValue(forKey: surfaceID)
    }

    func context(for surfaceID: Int) -> Context {
        Context(tabID: tabs[surfaceID], windowID: windows[surfaceID])
    }
}
