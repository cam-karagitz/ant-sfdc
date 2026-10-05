#!/usr/bin/env python3
"""Deploys one phase of the install to an org.

Phases, in the order an install runs them:
  prerequisites   Turns on Quotes and Path if they are off. Org-wide switches, so each must be named with --enable.
  value-sets      Adds our values to five standard picklists. Reads the org's own values first and keeps every one.
  core            The data model, code, pages, app, flows and reports. Runs our tests.
  look-and-feel   Optional. The theme and renaming Accounts to Customers. Changes what everyone in the org sees.
  portal          Optional. The customer portal. Needs Digital Experiences, which cannot be turned off again.

Or one part of the app, with whatever that part needs (FEATURES.md lists the parts; --list prints them):
  --only data-model   Our objects, fields and record types. No code, no screens.
  --only automation   The triggers, their classes and the flows. Needs the data model, and installs it first if it is not there.
  --only components   Every screen component and the Apex it calls, the Claude features among them. Needs the data model.
  --only pages        The app, its tabs, record pages, layouts, buttons and paths. Needs all three of the above.
  --only ask-claude   The Ask Claude chat: a tab and a utility bar item, in an app of their own. Adds no object, field,
                      record type or picklist value, and changes nothing the org already has. Runs its own tests.
  --only portal, --only look-and-feel    The optional phases, after a check that what they are built on is in the org.
Before anything is deployed it says what the part needs, what is already in the org and what will be installed.

Usage:
  python3 scripts/setup/deploy_phase.py --list                                          (the choices; calls no org)
  python3 scripts/setup/deploy_phase.py --target-org <alias> --phase core --dry-run     (check only, changes nothing)
  python3 scripts/setup/deploy_phase.py --target-org <alias> --phase core
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --dry-run
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --remove          (says what would go)
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --remove --yes
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only automation --dry-run
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only automation
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only automation --remove [--yes]
  python3 scripts/setup/deploy_phase.py --target-org <alias> --only portal --remove [--yes]      (the site itself stays, emptied)

Nothing in the kit's own folders is edited. Each phase is copied to stage/<phase>/ with this org's details filled in,
and that copy is what gets deployed.
"""
import json
import argparse
import os
import re
import shutil
import sys
import tempfile
import uuid
import zipfile
from xml.sax.saxutils import escape

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capabilities  # noqa: E402
from _common import KIT_ROOT, SetupError, announce, api_version, batch, coverage_gate, coverage_rows, describe_org, guard_production, in_list, low_coverage_lines, main, manifest, record, records, rest, sf, soql, stage_project, tooling  # noqa: E402

STAGE = os.path.join(KIT_ROOT, 'stage')
PHASES = ['prerequisites', 'value-sets', 'core', 'look-and-feel', 'portal']
VALUE_SETS = ['CaseOrigin', 'CaseStatus', 'OpportunityStage', 'OpportunityType', 'QuoteStatus']
NAMESPACE = 'http://soap.sforce.com/2006/04/metadata'
SETTINGS = {'quotes': 'Quote.settings-meta.xml', 'path': 'PathAssistant.settings-meta.xml'}


def stage_dir(phase):
    """An empty folder under stage/ for this phase's copy."""
    path = os.path.join(STAGE, phase)
    if os.path.isdir(path):
        shutil.rmtree(path)
    os.makedirs(path)
    return path


def fill_in(source, target, values):
    """Copies a folder, replacing {{NAME}} markers in text files with this org's values. Fails if a marker is left over."""
    left_over = []
    for folder, _, files in os.walk(source):
        for name in files:
            from_path = os.path.join(folder, name)
            to_path = os.path.join(target, os.path.relpath(from_path, source))
            os.makedirs(os.path.dirname(to_path), exist_ok=True)
            try:
                with open(from_path, encoding='utf-8') as handle:
                    text = handle.read()
            except UnicodeDecodeError:
                shutil.copyfile(from_path, to_path)
                continue
            if '{{' in text:
                for marker, value in values.items():
                    text = text.replace('{{%s}}' % marker, escape(value) if name.endswith('.xml') else value)
                left_over += ['%s: %s' % (os.path.relpath(from_path, KIT_ROOT), found) for found in re.findall(r'\{\{[A-Z_]+\}\}', text)]
            with open(to_path, 'w', encoding='utf-8') as handle:
                handle.write(text)
    if left_over:
        raise SetupError('These files still have a blank the installer could not fill in: ' + '; '.join(sorted(set(left_over))[:5]))


def org_values(org):
    answers = batch(org['alias'], [('me', soql("SELECT Username, Email FROM User WHERE Username = '%s'" % org['username'].replace("'", "\\'")))])
    rows = records(answers['me'])
    if not rows:
        raise SetupError('Could not read the signed-in user (%s) from the org.' % org['username'])
    return {'RUNNING_USER': rows[0]['Username'], 'SENDER_EMAIL': rows[0]['Email']}


# ---------------------------------------------------------------- standard value sets

def parse_value_set(text):
    """The head of the file, its value blocks, and its tail, as text, plus each value's name."""
    blocks = re.findall(r'[ \t]*<standardValue>.*?</standardValue>\n?', text, re.S)
    names = [re.search(r'<fullName>(.*?)</fullName>', block, re.S).group(1).strip() for block in blocks]
    return blocks, names


def merge_value_set(theirs, ours):
    """The org's file with our missing values added after its own. Nothing of the org's is removed, changed or reordered."""
    our_blocks, our_names = parse_value_set(ours)
    if theirs is None:
        return ours, our_names, []
    their_blocks, their_names = parse_value_set(theirs)
    have = {name.lower() for name in their_names}
    added = [(name, block) for name, block in zip(our_names, our_blocks) if name.lower() not in have]
    if not added:
        return theirs, [], their_names
    extra = ''
    for _, block in added:
        # Only one value may be the default, and the org's own choice stands.
        block = re.sub(r'<default>true</default>', '<default>false</default>', block)
        extra += block if block.endswith('\n') else block + '\n'
    close = theirs.rindex('</StandardValueSet>')
    head = theirs[:close]
    if not head.endswith('\n'):
        head += '\n'
    return head + extra + theirs[close:], [name for name, _ in added], their_names


def retrieve_value_sets(org_alias):
    """The org's current five picklists, read into a temporary folder. Returns {name: xml text}."""
    work = tempfile.mkdtemp(prefix='antsurance-valuesets-')
    try:
        args = ['project', 'retrieve', 'start', '--target-org', org_alias, '--target-metadata-dir', work, '--unzip', '--wait', '20']
        for name in VALUE_SETS:
            args += ['--metadata', 'StandardValueSet:' + name]
        sf(args)
        found = {}
        for folder, _, files in os.walk(work):
            for name in files:
                if name.endswith('.standardValueSet'):
                    with open(os.path.join(folder, name), encoding='utf-8') as handle:
                        found[name.split('.')[0]] = handle.read()
        if not found:
            # Some CLI versions leave the zip in place.
            for folder, _, files in os.walk(work):
                for name in files:
                    if name.endswith('.zip'):
                        with zipfile.ZipFile(os.path.join(folder, name)) as archive:
                            for entry in archive.namelist():
                                if entry.endswith('.standardValueSet'):
                                    found[os.path.basename(entry).split('.')[0]] = archive.read(entry).decode('utf-8')
        return found
    finally:
        shutil.rmtree(work, ignore_errors=True)


def stage_value_sets(org):
    target = stage_dir('value-sets')
    folder = os.path.join(target, 'standardValueSets')
    os.makedirs(folder)
    theirs = retrieve_value_sets(org['alias'])
    summary = {}
    for name in VALUE_SETS:
        with open(os.path.join(KIT_ROOT, 'optional', 'value-sets', 'standardValueSets', name + '.standardValueSet-meta.xml'), encoding='utf-8') as handle:
            ours = handle.read()
        merged, added, kept = merge_value_set(theirs.get(name), ours)
        summary[name] = {'kept': len(kept), 'added': added}
        if theirs.get(name) is not None and not added:
            print('  %s: the org already has every value we use (%d values kept).' % (name, len(kept)))
            continue
        with open(os.path.join(folder, name + '.standardValueSet-meta.xml'), 'w', encoding='utf-8') as handle:
            handle.write(merged)
        print('  %s: keeping %d of yours, adding %s.' % (name, len(kept), ', '.join(added) if added else 'nothing'))
    if not os.listdir(folder):
        return None, summary
    return target, summary


# ---------------------------------------------------------------- staging each phase

def stage(phase, org, enable):
    if phase == 'prerequisites':
        if not enable:
            raise SetupError('Name what to turn on: --enable quotes, --enable path, or both. Each is an org-wide switch, so it is never turned on unasked.')
        target = stage_dir(phase)
        os.makedirs(os.path.join(target, 'settings'))
        for name in enable:
            shutil.copyfile(os.path.join(KIT_ROOT, 'optional', 'settings', SETTINGS[name]), os.path.join(target, 'settings', SETTINGS[name]))
        return target, {'turnedOn': enable}
    if phase == 'value-sets':
        return stage_value_sets(org)
    values = org_values(org)
    target = stage_dir(phase)
    source = os.path.join(KIT_ROOT, 'force-app') if phase == 'core' else os.path.join(KIT_ROOT, 'optional', phase)
    if not os.path.isdir(source):
        raise SetupError('This kit has no "%s" phase (%s is missing).' % (phase, os.path.relpath(source, KIT_ROOT)))
    fill_in(source, target, values)
    return target, {}


# ---------------------------------------------------------------- the data model goes first

