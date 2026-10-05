#!/usr/bin/env python3
"""The preflight. Reads an org and says whether Antsurance can be installed in it, and what to decide first.

Read only: it asks the org questions, pulls a copy of the metadata ours could meet, and changes nothing. It writes:
  setup-report.md        for a person: the verdict, then every STOP, DECIDE and NOTE with what to do
  setup-report.json      the same for the installer and for Claude Code
  org-conventions.md     how this org names and builds things, and the rules for building anything new in it
  org-conventions.json   the same as data
  .install/org-metadata/<alias>/   the pulled metadata, laid out like the kit's own

Usage: python3 scripts/setup/analyze_org.py --target-org <alias>
       --offline     read the last pull and the last answers again without calling the org
       --pull        pull the metadata even from an org that looks new and empty
       --skip-pull   questions only, no metadata pull (the clash and convention checks are then thinner)
       --pull-again  keep the last answers and pull the metadata again: one call, for after a pull that failed
       --measure     ask the org once more at the end how many requests it counted during the run

The metadata is pulled whenever the org holds anything of its own or anything of ours. A new, empty org needs no pull.
Cost with a pull: 6 `sf` commands and about 50 requests plus one for each second the retrieve takes.

Verdict: GO (install as is), GO WITH CHANGES (install after the listed decisions), STOP (do not install here yet).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import preflight  # noqa: E402
from _common import KIT_ROOT, STATE_DIR, USAGE, SetupError, batch, describe_org, in_list, kind_of, load_state, main, manifest, now, records, rest, soql, tooling  # noqa: E402

STANDARD_OBJECTS = ['Account', 'Contact', 'Case', 'Opportunity', 'Lead', 'Task', 'Quote']
RECORD_COUNTED = ['Account', 'Contact', 'Case', 'Opportunity', 'Lead']
DEPLOY_PERMISSIONS = {
    'PermissionsModifyAllData': 'Modify All Data',
    'PermissionsCustomizeApplication': 'Customize Application',
    'PermissionsAuthorApex': 'Author Apex',
    'PermissionsModifyMetadata': 'Modify Metadata Through Metadata API Functions',
    'PermissionsAssignPermissionSets': 'Assign Permission Sets',
    'PermissionsManageUsers': 'Manage Users',
}
# Where each standard picklist's current values are read from.
VALUE_SET_FIELDS = {
    'CaseStatus': ('Case', 'Status'), 'CaseOrigin': ('Case', 'Origin'), 'OpportunityStage': ('Opportunity', 'StageName'),
    'OpportunityType': ('Opportunity', 'Type'), 'QuoteStatus': ('Quote', 'Status'),
}


class Report:
    def __init__(self):
        self.findings = []
        self.facts = {}

    def add(self, level, area, what, action, key=None, data=None):
        """level: stop | change | note | info. One line of what was found and one line of what to do about it.

        A note is worth knowing and asks for no decision; it does not change the verdict.
        """
        self.findings.append({'level': level, 'area': area, 'finding': what, 'action': action, 'key': key, 'data': data})

    def verdict(self):
        levels = {finding['level'] for finding in self.findings}
        return 'STOP' if 'stop' in levels else 'GO WITH CHANGES' if 'change' in levels else 'GO'


def questions(ours):
    """Every read-only question, asked in as few calls as the API allows."""
    asks = [
        ('limits', 'limits'),
        ('licenses', soql("SELECT Name, TotalLicenses, UsedLicenses, Status FROM UserLicense WHERE Name IN ('Salesforce', 'Salesforce Platform', 'Customer Community', 'Customer Community Login', 'Customer Community Plus')")),
        ('permissions', soql('SELECT ' + ', '.join(DEPLOY_PERMISSIONS) + ' FROM UserPermissionAccess')),
        ('sharing', soql('SELECT QualifiedApiName, InternalSharingModel, ExternalSharingModel FROM EntityDefinition WHERE QualifiedApiName IN (%s)' % in_list(STANDARD_OBJECTS[:6] + ['Quote']))),
        ('ourObjects', soql('SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName IN (%s)' % in_list(ours['customObjects']))),
        ('classes', soql("SELECT Name FROM ApexClass WHERE NamespacePrefix = null AND Name LIKE 'Antsurance%'")),
        ('triggers', soql('SELECT Name, TableEnumOrId, Status, NamespacePrefix FROM ApexTrigger')),
        ('flows', soql('SELECT ApiName, IsActive FROM FlowDefinitionView WHERE ApiName IN (%s)' % in_list(ours['flows']))),
        ('recordFlows', soql("SELECT ApiName, Label, TriggerType, TriggerObjectOrEventLabel FROM FlowDefinitionView WHERE IsActive = true AND TriggerType IN ('RecordBeforeSave', 'RecordAfterSave', 'RecordBeforeDelete') AND TriggerObjectOrEventLabel IN ('Case', 'Opportunity', 'Account', 'Contact', 'Lead', 'Task', 'Quote')")),
        ('permissionSets', soql('SELECT Name FROM PermissionSet WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(ours['permissionSets']))),
        ('namedCredentials', soql('SELECT DeveloperName FROM NamedCredential WHERE NamespacePrefix = null AND DeveloperName IN (%s)' % in_list(ours['namedCredentials']))),
        ('groups', soql('SELECT DeveloperName FROM Group WHERE DeveloperName IN (%s)' % in_list(ours['groups']))),
        ('businessProcesses', soql('SELECT Name, TableEnumOrId, IsActive FROM BusinessProcess')),
        ('duplicateRules', soql('SELECT DeveloperName, SobjectType FROM DuplicateRule WHERE IsActive = true')),
        ('matchingRules', soql("SELECT DeveloperName, SobjectType FROM MatchingRule WHERE RuleStatus = 'Active'")),
        ('profiles', soql('SELECT Profile.Name profile, Profile.UserLicense.Name license, COUNT(Id) people FROM User WHERE IsActive = true GROUP BY Profile.Name, Profile.UserLicense.Name ORDER BY COUNT(Id) DESC')),
        ('roles', soql('SELECT UserRole.Name role, COUNT(Id) people FROM User WHERE IsActive = true AND UserRoleId != null GROUP BY UserRole.Name ORDER BY COUNT(Id) DESC LIMIT 50')),
        ('assignedSets', soql('SELECT PermissionSet.Name name, PermissionSet.Label label, COUNT(Id) people FROM PermissionSetAssignment WHERE PermissionSet.IsOwnedByProfile = false AND Assignee.IsActive = true GROUP BY PermissionSet.Name, PermissionSet.Label ORDER BY COUNT(Id) DESC LIMIT 100')),
        ('networks', soql('SELECT Name, Status, UrlPathPrefix FROM Network')),
        ('quotes', soql('SELECT COUNT() FROM Quote')),
        ('paths', soql('SELECT COUNT() FROM PathAssistant', tooling=True)),
        ('devHub', soql('SELECT COUNT() FROM ScratchOrgInfo')),
        ('notes', soql('SELECT COUNT() FROM ContentNote')),
    ]
    # Our apps and tabs, counted one by one through the Tooling API. The lists of apps and tabs a person gets hold
    # only the ones that person may open, and a clash must be found whoever runs this.
    import capabilities
    asks += capabilities.by_name('app:', 'CustomApplication', ours['apps']) + capabilities.by_name('tab:', 'CustomTab', capabilities.named_tabs(ours['tabs']))
    asks += [('count' + name, soql('SELECT COUNT() FROM ' + name)) for name in RECORD_COUNTED]
    asks += [('describe' + name, 'sobjects/%s/describe' % name) for name in STANDARD_OBJECTS]
    # What the org has by name. These say whether there is anything to pull, and feed the conventions.
    folders = ours.get('reportFolders', []) + ours.get('dashboardFolders', [])
    asks += [
        ('objectCount', soql('SELECT COUNT() FROM CustomObject WHERE NamespacePrefix = null', tooling=True)),
        ('classList', soql('SELECT Name, ApiVersion FROM ApexClass WHERE NamespacePrefix = null')),
        ('auraList', soql('SELECT DeveloperName, ApiVersion FROM AuraDefinitionBundle WHERE NamespacePrefix = null')),
        ('flowList', soql('SELECT ApiName, Label, ProcessType, TriggerType, TriggerObjectOrEventId, TriggerObjectOrEventLabel, IsActive, NamespacePrefix FROM FlowDefinitionView')),
        ('setList', soql('SELECT Name, Label, Type FROM PermissionSet WHERE IsCustom = true AND IsOwnedByProfile = false AND NamespacePrefix = null')),
        ('setGroupList', soql('SELECT DeveloperName FROM PermissionSetGroup WHERE NamespacePrefix = null')),
        ('resourceList', soql('SELECT Name FROM StaticResource WHERE NamespacePrefix = null')),
        ('folders', soql('SELECT DeveloperName, Type FROM Folder WHERE NamespacePrefix = null AND DeveloperName IN (%s)' % in_list(folders))),
        ('pages', soql('SELECT Name FROM ApexPage WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(ours.get('apexPages', [])))),
    ]
    return asks


# Asked for the conventions and the fuller name checks. If the org refuses one, the report says so in
# org-conventions.md and under the names check; it is not a reason to hold up an install.
FOR_CONVENTIONS = {'objectCount', 'classList', 'auraList', 'flowList', 'setList', 'setGroupList', 'resourceList', 'folders', 'pages'}


# Questions an org may fairly refuse, because the feature they ask about is switched off. A refusal is the answer.
MAY_REFUSE = {'quotes', 'networks', 'paths', 'devHub', 'describeQuote', 'theme', 'notes'}


def could_not_check(report, answers, asked=None):
    """A question the org refused is reported, never dropped: a check that did not run is not a check that passed.

    `asked` is the names this version asks. Answers kept from a read by an older kit may hold others; those are skipped.
    """
    for name, (ok, payload) in sorted(answers.items()):
        if not ok and name not in MAY_REFUSE and name not in FOR_CONVENTIONS and (asked is None or name in asked):
            report.add('change', 'Not checked', 'The org would not answer the "%s" check: %s' % (name, str(payload).replace('&#39;', "'")[:160]),
                       'Treat this as unknown, not as fine. Check it by hand in Setup, or ask your Salesforce administrator why the installer cannot read it.', 'notChecked')


def names(answer, field):
    return sorted({row.get(field) for row in records(answer) if row.get(field)})


def total(answer):
    ok, payload = answer
    return (payload or {}).get('totalSize') if ok else None


def answers_path(alias):
    return os.path.join(STATE_DIR, 'org-answers-%s.json' % ''.join(char if char.isalnum() or char in '._-' else '_' for char in alias))


def holds_anything(answers, describes, ours):
    """What the org holds of its own or of ours, as short reasons. Empty means new and empty: nothing for ours to meet."""
    mine = set(ours['apexClasses']) | set(ours.get('portalClasses', []))
    reasons = []
    classes = names(answers['classList'], 'Name') if answers.get('classList', (False, None))[0] else names(answers['classes'], 'Name')
    if [name for name in classes if name not in mine and name not in preflight.STOCK_CLASSES]:
        reasons.append('Apex classes of its own')
    if [name for name in classes if name in mine]:
        reasons.append('Apex classes of ours')
    if [row for row in records(answers['triggers']) if row.get('Name') not in set(ours['apexTriggers'])]:
        reasons.append('triggers')
    # Every custom object, setting and settings type the org has, less the ones that are ours.
    if (total(answers.get('objectCount', (False, None))) or 0) > len(names(answers['ourObjects'], 'QualifiedApiName')):
        reasons.append('custom objects')
    if [row for row in records(answers.get('flowList', (False, None))) if not row.get('NamespacePrefix') and row.get('ApiName') not in set(ours['flows'])]:
        reasons.append('flows')
    for name in STANDARD_OBJECTS:
        skip = set(ours['standardObjectFields'].get(name, []))
        if any(field.get('custom') and field_name not in skip for field_name, field in fields_of(describes.get(name, (False, None))).items()):
            reasons.append('custom fields on standard objects')
            break
    return reasons


def gather(org, kit, mode='auto', again=False):
    """Everything read from the org: who it is, its answers, and the pulled metadata when there is a reason to pull.

    Kept in .install/ so `--offline` can judge the same org again without another call, and `--pull-again` can
    repeat only the pull.
    """
    ours = kit['ours']
    if again:
        facts, answers, _ = recall(org, need_pull=False)
        describes = {name: answers['describe' + name] for name in STANDARD_OBJECTS}
        reasons = holds_anything(answers, describes, ours)
        cost = {'pulled': False, 'why': reasons, 'mode': 'always', 'pull': None, 'answersFrom': 'the last read'}
        try:
            cost['pull'] = preflight.pull(org, kit, ours_in_org(answers, ours))
            cost['pulled'] = True
        except SetupError as problem:
            cost['pullFailed'] = str(problem)
        cost.update(commands=USAGE['commands'], requests=USAGE['requests'])
        with open(answers_path(org), 'w') as handle:
            json.dump({'facts': facts, 'answers': {name: list(answer) for name, answer in answers.items()}, 'cost': cost}, handle)
        return facts, answers, cost
    facts = describe_org(org)
    answers = batch(org, questions(ours))
    describes = {name: answers['describe' + name] for name in STANDARD_OBJECTS}
    reasons = holds_anything(answers, describes, ours)
    pull = mode == 'always' or (mode == 'auto' and bool(reasons))
    # These live in the Tooling API and are asked one at a time. With a pull, the pulled files answer three of them.
    singles = {'components': 'SELECT DeveloperName, ApiVersion FROM LightningComponentBundle WHERE NamespacePrefix = null'}
    if not pull:
        singles.update({
            'externalCredentials': 'SELECT DeveloperName FROM ExternalCredential WHERE DeveloperName IN (%s)' % in_list(ours['externalCredentials']),
            'validationRules': 'SELECT ValidationName, EntityDefinitionId FROM ValidationRule WHERE Active = true AND NamespacePrefix = null',
            'theme': 'SELECT DeveloperName FROM LightningExperienceTheme',
        })
    for name, text in singles.items():
        ok, rows = tooling(org, text)
        answers[name] = (ok, {'records': rows} if ok else rows)
    cost = {'pulled': False, 'why': reasons if pull else [], 'mode': mode, 'pull': None}

    def keep():
        cost.update(commands=USAGE['commands'], requests=USAGE['requests'])
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(answers_path(org), 'w') as handle:
            json.dump({'facts': facts, 'answers': {name: list(answer) for name, answer in answers.items()}, 'cost': cost}, handle)
    # Kept before the pull as well, so a pull that fails does not cost the answers already paid for.
    keep()
    if pull:
        try:
            cost['pull'] = preflight.pull(org, kit, ours_in_org(answers, ours))
            cost['pulled'] = True
        except SetupError as problem:
            cost['pullFailed'] = str(problem)
            for name, text in {'externalCredentials': 'SELECT DeveloperName FROM ExternalCredential WHERE DeveloperName IN (%s)' % in_list(ours['externalCredentials']),
                               'validationRules': 'SELECT ValidationName, EntityDefinitionId FROM ValidationRule WHERE Active = true AND NamespacePrefix = null',
                               'theme': 'SELECT DeveloperName FROM LightningExperienceTheme'}.items():
                ok, rows = tooling(org, text)
                answers[name] = (ok, {'records': rows} if ok else rows)
        keep()
    return facts, answers, cost


def ours_in_org(answers, ours):
    """Which of our names the questions found in the org, by metadata type, so the pull asks only for what is there."""
    def found(ask, field):
        return set(names(answers[ask], field)) if answers.get(ask, (False, None))[0] else None
    in_org = {'ApexClass': found('classList', 'Name'), 'LightningComponentBundle': found('components', 'DeveloperName'), 'Flow': found('flows', 'ApiName'),
              'PermissionSet': (found('permissionSets', 'Name') or set()) | (found('setList', 'Name') or set()) if found('permissionSets', 'Name') is not None else None,
              'Group': found('groups', 'DeveloperName'), 'ApexPage': found('pages', 'Name')}
    in_org = {kind: found_names for kind, found_names in in_org.items() if found_names is not None}
    if answers.get('ourObjects', (False, None))[0]:
        in_org['customMetadataTypes'] = {name for name in names(answers['ourObjects'], 'QualifiedApiName') if name.endswith('__mdt')}
    if not answers.get('quotes', (True, None))[0]:
        in_org['missingObjects'] = {'Quote'}
    return in_org


def recall(org, need_pull=True):
    """The last gather for this org, read back from .install/ with no call to the org."""
    path = answers_path(org)
    if not os.path.exists(path):
        raise SetupError('There is no earlier read of %s to go back to. Run this once without --offline.' % org)
    with open(path) as handle:
        kept = json.load(handle)
    cost = dict(kept['cost'], offline=True)
    if need_pull and cost.get('pulled') and not os.path.isdir(preflight.metadata_root(preflight.pull_folder(org))):
        raise SetupError('The metadata pulled from %s is no longer in .install/org-metadata/. Run this once without --offline.' % org)
    return kept['facts'], {name: tuple(answer) for name, answer in kept['answers'].items()}, cost


def from_counts(answers):
    """Puts the counted apps and tabs in the shape the checks read. An earlier read kept in .install/ has them already."""
    import capabilities
    for key, lead, field in (('apps', 'app:', 'DeveloperName'), ('tabs', 'tab:', 'Name')):
        if key in answers:
            continue
        found = capabilities.read_by_name(lead, answers)
        answers[key] = (True, {'records': [{field: name} for name in sorted(found)]}) if found is not None else (False, 'the org would not say which of these it holds')


def from_pull(answers, inventory, ours):
    """Answers three of the name questions from the pulled files, in the shape the Tooling API gives them."""
    rules = [{'ValidationName': rule, 'EntityDefinitionId': name} for name, entry in inventory['objects'].items()
             for rule, facts in entry['validationRules'].items() if facts['active']]
    answers['validationRules'] = (True, {'records': rules})
    answers['externalCredentials'] = (True, {'records': [{'DeveloperName': name} for name in inventory['externalCredentials'] if name in set(ours['externalCredentials'])]})
    answers['theme'] = (True, {'records': [{'DeveloperName': name} for name in inventory['themes']]})


def judge(kit, facts, answers, cost, kit_root=KIT_ROOT, pulled_root=None):
    """Turns what was read into findings. Calls nothing: the same answers always give the same report."""
    ours = kit['ours']
    report = Report()
    report.facts['org'] = facts
    report.facts['preflight'] = cost
    inventory = compared = None
    from_counts(answers)
    part = installed_part(kit, answers)
    if cost.get('pulled'):
        pulled_root = pulled_root or preflight.metadata_root(preflight.pull_folder(facts['alias']))
        inventory = preflight.read_inventory(pulled_root)
        # An org that holds one part of the app is compared with that part's own files, not with the whole app's.
        compared = preflight.compare(kit_root, pulled_root, [os.path.join(part['path'], 'main', 'default')] if part and part.get('path') else None)
        from_pull(answers, inventory, ours)
    could_not_check(report, answers, {name for name, _ in questions(ours)} | {'components', 'externalCredentials', 'validationRules', 'theme'})

    check_org(report, facts)
    check_limits(report, answers, kit)
    check_permissions(report, answers)
    describes = {name: answers['describe' + name] for name in STANDARD_OBJECTS}
    check_features(report, answers, describes, kit)
    previous = check_names(report, answers, describes, ours, compared, part)
    check_automation(report, answers, describes, kit, previous, inventory, kit_root)
    check_value_sets(report, describes, kit, answers)
    if inventory is not None:
        check_metadata(report, kit, inventory, compared, previous, kit_root, pulled_root)
    elif cost.get('pullFailed'):
        report.add('change', 'Metadata', 'The org holds %s, but its metadata could not be pulled. %s' % (', '.join(cost.get('why') or ['things of its own']), cost['pullFailed']),
                   'The checks in this report rest on the questions alone: field types, picklist meanings and what differs from this kit are unknown, not fine. Fix what the message names, or ask your Salesforce administrator, and run the analysis again.', 'pullFailed')
    else:
        report.add('info', 'Metadata', 'No metadata was pulled: %s.' % ('the pull was skipped' if cost.get('mode') == 'never' else 'the org holds nothing of its own and nothing of ours'),
                   'Nothing for ours to clash with was found by the questions alone. Run with --pull to read the metadata anyway.')
    check_sharing(report, answers)
    check_people(report, answers)
    check_records(report, answers, facts)
    report.conventions = preflight.read_conventions(kit, inventory or {}, listing_of(answers))
    return report


def installed_part(kit, answers):
    """The one part of the app this org holds (FEATURES.md lists the parts), when it holds a part and not the whole app.

    A part is there when its permission set is in the org and every class of ours the org has belongs to it.
    """
    ours = kit['ours']
    have = {name for name in names(answers['classes'], 'Name') if name.startswith('Antsurance')}
    sets = set(names(answers.get('setList', (False, None)), 'Name')) | set(names(answers['permissionSets'], 'Name'))
    for name, part in sorted((kit.get('slices') or {}).items()):
        classes = set((part.get('members') or {}).get('ApexClass', []))
        if have and part.get('permissionSet') in sets and have <= classes and len(have) * 2 < len(ours['apexClasses']):
            members = {one.split('.')[-1] for group in (part.get('members') or {}).values() for one in group}
            return dict(part, name=name, names=members)
    return installed_capabilities(kit, answers, sets)


def installed_capabilities(kit, answers, sets):
    """The parts cut from the app that this org holds (the data model, the automations, the components, the pages),
    when it holds some of them and not the whole app. Returned as one part: its label names them all, and its members
    are theirs together, so that what belongs to them is not taken for a clash.
    """
    import capabilities
    if capabilities.WHOLE_APP_SET in sets or not kit.get('capabilities'):
        return None

    def found(ask, field):
        return set(names(answers[ask], field)) if answers.get(ask, (False, None))[0] else None
    have = {'ApexClass': found('classes', 'Name'), 'ApexTrigger': {name for name in found('triggers', 'Name') or set() if name.startswith('Antsurance')} if found('triggers', 'Name') is not None else None,
            'Flow': found('flows', 'ApiName'), 'CustomObject': found('ourObjects', 'QualifiedApiName'), 'PermissionSet': {name for name in sets if name.startswith('Antsurance')},
            'CustomTab': found('tabs', 'Name'), 'CustomApplication': found('apps', 'DeveloperName'), 'ApexPage': found('pages', 'Name'),
            'StaticResource': (found('resourceList', 'Name') or set()) & set(kit['ours'].get('staticResources', [])) if found('resourceList', 'Name') is not None else None,
            'LightningComponentBundle': None, 'mine': set()}
    state = capabilities.judge(kit, have)
    layers = [name for name in state['installed'] if kit['capabilities'][name]['kind'] == 'layer']
    if not layers:
        return None
    members = {}
    for name in layers:
        for kind, group in (kit['capabilities'][name].get('members') or {}).items():
            members.setdefault(kind, [])
            members[kind] += [one for one in group if one not in members[kind]]
        for one in (kit['capabilities'][name].get('permissionSet'),):
            if one:
                members.setdefault('PermissionSet', []).append(one)
    labels = [kit['capabilities'][name]['label'] for name in layers]
    return {'name': layers[-1], 'installed': layers, 'label': ' and '.join([', '.join(labels[:-1]), labels[-1]]) if len(labels) > 1 else labels[0], 'members': members, 'path': None,
            'names': {one.split('.')[-1] for group in members.values() for one in group}, 'outside': state['outside'], 'partly': state['partly']}


def listing_of(answers):
    """What the org has by name, for the conventions: rows per kind, and the kinds the org would not list."""
    asks = {'classes': 'classList', 'components': 'components', 'auras': 'auraList', 'flows': 'flowList', 'sets': 'setList', 'setGroups': 'setGroupList', 'resources': 'resourceList'}
    listing = {kind: records(answers.get(ask, (False, None))) for kind, ask in asks.items()}
    listing['notRead'] = [kind for kind, ask in asks.items() if not answers.get(ask, (False, None))[0]]
    return listing


def analyze(org, mode='auto', offline=False, again=False):
    kit = manifest()
    facts, answers, cost = recall(org) if offline else gather(org, kit, mode, again)
    return judge(kit, facts, answers, cost)


def check_org(report, facts):
    what = '%s is a %s (%s).' % (facts['name'], kind_of(facts), facts['edition'])
    if facts['isProduction']:
        report.add('stop', 'Org', what, 'Do not install into production first. Install into a sandbox or a scratch org, then decide.', 'production')
    else:
        report.add('info', 'Org', what, 'A safe place to install.')
    if facts.get('namespace'):
        report.add('stop', 'Org', 'The org has the namespace "%s".' % facts['namespace'], 'This kit is written for an org with no namespace. Use a different org.', 'namespace')


def check_limits(report, answers, kit):
    ok, limits = answers['limits']
    if not ok:
        report.add('change', 'Limits', 'The org would not show its limits.', 'Check storage and the daily API limit in Setup, Company Information.')
        return
    kept = {}
    for name in ('DataStorageMB', 'FileStorageMB', 'DailyApiRequests'):
        entry = limits.get(name) or {}
        kept[name] = {'max': entry.get('Max'), 'remaining': entry.get('Remaining')}
    report.facts['limits'] = kept
    data, files, api = kept['DataStorageMB'], kept['FileStorageMB'], kept['DailyApiRequests']
    demo = kit.get('demoData', {})
    need_mb = demo.get('dataStorageMB', 5)
    if data['remaining'] is not None:
        room = 'Data storage: %s MB free of %s MB.' % (data['remaining'], data['max'])
        if data['remaining'] < need_mb:
            report.add('change', 'Limits', room, 'Not enough room for the demo data (about %s MB, %s records). Install without it.' % (need_mb, demo.get('records', '2,100')), 'noRoomForDemoData')
        else:
            report.add('info', 'Limits', room, 'Enough for the demo data (about %s MB) if you want it.' % need_mb)
    if files['remaining'] is not None:
        report.add('info', 'Limits', 'File storage: %s MB free of %s MB.' % (files['remaining'], files['max']), 'The sample claim photos and documents take about 5 MB.')
    if api['remaining'] is not None:
        line = 'API requests: %s left today of %s.' % (api['remaining'], api['max'])
        if api['remaining'] < 2000:
            report.add('change', 'Limits', line, 'An install uses about 500 requests. Wait until the count resets, or keep other tools off the org while installing.', 'apiLow')
        else:
            report.add('info', 'Limits', line, 'An install uses about 500.')


def check_permissions(report, answers):
    rows = records(answers['permissions'])
    if not rows:
        report.add('change', 'Your access', 'Could not read what you are allowed to do.', 'Sign in as a System Administrator and run this again.')
        return
    missing = [label for field, label in DEPLOY_PERMISSIONS.items() if not rows[0].get(field)]
    report.facts['missingPermissions'] = missing
    if missing:
        report.add('stop', 'Your access', 'You are missing: ' + ', '.join(missing) + '.', 'Sign in as a System Administrator, or have one run the install.', 'permissions')
    else:
        report.add('info', 'Your access', 'You can deploy code and settings and assign permission sets.', 'Nothing to do.')


def fields_of(describe):
    ok, payload = describe
    return {field['name']: field for field in (payload or {}).get('fields', [])} if ok else {}


def check_features(report, answers, describes, kit):
    needs = kit.get('requirements', {})
    account = fields_of(describes['Account'])
    features = {}

    features['stateCountryPicklists'] = 'BillingStateCode' in account
    if features['stateCountryPicklists']:
        report.add('info', 'Features', 'State and country picklists are on.', 'Nothing to do.')
    elif needs.get('stateCountryPicklists'):
        report.add('stop', 'Features', 'State and country picklists are off.',
                   'This version of the code needs them and will not compile without. Turning them on converts every address in the org, so do not do that to a working org for a trial: use a scratch org or a new Developer Edition instead.',
                   'stateCountryPicklists')
    else:
        report.add('info', 'Features', 'State and country picklists are off.', 'The app stores states as text here.')

    features['quotes'] = answers['quotes'][0]
    if features['quotes']:
        report.add('info', 'Features', 'Quotes are on.', 'Nothing to do.')
    else:
        report.add('change', 'Features', 'Quotes are off.', 'The app uses the standard Quote object. The installer turns Quotes on, with your yes. It adds a Quotes related list to opportunity layouts.', 'enableQuotes')

    # The switch itself cannot be read. A path that already exists proves it is on.
    features['path'] = True if (total(answers['paths']) or 0) > 0 else None
    if features['path']:
        report.add('info', 'Features', 'Path (the stage bar on a record) is on.', 'Nothing to do.')
    else:
        report.add('change', 'Features', 'Path (the stage bar on a record) may be off: the org has no paths.',
                   'The installer turns Path on, with your yes. It shows nothing on your own pages until you build a path. If it is on already, this changes nothing.', 'enablePath')

    # Salesforce Notes can be off, and then the note object does not exist. The app looks it up by name and works either way.
    if 'notes' in answers:
        features['notes'] = answers['notes'][0]
        if features['notes']:
            report.add('note', 'Features', 'Salesforce Notes is on.', 'Claude reads the notes kept on a record along with our own file notes, and offers to save one. Nothing to do.', 'notesOn')
        else:
            report.add('note', 'Features', 'Salesforce Notes is off.',
                       'The app works the same without it: it reads no Salesforce notes and does not offer to save one. Our own file notes are not affected. Do not switch Notes on for this.', 'notesOff')

    features['personAccounts'] = 'IsPersonAccount' in account
    if features['personAccounts']:
        report.add('change', 'Features', 'Person Accounts are on.', 'The app models a household as a business-style account with contacts. It works beside Person Accounts but does not use them; check your account validation rules below.', 'personAccounts')

    features['multiCurrency'] = 'CurrencyIsoCode' in account
    if features['multiCurrency']:
        report.add('change', 'Features', 'Multiple currencies are on.', 'The app shows every amount in US dollars. Records it creates take your default currency.', 'multiCurrency')

    ok, networks = answers['networks']
    features['digitalExperiences'] = ok
    if ok:
        used = [row for row in records(answers['networks'])]
        report.add('info', 'Features', 'Digital Experiences is on, with %d site%s.' % (len(used), '' if len(used) == 1 else 's'), 'The optional customer portal can be added without switching anything on.')
        report.facts['sites'] = [{'name': row.get('Name'), 'path': row.get('UrlPathPrefix'), 'status': row.get('Status')} for row in used]
    else:
        report.add('info', 'Features', 'Digital Experiences is off.', 'Only matters for the optional customer portal. Turning it on cannot be undone, so the installer asks first.')

    features['devHub'] = answers['devHub'][0]
    themes = names(answers['theme'], 'DeveloperName')
    report.facts['customThemes'] = themes
    if themes:
        report.add('info', 'Features', 'The org has its own theme%s: %s.' % ('' if len(themes) == 1 else 's', ', '.join(themes)), 'The optional look and feel would replace the active theme for everyone. Skip it to keep yours.')
    report.facts['features'] = features


def left_by_an_uninstall(found, describes, ours):
    """Whether the only things in the org with our names are our record types, in the state our uninstall leaves
    them: switched off, or still on only because the object keeps its last active record type. Salesforce does not
    let an installer delete a record type, so an org the app was removed from always holds these."""
    if not found.get('recordTypes') or any(items for kind, items in found.items() if kind != 'recordTypes'):
        return False
    for name, wanted in ours['recordTypes'].items():
        ok, payload = describes.get(name, (False, None))
        on = [info.get('developerName') for info in (payload or {}).get('recordTypeInfos', []) if info.get('active') and not info.get('master')] if ok else []
        if len(on) > 1 and any(one in wanted for one in on):
            return False
    return True


def uninstalled_from_here(report):
    """When this kit's own notes say its uninstall ran on this org, the time it did; else None."""
    org = report.facts.get('org') or {}
    if not (org.get('orgId') or org.get('alias')):
        return None
    try:
        return ((load_state(org).get('phases') or {}).get('uninstall') or {}).get('at')
    except (OSError, ValueError, KeyError):
        return None


