"""Shared helpers for the Antsurance setup scripts.

Python 3 standard library only. Every call to an org goes through the Salesforce CLI (`sf`), using the
login the person already made with `sf org login web`. Nothing here stores a password, a token or a key.
"""
import html
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone

KIT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
STATE_DIR = os.path.join(KIT_ROOT, '.install')
MIN_PYTHON = (3, 8)
# What this run has spent: `sf` commands started, and requests the org counts against its daily allowance.
USAGE = {'commands': 0, 'requests': 0}


class SetupError(Exception):
    """A problem the person has to know about. The message is written for them."""


def fail(message, code=1):
    print('STOPPED: ' + message, file=sys.stderr)
    sys.exit(code)


def check_python():
    if sys.version_info < MIN_PYTHON:
        fail('Python %d.%d or newer is needed. This is %s.' % (MIN_PYTHON[0], MIN_PYTHON[1], sys.version.split()[0]))


def manifest():
    path = os.path.join(KIT_ROOT, 'kit-manifest.json')
    if not os.path.exists(path):
        raise SetupError('kit-manifest.json is missing from ' + KIT_ROOT + '. Run these scripts from an unpacked kit.')
    with open(path) as handle:
        return json.load(handle)


def api_version():
    return manifest().get('apiVersion', '67.0')


def sf(args, stdin=None, timeout=1800, allow_failure=False, cwd=None):
    """Runs `sf <args> --json` and returns the parsed reply. Raises SetupError with sf's own message on failure."""
    if shutil.which('sf') is None:
        raise SetupError('The Salesforce CLI (sf) is not installed. Install it with: npm install --global @salesforce/cli')
    env = dict(os.environ, SF_DISABLE_TELEMETRY='true', SF_AUTOUPDATE_DISABLE='true')
    USAGE['commands'] += 1
    try:
        done = subprocess.run(['sf'] + args + ['--json'], input=stdin, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd or KIT_ROOT)
    except subprocess.TimeoutExpired:
        raise SetupError('sf %s did not finish in %d seconds.' % (' '.join(args[:3]), timeout))
    text = done.stdout.strip()
    try:
        reply = json.loads(text[text.index('{'):]) if '{' in text else {}
    except ValueError:
        reply = {}
    if not reply:
        raise SetupError('sf %s gave no readable answer. %s' % (' '.join(args[:3]), (done.stderr or text).strip()[:400]))
    if reply.get('status', 0) != 0 and not allow_failure:
        raise SetupError('sf %s failed: %s' % (' '.join(args[:3]), str(reply.get('message') or reply.get('name') or 'unknown error')[:600]))
    return reply


def rest(org, path, method='GET', body=None):
    """One request to the org's REST API through `sf api request rest`. Returns the parsed JSON, or None for an empty reply."""
    if shutil.which('sf') is None:
        raise SetupError('The Salesforce CLI (sf) is not installed. Install it with: npm install --global @salesforce/cli')
    env = dict(os.environ, SF_DISABLE_TELEMETRY='true', SF_AUTOUPDATE_DISABLE='true')
    args = ['sf', 'api', 'request', 'rest', path, '--method', method, '--target-org', org]
    USAGE['commands'] += 1
    USAGE['requests'] += 1
    if body is not None:
        # The body goes in on standard input, so nothing in it appears in a command line or a file.
        args += ['--header', 'Content-Type:application/json', '--body', '-']
    done = subprocess.run(args, input=None if body is None else json.dumps(body), capture_output=True, text=True, timeout=600, env=env, cwd=KIT_ROOT)
    out = done.stdout.strip()
    if done.returncode != 0 and not out:
        err = (done.stderr or '').strip()
        if 'is not a sf command' in err or 'not found' in err.lower() and 'api' in err:
            raise SetupError('This Salesforce CLI is too old for these scripts. Update it with: npm install --global @salesforce/cli')
        raise SetupError('The org refused a request to %s: %s' % (path.split('?')[0], err[:400]))
    if not out:
        return None
    start = min([i for i in (out.find('{'), out.find('[')) if i >= 0] or [0])
    try:
        return json.loads(out[start:])
    except ValueError:
        raise SetupError('The org sent back something unreadable from %s: %s' % (path.split('?')[0], out[:200]))


