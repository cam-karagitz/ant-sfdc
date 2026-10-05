#!/usr/bin/env python3
"""Removes Antsurance from an org, in the order Salesforce needs, and leaves everything else alone.

Without --yes it is a dry run: it lists what would be removed and what would stay, and changes nothing.

What it removes: our app, pages, tabs, buttons, flows, code, reports, dashboards, permission sets, our fields on
standard objects, our own objects, and the Claude credential (with the key stored in it).

What it cannot remove, because Salesforce does not allow it through its API (the dry run lists them, with the clicks):
  our record types on Account, Case and Opportunity (they are switched off instead);
  the picklist values the install added to five standard picklists;
  Quotes, Path or Digital Experiences if the install turned them on.

Records. Deleting our objects deletes the records in them, and our fields on standard objects lose their values.
If the org holds any such records, the uninstall stops unless you pass --delete-our-records, which deletes policies
and their details, and the claims, service requests, policy sales, customers and agencies that use our record types.
It never deletes a record of any other record type.

Settings. What the app keeps for itself in its own custom settings (the coverage agent's ids, the desk's switches) is
not anyone's business data. The dry run lists those rows, and they go with the app without --delete-our-records.

One part. With --capability PART it removes one part of the app and leaves what the other parts in the org need
(deploy_phase.py --list names the parts). It refuses to remove a part that another installed part is built on, and
names that part. The data model is the last to go: removing it is this uninstall, run on an org that holds nothing
else of ours.

Usage:
  python3 scripts/setup/uninstall.py --target-org <alias>                               (dry run)
  python3 scripts/setup/uninstall.py --target-org <alias> --yes [--delete-our-records]
  python3 scripts/setup/uninstall.py --target-org <alias> --capability automation       (dry run)
  python3 scripts/setup/uninstall.py --target-org <alias> --capability automation --yes
"""
import argparse
import json
import os
import re
import shutil
import sys
from xml.sax.saxutils import escape

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import KIT_ROOT, SetupError, announce, api_version, batch, debug_line, delete_ids, describe_org, guard_production, in_list, main, manifest, record, records, rest, sf, soql, tooling  # noqa: E402

STAGE = os.path.join(KIT_ROOT, 'stage')
OUR_RECORD_TYPES = {'Case': ['Claim', 'Policy_Service'], 'Opportunity': ['Policy_Sale'], 'Account': ['Household', 'Business', 'Agency']}
# Children before parents. Each line deletes up to 9,000 records and reports how many are left.
DELETE_RECORDS = """
Integer room = 9000;
Integer left = 0;
List<String> queries = new List<String>{
    'SELECT Id FROM Claude_Work__c',
    'SELECT Id FROM File_Note__c',
    'SELECT Id FROM Case WHERE RecordType.DeveloperName IN (\\'Claim\\', \\'Policy_Service\\')',
    'SELECT Id FROM Opportunity WHERE RecordType.DeveloperName = \\'Policy_Sale\\'',
    'SELECT Id FROM Policy__c',
    'SELECT Id FROM Account WHERE RecordType.DeveloperName IN (\\'Household\\', \\'Business\\')',
    'SELECT Id FROM Account WHERE RecordType.DeveloperName = \\'Agency\\''
};
for (String query : queries) {
    if (room <= 0) {
        left += Database.countQuery(query.replace('SELECT Id', 'SELECT COUNT()'));
        continue;
    }
    List<SObject> rows = Database.query(query + ' LIMIT ' + room);
    room -= rows.size();
    for (Database.DeleteResult result : Database.delete(rows, false)) {
        if (!result.isSuccess()) {
            left++;
        }
    }
    left += Database.countQuery(query.replace('SELECT Id', 'SELECT COUNT()'));
}
System.debug(LoggingLevel.ERROR, 'UNINSTALL|left|' + left);
"""


def steps():
    path = os.path.join(KIT_ROOT, 'uninstall', 'steps.json')
    if not os.path.exists(path):
        raise SetupError('uninstall/steps.json is missing from the kit.')
    with open(path) as handle:
        return json.load(handle)