def check_names(report, answers, describes, ours, compared=None, part=None):
    """Things in the org that already carry one of our names. Returns True when this looks like an earlier install of ours.

    `compared` is the file by file comparison from a metadata pull. With it, a clash says whether the org's thing is
    the same as ours or different, and an earlier install says how much of it matches this kit.
    """
    found = {
        'customObjects': names(answers['ourObjects'], 'QualifiedApiName'),
        'apexClasses': [name for name in names(answers['classes'], 'Name') if name in set(ours['apexClasses'])],
        'lwc': [name for name in names(answers['components'], 'DeveloperName') if name in set(ours['lwc'])],
        'staticResources': [name for name in names(answers.get('resourceList', (False, None)), 'Name') if name in set(ours.get('staticResources', []))],
        'reportAndDashboardFolders': names(answers.get('folders', (False, None)), 'DeveloperName'),
        'flows': names(answers['flows'], 'ApiName'),
        'permissionSets': names(answers['permissionSets'], 'Name'),
        'apps': names(answers['apps'], 'DeveloperName'),
        'tabs': names(answers['tabs'], 'Name'),
        'namedCredentials': names(answers['namedCredentials'], 'DeveloperName'),
        'externalCredentials': names(answers['externalCredentials'], 'DeveloperName'),
        'groups': names(answers['groups'], 'DeveloperName'),
    }
    field_clashes, type_clashes = [], []
    for name, wanted in ours['standardObjectFields'].items():
        have = fields_of(describes.get(name, (False, None)))
        field_clashes += ['%s.%s' % (name, field) for field in wanted if field in have]
    for name, wanted in ours['recordTypes'].items():
        ok, payload = describes.get(name, (False, None))
        have = {info.get('developerName') for info in (payload or {}).get('recordTypeInfos', [])} if ok else set()
        type_clashes += ['%s.%s' % (name, one) for one in wanted if one in have]
    found['standardObjectFields'] = field_clashes
    found['recordTypes'] = type_clashes
    report.facts['existingNames'] = found

    classes_total = max(len(ours['apexClasses']), 1)
    share = len(found['apexClasses']) / classes_total
    previous = share >= 0.5 and bool(found['permissionSets'])
    report.facts['previousInstall'] = previous
    count = sum(len(items) for items in found.values())
    same = [entry for entry in (compared or {}).get('same', [])]
    different = [entry for entry in (compared or {}).get('different', [])]
    if compared is not None:
        report.facts['comparison'] = {'same': len(same), 'different': different, 'notInOrg': compared.get('absent', 0)}
    if previous:
        report.add('info', 'Names', 'Antsurance is already installed here (%d of %d classes found).' % (len(found['apexClasses']), classes_total),
                   'Installing again updates it in place.', 'previousInstall')
        if compared is not None:
            line = 'Of what this kit holds, %d components are in the org exactly as the kit has them, %d are in the org but differ, and %d are not in the org yet.' % (len(same), len(different), compared.get('absent', 0))
            if different:
                by_kind = {}
                for entry in different:
                    by_kind.setdefault(preflight.KIND_WORDS.get(entry['kind'], entry['kind']), []).append(entry['name'])
                line += ' Differing: ' + '; '.join('%d %s (%s%s)' % (len(items), kind, ', '.join(items[:3]), ' and others' if len(items) > 3 else '') for kind, items in sorted(by_kind.items(), key=lambda item: -len(item[1]))[:6]) + '.'
            report.add('note' if different else 'info', 'Names', line,
                       'An update replaces the ones that differ with this kit\'s version and adds the ones that are missing. If you changed any of them in the org on purpose (the model in Antsurance AI Setting, a page), note the change first: the full list is in setup-report.json under facts.comparison.' if different
                       else 'The org matches this kit. An update would change nothing of ours.', 'alreadyInstalled')
        known = set(ours['apexClasses']) | set(ours.get('portalClasses', []))
        left_over = [name for name in names(answers['classes'], 'Name') if name not in known]
        if left_over:
            report.add('note', 'Names', 'The org has %d Antsurance classes this kit does not hold: %s.' % (len(left_over), ', '.join(left_over[:6]) + (' and others' if len(left_over) > 6 else '')),
                       'They are from another version of the app, or the optional portal. An update leaves them where they are; the uninstall removes only what this kit lists.', 'leftOverClasses', left_over)
    elif part:
        line = 'The %s part of Antsurance is installed here by itself (%d of its %d classes found). The rest of the app is not.' % (part.get('label', part['name']), len(found['apexClasses']), len((part.get('members') or {}).get('ApexClass', [])))
        if compared is not None:
            line += ' Of that part, %d components are in the org as this kit has them and %d differ%s.' % (len(same), len(different), ' (%s)' % ', '.join(entry['name'] for entry in different[:5]) if different else '')
        report.facts['installedPart'] = part['name']
        report.facts['installedParts'] = part.get('installed') or [part['name']]
        report.add('note', 'Names', line, 'Not a clash. Installing that part again updates it in place. FEATURES.md says what going from this part to the whole app involves, and what each other part would bring with it.', 'partInstalled')
        # What carries one of our names and is in none of the parts installed here is still a clash, and only that.
        for kind, items in found.items():
            strays = [item for item in items if item.split('.')[-1] not in part['names']]
            if strays:
                report.add('stop', 'Names', 'In the org with one of our names, and in none of the parts installed here (%s): %s.' % (kind, ', '.join(strays[:8]) + (' and %d more' % (len(strays) - 8) if len(strays) > 8 else '')),
                           'Decide for each: it is ours, left from an earlier install or removal (remove it, or go ahead and the install will overwrite it), or it is yours (install in a scratch org instead). Ours keep their names: we do not rename ours to step around yours, and never rename yours.', 'nameClash', {kind: strays})
    elif left_by_an_uninstall(found, describes, ours) and not same and not different:
        shown = ', '.join(found['recordTypes'])
        removed_at = uninstalled_from_here(report)
        if removed_at:
            report.add('note', 'Names', 'Our record types are still in the org, switched off where Salesforce allows it: %s. The uninstall run from this kit on %s left them, because Salesforce does not let an installer delete a record type. Nothing else of ours is here.' % (shown, removed_at),
                       'Not a clash. Installing the app or a part of it again switches them on again. To be rid of them instead, delete them in Setup, Object Manager, the object, Record Types.', 'leftByUninstall', {'recordTypes': found['recordTypes']})
        else:
            report.add('change', 'Names', 'Record types with our names are in the org and nothing else of ours is: %s. They are as our uninstall leaves them: switched off, or on only because an object keeps its last active record type.' % shown,
                       'Decide: if Antsurance was removed from this org before, they are ours, and installing the app or a part of it again switches them on again (go ahead). If one is a record type of your own, installing would overwrite it: install in a scratch org instead.', 'leftByUninstall', {'recordTypes': found['recordTypes']})
    elif count or same or different:
        differs = {(entry['kind'], entry['name'].split('.')[-1]): entry for entry in different}
        matches = {(entry['kind'], entry['name'].split('.')[-1]) for entry in same}
        for kind, items in found.items():
            if not items:
                continue
            shown = ', '.join(items[:8]) + (' and %d more' % (len(items) - 8) if len(items) > 8 else '')
            told = ''
            if compared is not None:
                bare = [item.split('.')[-1] for item in items]
                alike = len([one for one in bare if any(key[1] == one for key in matches)])
                unlike = len([one for one in bare if any(key[1] == one for key in differs)])
                if alike or unlike:
                    told = ' %d identical to ours, %d different.' % (alike, unlike)
            report.add('stop', 'Names', 'Already in the org with one of our names (%s): %s.%s' % (kind, shown, told),
                       'Installing would overwrite these. Decide for each: it is ours from an earlier try (go ahead), or it is yours (install in a scratch org instead). Ours keep their names: we do not rename ours to step around yours, and never rename yours.', 'nameClash', {kind: items})
        listed = {item.split('.')[-1] for items in found.values() for item in items}
        others = [entry for entry in same + different if entry['name'].split('.')[-1] not in listed]
        if others:
            shown = ', '.join('%s %s' % (preflight.KIND_WORDS.get(entry['kind'], entry['kind']), entry['name']) for entry in others[:8]) + (' and %d more' % (len(others) - 8) if len(others) > 8 else '')
            report.add('stop', 'Names', 'The pulled metadata shows more in the org with one of our names: %s.' % shown,
                       'Same decision: ours from an earlier try, or yours. The full list, with what differs in each, is in setup-report.json under facts.comparison.', 'nameClash', {'pulled': [entry['name'] for entry in others]})
    else:
        report.add('info', 'Names', 'Nothing in the org uses any of our names.', 'No clash.')
    return previous


