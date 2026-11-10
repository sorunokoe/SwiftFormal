import subprocess, sys, time, os, signal
signal.signal(signal.SIGTERM, lambda *a: (_ for _ in ()).throw(KeyboardInterrupt()))
signal.signal(signal.SIGHUP, signal.SIG_IGN)
sys.path.insert(0, os.path.dirname(__file__))
from mutants import MUTANTS
REPO = sys.argv[1]; FILTER = sys.argv[2]; ids = set(sys.argv[3:])
for mid, f, old, new, desc in MUTANTS:
    if ids and mid not in ids: continue
    p = os.path.join(REPO, f); src = open(p).read()
    assert src.count(old) == 1, (mid, src.count(old))
    open(p, 'w').write(src.replace(old, new))
    t = time.time()
    try:
        b = subprocess.run(['swift', 'build', '--build-tests'], cwd=REPO, capture_output=True, text=True)
        if b.returncode != 0:
            print(mid, 'STILLBORN', desc, b.stdout[-300:], flush=True); continue
        r = subprocess.run(['perl', '-e', 'alarm 1500; exec @ARGV', 'swift', 'test', '--skip-build', '--filter', FILTER] + (['--skip', os.environ['SKIP']] if os.environ.get('SKIP') else []), cwd=REPO, capture_output=True, text=True)
        out = r.stdout + r.stderr
        open(os.path.join(os.path.dirname(__file__), mid + '.log'), 'w').write(out)
        failed = sorted({l.split('"')[1] if '"' in l else l[:80] for l in out.splitlines() if 'failed after' in l and 'Test ' in l})
        print(mid, 'KILLED' if r.returncode != 0 else 'SURVIVED', '%.0fs' % (time.time() - t), desc, '|', '; '.join(failed)[:400], flush=True)
    finally:
        open(p, 'w').write(src)