MODEL_FOLDERS = ['objects', 'globalValueSets', 'groups']
KEPT_IN_A_FIRST_PERMISSION_SET = ('description', 'hasActivationRequired', 'label', 'license', 'objectPermissions', 'fieldPermissions', 'recordTypeVisibilities')


def stage_model(core):
    """The data model by itself: objects, fields, record types, and our permission sets cut down to those.

    Our tests save records as the person installing, and Salesforce checks that person's access to every field.
    In a new org nobody has that access until a permission set exists and is assigned. So the model and the
    permission sets go in first, with no code and so no tests, and the person installing is assigned them.
    Then everything deploys, with its tests.
    """
    target = stage_dir('core-model')
    source = os.path.join(core, 'main', 'default')
    for folder in MODEL_FOLDERS:
        if os.path.isdir(os.path.join(source, folder)):
            shutil.copytree(os.path.join(source, folder), os.path.join(target, folder))
    os.makedirs(os.path.join(target, 'permissionsets'))
    for name in sorted(os.listdir(os.path.join(source, 'permissionsets'))):
        with open(os.path.join(source, 'permissionsets', name), encoding='utf-8') as handle:
            text = handle.read()
        blocks = re.findall(r'    <(\w+)>.*?</\1>\n', text, re.S)
        kept = ''.join(match.group(0) for match in re.finditer(r'    <(\w+)>.*?</\1>\n', text, re.S) if match.group(1) in KEPT_IN_A_FIRST_PERMISSION_SET)
        if not blocks:
            raise SetupError('Could not read the permission set %s.' % name)
        with open(os.path.join(target, 'permissionsets', name), 'w', encoding='utf-8') as handle:
            handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<PermissionSet xmlns="%s">\n%s</PermissionSet>\n' % (NAMESPACE, kept))
    return target


def holds_our_sets(org):
    """Which of our permission sets exist in the org, and which of them the person installing holds."""
    sets = manifest()['ours']['permissionSets']
    internal = sorted({name for name in sets if 'Portal' not in name})
    answers = batch(org['alias'], [
        ('sets', soql('SELECT Id, Name FROM PermissionSet WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(internal))),
        ('me', soql("SELECT Id FROM User WHERE Username = '%s'" % org['username'].replace("'", "\\'"))),
        ('mine', soql("SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE Assignee.Username = '%s' AND PermissionSet.NamespacePrefix = null AND PermissionSet.Name IN (%s)" % (org['username'].replace("'", "\\'"), in_list(internal)))),
    ])
    existing = {row['Name']: row['Id'] for row in records(answers['sets'])}
    mine = {(row.get('PermissionSet') or {}).get('Name') for row in records(answers['mine'])}
    me = (records(answers['me']) or [{}])[0].get('Id')
    return internal, existing, mine, me


def give_installer_access(org):
    """Assigns our permission sets to the person installing, so the tests can run as them. Returns the names newly assigned."""
    internal, existing, mine, me = holds_our_sets(org)
    missing = [name for name in internal if name in existing and name not in mine]
    if not missing:
        return []
    rows = [{'attributes': {'type': 'PermissionSetAssignment'}, 'AssigneeId': me, 'PermissionSetId': existing[name]} for name in missing]
    reply = rest(org['alias'], '/services/data/v%s/composite/sobjects' % api_version(), 'POST', {'allOrNone': True, 'records': rows})
    problems = ['%s: %s' % (error.get('statusCode'), error.get('message')) for result in reply or [] if not result.get('success') for error in result.get('errors', [])]
    if problems:
        raise SetupError('Could not give you our permission sets, which the tests need: ' + '; '.join(problems[:3]))
    return missing


def tests_for(phase):
    if phase.startswith(ONLY):
        name = phase[len(ONLY):]
        if name in slices():
            return slice_named(name)['tests']
        # A small step of the installer's own (a permission set put in first) is no part and has no tests.
        return list((manifest().get('capabilities') or {}).get(name, {}).get('tests') or [])
    key = {'core': 'apexTestClasses', 'portal': 'portalTestClasses'}.get(phase)
    return manifest()['ours'].get(key, []) if key else []


# ---------------------------------------------------------------- one part of the app alone

ONLY = 'only-'


def slices():
    """The parts of the app that install alone, as the kit's build described them."""
    return manifest().get('slices') or {}


def slice_named(name):
    found = slices().get(name)
    if not found:
        raise SetupError('This kit has no part called "%s" that installs alone. It has: %s.' % (name, ', '.join(sorted(slices())) or 'none'))
    path = os.path.join(KIT_ROOT, found['path'], 'slice.json')
    if not os.path.exists(path):
        raise SetupError('%s is missing from the kit.' % os.path.relpath(path, KIT_ROOT))
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)


def count_of(members):
    return sum(len(names) for names in members.values())


def stage_slice(name):
    """A copy of the slice under stage/, which is what gets deployed. A slice has no blanks to fill in."""
    part = slice_named(name)
    target = stage_dir(ONLY + name)
    fill_in(os.path.join(KIT_ROOT, part['path'], 'main'), os.path.join(target, 'main'), {})
    return target


def give_set(org, set_name):
    """Assigns one permission set to the person installing, if they do not hold it. Returns True when it was assigned now."""
    user = org['username'].replace("'", "\\'")
    answers = batch(org['alias'], [
        ('set', soql("SELECT Id FROM PermissionSet WHERE NamespacePrefix = null AND Name = '%s'" % set_name)),
        ('me', soql("SELECT Id FROM User WHERE Username = '%s'" % user)),
        ('mine', soql("SELECT Id FROM PermissionSetAssignment WHERE Assignee.Username = '%s' AND PermissionSet.NamespacePrefix = null AND PermissionSet.Name = '%s'" % (user, set_name))),
    ])
    found, me = records(answers['set']), records(answers['me'])
    if not found or not me:
        raise SetupError('Could not find the permission set %s, or you, in the org.' % set_name)
    if records(answers['mine']):
        return False
    reply = rest(org['alias'], '/services/data/v%s/sobjects/PermissionSetAssignment' % api_version(), 'POST', {'AssigneeId': me[0]['Id'], 'PermissionSetId': found[0]['Id']})
    if not (reply or {}).get('success'):
        raise SetupError('Could not give you the permission set %s: %s' % (set_name, str(reply)[:300]))
    return True


def install_slice(org, name, args):
    part = slice_named(name)
    members = part['members']
    announce(org, '%s only "%s" (%d components, %d test classes). Nothing else of the app is touched.'
             % ('CHECK (dry run, nothing changes)' if args.dry_run else 'DEPLOY', part['label'], count_of(members), len(part['tests'])))
    guard_production(org, args.allow_production)
    for line in part.get('changes', []):
        print('  ' + line)
    staged = stage_slice(name)
    reply = deploy(org, ONLY + name, staged, args.dry_run, args.wait, args.run_async, args.test_level)
    if args.run_async:
        job = (reply.get('result') or {}).get('id')
        if not job:
            raise SetupError('The org did not accept the deploy: ' + str(reply.get('message'))[:500])
        print('Started. Job id %s. Check it with: python3 scripts/setup/deploy_phase.py --target-org %s --report %s' % (job, args.target_org, job))
        print('When it has succeeded, give yourself access: sf org assign permset --name %s --target-org %s' % (part['permissionSet'], args.target_org))
        return
    ok, lines, job = summarize(reply)
    print('\n'.join(lines))
    if not args.dry_run:
        record(org, ONLY + name, 'deployed' if ok else 'failed', {'job': job})
    if not ok:
        raise SetupError('"%s" did not %s. Nothing was half-applied: a failed deploy is rolled back by Salesforce. Fix what is listed above and run it again.'
                         % (part['label'], 'pass its check' if args.dry_run else 'deploy'))
    if args.dry_run:
        print('"%s" would deploy cleanly.' % part['label'])
        return
    print('"%s" is in the org.' % part['label'])
    if give_set(org, part['permissionSet']):
        print('Gave you the permission set %s. Nobody else was given anything.' % part['permissionSet'])
    print('Next:')
    print('  1. Store your Claude API key (hidden prompt):  python3 scripts/setup/set_api_key.py --target-org %s' % args.target_org)
    print('  2. Check Claude answers from the org:           python3 scripts/setup/smoke_test.py --target-org %s' % args.target_org)
    print('  3. Open it:                                     sf org open --target-org %s --path /lightning/app/c__%s' % (args.target_org, part['app']))
    print('  To give someone else access:                    sf org assign permset --name %s --target-org %s --on-behalf-of <their username>' % (part['permissionSet'], args.target_org))


# What uses a thing goes before the thing, each step a removal of its own: the app and access to it, then the screens,
# the code and the connection to Claude, then what those were built on.
REMOVAL_STEPS = [
    ['CustomApplication', 'PermissionSet'],
    ['CustomTab', 'FlexiPage', 'LightningComponentBundle', 'ApexClass', 'CustomMetadata', 'NamedCredential'],
    ['ExternalCredential', 'CustomObject', 'StaticResource'],
]


def remove_slice(org, name, args):
    part = slice_named(name)
    members = part['members']
    announce(org, '%s only "%s" (%d components)' % ('REMOVE' if args.yes else 'show what removing would take away (nothing changes) for', part['label'], count_of(members)))
    guard_production(org, args.allow_production)
    user_rows = records(batch(org['alias'], [('held', soql(
        "SELECT Id, Assignee.Username FROM PermissionSetAssignment WHERE PermissionSet.NamespacePrefix = null AND PermissionSet.Name = '%s'" % part['permissionSet']))])['held'])
    for kind in [kind for step in REMOVAL_STEPS for kind in step]:
        if members.get(kind):
            print('  %s: %s' % (kind, ', '.join(members[kind])))
    unlisted = sorted(set(members) - {kind for step in REMOVAL_STEPS for kind in step})
    if unlisted:
        raise SetupError('This script does not know in what order to remove: %s. Nothing was changed.' % ', '.join(unlisted))
    print('  Access taken away from %d %s. The Claude API key stored in the credential goes with it.' % (len(user_rows), 'person' if len(user_rows) == 1 else 'people'))
    print('  No record of yours is deleted: this part of the app keeps none.')
    lines, stop = say_used_by_theirs(*used_by_theirs(org, manifest(), members.get('ApexClass', [])))
    print('\n'.join(lines))
    if not args.yes:
        print('Nothing was changed. %s' % ('Change or remove what is listed above first: this would stop there with --yes.' if stop else 'Run it again with --yes to remove it.'))
        return
    if stop:
        raise SetupError(stop)
    held = [row['Id'] for row in user_rows]
    version = 'v' + api_version()
    for start in range(0, len(held), 25):
        chunk = held[start:start + 25]
        body = {'haltOnError': False, 'batchRequests': [{'method': 'DELETE', 'url': '%s/sobjects/PermissionSetAssignment/%s' % (version, one)} for one in chunk]}
        reply = rest(org['alias'], '/services/data/%s/composite/batch' % version, 'POST', body)
        failed = [result for result in (reply or {}).get('results') or [] if not 200 <= result.get('statusCode', 500) < 300]
        if failed:
            raise SetupError('Could not take away access to "%s": %s' % (part['label'], str(failed[0].get('result'))[:300]))
    for number, step in enumerate(REMOVAL_STEPS, 1):
        kinds = [kind for kind in step if members.get(kind)]
        if not kinds:
            continue
        target = stage_dir('%s%s-remove-%d' % (ONLY, name, number))
        types = ''.join('    <types>\n%s        <name>%s</name>\n    </types>\n' % (''.join('        <members>%s</members>\n' % escape(one) for one in members[kind]), kind) for kind in kinds)
        for file_name, body in (('destructiveChanges.xml', types), ('package.xml', '')):
            with open(os.path.join(target, file_name), 'w', encoding='utf-8') as handle:
                handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="%s">\n%s    <version>%s</version>\n</Package>\n' % (NAMESPACE, body, api_version()))
        command = ['project', 'deploy', 'start', '--target-org', org['alias'], '--metadata-dir', target, '--ignore-warnings', '--wait', str(args.wait)]
        if args.test_level == 'NoTestRun':
            command += ['--test-level', 'NoTestRun']
        ok, lines, job = summarize(sf(command, timeout=args.wait * 60 + 300, allow_failure=True))
        print('\n'.join(['Step %d of %d (%s): %s' % (number, len(REMOVAL_STEPS), ', '.join(kinds), lines[0])] + lines[1:]))
        record(org, '%s%s-remove-%d' % (ONLY, name, number), 'removed' if ok else 'failed', {'job': job})
        if not ok:
            raise SetupError('"%s" was not removed in full: step %d of %d failed, and Salesforce rolled that step back. Access was taken away and the earlier steps stand. '
                             'Fix what is listed above and run this again: what is already gone is skipped.' % (part['label'], number, len(REMOVAL_STEPS)))
    print('"%s" is removed.' % part['label'])


# ---------------------------------------------------------------- a capability cut from the app, with what it needs

# What uses a thing goes before the thing. Only the kinds a capability really holds are removed; an empty step is skipped.
LAYER_REMOVAL_STEPS = [
    ['CustomApplication', 'PermissionSet'],
    ['FlexiPage', 'QuickAction', 'CustomTab', 'PathAssistant', 'Layout'],
    ['ApexTrigger', 'Flow'],
    ['LightningComponentBundle', 'AuraDefinitionBundle', 'ApexPage', 'ApexClass', 'NamedCredential', 'CustomNotificationType', 'CustomPermission', 'CspTrustedSite', 'RemoteSiteSetting'],
    ['ExternalCredential', 'StaticResource', 'ContentAsset'],
]


def stage_layer(name):
    """A copy of one capability's own files under stage/: its files from force-app/, and its permission set."""
    part = capabilities.detail(name)
    target = stage_dir(ONLY + name)
    source = os.path.join(KIT_ROOT, 'force-app', 'main', 'default')
    for path in part['fileList']:
        from_path, to_path = os.path.join(source, path), os.path.join(target, 'main', 'default', path)
        if not os.path.exists(from_path):
            raise SetupError('%s is listed for "%s" and is missing from the kit.' % (os.path.join('force-app', 'main', 'default', path), part['label']))
        os.makedirs(os.path.dirname(to_path), exist_ok=True)
        shutil.copyfile(from_path, to_path)
    own = os.path.join(KIT_ROOT, part['path'], 'main')
    if os.path.isdir(own):
        fill_in(own, os.path.join(target, 'main'), {})
    return target


def coverage_line(result, part):
    """One line saying how the classes and triggers of this set are covered by the tests the deploy ran."""
    covered = part.get('covered') or {}
    if not covered.get('classes') and not covered.get('triggers'):
        return None

    def has_code(name):
        path = os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'classes', name + '.cls')
        if not os.path.exists(path):
            return None
        from _common import apex_has_code
        with open(path, encoding='utf-8') as handle:
            return apex_has_code(handle.read())
    found, problems = coverage_gate(coverage_rows(result), covered.get('classes', []), covered.get('triggers', []), has_code)
    if problems:
        return 'Coverage: short of the bar (%s). %s' % (', '.join(problems), ' '.join(found['lines'][:6]))
    return 'Coverage: %s. Every class and trigger in this set is at 75 percent or more. Lowest: %s.' % (found['summary'].replace('our code', 'this set'), found['lowest'])