def check_automation(report, answers, describes, kit, previous, inventory=None, kit_root=KIT_ROOT):
    ours = kit['ours']
    writes_to = kit.get('insertsInto', STANDARD_OBJECTS)
    mine = set(ours['apexTriggers'])
    theirs = [row for row in records(answers['triggers']) if row.get('Name') not in mine and row.get('Status') == 'Active' and row.get('TableEnumOrId') in writes_to]
    report.facts['triggers'] = [{'name': row['Name'], 'object': row['TableEnumOrId'], 'namespace': row.get('NamespacePrefix')} for row in theirs]
    our_triggers = preflight.our_triggers(kit_root)
    if theirs:
        shown = ', '.join('%s%s on %s' % (row['NamespacePrefix'] + '.' if row.get('NamespacePrefix') else '', row['Name'], row['TableEnumOrId']) for row in theirs[:8])
        both = sorted({row['TableEnumOrId'] for row in theirs} & set(our_triggers))
        action = 'Yours will run on the customers, claims, service requests, policy sales, quotes and tasks this app creates.'
        if both:
            action += ' On %s both sides have triggers: ours run on your records too, and step aside at once unless the record type is ours (a test in the kit proves it).' % ' and '.join(both)
        action += ' Salesforce does not promise which trigger runs first. Run the install tests in a sandbox to see the two together.'
        report.add('change', 'Automation', 'Your org has triggers on objects this app saves records in: %s%s.' % (shown, ' and %d more' % (len(theirs) - 8) if len(theirs) > 8 else ''), action, 'theirTriggers')
    our_flows = set(ours['flows'])
    flow_rows = records(answers['flowList']) if answers.get('flowList', (False, None))[0] else records(answers['recordFlows'])
    flows = [row for row in flow_rows if row.get('ApiName') not in our_flows and row.get('IsActive', True)
             and row.get('TriggerType') in ('RecordBeforeSave', 'RecordAfterSave', 'RecordBeforeDelete')
             and (row.get('TriggerObjectOrEventId') in writes_to or row.get('TriggerObjectOrEventLabel') in writes_to)]
    report.facts['recordFlows'] = [{'name': row.get('ApiName'), 'object': row.get('TriggerObjectOrEventId') or row.get('TriggerObjectOrEventLabel')} for row in flows]
    if flows:
        shown = ', '.join('%s (%s)' % (row.get('ApiName'), row.get('TriggerObjectOrEventId') or row.get('TriggerObjectOrEventLabel')) for row in flows[:8])
        report.add('change', 'Automation', 'Your org has flows that run when these records are saved: %s.' % shown,
                   'They will run on the records this app creates. Check that none of them needs a field our records leave empty. Our one record-triggered flow is on our own Policy object, so it never runs on your records.', 'theirFlows')

    our_fields = ours['standardObjectFields']
    required = []
    for name in ours.get('insertsInto', []):
        skip = set(our_fields.get(name, []))
        for field_name, field in fields_of(describes.get(name, (False, None))).items():
            if field.get('custom') and field_name not in skip and field.get('createable') and not field.get('nillable') and not field.get('defaultedOnCreate') and field.get('type') != 'boolean':
                required.append('%s.%s' % (name, field_name))
    report.facts['requiredCustomFields'] = required
    if required:
        report.add('stop', 'Automation', 'Your org has required fields of its own on objects this app creates records in: %s.' % ', '.join(required[:10]),
                   'Our code and tests leave them empty, so those saves would fail. Give each a default value, or make it required on the page layout instead of on the field, or install in a scratch org.', 'requiredFields', required)

    our_rules = set(ours.get('validationRules', []))
    rules = []
    for row in records(answers['validationRules']):
        entity = row.get('EntityDefinitionId')
        full = '%s.%s' % (entity, row.get('ValidationName'))
        if entity in STANDARD_OBJECTS and full not in our_rules:
            rules.append(full)
    report.facts['validationRules'] = rules
    # With the pulled formulas, a rule that names a record type is told apart from one that applies to every record.
    narrow = []
    if inventory is not None:
        for full in rules:
            entity, rule = full.split('.', 1)
            formula = ((inventory['objects'].get(entity) or {}).get('validationRules', {}).get(rule) or {}).get('formula', '')
            if 'recordtype' in formula.lower():
                narrow.append(full)
    wide = [full for full in rules if full not in narrow]
    report.facts['validationRulesForEveryRecordType'] = wide if inventory is not None else None
    if wide:
        known = ' that do not name a record type, so they apply to ours too' if inventory is not None else ''
        report.add('change', 'Automation', '%d active validation rule%s of yours on objects this app creates records in%s: %s.' % (len(wide), '' if len(wide) == 1 else 's', known, ', '.join(wide[:8]) + (' and more' if len(wide) > 8 else '')),
                   'A rule that applies to every record type can reject our records and fail our tests. The deploy runs our tests, so a failure names the rule; narrow that rule to your own record types.', 'validationRules', wide)
    if narrow:
        report.add('note', 'Automation', '%d more validation rule%s of yours name a record type in their formula: %s.' % (len(narrow), '' if len(narrow) == 1 else 's', ', '.join(narrow[:8]) + (' and more' if len(narrow) > 8 else '')),
                   'They most likely apply to your record types only and leave ours alone. The tests in the deploy confirm it.', 'validationRulesNarrow', narrow)

    duplicates = ['%s (%s)' % (row.get('DeveloperName'), row.get('SobjectType')) for row in records(answers['duplicateRules'])]
    matching = ['%s (%s)' % (row.get('DeveloperName'), row.get('SobjectType')) for row in records(answers['matchingRules'])]
    report.facts['duplicateRules'] = duplicates
    report.facts['matchingRules'] = matching
    if duplicates:
        report.add('change' if not previous else 'info', 'Automation', 'Active duplicate rules: %s.' % ', '.join(duplicates[:8]),
                   'A rule set to block can stop the demo data from loading, because sample people share surnames and towns. Load demo data only in an org where these are set to alert, or skip it.', 'duplicateRules')

    for name in ('Case', 'Account', 'Opportunity', 'Lead'):
        ok, payload = describes.get(name, (False, None))
        infos = [info for info in (payload or {}).get('recordTypeInfos', []) if not info.get('master')] if ok else []
        mine_types = set(ours['recordTypes'].get(name, []))
        other = sorted(info.get('developerName') for info in infos if info.get('developerName') not in mine_types)
        report.facts.setdefault('recordTypes', {})[name] = other
        if other:
            report.add('info', 'Record types', '%s already has record types: %s.' % (name, ', '.join(other[:8])), 'Ours are added beside them. Nobody sees ours until they are given the permission set.')
        elif mine_types and not infos:
            report.add('change', 'Record types', '%s has no record types today.' % name,
                       'Adding ours gives %s its first record types. People without our permission set keep working as before, but new picklist values we add (see below) show on their records too.' % name, 'firstRecordTypes' + name)
    processes = {}
    for row in records(answers['businessProcesses']):
        processes.setdefault(row.get('TableEnumOrId'), []).append(row.get('Name'))
    report.facts['businessProcesses'] = processes


