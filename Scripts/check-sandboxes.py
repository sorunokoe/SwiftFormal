#!/usr/bin/env python3
"""Fails if the sandbox cards and the registry (Scripts/sandboxes.py) disagree.

Checks: every registry entry has a card in docs/sandboxes/ and is listed in the README table;
every card has the seven headings; the card's "Depends on" and "Platforms" match the registry;
no card exists for a name that is not in the registry.
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sandboxes import GATED, SANDBOXES  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CARDS = ROOT / "docs" / "sandboxes"
HEADINGS = [
    "**Job (Inspector view):**",
    "**Raw input → typed → result:**",
    "**Depends on:**",
    "**Fast loop:**",
    "**Real consumers:**",
    "**Platforms (verified):**",
    "**Known gaps:**",
]

bad = []


def line_after(text, label):
    m = re.search(re.escape(label) + r"(.*)", text)
    return m.group(1).strip() if m else ""


for name, entry in SANDBOXES.items():
    card = CARDS / f"{name}.md"
    if not card.exists():
        bad.append(f"{name}: no card at docs/sandboxes/{name}.md")
        continue
    text = card.read_text()
    for h in HEADINGS:
        if h not in text:
            bad.append(f"{name}: card is missing the heading {h}")
    if not text.startswith(f"# {name}:"):
        bad.append(f"{name}: the card title must start with '# {name}:'")

    depends = line_after(text, "**Depends on:**").split("**Must not depend on:**")[0]
    listed = {n for n in SANDBOXES if re.search(rf"(?<![\w`]){re.escape(n)}(?![\w])", depends)}
    if listed != set(entry.deps):
        bad.append(f"{name}: card says it depends on {sorted(listed)}, the registry says {sorted(entry.deps)}")

    platforms = re.split(r"[(]|\.(?:\s|$)", line_after(text, "**Platforms (verified):**"))[0]
    claimed = {p for p in ("macOS", "iOS") if p in platforms}
    if claimed != set(entry.platforms):
        bad.append(f"{name}: card says platforms {sorted(claimed)}, the registry says {sorted(entry.platforms)}")

    if f"Scripts/sandbox.py {name}" not in line_after(text, "**Fast loop:**"):
        bad.append(f"{name}: the fast loop must show `Scripts/sandbox.py {name}`")

readme = CARDS / "README.md"
readme_text = readme.read_text() if readme.exists() else ""
if not readme.exists():
    bad.append("docs/sandboxes/README.md is missing")
for name in SANDBOXES:
    if f"]({name}.md)" not in readme_text:
        bad.append(f"README.md does not list {name}")

for card in sorted(CARDS.glob("*.md")):
    if card.stem != "README" and card.stem not in SANDBOXES and card.stem not in GATED:
        bad.append(f"{card.name}: card for a name that is not in Scripts/sandboxes.py")

if bad:
    print("\n".join(bad))
    sys.exit(1)
print("sandboxes ok")
