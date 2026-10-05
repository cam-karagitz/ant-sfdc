"""What a person can choose to install, what each choice brings with it, and what an org already holds of it.

The kit's build worked the choices out by scanning the app (kit-scan.json) and wrote them into kit-manifest.json
under "capabilities", with one folder each under capabilities/. This module reads them. It is used by
deploy_phase.py (--only, --list), verify.py and assign_access.py (--capability), the preflight, and
describe_capability.py. Only standing() calls the org, and it only reads.

The kinds of choice:
  whole   everything: the phases, in order (INSTALL.md)
  layer   a set cut from force-app/ by the scan: the data model, the automations, the components, the pages
  slice   a part with a folder of its own under slices/: Ask Claude
  phase   an optional phase: the customer portal, the look and feel
  step    a script of its own: the sample records, the coverage agent
"""
import json
import os

from _common import KIT_ROOT, SetupError, batch, in_list, manifest, records, soql

WHOLE_APP_SET = 'Antsurance_CRM'
# The kinds of component an org can be asked about by name in one batch of questions.
ASKED = ('ApexClass', 'ApexTrigger', 'Flow', 'CustomObject', 'PermissionSet', 'CustomTab', 'CustomApplication', 'ApexPage', 'StaticResource')
KIND_WORDS = {'ApexClass': 'classes', 'ApexTrigger': 'triggers', 'Flow': 'flows', 'CustomObject': 'objects', 'PermissionSet': 'permission sets', 'CustomTab': 'tabs',
              'CustomApplication': 'apps', 'ApexPage': 'document pages', 'StaticResource': 'static resources', 'LightningComponentBundle': 'screen components'}


def listed(kit=None):
    """Every choice, by name, as the build described it."""
    found = (kit or manifest()).get('capabilities')
    if not found:
        raise SetupError('This kit does not say what can be installed by itself (kit-manifest.json has no capabilities). Build it again, or install the whole app with the phases.')
    return found


def order(kit=None):
    kit = kit or manifest()
    return [name for name in kit.get('capabilityOrder') or sorted(listed(kit)) if name in listed(kit)]


def named(name, kit=None):
    found = listed(kit).get(name)
    if not found:
        raise SetupError('This kit has no part called "%s" that installs alone. It has: %s. FEATURES.md says what each one is.' % (name, ', '.join(order(kit))))
    return found


def detail(name, kit=None):
    """A layer's own files and components, from its folder in the kit."""
    entry = named(name, kit)
    path = os.path.join(KIT_ROOT, entry.get('path') or os.path.join('capabilities', name), 'capability.json')
    if not os.path.exists(path):
        raise SetupError('%s is missing from the kit.' % os.path.relpath(path, KIT_ROOT))
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)


def chain(name, kit=None):
    """The choice and what it brings, in the order they install. 'everything' stands for the phases."""
    return [other for other in named(name, kit).get('brings', []) if other != name] + [name]


def access_sets(name, kit=None):
    """The permission sets a person needs for this choice: its own and those of what it brings."""
    return list(named(name, kit).get('accessSets') or [])


def shape(kit=None):
    """How the parts cut from the app stack on each other, in one or two sentences, from what the build found."""
    kit = kit or manifest()
    all_of = listed(kit)
    layers = [name for name in order(kit) if all_of[name]['kind'] == 'layer']
    by_base = {}
    for name in layers:
        by_base.setdefault(tuple(all_of[name].get('brings', [])), []).append(name)
    said = []
    for base, names in sorted(by_base.items(), key=lambda item: len(item[0])):
        labels = ['"%s"' % all_of[name]['label'] for name in names]
        if not base:
            said.append('%s %s at the bottom and need%s nothing else of ours.' % (' and '.join(labels), 'is' if len(names) == 1 else 'are', 's' if len(names) == 1 else ''))
            continue
        on = 'it' if len(base) == 1 and len(said) == 1 else ('all %d of the others' % len(base) if len(base) == len(layers) - 1 and len(base) > 1 else ' and '.join('"%s"' % all_of[other]['label'] for other in base))
        line = '%s %s on %s%s.' % (' and '.join(labels), 'sits' if len(names) == 1 else 'sit side by side', on, '' if len(names) == 1 else ', and neither needs the other')
        for name in names:
            for other, found in sorted((all_of[name].get('testsCountOn') or {}).items()):
                if 'it names' not in (all_of[name].get('bringsWhy') or {}).get(other, ''):
                    line += ' By name it needs nothing of "%s": its code compiles without it. Its tests work with records of %s and count on what the triggers there do, so the two are installed together.' % (
                        all_of[other]['label'], ', '.join(found['objects']))
        shared = max([all_of[name].get('sharedWith', {}).get(other, 0) for name in names for other in names if other != name] or [0])
        if shared:
            line += ' They share %d components (the same classes and the connection to Claude), which are installed once.' % shared
        said.append(line)
    return ' '.join(said)