def check_metadata(report, kit, inventory, compared, previous, kit_root, pulled_root):
    """What only the pulled metadata can say: types, meanings, and what ours would sit beside."""
    ours = kit['ours']
    cost = report.facts['preflight'].get('pull') or {}
    line = 'Pulled %s files of metadata into %s (read only, %s seconds).' % (cost.get('files', '?'), cost.get('folder', '.install/org-metadata/'), cost.get('seconds', '?'))
    said = [note for note in cost.get('warnings', []) if note]
    if said:
        report.add('note', 'Metadata', line + ' The org added: %s' % '; '.join(sorted(set(said))[:3]),
                   'What the org would not hand over is not in the checks below. If it names something this report should have read, sign in as a System Administrator and run the analysis again.', 'pullWarnings')
    else:
        report.add('info', 'Metadata', line, 'This is what the clash checks in this report and org-conventions.md were read from. Safe to delete.')
    if cost and not cost.get('complete', True):
        report.add('change', 'Metadata', 'The org answered the metadata pull with a problem: %s' % ('; '.join(cost.get('warnings', [])[:3]) or 'no reason given'),
                   'The checks below rest on what did come back. Treat anything they do not mention as unknown, and run the analysis again.', 'pullIncomplete')

    types = preflight.field_types(kit_root, pulled_root, kit)
    report.facts['fieldTypeClashes'] = [{'field': field, 'theirs': theirs, 'ours': mine} for field, theirs, mine in types]
    if types:
        shown = '; '.join('%s is %s in the org and %s in the kit' % one for one in types[:6])
        report.add('stop', 'Clashes', 'A field of ours is already in the org as another type: %s.' % shown,
                   'Salesforce will not turn one into the other while the field holds values, and our code expects our type. If the field is yours, install in a scratch org. If it is left from an earlier try, delete it first.', 'fieldTypeClash', [field for field, _, _ in types])

    collisions = preflight.value_set_collisions(kit_root, inventory['valueSets'])
    report.facts['valueSetCollisions'] = [{'set': name, 'value': value, 'differs': what} for name, value, what in collisions]
    if collisions and not previous:
        shown = '; '.join('%s "%s": %s' % one for one in collisions[:6])
        report.add('change', 'Clashes', 'Picklist values you already have that mean something else in this app: %s.' % shown,
                   'The installer keeps yours exactly as they are and does not add ours beside them, so the app would read your value with your meaning. If that changes what closed, won or forecast means for our records, stop and use a scratch org.', 'valueSetCollision')
    elif collisions:
        report.add('note', 'Clashes', 'Picklist values that differ from the kit: %s.' % '; '.join('%s "%s": %s' % one for one in collisions[:6]),
                   'The installer keeps the org\'s. If you changed them on purpose, nothing to do.', 'valueSetCollision')

    labels = []
    for name, wanted in ours['recordTypes'].items():
        have = (inventory['objects'].get(name) or {}).get('recordTypes', {})
        our_labels = {one.replace('_', ' ').lower() for one in wanted}
        labels += ['%s "%s" (%s)' % (name, facts.get('label'), developer) for developer, facts in have.items()
                   if developer not in wanted and (facts.get('label') or '').lower() in our_labels]
    if labels:
        report.add('change', 'Clashes', 'Record types of yours carry the same label as one of ours: %s.' % ', '.join(labels[:6]),
                   'Both would be offered under the same name to anyone who holds our permission set and yours. Ours keeps its name. Decide whether people can tell them apart, or install in a scratch org.', 'recordTypeLabels')

    apps = {name: facts for name, facts in inventory['apps'].items() if name not in set(ours['apps']) and not name.startswith('standard__')}
    stock_bars = sorted(name.replace('standard__', '') for name, facts in inventory['apps'].items() if name.startswith('standard__') and facts.get('utilityBar'))
    bars = sorted(name for name, facts in apps.items() if facts.get('utilityBar'))
    homes = sorted(name for name, facts in inventory['pages'].items() if facts.get('type') == 'HomePage' and name not in set(ours.get('flexipages', [])))
    report.facts['apps'] = [{'name': name, 'label': facts.get('label'), 'utilityBar': facts.get('utilityBar'), 'console': facts.get('console')} for name, facts in sorted(apps.items())]
    report.facts['homePages'] = homes
    if apps or homes:
        what = 'Your org has %d app%s of its own%s' % (len(apps), '' if len(apps) == 1 else 's', ' (%s)' % ', '.join(sorted(apps)[:6]) if apps else '')
        what += ', %d with a utility bar (%s)' % (len(bars), ', '.join(bars[:4])) if bars else ', none with a utility bar'
        what += ', and %d Home page%s of its own (%s).' % (len(homes), '' if len(homes) == 1 else 's', ', '.join(homes[:4])) if homes else ', and no Home page of its own.'
        if stock_bars:
            what += ' Salesforce\'s own %s app%s a utility bar too.' % (' and '.join(stock_bars[:3]), ' has' if len(stock_bars) == 1 else 's have')
        report.add('note', 'Beside yours', what,
                   'Ours is one more app in the App Launcher, with its own utility bar and its own Home page, both assigned inside our app only. Your apps, utility bars, Home pages and everyone\'s default app stay as they are. To put Ask Claude on a utility bar of yours, that is a change to your app: see FEATURES.md.', 'besideYours')

    needed = {}
    for name in kit.get('insertsInto', []):
        skip = set(ours['standardObjectFields'].get(name, []))
        for layout in inventory['layouts'].get(name, []):
            if layout['name'] in set(ours.get('layouts', [])):
                continue
            for field in layout['required']:
                if field.endswith('__c') and field not in skip:
                    needed.setdefault('%s.%s' % (name, field), []).append(layout['name'])
    report.facts['layoutRequiredFields'] = needed
    if needed:
        report.add('note', 'Beside yours', 'Your page layouts mark these fields of yours as required: %s.' % ', '.join(sorted(needed)[:8]) + (' and more' if len(needed) > 8 else ''),
                   'Our code is not held to a layout, so its saves still work. People who create one of our records through the standard New dialog see your default layout there and will be asked for these.', 'layoutRequired')


