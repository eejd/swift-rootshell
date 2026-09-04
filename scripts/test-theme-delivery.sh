#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rootshell-theme-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library \
    -module-cache-path "$test_dir/module-cache" \
    "$repo_root/rootshell/Core/Theme/ThemeDeliveryPlanner.swift" \
    "$repo_root/scripts/tests/ThemeDeliveryPlannerTests.swift" \
    -o "$test_dir/theme-delivery-tests"

"$test_dir/theme-delivery-tests"

# Production integration guards. The standalone Swift test exercises the
# shared planner/coordinator; these assertions ensure the app's mutation and
# pane-move call sites continue to use those tested funnels.
custom_theme_manager="$repo_root/rootshell/Core/Theme/CustomThemeManager.swift"
theme_manager="$repo_root/rootshell/Core/Theme/ThemeManager.swift"

assert_before() {
    first_line=$(grep -nF "$2" "$1" | sed -n '1s/:.*//p')
    second_line=$(grep -nF "$3" "$1" | sed -n '$s/:.*//p')
    if [ -z "$first_line" ] || [ -z "$second_line" ] || [ "$first_line" -ge "$second_line" ]; then
        echo "expected '$2' before '$3' in $1" >&2
        exit 1
    fi
}

grep -Fq 'ThemeOverrideManager.shared.clearOverrides(named: theme.name)' \
    "$custom_theme_manager"
grep -Fq 'themeDidChange.send(currentTheme)' \
    "$theme_manager"
grep -Fq 'SurfaceThemeRetargetCoordinator.retarget(' \
    "$repo_root/rootshell/Features/Tmux/TmuxController.swift"
grep -Fq 'SurfaceThemeRetargetCoordinator.retarget(' \
    "$repo_root/rootshell/UI/Tabs/TabsModel.swift"
grep -Fq 'override func retargetThemeContext(toWindowID newWindowID: String, tabID newTabID: UUID?)' \
    "$repo_root/rootshell/UI/Terminal/TerminalView.swift"
grep -Fq 'refreshSurfaceTheme(surface, tabId: newTabID, windowId: newWindowID)' \
    "$repo_root/rootshell/UI/Terminal/TerminalView.swift"
grep -Fq 'ghostty_surface_new_tmux_pane_with_theme(' \
    "$repo_root/rootshell/UI/Terminal/TerminalSurfaceController.swift"

# Rename publication is ordered: install the new resolvable theme before any
# synchronous name-based subscriber runs. Deletion clears scoped references
# before removing the theme file. Catalog refresh must precede its live event.
assert_before "$custom_theme_manager" \
    'writeGhosttyFile(for: updated)' \
    'ThemeManager.shared.currentTheme = updated.name'
assert_before "$custom_theme_manager" \
    'ThemeOverrideManager.shared.clearOverrides(named: theme.name)' \
    'deleteGhosttyFile(named: theme.name)'
assert_before "$theme_manager" \
    'rebuildCatalog()' \
    'themeDidChange.send(currentTheme)'