def hold_first(org, part, have, args):
    """A permission set a part carries whole (the desk's) holds a permission one of the part's tests checks for the
    person running it. So, as the core phase does, that set goes in first, cut down to its object and field access,
    and is given to the person installing; the part's own deploy then fills it in before its tests run."""
    wanted = [one for one in part.get('alsoHolds') or [] if one not in have['mine']]
    if not wanted:
        return []
    target = stage_dir(ONLY + 'held-first')
    os.makedirs(os.path.join(target, 'main', 'default', 'permissionsets'))
    for one in wanted:
        with open(os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'permissionsets', one + '.permissionset-meta.xml'), encoding='utf-8') as handle:
            text = handle.read()
        kept = ''.join(match.group(0) for match in re.finditer(r'    <(\w+)>.*?</\1>\n', text, re.S) if match.group(1) in KEPT_IN_A_FIRST_PERMISSION_SET)
        with open(os.path.join(target, 'main', 'default', 'permissionsets', one + '.permissionset-meta.xml'), 'w', encoding='utf-8') as handle:
            handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<PermissionSet xmlns="%s">\n%s</PermissionSet>\n' % (NAMESPACE, kept))
    ok, shown, _ = summarize(deploy(org, ONLY + 'held-first', target, False, args.wait, False, args.test_level))
    if not ok:
        print('\n'.join(shown))
        raise SetupError('Could not put %s in first, which the tests of "%s" need you to hold. Nothing else was changed. Fix what is listed above and run it again.' % (', '.join(wanted), part['label']))
    for one in wanted:
        assign_set(org, one)
        have['mine'].add(one)
    print('First: %s, which a test of "%s" needs you to hold. %s' % (', '.join(wanted), part['label'], shown[0]))
    return wanted


def assign_set(org, set_name):
    reply = sf(['org', 'assign', 'permset', '--name', set_name, '--target-org', org['alias']], allow_failure=True)
    failures = (reply.get('result') or {}).get('failures') or []
    if reply.get('status', 0) != 0 or failures:
        why = '; '.join(str(failure.get('message')) for failure in failures) or str(reply.get('message'))
        if 'duplicate' not in why.lower():
            raise SetupError('Could not give you the permission set %s: %s' % (set_name, why[:300]))


def say_standing(kit, org, title=None):
    have = capabilities.standing(org['alias'], org['username'], kit)
    state = capabilities.judge(kit, have)
    if title:
        print(title)
    print('\n'.join(capabilities.standing_lines(kit, have, state)))
    return have, state