def our_records(org, ours, ask=batch):
    """What the org holds that goes when the app goes: (records people made with the app, rows in the app's own settings).

    A custom setting holds what the app keeps for itself, such as the ids the coverage agent's setup wrote. Those rows
    are counted and shown, and removed with their object, but they are never a reason to stop and ask.
    """
    asks = [(name, soql('SELECT COUNT() FROM ' + name)) for name in ours['customObjects'] if name.endswith('__c')]
    for name, types in OUR_RECORD_TYPES.items():
        asks.append((name, soql('SELECT COUNT() FROM %s WHERE RecordType.DeveloperName IN (%s)' % (name, in_list(types)))))
    answers = ask(org, asks)
    found = {name: (answers[name][1] or {}).get('totalSize', 0) for name, _ in asks if answers[name][0] and (answers[name][1] or {}).get('totalSize', 0)}
    settings = set(ours.get('customSettings', []))
    return ({name: count for name, count in found.items() if name not in settings},
            {name: count for name, count in found.items() if name in settings})


def remove_access(org, ours):
    answers = batch(org, [
        ('assigned', soql('SELECT Id FROM PermissionSetAssignment WHERE PermissionSet.NamespacePrefix = null AND PermissionSet.Name IN (%s)' % in_list(ours['permissionSets']))),
        ('members', soql('SELECT Id FROM GroupMember WHERE Group.DeveloperName IN (%s)' % in_list(ours['groups']))),
    ])
    ids = [row['Id'] for row in records(answers['assigned'])] + [row['Id'] for row in records(answers['members'])]
    problems = delete_ids(org, ids)
    if problems:
        raise SetupError('Could not take away access: ' + '; '.join(problems[:5]))
    return len(ids)


def delete_records(org):
    for _ in range(40):
        reply = sf(['apex', 'run', '--target-org', org], stdin=DELETE_RECORDS, allow_failure=True, timeout=900)
        result = reply.get('result') or {}
        if not result.get('success'):
            raise SetupError('Could not delete our records: %s' % (result.get('exceptionMessage') or result.get('compileProblem') or reply.get('message')))
        found = debug_line(result.get('logs'), 'UNINSTALL|left|')
        left = int(found) if found and found.isdigit() else None
        if left == 0:
            return
        if left is None:
            raise SetupError('Could not tell how many of our records are left.')
    raise SetupError('Some of our records could not be deleted (something of yours may point at them). Delete them by hand, then run the uninstall again.')


def stage_dir(name):
    path = os.path.join(STAGE, name)
    if os.path.isdir(path):
        shutil.rmtree(path)
    os.makedirs(path)
    return path


# A folder of reports or of dashboards has no type of its own in a deploy: it is removed as a member of Report or of
# Dashboard that names only the folder. Asked for as "ReportFolder", Salesforce ignores it without a word and the
# folder stays.
AS_DEPLOYED = {'ReportFolder': 'Report', 'DashboardFolder': 'Dashboard'}


def package_xml(types):
    body = ''
    merged = {}
    for kind in sorted(types):
        merged.setdefault(AS_DEPLOYED.get(kind, kind), [])
        merged[AS_DEPLOYED.get(kind, kind)] += [member for member in types[kind] if member not in merged[AS_DEPLOYED.get(kind, kind)]]
    for kind in sorted(merged):
        members = ''.join('        <members>%s</members>\n' % escape(member) for member in sorted(merged[kind]))
        body += '    <types>\n%s        <name>%s</name>\n    </types>\n' % (members, kind)
    return '<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n%s    <version>%s</version>\n</Package>\n' % (body, api_version())


# Set once the org is known: two flags Salesforce accepts only outside production. --purge-on-delete asks it to erase
# what is deleted instead of keeping it in the recycle bin. --ignore-errors does not make it delete part of a step
# (see remove_step); here it marks an org where a step may go on without a component Salesforce refused.
LENIENT = []


