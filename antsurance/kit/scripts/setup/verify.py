#!/usr/bin/env python3
"""Checks an install: runs our tests with code coverage, confirms access comes only from our permission sets, and
gives the app's address.

Changes nothing in the org (the tests roll back whatever they create).

The coverage gate: Salesforce refuses a production deploy under 75 percent coverage, and a deploy that names its
tests asks 75 percent of every class and trigger in it. This holds our own code to that everywhere: it prints our
overall figure and every class or trigger of ours under 75 percent, and fails if there is one, or a trigger no test runs.

With --capability it checks one part of the app instead (deploy_phase.py --list names them): that the part and
everything it needs is in the org, that you hold its permission sets, that nothing else of ours is there, and that
the part's own tests pass with every class and trigger in it at 75 percent or more.

Usage: python3 scripts/setup/verify.py --target-org <alias> [--skip-tests] [--open]
       python3 scripts/setup/verify.py --target-org <alias> --capability automation [--skip-tests]
Exit code 0 when every check passes, 1 when any fails.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capabilities  # noqa: E402
from _common import COVERAGE_FLOOR, KIT_ROOT, SetupError, apex_has_code, batch, coverage_gate, coverage_rows, describe_org, in_list, main, manifest, our_coverage, record, records, sf, soql, tooling  # noqa: E402


def run_tests(org, classes, wait):
    # Coverage comes back with the same run, so the gate costs no extra call to the org.
    args = ['apex', 'run', 'test', '--target-org', org, '--test-level', 'RunSpecifiedTests', '--wait', str(wait), '--result-format', 'json', '--code-coverage']
    for name in classes:
        args += ['--class-names', name]
    reply = sf(args, timeout=wait * 60 + 120, allow_failure=True)
    result = reply.get('result') or {}
    summary = result.get('summary') or {}
    failures = [test for test in result.get('tests') or [] if str(test.get('Outcome')).lower() not in ('pass', 'skip')]
    return summary, failures, reply


def capability_checks(kit, name, have, state):
    """The checks of one part that need no test run. Returns [(passed, line)]. Calls nothing."""
    all_of = capabilities.listed(kit)
    entry = all_of[name]
    needed = capabilities.chain(name, kit)
    lines = []
    absent = [other for other in needed if not (state['whole'] or other in state['installed'])]
    labels = ', '.join('"%s"' % all_of[other]['label'] for other in needed)
    if absent:
        lines.append((False, 'Installed: %s %s not in the org in full. "%s" needs: %s.' % (', '.join('"%s"' % all_of[other]['label'] for other in absent), 'is' if len(absent) == 1 else 'are', entry['label'], labels)))
    else:
        lines.append((True, 'Installed: %s %s in the org%s.' % (labels, 'is' if len(needed) == 1 else 'are', ', as part of the whole app' if state['whole'] else '')))
    sets = capabilities.access_sets(name, kit)
    lacking = [one for one in sets if one not in have['mine']]
    if state['whole'] and capabilities.WHOLE_APP_SET in have['mine']:
        lines.append((True, 'Your access: you hold %s, which covers this part.' % capabilities.WHOLE_APP_SET))
    elif lacking:
        lines.append((False, 'Your access: you do not hold %s. Run: python3 scripts/setup/assign_access.py --target-org <alias> --capability %s --only-me --yes' % (', '.join(lacking), name)))
    else:
        lines.append((True, 'Your access: you hold %s.' % (', '.join(sets) or 'what it needs: this part has no permission set of its own')))
    if not state['whole']:
        extra = dict(state['outside'])
        if extra or state['partly']:
            lines.append((False, 'Nothing else of ours: ' + ' '.join(line.strip() for line in capabilities.standing_lines(kit, have, state)[1:])))
        else:
            lines.append((True, 'Nothing else of ours is in the org beyond: %s.' % ', '.join('"%s"' % all_of[other]['label'] for other in state['installed'])))
    return lines


def capability_coverage(kit, name, result):
    """The 75 percent bar for one part: every class and trigger of the part and of what it brings."""
    classes, triggers = [], []
    for other in capabilities.chain(name, kit):
        covered = capabilities.named(other, kit).get('covered') or {}
        classes += [one for one in covered.get('classes', []) if one not in classes]
        triggers += [one for one in covered.get('triggers', []) if one not in triggers]

    def has_code(one):
        path = os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'classes', one + '.cls')
        if not os.path.exists(path):
            return None
        with open(path, encoding='utf-8') as handle:
            return apex_has_code(handle.read())
    found, problems = coverage_gate(coverage_rows(result), classes, triggers, has_code)
    if not problems:
        return True, ['PASS  Coverage: %s. Every class and trigger in this part is at %d percent or more. Lowest: %s.' % (found['summary'].replace('our code', 'this part'), COVERAGE_FLOOR, found['lowest'])]
    return False, ['FAIL  Coverage: %s. Short of the bar (%s):' % (found['summary'].replace('our code', 'this part'), ', '.join(problems))] + ['      ' + line for line in found['lines']]


def verify_capability(org, args):
    kit = manifest()
    name = args.capability
    entry = capabilities.named(name, kit)
    if entry['kind'] not in ('layer', 'slice'):
        raise SetupError('"%s" is checked with the whole app: run this without --capability.' % entry['label'])
    print('Target org: %s (%s). Checking "%s". This changes nothing.' % (args.target_org, org['name'], entry['label']))
    have = capabilities.standing(args.target_org, org['username'], kit)
    state = capabilities.judge(kit, have)
    failed = []
    for passed, line in capability_checks(kit, name, have, state):
        print(('PASS  ' if passed else 'FAIL  ') + line.replace('<alias>', args.target_org))
        if not passed:
            failed.append(line.split(':')[0].lower())
    tests = []
    for other in capabilities.chain(name, kit):
        tests += [one for one in capabilities.named(other, kit).get('tests') or [] if one not in tests]
    if args.skip_tests or not tests:
        print('SKIP  Tests: %s' % ('this part holds no code.' if not tests else 'not run, so coverage was not measured here. The install of each part runs its tests, and Salesforce refuses it under %d percent for any class or trigger in it.' % COVERAGE_FLOOR))
    else:
        print('Running %d test classes with code coverage.' % len(tests))
        summary, failures, reply = run_tests(args.target_org, tests, args.wait)
        if not summary:
            failed.append('tests')
            print('FAIL  Tests: the run did not finish: %s' % str(reply.get('message'))[:300])
        elif failures or str(summary.get('outcome')).lower() != 'passed':
            failed.append('tests')
            print('FAIL  Tests: %s ran, %s failed.' % (summary.get('testsRan'), summary.get('failing')))
            for test in failures[:20]:
                print('      %s: %s' % (test.get('FullName'), (test.get('Message') or '').strip()[:240]))
        else:
            print('PASS  Tests: %s ran, all passed.' % summary.get('testsRan'))
        if summary:
            covered, lines = capability_coverage(kit, name, reply.get('result') or {})
            print('\n'.join(lines))
            if not covered:
                failed.append('coverage')
    record(org, 'verify-' + name, 'passed' if not failed else 'failed: ' + ', '.join(failed))
    if failed:
        raise SetupError('Verification of "%s" failed: %s.' % (entry['label'], ', '.join(failed)))
    print('Everything checked out for "%s".' % entry['label'])


def run():
    parser = argparse.ArgumentParser(description='Check an Antsurance install.')
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--capability', metavar='PART', help='Check one part of the app and what it needs, not the whole app. deploy_phase.py --list names the parts.')
    parser.add_argument('--skip-tests', action='store_true', help='Skip the Apex tests and the coverage gate (they take 10 to 20 minutes)')
    parser.add_argument('--open', action='store_true', help='Open the app in your browser at the end')
    parser.add_argument('--wait', type=int, default=45)
    args = parser.parse_args()

    org = describe_org(args.target_org)
    alias = args.target_org
    if args.capability:
        verify_capability(org, args)
        return
    ours = manifest()['ours']
    print('Target org: %s (%s). Checking the install. This changes nothing.' % (alias, org['name']))
    failed = []

    ok, apps = tooling(alias, "SELECT Id FROM CustomApplication WHERE DeveloperName = 'Antsurance' AND NamespacePrefix = null")
    app_ids = [row['Id'] for row in apps] if ok else []
    answers = batch(alias, [
        ('classes', soql("SELECT COUNT() FROM ApexClass WHERE NamespacePrefix = null AND Name LIKE 'Antsurance%'")),
        ('sets', soql('SELECT Name FROM PermissionSet WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(ours['permissionSets']))),
        ('mine', soql("SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE Assignee.Username = '%s' AND PermissionSet.Name IN (%s)" % (org['username'].replace("'", "\\'"), in_list(ours['permissionSets'])))),
        ('people', soql("SELECT COUNT_DISTINCT(AssigneeId) people FROM PermissionSetAssignment WHERE PermissionSet.Name = 'Antsurance_CRM' AND PermissionSet.NamespacePrefix = null")),
        ('profileTabs', soql('SELECT Name, Parent.Profile.Name FROM PermissionSetTabSetting WHERE Parent.IsOwnedByProfile = true AND Name IN (%s)' % in_list(ours['tabs']))),
        ('profileApp', soql("SELECT Parent.Profile.Name FROM SetupEntityAccess WHERE Parent.IsOwnedByProfile = true AND Parent.Profile.PermissionsModifyAllData = false AND SetupEntityType = 'TabSet' AND SetupEntityId IN (%s)" % in_list(app_ids))),
        ('profileObjects', soql('SELECT SobjectType, Parent.Profile.Name FROM ObjectPermissions WHERE Parent.IsOwnedByProfile = true AND PermissionsRead = true AND Parent.Profile.PermissionsModifyAllData = false AND Parent.Profile.PermissionsViewAllData = false AND SobjectType IN (%s)' % in_list([name for name in ours['customObjects'] if name.endswith('__c')]))),
        ('app', soql("SELECT DurableId FROM AppDefinition WHERE DeveloperName = 'Antsurance' AND NamespacePrefix = null")),
    ])

    refused = sorted(name for name, (ok, _) in answers.items() if not ok)
    if refused:
        failed.append('unanswered checks')
        print('FAIL  The org would not answer these checks, so they are unknown, not passed: ' + ', '.join(refused))
    found = (answers['classes'][1] or {}).get('totalSize', 0) if answers['classes'][0] else 0
    wanted = len(ours['apexClasses'])
    if found >= wanted:
        print('PASS  Code: all %d classes are in the org.' % wanted)
    else:
        failed.append('code')
        print('FAIL  Code: %d of %d classes are in the org. The core install has not finished.' % (found, wanted))

    have_sets = {row['Name'] for row in records(answers['sets'])}
    mine = {(row.get('PermissionSet') or {}).get('Name') for row in records(answers['mine'])}
    if {'Antsurance_CRM', 'Antsurance_Claude'} <= mine:
        people = (records(answers['people']) or [{}])[0].get('people')
        print('PASS  Your access: you hold %s. People with access in all: %s.' % (', '.join(sorted(mine)), people))
    else:
        failed.append('access')
        print('FAIL  Your access: you do not hold Antsurance CRM and Antsurance Claude (%d of our sets exist). Run assign_access.py --only-me --yes.' % len(have_sets))

    leaks = []
    leaks += ['tab %s on profile %s' % (row['Name'], ((row.get('Parent') or {}).get('Profile') or {}).get('Name')) for row in records(answers['profileTabs'])]
    leaks += ['the app on profile %s' % ((row.get('Parent') or {}).get('Profile') or {}).get('Name') for row in records(answers['profileApp'])]
    leaks += ['object %s on profile %s' % (row['SobjectType'], ((row.get('Parent') or {}).get('Profile') or {}).get('Name')) for row in records(answers['profileObjects'])]
    if leaks:
        failed.append('profiles')
        print('FAIL  Profiles: access to our things was found on a profile, which this install never grants: ' + '; '.join(leaks[:8]))
        print('      Someone gave it by hand, or it is left from an earlier install. People on that profile can see it without a permission set.')
    else:
        print('PASS  Profiles: no profile grants our app, tabs or objects. Access comes only from our permission sets.')
        print('      (Profiles that can already see or change all data, such as System Administrator, are not counted: they see everything.)')

    # Optional, so never a failure: says which way coverage can be checked on a claim.
    try:
        from setup_coverage_agent import standing
        _, agent_ready = standing(alias)
        print('INFO  Coverage agent on Claude Managed Agents: %s' % ('set up.' if agent_ready else 'not set up (optional). The coverage card offers "Check coverage" only. To add it: setup_coverage_agent.py.'))
    except SetupError:
        print('INFO  Coverage agent on Claude Managed Agents: could not be read.')

    if args.skip_tests:
        print('SKIP  Tests: not run, so coverage was not measured here. The core deploy runs the same tests, and Salesforce refuses it under %d percent for any class or trigger in it.' % COVERAGE_FLOOR)
    else:
        classes = list(ours['apexTestClasses'])
        # The portal's tests run too when the portal is in the org.
        portal_tests = ours.get('portalTestClasses') or []
        portal_in_org = False
        if portal_tests:
            there = batch(alias, [('portal', soql('SELECT Name FROM ApexClass WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(portal_tests)))])
            found_tests = sorted(row['Name'] for row in records(there['portal']))
            portal_in_org = bool(found_tests)
            classes += found_tests
        print('Running %d test classes with code coverage. This takes 10 to 20 minutes.' % len(classes))
        summary, failures, reply = run_tests(alias, classes, args.wait)
        if not summary:
            failed.append('tests')
            print('FAIL  Tests: the run did not finish: %s' % str(reply.get('message'))[:300])
        elif failures or str(summary.get('outcome')).lower() != 'passed':
            failed.append('tests')
            print('FAIL  Tests: %s ran, %s failed.' % (summary.get('testsRan'), summary.get('failing')))
            for test in failures[:20]:
                print('      %s: %s' % (test.get('FullName'), (test.get('Message') or '').strip()[:240]))
        else:
            print('PASS  Tests: %s ran, all passed.' % summary.get('testsRan'))
        if summary:
            # Measured even when a test failed: the figures say where the gaps are either way.
            covered, lines = our_coverage(reply.get('result') or {}, ours, portal_in_org)
            print('\n'.join(lines))
            if not covered:
                failed.append('coverage')

    path = '/lightning/app/c__Antsurance'
    if args.open:
        # Plain `sf org open` signs the browser in without printing a login link anywhere.
        import subprocess
        done = subprocess.run(['sf', 'org', 'open', '--target-org', alias, '--path', path], cwd=KIT_ROOT)
        print('Opened the app in your browser.' if done.returncode == 0 else 'Could not open a browser. Open it yourself: sf org open --target-org %s --path %s' % (alias, path))
    else:
        print('The app: %s%s  (or: sf org open --target-org %s --path %s)' % (org['instanceUrl'] or '', path, alias, path))

    record(org, 'verify', 'passed' if not failed else 'failed: ' + ', '.join(failed))
    if failed:
        raise SetupError('Verification failed: ' + ', '.join(failed) + '.')
    print('Everything checked out.')


if __name__ == '__main__':
    main(run)
