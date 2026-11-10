#!/usr/bin/env python3
"""The summary pin (plan item R6): the standard-library code behind Scan's summaries cannot change unnoticed.

    python3 Scripts/check-summary-pin.py            compare with Scripts/baseline/stdlib-summaries.json
    python3 Scripts/check-summary-pin.py --update   rewrite it (review the diff and the dumped bodies, then commit)

Scan does not read the bodies of the standard-library functions in `StdlibSummary.table`
(Sources/SFSIL/SILSummaries.swift): it trusts a hand-written summary of each. This script pins what was reviewed.
It compiles tools/summary-probe/probe.swift, which calls every summarized function, with
`-O -Xllvm -sil-print-after=performance-linker`; the first printed module holds every serialized standard-library
body the probe reaches, before inlining. For each summarized symbol it hashes the normalized body and the closure of
bodies it reaches through `function_ref`; a symbol with no serialized body (`String.count`, `lowercased()`, ...) is
pinned by its printed declaration only. Normalizing drops comments, the UUIDs of opened existentials (fresh in every
compile), the `Swift/<triple>.swiftinterface` file name and
the source line number passed to a failure message (`integer_literal` feeding `struct $UInt`), so that only a change
of code or of a message or condition counts.

The pin is keyed to the compiler (`swiftc --version`), the SDK and the target. With a compiler outside
`SILFrontendVersion.verifiedCompilers` the check is skipped with a warning (CI runners); with a pinned compiler whose
line is not the baseline's, or another SDK, it fails until `--update` is run and reviewed. The Composable
Architecture rows are not standard library and are not pinned. `--update` writes the normalized bodies that changed
to .build/summary-pin/ for review.
"""
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE = ROOT / "Scripts/baseline/stdlib-summaries.json"
PROBE = ROOT / "tools/summary-probe/probe.swift"
# The files that add rows to `StdlibSummary.table`.
TABLES = [ROOT / "Sources/SFSIL" / name for name in ("SILSummaries.swift", "SILDictionaryTable.swift", "SILRanges.swift", "SILStrings.swift", "SILFloatSummaries.swift", "SILForeign.swift")]
PIN = ROOT / "Sources/SFSIL/ProofCacheVersions.swift"
DUMP = ROOT / ".build/summary-pin"
TAG = "swift-6.4.0-RELEASE"


def run(arguments):
    return subprocess.run(arguments, capture_output=True, text=True, check=True)


def compiler_line():
    text = run(["xcrun", "swiftc", "--version"]).stdout + run(["xcrun", "swiftc", "--version"]).stderr
    first = text.strip().splitlines()[0]
    return first[first.index("Apple Swift") :] if "Apple Swift" in first else first


def verified_compilers():
    return re.findall(r'"(Apple Swift version [^"]+)"', PIN.read_text())


def toolchain():
    return {
        "compiler": compiler_line(),
        "sdk": run(["xcrun", "--show-sdk-version"]).stdout.strip() + " (" + run(["xcrun", "--show-sdk-build-version"]).stdout.strip() + ")",
        "target": json.loads(run(["xcrun", "swiftc", "-print-target-info"]).stdout)["target"]["triple"],
    }


def table():
    """{symbol: name} of the standard-library rows of StdlibSummary.table."""
    text = "\n".join(path.read_text() for path in TABLES)
    rows = re.findall(r'(?:add|array|collection)\(\s*"(\$s[^"]+)",\s*"([^"]+)"', text)
    return {symbol: name for symbol, name in rows}