def delete_flows(org, flows):
    """Deletes every version of our flows. A flow has no single delete; each version goes by itself."""
    ok, rows = tooling(org, 'SELECT Id, Definition.DeveloperName, VersionNumber FROM Flow WHERE Definition.DeveloperName IN (%s) ORDER BY VersionNumber DESC' % in_list(flows))
    if not ok:
        return ['could not list the flow versions: %s' % rows]
    problems = []
    for row in rows:
        reply = sf(['data', 'delete', 'record', '--target-org', org, '--use-tooling-api', '--sobject', 'Flow', '--record-id', row['Id']], allow_failure=True)
        if reply.get('status', 0) != 0:
            problems.append('Flow %s version %s: %s' % ((row.get('Definition') or {}).get('DeveloperName'), row.get('VersionNumber'), str(reply.get('message'))[:200]))
    return problems


def line_of(failure):
    return '%s %s: %s' % (failure.get('componentType'), failure.get('fullName'), failure.get('problem'))


def already_gone(failure):
    return 'No ' in str(failure.get('problem')) and 'found' in str(failure.get('problem'))


def deploy_result(org, folder):
    """One deploy of a staged folder. Says whether Salesforce applied it and which components it refused."""
    reply = sf(['project', 'deploy', 'start', '--target-org', org, '--metadata-dir', folder, '--ignore-warnings', '--wait', '45'] + LENIENT, allow_failure=True, timeout=3300)
    result = reply.get('result') or {}
    failures = (result.get('details') or {}).get('componentFailures') or []
    failures = [failures] if isinstance(failures, dict) else failures
    # A deploy can also fail as a whole, naming no component: then the reason is in its error message.
    return {'applied': result.get('status') in ('Succeeded', 'SucceededPartial'), 'failures': failures, 'message': result.get('errorMessage') if result else reply.get('message')}


def deploy_dir(org, folder, what):
    result = deploy_result(org, folder)
    # Something that is already gone is not a failure.
    real = [failure for failure in result['failures'] if not already_gone(failure)]
    ok = (result['applied'] and not real) or (bool(result['failures']) and not real)
    return ok, [line_of(failure) for failure in real], result['message']


def expected_to_stay(line):
    """The two refusals that are on the "would stay" list: neither is a failure."""
    return 'cannot delete last filter' in line or 'Branding Set Property' in line


def delete_components(org, number, types):
    folder = stage_dir('uninstall-%d' % number)
    with open(os.path.join(folder, 'package.xml'), 'w') as handle:
        handle.write(package_xml({}))
    with open(os.path.join(folder, 'destructiveChanges.xml'), 'w') as handle:
        handle.write(package_xml(types))
    return deploy_result(org, folder)


def remove_step(org, number, step, delete=delete_components):
    """Removes one step's components. Returns (the rest of the step is gone, what Salesforce refused, sf's message if any).

    Salesforce deletes the components of one deploy together or not at all: a single refusal fails the deploy, and
    nothing in it is removed, whatever --ignore-errors says. So a refused component is taken off the list and the
    step runs again, until the rest are gone. In production only the refusals on the "would stay" list are set aside
    this way; any other stops the step there, which is all or nothing.
    """
    types = {kind: list(members) for kind, members in step['types'].items()}
    refused = []
    for _ in range(8):
        types = {kind: members for kind, members in types.items() if members}
        if not types:
            return True, refused, None
        result = delete(org, number, types)
        # On a second run our settings types are already gone, and Salesforce then fails the whole deploy over their
        # records, one type at a time, naming no component. Those records went with their type.
        gone_type = re.search(r'Custom metadata type (\w+)__mdt is not available', str(result['message']))
        if not result['applied'] and not result['failures'] and gone_type and any(name.startswith(gone_type.group(1) + '.') for name in types.get('CustomMetadata', [])):
            types['CustomMetadata'] = [name for name in types['CustomMetadata'] if not name.startswith(gone_type.group(1) + '.')]
            continue
        for failure in result['failures']:
            # Salesforce can list one refusal twice.
            if not already_gone(failure) and line_of(failure) not in refused:
                refused.append(line_of(failure))
        if result['applied']:
            return True, refused, None
        if not result['failures']:
            return False, refused, result['message']
        set_aside = 0
        for failure in result['failures']:
            # Salesforce names a refused folder by the type it was deployed as.
            for kind in [kind for kind in types if failure.get('componentType') in (kind, AS_DEPLOYED.get(kind))]:
                members = types[kind]
                if (already_gone(failure) or expected_to_stay(line_of(failure)) or LENIENT) and failure.get('fullName') in members:
                    members.remove(failure.get('fullName'))
                    set_aside += 1
                    break
        # A refusal that cannot be set aside would only be refused again.
        if set_aside < len({(failure.get('componentType'), failure.get('fullName')) for failure in result['failures']}):
            return False, refused, None
    return False, refused, None