def check_value_sets(report, describes, kit, answers):
    merged = {}
    for set_name, (object_name, field_name) in VALUE_SET_FIELDS.items():
        field = fields_of(describes.get(object_name, (False, None))).get(field_name)
        ours = [value['fullName'] for value in kit['standardValueSets'].get(set_name, [])]
        if field is None:
            merged[set_name] = {'current': None, 'toAdd': ours}
            continue
        current = [value['value'] for value in field.get('picklistValues', []) if value.get('active')]
        to_add = [value for value in ours if value not in current]
        merged[set_name] = {'current': current, 'toAdd': to_add}
        if to_add:
            report.add('change', 'Picklists', '%s.%s has %d value%s today. Ours adds: %s.' % (object_name, field_name, len(current), '' if len(current) == 1 else 's', ', '.join(to_add)),
                       'The installer adds these and keeps every value you have. It never removes or reorders yours.', 'mergeValueSet', {set_name: to_add})
        else:
            report.add('info', 'Picklists', '%s.%s already has every value we use.' % (object_name, field_name), 'Nothing to add.')
    report.facts['valueSets'] = merged


def check_sharing(report, answers):
    kept = {row['QualifiedApiName']: {'internal': row.get('InternalSharingModel'), 'external': row.get('ExternalSharingModel')} for row in records(answers['sharing'])}
    report.facts['sharing'] = kept
    if kept:
        line = ', '.join('%s %s' % (name, value['internal']) for name, value in sorted(kept.items()))
        report.add('info', 'Sharing', 'Who can see records by default: %s.' % line,
                   'The installer does not change these. Policies follow the sharing of the customer they belong to.')
    private = [name for name, value in kept.items() if value['internal'] == 'Private' and name in ('Account', 'Case', 'Opportunity')]
    if private:
        report.add('change', 'Sharing', '%s records are private in this org.' % ' and '.join(sorted(private)),
                   'People given access to the app will see only the records your sharing rules let them see. Give test users a role above the record owners, or share the sample records with them.', 'privateSharing')


