"""Runs the intake accuracy cases against the deployed Apex in the Antsurance demo org and scores them.

usage: python3 run.py <label> [tune|held|all] [reps]
Each case is one Anonymous Apex run that calls AntsuranceClaimsAssistantIntake.readMessage, the
method the form calls, so the prompt, schema and model settings are the ones that ship. Nothing is saved.
"""
import concurrent.futures, html, json, os, re, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from cases import CASES

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = '/Users/ck/dev/customer/sfdc/antsurance'

def apex_string(text):
    return "'" + text.replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n') + "'"

def build(case):
    if case.get('sample'):
        message = ("''; for (AntsuranceClaimsAssistantIntake.Sample s : c.samples) { if (s.key == '%s') { message = s.text; } }" % case['sample'])
        message_line = 'String message = ' + message
    else:
        message_line = 'String message = ' + apex_string(case['message']) + ';'
    return f"""
Account a = [SELECT Id FROM Account WHERE Name = {apex_string(case['account'])} LIMIT 1];
AntsuranceClaimsAssistantIntake.IntakeContext c = AntsuranceClaimsAssistantIntake.getContext(a.Id);
{message_line}
Long started = System.currentTimeMillis();
AntsuranceClaimsAssistantIntake.Draft d = AntsuranceClaimsAssistantIntake.readMessage(a.Id, message);
Map<String, Object> out = new Map<String, Object>{{ 'ms' => System.currentTimeMillis() - started, 'draft' => d, 'message' => message }};
for (AntsuranceClaimsAssistantIntake.PolicyOption p : c.policies) {{ if (p.policyId == d.policyId) {{ out.put('line', p.lineOfBusiness); out.put('status', p.status); }} }}
for (AntsuranceClaimsAssistantIntake.ContactOption p : c.contacts) {{ if (p.contactId == d.contactId) {{ out.put('reporter', p.name); }} }}
System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(out));
"""

def run_case(case, rep, outdir):
    path = os.path.join(outdir, f"{case['id']}.{rep}.apex")
    open(path, 'w').write(build(case))
    for attempt in range(2):
        proc = subprocess.run(['sf', 'apex', 'run', '--file', path, '--target-org', os.environ['SF_TARGET_ORG'], '--json'], cwd=PROJECT,
                              capture_output=True, text=True, env={**os.environ, 'SF_DISABLE_TELEMETRY': 'true'})
        try:
            result = json.loads(proc.stdout)['result']
            match = re.search(r'USER_DEBUG\|\[\d+\]\|ERROR\|EVAL(.*)', result.get('logs') or '')
            if match:
                return json.loads(html.unescape(match.group(1)))
            error = result.get('exceptionMessage') or result.get('compileProblem') or 'no output'
        except Exception as e:  # the CLI itself failed
            error = f'{e}: {proc.stdout[:200]} {proc.stderr[:200]}'
        time.sleep(3)
    return {'error': error}

def score(case, out):
    """Returns {check: True/False} for one output. Only fields the case specifies are scored."""
    d = out['draft']
    checks = {'is_claim': bool(d.get('isClaim')) == case['is_claim']}
    if not case['is_claim']:
        checks['reason_given'] = bool(d.get('notClaimReason'))
        return checks
    checks['policy'] = out.get('line') == case['line']
    checks['date'] = d.get('dateOfLoss') == case['date'].isoformat()
    checks['loss_type'] = d.get('lossType') == case['loss_type']
    checks['severity'] = d.get('severity') in case['severity']
    estimate = d.get('estimatedLoss')
    checks['estimate'] = (estimate is None) if case['estimate'] is None else (estimate is not None and abs(float(estimate) - case['estimate']) < 0.5)
    if 'origin' in case:
        checks['origin'] = d.get('origin') == case['origin']
    if 'reporter' in case:
        checks['reporter'] = (out.get('reporter') or '') == case['reporter']
    location = (d.get('lossLocation') or '')
    checks['location'] = (location == '') if not case['location'] else any(token.lower() in location.lower() for token in case['location'])
    subject = d.get('subject') or ''
    surname = case['account'].split()[0]
    checks['subject_form'] = 0 < len(subject) <= 60 and surname.lower() not in subject.lower() and not subject.endswith('.')
    description = d.get('description') or ''
    checks['details_kept'] = all(token.lower() in description.lower() for token in case.get('keep', []))
    if case.get('needs_missing'):
        checks['asks_whats_missing'] = len(d.get('missing') or []) >= 1
    if case.get('watch'):
        watch = ' '.join(d.get('watch') or []).lower()
        checks['flags_it'] = all(token in watch for token in case['watch'])
    text = json.dumps(d)
    checks['no_dashes'] = '\u2014' not in text and '\u2013' not in text
    return checks

def main():
    label = sys.argv[1]
    split = sys.argv[2] if len(sys.argv) > 2 else 'all'
    reps = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    outdir = os.path.join(HERE, 'runs', label)
    os.makedirs(outdir, exist_ok=True)
    cases = [c for c in CASES if split == 'all' or c['split'] == split]
    jobs = [(c, r) for c in cases for r in range(reps)]
    rows, errors = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures = {pool.submit(run_case, c, r, outdir): (c, r) for c, r in jobs}
        for future in concurrent.futures.as_completed(futures):
            case, rep = futures[future]
            out = future.result()
            if 'error' in out:
                # A run that produced no answer is an infrastructure failure, not a wrong answer.
                errors.append({'case': case['id'], 'rep': rep, 'error': out['error']})
                continue
            rows.append({'case': case['id'], 'split': case['split'], 'rep': rep, 'ms': out['ms'], 'checks': score(case, out), 'out': out})
    json.dump({'rows': rows, 'errors': errors}, open(os.path.join(outdir, 'results.json'), 'w'), indent=1, default=str)

    totals = {}
    for row in rows:
        for name, ok in row['checks'].items():
            passed, seen = totals.get(name, (0, 0))
            totals[name] = (passed + bool(ok), seen + 1)
    print(f"\n== {label}: {len(rows)} scored, {len(errors)} errored, {len(cases)} cases x {reps}")
    for name, (passed, seen) in totals.items():
        print(f"  {name:20s} {passed}/{seen}")
    clean = sum(all(row['checks'].values()) for row in rows)
    print(f"  {'all checks pass':20s} {clean}/{len(rows)}")
    times = sorted(row['ms'] for row in rows)
    if times:
        print(f"  latency ms: median {times[len(times)//2]}, max {times[-1]}")
    for row in sorted(rows, key=lambda r: r['case']):
        failed = [name for name, ok in row['checks'].items() if not ok]
        if failed:
            d = row['out']['draft']
            print(f"  FAIL {row['case']} rep {row['rep']}: {failed}")
            print('       got: line=%s date=%s type=%s sev=%s est=%s origin=%s reporter=%s loc=%r' % (
                row['out'].get('line'), d.get('dateOfLoss'), d.get('lossType'), d.get('severity'), d.get('estimatedLoss'), d.get('origin'), row['out'].get('reporter'), d.get('lossLocation')))
            print('       subject=%r' % d.get('subject'))
            if 'details_kept' in failed: print('       description=%r' % d.get('description'))
            if 'flags_it' in failed: print('       watch=%r' % d.get('watch'))
            if 'is_claim' in failed: print('       reason=%r' % d.get('notClaimReason'))
    for e in errors:
        print('  ERROR', e)

main()