def batch(org, requests):
    """Many read-only GETs in as few calls as possible. `requests` is a list of (name, path under /services/data/vNN.N/).

    Returns {name: (ok, result)}. A sub-request that fails comes back as (False, message); it never stops the others.
    """
    version = 'v' + api_version()
    answers = {}
    for start in range(0, len(requests), 25):
        chunk = requests[start:start + 25]
        # The org counts each question in a batch as a request of its own.
        USAGE['requests'] += len(chunk)
        body = {'haltOnError': False, 'batchRequests': [{'method': 'GET', 'url': version + '/' + path} for _, path in chunk]}
        reply = rest(org, '/services/data/' + version + '/composite/batch', 'POST', body)
        results = (reply or {}).get('results') or []
        if len(results) != len(chunk):
            raise SetupError('The org answered %d of %d questions; expected all of them.' % (len(results), len(chunk)))
        for (name, _), result in zip(chunk, results):
            code = result.get('statusCode', 500)
            payload = result.get('result')
            if 200 <= code < 300:
                answers[name] = (True, payload)
            else:
                first = payload[0] if isinstance(payload, list) and payload else payload or {}
                answers[name] = (False, '%s: %s' % (first.get('errorCode', code), first.get('message', '')) if isinstance(first, dict) else str(first))
    return answers


def stage_project(folder_name):
    """Makes stage/ a small Salesforce project whose one package folder is the phase being deployed.

    Deploys run from there, so the kit's own folders are never the thing that is deployed or changed.
    """
    stage = os.path.join(KIT_ROOT, 'stage')
    os.makedirs(os.path.join(stage, folder_name), exist_ok=True)
    with open(os.path.join(stage, 'sfdx-project.json'), 'w') as handle:
        json.dump({'packageDirectories': [{'path': folder_name, 'default': True}], 'namespace': '', 'sourceApiVersion': api_version()}, handle, indent=2)
    ignore = os.path.join(KIT_ROOT, '.forceignore')
    if os.path.exists(ignore):
        shutil.copyfile(ignore, os.path.join(stage, '.forceignore'))
    return stage


def debug_line(logs, marker):
    """The text after `marker` on the line our Apex wrote to the debug log, or None.

    Only lines the org logged as USER_DEBUG count: the log also echoes the Apex source, which holds the marker too.
    """
    for line in (logs or '').splitlines():
        # The log writes "|" inside a message as &#124;.
        line = html.unescape(line)
        if 'USER_DEBUG' in line and marker in line:
            return line[line.index(marker) + len(marker):].strip()
    return None


ID_PREFIXES = {'0Pa': 'PermissionSetAssignment', '011': 'GroupMember'}


def delete_ids(org, ids):
    """Deletes permission set assignments and group memberships by id. Returns the problems, as plain lines."""
    version = 'v' + api_version()
    problems = []
    for start in range(0, len(ids), 25):
        chunk = ids[start:start + 25]
        body = {'haltOnError': False, 'batchRequests': [{'method': 'DELETE', 'url': '%s/sobjects/%s/%s' % (version, ID_PREFIXES[one[:3]], one)} for one in chunk]}
        reply = rest(org, '/services/data/%s/composite/batch' % version, 'POST', body)
        for one, result in zip(chunk, (reply or {}).get('results') or []):
            if not 200 <= result.get('statusCode', 500) < 300:
                detail = result.get('result')
                first = detail[0] if isinstance(detail, list) and detail else {}
                # Already gone is not a problem.
                if first.get('errorCode') != 'ENTITY_IS_DELETED':
                    problems.append('%s: %s' % (first.get('errorCode', result.get('statusCode')), first.get('message', one)))
    return problems


def soql(text, tooling=False):
    return ('tooling/' if tooling else '') + 'query?q=' + urllib.parse.quote(' '.join(text.split()))


