#!/bin/sh
# Compile the pure theme/appearance logic outside Xcode and run its tests.
#
# ThemeDeliveryPlanner and AppearanceResolver are Foundation-only so they can
# be built with a bare swiftc invocation, without GhosttyKit, UIKit, or an
# iOS Simulator. Anything that needs the app (surface registration, the OS
# appearance monitor, Ghostty's CSI ?996n reply) is covered by the manual
# checklist in eejd/swift-rootshell#2.
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rootshell-theme-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library \
    -module-cache-path "$test_dir/module-cache" \
    "$repo_root/rootshell/Core/Theme/ThemeDeliveryPlanner.swift" \
    "$repo_root/rootshell/Core/Theme/AppearanceResolver.swift" \
    "$repo_root/scripts/tests/ThemeDeliveryPlannerTests.swift" \
    "$repo_root/scripts/tests/AppearanceResolverTests.swift" \
    "$repo_root/scripts/tests/ThemeTestMain.swift" \
    -o "$test_dir/theme-delivery-tests"

"$test_dir/theme-delivery-tests"
