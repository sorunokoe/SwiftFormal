#!/usr/bin/env python3
"""Size of the code a user has to trust (PC-6, Task Q.6 Step 2).

    python3 Scripts/measure-trust.py          # table of code lines (non-blank, non-comment) per trusted piece
    python3 Scripts/measure-trust.py --check  # also fail if one grew more than 10% over Scripts/baseline/quality.json

The trusted pieces are listed in Scripts/quality_metrics.py (TRUSTED) and explained in docs/TRUST.md.
`Scripts/check-ratchet.py` runs the same check as part of the ratchets.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import quality_metrics as qm  # noqa: E402


def main() -> int:
    quality = qm.load()
    print(f'{"trusted piece":20} {"code lines":>10} {"recorded":>9}  path')
    for name, lines in qm.trusted_lines().items():
        print(f'{name:20} {lines:10d} {quality["trusted_lines"].get(name, "-")!s:>9}  {qm.TRUSTED[name]}')
    if "--check" in sys.argv[1:]:
        bad = qm.trust_violations(quality)
        if bad:
            print("\n".join(bad))
            return 1
        print("trusted code within its limit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
