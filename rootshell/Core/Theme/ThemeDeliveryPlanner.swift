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