def menu(kit=None):
    """The choices as lines to show a person: the label, what it is, what it brings, and the command."""
    kit = kit or manifest()
    all_of = listed(kit)
    lines = ['How the parts stack: ' + shape(kit), '']
    for name in order(kit):
        entry = all_of[name]
        lines.append('%s  (%s)' % (entry['label'], name))
        lines.append('    ' + entry['option'])
        brought = [all_of[other]['label'] if other in all_of else other for other in entry.get('brings', [])]
        if brought:
            lines.append('    Comes with: %s.' % ', '.join(brought) + (' ' + entry['whyEverything'] if entry.get('whyEverything') else ''))
        elif entry['kind'] in ('layer', 'slice'):
            lines.append('    Comes with nothing else of ours.')
        for other, count in sorted((entry.get('sharedWith') or {}).items()):
            lines.append('    Shares %d components with "%s": they are the same files, installed once, and stay when only one of the two is removed.' % (count, all_of[other]['label']))
        if entry.get('provenNote'):
            lines.append('    ' + entry['provenNote'])
        if entry.get('carriedWords'):
            lines.append('    Also carries: ' + entry['carriedWords'])
        for need in entry.get('needsFirst', []):
            lines.append('    Needs: ' + need)
        if entry.get('ownYes'):
            lines.append('    Asks for its own yes: ' + entry['ownYes'])
        lines.append('    Install: ' + (entry.get('command') or '; '.join(entry.get('how', []))))
    return lines


# ---------------------------------------------------------------- what the org holds

def named_tabs(names):
    """The tabs that have a name of their own. The tab of a custom object is named after its object and is there
    when the object is, so it says nothing more than the object does and is not asked for."""
    return [name for name in names if not name.endswith('__c')]


def by_name(lead, kind, names):
    """One counting question for each name, to the Tooling API, which answers the same whoever asks."""
    return [(lead + name, soql("SELECT COUNT() FROM %s WHERE NamespacePrefix = null AND DeveloperName = '%s'" % (kind, name), tooling=True)) for name in names]


def read_by_name(lead, answers):
    """The names the org holds, from by_name's answers. None when it would not answer one of them: unknown, not absent."""
    asked = {name[len(lead):]: answer for name, answer in answers.items() if name.startswith(lead)}
    if not asked or not all(ok for ok, _ in asked.values()):
        return None
    return {name for name, (_, payload) in asked.items() if (payload or {}).get('totalSize')}


