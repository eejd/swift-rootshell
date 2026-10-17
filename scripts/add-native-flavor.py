#!/usr/bin/env python3
"""Add the NATIVE build flavor to rootshell.xcodeproj.

NATIVE is a Standalone variant for builds with no Apple-issued provisioning
profile (see Configuration/Native.xcconfig). This script makes the project
changes that flavor needs, and nothing else:

  1. DebugNative / ReleaseNative build configurations: clones of
     DebugStandalone / ReleaseStandalone in every configuration list. Where a
     clone was based on {Debug,Release}-Standalone.xcconfig it is rebased onto
     {Debug,Release}-Native.xcconfig; every other clone keeps its base, so all
     non-app targets build exactly as they do for Standalone.
  2. The `rootshell-keychain` target: a native macOS command-line tool built
     from the rootshell-keychain/ folder (Configuration/KeychainTool.xcconfig).
  3. rootshell-standalone depends on that tool and embeds it in
     Contents/Helpers. EXCLUDED_SOURCE_FILE_NAMES keeps it out of every
     configuration except the two Native ones, so the Standalone product is
     unchanged.
  4. The shared scheme rootshell-Native, derived from rootshell-Standalone.

Why a script rather than a committed diff: the pbxproj is regenerated in
large stretches by every upstream merge, so a literal patch half-applies.
This finds objects by stable identity (names), derives new object IDs
deterministically, and fails closed -- it raises instead of skipping when
the project does not have the shape it was written against. It is
idempotent: re-running on an already-converted project is a no-op.

Usage:
    python3 scripts/add-native-flavor.py [--check]

--check verifies and reports without writing.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "rootshell.xcodeproj" / "project.pbxproj"
SCHEMES = ROOT / "rootshell.xcodeproj" / "xcshareddata" / "xcschemes"

APP_TARGET = "rootshell-standalone"
TOOL = "rootshell-keychain"
FLAVORS = {"DebugStandalone": "DebugNative", "ReleaseStandalone": "ReleaseNative"}
REBASE = {
    "Debug-Standalone.xcconfig": "Debug-Native.xcconfig",
    "Release-Standalone.xcconfig": "Release-Native.xcconfig",
}
ALL_CONFIGS = [
    "Debug", "DebugStandalone", "DebugAppStore", "DebugChina", "DebugNative",
    "Release", "ReleaseStandalone", "ReleaseAppStore", "ReleaseChina", "ReleaseNative",
]


class SurgeryError(RuntimeError):
    pass


def oid(key: str) -> str:
    """Deterministic 24-hex-digit pbxproj object ID."""
    return hashlib.sha1(f"native-flavor:{key}".encode()).hexdigest()[:24].upper()


def stanza(text: str, object_id: str) -> re.Match[str]:
    match = re.search(
        r"\n(\t+)" + re.escape(object_id) + r"(?: /\*[^\n]*?\*/)? = \{\n.*?\n\1\};", text, re.S
    )
    if not match:
        raise SurgeryError(f"object {object_id} not found")
    return match


def insert_after(text: str, anchor: re.Match[str] | str, addition: str) -> str:
    if isinstance(anchor, str):
        index = text.find(anchor)
        if index < 0:
            raise SurgeryError(f"anchor not found: {anchor!r}")
        end = index + len(anchor)
    else:
        end = anchor.end()
    return text[:end] + addition + text[end:]


def append_to_list(text: str, object_id: str, list_name: str, entry: str) -> str:
    """Append `entry` to the `list_name = ( ... );` list inside one object."""
    block = stanza(text, object_id)
    body = block.group(0)
    match = re.search(r"\n(\t+)" + re.escape(list_name) + r" = \(\n(?:.*?\n)??\1\);", body, re.S)
    if not match:
        raise SurgeryError(f"list {list_name} not found in {object_id}")
    indent = match.group(1)
    closing = match.end() - len(f"{indent});")
    body = body[:closing] + f"{indent}\t{entry},\n" + body[closing:]
    return text[: block.start()] + body + text[block.end():]


def section_end(text: str, isa: str) -> str:
    marker = f"/* End {isa} section */"
    if marker not in text:
        raise SurgeryError(f"section {isa} not found")
    return marker


def add_to_section(text: str, isa: str, addition: str) -> str:
    marker = section_end(text, isa)
    index = text.index(marker)
    return text[:index] + addition.lstrip("\n") + "\n" + text[index:]


def find_id(text: str, pattern: str, what: str) -> str:
    matches = set(re.findall(pattern, text))
    if len(matches) != 1:
        raise SurgeryError(f"expected exactly one {what}, found {len(matches)}")
    return matches.pop()


# ---------------------------------------------------------------------------


def add_file_references(text: str) -> tuple[str, dict[str, str]]:
    group = find_id(text, r"\n\t\t(\w+) /\* Configuration \*/ = \{\n\t\t\tisa = PBXGroup;", "Configuration group")
    refs: dict[str, str] = {}
    for name in [*REBASE.values(), "KeychainTool.xcconfig"]:
        if not (ROOT / "Configuration" / name).is_file():
            raise SurgeryError(f"Configuration/{name} is missing")
        ref = oid(f"fileref:{name}")
        refs[name] = ref
        text = add_to_section(
            text,
            "PBXFileReference",
            f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; "
            f"path = {name}; sourceTree = \"<group>\"; }};",
        )
        text = append_to_list(text, group, "children", f"{ref} /* {name} */")
    return text, refs


def clone_configurations(text: str, refs: dict[str, str]) -> tuple[str, int, int]:
    lists = re.findall(
        r"\n\t\t(\w+) /\* Build configuration list for [^\n]*\*/ = \{\n\t\t\tisa = XCConfigurationList;", text
    )
    if not lists:
        raise SurgeryError("no XCConfigurationList objects found")
    cloned = rebased = 0
    for list_id in lists:
        body = stanza(text, list_id).group(0)
        for source_name, native_name in FLAVORS.items():
            found = re.findall(r"(\w+) /\* " + source_name + r" \*/,", body)
            if len(found) != 1:
                raise SurgeryError(f"configuration list {list_id} has {len(found)} {source_name} entries")
            source_id = found[0]
            native_id = oid(f"config:{source_id}")
            source = stanza(text, source_id)
            clone = source.group(0).replace(source_id, native_id, 1)
            clone = clone.replace(f"/* {source_name} */ = {{", f"/* {native_name} */ = {{", 1)
            clone, renamed = re.subn(r"(\n\t+name = )" + source_name + ";", r"\g<1>" + native_name + ";", clone)
            if renamed != 1:
                raise SurgeryError(f"configuration {source_id} has no name = {source_name}")
            for old, new in REBASE.items():
                pattern = r"baseConfigurationReference = \w+ /\* " + re.escape(old) + r" \*/;"
                clone, count = re.subn(pattern, f"baseConfigurationReference = {refs[new]} /* {new} */;", clone)
                rebased += count
            text = insert_after(text, source, clone)
            text = append_to_list(text, list_id, "buildConfigurations", f"{native_id} /* {native_name} */")
            cloned += 1
    return text, cloned, rebased


def exclude_tool_outside_native(text: str) -> tuple[str, int]:
    """Keep the embedded tool out of every non-Native app configuration."""
    target = find_id(
        text, r"\n\t\t(\w+) /\* " + APP_TARGET + r" \*/ = \{\n\t\t\tisa = PBXNativeTarget;", f"{APP_TARGET} target"
    )
    list_id = re.search(r"buildConfigurationList = (\w+)", stanza(text, target).group(0)).group(1)
    entries = re.findall(r"(\w+) /\* (\w+) \*/,", stanza(text, list_id).group(0))
    edited = 0
    for config_id, name in entries:
        if name in FLAVORS.values():
            continue
        block = stanza(text, config_id)
        body = block.group(0)
        if "EXCLUDED_SOURCE_FILE_NAMES" in body:
            raise SurgeryError(f"{APP_TARGET}/{name} already sets EXCLUDED_SOURCE_FILE_NAMES in the project file")
        setting = f'\t\t\t\tEXCLUDED_SOURCE_FILE_NAMES = "$(inherited) {TOOL}";\n'
        body, count = re.subn(r"(\n\t+buildSettings = \{\n)", lambda m: m.group(1) + setting, body, count=1)
        if count != 1:
            raise SurgeryError(f"{APP_TARGET}/{name} has no buildSettings")
        text = text[: block.start()] + body + text[block.end():]
        edited += 1
    return text, edited


def add_tool_target(text: str, refs: dict[str, str]) -> str:
    if not (ROOT / TOOL / "Sources" / "main.swift").is_file():
        raise SurgeryError(f"{TOOL}/Sources/main.swift is missing")

    project = find_id(text, r"\n\t\t(\w+) /\* Project object \*/ = \{", "project object")
    main_group = re.search(r"mainGroup = (\w+)", stanza(text, project).group(0)).group(1)
    products = find_id(text, r"\n\t\t(\w+) /\* Products \*/ = \{\n\t\t\tisa = PBXGroup;", "Products group")
    app = find_id(
        text, r"\n\t\t(\w+) /\* " + APP_TARGET + r" \*/ = \{\n\t\t\tisa = PBXNativeTarget;", f"{APP_TARGET} target"
    )

    ids = {key: oid(f"tool:{key}") for key in (
        "target", "group", "product", "sources", "frameworks", "configs", "proxy", "dependency", "buildfile", "embed",
    )}
    base = refs["KeychainTool.xcconfig"]

    config_ids = []
    configs = ""
    for name in ALL_CONFIGS:
        config_id = oid(f"tool:config:{name}")
        config_ids.append((config_id, name))
        configs += (
            f"\t\t{config_id} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbaseConfigurationReference = {base} /* KeychainTool.xcconfig */;\n"
            f"\t\t\tbuildSettings = {{\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n"
        )
    text = add_to_section(text, "XCBuildConfiguration", configs.rstrip("\n"))

    listing = "".join(f"\t\t\t\t{cid} /* {name} */,\n" for cid, name in config_ids)
    text = add_to_section(
        text,
        "XCConfigurationList",
        f"\t\t{ids['configs']} /* Build configuration list for PBXNativeTarget \"{TOOL}\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n{listing}\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};",
    )
    text = add_to_section(
        text,
        "PBXFileReference",
        f"\t\t{ids['product']} /* {TOOL} */ = {{isa = PBXFileReference; explicitFileType = "
        f"\"compiled.mach-o.executable\"; includeInIndex = 0; path = \"{TOOL}\"; "
        f"sourceTree = BUILT_PRODUCTS_DIR; }};",
    )
    text = append_to_list(text, products, "children", f"{ids['product']} /* {TOOL} */")
    text = add_to_section(
        text,
        "PBXFileSystemSynchronizedRootGroup",
        f"\t\t{ids['group']} /* {TOOL} */ = {{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
        f"\t\t\tpath = \"{TOOL}\";\n\t\t\tsourceTree = \"<group>\";\n\t\t}};",
    )
    text = append_to_list(text, main_group, "children", f"{ids['group']} /* {TOOL} */")
    text = add_to_section(
        text,
        "PBXSourcesBuildPhase",
        f"\t\t{ids['sources']} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
    )
    text = add_to_section(
        text,
        "PBXFrameworksBuildPhase",
        f"\t\t{ids['frameworks']} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
    )
    text = add_to_section(
        text,
        "PBXNativeTarget",
        f"\t\t{ids['target']} /* {TOOL} */ = {{\n\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {ids['configs']} /* Build configuration list for PBXNativeTarget \"{TOOL}\" */;\n"
        f"\t\t\tbuildPhases = (\n\t\t\t\t{ids['sources']} /* Sources */,\n\t\t\t\t{ids['frameworks']} /* Frameworks */,\n\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t{ids['group']} /* {TOOL} */,\n\t\t\t);\n"
        f"\t\t\tname = \"{TOOL}\";\n\t\t\tproductName = \"{TOOL}\";\n"
        f"\t\t\tproductReference = {ids['product']} /* {TOOL} */;\n"
        f"\t\t\tproductType = \"com.apple.product-type.tool\";\n\t\t}};",
    )
    text = append_to_list(text, project, "targets", f"{ids['target']} /* {TOOL} */")

    # App -> tool dependency, Catalyst only (mirrors the rootshell-helper wiring).
    text = add_to_section(
        text,
        "PBXContainerItemProxy",
        f"\t\t{ids['proxy']} /* PBXContainerItemProxy */ = {{\n\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = {project} /* Project object */;\n\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {ids['target']};\n\t\t\tremoteInfo = \"{TOOL}\";\n\t\t}};",
    )
    text = add_to_section(
        text,
        "PBXTargetDependency",
        f"\t\t{ids['dependency']} /* PBXTargetDependency */ = {{\n\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\tname = \"{TOOL}\";\n\t\t\tplatformFilter = maccatalyst;\n"
        f"\t\t\ttarget = {ids['target']} /* {TOOL} */;\n"
        f"\t\t\ttargetProxy = {ids['proxy']} /* PBXContainerItemProxy */;\n\t\t}};",
    )
    text = append_to_list(text, app, "dependencies", f"{ids['dependency']} /* PBXTargetDependency */")

    text = add_to_section(
        text,
        "PBXBuildFile",
        f"\t\t{ids['buildfile']} /* {TOOL} in Embed Keychain Tool */ = {{isa = PBXBuildFile; "
        f"fileRef = {ids['product']} /* {TOOL} */; platformFilter = maccatalyst; "
        f"settings = {{ATTRIBUTES = (CodeSignOnCopy, ); }}; }};",
    )
    text = add_to_section(
        text,
        "PBXCopyFilesBuildPhase",
        f"\t\t{ids['embed']} /* Embed Keychain Tool */ = {{\n\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n\t\t\tdstPath = Contents/Helpers;\n\t\t\tdstSubfolderSpec = 1;\n"
        f"\t\t\tfiles = (\n\t\t\t\t{ids['buildfile']} /* {TOOL} in Embed Keychain Tool */,\n\t\t\t);\n"
        f"\t\t\tname = \"Embed Keychain Tool\";\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};",
    )
    text = append_to_list(text, app, "buildPhases", f"{ids['embed']} /* Embed Keychain Tool */")
    return text


def write_scheme(check: bool) -> bool:
    source = SCHEMES / "rootshell-Standalone.xcscheme"
    target = SCHEMES / "rootshell-Native.xcscheme"
    if not source.is_file():
        raise SurgeryError(f"{source.name} is missing")
    text = source.read_text()
    for old, new in FLAVORS.items():
        if f'"{old}"' not in text:
            raise SurgeryError(f"{source.name} does not reference {old}")
        text = text.replace(f'"{old}"', f'"{new}"')
    if target.is_file() and target.read_text() == text:
        return False
    if not check:
        target.write_text(text)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true", help="verify without writing")
    args = parser.parse_args()

    text = PBXPROJ.read_text()
    try:
        if f'remoteInfo = "{TOOL}"' in text or "/* ReleaseNative */" in text:
            if f'remoteInfo = "{TOOL}"' not in text or "/* ReleaseNative */" not in text:
                raise SurgeryError("project is partially converted; restore project.pbxproj and re-run")
            print("project.pbxproj: NATIVE flavor already present")
        else:
            text, refs = add_file_references(text)
            # Clone first: the Native clones must not inherit the exclusion.
            text, cloned, rebased = clone_configurations(text, refs)
            if rebased == 0:
                raise SurgeryError("no configuration was based on a *-Standalone.xcconfig")
            text, excluded = exclude_tool_outside_native(text)
            text = add_tool_target(text, refs)
            print(
                f"project.pbxproj: cloned {cloned} configurations ({rebased} rebased onto Native xcconfigs), "
                f"added {TOOL}, excluded it from {excluded} non-Native {APP_TARGET} configurations"
            )
            if not args.check:
                PBXPROJ.write_text(text)
        changed = write_scheme(args.check)
        print(f"rootshell-Native.xcscheme: {'written' if changed else 'up to date'}")
    except SurgeryError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