def tooling(org, text):
    """One Tooling API query, asked by itself. (Asked in a batch, the Tooling API leaves the fields out of its rows.)

    Returns (ok, rows or message), and never raises for a question the org cannot answer.
    """
    try:
        reply = rest(org, '/services/data/v%s/%s' % (api_version(), soql(text, tooling=True)))
    except SetupError as problem:
        return False, str(problem)
    if isinstance(reply, list):
        first = reply[0] if reply else {}
        return False, '%s: %s' % (first.get('errorCode'), first.get('message'))
    return True, (reply or {}).get('records', [])


def records(answer):
    ok, payload = answer
    return (payload or {}).get('records', []) if ok else []


def in_list(names):
    return ','.join("'" + name.replace("'", "\\'") + "'" for name in names) or "''"


def describe_org(org):
    """Who and what the target is. Always called first, and always printed, so nobody acts on the wrong org."""
    shown = sf(['org', 'display', '--target-org', org])['result']
    answers = batch(org, [('org', soql('SELECT Id, Name, OrganizationType, IsSandbox, TrialExpirationDate, NamespacePrefix, InstanceName FROM Organization'))])
    row = (records(answers['org']) or [{}])[0]
    is_sandbox = bool(row.get('IsSandbox'))
    expires = row.get('TrialExpirationDate')
    kind = row.get('OrganizationType') or 'Unknown'
    is_scratch = is_sandbox and expires is not None
    is_developer = kind == 'Developer Edition'
    # Anything that is not a sandbox, a scratch org, a Developer Edition or a trial is treated as production.
    is_production = not is_sandbox and not is_developer and expires is None
    return {
        'alias': org, 'username': shown.get('username'), 'orgId': shown.get('id') or row.get('Id'), 'instanceUrl': shown.get('instanceUrl'),
        'name': row.get('Name'), 'edition': kind, 'isSandbox': is_sandbox and not is_scratch, 'isScratch': is_scratch, 'isDeveloperEdition': is_developer,
        'isTrial': not is_sandbox and expires is not None, 'expires': expires, 'isProduction': is_production, 'namespace': row.get('NamespacePrefix'),
    }


def kind_of(org_facts):
    if org_facts['isProduction']:
        return 'PRODUCTION'
    if org_facts['isScratch']:
        return 'scratch org'
    if org_facts['isSandbox']:
        return 'sandbox'
    if org_facts['isDeveloperEdition']:
        return 'Developer Edition'
    return 'trial org'


def announce(org_facts, action):
    """Says the target before anything happens to it."""
    print('Target org: %s (%s, %s, signed in as %s)' % (org_facts['alias'], org_facts['name'], kind_of(org_facts), org_facts['username']))
    print('About to: ' + action)


def guard_production(org_facts, allowed):
    if org_facts['isProduction'] and not allowed:
        raise SetupError(
            '%s is a production org. Install into a sandbox or a scratch org first. To go ahead in production anyway, '
            'the person who owns the org must ask for that, and the command must be run again with --allow-production.' % org_facts['alias']
        )


def load_state(org_facts):
    path = state_path(org_facts)
    if os.path.exists(path):
        with open(path) as handle:
            return json.load(handle)
    return {'orgId': org_facts['orgId'], 'alias': org_facts['alias'], 'answers': {}, 'phases': {}, 'access': {}, 'log': []}


def save_state(org_facts, state):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(state_path(org_facts), 'w') as handle:
        json.dump(state, handle, indent=2, sort_keys=True)


def state_path(org_facts):
    return os.path.join(STATE_DIR, 'state-%s.json' % (org_facts['orgId'] or org_facts['alias']))


def record(org_facts, phase, outcome, detail=None):
    """Writes what was done to the state file the install report is made from."""
    state = load_state(org_facts)
    entry = {'at': now(), 'outcome': outcome}
    if detail:
        entry['detail'] = detail
    state['phases'][phase] = entry
    state['log'].append(dict(entry, phase=phase))
    save_state(org_facts, state)


def now():
    return datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')


# ---------------------------------------------------------------- code coverage

COVERAGE_FLOOR = 75