def standing_questions(kit, username):
    ours = kit['ours']
    apps = sorted(set(ours.get('apps', [])) | {entry['app'] for entry in listed(kit).values() if entry.get('app')})
    tabs = sorted(set(ours.get('tabs', [])) | {one for entry in listed(kit).values() for one in (entry.get('detect') or {}).get('CustomTab', [])})
    user = (username or '').replace("'", "\\'")
    return [
        ('ApexClass', soql("SELECT Name FROM ApexClass WHERE NamespacePrefix = null AND Name LIKE 'Antsurance%'")),
        ('ApexTrigger', soql("SELECT Name FROM ApexTrigger WHERE NamespacePrefix = null AND Name LIKE 'Antsurance%'")),
        ('Flow', soql('SELECT ApiName FROM FlowDefinitionView WHERE ApiName IN (%s)' % in_list(ours.get('flows', [])))),
        ('CustomObject', soql('SELECT QualifiedApiName FROM EntityDefinition WHERE QualifiedApiName IN (%s)' % in_list(ours.get('customObjects', [])))),
        ('PermissionSet', soql("SELECT Name FROM PermissionSet WHERE NamespacePrefix = null AND IsOwnedByProfile = false AND Name LIKE 'Antsurance%'")),
        ('ApexPage', soql("SELECT Name FROM ApexPage WHERE NamespacePrefix = null AND Name LIKE 'Antsurance%'")),
        ('StaticResource', soql('SELECT Name FROM StaticResource WHERE NamespacePrefix = null AND Name IN (%s)' % in_list(ours.get('staticResources', [])))),
        ('LightningComponentBundle', soql("SELECT COUNT() FROM LightningComponentBundle WHERE NamespacePrefix = null AND DeveloperName LIKE 'antsurance%'", tooling=True)),
        ('mine', soql("SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE Assignee.Username = '%s' AND PermissionSet.NamespacePrefix = null AND PermissionSet.Name LIKE 'Antsurance%%'" % user)),
        ('describeCase', 'sobjects/Case/describe'), ('describeOpportunity', 'sobjects/Opportunity/describe'), ('describeQuote', 'sobjects/Quote/describe'),
        ('paths', soql('SELECT COUNT() FROM PathAssistant', tooling=True)),
        # An app or a tab is asked for one by one, and counted, not listed: the lists of apps and tabs a person gets
        # hold only the ones that person may open, and whether one is in the org must not depend on who asks.
    ] + by_name('app:', 'CustomApplication', apps) + by_name('tab:', 'CustomTab', named_tabs(tabs))


FIELDS = {'ApexClass': 'Name', 'ApexTrigger': 'Name', 'Flow': 'ApiName', 'CustomObject': 'QualifiedApiName', 'PermissionSet': 'Name',
          'ApexPage': 'Name', 'StaticResource': 'Name'}
PICKLISTS = {'CaseStatus': ('describeCase', 'Status'), 'CaseOrigin': ('describeCase', 'Origin'), 'OpportunityStage': ('describeOpportunity', 'StageName'),
             'OpportunityType': ('describeOpportunity', 'Type'), 'QuoteStatus': ('describeQuote', 'Status')}


def read_standing(kit, answers):
    """Turns the org's answers into what it holds: {kind: names}, how many screen components, which sets the person
    holds, and which of the things a capability needs first are missing."""
    have = {kind: {row[FIELDS[kind]] for row in records(answers[kind])} if answers.get(kind, (False, None))[0] else None for kind in ASKED if kind in FIELDS}
    have['CustomApplication'] = read_by_name('app:', answers)
    have['CustomTab'] = read_by_name('tab:', answers)
    ok, payload = answers.get('LightningComponentBundle', (False, None))
    have['LightningComponentBundle'] = (payload or {}).get('totalSize') if ok else None
    have['mine'] = {(row.get('PermissionSet') or {}).get('Name') for row in records(answers.get('mine', (False, None)))}
    have['quotes'] = bool(answers.get('describeQuote', (False, None))[0])
    have['path'] = bool(answers.get('paths', (False, None))[0])
    missing = {}
    for value_set, wanted in sorted((kit.get('standardValueSets') or {}).items()):
        ask, field = PICKLISTS.get(value_set, (None, None))
        ok, payload = answers.get(ask, (False, None))
        if not ok:
            continue
        values = {value.get('value') for one in (payload or {}).get('fields', []) if one.get('name') == field for value in one.get('picklistValues', [])}
        absent = [value['fullName'] for value in wanted if value['fullName'] not in values]
        if absent:
            missing[value_set] = absent
    have['missingValues'] = missing
    have['unanswered'] = sorted(kind for kind in ASKED if have[kind] is None)
    return have


def standing(org_alias, username, kit=None):
    """One batch of read-only questions: what of ours the org holds."""
    kit = kit or manifest()
    return read_standing(kit, batch(org_alias, standing_questions(kit, username)))