def turn_off_flows(org, flows):
    folder = stage_dir('uninstall-flows')
    os.makedirs(os.path.join(folder, 'flowDefinitions'))
    for name in flows:
        with open(os.path.join(folder, 'flowDefinitions', name + '.flowDefinition'), 'w') as handle:
            handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<FlowDefinition xmlns="http://soap.sforce.com/2006/04/metadata">\n    <activeVersionNumber>0</activeVersionNumber>\n</FlowDefinition>\n')
    with open(os.path.join(folder, 'package.xml'), 'w') as handle:
        handle.write(package_xml({'FlowDefinition': flows}))
    ok, failed, message = deploy_dir(org, folder, 'turn off our flows')
    # A flow that is already gone cannot be turned off, and Salesforce says so in these words. That is not a failure.
    left = [line for line in failed if "can't create a flow definition" not in line]
    return ok or (len(left) < len(failed) and not left), left, message


def switched_off(text):
    """A record type's file, as the body to deploy to switch it off: marked inactive, without its compact layout and
    without its picklist values. Salesforce leaves the values a record type has when none are named, and refuses the
    whole change when one is named that the org's field does not have, as happens when the org holds an older or
    newer version of the app than this kit."""
    inner = text[text.index('>', text.index('<RecordType')) + 1:text.rindex('</RecordType>')]
    inner = re.sub(r'<active>true</active>', '<active>false</active>', inner)
    inner = re.sub(r'\s*<compactLayoutAssignment>.*?</compactLayoutAssignment>', '', inner, flags=re.S)
    return re.sub(r'\s*<picklistValues>.*?</picklistValues>', '', inner, flags=re.S)


def switch_off_record_types(org):
    """Record types cannot be deleted through the API. This switches ours off, so they stop being offered."""
    folder = stage_dir('uninstall-record-types')
    source = os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'objects')
    # Only the ones that are still on. One that an earlier run switched off is left as it is.
    answers = batch(org, [(name, soql("SELECT DeveloperName FROM RecordType WHERE SobjectType = '%s' AND IsActive = true AND NamespacePrefix = null AND DeveloperName IN (%s)" % (name, in_list(types))))
                          for name, types in OUR_RECORD_TYPES.items()])
    members = []
    for name, types in OUR_RECORD_TYPES.items():
        blocks = ''
        still_on = {row['DeveloperName'] for row in records(answers[name])} if answers[name][0] else set(types)
        for one in types:
            path = os.path.join(source, name, 'recordTypes', one + '.recordType-meta.xml')
            if one not in still_on or not os.path.exists(path):
                continue
            with open(path, encoding='utf-8') as handle:
                text = handle.read()
            inner = switched_off(text)
            blocks += '    <recordTypes>%s</recordTypes>\n' % inner.rstrip() if inner.strip() else ''
            members.append('%s.%s' % (name, one))
        if blocks:
            os.makedirs(os.path.join(folder, 'objects'), exist_ok=True)
            with open(os.path.join(folder, 'objects', name + '.object'), 'w', encoding='utf-8') as handle:
                handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">\n%s</CustomObject>\n' % blocks)
    if not members:
        return True, [], None
    with open(os.path.join(folder, 'package.xml'), 'w') as handle:
        handle.write(package_xml({'RecordType': members}))
    return deploy_dir(org, folder, 'switch off our record types')


def part_sets(kit):
    """The permission sets of the parts that install alone, which an org may hold beside or in place of the whole app's."""
    found = []
    for entry in (kit.get('capabilities') or {}).values():
        found += [one for one in [entry.get('permissionSet'), entry.get('staffSet')] if one and one not in found]
    return found