def linked_module():
    """The SIL printed after the first performance-linker pass."""
    result = subprocess.run(
        ["xcrun", "swiftc", "-emit-sil", "-O", "-parse-as-library", "-module-name", "Probe", str(PROBE),
         "-Xllvm", "-sil-print-after=performance-linker", "-Xllvm", "-sil-print-no-color", "-o", os.devnull],
        capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("check-summary-pin: the probe did not compile:\n" + result.stderr[-2000:])
    banners = [i for i, line in enumerate(result.stderr.split("\n")) if "*** SIL module after" in line]
    if not banners:
        sys.exit("check-summary-pin: the compiler printed no module after performance-linker")
    lines = result.stderr.split("\n")
    end = banners[1] if len(banners) > 1 else len(lines)
    return lines[banners[0] + 1 : end]


def unoptimized_module():
    """The probe's SIL at -Onone: it still prints `[transparent]` functions, which mandatory inlining removes at -O."""
    result = subprocess.run(
        ["xcrun", "swiftc", "-emit-sil", "-Onone", "-parse-as-library", "-module-name", "Probe", str(PROBE)],
        capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit("check-summary-pin: the probe did not compile at -Onone:\n" + result.stderr[-2000:])
    return result.stdout.split("\n")


def split(lines):
    """({symbol: body lines}, {symbol: declaration line})."""
    bodies, declarations = {}, {}
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("sil ") and " @" in line:
            symbol = line.split(" @", 1)[1].split(" : ", 1)[0]
            if line.endswith("{"):
                j = i
                while j < len(lines) and not lines[j].startswith("}"):
                    j += 1
                bodies[symbol] = lines[i : j + 1]
                i = j + 1
                continue
            declarations[symbol] = line
        i += 1
    return bodies, declarations


def strip_comment(line):
    """`line` without a trailing `// ...` that is outside every string literal."""
    quote = line.rfind('"')
    cut = line.find("//", quote + 1 if quote >= 0 else 0)
    return (line[:cut] if cut >= 0 else line).rstrip()


def normalize(lines):
    out = [strip_comment(l) for l in lines]
    out = [re.sub(r'"Swift/[^"]*\.swiftinterface"', '"Swift/<interface>"', l) for l in out if l.strip()]
    text = "\n".join(out)
    # An opened existential gets a fresh UUID in every compile: number them in order of appearance.
    opened = list(dict.fromkeys(re.findall(r'@opened\("([0-9A-F-]{36})"', text)))
    for n, uuid in enumerate(opened):
        text = text.replace(uuid, f"<opened-{n}>")
    if "<interface>" in text:
        # The line number of a failure message: an integer literal whose only use here is `struct $UInt (%n)`.
        for value in set(re.findall(r"struct \$UInt \((%\d+)\)", text)):
            text = re.sub(rf"^(\s*{re.escape(value)} = integer_literal \$Builtin\.(?:Int64|Word), )-?\d+$", r"\1<line>", text, flags=re.M)
    return text + "\n"


def sha(text):
    return "sha256:" + hashlib.sha256(text.encode()).hexdigest()


def references(body):
    return re.findall(r"function_ref @(\S+) :", "\n".join(body))


def measure():
    bodies, declarations = split(linked_module())
    # A `[transparent]` function is always inlined, so -O never links it: take its -Onone body instead.
    unoptimized, _ = split(unoptimized_module())
    for symbol, body in unoptimized.items():
        if symbol not in bodies and "[transparent]" in body[0]:
            bodies[symbol] = body
    normalized = {symbol: normalize(body) for symbol, body in bodies.items()}
    entries, texts = {}, {}
    for symbol, name in sorted(table().items()):
        if symbol in bodies:
            closure, todo = [], [symbol]
            while todo:
                s = todo.pop()
                if s in closure or s not in bodies:
                    continue
                closure.append(s)
                todo += references(bodies[s])
            joined = "".join(f"{s}\n{normalized[s]}" for s in sorted(closure))
            entries[symbol] = {"name": name, "kind": "body", "body": sha(normalized[symbol]), "closure": sha(joined), "closureSize": len(closure)}
            texts[symbol] = normalized[symbol]
        elif symbol in declarations:
            text = normalize([declarations[symbol]])
            entries[symbol] = {"name": name, "kind": "declaration", "declaration": sha(text)}
            texts[symbol] = text
        else:
            entries[symbol] = {"name": name, "kind": "missing"}
    return entries, texts


def self_test():
    """Offline: a moved line keeps the hash; a changed condition or message does not."""
    body = [
        "sil @f : $@convention(thin) (Int) -> () {",
        "bb0(%0 : $Int):",
        '  %1 = string_literal utf8 "Swift/arm64e-apple-macos.swiftinterface" // user: %2',
        "  %2 = integer_literal $Builtin.Int64, 1089      // user: %3",
        "  %3 = struct $UInt (%2)",
        "  %4 = integer_literal $Builtin.Int64, 7",
        '  %5 = string_literal utf8 "Index out of range"',
        "}",
    ]
    moved = [l.replace("1089", "1201").replace("arm64e-apple-macos", "x86_64-apple-macos") for l in body]
    condition = [l.replace("Int64, 7", "Int64, 8") for l in body]
    message = [l.replace("out of range", "out of bounds") for l in body]
    base = sha(normalize(body))
    assert sha(normalize(moved)) == base, "a moved line changed the hash"
    assert sha(normalize(condition)) != base, "a changed literal kept the hash"
    assert sha(normalize(message)) != base, "a changed message kept the hash"
    opened = [body[0], '  %6 = open_existential_metatype %5 to $@thick (@opened("D4BF8DC6-DAA8-11F1-BFAD-4F5164DBCA84", AnyObject) Self).Type']
    reopened = [opened[0], opened[1].replace("D4BF8DC6-DAA8-11F1-BFAD-4F5164DBCA84", "D51594BE-DAA8-11F1-A9C9-89B6247D093E")]
    assert sha(normalize(opened)) == sha(normalize(reopened)), "an opened existential's UUID changed the hash"
    assert strip_comment('  %1 = string_literal utf8 "a // b" // user: %2') == '  %1 = string_literal utf8 "a // b"'


def main():
    self_test()
    update = "--update" in sys.argv
    found = toolchain()
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else None
    if not update and found["compiler"] not in verified_compilers():
        message = f"summary pin skipped: '{found['compiler']}' is not a pinned compiler (docs/guides/compilers.md)"
        print(f"::warning::{message}" if os.environ.get("GITHUB_ACTIONS") else message)
        return 0
    entries, texts = measure()
    missing = sorted(s for s, e in entries.items() if e["kind"] == "missing")
    if missing:
        print("tools/summary-probe/probe.swift does not reach these summarized functions; add a call to each:")
        for symbol in missing:
            print(f"  {entries[symbol]['name']}  {symbol}")
        return 1
    measured = {**found, "tag": TAG, "probe": str(PROBE.relative_to(ROOT)), "entries": entries}
    if update:
        changed = [s for s in entries if not baseline or baseline["entries"].get(s) != entries[s]]
        DUMP.mkdir(parents=True, exist_ok=True)
        for symbol in changed:
            (DUMP / (re.sub(r"[^A-Za-z0-9_]", "_", symbol) + ".sil")).write_text(texts[symbol])
        BASELINE.write_text(json.dumps(measured, indent=1, sort_keys=True) + "\n")
        print(f"recorded {BASELINE.relative_to(ROOT)}: {len(entries)} entries, {len(changed)} new or changed")
        if changed:
            print(f"review the normalized code of each in {DUMP.relative_to(ROOT)}/ against its summary:")
            for symbol in changed:
                print(f"  {entries[symbol]['name']}  {symbol}")
        return 0
    if baseline is None:
        print(f"no {BASELINE.relative_to(ROOT)}: run with --update")
        return 1
    problems = [f"{key}: baseline '{baseline.get(key)}', here '{found[key]}'" for key in ("compiler", "sdk", "target") if baseline.get(key) != found[key]]
    for symbol in sorted(set(entries) | set(baseline["entries"])):
        old, new = baseline["entries"].get(symbol), entries.get(symbol)
        if old != new:
            name = (new or old)["name"]
            problems.append(f"{name} ({symbol}): " + ("not pinned" if old is None else "no longer summarized" if new is None else "its code changed"))
    if problems:
        print("summary pin: the standard library behind Scan's summaries is not the reviewed one:")
        for problem in problems:
            print(f"  {problem}")
        print("Review each summary against the new code (python3 Scripts/check-summary-pin.py --update dumps it), then commit the baseline.")
        return 1
    bodies = sum(1 for e in entries.values() if e["kind"] == "body")
    print(f"summary pin ok: {len(entries)} summarized functions ({bodies} bodies, {len(entries) - bodies} declarations)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