def judge(kit, have):
    """Which choices the org holds, from what it has by name. Calls nothing.

    Returns {'whole': the whole app is there, 'installed': [names], 'partly': {name: what of it is there},
    'outside': {kind: names of ours that no installed choice holds}, 'components': (in the org, in the installed sets)}.
    """
    all_of = listed(kit)
    sets = have.get('PermissionSet') or set()
    whole = WHOLE_APP_SET in sets
    present = {(kind, name) for kind in ASKED for name in (have.get(kind) or set()) if kind != 'CustomTab' or name in named_tabs([name])}
    members = {}
    # A kind the org would not answer for is unknown: it neither proves nor disproves that a choice is installed.
    known = [kind for kind in ASKED if have.get(kind) is not None]
    for name, entry in all_of.items():
        detect = entry.get('detect') or {}
        members[name] = {(kind, one) for kind in known for one in (named_tabs(detect.get(kind, [])) if kind == 'CustomTab' else detect.get(kind, []))}
    installed = [name for name in order(kit) if members[name] and members[name] <= present and all_of[name]['kind'] in ('layer', 'slice', 'phase')]
    if whole:
        # The whole app holds every layer. A slice or a phase is still its own thing beside it.
        installed = ['everything'] + [name for name in installed if all_of[name]['kind'] != 'layer']
    explained = set().union(*[members[name] for name in installed if name in members]) if installed else set()
    for name in installed:
        # What an installed choice may also have put in, depending on what was there before it (the portal's staff set).
        explained |= {(kind, one) for kind, names in ((all_of.get(name) or {}).get('mayAlsoHold') or {}).items() for one in names}
    if whole:
        ours = kit['ours']
        explained |= {('ApexClass', one) for one in ours.get('apexClasses', [])} | {('ApexTrigger', one) for one in ours.get('apexTriggers', [])}
        explained |= {('Flow', one) for one in ours.get('flows', [])} | {('CustomObject', one) for one in ours.get('customObjects', [])}
        explained |= {('PermissionSet', one) for one in ours.get('permissionSets', [])} | {('CustomTab', one) for one in ours.get('tabs', [])}
        explained |= {('CustomApplication', one) for one in ours.get('apps', [])} | {('ApexPage', one) for one in ours.get('apexPages', [])}
        explained |= {('StaticResource', one) for one in ours.get('staticResources', [])}
    found = {}
    for name in order(kit):
        if name in installed or not members[name] or (whole and all_of[name]['kind'] == 'layer'):
            continue
        there = members[name] & present - explained
        if there:
            found[name] = there
    # Something two choices hold (the chat's tab is in the pages and in Ask Claude) says "part of it is there" of the
    # choice that has more of itself in the org, not of both.
    partly = {}
    for name, there in found.items():
        of_a_fuller_one = set().union(*[other_there for other, other_there in found.items() if other != name and len(other_there) > len(there)])
        if there - of_a_fuller_one:
            partly[name] = sorted('%s %s' % pair for pair in there)
    outside = {}
    for kind, one in sorted(present - explained):
        outside.setdefault(kind, []).append(one)
    in_sets = None
    if have.get('LightningComponentBundle') is not None and not whole:
        bundles = set()
        for name in installed:
            bundles |= set(((all_of.get(name) or {}).get('detect') or {}).get('LightningComponentBundle', []))
        in_sets = len(bundles)
    return {'whole': whole, 'installed': installed, 'partly': partly, 'outside': outside,
            'components': (have.get('LightningComponentBundle'), in_sets)}


