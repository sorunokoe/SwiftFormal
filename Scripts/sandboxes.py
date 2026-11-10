#!/usr/bin/env python3
"""Single source of truth for sandboxes: layering, fast loop, connected loop, platforms.

A sandbox is one target that builds, tests and runs on its own. `deps` are the compile
dependencies it is ALLOWED to have (Scripts/check-layering.py compares them with Package.swift).
`consumers` are commands that exercise real code that uses the sandbox. Every command listed
here must exist today; do not add a command for something that has not been written yet.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass

GOLDEN = "Scripts/check-golden.sh"  # sfverify --json on Examples/GatedPackage, timing stripped
# The gate on a real package: every `@Verify` function of Kernels proved (`swiftformal check --gate`).
GATE = "swift run -c release swiftformal check --gate --package Examples/GatedPackage --target Kernels --force"
# `sfgen` is a maintainer tool now (no product) and needs symbol graphs to do anything useful, so we only build it.
SFGEN = "swift build --product sfgen"


def swift_test(target: str, release: bool = False) -> str:
    # Release test builds need -enable-testing or the `@testable import` in the other test targets fails to build.
    # A fast target's `*SlowTests` suites are the slow lane's: the sandbox loop skips them (Scripts/test-lane.sh slow runs them).
    skip = " --skip SlowTests" if not release and target not in SLOW_TESTS else ""
    return f"swift test{' -c release -Xswiftc -enable-testing' if release else ''} --filter {target}{skip}"


# Test targets that take minutes in debug (see Scripts/safety-net.sh and Scripts/baseline/timings.md).
SLOW_TESTS = frozenset({"SFBVTests", "SFSILTests", "SFProveTests", "SFSATTests", "SFOracleTests"})

# Library layers that are not allowed to know about each other.
CNF_MAX_LINES = 150  # SFCNF is the shared alphabet; past this size it is becoming a dumping ground


@dataclass(frozen=True)
class Sandbox:
    deps: frozenset[str]  # allowed compile dependencies (target names)
    tests: str | None  # fast-loop test target, None if covered elsewhere
    consumers: tuple[str, ...] = ()  # commands that exercise the real consumers (connected loop)
    platforms: tuple[str, ...] = ("macOS",)  # only list what was actually built (see docs/guides/platforms.md)
    kind: str = "library"  # library | tool | plugin | macro
    ios_scheme: str | None = None  # xcodebuild scheme, when SwiftPM generates one for this target
    core: tuple[str, ...] | None = None  # replaces the default fast loop (used by the plugin)
    more_tests: tuple[str, ...] = ()  # cross-cutting test targets that also exercise this sandbox (SelfVerificationTests, SoundnessZooTests)


def S(*names: str) -> frozenset[str]:
    return frozenset(names)


SANDBOXES: dict[str, Sandbox] = {
    "SwiftFormal": Sandbox(
        S("SwiftFormalMacros"), "SwiftFormalTests",
        (swift_test("SwiftFormalTestingTests"),),
        ("macOS", "iOS"), ios_scheme="SwiftFormal",
        more_tests=("SelfVerificationTests", "SoundnessZooTests", "SwiftFormalAppImportTests")),
    "SwiftFormalTesting": Sandbox(
        # Re-exports SFProve (the owner's decision: one test product); the other engines stay out of it.
        S("SwiftFormal", "SFProve"), "SwiftFormalTestingTests", (),  # consumer is Examples/Walk, a separate package run by Scripts/check-examples.sh (CI only)
        ("macOS", "iOS"), ios_scheme="SwiftFormalTesting"),
    "SwiftFormalMacros": Sandbox(
        S(), "SwiftFormalMacrosTests", (swift_test("SwiftFormalTests"),),
        ("macOS",), "macro"),  # runs inside the compiler on the Mac, never on a phone
    "SFCNF": Sandbox(
        S(), None, (swift_test("SFSATTests"), swift_test("SFProveTests"), GOLDEN),
        ("macOS", "iOS"), more_tests=("SelfVerificationTests", "SoundnessZooTests")),
    # Checked in Phase 3B: weakening one SFSAT function body (clause minimisation) made GOLDEN and the gate fail.
    "SFSAT": Sandbox(
        S("SFCNF"), "SFSATTests", (swift_test("SFProveTests"), GOLDEN),
        ("macOS", "iOS"), more_tests=("SelfVerificationTests", "SoundnessZooTests")),
    # Independence rule: the checker must never depend on the solver (SFSAT) or the encoder (SFBV).
    "SFCheck": Sandbox(
        S("SFCNF"), "SFSATTests", (swift_test("SFProveTests"), GOLDEN),
        ("macOS", "iOS"), more_tests=("SoundnessZooTests",)),
    "SFBV": Sandbox(
        S("SFCNF"), "SFBVTests", (swift_test("SFProveTests"), swift_test("SFSemanticsTests"), GOLDEN),
        ("macOS", "iOS"), more_tests=("SelfVerificationTests",)),
    "SFProve": Sandbox(
        S("SFCNF", "SFSAT", "SFCheck", "SFBV"), "SFProveTests", (swift_test("SFSILTests"), GOLDEN),
        ("macOS", "iOS"), more_tests=("SelfVerificationTests", "SoundnessZooTests")),
    "SFSemantics": Sandbox(
        S("SFCNF", "SFBV"), "SFSemanticsTests", (swift_test("SFSILTests"), GOLDEN),
        ("macOS", "iOS")),  # SwiftPM makes no scheme for it: checked with `swift build --triple`
    "SFSIL": Sandbox(
        S("SFCNF", "SFBV", "SFSemantics", "SFProve"), "SFSILTests",
        (swift_test("SFVerifyKitTests"), GOLDEN, GATE), more_tests=("SoundnessZooTests",)),  # uses `Process`, so no iOS
    # SFVerifyKit uses SFLLVM only for the opt-in `--cross-check llvm` (plan item V4, ADR 0008).
    "SFLLVM": Sandbox(
        S("SFCNF", "SFBV", "SFProve", "SFSIL"), "SFOracleTests", (swift_test("SFOracleTests", release=True),),
        more_tests=("SoundnessZooTests",)),
    "SFVerifyKit": Sandbox(
        S("SFCNF", "SFBV", "SFProve", "SFSemantics", "SFSIL", "SFLLVM"), "SFVerifyKitTests", (GOLDEN, GATE)),
    # `sfverify`: the maintainers' scan tool (no product); the golden scan, metrics, corpus and mutation lanes run it.
    "sfverify": Sandbox(
        S("SFVerifyKit"), None, (GOLDEN,), kind="tool"),
    # `swiftformal`: the one front door (`check`, `doctor`, `lsp`). Its logic lives in SFVerifyKit (`CheckTests`).
    "SwiftFormalCLI": Sandbox(
        S("SFVerifyKit", "SFLanguageServer"), None, ("swift build --product swiftformal", GATE), kind="tool"),
    # `swiftformal lsp`: runs each check as a child `swiftformal check --json` (docs/guides/editor.md). Its end-to-end
    # test (`LanguageServerSlowTests`) drives the built server over pipes; it runs in the slow lane.
    "SFLanguageServer": Sandbox(
        S("SFVerifyKit"), "SFLanguageServerTests", ("swift build --product swiftformal",)),
    "SFGenKit": Sandbox(
        S(), "SFGenKitTests", (SFGEN,)),
    "sfgen": Sandbox(
        S("SFGenKit"), None, (SFGEN,), kind="tool"),
    # Test tags only (`.slow`, `.oracle`); imported by test targets, never by production code.
    "SFTestSupport": Sandbox(S(), None, ()),
}


# Targets that exist only when an environment variable is set in Package.swift (developer-only, never fetched by users).
# They join the registry only under that variable, so every check sees the same target list as `swift package describe`.
GATED: dict[str, tuple[str, Sandbox]] = {
    "SwiftFormalScaling": ("SWIFTFORMAL_BENCH", Sandbox(
        S("SwiftFormal", "SwiftFormalTesting", "SFCNF", "SFSAT", "SFCheck", "SFBV", "SFProve", "SFSIL", "SFVerifyKit"),
        None, (), kind="tool")),
}
for _name, (_variable, _entry) in GATED.items():
    if os.environ.get(_variable):
        SANDBOXES[_name] = _entry

def tests_owner() -> dict[str, list[str]]:
    """Test target -> sandboxes whose fast loop it is."""
    owners: dict[str, list[str]] = {}
    for name, s in SANDBOXES.items():
        for target in ([s.tests] if s.tests else []) + list(s.more_tests):
            owners.setdefault(target, []).append(name)
    return owners


def reverse_closure(changed: set[str]) -> set[str]:
    """Everything that (transitively) depends on a changed sandbox: the CONSUMER graph, not just the build list."""
    out, grew = set(changed), True
    while grew:
        grew = False
        for name, s in SANDBOXES.items():
            if name not in out and s.deps & out:
                out.add(name)
                grew = True
    return out


def core_commands(name: str) -> list[str]:
    s = SANDBOXES[name]
    if s.core is not None:
        return list(s.core)
    cmds = [f"swift build --product {name}" if s.kind == "tool" else f"swift build --target {name}"]
    if s.tests:
        cmds += [f"swift build --target {s.tests}", swift_test(s.tests)]
    for target in s.more_tests:
        cmds += [f"swift build --target {target}", swift_test(target)]
    return cmds


def is_slow(command: str) -> bool:
    m = re.search(r"--filter (\w+)", command)
    return bool(m and m.group(1) in SLOW_TESTS)


def ios_command(name: str) -> str | None:
    """The command that proves the iOS claim for a sandbox, or None if it does not claim iOS."""
    s = SANDBOXES[name]
    if "iOS" not in s.platforms:
        return None
    if s.ios_scheme:
        return f"xcodebuild -scheme {s.ios_scheme} -destination 'generic/platform=iOS Simulator' build"
    return ("swift build --target " + name + " --triple arm64-apple-ios16.0-simulator "
            "--sdk \"$(xcrun --sdk iphonesimulator --show-sdk-path)\" --scratch-path .build/ios-spm")