def coverage_rows(result):
    """Lines covered and lines in all, for each class and trigger, from a test run or from a deploy that ran tests.

    Reads the shapes the Salesforce CLI has used: a test run with code coverage (coverage.coverage, and the older
    codecoverage) and a deploy's details.runTestResult.codeCoverage. Returns {name: (covered, lines)}.
    """
    result = result or {}
    rows = {}

    def number(value):
        try:
            return int(float(str(value).strip().rstrip('%')))
        except (TypeError, ValueError):
            return 0
    for row in ((result.get('coverage') or {}).get('coverage') or []):
        rows[row.get('name')] = (number(row.get('totalCovered')), number(row.get('totalLines')))
    for row in result.get('codecoverage') or []:
        covered, missed = number(row.get('numLinesCovered')), number(row.get('numLinesUncovered'))
        rows.setdefault(row.get('name'), (covered, covered + missed))
    deployed = ((result.get('details') or {}).get('runTestResult') or {}).get('codeCoverage') or []
    for row in [deployed] if isinstance(deployed, dict) else deployed:
        lines, missed = number(row.get('numLocations')), number(row.get('numLocationsNotCovered'))
        rows.setdefault(row.get('name'), (lines - missed, lines))
    rows.pop(None, None)
    return rows


def apex_has_code(text):
    """Whether an Apex class holds anything a test could run: a statement inside a method, or a field given a value.

    An interface, an enum, an exception with an empty body and a class of plain fields have nothing to cover, and
    Salesforce reports no coverage for them. That is not a gap.
    """
    text = re.sub(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\\n])*'", "''", text or '', flags=re.S)
    # For each open brace: 'type' when it opens a class, interface or enum, 'code' when it opens anything else.
    open_blocks = []
    header = ''
    for char in text:
        if char == '{':
            words = {word.lower() for word in re.findall(r'\w+', header)}
            open_blocks.append('type' if words & {'class', 'interface', 'enum'} else 'code')
            header = ''
        elif char == '}':
            if open_blocks:
                open_blocks.pop()
            header = ''
        elif char == ';':
            statement, header = header.strip(), ''
            if not open_blocks:
                continue
            if open_blocks[-1] == 'type':
                # In a class body this is a field or an abstract method. Only a field that is given a value runs.
                if '=' in statement:
                    return True
            elif not re.fullmatch(r'(?i)((public|private|protected|global)\s+)?(get|set)', statement):
                # In code, any statement runs. The `get;` and `set;` of a plain property do not.
                return True
        else:
            header += char
    return False


def coverage_gate(rows, classes, triggers, has_code=None, floor=COVERAGE_FLOOR):
    """Holds our code to the bar a production deploy is held to. Returns (what was measured, problems).

    Salesforce refuses a production deploy under 75 percent, and a deploy that names its tests (how this kit deploys)
    asks 75 percent of every class and trigger in it. So: every class and trigger of ours at 75 or more, and 75 overall.
    `has_code(name)` says whether a class the run reported nothing for holds any code at all; None means unknown.
    """
    low, missing, nothing, measured = [], [], [], []
    covered_all = lines_all = 0
    for kind, names in (('class', classes), ('trigger', triggers)):
        for name in sorted(names):
            if name in rows and rows[name][1] > 0:
                covered, lines = rows[name]
                covered_all += covered
                lines_all += lines
                entry = (covered * 100.0 / lines, name, covered, lines, kind)
                measured.append(entry)
                if covered * 100 < floor * lines:
                    low.append(entry)
            elif kind == 'trigger' or has_code is None or has_code(name) is not False:
                missing.append((name, kind))
            else:
                nothing.append(name)
    lines, problems = [], []
    overall = covered_all * 100.0 / lines_all if lines_all else 0.0
    for percent, name, covered, total, kind in sorted(low):
        lines.append('%s%s is %d percent covered (%d of %d lines). The bar is %d.' % ('Trigger ' if kind == 'trigger' else '', name, int(percent), covered, total, floor))
    for name, kind in missing:
        lines.append('%s%s has no coverage recorded: no test that ran reaches it. The bar is %d.' % ('Trigger ' if kind == 'trigger' else '', name, floor))
    if low:
        problems.append('%d under %d percent' % (len(low), floor))
    if missing:
        problems.append('%d with no coverage' % len(missing))
    if lines_all and covered_all * 100 < floor * lines_all:
        problems.append('%d percent overall' % int(overall))
    if not measured:
        problems.append('the run reported no coverage at all')
    summary = 'our code is %d percent covered overall (%s of %s lines in %d classes and triggers' % (int(overall), format(covered_all, ','), format(lines_all, ','), len(measured))
    summary += '; %d more have nothing to cover)' % len(nothing) if nothing else ')'
    lowest = ', '.join('%s %d' % (name, int(percent)) for percent, name, _, _, _ in sorted(measured)[:3])
    return {'summary': summary, 'lowest': lowest, 'overall': overall, 'measured': len(measured), 'nothing': nothing, 'lines': lines}, problems