def check_people(report, answers):
    licenses = {row['Name']: {'total': row.get('TotalLicenses'), 'used': row.get('UsedLicenses'), 'status': row.get('Status')} for row in records(answers['licenses'])}
    report.facts['licenses'] = licenses
    full = licenses.get('Salesforce')
    if full:
        report.add('info', 'People', 'Salesforce licenses: %s of %s in use.' % (full['used'], full['total']), 'Everyone who uses the app needs one. The installer creates no users.')
    portal = [name for name in licenses if name.startswith('Customer Community') and (licenses[name]['total'] or 0) > (licenses[name]['used'] or 0)]
    if portal:
        report.add('info', 'People', 'Portal licenses free: %s.' % ', '.join('%s (%s)' % (name, licenses[name]['total'] - licenses[name]['used']) for name in portal), 'Enough to try the optional customer portal.')
    else:
        report.add('info', 'People', 'No free Customer Community license.', 'The optional customer portal needs one for each customer who signs in. Skip the portal, or use a scratch org.')
    profiles = [{'profile': row.get('profile'), 'license': row.get('license'), 'people': row.get('people')} for row in records(answers['profiles'])]
    roles = [{'role': row.get('role'), 'people': row.get('people')} for row in records(answers['roles'])]
    sets = [{'name': row.get('name'), 'label': row.get('label'), 'people': row.get('people')} for row in records(answers['assignedSets'])]
    report.facts['profiles'], report.facts['roles'], report.facts['permissionSetsInUse'] = profiles, roles, sets
    internal = sum(row['people'] or 0 for row in profiles if row['license'] == 'Salesforce')
    in_profiles = len([row for row in profiles if row['license'] == 'Salesforce'])
    report.add('info', 'People', '%d active people on a Salesforce license, in %d profile%s.' % (internal, in_profiles, '' if in_profiles == 1 else 's'),
               'To start, only the person installing gets access. scripts/setup/assign_access.py proposes who else should, when you are ready.')