def install_layer(org, name, args):
    kit = manifest()
    entry = capabilities.named(name, kit)
    announce(org, '%s "%s" and what it needs. First: a read of what the org holds, which changes nothing.' % ('CHECK (dry run, nothing changes)' if args.dry_run else 'INSTALL', entry['label']))
    guard_production(org, args.allow_production)
    have, state = say_standing(kit, org)
    if state['whole']:
        print('The whole app is in this org, and "%s" is part of it. Nothing to install. To update the app, run the core phase.' % entry['label'])
        return
    todo, lines = capabilities.plan(kit, name, state)
    print('\n'.join(lines))
    stops = capabilities.missing_first(kit, name, have)
    if stops:
        raise SetupError('"%s" cannot be installed yet. Nothing was changed. %s' % (entry['label'], ' '.join(line.replace('<alias>', args.target_org) for line in stops)))
    given = []
    for position, layer in enumerate(todo, 1):
        part = capabilities.named(layer, kit)
        tests = [] if args.test_level == 'NoTestRun' else part.get('tests') or []
        print('Step %d of %d: "%s" (%d components in %d files, %s).' % (position, len(todo), part['label'], sum(len(found) for found in part['members'].values()), part['files'],
                                                                        '%d test classes' % len(tests) if tests else 'no code, so no tests'))
        if tests and not args.dry_run:
            given += hold_first(org, part, have, args)
        staged = stage_layer(layer)
        reply = deploy(org, ONLY + layer, staged, args.dry_run, args.wait, False, args.test_level)
        ok, shown, job = summarize(reply)
        print('\n'.join(shown))
        line = coverage_line(reply.get('result') or {}, part) if ok and tests else None
        if line:
            print(line)
        if not args.dry_run:
            record(org, ONLY + layer, 'deployed' if ok else 'failed', {'job': job})
        if not ok:
            earlier = [capabilities.named(other, kit)['label'] for other in todo[:position - 1]]
            raise SetupError('"%s" did not %s. Salesforce rolled this step back.%s Fix what is listed above and run it again: what is already there is not installed twice.'
                             % (part['label'], 'pass its check' if args.dry_run else 'deploy', ' Already in the org from this run: %s.' % ', '.join(earlier) if earlier and not args.dry_run else ''))
        if args.dry_run:
            print('"%s" would deploy cleanly.' % part['label'])
            if position < len(todo):
                print('What comes after it cannot be checked ahead of time: %s need "%s" to be really in the org, and their tests save records as you with the access it gives.'
                      % (', '.join('"%s"' % capabilities.named(other, kit)['label'] for other in todo[position:]), part['label']))
            return
        if part.get('permissionSet') and part['permissionSet'] not in have['mine']:
            # The next set's tests save records as the person installing, and need this one's access to do it.
            assign_set(org, part['permissionSet'])
            given.append(part['permissionSet'])
    print('"%s" is in the org.' % entry['label'])
    if given:
        print('Gave you %s. Nobody else was given anything.' % ', '.join(given))
    say_standing(kit, org)
    sets = capabilities.access_sets(name, kit)
    print('To give someone else access: python3 scripts/setup/assign_access.py --target-org %s --capability %s --users <their username>   (it assigns %s)' % (args.target_org, name, ', '.join(sets)))
    if any(capabilities.named(layer, kit).get('members', {}).get('NamedCredential') for layer in capabilities.chain(name, kit)):
        print('Anything here that calls Claude needs a key: python3 scripts/setup/set_api_key.py --target-org %s   (the person runs it; the key is typed at a hidden prompt)' % args.target_org)


def all_ours(kit):
    """Every class and trigger name the kit ships, in any part."""
    ours = kit.get('ours') or {}
    names = set(ours.get('apexClasses', [])) | set(ours.get('portalClasses', [])) | set(ours.get('apexTriggers', []))
    for entry in (kit.get('capabilities') or {}).values():
        names |= set((entry.get('members') or {}).get('ApexClass', [])) | set((entry.get('members') or {}).get('ApexTrigger', []))
    return names


