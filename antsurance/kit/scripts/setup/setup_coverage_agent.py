#!/usr/bin/env python3
"""Sets up the claims coverage agent on Claude Managed Agents. Optional.

The app checks coverage on a claim with one Claude call ("Check coverage"). The coverage agent is a second way:
an agent that Anthropic runs for you, which reads the claim, the policy, the file notes, the documents and the
photo assessment step by step, with its tools running in your org as the person who pressed the button.

Setting it up creates three things in YOUR Anthropic workspace, the one your Claude API key belongs to:
  an agent        "Antsurance claims coverage agent (Salesforce)"
  an environment  "antsurance-crm-coverage"
  a skill         "antsurance-coverage" (the method; the same text is in skills/antsurance-coverage/SKILL.md)
and keeps their ids in the org, in the Antsurance Coverage Agent custom setting. The ids are not secrets.

It needs the Claude API key stored first (set_api_key.py), and a key whose workspace has Claude Managed Agents.
If the key cannot use Managed Agents, this stops with what the API said and changes nothing; the coverage card
then simply does not offer the agent. Each investigation is billed to your key: about 10 cents and under a
minute in our runs, and capped at one dollar a session (change the cap in the same custom setting).

Nothing here ever archives or deletes anything in your Anthropic workspace. Archiving there is permanent, so
that is yours to do in the Claude Console if you remove the app.

Usage:
  python3 scripts/setup/setup_coverage_agent.py --target-org <alias>          (says whether it is set up; changes nothing)
  python3 scripts/setup/setup_coverage_agent.py --target-org <alias> --yes    (sets it up; safe to run again)
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import SetupError, announce, batch, debug_line, describe_org, guard_production, main, record, records, sf, soql  # noqa: E402

SETUP = """
try {
    String said = AntsuranceCoverageAgentSetup.run();
    System.debug(LoggingLevel.ERROR, 'AGENT|ok|' + said.replace('\\n', ' ~ '));
} catch (Exception problem) {
    System.debug(LoggingLevel.ERROR, 'AGENT|no|' + problem.getMessage().replace('\\n', ' '));
}
"""


def standing(org):
    """(app installed, set up) read from the org's custom setting. Changes nothing."""
    answers = batch(org, [('setting', soql('SELECT Agent_Id__c, Environment_Id__c, SetupOwnerId FROM Antsurance_Coverage_Agent__c'))])
    if not answers['setting'][0]:
        return False, False
    # The ids are kept once for the whole org: the row owned by the org itself (its id starts 00D).
    rows = [row for row in records(answers['setting']) if str(row.get('SetupOwnerId', '')).startswith('00D')]
    return True, bool(rows and rows[0].get('Agent_Id__c') and rows[0].get('Environment_Id__c'))


def run():
    parser = argparse.ArgumentParser(description='Set up the claims coverage agent on Claude Managed Agents (optional).')
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--yes', action='store_true', help='Set it up. Without it, only says whether it is set up.')
    parser.add_argument('--allow-production', action='store_true', help='Only when the org owner has asked for a production install.')
    args = parser.parse_args()

    org = describe_org(args.target_org)
    alias = args.target_org
    announce(org, 'set up the coverage agent: create an agent, an environment and a skill in your Anthropic workspace and keep their ids in this org'
             if args.yes else 'check whether the coverage agent is set up (nothing changes)')

    installed, ready = standing(alias)
    if not installed:
        raise SetupError('The Antsurance app is not in this org yet, so there is nothing to set the agent up for. Run the core install first.')
    if not args.yes:
        if ready:
            print('The coverage agent is set up. A claim\'s coverage card offers "Investigate with the coverage agent".')
        else:
            print('The coverage agent is not set up. The coverage card offers "Check coverage" only, and everything else works as it is.')
            print('To set it up (it creates an agent, an environment and a skill in your Anthropic workspace, and each investigation is billed to your key):')
            print('  python3 scripts/setup/setup_coverage_agent.py --target-org %s --yes' % alias)
        print('Nothing was changed.')
        return

    guard_production(org, args.allow_production)
    reply = sf(['apex', 'run', '--target-org', alias], stdin=SETUP, allow_failure=True, timeout=600)
    result = reply.get('result') or {}
    if not result.get('compiled', False):
        raise SetupError('Could not set up the coverage agent: the org would not compile the request (%s). Has the core install finished?' % (result.get('compileProblem') or reply.get('message')))
    if not result.get('success', False):
        raise SetupError('Could not set up the coverage agent: %s' % (result.get('exceptionMessage') or 'the org reported a failure'))
    said = debug_line(result.get('logs'), 'AGENT|')
    if said is None:
        raise SetupError('The setup ran but its answer was not in the log. Run this again without --yes to see whether it is set up.')
    outcome, _, text = said.partition('|')
    if outcome != 'ok':
        text = text.strip()
        text += '' if text.endswith(('.', '!', '?', '}')) else '.'
        record(org, 'coverage-agent', 'not set up: ' + text[:200])
        # A key the API does not know at all is a different fix from a good key without Managed Agents.
        refused = 'authentication_error' in text or 'invalid x-api-key' in text
        advice = ('The key stored in the org was refused, so this is about the key, not about Managed Agents: store a working key with set_api_key.py, pass smoke_test.py, then run this again.'
                  if refused else 'If the key works for the rest of the app, its Anthropic workspace does not have Claude Managed Agents yet.')
        raise SetupError('The coverage agent was not set up. %s\n  What the org reported: %s\n  Nothing was changed, and the rest of the app works without the agent: claims keep "Check coverage".' % (advice, text))
    for line in text.split(' ~ '):
        if line.strip():
            print('  ' + line.strip())
    _, ready = standing(alias)
    if not ready:
        record(org, 'coverage-agent', 'ran, but the ids were not kept')
        raise SetupError('The setup ran, but the org did not keep the agent\'s ids. Run this again.')
    record(org, 'coverage-agent', 'set up')
    print('The coverage agent is set up. Open a claim: its coverage card now offers "Investigate with the coverage agent".')
    print('Give people who should run it the Antsurance CRM permission set, as for the rest of the app.')


if __name__ == '__main__':
    main(run)
