#!/usr/bin/env python3
"""Puts the showcase claims into the state the app is shown in, after the sample records are loaded.

A fresh load of the sample records has no files on its claims and nothing Claude has written yet. This step:
  1. attaches the sample documents and photos that are not on their claims yet;
  2. raises the burst pipe claim's estimate from its first figure to what its two documents add up to, with a
     file note from the adjuster;
  3. has Claude do its work on each showcase claim, one step per request: the photo assessment, a reading of each
     document, the coverage check, the claim analysis and the brief;
  4. prints what each showcase claim now says.

It is safe to run twice: a file, an estimate or a piece of Claude's work that is already there is left alone.
It only ever adds to the sample claims. It never clears or reloads records, and it refuses a production org.

Part 3 calls Claude about a dozen times on your key, so it needs the key stored first (set_api_key.py).
--without-claude does parts 1, 2 and 4 only, which need no key.

Usage:
  python3 scripts/setup/prepare_demo.py --target-org <alias> --check             (changes nothing, says what a run would do)
  python3 scripts/setup/prepare_demo.py --target-org <alias> --without-claude    (files and the estimate only)
  python3 scripts/setup/prepare_demo.py --target-org <alias>                     (everything)
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import SetupError, announce, debug_line, describe_org, main, record, sf  # noqa: E402

TRIES = 3
PAUSE_SECONDS = 15


def ask(org, expression, what):
    """Runs one Apex expression that returns something JSON can hold, and returns it."""
    body = "System.debug(LoggingLevel.ERROR, 'PREP|' + JSON.serialize(%s));\n" % expression
    reply = sf(['apex', 'run', '--target-org', org], stdin=body, allow_failure=True, timeout=600)
    result = reply.get('result') or {}
    if not result.get('compiled', False):
        raise SetupError('Could not %s: the org would not compile the request (%s). Has the core install finished?' % (what, result.get('compileProblem') or reply.get('message')))
    if not result.get('success', False):
        raise SetupError('Could not %s: %s' % (what, result.get('exceptionMessage') or 'the org reported a failure'))
    found = debug_line(result.get('logs'), 'PREP|')
    if found is None:
        raise SetupError('Could not %s: the run finished but its answer was not in the log.' % what)
    try:
        return json.loads(found)
    except ValueError:
        raise SetupError('Could not %s: the org sent back something unreadable.' % what)


def run():
    parser = argparse.ArgumentParser(description='Prepare the showcase claims after loading the sample records.')
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--check', action='store_true', help='Change nothing; say what a run would do.')
    parser.add_argument('--without-claude', action='store_true', help='Attach the files and settle the estimate only. Needs no Claude API key.')
    args = parser.parse_args()

    org = describe_org(args.target_org)
    alias = args.target_org
    announce(org, 'check the showcase claims (nothing changes)' if args.check else 'prepare the showcase claims: attach sample files, settle one estimate%s' % ('' if args.without_claude else ', and have Claude do its work on them'))
    if org['isProduction']:
        raise SetupError('This is a production org. The showcase claims are sample records, which are never loaded into production.')

    if args.check:
        for line in ask(alias, 'AntsuranceDemoPrep.check()', 'check the showcase claims'):
            print('  ' + line)
        print('Nothing was changed.')
        return

    print('Sample files and the burst pipe estimate:')
    for line in ask(alias, 'new List<String>{ AntsuranceDemoPrep.attach(), AntsuranceDemoPrep.settle() }', 'attach the sample files'):
        print('  ' + line)

    asked = 0
    if args.without_claude:
        print("Claude's work: left for later, as asked. Once the key is stored, run:")
        print('  python3 scripts/setup/prepare_demo.py --target-org %s' % alias)
    else:
        print("Claude's work:")
        for step in ask(alias, 'AntsuranceDemoPrep.steps()', "list Claude's work"):
            key, number, label = step.get('key'), step.get('caseNumber'), step.get('label')
            if step.get('done'):
                print('  %s: has %s.' % (number, label))
                continue
            for attempt in range(1, TRIES + 1):
                outcome = ask(alias, "AntsuranceDemoPrep.run('%s', false)" % str(key).replace("'", ''), 'run "%s"' % label)
                if outcome.get('ok'):
                    print('  %s: %s. %s' % (number, label, 'Already on the claim.' if outcome.get('skipped') else (outcome.get('line') or 'Done.')))
                    asked += 0 if outcome.get('skipped') else 1
                    break
                problem = (outcome.get('error') or 'It did not work.').strip()
                problem += '' if problem.endswith(('.', '!', '?')) else '.'
                if outcome.get('retryable') and attempt < TRIES:
                    print('  %s: %s did not finish (%s). Trying again in %d seconds ...' % (number, label, problem, PAUSE_SECONDS))
                    time.sleep(PAUSE_SECONDS)
                    continue
                record(org, 'demo-prep', 'stopped at: %s on %s' % (label, number))
                raise SetupError('%s on claim %s did not work%s: %s Everything before it is kept. Fix what it names and run this again; it carries on from here.'
                                 % (label[:1].upper() + label[1:], number, ' after %d tries' % TRIES if outcome.get('retryable') else '', problem))
        if not asked:
            print('  Claude was not asked for anything: it was all there.')

    print('What the showcase claims now say:')
    for line in ask(alias, 'AntsuranceDemoPrep.summary()', 'read the showcase claims'):
        print('  ' + line)
    record(org, 'demo-prep', 'files and estimate only' if args.without_claude else 'prepared', {'claudeSteps': asked})


if __name__ == '__main__':
    main(run)
