import Foundation

@main
enum ThemeDeliveryPlannerTests {
    static func main() {
        testThemePrecedenceAndLiveChanges()
        testSurfaceReassociation()
        print("ThemeDeliveryPlannerTests: PASS")
    }

    private static func testThemePrecedenceAndLiveChanges() {
        expect(
            ThemeDeliveryPlanner.resolve(
                globalTheme: "global-dark",
                windowTheme: "window-light",
                tabTheme: "tab-dark"
            ) == .init(themeName: "tab-dark", source: .tab),
            "tab override must win over window and global"
        )
        expect(
            ThemeDeliveryPlanner.resolve(
                globalTheme: "global-dark",
                windowTheme: "window-light",
                tabTheme: nil
            ) == .init(themeName: "window-light", source: .window),
            "window override must win when the tab override is cleared"
        )
        expect(
            ThemeDeliveryPlanner.resolve(
                globalTheme: "global-light",
                windowTheme: nil,
                tabTheme: nil
            ) == .init(themeName: "global-light", source: .global),
            "a live global change must be visible after overrides are cleared"
        )
    }

    private static func testSurfaceReassociation() {
        let firstTab = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondTab = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        var associations = SurfaceThemeAssociations()

        associations.setWindow("window-a", for: 7)
        associations.setTab(firstTab, for: 7)
        expect(
            associations.context(for: 7) == .init(tabID: firstTab, windowID: "window-a"),
            "initial surface ownership must include its window and tab"
        )

        associations.setTab(secondTab, for: 7)
        expect(
            associations.context(for: 7) == .init(tabID: secondTab, windowID: "window-a"),
            "moving a live pane must replace its tab association"
        )

        associations.setTab(nil, for: 7)
        expect(
            associations.context(for: 7) == .init(tabID: nil, windowID: "window-a"),
            "detaching a live pane must clear its stale tab association"
        )

        associations.removeSurface(7)
        expect(
            associations.context(for: 7) == .init(tabID: nil, windowID: nil),
            "surface teardown must clear all theme ownership"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(message) (\(file):\(line))")
        }
    }
}
