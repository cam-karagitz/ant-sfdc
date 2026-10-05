#!/usr/bin/env python3
"""Checks what kit/scripts/setup/uninstall.py decides, without an org: no sf command runs.

The org is replaced by a stand-in that answers the counting questions, and the first step that would change
anything is replaced by a stop. So this shows, for each case, what the plan prints about records and settings and
whether the uninstall stops, returns after a dry run, or goes on to remove.

It reads the uninstall from the working tree. The manifest and the steps are stand-ins too, because the real ones
are written by the kit build: the manifest here says which objects are custom settings, as the built one does.

Usage: python3 scripts/kit_checks/uninstall_offline.py [-v]
"""
import contextlib
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', '..', 'kit', 'scripts', 'setup'))
import uninstall  # noqa: E402

VERBOSE = '-v' in sys.argv[1:]
ORG = {'alias': 'stand-in', 'name': 'Stand-in', 'username': 'someone@example.invalid', 'orgId': '00D000000000000', 'isProduction': False,
       'isScratch': True, 'isSandbox': False, 'isDeveloperEdition': False}
OURS = {'customObjects': ['Antsurance_AI_Setting__mdt', 'Antsurance_Coverage_Agent__c', 'Claude_Autonomy__c', 'Claude_Work__c', 'File_Note__c', 'Policy__c'],
        'customSettings': ['Antsurance_Coverage_Agent__c', 'Claude_Autonomy__c'], 'permissionSets': [], 'groups': [], 'flows': []}
STEPS = {'steps': [{'name': 'Our own objects and files', 'types': {'CustomObject': OURS['customObjects']}}], 'stays': ['Record types (stand-in line)']}
AGENT = {'Antsurance_Coverage_Agent__c': 1}
BUSINESS = {'Policy__c': 149, 'Case': 86, 'Account': 69}
SETTINGS_LINE = "The app's own settings, which go with the app: 1 row in Antsurance_Coverage_Agent__c"
RECORDS_LINE = 'Records that exist only because of this app: 69 Account, 86 Case, 149 Policy__c'
failed = []


class Reached(Exception):
    """The uninstall got as far as its first changing step."""


def decide(totals, argv, ours=OURS):
    def ask(org, requests):
        return {name: (True, {'totalSize': totals.get(name, 0)}) for name, _ in requests}

    def removing(*_):
        raise Reached()
    uninstall.describe_org = lambda alias: ORG
    uninstall.manifest = lambda: {'ours': ours}
    uninstall.steps = lambda: STEPS
    uninstall.batch = ask
    uninstall.our_records.__defaults__ = (ask,)
    uninstall.remove_access = removing
    sys.argv = ['uninstall.py', '--target-org', 'stand-in'] + argv
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            uninstall.run()
        verdict = 'dry run'
    except Reached:
        verdict = 'goes on to remove'
    except uninstall.SetupError as problem:
        verdict = 'stops: ' + str(problem)
    return verdict, out.getvalue().splitlines()


def case(label, totals, argv, verdict, lines=(), absent=(), ours=OURS):
    got, printed = decide(totals, argv, ours)
    problems = []
    if not got.startswith(verdict):
        problems.append('expected "%s", got "%s"' % (verdict, got))
    problems += ['missing line: ' + line for line in lines if line not in printed]
    problems += ['unexpected line starting: ' + start for start in absent if any(line.startswith(start) for line in printed)]
    if VERBOSE or problems:
        print('=== %s: uninstall.py --target-org stand-in %s' % (label, ' '.join(argv)))
        for line in printed:
            if line.startswith(('Records that', 'No records', "The app's own settings", 'Dry run')):
                print('    | ' + line)
        print('    -> ' + got)
    for problem in problems:
        print('FAILED  %s: %s' % (label, problem))
    if problems:
        failed.append(label)


STOP = 'stops: The org holds records that would be deleted along with our objects. Nothing was changed.'
case('1 agent set up, no business records, dry run', AGENT, [], 'dry run', ['No records depend on this app.', SETTINGS_LINE], ['Records that'])
case('2 agent set up, no business records, --yes', AGENT, ['--yes'], 'goes on to remove', ['No records depend on this app.', SETTINGS_LINE])
case('3 agent set up and business records, dry run', dict(AGENT, **BUSINESS), [], 'dry run', [RECORDS_LINE, SETTINGS_LINE], ['No records'])
case('4 agent set up and business records, --yes', dict(AGENT, **BUSINESS), ['--yes'], STOP, [RECORDS_LINE, SETTINGS_LINE])
case('5 agent set up and business records, --yes --delete-our-records', dict(AGENT, **BUSINESS), ['--yes', '--delete-our-records'], 'goes on to remove', [RECORDS_LINE, SETTINGS_LINE])
case('6 nothing at all, --yes', {}, ['--yes'], 'goes on to remove', ['No records depend on this app.'], ["The app's own settings"])
case('7 a kit whose manifest does not name the settings stays careful, --yes', AGENT, ['--yes'], STOP,
     ['Records that exist only because of this app: 1 Antsurance_Coverage_Agent__c'], ["The app's own settings"], ours={key: value for key, value in OURS.items() if key != 'customSettings'})

print('uninstall decisions: 7 cases, %d failed' % len(failed))
sys.exit(1 if failed else 0)
