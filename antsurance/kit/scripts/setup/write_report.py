#!/usr/bin/env python3
"""Writes install-report.md: what was installed where, which choices were made, and how to undo it.

It reads the notes the other scripts kept in .install/ and asks the org nothing new.
Record the answers to the install questions first, so a later run or an uninstall knows what was chosen:
  python3 scripts/setup/write_report.py --target-org <alias> --answer where=sandbox --answer access=only-me

Usage: python3 scripts/setup/write_report.py --target-org <alias>
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import KIT_ROOT, describe_org, kind_of, load_state, main, now, save_state  # noqa: E402

ORDER = ['prerequisites', 'value-sets', 'core-model', 'core', 'access', 'claude-key', 'claude-smoke-test', 'coverage-agent', 'look-and-feel', 'demo-data', 'demo-prep', 'portal', 'verify']
TITLES = {
    'prerequisites': 'Switches turned on', 'value-sets': 'Picklist values added', 'core-model': 'Data model and permission sets', 'core': 'Core install', 'access': 'Access',
    'claude-key': 'Claude API key', 'claude-smoke-test': 'Claude answered from the org', 'look-and-feel': 'Look and feel (optional)',
    'demo-data': 'Sample records (optional)', 'portal': 'Customer portal (optional)', 'verify': 'Verification',
    'coverage-agent': 'Coverage agent on Claude Managed Agents (optional)', 'demo-prep': 'Showcase claims prepared (with the sample records)',
}
QUESTIONS = {
    'where': 'Where to install', 'access': 'Who gets access to start', 'demoData': 'Load sample records', 'lookAndFeel': 'Apply the look and feel',
    'portal': 'Set up the customer portal', 'clashes': 'How to handle clashes', 'enable': 'Switches to turn on',
    'coverageAgent': 'Set up the coverage agent on Claude Managed Agents',
    # The scratch script records this when a run was carried on with --leave-out-failed.
    'leftOut': 'Left out after it failed, because the person said to carry on without it',
}
# What the scratch script can leave out: the words for it, and the note another script keeps once it is done after all.
LEFT_OUT = {
    'portal': ('the customer portal (step 9)', 'portal', 'deployed'),
    'claude': ('connecting Claude (step 10); nothing that asks Claude works until a key is stored', 'claude-smoke-test', 'answered'),
    'claude-work-on-showcase-claims': ("Claude's work on the showcase claims (step 11)", 'demo-prep', 'prepared'),
    'coverage-agent': ('the coverage agent on Claude Managed Agents (step 12)', 'coverage-agent', 'set up'),
}


def settle_left_out(state):
    """Drops the "left out" answer once the step it names was done later, so the report never says both."""
    answer = state['answers'].get('leftOut') or {}
    _, phase, done = LEFT_OUT.get(answer.get('answer'), (None, None, None))
    entry = state['phases'].get(phase) or {}
    # Times are kept to the minute. Only a later minute counts: the step may have failed in the minute it was left out.
    if entry.get('outcome') == done and entry.get('at', '') > answer.get('at', ''):
        del state['answers']['leftOut']


def answer_line(key, value):
    said = value.get('answer')
    if key == 'leftOut':
        said = LEFT_OUT.get(said, (said,))[0]
    return '- %s: %s (%s).' % (QUESTIONS.get(key, key), said, value.get('at'))


def run():
    parser = argparse.ArgumentParser(description='Write the install report.')
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--answer', action='append', default=[], metavar='KEY=VALUE', help='Record an answer the person gave. Keys: ' + ', '.join(QUESTIONS))
    args = parser.parse_args()

    org = describe_org(args.target_org)
    state = load_state(org)
    for pair in args.answer:
        key, _, value = pair.partition('=')
        state['answers'][key.strip()] = {'answer': value.strip(), 'at': now()}
    settle_left_out(state)
    save_state(org, state)

    verdict = None
    report_path = os.path.join(KIT_ROOT, 'setup-report.json')
    if os.path.exists(report_path):
        with open(report_path) as handle:
            analysis = json.load(handle)
        if (analysis.get('facts', {}).get('org') or {}).get('orgId') == org['orgId']:
            verdict = analysis.get('verdict')

    lines = ['# Antsurance install report', '',
             'Org: %s (%s), org id %s. Installed by %s. Written %s.' % (org['name'], kind_of(org), org['orgId'], org['username'], now()), '']
    if verdict:
        lines += ['Analysis before installing: **%s** (see setup-report.md).' % verdict, '']
    lines += ['## What was done', '']
    for phase in ORDER:
        entry = state['phases'].get(phase)
        if entry is None:
            lines.append('- %s: not done.' % TITLES[phase])
            continue
        detail = entry.get('detail')
        extra = ''
        if isinstance(detail, dict):
            shown = []
            for key, value in sorted(detail.items()):
                if isinstance(value, dict) and 'added' in value:
                    # A picklist: what was added to it.
                    shown.append('%s: %s' % (key, 'added ' + ', '.join(value['added']) if value['added'] else 'nothing to add'))
                elif isinstance(value, (list, tuple)):
                    if value:
                        shown.append('%s: %s' % (key, ', '.join(str(one) for one in value)))
                elif value not in (None, '', {}):
                    shown.append('%s: %s' % (key, value))
            extra = ' (' + '; '.join(shown) + ')' if shown else ''
        elif detail:
            extra = ' (' + str(detail) + ')'
        lines.append('- %s: %s, %s%s.' % (TITLES[phase], entry.get('outcome'), entry.get('at'), extra))
    lines += ['', '## Choices made', '']
    if state['answers']:
        for key, value in sorted(state['answers'].items()):
            lines.append(answer_line(key, value))
    else:
        lines.append('- None recorded.')
    access = state.get('access') or {}
    lines += ['', '## Who has access', '']
    if access:
        lines.append('- Mode: %s. People: %s.' % (access.get('mode'), ', '.join(access.get('people', [])) or 'none'))
        lines.append('- Desk: %s.' % (', '.join(access.get('desk', [])) or 'nobody'))
        lines.append('- No profile was edited. Access comes from the permission sets Antsurance CRM, Antsurance Claude and Antsurance Desk.')
    else:
        lines.append('- Nobody yet. Run: python3 scripts/setup/assign_access.py --target-org %s --only-me --yes' % args.target_org)
    lines += ['', '## To give more people access', '', '    python3 scripts/setup/assign_access.py --target-org %s --propose' % args.target_org,
              '', '## To remove everything', '', '    python3 scripts/setup/uninstall.py --target-org %s' % args.target_org,
              '', 'That shows what would be removed and changes nothing until you add --yes.', '']
    path = os.path.join(KIT_ROOT, 'install-report.md')
    with open(path, 'w') as handle:
        handle.write('\n'.join(lines))
    print('Wrote ' + path)


if __name__ == '__main__':
    main(run)
