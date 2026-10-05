#!/usr/bin/env python3
"""Loads the sample book of business: about 2,100 invented customers, policies, claims, quotes and tasks.

It only ever adds records. It never deletes or changes a record that is already in the org.
Every sample household lives on an invented street, and every person, policy and claim is made up.

It refuses to run:
  in a production org, always;
  in an org that already holds customer, case, sale or lead records, unless you pass --into-org-with-records
  (the sample records would be mixed in with yours). A scratch org is exempt: it is a throwaway, and the few
  records in a new one are Salesforce's own samples. A new Developer Edition org also comes with Salesforce's
  samples; there the script stops and tells you, and you decide;
  when the org does not have room for it.

Without --yes it only says what it would do.

Usage: python3 scripts/setup/load_demo_data.py --target-org <alias> --yes
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import SetupError, announce, api_version, batch, debug_line, describe_org, main, manifest, record, records, rest, sf, soql  # noqa: E402

COUNTED = ['Account', 'Contact', 'Case', 'Opportunity', 'Lead']
LOAD = """
AntsuranceDemoData.load();
Integer flagged = AntsuranceRenewalJob.flagUpcomingRenewals();
System.debug(LoggingLevel.ERROR, 'DEMO|loaded|' + [SELECT COUNT() FROM Account] + ' customers, ' + [SELECT COUNT() FROM Policy__c] + ' policies, ' + [SELECT COUNT() FROM Case] + ' claims and requests');
"""
ATTACH = """
AntsuranceClaimsAssistantDemo.attachSampleDocuments();
AntsuranceClaimsAssistantPhotos.attachSamplePhotos();
System.debug(LoggingLevel.ERROR, 'DEMO|attached|sample claim documents and photos');
"""


def apex(org, body, what):
    reply = sf(['apex', 'run', '--target-org', org], stdin=body, allow_failure=True, timeout=900)
    result = reply.get('result') or {}
    if not result.get('compiled', False):
        raise SetupError('Could not %s: the org would not compile the request (%s). Has the core install finished?' % (what, result.get('compileProblem') or reply.get('message')))
    if not result.get('success', False):
        raise SetupError('Could not %s: %s' % (what, result.get('exceptionMessage') or 'the org reported a failure'))
    found = debug_line(result.get('logs'), 'DEMO|')
    return found.split('|', 1)[1] if found and '|' in found else 'done'


def refresh_dashboards(org):
    folders = manifest()['ours'].get('dashboardFolderLabels', [])
    if not folders:
        return 0
    answers = batch(org, [('dashboards', soql('SELECT Id FROM Dashboard WHERE FolderName IN (%s)' % ','.join("'%s'" % name.replace("'", "\\'") for name in folders)))])
    refreshed = 0
    for row in records(answers['dashboards']):
        rest(org, '/services/data/v%s/analytics/dashboards/%s' % (api_version(), row['Id']), 'PUT', {})
        refreshed += 1
    return refreshed


def run():
    parser = argparse.ArgumentParser(description='Load the sample records. Adds only; never deletes.')
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--yes', action='store_true', help='Load. Without it, only the plan is shown.')
    parser.add_argument('--into-org-with-records', action='store_true', help='Allow loading beside records the org already holds. Only when the org owner asks.')
    args = parser.parse_args()

    org = describe_org(args.target_org)
    alias = args.target_org
    announce(org, 'add about %s sample records' % manifest().get('demoData', {}).get('records', '2,100') if args.yes else 'check whether the sample records can be loaded (nothing changes)')
    if org['isProduction']:
        raise SetupError('This is a production org. Sample records are never loaded into production. Use a scratch org or a sandbox.')

    asks = [('count' + name, soql('SELECT COUNT() FROM ' + name)) for name in COUNTED] + [('policies', soql('SELECT COUNT() FROM Policy__c')), ('limits', 'limits')]
    answers = batch(alias, asks)
    if not answers['policies'][0]:
        raise SetupError('The Antsurance data model is not in this org yet. Run the core install first.')
    counts = {name: (answers['count' + name][1] or {}).get('totalSize', 0) for name in COUNTED}
    policies = (answers['policies'][1] or {}).get('totalSize', 0)
    busy = {name: count for name, count in counts.items() if count}
    if policies and not args.into_org_with_records:
        raise SetupError('This org already has %d policies, so the sample records look loaded already. Loading again would double them. Nothing was changed.' % policies)
    # A scratch org is a throwaway. The handful of records it holds are Salesforce's own samples.
    if busy and not args.into_org_with_records and not org['isScratch']:
        raise SetupError('This org already holds records (%s). Loading would mix about 2,100 sample records in with them. Nothing was changed. '
                         'Try the sample records in a scratch org instead, or pass --into-org-with-records if the org owner has asked for exactly that.'
                         % ', '.join('%s %s' % (count, name) for name, count in busy.items()))
    need = manifest().get('demoData', {}).get('dataStorageMB', 5)
    storage = ((answers['limits'][1] or {}).get('DataStorageMB') or {}) if answers['limits'][0] else {}
    if storage.get('Remaining') is not None and storage['Remaining'] < need:
        raise SetupError('The org has %s MB of data storage free and the sample records need about %s MB. Nothing was changed.' % (storage['Remaining'], need))
    if not busy:
        print('The org holds no records of its own and has room.')
    elif org['isScratch']:
        print('This scratch org holds a few sample records Salesforce put there (%s). They are left alone.' % ', '.join('%s %s' % (count, name) for name, count in busy.items()))
    else:
        print('Loading beside the records already here, as asked.')
    if not args.yes:
        print('Plan only. Nothing was changed. Run again with --yes to load.')
        return

    loaded = apex(alias, LOAD, 'load the sample records')
    print('Loaded: ' + loaded + '.')
    try:
        print('Attached: ' + apex(alias, ATTACH, 'attach the sample documents and photos') + '.')
    except SetupError as problem:
        print('WARNING: the records are loaded, but the sample documents and photos were not attached: %s' % problem)
    refreshed = refresh_dashboards(alias)
    print('Refreshed %d dashboard%s.' % (refreshed, '' if refreshed == 1 else 's'))
    record(org, 'demo-data', 'loaded', {'loaded': loaded, 'besideExistingRecords': bool(busy)})


if __name__ == '__main__':
    main(run)
