#!/usr/bin/env python3
"""Edit rootshell.xcodeproj/project.pbxproj into a Catalyst-only, source-built
SwiftPM graph for the MacPorts aqua/rootshell port (ADR-0007 Phase 7a).

Why a script instead of a hand-written patch: this pbxproj is ~6700 lines and
every upstream re-pin regenerates large stretches of it (new object IDs,
reordered sections). A literal diff would silently half-apply -- or worse,
apply to the wrong objects -- the next time this fork rebases onto a newer
upstream tag. This script instead finds objects BY THEIR STABLE IDENTITY
(package name / product name) and edits every place that references them,
failing closed (raising, not skipping) if an expected object or reference
count doesn't match what was true when this script was last verified against
the tree -- see the EXPECTED_* counts below. Re-run this after every re-pin;
if upstream's own package graph changed shape, this script will tell you
exactly where, instead of producing a project that silently reverted the
prune.

Two independent operations, run separately so they land as separate,
independently-revertable commits (see ADR-0007 Phase 7a commits 5 and 6):

    remove-ios-only   Delete the 12 SwiftPM package references whose every
                       product is consumed exclusively by non-Catalyst
                       targets (platformFilters = (ios, xros, ), or a target
                       that Catalyst never builds at all). These packages are
                       still downloaded by SwiftPM even though rootshell-
                       standalone never links them -- platformFilters is a
                       build-time, not resolve-time, filter.

    localize-providers Replace the three MacPorts-built provider packages
                       (ghosttykit-rootshell, trzsz-ssh-rootshell,
                       Sparkle-rootshell) with XCLocalSwiftPackageReferences
                       pointing at Packages/<name>, mirroring the existing
                       Packages/RootshellPushKit local reference. Also drops
                       the two extra products of the first two packages that
                       only exist for iOS/App Store/VPN-appex targets
                       (GhosttyKitAppStore, VPNTunnel) -- rootshell-standalone
                       never links them either.

Both operations are PORT-ONLY: they intentionally break the "rootshell" and
"rootshell-china" (and, for VPNTunnel, "tunnel"/"VPNTunnelExtension") targets,
which is fine because this whole branch is never proposed upstream (D5/D9 in
the MacPorts overlay's ADR-0007) -- only "rootshell-standalone" is built by
the port. Never run this against a branch meant to stay buildable for iOS or
the App Store.

Usage:
    python3 scripts/macports-prune-package-graph.py remove-ios-only [--check]
    python3 scripts/macports-prune-package-graph.py localize-providers [--check]

--check runs every verification without writing the file (dry run).
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parent.parent / "rootshell.xcodeproj" / "project.pbxproj"


# ---------------------------------------------------------------------------
# Generic pbxproj line-oriented block editor.
#
# Every object in a pbxproj is either:
#   - a single physical line ending in "};" (PBXBuildFile, and list entries
#     like "<ID> /* comment */,"), or
#   - a multi-line stanza "<ID> /* comment */ = {\n ... \n<same-indent>};\n"
#
# We never touch anything by line number (line numbers shift after every
# deletion) -- always re-locate by object ID / substring, and re-scan the
# CURRENT in-memory line list on each call.
# ---------------------------------------------------------------------------


class PbxprojSurgeryError(RuntimeError):
    pass


def find_stanza(lines: list[str], obj_id: str) -> tuple[int, int]:
    """Return the [start, end) line range of the object's own definition
    stanza: a line starting with `<obj_id> ` (word-boundary) followed later
    on the same line by "= {". Multi-line stanzas are closed by the first
    following line whose leading whitespace exactly matches the opening
    line's leading whitespace and whose stripped content is "};" -- this
    correctly skips nested blocks (e.g. XCRemoteSwiftPackageReference's own
    nested `requirement = { ... };`), which are indented one level deeper.
    """
    pattern = re.compile(rf"^(\s*){re.escape(obj_id)}\b.*=\s*\{{")
    start = None
    indent = None
    for i, line in enumerate(lines):
        m = pattern.match(line)
        if m:
            start = i
            indent = m.group(1)
            break
    if start is None:
        raise PbxprojSurgeryError(f"could not find definition stanza for object {obj_id!r}")
    if lines[start].rstrip().endswith("};"):
        return (start, start + 1)
    close_pattern = re.compile(rf"^{re.escape(indent)}\}};\s*$")
    for j in range(start + 1, len(lines)):
        if close_pattern.match(lines[j]):
            return (start, j + 1)
    raise PbxprojSurgeryError(f"unterminated stanza for object {obj_id!r} (opened at line {start + 1})")


def delete_ranges(lines: list[str], ranges: list[tuple[int, int]]) -> list[str]:
    """Delete a set of non-overlapping [start, end) ranges from lines."""
    doomed = set()
    for start, end in ranges:
        doomed.update(range(start, end))
    return [line for i, line in enumerate(lines) if i not in doomed]


def require_count(what: str, actual: int, expected: int) -> None:
    if actual != expected:
        raise PbxprojSurgeryError(
            f"expected {expected} occurrence(s) of {what}, found {actual} -- "
            "the pbxproj shape has changed since this script was last verified; "
            "re-derive the expected counts by hand before re-running"
        )


# ---------------------------------------------------------------------------
# operation: remove-ios-only
# ---------------------------------------------------------------------------


@dataclass
class RemovablePackage:
    name: str
    package_ref_id: str
    product_dep_id: str
    product_name: str
    expected_build_file_count: int
    expected_product_dep_list_count: int


# Every product below is consumed EXCLUSIVELY by targets rootshell-standalone
# never builds, or by PBXBuildFile entries carrying
# platformFilters = (ios, xros, ) on every single reference -- confirmed by a
# full cross-reference of every PBXBuildFile, packageProductDependencies list,
# and PBXFrameworksBuildPhase/PBXCopyFilesBuildPhase files list in the tree
# (2026-09-09). libgit2-rootshell is not in rootshell-standalone's dependency
# graph at all; the other eleven ARE listed there but every one of their
# PBXBuildFile entries is platformFilters-restricted to ios/xros, so Catalyst
# never actually compiles them in -- SwiftPM still downloads the xcframework
# regardless, which is the entire point of removing the reference (D6).
REMOVABLE_PACKAGES = [
    RemovablePackage("bat-rootshell", "47BTP0002F680000AABB0000", "47BTP0012F680000AABB0001", "bat_ios", 3, 3),
    RemovablePackage("curl_ios-rootshell", "47CURL0002FE0000AABB0000", "47CURL0012FE0000AABB0001", "curl_ios", 3, 3),
    RemovablePackage("helix-rootshell", "47HLX0002FD00000AABB0000", "47HLX0012FD00000AABB0001", "HelixKit", 3, 3),
    RemovablePackage("ios_system-rootshell", "47IOS0002FA00000AABB0000", "47IOS0012FA00000AABB0001", "ios_system", 3, 3),
    RemovablePackage("joe-rootshell", "47JOE0002FA00000AABB0000", "47JOE0012FA00000AABB0001", "joe", 3, 3),
    RemovablePackage("jq-rootshell", "47JQPKG02FB00000AABB0000", "47JQPKG12FB00000AABB0001", "jq_ios", 3, 3),
    RemovablePackage("libarchive_ios-rootshell", "47LAR0002FF20000AABB0000", "47LAR0012FF20000AABB0001", "libarchive_ios", 3, 3),
    RemovablePackage("libgit2-rootshell", "47B617022FF30000AABB0000", "47B617122FF30000AABB0001", "libgit2", 2, 2),
    RemovablePackage("network_ios-rootshell", "47NWPKG02FF10000AABB0000", "47NWPKG12FF10000AABB0001", "network_ios", 3, 3),
    RemovablePackage("ripgrep-rootshell", "47RGP0002F680000AABB0000", "47RGP0012F680000AABB0001", "ripgrep_ios", 3, 3),
    RemovablePackage("vim-rootshell", "47A0B0012F8A000000000001", "47A0B0022F8A000000000002", "vim", 3, 3),
    RemovablePackage("xz_ios-rootshell", "47XZPKG02FF00000AABB0000", "47XZPKG12FF00000AABB0001", "xz_ios", 3, 3),
]


def remove_product_and_its_build_files(lines: list[str], product_dep_id: str, product_name: str, expected_build_files: int) -> list[str]:
    """Delete every PBXBuildFile line whose productRef is product_dep_id, and
    every PBXFrameworksBuildPhase/PBXCopyFilesBuildPhase `files` list entry
    that references one of those PBXBuildFile's own object IDs.
    """
    build_file_pattern = re.compile(rf"^\s*([0-9A-Za-z]+)\s*/\*[^*]*\*/\s*=\s*\{{isa = PBXBuildFile;.*productRef = {re.escape(product_dep_id)}\b")
    build_file_ids = []
    build_file_line_indices = []
    for i, line in enumerate(lines):
        m = build_file_pattern.match(line)
        if m:
            build_file_ids.append(m.group(1))
            build_file_line_indices.append(i)
    require_count(f"PBXBuildFile entries for product {product_name!r} ({product_dep_id})", len(build_file_ids), expected_build_files)

    ranges = [(i, i + 1) for i in build_file_line_indices]

    for bf_id in build_file_ids:
        phase_ref_pattern = re.compile(rf"^\s*{re.escape(bf_id)}\s*/\*.*\*/,\s*$")
        matches = [i for i, line in enumerate(lines) if phase_ref_pattern.match(line)]
        require_count(f"build-phase file-list entry for PBXBuildFile {bf_id} (product {product_name!r})", len(matches), 1)
        ranges.append((matches[0], matches[0] + 1))

    return delete_ranges(lines, ranges)


def remove_from_product_dependency_lists(lines: list[str], product_dep_id: str, product_name: str, expected: int) -> list[str]:
    pattern = re.compile(rf"^\s*{re.escape(product_dep_id)}\s*/\*.*\*/,\s*$")
    matches = [i for i, line in enumerate(lines) if pattern.match(line)]
    require_count(f"packageProductDependencies entries for product {product_name!r} ({product_dep_id})", len(matches), expected)
    return delete_ranges(lines, [(i, i + 1) for i in matches])


def remove_package_reference_list_entry(lines: list[str], package_ref_id: str, package_name: str) -> list[str]:
    pattern = re.compile(rf"^\s*{re.escape(package_ref_id)}\s*/\*.*\*/,\s*$")
    matches = [i for i, line in enumerate(lines) if pattern.match(line)]
    require_count(f"packageReferences list entry for {package_name!r} ({package_ref_id})", len(matches), 1)
    return delete_ranges(lines, [(matches[0], matches[0] + 1)])


def op_remove_ios_only(lines: list[str]) -> list[str]:
    for pkg in REMOVABLE_PACKAGES:
        lines = remove_product_and_its_build_files(lines, pkg.product_dep_id, pkg.product_name, pkg.expected_build_file_count)
        lines = remove_from_product_dependency_lists(lines, pkg.product_dep_id, pkg.product_name, pkg.expected_product_dep_list_count)
        start, end = find_stanza(lines, pkg.product_dep_id)
        lines = delete_ranges(lines, [(start, end)])
        start, end = find_stanza(lines, pkg.package_ref_id)
        lines = delete_ranges(lines, [(start, end)])
        lines = remove_package_reference_list_entry(lines, pkg.package_ref_id, pkg.name)
    return lines


# ---------------------------------------------------------------------------
# operation: localize-providers
# ---------------------------------------------------------------------------


@dataclass
class ProviderPackage:
    name: str
    package_ref_id: str
    kept_product_dep_id: str
    kept_product_name: str
    local_relative_path: str
    # A product of the SAME package that rootshell-standalone never links
    # (only the iOS/App Store/VPN-appex targets do) -- dropped entirely,
    # same rationale as REMOVABLE_PACKAGES above, just scoped to one product
    # of a package we otherwise keep.
    dropped_product_dep_id: str | None = None
    dropped_product_name: str | None = None
    dropped_product_build_file_count: int = 0
    dropped_product_list_count: int = 0
    new_local_ref_id: str = ""


PROVIDER_PACKAGES = [
    ProviderPackage(
        name="ghosttykit-rootshell",
        package_ref_id="9CE133DDBCF3D8D79F649B5F",
        kept_product_dep_id="417549D6E2D63FC56F6548A4",
        kept_product_name="GhosttyKitStandalone",
        local_relative_path="Packages/ghosttykit-rootshell",
        dropped_product_dep_id="1F83B189B33FFF1BDDA28F6B",
        dropped_product_name="GhosttyKitAppStore",
        dropped_product_build_file_count=2,
        dropped_product_list_count=2,
        new_local_ref_id="47GHK0002F900000AABB0000",
    ),
    ProviderPackage(
        name="trzsz-ssh-rootshell",
        package_ref_id="47TSSH0002FC00000AABB0000",
        kept_product_dep_id="47TSSH0112FC00000AABB0001",
        kept_product_name="TrzszSSH",
        local_relative_path="Packages/trzsz-ssh-rootshell",
        dropped_product_dep_id="47TSSH0122FC00000AABB0002",
        dropped_product_name="VPNTunnel",
        dropped_product_build_file_count=2,
        dropped_product_list_count=2,
        new_local_ref_id="47TZS0002F900000AABB0000",
    ),
    ProviderPackage(
        name="Sparkle-rootshell",
        package_ref_id="47A810B02EE40000005A0B9C",
        kept_product_dep_id="47A810B12EE40000005A0B9C",
        kept_product_name="Sparkle",
        local_relative_path="Packages/sparkle-rootshell",
        new_local_ref_id="47SPK0002F900000AABB0000",
    ),
]


def repoint_product_package_field(lines: list[str], product_dep_id: str, product_name: str, new_package_ref_id: str, new_package_name: str) -> list[str]:
    start, end = find_stanza(lines, product_dep_id)
    pattern = re.compile(r"^(\s*package = )[0-9A-Za-z]+(\s*/\*.*\*/;\s*)$")
    replaced = 0
    for i in range(start, end):
        m = pattern.match(lines[i])
        if m:
            lines[i] = re.sub(
                r"package = [0-9A-Za-z]+ /\*.*\*/;",
                f'package = {new_package_ref_id} /* XCLocalSwiftPackageReference "{new_package_name}" */;',
                lines[i],
            )
            replaced += 1
    require_count(f"'package =' field inside product dependency {product_name!r} ({product_dep_id})", replaced, 1)
    return lines


def insert_local_package_reference(lines: list[str], after_obj_id: str, new_id: str, relative_path: str) -> list[str]:
    """Insert a new XCLocalSwiftPackageReference stanza immediately after an
    existing object's stanza, matching that object's indentation. Used to
    place new local refs right after the existing
    'Packages/RootshellPushKit' one, in the same section.
    """
    start, end = find_stanza(lines, after_obj_id)
    indent = re.match(r"^(\s*)", lines[start]).group(1)
    stanza = [
        f'{indent}{new_id} /* XCLocalSwiftPackageReference "{relative_path}" */ = {{\n',
        f"{indent}\tisa = XCLocalSwiftPackageReference;\n",
        f"{indent}\trelativePath = {relative_path};\n",
        f"{indent}}};\n",
    ]
    return lines[:end] + stanza + lines[end:]


def add_to_package_references_list(lines: list[str], after_obj_id: str, new_id: str, relative_path: str) -> list[str]:
    pattern = re.compile(rf"^(\s*){re.escape(after_obj_id)}\s*/\*.*\*/,\s*$")
    matches = [i for i, line in enumerate(lines) if pattern.match(line)]
    require_count(f"packageReferences list entry for {after_obj_id}", len(matches), 1)
    i = matches[0]
    indent = pattern.match(lines[i]).group(1)
    new_line = f'{indent}{new_id} /* XCLocalSwiftPackageReference "{relative_path}" */,\n'
    return lines[: i + 1] + [new_line] + lines[i + 1 :]


def op_localize_providers(lines: list[str]) -> list[str]:
    for pkg in PROVIDER_PACKAGES:
        if pkg.dropped_product_dep_id:
            lines = remove_product_and_its_build_files(
                lines, pkg.dropped_product_dep_id, pkg.dropped_product_name, pkg.dropped_product_build_file_count
            )
            lines = remove_from_product_dependency_lists(
                lines, pkg.dropped_product_dep_id, pkg.dropped_product_name, pkg.dropped_product_list_count
            )
            start, end = find_stanza(lines, pkg.dropped_product_dep_id)
            lines = delete_ranges(lines, [(start, end)])

        # Insert the new local reference and repoint the kept product BEFORE
        # deleting the old remote reference, so find_stanza can still use the
        # old reference's position as an anchor for insertion ordering.
        lines = insert_local_package_reference(lines, "47PKG0002F900000AABB0000", pkg.new_local_ref_id, pkg.local_relative_path)
        lines = add_to_package_references_list(lines, "47PKG0002F900000AABB0000", pkg.new_local_ref_id, pkg.local_relative_path)
        lines = repoint_product_package_field(lines, pkg.kept_product_dep_id, pkg.kept_product_name, pkg.new_local_ref_id, pkg.local_relative_path)

        start, end = find_stanza(lines, pkg.package_ref_id)
        lines = delete_ranges(lines, [(start, end)])
        lines = remove_package_reference_list_entry(lines, pkg.package_ref_id, pkg.name)

    return lines


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("operation", choices=["remove-ios-only", "localize-providers"])
    parser.add_argument("--check", action="store_true", help="verify and report without writing the file")
    args = parser.parse_args(argv)

    original = PBXPROJ.read_text().splitlines(keepends=True)
    lines = list(original)

    if args.operation == "remove-ios-only":
        lines = op_remove_ios_only(lines)
    else:
        lines = op_localize_providers(lines)

    delta = len(lines) - len(original)
    print(f"{args.operation}: {len(original)} -> {len(lines)} lines ({delta:+d})", file=sys.stderr)

    if not args.check:
        PBXPROJ.write_text("".join(lines))
        print(f"wrote {PBXPROJ}", file=sys.stderr)
    else:
        print("--check: not written", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
