#!/usr/bin/env python3
"""Gets a new scratch org ready for the install. Only ever runs against a scratch org.

A new scratch org with state and country picklists has its one user's country stored as text the picklist does not
know, so saving that user fails ("There's a problem with this country"). The app saves a note on the user record,
so this sets the user's country to the United States through the picklist. In a scratch org without those picklists
there is nothing to do, and it says so.

Usage: python3 scripts/setup/prepare_scratch_org.py --target-org <alias>
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import SetupError, announce, api_version, batch, describe_org, main, records, rest, soql  # noqa: E402


def run():
    parser = argparse.ArgumentParser(description='Get a new scratch org ready for the install.')
    parser.add_argument('--target-org', required=True)
    args = parser.parse_args()
    org = describe_org(args.target_org)
    announce(org, "set the scratch org user's country so the user record can be saved")
    if not org['isScratch']:
        raise SetupError('%s is not a scratch org. This step is only for scratch orgs and changed nothing.' % args.target_org)
    answers = batch(args.target_org, [('me', soql("SELECT Id, Country, CountryCode FROM User WHERE Username = '%s'" % org['username'].replace("'", "\\'")))])
    if not answers['me'][0]:
        # No CountryCode field: state and country picklists are off here, so the user record saves as it is.
        print('Nothing to do. State and country picklists are off in this scratch org, and the app stores states as text here.')
        return
    me = records(answers['me'])[0]
    reply = rest(args.target_org, '/services/data/v%s/sobjects/User/%s' % (api_version(), me['Id']), 'PATCH', {'CountryCode': 'US', 'StateCode': None})
    if isinstance(reply, list) and reply and reply[0].get('errorCode'):
        raise SetupError("Could not set the user's country: %s" % reply[0].get('message'))
    print("Done. The user's country is set to the United States.")


if __name__ == '__main__':
    main(run)
