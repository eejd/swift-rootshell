#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/rootshell-theme-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

xcrun swiftc -parse-as-library \
    -module-cache-path "$test_dir/module-cache" \
    "$repo_root/rootshell/Core/Theme/ThemeDeliveryPlanner.swift" \
    "$repo_root/scripts/tests/ThemeDeliveryPlannerTests.swift" \
    -o "$test_dir/theme-delivery-tests"

"$test_dir/theme-delivery-tests"
