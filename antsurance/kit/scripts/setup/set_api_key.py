#!/usr/bin/env python3
"""Puts your Claude API key into the org's Anthropic credential.

The key is typed at a hidden prompt, or read from an environment variable you name. It goes straight to
the org over the Salesforce CLI's own connection. It is never printed, never written to a file, never put
on a command line, and this script keeps no copy.

Usage:
  python3 scripts/setup/set_api_key.py --target-org <alias>                     (hidden prompt)
  python3 scripts/setup/set_api_key.py --target-org <alias> --from-env MY_VAR   (reads $MY_VAR)
  python3 scripts/setup/set_api_key.py --target-org <alias> --check             (says whether a key is stored)

Run it yourself in a terminal. Do not paste the key into a chat with Claude Code.
To do the same by hand in Setup, see .claude/skills/antsurance-install/references/api-key-by-hand.md
"""
import argparse
import getpass
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import SetupError, announce, api_version, describe_org, guard_production, main, record, rest  # noqa: E402

EXTERNAL_CREDENTIAL = 'Anthropic'
PRINCIPAL = 'ApiUser'
PARAMETER = 'ApiKey'


def credential_path():
    return '/services/data/v%s/named-credentials/credential' % api_version()


def stored(org, request=rest):
    """True when the principal already holds a value for the key. The value itself is never returned by the org."""
    query = urllib.parse.urlencode({'externalCredential': EXTERNAL_CREDENTIAL, 'principalName': PRINCIPAL, 'principalType': 'NamedPrincipal'})
    reply = request(org, credential_path() + '?' + query)
    return PARAMETER in ((reply or {}).get('credentials') or {})


def read_key(env_name, prompt=getpass.getpass, environ=os.environ):
    if env_name:
        key = environ.get(env_name, '')
        if not key:
            raise SetupError('The environment variable %s is empty or not set.' % env_name)
    else:
        if not sys.stdin.isatty():
            raise SetupError('No terminal to type the key into. Run this yourself in a terminal, or name an environment variable with --from-env.')
        key = prompt('Claude API key (typing is hidden): ')
    key = key.strip()
    if not key:
        raise SetupError('No key was entered. Nothing was changed.')
    if any(character.isspace() for character in key):
        raise SetupError('That does not look like a key: it has a space or a line break in it. Nothing was changed.')
    return key


def store(org, key, request=rest):
    """Sends the key to the org. Creates the stored value, or replaces the one that is there."""
    body = {
        'externalCredential': EXTERNAL_CREDENTIAL, 'principalName': PRINCIPAL, 'principalType': 'NamedPrincipal', 'authenticationProtocol': 'Custom',
        'credentials': {PARAMETER: {'value': key, 'encrypted': True}},
    }
    method = 'PUT' if stored(org, request) else 'POST'
    reply = request(org, credential_path(), method, body)
    problem = error_of(reply)
    if problem:
        # The org's message is passed on, with the key cut out in case the org echoed it.
        raise SetupError('The org did not accept the key: ' + problem.replace(key, '[key]'))
    return method


def error_of(reply):
    if isinstance(reply, list) and reply and isinstance(reply[0], dict) and reply[0].get('errorCode'):
        return '%s: %s' % (reply[0].get('errorCode'), reply[0].get('message'))
    if isinstance(reply, dict) and reply.get('errorCode'):
        return '%s: %s' % (reply.get('errorCode'), reply.get('message'))
    return None


def run():
    parser = argparse.ArgumentParser(description="Store your Claude API key in the org's Anthropic credential.")
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--from-env', metavar='NAME', help='Read the key from this environment variable instead of prompting')
    parser.add_argument('--check', action='store_true', help='Only say whether a key is stored. Changes nothing.')
    parser.add_argument('--allow-production', action='store_true')
    args = parser.parse_args()

    org = describe_org(args.target_org)
    if args.check:
        print('Target org: %s (%s)' % (org['alias'], org['name']))
        print('A key is stored.' if stored(args.target_org) else 'No key is stored yet.')
        return
    announce(org, 'store your Claude API key in the "%s" credential (principal %s). The key is not shown or saved anywhere else.' % (EXTERNAL_CREDENTIAL, PRINCIPAL))
    guard_production(org, args.allow_production)
    key = read_key(args.from_env)
    try:
        how = store(args.target_org, key)
    finally:
        key = None
    record(org, 'claude-key', 'stored', 'replaced the stored key' if how == 'PUT' else 'stored a key for the first time')
    print('Done. The key is stored in the org. Next: python3 scripts/setup/smoke_test.py --target-org ' + args.target_org)


if __name__ == '__main__':
    main(run)
