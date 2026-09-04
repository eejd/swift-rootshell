import Foundation

@main
enum ThemeDeliveryPlannerTests {
    static func main() {
        testThemePrecedenceAndLiveChanges()
        testAtomicDeliveryFallback()
        testSurfaceReassociation()
        testProductionRetargetCoordinator()
        testExactlyOnceSurfaceInitialization()
        testThemePersistenceTransaction()
        print("ThemeDeliveryPlannerTests: PASS")
    }

    private static func testAtomicDeliveryFallback() {
        let effective = ThemeDeliveryPlanner.Resolution(
            themeName: "deleted-tab-theme",
            source: .tab
        )
        var attempts: [String] = []
        let delivery = ThemeDeliveryPlanner.delivery(
            effective: effective,
            globalTheme: "global-light"
        ) { resolution -> String? in
            attempts.append(resolution.themeName)
            return resolution.themeName == "global-light" ? "complete-artifacts" : nil
        }

        expect(
            delivery?.resolution == .init(themeName: "global-light", source: .global),
            "an invalid override must fall back to the complete global theme"
        )
        expect(
            delivery?.artifacts == "complete-artifacts",
            "fallback must return one complete config/scheme artifact set"
        )
        expect(
            attempts == ["deleted-tab-theme", "global-light"],
            "delivery must try the effective override before global fallback"
        )
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


    private static func testProductionRetargetCoordinator() {
        final class FakeSurface: SurfaceThemeContextRetargeting {
            var contexts: [SurfaceThemeAssociations.Context] = []

            func retargetThemeContext(toWindowID windowID: String, tabID: UUID?) {
                contexts.append(.init(tabID: tabID, windowID: windowID))
            }
        }

        let destinationTab = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let surface = FakeSurface()
        SurfaceThemeRetargetCoordinator.retarget(
            surface,
            toWindowID: "window-b",
            tabID: destinationTab
        )
        expect(
            surface.contexts == [.init(tabID: destinationTab, windowID: "window-b")],
            "a live move must deliver destination window and tab in one call"
        )
    }

    private static func testExactlyOnceSurfaceInitialization() {
        var ordinaryEvents: [String] = []
        SurfaceThemeInitializationCoordinator.register(
            themeAlreadySeeded: false,
            recordLifetime: { ordinaryEvents.append("record") },
            deliverInitialTheme: { ordinaryEvents.append("deliver") }
        )
        expect(
            ordinaryEvents == ["record", "deliver"],
            "an ordinary surface must receive exactly one initial delivery after registration"
        )

        var seededEvents: [String] = []
        SurfaceThemeInitializationCoordinator.register(
            themeAlreadySeeded: true,
            recordLifetime: { seededEvents.append("record") },
            deliverInitialTheme: { seededEvents.append("deliver") }
        )
        expect(
            seededEvents == ["record"],
            "a constructor-seeded tmux surface must not receive a second initial delivery"
        )
    }

    private enum InjectedFailure: Error {
        case backing
        case metadata
    }

    private static func testThemePersistenceTransaction() {
        var successEvents: [String] = []
        try! ThemePersistenceCoordinator.commit(
            writeBackingFile: { successEvents.append("backing") },
            writeMetadata: { successEvents.append("metadata") },
            rollbackBackingFile: { successEvents.append("rollback") },
            publish: { successEvents.append("publish") },
            retirePreviousFile: { successEvents.append("retire") }
        )
        expect(
            successEvents == ["backing", "metadata", "publish", "retire"],
            "successful rename must become durable before references publish and the old file retires"
        )

        var sameNameFailureEvents: [String] = []
        do {
            try ThemePersistenceCoordinator.commit(
                writeBackingFile: {
                    sameNameFailureEvents.append("backing")
                    throw InjectedFailure.backing
                },
                writeMetadata: { sameNameFailureEvents.append("metadata") },
                rollbackBackingFile: { sameNameFailureEvents.append("rollback") },
                publish: { sameNameFailureEvents.append("publish") },
                retirePreviousFile: {}
            )
            fatalError("expected injected same-name backing failure")
        } catch InjectedFailure.backing {
            expect(
                sameNameFailureEvents == ["backing", "rollback"],
                "same-name write failure must restore backing data and publish nothing"
            )
        } catch {
            fatalError("unexpected error: \(error)")
        }

        var renameFailureEvents: [String] = []
        do {
            try ThemePersistenceCoordinator.commit(
                writeBackingFile: { renameFailureEvents.append("backing") },
                writeMetadata: {
                    renameFailureEvents.append("metadata")
                    throw InjectedFailure.metadata
                },
                rollbackBackingFile: { renameFailureEvents.append("rollback") },
                publish: { renameFailureEvents.append("publish") },
                retirePreviousFile: { renameFailureEvents.append("retire") }
            )
            fatalError("expected injected rename metadata failure")
        } catch InjectedFailure.metadata {
            expect(
                renameFailureEvents == ["backing", "metadata", "rollback"],
                "rename failure must roll back the new file without publishing or retiring the old file"
            )
        } catch {
            fatalError("unexpected error: \(error)")
        }
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
