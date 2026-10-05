"""Summarize a deploy report saved as JSON: status, failures, and coverage per class.

usage: python3 -I scripts/apex_coverage/report.py <report.json> [--lines Class,Class]
"""
import json
import sys


def main():
    d = json.load(open(sys.argv[1]))
    r = d.get('result', d)
    lines_for = set()
    if '--lines' in sys.argv:
        lines_for = set(sys.argv[sys.argv.index('--lines') + 1].split(','))
    print('status', r.get('status'), '| checkOnly', r.get('checkOnly'), '| done', r.get('done'),
          '| components', r.get('numberComponentsDeployed'), '/', r.get('numberComponentsTotal'),
          '| component errors', r.get('numberComponentErrors'),
          '| tests', r.get('numberTestsCompleted'), '/', r.get('numberTestsTotal'),
          '| test errors', r.get('numberTestErrors'))
    print('start', r.get('startDate'), 'completed', r.get('completedDate'))
    if d.get('message'):
        print('message', str(d.get('message'))[:600])
    det = r.get('details', {}) or {}

    def aslist(v):
        if v is None:
            return []
        return v if isinstance(v, list) else [v]

    for f in aslist(det.get('componentFailures')):
        print('COMPONENT FAILURE', f.get('fullName'), f.get('lineNumber'), f.get('problem'))
    rt = det.get('runTestResult', {}) or {}
    print('tests run', rt.get('numTestsRun'), 'failures', rt.get('numFailures'), 'time ms', rt.get('totalTime'))
    for f in aslist(rt.get('failures')):
        print('TEST FAILURE', f.get('name'), f.get('methodName'), '|', str(f.get('message'))[:300])
        st = str(f.get('stackTrace') or '')[:300]
        if st:
            print('   ', st)
    for w in aslist(rt.get('codeCoverageWarnings')):
        print('WARNING', w.get('name'), '|', w.get('message'))
    rows = []
    for c in aslist(rt.get('codeCoverage')):
        n = int(c.get('numLocations') or 0)
        u = int(c.get('numLocationsNotCovered') or 0)
        pct = 100.0 * (n - u) / n if n else None
        rows.append((pct if pct is not None else 101, c.get('name'), c.get('type'), n - u, n, c))
    rows.sort(key=lambda x: (x[0], x[1]))
    tc = sum(x[3] for x in rows)
    tn = sum(x[4] for x in rows)
    for pct, name, typ, cov, n, c in rows:
        flag = '' if pct >= 75 else '  <-- UNDER 75'
        shown = 'no lines' if n == 0 else f'{pct:5.1f}%'
        print(f'{name:45s} {typ:8s} {cov:5d}/{n:5d} {shown}{flag}')
        if name in lines_for:
            locs = aslist(c.get('locationsNotCovered'))
            print('    uncovered lines:', sorted(int(l.get('line')) for l in locs))
    if tn:
        print(f'TOTAL {tc}/{tn} {100.0 * tc / tn:.1f}%')


main()