def check_records(report, answers, facts):
    counts = {name: total(answers['count' + name]) for name in RECORD_COUNTED}
    report.facts['recordCounts'] = counts
    busy = {name: count for name, count in counts.items() if count}
    report.facts['holdsRecords'] = bool(busy)
    if report.facts.get('previousInstall'):
        report.add('info', 'Records', 'The org holds records: %s.' % ', '.join('%s %s' % (count, name) for name, count in busy.items()), 'Some or all are from the earlier install. The demo data is not loaded twice.')
    elif busy:
        report.add('change', 'Records', 'The org holds records of its own: %s.' % ', '.join('%s %s' % (count, name) for name, count in busy.items()),
                   'Do not load the demo data here: it would mix about 2,100 sample records in with yours. Try the demo data in a scratch org.', 'holdsRecords')
    else:
        report.add('info', 'Records', 'The org holds no customer, case, sale or lead records.', 'Safe to load the demo data if you want it.')


def write(report, org):
    verdict = report.verdict()
    when = now()
    cost = report.facts.get('preflight') or {}
    conventions = getattr(report, 'conventions', None)
    if conventions is not None:
        preflight.write_conventions(conventions, report.facts['org'], cost.get('pull'), when)
        report.facts['conventions'] = {'file': 'org-conventions.md', 'data': 'org-conventions.json', 'counts': conventions['counts']}
    data = {'verdict': verdict, 'analysedAt': when, 'targetOrg': org, 'facts': report.facts, 'findings': report.findings}
    with open(os.path.join(KIT_ROOT, 'setup-report.json'), 'w') as handle:
        json.dump(data, handle, indent=2, sort_keys=True)

    facts = report.facts['org']
    lines = ['# Antsurance setup report', '', '**Verdict: %s**' % verdict, '',
             'Org: %s (%s), signed in as %s. Read on %s. Nothing in the org was changed.' % (facts['name'], kind_of(facts), facts['username'], data['analysedAt']), '']
    if cost.get('pulled'):
        lines += ['The org\'s metadata was pulled (read only) and compared with the kit. How this org names and builds things, and the rules for building anything new in it, are in `org-conventions.md`.', '']
    else:
        lines += ['No metadata was pulled%s. `org-conventions.md` says what little the questions alone showed.' % (' (skipped)' if cost.get('mode') == 'never' else ': the pull failed' if cost.get('pullFailed') else ': the org holds nothing of its own and nothing of ours'), '']
    headings = [('stop', 'Stop: fix or choose another org'), ('change', 'Decide before installing'), ('note', 'Worth knowing: no decision needed'), ('info', 'Checked and fine')]
    for level, heading in headings:
        chosen = [finding for finding in report.findings if finding['level'] == level]
        if not chosen:
            continue
        lines += ['## ' + heading, '']
        for finding in chosen:
            lines += ['- **%s.** %s' % (finding['area'], finding['finding']), '  %s' % finding['action']]
        lines.append('')
    lines += ['## What next', '']
    if verdict == 'STOP':
        lines.append('Do not install here yet. The quickest way to see the app is a scratch org: `scripts/setup/test_in_scratch_org.sh --dev-hub <your Dev Hub>`.')
    elif verdict == 'GO WITH CHANGES':
        lines.append('Go through the decisions above, then run the install. In Claude Code, say "install this" and it will ask you each one.')
    else:
        lines.append('Ready to install. In Claude Code, say "install this".')
    with open(os.path.join(KIT_ROOT, 'setup-report.md'), 'w') as handle:
        handle.write('\n'.join(lines) + '\n')
    return verdict


