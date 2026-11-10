#!/usr/bin/env python3
"""One-command sandbox loops.

  Scripts/sandbox.py SFSAT                 fast loop: build the target, build its tests, run its tests
  Scripts/sandbox.py SFSAT --connect       fast loop, then the commands that exercise the real consumers
  Scripts/sandbox.py --affected <git-ref>  sandboxes touched since <ref>, plus everything that depends on them

Options:
  --dry-run     print the commands without running them
  --skip-slow   do not run commands that use a slow test target (Scripts/sandboxes.py: SLOW_TESTS)
  --run         with --affected: run the commands (the default is to only print them)

Every command is printed before it runs. The last line says what was and was not checked,
so a green package is never reported as a green product.
"""
import argparse
import pathlib
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sandboxes import SANDBOXES, core_commands, ios_command, is_slow, reverse_closure, tests_owner  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent


def sandboxes_for_files(files):
    """Map changed paths to sandboxes. Returns (sandboxes, notes)."""
    owners = tests_owner()
    found, notes = set(), []
    for f in files:
        parts = f.split("/")
        if f == "Package.swift" or f.startswith("Scripts/sandboxes"):
            notes.append(f"{f} changed: treating every sandbox as changed")
            found |= set(SANDBOXES)
        elif len(parts) > 1 and parts[0] in ("Sources", "Plugins") and parts[1] in SANDBOXES:
            found.add(parts[1])
        elif len(parts) > 1 and parts[0] == "Tests" and parts[1] in owners:
            found |= set(owners[parts[1]])
    return found, notes


def run(commands, dry_run, skip_slow):
    """Runs commands in order. Returns (passed, failed, skipped)."""
    passed, failed, skipped = 0, [], []
    for cmd in commands:
        if skip_slow and is_slow(cmd):
            print(f"$ {cmd}\n  (skipped: slow test target)", flush=True)
            skipped.append(cmd)
            continue
        print(f"$ {cmd}", flush=True)
        if dry_run:
            continue
        if subprocess.run(cmd, shell=True, cwd=ROOT).returncode == 0:
            passed += 1
        else:
            failed.append(cmd)
    return passed, failed, skipped


def dedupe(items):
    return list(dict.fromkeys(items))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sandbox", nargs="?", help="a name from Scripts/sandboxes.py")
    ap.add_argument("--connect", action="store_true", help="also run the real-consumer commands")
    ap.add_argument("--affected", metavar="REF", help="work out the sandboxes from `git diff --name-only REF`")
    ap.add_argument("--run", action="store_true", help="with --affected: run instead of only printing")
    ap.add_argument("--dry-run", action="store_true", help="print commands, run nothing")
    ap.add_argument("--skip-slow", action="store_true", help="skip commands that use a slow test target")
    args = ap.parse_args()

    if bool(args.sandbox) == bool(args.affected):
        ap.error("give either a sandbox name or --affected <git-ref>")

    if args.affected:
        files = subprocess.check_output(["git", "diff", "--name-only", args.affected], cwd=ROOT, text=True).split()
        files += subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=ROOT, text=True).split()
        changed, notes = sandboxes_for_files(files)
        for n in notes:
            print(f"note: {n}")
        affected = reverse_closure(changed)
        names = [n for n in SANDBOXES if n in affected]
        print(f"changed: {sorted(changed) or 'none'}")
        print(f"affected (changed + everything that depends on it): {names or 'none'}")
        core = dedupe(c for n in names for c in core_commands(n))
        consumers = dedupe(c for n in names for c in SANDBOXES[n].consumers)
        dry = args.dry_run or not args.run
        if not args.run:
            print("(printing only; add --run to run)")
    else:
        if args.sandbox not in SANDBOXES:
            ap.error(f"unknown sandbox {args.sandbox!r}; known: {', '.join(SANDBOXES)}")
        names = [args.sandbox]
        core = core_commands(args.sandbox)
        consumers = list(SANDBOXES[args.sandbox].consumers) if args.connect else []
        dry = args.dry_run

    # A command that is already part of the fast loop does not run twice.
    consumers = [c for c in consumers if c not in core]

    print("== fast loop")
    c_pass, c_fail, c_skip = run(core, dry, args.skip_slow)
    if c_fail:
        print(f"Core: {c_pass} passed, FAILED: {c_fail[0]}; consumers: not run")
        sys.exit(1)
    if consumers:
        print("== connected loop (real consumers)")
    k_pass, k_fail, k_skip = run(consumers, dry, args.skip_slow)

    not_run = []
    if not args.connect and not args.affected:
        not_run.append("consumers (add --connect)")
    not_run += [f"slow: {c}" for c in c_skip + k_skip]
    ios = dedupe(c for c in (ios_command(n) for n in names) if c)
    if ios:
        not_run.append("iOS builds (this script never runs them; see docs/guides/platforms.md)")
    else:
        not_run.append("iOS (these sandboxes are macOS-only)")
    if dry:
        print(f"DRY RUN: nothing was run. Would run {len(core)} core and {len(consumers)} consumer commands.")
        print(f"Not covered by this loop: {', '.join(not_run)}")
        return
    status = f"Core: {c_pass} passed; consumers: {k_pass} passed"
    if k_fail:
        status += f", {len(k_fail)} FAILED ({'; '.join(k_fail)})"
    print(f"{status}; not run: {', '.join(not_run)}")
    sys.exit(1 if k_fail else 0)


if __name__ == "__main__":
    main()
