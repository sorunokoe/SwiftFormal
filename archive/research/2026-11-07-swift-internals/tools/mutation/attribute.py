import glob, os, re, sys
d = os.path.dirname(os.path.abspath(__file__))
fast = {'S0Tests', 'SoundnessZooTests', 'ParserFuzzTests', 'ProofCheckerFuzzTests', 'SATDifferentialTests', 'SATMetamorphicTests'}
for log in sorted(glob.glob(os.path.join(d, 'M*.log'))):
    s = open(log).read()
    failed = sorted(set(re.findall(r'Suite (\S+) failed after', s)))
    tests = sorted(set(re.findall(r'Test (\S+?)\(.*?\) (?:with \d+ test cases )?failed after', s)))
    problems = [p for p in ('No space left', 'error: fatalError', 'Fatal error', 'signal', 'timed out') if p in s]
    lane = 'fast' if set(failed) & fast else ('slow' if failed else '-')
    print(os.path.basename(log)[:-4], 'lane=' + lane, 'suites=' + ','.join(failed), 'tests=' + ','.join(tests)[:200], 'notes=' + ','.join(problems))