def portal_in_org(alias, org, kit):
    """What the org holds, when any of the customer portal is in it; None when none of it is, or the kit has no portal.

    A page of the portal's site shows our components, and Salesforce refuses to delete a component a site shows. So
    the uninstall has to know the portal is there before its own steps run."""
    import capabilities
    entry = (kit.get('capabilities') or {}).get('portal')
    if not entry:
        return None
    have = capabilities.standing(alias, org['username'], kit)
    state = capabilities.judge(kit, have)
    return have if 'portal' in state['installed'] or 'portal' in state['partly'] else None


def remove_capability(org, args):
    """Removes one part of the app, the way the installer put it in. Returns True when there is nothing more to do.

    A part cut from the app or with a folder of its own is taken out by the installer's own removal, which leaves what
    the other parts in the org hold and refuses when one of them is built on this one. The data model has no removal
    of its own: once nothing built on it is left, removing it is the whole uninstall, so the run carries on.
    """
    import capabilities
    import deploy_phase
    kit = manifest()
    entry = capabilities.named(args.capability, kit)
    args.only, args.remove, args.wait, args.test_level = args.capability, True, 45, 'RunSpecifiedTests'
    if entry['kind'] == 'slice':
        deploy_phase.remove_slice(org, args.capability, args)
        return True
    if args.capability in deploy_phase.REMOVABLE_PHASES:
        deploy_phase.REMOVABLE_PHASES[args.capability](org, args.capability, args)
        return True
    if entry['kind'] != 'layer':
        raise SetupError('"%s" is not a part that is removed by itself. Run the uninstall without --capability; its dry run says what goes and what stays.' % entry['label'])
    if 'CustomObject' not in (entry.get('members') or {}):
        deploy_phase.remove_layer(org, args.capability, args)
        return True
    have = capabilities.standing(args.target_org, org['username'], kit)
    state = capabilities.judge(kit, have)
    print('\n'.join(capabilities.standing_lines(kit, have, state)))
    if state['whole']:
        raise SetupError('The whole app is in this org. "%s" cannot be taken out from under it. Run the uninstall without --capability to remove the app.' % entry['label'])
    above = capabilities.built_on(kit, args.capability, state)
    if above:
        raise SetupError('%s built on "%s" and still in the org. Remove %s first: python3 scripts/setup/uninstall.py --target-org %s --capability %s. Nothing was changed.' % (
            ', '.join('"%s"' % capabilities.named(other, kit)['label'] for other in above) + (' is' if len(above) == 1 else ' are'), entry['label'],
            'it' if len(above) == 1 else 'them', args.target_org, above[-1]))
    print('Nothing else of ours is built on "%s" here, so removing it is the uninstall below. What the org does not hold is skipped.' % entry['label'])
    return False


