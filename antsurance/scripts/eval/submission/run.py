#!/usr/bin/env python3
"""Reads the sample submission through the deployed code and counts what it got right.

Each sample document is read in an Anonymous Apex run of its own (one call to Claude each), as the
page does. A last run lays the readings against the quote questions and has Claude list what is
missing and draft the reply. Nothing is saved to any record.

    python3 -I scripts/eval/submission/run.py --org <alias> --run v1

Writes runs/<run>/readings.json, result.json and score.md. Uses five `sf` commands.
"""
import argparse, json, os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MARK = 'SUBMISSION>>'


def apex(org, body):
    """Runs one Anonymous Apex script and returns what it printed after the marker."""
    with tempfile.NamedTemporaryFile('w', suffix='.apex', delete=False) as script:
        script.write(body)
    try:
        done = subprocess.run(['sf', 'apex', 'run', '--file', script.name, '--target-org', org, '--json'],
                              capture_output=True, text=True, env={**os.environ, 'SF_DISABLE_TELEMETRY': 'true'})
    finally:
        os.unlink(script.name)
    reply = json.loads(done.stdout)
    result = reply.get('result') or {}
    if not result.get('success'):
        raise SystemExit('Apex failed: ' + (result.get('compileProblem') or result.get('exceptionMessage') or reply.get('message') or done.stdout[:400]))
    printed = []
    for line in result.get('logs', '').splitlines():
        # The log echoes the script itself, so only what System.debug wrote counts.
        if '|USER_DEBUG|' in line and MARK in line:
            printed.append(line.split(MARK, 1)[1].replace('&#124;', '|'))
    if not printed:
        raise SystemExit('The run printed nothing. Is a debug log being kept for this user?')
    return printed


def literal(text):
    return "'" + text.replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n').replace('\r', '') + "'"


def chunks(name, text, size=30000):
    """An Apex string too long for one literal, built in pieces."""
    lines = [f"String {name} = '';"]
    lines += [f'{name} += {literal(text[start:start + size])};' for start in range(0, len(text), size)]
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--org', required=True)
    parser.add_argument('--run', required=True)
    args = parser.parse_args()
    expected = json.load(open(os.path.join(HERE, 'expected.json')))
    folder = os.path.join(HERE, 'runs', args.run)
    os.makedirs(folder, exist_ok=True)
    sale = f"[SELECT Id FROM Opportunity WHERE Name = {literal(expected['sale'])} LIMIT 1].Id"

    readings = []
    for sample, name in zip(expected['samples'], expected['names']):
        printed = apex(args.org, f"System.debug(LoggingLevel.ERROR, '{MARK}' + JSON.serialize(AntsuranceSubmissionIntake.readSample({sale}, '{sample}')));")
        reading = json.loads(printed[0])
        reading['name'] = name
        readings.append(reading)
        print(f"read {name}: {len(reading.get('answers') or [])} answers, {len(reading.get('problems') or [])} problems")
    json.dump(readings, open(os.path.join(folder, 'readings.json'), 'w'), indent=1)

    printed = apex(args.org, '\n'.join([
        chunks('readings', json.dumps(readings)),
        f'Id saleId = {sale};',
        f"System.debug(LoggingLevel.ERROR, '{MARK}' + JSON.serialize(AntsuranceSubmissionIntake.assemble(saleId, readings, null)));",
        f"System.debug(LoggingLevel.ERROR, '{MARK}' + JSON.serialize(AntsuranceSubmissionIntake.advise(saleId, readings, null)));"
    ]))
    assembly, advice = json.loads(printed[0]), json.loads(printed[1])
    json.dump({'assembly': assembly, 'advice': advice}, open(os.path.join(folder, 'result.json'), 'w'), indent=1)

    rows = {row['key']: row for row in assembly['rows']}
    lines, right, wrong, missed = [], 0, 0, 0
    for key, want in expected['answers'].items():
        row = rows.get(key)
        got = 'not asked' if row is None else row['status']
        shown = '' if row is None else (row.get('value') or ' / '.join(sorted({s['value'] for s in row.get('sources') or []})))
        ok = row is not None and row['status'] in want['status']
        if ok and 'value' in want:
            ok = row.get('value') == want['value']
        if ok and 'contains' in want:
            ok = want['contains'] in (row.get('value') or '').lower()
        if ok and 'sides' in want:
            ok = sorted({s['value'] for s in row.get('sources') or []}) == sorted(want['sides'])
        if ok:
            right += 1
        elif row is not None and row['status'] == 'not_found' and want['status'] != ['not_found']:
            missed += 1
        else:
            wrong += 1
        lines.append(f"| {key} | {' or '.join(want['status'])} {want.get('value', want.get('contains', ''))} | {got} {shown} | {'right' if ok else 'WRONG'} |")

    conditional = any(item['document'] == expected['conditional']['document'] and expected['conditional']['reason'] in item['reasons'] for item in assembly.get('conditionals') or [])
    said = ' '.join(f"{issue.get('title', '')} {issue.get('detail', '')} {issue.get('ask', '')}" for issue in advice.get('issues') or []).lower()
    caught = {label: any(word in said for word in words) for label, words in expected['issues'].items()}

    report = [
        f'# Submission reading, run {args.run}', '',
        f"{right} of {len(expected['answers'])} fields right, {wrong} wrong, {missed} not found that should have been.", '',
        '| Question | Expected | Got | |', '|---|---|---|---|', *lines, '',
        f"Referral that depends on the loss run being right: {'shown' if conditional else 'NOT SHOWN'}.", '',
        'What Claude raised:', *[f"- {label}: {'raised' if hit else 'NOT RAISED'}" for label, hit in caught.items()], '',
        f"Headline: {advice.get('headline')}", '', 'Reply:', '', '```', f"Subject: {advice.get('replySubject')}", '', advice.get('replyBody') or '', '```', ''
    ]
    open(os.path.join(folder, 'score.md'), 'w').write('\n'.join(report))
    print('\n'.join(report))


if __name__ == '__main__':
    main()
