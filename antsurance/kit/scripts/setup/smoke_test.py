#!/usr/bin/env python3
"""Asks Claude one short question from inside the org, to prove the key and the connection work.

One call, a few words each way. It changes nothing in the org.

Usage: python3 scripts/setup/smoke_test.py --target-org <alias>
Exit code 0 when Claude answered, 1 when it did not, with the reason in plain words.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import SetupError, debug_line, describe_org, main, record, sf  # noqa: E402

APEX = """
String line;
try {
    AntsuranceAiClient.Question question = new AntsuranceAiClient.Question('Answer in three words or fewer.', 'Reply with the single word: ready');
    question.maxTokens = 64;
    AntsuranceAiClient.Answer answer = AntsuranceAiClient.ask(question);
    line = 'SMOKE|ok|' + AntsuranceAiSettings.model() + '|' + String.valueOf(answer.text).left(80);
} catch (AntsuranceAiClient.AiException problem) {
    line = 'SMOKE|' + problem.kind + '|' + AntsuranceAiSettings.model() + '|' + problem.getMessage().left(300);
} catch (Exception problem) {
    line = 'SMOKE|error|' + AntsuranceAiSettings.model() + '|' + problem.getTypeName() + ': ' + problem.getMessage().left(300);
}
System.debug(LoggingLevel.ERROR, line.replace('\\n', ' '));
"""

# What each kind of failure means and what to do, in plain words.
ADVICE = {
    'auth': 'The key was refused. Claude did not accept the API key stored in the org. Store a working key: python3 scripts/setup/set_api_key.py --target-org %(org)s',
    'rate_limited': 'The key works, but Claude is limiting how fast it can be used right now. Wait a minute and run this again.',
    'unavailable': 'Claude is temporarily unavailable. Nothing is wrong with your setup. Try again in a few minutes.',
    'timeout': 'Claude took too long to answer. Try again. If it keeps happening, check that api.anthropic.com is reachable from Salesforce.',
    'unreachable': 'The org could not reach Claude. Check that the "Anthropic API" named credential exists and that you have the "Antsurance Claude" permission set.',
    'other': 'Claude turned the request down. The usual cause is a model your Anthropic account does not have. Change the model in Setup, Custom Metadata Types, Antsurance AI Setting, Default.',
    'error': 'The org failed before it reached Claude. The usual causes: no key stored yet, or you are missing the "Antsurance Claude" permission set.',
}


def interpret(logs):
    """Finds the one result line in the Apex log. Returns (kind, model, detail), or None when it is not there."""
    found = debug_line(logs, 'SMOKE|')
    parts = found.split('|', 2) if found else []
    return (parts[0], parts[1], parts[2].strip()) if len(parts) == 3 else None


def explain(result, org):
    if result is None:
        return False, 'The test did not run to the end, so there is no answer to report. Check that the core install finished.'
    kind, model, detail = result
    if kind == 'ok':
        return True, 'Claude answered from the org (model %s): "%s"' % (model, detail)
    advice = ADVICE.get(kind, ADVICE['other']) % {'org': org}
    return False, '%s\n  Model: %s\n  What the org reported: %s' % (advice, model, detail)


def run():
    parser = argparse.ArgumentParser(description='Ask Claude one short question from inside the org.')
    parser.add_argument('--target-org', required=True)
    args = parser.parse_args()
    org = describe_org(args.target_org)
    print('Target org: %s (%s). Asking Claude one short question. This changes nothing.' % (org['alias'], org['name']))
    reply = sf(['apex', 'run', '--target-org', args.target_org], stdin=APEX, allow_failure=True)
    result = reply.get('result') or {}
    if result.get('compiled') is False:
        raise SetupError('The test could not compile in the org: %s. Has the core install finished?' % result.get('compileProblem'))
    ok, message = explain(interpret(result.get('logs')), args.target_org)
    record(org, 'claude-smoke-test', 'answered' if ok else 'did not answer', message.splitlines()[0])
    print(message)
    if not ok:
        sys.exit(1)


if __name__ == '__main__':
    main(run)