def run():
    parser = argparse.ArgumentParser(description='Remove Antsurance from an org. Dry run unless --yes.')
    parser.add_argument('--target-org', required=True)
    parser.add_argument('--capability', metavar='PART', help='Remove one part of the app and leave what the other parts need. deploy_phase.py --list names the parts.')
    parser.add_argument('--yes', action='store_true', help='Remove. Without it, only the plan is shown.')
    parser.add_argument('--delete-our-records', action='store_true', help='Also delete the records that only exist because of this app')
    parser.add_argument('--allow-production', action='store_true')
    args = parser.parse_args()

    org = describe_org(args.target_org)
    alias = args.target_org
    kit = manifest()
    # The parts that install alone have permission sets of their own. They go with the app, and so does access to them.
    ours = dict(kit['ours'], permissionSets=kit['ours']['permissionSets'] + [one for one in part_sets(kit) if one not in kit['ours']['permissionSets']])
    plan = steps()
    if args.capability and remove_capability(org, args):
        return
    announce(org, 'REMOVE Antsurance' if args.yes else 'show what removing Antsurance would do (dry run, nothing changes)')
    guard_production(org, args.allow_production)

    counts, settings = our_records(alias, ours)
    portal = portal_in_org(alias, org, kit)
    total = sum(len(members) for step in plan['steps'] for members in step['types'].values()) + sum(len(step.get('flows', [])) for step in plan['steps'])
    print('Would remove %d components in %d steps:' % (total, len(plan['steps'])))
    for number, step in enumerate(plan['steps'], 1):
        counted = ['%d %s' % (len(members), kind) for kind, members in sorted(step['types'].items())] + (['%d Flow' % len(step['flows'])] if step.get('flows') else [])
        print('  %d. %s: %s' % (number, step['name'], ', '.join(counted)))
    if portal:
        print('The customer portal is in this org. It is removed first, the way --capability portal removes it: its site lets go of our components and is switched off.')
    print('Would stay, because Salesforce does not let an installer remove them:')
    for line in plan['stays']:
        print('  - ' + line)
    if counts:
        print('Records that exist only because of this app: ' + ', '.join('%d %s' % (count, name) for name, count in sorted(counts.items())))
    else:
        print('No records depend on this app.')
    if settings:
        print("The app's own settings, which go with the app: " + ', '.join('%d %s' % (count, 'row' if count == 1 else 'rows') + ' in ' + name for name, count in sorted(settings.items())))
    print('Your own records, record types, fields, profiles and code are not touched.')
    import deploy_phase
    lines, stop = deploy_phase.say_used_by_theirs(*deploy_phase.used_by_theirs(org, kit, deploy_phase.all_ours(kit)))
    print('\n'.join(lines))
    if not args.yes:
        print('Dry run. Nothing was changed. %s' % ('Change or remove what is listed above first: the removal would stop there.' if stop else 'Run again with --yes to remove.'))
        return
    if stop:
        raise SetupError(stop)
    if counts and not args.delete_our_records:
        raise SetupError('The org holds records that would be deleted along with our objects. Nothing was changed. '
                         'Export them if you want them, then run again with --yes --delete-our-records.')

    if not org['isProduction']:
        LENIENT.extend(['--ignore-errors', '--purge-on-delete'])
    print('Removing access: %d assignments and group memberships removed.' % remove_access(alias, ours))
    if counts:
        delete_records(alias)
        print('Deleted the records that depended on this app.')
    problems = []
    if portal:
        args.wait, args.test_level = 45, 'RunSpecifiedTests'
        deploy_phase.remove_portal(org, 'portal', args, have=portal)
    ok, failed, message = turn_off_flows(alias, ours['flows'])
    print('Turned off our flows.' if ok else 'Could not turn off every flow: ' + '; '.join(failed[:5] or [str(message)]))
    ok, failed, message = switch_off_record_types(alias)
    print('Switched off our record types.' if ok else 'Switched off the record types Salesforce allows. Still on: ' + '; '.join(failed[:6] or [str(message)]))
    left_in_place = []
    for number, step in enumerate(plan['steps'], 1):
        ok, failed, message = remove_step(alias, number, step)
        if step.get('flows'):
            failed = delete_flows(alias, step['flows']) + failed
        failed = sorted(set(failed))
        # Two leftovers are expected and are on the "would stay" list: neither is a failure.
        expected = [line for line in failed if expected_to_stay(line)]
        failed = [line for line in failed if line not in expected]
        left_in_place += expected
        if ok and not failed:
            print('  %d. %s: removed.%s' % (number, step['name'], ' Left in place, as listed under what stays: ' + '; '.join(line.split(':')[0] for line in expected) if expected else ''))
        else:
            problems.append(step['name'])
            print('  %d. %s: %s' % (number, step['name'], 'NOT fully removed. Salesforce refused these and the rest of the step is gone:' if ok else 'NOT removed.'))
            for line in (failed[:12] or [str(message)[:400]]):
                print('       ' + line)
    record(org, 'uninstall', 'removed' if not problems else 'partly removed', {'notRemoved': problems, 'leftInPlace': left_in_place})
    if problems:
        raise SetupError('Some steps did not finish: %s. The usual cause is something of yours that uses one of our components; the lines above name it. '
                         'Remove that reference and run the uninstall again; it picks up where it left off.' % ', '.join(problems))
    print('Antsurance is removed. What stays is listed above, with how to remove each by hand in INSTALL.md.')


if __name__ == '__main__':
    main(run)
