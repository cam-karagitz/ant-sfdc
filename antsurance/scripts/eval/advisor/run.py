"""Runs the quote advisor cases against the deployed Apex in the Antsurance demo org and scores them.

usage: python3 run.py <label>
The cases run in two Anonymous Apex executions (to stay inside the org's daily API allowance), each calling
AntsuranceQuoteAdvisor.suggest, the method the page's entry point calls, so the prompt, the schema, the check
and the pricing are the ones that ship. Nothing is read from or saved to the org's records.

Scored per case:
  hit      the expected suggestion is among those returned (right kind, question and one of the acceptable values)
  valid    every suggestion returned names a real, shown question and one of its options that is not the answer
           already given (checked here again, independently of the Apex check)
Also reported: how many proposals Claude made and how many the Apex check dropped.
"""
import html, json, os, re, subprocess, sys
sys.path.insert(0, os.path.dirname(__file__))
from cases import CASES

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
BATCH = 5

def apex_string(text):
    return "'" + text.replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n') + "'"

def build(cases):
    body = []
    for case in cases:
        body.append(f"""
{{
    List<AntsuranceQuoteConfigurator.Section> sections = AntsuranceQuoteConfigurator.getQuestionnaire({apex_string(case['line'])});
    Integer step = sections.size();
    for (Integer i = 0; i < sections.size(); i++) {{ if (sections[i].key == {apex_string(case['step'])}) {{ step = i; }} }}
    Map<String, Object> answers = (Map<String, Object>) JSON.deserializeUntyped({apex_string(json.dumps(case['answers']))});
    Map<String, Object> options = new Map<String, Object>();
    for (AntsuranceQuoteConfigurator.Section s : sections) {{ for (AntsuranceQuoteConfigurator.Question q : s.questions) {{
        List<String> values = new List<String>(); for (AntsuranceQuoteConfigurator.Option o : q.options) {{ values.add(o.value); }}
        Object given = answers.get(q.key);
        options.put(q.key, new Map<String, Object>{{ 'values' => values, 'now' => given == null ? q.defaultValue : String.valueOf(given), 'asked' => AntsuranceQuoteConfigurator.isAsked(q, answers) }});
    }} }}
    Map<String, Object> row = new Map<String, Object>{{ 'id' => {apex_string(case['id'])}, 'options' => options }};
    Long started = System.currentTimeMillis();
    try {{
        AntsuranceQuoteAdvisor.Advice advice = AntsuranceQuoteAdvisor.suggest({apex_string(case['line'])}, JSON.serialize(answers), 1, step, {apex_string(case['facts'])});
        row.put('proposed', advice.proposed); row.put('dropped', advice.dropped); row.put('pitch', advice.pitch); row.put('suggestions', advice.suggestions);
    }} catch (Exception e) {{ row.put('error', e.getMessage()); }}
    row.put('ms', System.currentTimeMillis() - started);
    System.debug(LoggingLevel.ERROR, 'EVAL' + JSON.serialize(row));
}}""")
    return '\n'.join(body)

def run_batch(cases, outdir, index):
    path = os.path.join(outdir, f'batch-{index}.apex')
    open(path, 'w').write(build(cases))
    proc = subprocess.run(['sf', 'apex', 'run', '--file', path, '--target-org', os.environ['SF_TARGET_ORG'], '--json'], cwd=PROJECT,
                          capture_output=True, text=True, env={**os.environ, 'SF_DISABLE_TELEMETRY': 'true'})
    try:
        result = json.loads(proc.stdout)['result']
    except Exception as e:
        return [], f'{e}: {proc.stdout[:300]} {proc.stderr[:300]}'
    rows = [json.loads(html.unescape(m)) for m in re.findall(r'USER_DEBUG\|\[\d+\]\|ERROR\|EVAL(.*)', result.get('logs') or '')]
    problem = None if rows else (result.get('exceptionMessage') or result.get('compileProblem') or 'no output')
    return rows, problem

def score(case, row):
    suggestions = row.get('suggestions') or []
    kind, key, values = case['expect']
    wanted = case.get('any_of') or [(key, values)]
    hit = any(s['kind'] == kind and any(s['questionKey'] == k and s['value'] in v for k, v in wanted) for s in suggestions)
    valid = all(
        s['questionKey'] in row['options'] and row['options'][s['questionKey']]['asked']
        and s['value'] in row['options'][s['questionKey']]['values'] and s['value'] != row['options'][s['questionKey']]['now']
        for s in suggestions)
    text = json.dumps(suggestions) + (row.get('pitch') or '')
    # A limit or a fact may carry a figure ("Keep liability at $300,000", "18% of work was subcontracted"). What must not
    # appear is Claude's own arithmetic about the price: a saving, a cost, a percentage off.
    words = ' '.join((s.get('why') or '') + ' ' + (s.get('title') or '') for s in suggestions)
    arithmetic = re.search(r'(sav\w*|cheaper|costs?|adds?|discount of|off)\W+(\w+\W+){0,4}?(\$\s?\d|\d+(\.\d+)?\s?(%|percent))', words, re.I)
    clean = '\u2014' not in text and '\u2013' not in text and not arithmetic
    return {'hit': hit, 'valid': valid, 'no_arithmetic_or_dashes': clean, 'at_most_three': len(suggestions) <= 3}

def main():
    label = sys.argv[1]
    outdir = os.path.join(HERE, 'runs', label)
    os.makedirs(outdir, exist_ok=True)
    by_id = {c['id']: c for c in CASES}
    rows, problems = [], []
    for index in range(0, len(CASES), BATCH):
        got, problem = run_batch(CASES[index:index + BATCH], outdir, index // BATCH)
        rows += got
        if problem:
            problems.append(problem)
    results = []
    for row in rows:
        case = by_id[row['id']]
        results.append({'case': row['id'], 'checks': None if row.get('error') else score(case, row), 'out': {k: v for k, v in row.items() if k != 'options'}})
    json.dump({'results': results, 'problems': problems}, open(os.path.join(outdir, 'results.json'), 'w'), indent=1)

    scored = [r for r in results if r['checks']]
    print(f"\n== {label}: {len(scored)} scored of {len(CASES)} cases")
    for name in ('hit', 'valid', 'no_arithmetic_or_dashes', 'at_most_three'):
        print(f"  {name:22s} {sum(r['checks'][name] for r in scored)}/{len(scored)}")
    proposed = sum(r['out'].get('proposed') or 0 for r in scored); dropped = sum(r['out'].get('dropped') or 0 for r in scored)
    print(f"  proposals by Claude    {proposed}, dropped by the Apex check {dropped}")
    times = sorted(r['out']['ms'] for r in scored)
    if times:
        print(f"  latency ms: median {times[len(times)//2]}, max {times[-1]}")
    for r in sorted(results, key=lambda r: r['case']):
        mark = 'ERROR' if not r['checks'] else ('ok  ' if all(r['checks'].values()) else 'FAIL')
        print(f"  {mark} {r['case']}" + ('' if r['checks'] else f": {r['out'].get('error')}") + ('' if not r['checks'] or all(r['checks'].values()) else f": {[k for k, v in r['checks'].items() if not v]}"))
        for s in r['out'].get('suggestions') or []:
            print(f"        {s['kind']:6s} {s['questionKey']}={s['value']} ({s['premiumChange']:+.0f}) {s['title']!r}: {s['why']!r}" + (f" refers {s['referrals']}" if s.get('referrals') else ''))
    for p in problems:
        print('  PROBLEM', p)

main()
