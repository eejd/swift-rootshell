import Foundation

enum AppearanceResolverTests {
    static func run() {
        testAutomaticFollowsOS()
        testAutomaticFallsBackToLastKnown()
        testAutomaticDefersWithoutAnySignal()
        testExplicitOverrideWinsOverOS()
        testDayNightDisabledIsNoop()
        testProtectedDataUnavailableStillApplies()
        testEffectiveStyleTable()
        print("AppearanceResolverTests: PASS")
    }

    private static func input(
        os: AppearanceResolver.Style?,
        mode: AppearanceResolver.Mode = .automatic,
        dayNight: Bool = true,
        protected: Bool = true,
        lastKnown: AppearanceResolver.Style? = nil
    ) -> AppearanceResolver.Input {
        AppearanceResolver.Input(
            osStyle: os,
            appearanceMode: mode,
            dayNightEnabled: dayNight,
            dayTheme: "Solarized Light",
            nightTheme: "Catppuccin Mocha",
            protectedDataAvailable: protected,
            lastKnown: lastKnown
        )
    }

    private static func testAutomaticFollowsOS() {
        expect(
            AppearanceResolver.decide(input(os: .dark))
                == .apply(theme: "Catppuccin Mocha", style: .dark, persist: true),
            "automatic + OS dark must select the night theme"
        )
        expect(
            AppearanceResolver.decide(input(os: .light))
                == .apply(theme: "Solarized Light", style: .light, persist: true),
            "automatic + OS light must select the day theme"
        )
    }

    private static func testAutomaticFallsBackToLastKnown() {
        expect(
            AppearanceResolver.decide(input(os: nil, lastKnown: .light))
                == .apply(theme: "Solarized Light", style: .light, persist: true),
            "an unknown OS value must fall back to the last known style"
        )
    }

    private static func testAutomaticDefersWithoutAnySignal() {
        guard case .deferred = AppearanceResolver.decide(input(os: nil)) else {
            fatalError("no OS signal and no last known style must defer, never assume light")
        }
    }

    private static func testExplicitOverrideWinsOverOS() {
        expect(
            AppearanceResolver.decide(input(os: .dark, mode: .light))
                == .apply(theme: "Solarized Light", style: .light, persist: true),
            "an explicit Light override must win over a dark OS"
        )
        expect(
            AppearanceResolver.decide(input(os: .light, mode: .dark))
                == .apply(theme: "Catppuccin Mocha", style: .dark, persist: true),
            "an explicit Dark override must win over a light OS"
        )
        expect(
            AppearanceResolver.decide(input(os: nil, mode: .dark))
                == .apply(theme: "Catppuccin Mocha", style: .dark, persist: true),
            "an explicit override never defers, even with no OS signal"
        )
    }

    private static func testDayNightDisabledIsNoop() {
        expect(
            AppearanceResolver.decide(input(os: .dark, dayNight: false)) == .noop,
            "Day/Night off means the fixed theme is the user's explicit choice"
        )
    }

    private static func testProtectedDataUnavailableStillApplies() {
        expect(
            AppearanceResolver.decide(input(os: .dark, protected: false))
                == .apply(theme: "Catppuccin Mocha", style: .dark, persist: false),
            "a locked device must still propagate the theme, only deferring persistence"
        )
    }

    private static func testEffectiveStyleTable() {
        typealias R = AppearanceResolver
        expect(R.effectiveStyle(os: .dark, mode: .automatic, lastKnown: nil) == .dark, "automatic follows OS")
        expect(R.effectiveStyle(os: nil, mode: .automatic, lastKnown: .dark) == .dark, "automatic falls back")
        expect(R.effectiveStyle(os: nil, mode: .automatic, lastKnown: nil) == nil, "automatic with nothing is nil")
        expect(R.effectiveStyle(os: .dark, mode: .light, lastKnown: nil) == .light, "override light")
        expect(R.effectiveStyle(os: .light, mode: .dark, lastKnown: .light) == .dark, "override dark")
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