def used_by_theirs(org, kit, classes, ask=None, ask_tooling=None):
    """Classes and triggers of the org's own that use a class of ours that is about to go.

    Salesforce deletes a class even when another class uses it. It says nothing at the time, and the class that used
    it stops compiling. So this is asked before anything is removed. Returns ({theirs: [ours it uses]}, None), or
    ({}, a line saying the org could not be asked)."""
    ask, ask_tooling = ask or batch, ask_tooling or tooling
    classes = sorted(classes)
    if not classes:
        return {}, None
    answers = ask(org['alias'], [('ids%d' % start, soql('SELECT Id, Name FROM ApexClass WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(classes[start:start + 100])))
                                 for start in range(0, len(classes), 100)])
    ids = [row['Id'] for answer in answers.values() for row in records(answer)]
    mine, found = all_ours(kit), {}
    for start in range(0, len(ids), 100):
        ok, rows = ask_tooling(org['alias'], "SELECT MetadataComponentName, MetadataComponentType, RefMetadataComponentName FROM MetadataComponentDependency "
                                             "WHERE MetadataComponentType IN ('ApexClass', 'ApexTrigger') AND RefMetadataComponentId IN (%s)" % in_list(ids[start:start + 100]))
        if not ok:
            return {}, 'The org would not say whether any class of its own uses these (%s). Look for yourself before going on: Salesforce deletes a class that another class uses, and that one then stops compiling.' % str(rows)[:160]
        for row in rows:
            if row.get('MetadataComponentName') not in mine:
                found.setdefault(row['MetadataComponentName'], [])
                if row.get('RefMetadataComponentName') not in found[row['MetadataComponentName']]:
                    found[row['MetadataComponentName']].append(row.get('RefMetadataComponentName'))
    return found, None


def say_used_by_theirs(found, caution):
    """The lines to print for what used_by_theirs found, and the reason to stop on --yes, or None."""
    if caution:
        return ['  ' + caution], None
    if not found:
        return ['  No class or trigger of the org\'s own uses a class that would go.'], None
    named = '; '.join('%s (uses %s)' % (name, ', '.join(sorted(uses)[:3]) + (' and %d more' % (len(uses) - 3) if len(uses) > 3 else '')) for name, uses in sorted(found.items())[:8])
    more = ' and %d more' % (len(found) - 8) if len(found) > 8 else ''
    one = len(found) == 1
    lines = ['  Of the org\'s own, and using a class that would go: %s%s.' % (named, more),
             '  Salesforce would delete ours all the same, without a word, and %s would stop compiling.' % ('it' if one else 'each of these')]
    return lines, ('%d class%s of the org\'s own use%s a class that would go: %s%s. Salesforce would delete ours all the same and %s would stop compiling. '
                   'Change or remove %s first, then run this again. Nothing was changed.' % (len(found), '' if one else 'es', 's' if one else '', named, more, 'it' if one else 'they', 'it' if one else 'them'))


def held_by_the_theme(reply):
    """Whether everything a removal was refused for is a file a theme still shows (the logo, by the look and feel)."""
    failures = ((reply.get('result') or {}).get('details') or {}).get('componentFailures') or []
    failures = [failures] if isinstance(failures, dict) else failures
    return bool(failures) and all(failure.get('componentType') == 'ContentAsset' and 'Branding Set Property' in str(failure.get('problem')) for failure in failures)


def remove_layer(org, name, args):
    kit = manifest()
    entry = capabilities.named(name, kit)
    announce(org, '%s "%s"' % ('REMOVE' if args.yes else 'show what removing would take away (nothing changes) for', entry['label']))
    guard_production(org, args.allow_production)
    have, state = say_standing(kit, org)
    if state['whole']:
        raise SetupError('The whole app is in this org. "%s" cannot be taken out from under it. To remove the app: python3 scripts/setup/uninstall.py --target-org %s' % (entry['label'], args.target_org))
    if name not in state['installed'] and name not in state['partly']:
        raise SetupError('"%s" is not installed in this org as a part. Nothing was changed.' % entry['label'])
    if name in state['partly']:
        # A removal that stopped part-way leaves the part half there. Running it again takes out what is left.
        print('Only part of "%s" is in the org (an install or a removal of it stopped part-way). What is left of it is what would go; what is already gone is skipped.' % entry['label'])
    above = capabilities.built_on(kit, name, state)
    if above:
        raise SetupError('%s built on "%s" and still in the org. Remove %s first: %s. Nothing was changed.'
                         % (', '.join('"%s"' % capabilities.named(other, kit)['label'] for other in above) + (' is' if len(above) == 1 else ' are'), entry['label'], 'it' if len(above) == 1 else 'them',
                            ', then '.join('python3 scripts/setup/uninstall.py --target-org %s --capability %s' % (args.target_org, other) for other in reversed(above))))
    if not any(kind in entry['members'] for step in LAYER_REMOVAL_STEPS for kind in step) or 'CustomObject' in entry['members']:
        raise SetupError('"%s" holds objects, fields and record types. Removing those is removing the app\'s records with them, and Salesforce keeps record types and picklist values. '
                         'Use the uninstall, which says what goes and what stays: python3 scripts/setup/uninstall.py --target-org %s' % (entry['label'], args.target_org))
    part = capabilities.detail(name, kit)
    # What another installed capability also holds stays where it is.
    kept = set()
    for other in state['installed']:
        if other != name:
            kept |= set((part.get('shared') or {}).get(other, []))
    members = {}
    for node in part['nodes']:
        kind, one = node.split(':', 1)
        if node not in kept:
            members.setdefault(kind, []).append(one)
    if part.get('permissionSet'):
        members.setdefault('PermissionSet', []).append(part['permissionSet'])
    # A custom object keeps its last page layout for as long as the object is there.
    stays = [one for one in members.get('Layout', []) if '__' in one.split('-')[0]]
    members['Layout'] = [one for one in members.get('Layout', []) if one not in stays]
    ordered = [kind for step in LAYER_REMOVAL_STEPS for kind in step]
    unlisted = sorted(kind for kind in members if members[kind] and kind not in ordered)
    if unlisted:
        raise SetupError('This script does not know in what order to remove: %s. Nothing was changed.' % ', '.join(unlisted))
    for kind in ordered:
        if members.get(kind):
            print('  %s (%d): %s%s' % (kind, len(members[kind]), ', '.join(sorted(members[kind])[:8]), ' and others' if len(members[kind]) > 8 else ''))
    if kept:
        print('  Stays, because another part in the org also holds it: %d components (%s%s).' % (len(kept), ', '.join(sorted(node.split(':')[1] for node in kept)[:5]), ' and others' if len(kept) > 5 else ''))
    if stays:
        print('  Stays until the data model goes: %s.' % ', '.join(stays))
    sets = [one for one in members.get('PermissionSet', [])]
    user_rows = records(batch(org['alias'], [('held', soql(
        'SELECT Id FROM PermissionSetAssignment WHERE PermissionSet.NamespacePrefix = null AND PermissionSet.Name IN (%s)' % in_list(sets)))])['held']) if sets else []
    print('  Access taken away: %d assignment%s of %s.' % (len(user_rows), '' if len(user_rows) == 1 else 's', ', '.join(sets) or 'no permission set'))
    stay = [capabilities.named(other, kit)['label'] for other in state['installed'] if other != name]
    print('  No record is deleted.%s' % (' What it is built on stays: %s.' % ', '.join(stay) if stay else ''))
    lines, stop = say_used_by_theirs(*used_by_theirs(org, kit, members.get('ApexClass', [])))
    print('\n'.join(lines))
    if not args.yes:
        print('Nothing was changed. %s' % ('Change or remove what is listed above first: this would stop there with --yes.' if stop else 'Run it again with --yes to remove it.'))
        return
    if stop:
        raise SetupError(stop)
    held = [row['Id'] for row in user_rows]
    version = 'v' + api_version()
    for start in range(0, len(held), 25):
        body = {'haltOnError': False, 'batchRequests': [{'method': 'DELETE', 'url': '%s/sobjects/PermissionSetAssignment/%s' % (version, one)} for one in held[start:start + 25]]}
        reply = rest(org['alias'], '/services/data/%s/composite/batch' % version, 'POST', body)
        failed = [result for result in (reply or {}).get('results') or [] if not 200 <= result.get('statusCode', 500) < 300]
        if failed:
            raise SetupError('Could not take away access to "%s": %s' % (entry['label'], str(failed[0].get('result'))[:300]))
    flow_versions = []
    if members.get('Flow'):
        # A flow goes version by version, and only once it is switched off.
        off = stage_dir('%s%s-flows-off' % (ONLY, name))
        os.makedirs(os.path.join(off, 'flowDefinitions'))
        for flow in members['Flow']:
            with open(os.path.join(off, 'flowDefinitions', flow + '.flowDefinition'), 'w', encoding='utf-8') as handle:
                handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<FlowDefinition xmlns="%s">\n    <activeVersionNumber>0</activeVersionNumber>\n</FlowDefinition>\n' % NAMESPACE)
        with open(os.path.join(off, 'package.xml'), 'w', encoding='utf-8') as handle:
            handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="%s">\n    <types>\n%s        <name>FlowDefinition</name>\n    </types>\n    <version>%s</version>\n</Package>\n'
                         % (NAMESPACE, ''.join('        <members>%s</members>\n' % escape(flow) for flow in members['Flow']), api_version()))
        ok, shown, job = summarize(sf(['project', 'deploy', 'start', '--target-org', org['alias'], '--metadata-dir', off, '--ignore-warnings', '--wait', str(args.wait)], timeout=args.wait * 60 + 300, allow_failure=True))
        print('Switched the flows off: ' + shown[0])
        if not ok:
            print('\n'.join(shown[1:]))
            raise SetupError('The flows could not be switched off, so nothing was removed. Access was taken away. Fix what is listed above and run this again.')
        found, rows = tooling(org['alias'], 'SELECT Definition.DeveloperName, VersionNumber FROM Flow WHERE Definition.DeveloperName IN (%s)' % in_list(members['Flow']))
        if not found:
            raise SetupError('The org would not list the versions of the flows, so nothing was removed: %s' % rows)
        flow_versions = sorted('%s-%s' % ((row.get('Definition') or {}).get('DeveloperName'), row.get('VersionNumber')) for row in rows)
    steps = [[kind for kind in step if members.get(kind)] for step in LAYER_REMOVAL_STEPS]
    steps = [step for step in steps if step]
    for number, kinds in enumerate(steps, 1):
        target = stage_dir('%s%s-remove-%d' % (ONLY, name, number))
        types = ''.join('    <types>\n%s        <name>%s</name>\n    </types>\n' % (''.join('        <members>%s</members>\n' % escape(one) for one in sorted(flow_versions if kind == 'Flow' else members[kind])), kind) for kind in kinds)
        for file_name, body in (('destructiveChanges.xml', types), ('package.xml', '')):
            with open(os.path.join(target, file_name), 'w', encoding='utf-8') as handle:
                handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="%s">\n%s    <version>%s</version>\n</Package>\n' % (NAMESPACE, body, api_version()))
        command = ['project', 'deploy', 'start', '--target-org', org['alias'], '--metadata-dir', target, '--ignore-warnings', '--wait', str(args.wait)]
        if args.test_level == 'NoTestRun':
            command += ['--test-level', 'NoTestRun']
        reply = sf(command, timeout=args.wait * 60 + 300, allow_failure=True)
        ok, shown, job = summarize(reply)
        if not ok and held_by_the_theme(reply):
            # The logo is also what the look and feel's theme shows. Salesforce keeps it while a theme does.
            print('Step %d of %d (%s): left in place. The look and feel\'s theme shows this file as its logo, so Salesforce keeps it. It goes when the theme is deleted.' % (number, len(steps), ', '.join(kinds)))
            record(org, '%s%s-remove-%d' % (ONLY, name, number), 'left in place', {'job': job})
            continue
        print('\n'.join(['Step %d of %d (%s): %s' % (number, len(steps), ', '.join(kinds), shown[0])] + shown[1:]))
        record(org, '%s%s-remove-%d' % (ONLY, name, number), 'removed' if ok else 'failed', {'job': job})
        if not ok:
            raise SetupError('"%s" was not removed in full: step %d of %d failed, and Salesforce rolled that step back. Access was taken away and the earlier steps stand. '
                             'Fix what is listed above and run this again: what is already gone is skipped.' % (entry['label'], number, len(steps)))
    print('"%s" is removed.' % entry['label'])
    say_standing(kit, org)


# ---------------------------------------------------------------- the customer portal, taken out again

# What uses a thing goes before the thing: access, then what listens for a form a customer sent, then the screens
# and the code behind them, then the event itself.
PORTAL_REMOVAL_STEPS = [
    ['PermissionSet'],
    ['PlatformEventSubscriberConfig', 'ApexTrigger'],
    ['LightningComponentBundle', 'ApexClass'],
    ['CustomObject'],
]
CLOSED_NOTICE = '<h2 style="text-align: center;">This portal is closed.</h2>'
PUBLISH_WAITS = 4
PUBLISH_WAIT_SECONDS = 60


def without_ours(node, bundles):
    """A page of a site, as data, with our components taken out. Returns (the page, how many were taken out)."""
    taken = 0
    if isinstance(node, dict):
        children = node.get('children')
        if isinstance(children, list):
            kept = []
            for child in children:
                definition = child.get('definition', '') if isinstance(child, dict) else ''
                if definition.startswith('c:') and definition[2:] in bundles:
                    taken += 1
                    continue
                child, more = without_ours(child, bundles)
                taken += more
                kept.append(child)
            node = dict(node, children=kept)
        return node, taken
    return node, taken


def stage_closed_site(part, values, name='portal', live=True):
    """The pages of the portal's site that show our components, without them, and the site's own record.

    Salesforce does not delete a site, and refuses to delete a component while a page of a site shows it, so the
    site lets go of ours first. The site stays live while that happens (`live`), because Salesforce publishes only a
    live site and its published copy has to let go too; with `live` False only the site's record is staged, switched
    to "down for maintenance". Returns (the staged folder, the pages changed, the sites)."""
    source = os.path.join(KIT_ROOT, 'optional', name)
    target = stage_dir(ONLY + name + ('-closed' if live else '-off'))
    bundles = set((part.get('members') or {}).get('LightningComponentBundle', []))
    pages = []
    for folder, _, files in sorted(os.walk(os.path.join(source, 'digitalExperiences'))):
        if 'content.json' not in files or not live:
            continue
        with open(os.path.join(folder, 'content.json'), encoding='utf-8') as handle:
            text = handle.read()
        if not any('"c:%s"' % one in text for one in bundles):
            continue
        page = json.loads(text)
        body, taken = without_ours(page.get('contentBody', {}).get('component', {}), bundles)
        if not taken:
            continue

        def emptied(node):
            """A column our component was alone in is given one line of text, so the page is not blank."""
            if isinstance(node, dict):
                if node.get('type') == 'region' and node.get('children') == [] and node.get('name') != 'sfdcHiddenRegion':
                    node['children'] = [{'attributes': {'imageInfos': '', 'richTextValue': CLOSED_NOTICE}, 'definition': 'community_builder:richTextEditor',
                                         'id': str(uuid.uuid5(uuid.NAMESPACE_URL, str(node.get('id')))), 'type': 'component'}]
                for child in node.get('children') or []:
                    emptied(child)
        emptied(body)
        page['contentBody']['component'] = body
        to_folder = os.path.join(target, os.path.relpath(folder, source))
        os.makedirs(to_folder)
        with open(os.path.join(to_folder, 'content.json'), 'w', encoding='utf-8') as handle:
            json.dump(page, handle, indent=2)
        if os.path.exists(os.path.join(folder, '_meta.json')):
            shutil.copyfile(os.path.join(folder, '_meta.json'), os.path.join(to_folder, '_meta.json'))
        pages.append(page.get('title') or os.path.basename(folder))
    sites = []
    networks = os.path.join(source, 'networks')
    for file_name in sorted(os.listdir(networks)) if os.path.isdir(networks) else []:
        with open(os.path.join(networks, file_name), encoding='utf-8') as handle:
            text = handle.read()
        for marker, value in values.items():
            text = text.replace('{{%s}}' % marker, escape(value))
        if '<status>Live</status>' in text:
            if not live:
                text = text.replace('<status>Live</status>', '<status>DownForMaintenance</status>')
            os.makedirs(os.path.join(target, 'networks'), exist_ok=True)
            with open(os.path.join(target, 'networks', file_name), 'w', encoding='utf-8') as handle:
                handle.write(text)
            sites.append(file_name.split('.')[0])
    return target, pages, sites


def publish_site(org, site):
    """Asks Salesforce to publish the site, so that its published copy lets go of our components too. Returns
    (whether Salesforce took the request, a plain line saying how it went). Publishing runs in the background."""
    found = records(batch(org['alias'], [('site', soql("SELECT Id FROM Network WHERE Name = '%s'" % site.replace("'", "\\'")))])['site'])
    if not found:
        return False, 'The site "%s" could not be found to publish it.' % site
    try:
        reply = rest(org['alias'], '/services/data/v%s/connect/communities/%s/publish' % (api_version(), found[0]['Id']), 'POST', {})
    except SetupError as problem:
        return False, 'Salesforce would not publish the site "%s": %s' % (site, str(problem)[:300])
    if isinstance(reply, list):
        return False, 'Salesforce would not publish the site "%s": %s' % (site, str((reply[0] if reply else {}).get('message'))[:300])
    return True, 'Asked Salesforce to publish the site "%s" without our components. That runs in the background and takes a few minutes.' % site


def destroy(org, folder_name, members, kinds, wait, test_level, flow_versions=()):
    """One removal of the kinds named, as a deploy of its own. Returns the deploy's reply."""
    target = stage_dir(folder_name)
    types = ''.join('    <types>\n%s        <name>%s</name>\n    </types>\n' % (''.join('        <members>%s</members>\n' % escape(one) for one in sorted(flow_versions if kind == 'Flow' else members[kind])), kind) for kind in kinds)
    for file_name, body in (('destructiveChanges.xml', types), ('package.xml', '')):
        with open(os.path.join(target, file_name), 'w', encoding='utf-8') as handle:
            handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="%s">\n%s    <version>%s</version>\n</Package>\n' % (NAMESPACE, body, api_version()))
    command = ['project', 'deploy', 'start', '--target-org', org['alias'], '--metadata-dir', target, '--ignore-warnings', '--wait', str(wait)]
    if test_level == 'NoTestRun':
        command += ['--test-level', 'NoTestRun']
    return sf(command, timeout=wait * 60 + 300, allow_failure=True)


def still_published(reply):
    """Whether a removal was refused because the published copy of a site still uses something of ours.

    Salesforce says it in two ways: a component "is found in ... 1 Published Instance(s)", and a class one of those
    components calls "is referenced elsewhere in Salesforce ... Web App Resource Dependency". Both end when the
    site is published again without our components."""
    failures = ((reply.get('result') or {}).get('details') or {}).get('componentFailures') or []
    failures = [failures] if isinstance(failures, dict) else failures
    for failure in failures:
        problem = str(failure.get('problem'))
        found = re.search(r'and (\d+) Published Instance', problem)
        if (found and int(found.group(1)) > 0) or 'Web App Resource Dependency' in problem:
            return True
    return False


def remove_portal(org, name, args, pause=None, have=None):
    """Takes the customer portal out again and leaves the rest of the app. The site itself stays, emptied and
    switched off: Salesforce does not delete a site, and does not let Digital Experiences be switched off.

    The whole uninstall calls this first when the org holds the portal, with what it already read of the org
    (`have`): then whatever of the portal is there goes, and the closing read of the org is left to the uninstall."""
    import time
    pause = pause or time.sleep
    kit = manifest()
    entry = capabilities.named(name, kit)
    alone = have is None
    if alone:
        announce(org, '%s "%s"' % ('REMOVE' if args.yes else 'show what removing would take away (nothing changes) for', entry['label']))
        guard_production(org, args.allow_production)
        have, state = say_standing(kit, org)
        if name not in state['installed'] and name not in state['partly']:
            raise SetupError('"%s" is not installed in this org. Nothing was changed.' % entry['label'])
        if name in state['partly']:
            print('Only part of "%s" is in the org (an install or a removal of it stopped part-way). What is left of it is what would go; what is already gone is skipped.' % entry['label'])
    members = {kind: list(found) for kind, found in (entry.get('members') or {}).items() if any(kind in step for step in PORTAL_REMOVAL_STEPS)}
    if entry.get('staffSet') and entry['staffSet'] in (have.get('PermissionSet') or set()):
        members.setdefault('PermissionSet', []).append(entry['staffSet'])
    for kind in [kind for step in PORTAL_REMOVAL_STEPS for kind in step]:
        if members.get(kind):
            print('  %s (%d): %s%s' % (kind, len(members[kind]), ', '.join(sorted(members[kind])[:8]), ' and others' if len(members[kind]) > 8 else ''))
    sets = members.get('PermissionSet', [])
    profiles = (entry.get('members') or {}).get('Profile', [])
    answers = batch(org['alias'], [
        ('held', soql('SELECT Id FROM PermissionSetAssignment WHERE PermissionSet.NamespacePrefix = null AND PermissionSet.Name IN (%s)' % in_list(sets))),
        ('users', soql('SELECT COUNT() FROM User WHERE IsActive = true AND Profile.Name IN (%s)' % in_list(profiles))),
    ])
    user_rows = records(answers['held'])
    portal_users = (answers['users'][1] or {}).get('totalSize', 0) if answers['users'][0] else None
    print('  Access taken away: %d assignment%s of %s.' % (len(user_rows), '' if len(user_rows) == 1 else 's', ', '.join(sets) or 'no permission set'))
    print('  The site lets go of our components first: its pages that show them are saved without them, and the site is published again if its published copy still uses them.')
    print('  Last, the site is switched to "down for maintenance".')
    print('  Stays, because Salesforce does not let an installer remove it:')
    print('    - The site itself (%s), emptied and switched off. Salesforce does not delete a site. Archive it in Setup, Digital Experiences, All Sites.' % ', '.join((entry.get('members') or {}).get('Network', [])))
    print('    - Digital Experiences, switched on. Salesforce does not let it be switched off again.')
    print('    - What Salesforce itself made with the site, which is not ours: a guest profile named "%s Profile", a guest group and a file named SiteSamples.' % ((entry.get('members') or {}).get('Network') or ['the site'])[0])
    if profiles:
        print('    - The profile %s, which then grants nothing of ours. %s Delete it in Setup, Profiles, once no user is on it and the site no longer lists it.'
              % (', '.join(profiles), 'No active user is on it.' if portal_users == 0 else '%s on it: deactivate them in Setup, Users, or move them.' % ('%d active portal user%s' % (portal_users, ' is' if portal_users == 1 else 's are') if portal_users else 'Portal users may be')))
    print('  No record is deleted by this. The claims and requests customers sent through the portal are ordinary cases%s.' % (' and stay. The data model, the automations and the components stay' if alone else ''))
    if alone:
        # Called from the whole uninstall, that has asked this already, of every class of ours.
        lines, stop = say_used_by_theirs(*used_by_theirs(org, kit, members.get('ApexClass', [])))
        print('\n'.join(lines))
        if not args.yes:
            print('Nothing was changed. %s' % ('Change or remove what is listed above first: this would stop there with --yes.' if stop else 'Run it again with --yes to remove it.'))
            return
        if stop:
            raise SetupError(stop)
    held = [row['Id'] for row in user_rows]
    version = 'v' + api_version()
    for start in range(0, len(held), 25):
        body = {'haltOnError': False, 'batchRequests': [{'method': 'DELETE', 'url': '%s/sobjects/PermissionSetAssignment/%s' % (version, one)} for one in held[start:start + 25]]}
        reply = rest(org['alias'], '/services/data/%s/composite/batch' % version, 'POST', body)
        failed = [result for result in (reply or {}).get('results') or [] if not 200 <= result.get('statusCode', 500) < 300]
        if failed:
            raise SetupError('Could not take away access to "%s": %s' % (entry['label'], str(failed[0].get('result'))[:300]))
    values = org_values(org)
    staged, pages, sites = stage_closed_site(entry, values, name)
    if pages or sites:
        project = stage_project(os.path.basename(staged))
        ok, shown, job = summarize(sf(['project', 'deploy', 'start', '--target-org', org['alias'], '--source-dir', os.path.relpath(staged, project), '--ignore-conflicts', '--wait', str(args.wait)],
                                      timeout=args.wait * 60 + 300, allow_failure=True, cwd=project))
        print('The site let go of our components (%s): %s' % (', '.join(pages) or 'no page showed one', shown[0]))
        record(org, '%s%s-closed' % (ONLY, name), 'closed' if ok else 'failed', {'job': job})
        if not ok:
            print('\n'.join(shown[1:]))
            raise SetupError('The site could not be emptied, so nothing was removed. Access was taken away. Fix what is listed above and run this again.')
    steps = [[kind for kind in step if members.get(kind)] for step in PORTAL_REMOVAL_STEPS]
    steps = [step for step in steps if step]
    for number, kinds in enumerate(steps, 1):
        folder_name = '%s%s-remove-%d' % (ONLY, name, number)
        reply = destroy(org, folder_name, members, kinds, args.wait, args.test_level)
        if still_published(reply) and sites:
            # The published copy of the site is a copy of its own: it shows our components until the site is published again.
            asked = [publish_site(org, site) for site in sites]
            print('\n'.join(line for _, line in asked))
            for attempt in range(PUBLISH_WAITS if all(ok for ok, _ in asked) else 0):
                print('Waiting %d seconds for the published copy of the site to let go of ours (try %d of %d).' % (PUBLISH_WAIT_SECONDS, attempt + 1, PUBLISH_WAITS))
                pause(PUBLISH_WAIT_SECONDS)
                reply = destroy(org, folder_name, members, kinds, args.wait, args.test_level)
                if not still_published(reply):
                    break
        ok, shown, job = summarize(reply)
        print('\n'.join(['Step %d of %d (%s): %s' % (number, len(steps), ', '.join(kinds), shown[0])] + shown[1:]))
        record(org, folder_name, 'removed' if ok else 'failed', {'job': job})
        if not ok:
            wait_more = ' The published copy of the site had not let go of ours yet. Publishing takes a few minutes: wait, and run this again.' if still_published(reply) else ''
            raise SetupError('"%s" was not removed in full: step %d of %d failed, and Salesforce rolled that step back. Access was taken away, the site is emptied and the earlier steps stand.%s '
                             'Fix what is listed above and run this again: what is already gone is skipped.' % (entry['label'], number, len(steps), wait_more))
    staged, _, sites = stage_closed_site(entry, values, name, live=False)
    if sites:
        project = stage_project(os.path.basename(staged))
        ok, shown, job = summarize(sf(['project', 'deploy', 'start', '--target-org', org['alias'], '--source-dir', os.path.relpath(staged, project), '--ignore-conflicts', '--wait', str(args.wait)],
                                      timeout=args.wait * 60 + 300, allow_failure=True, cwd=project))
        record(org, '%s%s-off' % (ONLY, name), 'switched off' if ok else 'failed', {'job': job})
        print('The site (%s) is switched to "down for maintenance": %s' % (', '.join(sites), shown[0]) if ok else
              'The site (%s) could not be switched off, and is still live with its emptied pages. Switch it off in Setup, Digital Experiences, All Sites, Workspaces, Administration. %s' % (', '.join(sites), ' '.join(line.strip() for line in shown[:3])))
    print('"%s" is removed. The site, its profile and Digital Experiences stay, as listed above.' % entry['label'])
    if alone:
        say_standing(kit, org)


# The optional phases that can be taken out again by themselves.
REMOVABLE_PHASES = {'portal': remove_portal}


def retire_part_sets(org, args):
    """After the whole app is in: the permission sets of the parts that were installed before it are no longer needed
    by anyone who now holds the whole app's. They are removed when that is everyone who held one, and left, with a
    line saying who still relies on them, when it is not."""
    kit = manifest()
    all_of = kit.get('capabilities') or {}
    sets = sorted({entry['permissionSet'] for entry in all_of.values() if entry.get('kind') == 'layer' and entry.get('permissionSet')})
    if not sets:
        return
    answers = batch(org['alias'], [
        ('there', soql('SELECT Name FROM PermissionSet WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(sets))),
        ('held', soql('SELECT Id, AssigneeId, Assignee.Username, PermissionSet.Name FROM PermissionSetAssignment WHERE PermissionSet.NamespacePrefix = null AND PermissionSet.Name IN (%s)' % in_list(sets + [capabilities.WHOLE_APP_SET]))),
    ])
    there = sorted(row['Name'] for row in records(answers['there']))
    if not there:
        return
    rows = records(answers['held'])
    whole = {row['AssigneeId'] for row in rows if (row.get('PermissionSet') or {}).get('Name') == capabilities.WHOLE_APP_SET}
    relying = sorted({(row.get('Assignee') or {}).get('Username') for row in rows if (row.get('PermissionSet') or {}).get('Name') in there and row['AssigneeId'] not in whole} - {None})
    if relying:
        print('The parts installed before the whole app left these permission sets, and they still work: %s. %d %s only those and not %s (%s%s), so they are left in place. '
              'Give them the whole app\'s access with assign_access.py, then run the core phase again to tidy up.'
              % (', '.join(there), len(relying), 'person holds' if len(relying) == 1 else 'people hold', capabilities.WHOLE_APP_SET, ', '.join(relying[:4]), ' and others' if len(relying) > 4 else ''))
        return
    held = [row['Id'] for row in rows if (row.get('PermissionSet') or {}).get('Name') in there]
    version = 'v' + api_version()
    for start in range(0, len(held), 25):
        body = {'haltOnError': False, 'batchRequests': [{'method': 'DELETE', 'url': '%s/sobjects/PermissionSetAssignment/%s' % (version, one)} for one in held[start:start + 25]]}
        rest(org['alias'], '/services/data/%s/composite/batch' % version, 'POST', body)
    target = stage_dir('core-retire-part-sets')
    types = '    <types>\n%s        <name>PermissionSet</name>\n    </types>\n' % ''.join('        <members>%s</members>\n' % escape(one) for one in there)
    for file_name, body in (('destructiveChanges.xml', types), ('package.xml', '')):
        with open(os.path.join(target, file_name), 'w', encoding='utf-8') as handle:
            handle.write('<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="%s">\n%s    <version>%s</version>\n</Package>\n' % (NAMESPACE, body, api_version()))
    command = ['project', 'deploy', 'start', '--target-org', org['alias'], '--metadata-dir', target, '--ignore-warnings', '--wait', str(args.wait)]
    if args.test_level == 'NoTestRun' or not org['isProduction']:
        command += ['--test-level', 'NoTestRun']
    ok, shown, _ = summarize(sf(command, timeout=args.wait * 60 + 300, allow_failure=True))
    if ok:
        print('The whole app\'s permission sets now cover what the parts\' own sets gave, and everyone who held one holds %s. Removed: %s.' % (capabilities.WHOLE_APP_SET, ', '.join(there)))
    else:
        print('The parts\' own permission sets (%s) could not be removed and still work beside the whole app\'s. %s' % (', '.join(there), ' '.join(line.strip() for line in shown[1:3])))


def only(org, args, parser):
    """--only: one choice from the menu. Returns the phase to carry on with when the choice is an optional phase."""
    kit = manifest()
    entry = capabilities.named(args.only, kit)
    kind = entry['kind']
    if kind == 'slice':
        (remove_slice if args.remove else install_slice)(org, args.only, args)
        return None
    if kind == 'layer':
        (remove_layer if args.remove else install_layer)(org, args.only, args)
        return None
    if args.remove and args.only in REMOVABLE_PHASES:
        REMOVABLE_PHASES[args.only](org, args.only, args)
        return None
    if args.remove:
        parser.error('--remove goes with a part of the app (%s). To remove the whole app, use scripts/setup/uninstall.py'
                     % ', '.join(name for name in capabilities.order(kit) if capabilities.named(name, kit)['kind'] in ('layer', 'slice') or name in REMOVABLE_PHASES))
    if kind in ('whole', 'step'):
        print('"%s" is not one deploy: %s' % (entry['label'], entry['summary']))
        if entry.get('brings'):
            print('It is built on: %s.' % ', '.join('the whole app' if other == 'everything' else '"%s"' % capabilities.named(other, kit)['label'] for other in entry['brings']))
        for need in entry.get('needsFirst', []):
            print('Needs: ' + need)
        if entry.get('ownYes'):
            print('Its own yes: ' + entry['ownYes'])
        print('Run, in order:')
        for line in entry.get('how', []):
            print('  ' + line.replace('<alias>', args.target_org))
        print('Nothing was changed.')
        return None
    # An optional phase: read what the org holds, bring what the phase is built on, say so, then run the phase.
    have, state = say_standing(kit, org, 'Target org: %s (%s). "%s" first reads what the org holds, which changes nothing.' % (org['alias'], org['name'], entry['label']))

    def words(names):
        found = ['the whole app' if other == 'everything' else '"%s"' % capabilities.named(other, kit)['label'] for other in names]
        return found[0] if len(found) == 1 else ', '.join(found[:-1]) + ' and ' + found[-1]
    missing = [other for other in entry.get('brings', []) if not (state['whole'] or other in state['installed'])]
    if 'everything' in missing:
        raise SetupError('"%s" is built on the whole app, which is not in this org. %sInstall it first (the phases in INSTALL.md), then run this again. Nothing was changed.'
                         % (entry['label'], entry['whyEverything'] + ' ' if entry.get('whyEverything') else ''))
    if entry.get('brings'):
        print('"%s" is built on %s: %s.' % (entry['label'], words(entry['brings']), 'already in the org' if not missing else '%s %s not in the org yet, so %s will be installed first' % (words(missing), 'is' if len(missing) == 1 else 'are', 'it' if len(missing) == 1 else 'they')))
    if entry.get('ownYes'):
        print('Its own yes: ' + entry['ownYes'])
    brought = set()
    for other in reversed(missing):
        # The one highest up brings those under it, so each is installed once.
        if other in brought:
            continue
        install_layer(org, other, args)
        brought |= set(capabilities.chain(other, kit))
        if args.dry_run:
            print('"%s" itself cannot be checked ahead of time: it needs %s to be really in the org.' % (entry['label'], words(missing)))
            return None
    # Without the whole app, its permission set is not there for the phase to update, so the small staff set goes in its place.
    args.in_place_of = (entry.get('staffSetInPlaceOf'), os.path.join(KIT_ROOT, entry['path'], 'main', 'default', 'permissionsets', entry['staffSet'] + '.permissionset-meta.xml')) \
        if entry.get('staffSet') and not state['whole'] else None
    return entry['phase']


def deploy(org, phase, staged, dry_run, wait_minutes, run_async, test_level):
    project = stage_project(phase)
    args = ['project', 'deploy', 'start', '--target-org', org['alias'], '--source-dir', os.path.relpath(staged, project), '--ignore-conflicts']
    tests = tests_for(phase)
    if tests and test_level != 'NoTestRun':
        args += ['--test-level', 'RunSpecifiedTests']
        for name in tests:
            args += ['--tests', name]
    elif test_level == 'NoTestRun':
        args += ['--test-level', 'NoTestRun']
    if dry_run:
        args.append('--dry-run')
    args += ['--async'] if run_async else ['--wait', str(wait_minutes)]
    return sf(args, timeout=wait_minutes * 60 + 300, allow_failure=True, cwd=project)


def summarize(reply):
    """(succeeded, lines to print) from a deploy or a deploy report."""
    result = reply.get('result') or {}
    status = result.get('status') or ('Failed' if reply.get('status') else 'Unknown')
    lines = ['Status: %s. Components %s of %s. Tests run %s, failed %s.' % (
        status, result.get('numberComponentsDeployed', 0), result.get('numberComponentsTotal', 0), result.get('numberTestsCompleted', 0), result.get('numberTestErrors', 0))]
    details = result.get('details') or {}
    failures = details.get('componentFailures') or []
    if isinstance(failures, dict):
        failures = [failures]
    # One cause often fails many components. Say each cause once, with how many it stopped and a few of their names.
    by_problem = {}
    for failure in failures:
        by_problem.setdefault(str(failure.get('problem')), []).append('%s %s' % (failure.get('componentType'), failure.get('fullName')))
    for problem, names in sorted(by_problem.items(), key=lambda item: -len(item[1]))[:30]:
        names = sorted(set(names))
        if len(names) == 1:
            lines.append('  FAILED %s: %s' % (names[0], problem))
        else:
            lines.append('  FAILED %d components (%s%s): %s' % (len(names), ', '.join(names[:3]), ' and others' if len(names) > 3 else '', problem))
    if len(by_problem) > 30:
        lines.append('  and %d more causes.' % (len(by_problem) - 30))
    tests = (details.get('runTestResult') or {})
    test_failures = tests.get('failures') or []
    if isinstance(test_failures, dict):
        test_failures = [test_failures]
    for failure in test_failures[:25]:
        lines.append('  TEST FAILED %s.%s: %s' % (failure.get('name'), failure.get('methodName'), (failure.get('message') or '').strip()[:300]))
    if len(test_failures) > 25:
        reasons = {}
        for failure in test_failures:
            reason = (failure.get('message') or '').strip().split('\n')[0][:140]
            reasons[reason] = reasons.get(reason, 0) + 1
        lines.append('  and %d more test failures. All %d by reason:' % (len(test_failures) - 25, len(test_failures)))
        for reason, count in sorted(reasons.items(), key=lambda item: -item[1])[:12]:
            lines.append('    %4d  %s' % (count, reason))
    warnings = tests.get('codeCoverageWarnings') or []
    if isinstance(warnings, dict):
        warnings = [warnings]
    for warning in warnings[:10]:
        lines.append('  COVERAGE %s: %s' % (warning.get('name'), warning.get('message')))
    # Our own plain line for each class or trigger under the bar: its name, its figure and the bar.
    lines += low_coverage_lines(result)
    if not result and reply.get('message'):
        lines.append('  ' + str(reply.get('message'))[:600])
    return status in ('Succeeded', 'SucceededPartial'), lines, result.get('id')


def run():
    parser = argparse.ArgumentParser(description='Deploy one phase of the Antsurance install.')
    parser.add_argument('--target-org')
    parser.add_argument('--phase', choices=PHASES)
    parser.add_argument('--only', metavar='PART', help='Install one part of the app, with what that part needs. --list prints the parts; FEATURES.md describes them.')
    parser.add_argument('--list', action='store_true', help='Print what can be chosen, what each choice brings with it and its command. Calls no org.')
    parser.add_argument('--remove', action='store_true', help='With --only: remove that part again. Says what would go unless --yes is given too.')
    parser.add_argument('--yes', action='store_true', help='With --only --remove: do it.')
    parser.add_argument('--dry-run', action='store_true', help='Check that the phase would deploy. Changes nothing in the org.')
    parser.add_argument('--enable', action='append', choices=sorted(SETTINGS), default=[], help='For --phase prerequisites: the switch to turn on. Repeat for both.')
    parser.add_argument('--allow-production', action='store_true', help='Only when the org owner has asked for a production install.')
    parser.add_argument('--wait', type=int, default=60, help='Minutes to wait for the org to finish (default 60)')
    parser.add_argument('--async', dest='run_async', action='store_true', help='Start and return at once. Check later with --report.')
    parser.add_argument('--report', metavar='JOB_ID', help='Report on a deploy started with --async')
    parser.add_argument('--test-level', choices=['RunSpecifiedTests', 'NoTestRun'], default='RunSpecifiedTests', help='NoTestRun is refused by production orgs.')
    args = parser.parse_args()

    if args.list:
        print('\n'.join(capabilities.menu()))
        return
    if not args.target_org:
        parser.error('--target-org is required')
    org = describe_org(args.target_org)
    if args.report:
        print('Target org: %s (%s)' % (org['alias'], org['name']))
        ok, lines, _ = summarize(sf(['project', 'deploy', 'report', '--target-org', args.target_org, '--job-id', args.report], allow_failure=True))
        print('\n'.join(lines))
        sys.exit(0 if ok else 1)
    if args.only:
        if args.phase:
            parser.error('--only installs one part alone; it does not go with --phase')
        if args.only in slices() or not manifest().get('capabilities'):
            # A part with a folder of its own, exactly as before.
            (remove_slice if args.remove else install_slice)(org, args.only, args)
            return
        args.phase = only(org, args, parser)
        if not args.phase:
            return
    elif args.remove or args.yes:
        parser.error('--remove and --yes go with --only. To remove the whole app use scripts/setup/uninstall.py')
    if not args.phase:
        parser.error('--phase or --only is required')

    action = '%s the "%s" phase' % ('CHECK (dry run, nothing changes)' if args.dry_run else 'DEPLOY', args.phase)
    announce(org, action)
    guard_production(org, args.allow_production)

    staged, detail = stage(args.phase, org, args.enable)
    swap = getattr(args, 'in_place_of', None)
    if staged and swap:
        whole_app_set = os.path.join(staged, 'permissionsets', swap[0] + '.permissionset-meta.xml')
        if os.path.exists(whole_app_set):
            os.remove(whole_app_set)
            shutil.copyfile(swap[1], os.path.join(staged, 'permissionsets', os.path.basename(swap[1])))
            print('The whole app is not in this org, so staff reach this phase through the permission set %s, in place of %s.' % (os.path.basename(swap[1]).split('.')[0], swap[0]))
    if staged is None:
        print('Nothing to deploy for this phase: the org already has it all.')
        if not args.dry_run:
            record(org, args.phase, 'nothing to do', detail)
        return
    if args.phase == 'core':
        _, existing, mine, _ = holds_our_sets(org)
        first_time = 'Antsurance_CRM' not in existing
        if first_time:
            # Step one of two: the data model and our permission sets, with no code, so no tests run yet.
            # Only in an org new to the app. In an update the live permission sets are left whole.
            model = stage_model(staged)
            print('Step 1 of 2: the data model and permission sets (no code, so no tests).')
            ok, lines, job = summarize(deploy(org, 'core-model', model, args.dry_run, args.wait, False, args.test_level))
            print('\n'.join(lines))
            if not ok:
                raise SetupError('The data model did not %s. Nothing was changed. Fix what is listed above and run it again.' % ('pass its check' if args.dry_run else 'deploy'))
            if args.dry_run:
                print('The data model would deploy cleanly. The code and its tests cannot be checked ahead of time in an org that does not have the data model yet: '
                      'the tests save records as you, and you have no access to our fields until step 1 is really in the org. They are checked when the phase deploys, '
                      'and a failure there rolls the code back and leaves only the data model, which nobody can see.')
                return
            record(org, 'core-model', 'deployed', {'job': job})
        elif args.dry_run and 'Antsurance_CRM' not in mine:
            raise SetupError('The app is in this org, but you do not hold its permission sets, and its tests run as you. Nothing was checked or changed. '
                             'Run: python3 scripts/setup/assign_access.py --target-org %s --only-me --yes' % args.target_org)
        if not args.dry_run:
            given = give_installer_access(org)
            if given:
                print('Gave you %s, so the tests can run as you. Nobody else was given anything.' % ', '.join(given))
        print('Step 2 of 2: the code, pages, app, flows and reports, with the tests.' if first_time else 'The app is already in this org: updating it in one step, with the tests.')
    reply = deploy(org, args.phase, staged, args.dry_run, args.wait, args.run_async, args.test_level)
    if args.run_async:
        job = (reply.get('result') or {}).get('id')
        if not job:
            raise SetupError('The org did not accept the deploy: ' + str(reply.get('message'))[:500])
        print('Started. Job id %s. Check it with: python3 scripts/setup/deploy_phase.py --target-org %s --report %s' % (job, args.target_org, job))
        return
    ok, lines, job = summarize(reply)
    print('\n'.join(lines))
    if not args.dry_run:
        record(org, args.phase, 'deployed' if ok else 'failed', dict(detail or {}, job=job))
    if not ok:
        raise SetupError('The "%s" phase did not %s. Nothing was half-applied: a failed deploy is rolled back by Salesforce. Fix what is listed above and run it again.'
                         % (args.phase, 'pass its check' if args.dry_run else 'deploy'))
    print('The "%s" phase %s.' % (args.phase, 'would deploy cleanly' if args.dry_run else 'is in the org'))
    if args.phase == 'core' and not args.dry_run:
        retire_part_sets(org, args)


if __name__ == '__main__':
    main(run)