def run():
    parser = argparse.ArgumentParser(description='The preflight: read an org, pull the metadata ours could meet, and report whether Antsurance can be installed in it. Changes nothing.')
    parser.add_argument('--target-org', required=True, help='The alias or username of the org to read')
    parser.add_argument('--pull', action='store_true', help='Pull the metadata even when the org looks new and empty')
    parser.add_argument('--skip-pull', action='store_true', help='Ask the questions only. The clash and convention checks are then thinner.')
    parser.add_argument('--offline', action='store_true', help='Judge the last read of this org again. Calls nothing.')
    parser.add_argument('--pull-again', action='store_true', help='Keep the answers from the last read and pull the metadata again. One call.')
    parser.add_argument('--measure', action='store_true', help='Ask the org at the end how many requests it counted during this run')
    args = parser.parse_args()
    if args.pull and args.skip_pull:
        parser.error('--pull and --skip-pull cannot both be given')
    if args.offline:
        print('Reading the last answers and the last pull from %s again. Nothing is asked of the org.' % args.target_org)
    else:
        print('Reading %s. This changes nothing in the org.' % args.target_org)
    report = analyze(args.target_org, 'always' if args.pull else 'never' if args.skip_pull else 'auto', args.offline, args.pull_again)
    cost = report.facts['preflight']
    if args.measure and not args.offline and not args.pull_again:
        before = ((report.facts.get('limits') or {}).get('DailyApiRequests') or {}).get('remaining')
        after = ((rest(args.target_org, '/services/data/v%s/limits' % manifest().get('apiVersion', '67.0')) or {}).get('DailyApiRequests') or {}).get('Remaining')
        if before is not None and after is not None:
            # The first reading is taken inside the first batch of questions, so the count starts there.
            cost['measuredRequests'] = before - after
    verdict = write(report, args.target_org)
    counts = {level: len([f for f in report.findings if f['level'] == level]) for level in ('stop', 'change', 'note', 'info')}
    print('Verdict: %s  (%d to stop on, %d to decide, %d worth knowing, %d fine)' % (verdict, counts['stop'], counts['change'], counts['note'], counts['info']))
    words = {'stop': 'STOP', 'change': 'DECIDE', 'note': 'NOTE'}
    for finding in report.findings:
        if finding['level'] != 'info':
            print('  [%s] %s. %s' % (words[finding['level']], finding['area'], finding['finding']))
    if cost.get('pulled'):
        pulled = cost.get('pull') or {}
        print('Metadata: %s files in %s. The org holds %s.' % (pulled.get('files'), pulled.get('folder'), ', '.join(cost.get('why') or ['nothing of its own']) ))
    else:
        print('Metadata: not pulled (%s).' % ('skipped' if cost.get('mode') == 'never' else 'the pull failed, see the DECIDE line above' if cost.get('pullFailed') else 'the org holds nothing of its own and nothing of ours'))
    if not args.offline:
        line = 'Cost: %d sf commands, about %d requests against the org\'s daily allowance.' % (USAGE['commands'], USAGE['requests'])
        if cost.get('measuredRequests') is not None:
            line += ' The org counted %d from the first batch of questions to the end, other tools included.' % cost['measuredRequests']
        print(line)
    print('Full report: setup-report.md and setup-report.json in ' + KIT_ROOT)
    print('Conventions: org-conventions.md and org-conventions.json. Read them before building anything new in this org.')


if __name__ == '__main__':
    main(run)