def low_coverage_lines(result, floor=COVERAGE_FLOOR):
    """One plain line for each class or trigger of ours that a deploy's tests left under the bar: its name, its
    figure and the bar. For deploy_phase.py to print beside Salesforce's own message. Empty when all are at the bar."""
    low = sorted((covered * 100 // lines, name, covered, lines) for name, (covered, lines) in coverage_rows(result).items()
                 if lines and name.lower().startswith('antsurance') and covered * 100 < floor * lines)
    return ['  COVERAGE %s is %d percent covered (%d of %d lines). The bar is %d percent for every class and trigger in a deploy.' % (name, percent, covered, lines, floor)
            for percent, name, covered, lines in low]


def our_coverage(result, ours, portal_in_org=False):
    """Our coverage from a test run or a deploy, as lines to print. Returns (passed, lines).

    Used by verify.py after its test run. A deploy that ran tests can be read the same way: pass its result.
    """
    def source(name):
        for base in (os.path.join('force-app', 'main', 'default'), os.path.join('optional', 'portal')):
            path = os.path.join(KIT_ROOT, base, 'classes', name + '.cls')
            if os.path.exists(path):
                with open(path, encoding='utf-8') as handle:
                    return handle.read()
        return None

    def has_code(name):
        text = source(name)
        return None if text is None else apex_has_code(text)
    tests = set(ours['apexTestClasses']) | set(ours.get('portalTestClasses') or [])
    classes = [name for name in ours['apexClasses'] if name not in tests]
    in_portal = [name for name in ours['apexTriggers'] if os.path.exists(os.path.join(KIT_ROOT, 'optional', 'portal', 'triggers', name + '.trigger'))]
    triggers = [name for name in ours['apexTriggers'] if name not in in_portal]
    if portal_in_org:
        classes += [name for name in ours.get('portalClasses') or [] if name not in tests]
        triggers += in_portal
    found, problems = coverage_gate(coverage_rows(result), classes, triggers, has_code)
    if not problems:
        return True, ['PASS  Coverage: %s. Every class and trigger of ours is at %d percent or more. Lowest: %s.' % (found['summary'], COVERAGE_FLOOR, found['lowest'])]
    lines = ['FAIL  Coverage: %s. Salesforce asks %d percent of every class and trigger in a deploy, and refuses production under it. Short of the bar (%s):'
             % (found['summary'], COVERAGE_FLOOR, ', '.join(problems))]
    lines += ['      ' + line for line in found['lines']]
    lines += ['      A test that returns early because a feature is off in this org (Salesforce Notes, for example) passes and covers nothing.',
              '      Check that first for the classes named, then add tests for the lines they miss. CLAUDE.md, "The coverage bar", says how.']
    return False, lines


def main(run):
    """Runs a script's main function and turns a SetupError into one plain line and a non-zero exit."""
    check_python()
    try:
        # Print each line as it happens, also when the output goes to a file or to another program.
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass
    try:
        run()
    except SetupError as problem:
        fail(str(problem))
    except KeyboardInterrupt:
        fail('Canceled. Nothing further was changed.', 130)