def standing_lines(kit, have, state):
    """What the org holds, in words: the choices that are there, and anything of ours that none of them holds."""
    all_of = listed(kit)
    lines = []
    labels = ['the whole app' if name == 'everything' else all_of[name]['label'] for name in state['installed']]
    lines.append('In the org now: %s.' % (', '.join(labels) if labels else 'nothing of ours that installs as a part'))
    for name, there in sorted(state['partly'].items()):
        lines.append('  Part of "%s" is there and the rest is not (%d found: %s%s).' % (all_of[name]['label'], len(there), ', '.join(there[:4]), ' and others' if len(there) > 4 else ''))
    extra = {kind: names for kind, names in state['outside'].items() if not any(('%s %s' % (kind, one)) in there for there in state['partly'].values() for one in names)}
    if extra:
        lines.append('  Of ours and in none of those: ' + '; '.join('%d %s (%s%s)' % (len(names), KIND_WORDS[kind], ', '.join(names[:4]), ' and others' if len(names) > 4 else '') for kind, names in sorted(extra.items())) + '.')
    elif not state['partly']:
        lines.append('  Nothing else of ours is in the org (checked by name: %s).' % ', '.join(KIND_WORDS[kind] for kind in ASKED if have.get(kind) is not None))
    in_org, in_sets = state['components']
    if in_org is not None and in_sets is not None:
        more = ('' if in_org == in_sets else ' The org has %d fewer: a part was installed from an older kit, or stopped part-way. Run its install again to bring it up to date.' % (in_sets - in_org) if in_org < in_sets
                else ' The org has %d more: screen components of ours that none of the parts above holds.' % (in_org - in_sets))
        lines.append('  Screen components of ours in the org: %d. The sets above hold %d.%s' % (in_org, in_sets, more))
    if have.get('unanswered'):
        lines.append('  The org would not say which of these it holds, so they are unknown, not absent: %s.' % ', '.join(KIND_WORDS[kind] for kind in have['unanswered']))
    return lines


def missing_first(kit, name, have):
    """What this choice needs in the org before it can deploy, and is not there. Plain lines with the command for each."""
    needs = {}
    for other in chain(name, kit):
        for key, value in (listed(kit).get(other, {}).get('prerequisites') or {}).items():
            needs[key] = needs.get(key) or value
    lines = []
    if needs.get('quotes') and not have.get('quotes'):
        lines.append('Quotes are switched off, and the data model adds fields to Quote. Switch them on: python3 scripts/setup/deploy_phase.py --target-org <alias> --phase prerequisites --enable quotes')
    absent = {value_set: values for value_set, values in (have.get('missingValues') or {}).items() if value_set in (needs.get('valueSets') or []) or (value_set.startswith('Quote') and needs.get('quotes'))}
    if absent:
        lines.append('Our values are not in these standard picklists yet: %s. Add them (yours are all kept): python3 scripts/setup/deploy_phase.py --target-org <alias> --phase value-sets'
                     % '; '.join('%s (%s)' % (value_set, ', '.join(values[:4]) + (' and %d more' % (len(values) - 4) if len(values) > 4 else '')) for value_set, values in sorted(absent.items())))
    if needs.get('path') and not have.get('path'):
        lines.append('Path is switched off, and the pages hold four paths. Switch it on: python3 scripts/setup/deploy_phase.py --target-org <alias> --phase prerequisites --enable path')
    return lines


def plan(kit, name, state):
    """What installing this choice would do here. Returns (the layers to deploy, in order; lines to say first)."""
    all_of = listed(kit)
    entry = all_of[name]
    lines, todo = [], []
    for other in chain(name, kit):
        if other == name:
            continue
        there = other in state['installed'] or state['whole']
        lines.append('"%s" needs "%s"%s: %s.' % (entry['label'], all_of[other]['label'], ' (%s)' % entry['bringsWhy'][other] if (entry.get('bringsWhy') or {}).get(other) else '',
                                             'it is already there' if there else 'it is not in the org yet, so it will be installed first'))
        if not there:
            todo.append(other)
    todo.append(name)
    if len(todo) > 1:
        lines.append('So %d sets will be installed, in this order: %s.' % (len(todo), ', then '.join('"%s"' % all_of[other]['label'] for other in todo)))
    return todo, lines


def built_on(kit, name, state):
    """The choices in the org that need this one, so it cannot be removed from under them. One that is only partly
    there (its install or its removal stopped part-way) still holds things built on this one."""
    there = list(state['installed']) + [other for other in order(kit) if other in state.get('partly', {}) and other not in state['installed']]
    return [other for other in there if other != name and other in listed(kit) and name in listed(kit)[other].get('brings', [])]
