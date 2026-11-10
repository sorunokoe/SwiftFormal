#!/usr/bin/env bash
# Runs sfverify on the gated example and compares verdicts to the frozen baseline (timings removed). The proof cache
# stays on and its counts are removed: a warm run (answers from the cache) must give the same verdicts as a cold one.
set -euo pipefail
cd "$(dirname "$0")/.."
# Same flags as the release test lanes (test-lane.sh), so alternating between them does not rebuild everything.
swift build -c release -Xswiftc -enable-testing --product sfverify >/dev/null
out=$(.build/release/sfverify --package "$PWD/Examples/GatedPackage" --target Kernels --build --json \
  | SF_ROOT="$PWD" python3 -c 'import json,os,sys
text=sys.stdin.read()
# The same folder can be spelled several ways (/tmp is /private/tmp on macOS); replace the longest spelling first.
root=os.environ["SF_ROOT"]
for spelling in sorted({root,os.path.realpath(root),root.removeprefix("/private"),os.path.realpath(root).removeprefix("/private")},key=len,reverse=True):
    text=text.replace(spelling,"<ROOT>")
d=json.loads(text)
def strip(x):
    if isinstance(x,dict): return {k:strip(v) for k,v in x.items() if k not in ("seconds","compileSeconds","parseSeconds","verifySeconds","silBytes","schemaVersion","compiler","pinned","proofCache","fromCache")}
    if isinstance(x,list): return [strip(v) for v in x]
    return x
print(json.dumps(strip(d),indent=1,sort_keys=True))')
if [ "${1:-}" = "--record" ]; then printf '%s\n' "$out" > Scripts/baseline/golden-sfverify.json; echo recorded; exit 0; fi
diff <(printf '%s\n' "$out") Scripts/baseline/golden-sfverify.json && echo "golden verdicts unchanged"
