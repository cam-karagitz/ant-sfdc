"""The metadata half of the preflight: pulls what the org has, compares it with the kit, and reads the org's conventions.

Not a command of its own. `analyze_org.py` is the one command, and it calls this whenever the org holds anything of
its own or anything of ours. Three parts:

  pull         One read-only retrieve of the metadata ours could meet, into .install/org-metadata/<alias>/.
  compare      Every file of ours against the same file in the org: the same, different, or not there.
  conventions  How the org names and builds things, with how many examples each observation rests on.

Nothing here changes the org. A retrieve only reads.
"""
import json
import os
import re
import shutil
import time
import xml.etree.ElementTree as ElementTree
from collections import Counter

from _common import KIT_ROOT, STATE_DIR, USAGE, SetupError, api_version, sf

NAMESPACE = 'http://soap.sforce.com/2006/04/metadata'
# Pulled whole, because what the org has of these is what ours sits beside. Each is small text.
WILDCARD = ['CustomObject', 'Layout', 'ApexTrigger', 'CustomApplication', 'CustomTab', 'FlexiPage', 'NamedCredential',
            'ExternalCredential', 'GlobalValueSet', 'LightningExperienceTheme', 'QuickAction', 'CustomPermission',
            'CustomNotificationType', 'CspTrustedSite', 'RemoteSiteSetting', 'PathAssistant', 'ReportType']
# Pulled by our names only: if the org has one, we get its content to compare. The org's own Apex classes, components,
# flows, permission sets and static resources are listed by name with queries instead, so a large org stays a small pull.
# Only names the questions found in the org are asked for, so the org has nothing to warn about.
NAMED = {
    'ApexClass': ['apexClasses', 'portalClasses'], 'ApexPage': ['apexPages'], 'LightningComponentBundle': ['lwc'], 'Flow': ['flows'],
    'PermissionSet': ['permissionSets'], 'CustomMetadata': ['customMetadata'], 'Group': ['groups'],
}
# Where the kit keeps files that are ours alone. The optional look and feel and the switches are asked about, not compared.
OUR_ROOTS = [os.path.join('force-app', 'main', 'default'), os.path.join('optional', 'portal')]
NOT_COMPARED = {'standardValueSets', 'staticresources', 'contentassets', 'reports', 'dashboards', 'profiles', 'settings', 'sites', 'networks',
                'digitalExperiences', 'digitalExperienceConfigs', 'platformEventSubscriberConfigs', 'documents', 'email'}
BUNDLES = {'lwc', 'aura'}
KIND_WORDS = {
    'classes': 'Apex class', 'triggers': 'trigger', 'lwc': 'screen component', 'aura': 'Aura component', 'flows': 'flow', 'object': 'object',
    'fields': 'field', 'recordTypes': 'record type', 'validationRules': 'validation rule', 'businessProcesses': 'process',
    'compactLayouts': 'compact layout', 'listViews': 'list view', 'webLinks': 'button or link', 'layouts': 'page layout',
    'permissionsets': 'permission set', 'applications': 'app', 'tabs': 'tab', 'flexipages': 'Lightning page', 'quickActions': 'action',
    'pages': 'Visualforce page', 'customMetadata': 'settings record', 'customPermissions': 'custom permission',
    'notificationtypes': 'notification type', 'cspTrustedSites': 'trusted site', 'remoteSiteSettings': 'remote site',
    'pathAssistants': 'path', 'reportTypes': 'report type', 'groups': 'public group', 'namedCredentials': 'named credential',
    'externalCredentials': 'external credential', 'globalValueSets': 'global value set',
}
# Fields a new Developer Edition org ships with. They are Salesforce's samples, not the org's own way of naming things.
SAMPLE_FIELDS = {
    'Account': {'Active__c', 'CustomerPriority__c', 'NumberofLocations__c', 'SLA__c', 'SLAExpirationDate__c', 'SLASerialNumber__c', 'UpsellOpportunity__c'},
    'Case': {'EngineeringReqNumber__c', 'PotentialLiability__c', 'Product__c', 'SLAViolation__c'},
    'Contact': {'Languages__c', 'Level__c'},
    'Lead': {'CurrentGenerators__c', 'NumberofLocations__c', 'Primary__c', 'ProductInterest__c', 'SICCode__c'},
    'Opportunity': {'CurrentGenerators__c', 'DeliveryInstallationStatus__c', 'MainCompetitors__c', 'OrderNumber__c', 'TrackingNumber__c'},
}


# Classes Salesforce adds by itself when Digital Experiences or Sites is switched on. Not the org's own work.
STOCK_CLASSES = {name + ending for name in (
    'ChangePasswordController', 'CommunitiesLandingController', 'CommunitiesLoginController', 'CommunitiesSelfRegConfirmController', 'CommunitiesSelfRegController',
    'ForgotPasswordController', 'MyProfilePageController', 'SiteLoginController', 'SiteRegisterController', 'LightningForgotPasswordController',
    'LightningLoginFormController', 'LightningSelfRegisterController', 'MicrobatchSelfRegController') for ending in ('', 'Test')}
# Settings the org leaves out of a file when they hold their default. Ours spelling one out is not a difference.
DEFAULTS_LEFT_OUT = {'false', 'BlankAsBlank'}
# What the org rewrites in a file it was given, so a difference there says nothing: where a flow's boxes sit on the
# canvas (it lays them out itself), and the display name after the colon in a tab's icon.
REWRITTEN_BY_THE_ORG = {'locationX', 'locationY'}
# A field Salesforce always requires is stored as required on a page whatever the page file said.
STORED_AS = {('none', 'required')}


def is_ours(name, listed=()):
    """Ours by the kit's list, or by the prefix every component we ship carries."""
    return name in listed or name.lower().startswith('antsurance')


# ---------------------------------------------------------------- pull

def standard_objects(kit):
    """The standard objects ours adds to or saves records in. Activity holds the custom fields of tasks and events."""
    return sorted(set(kit['ours'].get('standardObjectFields', {})) | set(kit.get('insertsInto', [])) | {'Activity'})


def manifest_xml(kit, in_org=None):
    """The list of what to pull, as a package.xml.

    `in_org` is {metadata type: the names of ours the org has}, from the questions. A type it does not mention is
    asked for by every name of ours.
    """
    ours = kit['ours']
    in_org = in_org or {}
    members = {name: ['*'] for name in WILDCARD}
    standard = [name for name in standard_objects(kit) if name not in in_org.get('missingObjects', ())]
    members['CustomObject'] += standard
    for kind, keys in NAMED.items():
        named = {name for key in keys for name in ours.get(key, [])}
        # A part of the app that installs alone has a few components of its own (its app, its permission set).
        named = named | {name for part in (kit.get('slices') or {}).values() for name in (part.get('members') or {}).get(kind, [])}
        if kind == 'PermissionSet':
            # A part cut from the app has a permission set of its own, which the app's own list does not hold.
            named |= {one for part in (kit.get('capabilities') or {}).values() for one in (part.get('permissionSet'), part.get('staffSet')) if one}
        named = sorted(named)
        if kind in in_org:
            named = [name for name in named if name in in_org[kind]]
        elif kind == 'CustomMetadata' and 'customMetadataTypes' in in_org:
            named = [name for name in named if name.split('.')[0] + '__mdt' in in_org['customMetadataTypes']]
        if named:
            members[kind] = named
    members['StandardValueSet'] = sorted(name for name in kit.get('standardValueSets', {}) if not ('Quote' in in_org.get('missingObjects', ()) and name.startswith('Quote')))
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<Package xmlns="%s">' % NAMESPACE]
    for kind in sorted(members):
        lines.append('    <types>')
        lines += ['        <members>%s</members>' % name.replace('&', '&amp;') for name in members[kind]]
        lines += ['        <name>%s</name>' % kind, '    </types>']
    lines += ['    <version>%s</version>' % (kit.get('apiVersion') or api_version()), '</Package>']
    return '\n'.join(lines) + '\n'


def pull_folder(alias):
    return os.path.join(STATE_DIR, 'org-metadata', re.sub(r'[^A-Za-z0-9._-]', '_', alias))


def metadata_root(folder):
    return os.path.join(folder, 'org', 'main', 'default')


def pull(alias, kit, in_org=None):
    """One read-only retrieve into .install/org-metadata/<alias>/. Returns what it cost and what came back.

    The retrieve runs in a small Salesforce project of its own under stage/, so the files arrive laid out like the
    kit's and the kit's own folders are never written to. The result is then moved to .install/org-metadata/<alias>/,
    replacing an earlier pull of the same org. It is not retrieved straight into .install/: the Salesforce CLI
    ignores every file under a folder whose name starts with a dot, and would write nothing.
    """
    folder = pull_folder(alias)
    work = os.path.join(KIT_ROOT, 'stage', 'org-metadata')
    for path in (folder, work):
        if os.path.isdir(path):
            shutil.rmtree(path)
    os.makedirs(os.path.join(work, 'org'))
    with open(os.path.join(work, 'sfdx-project.json'), 'w') as handle:
        json.dump({'packageDirectories': [{'path': 'org', 'default': True}], 'namespace': '', 'sourceApiVersion': kit.get('apiVersion') or api_version()}, handle, indent=2)
    with open(os.path.join(work, '.forceignore'), 'w') as handle:
        handle.write('# Nothing is left out of a pull.\n')
    with open(os.path.join(work, 'manifest.xml'), 'w') as handle:
        handle.write(manifest_xml(kit, in_org))
    started = time.time()
    reply = sf(['project', 'retrieve', 'start', '--manifest', 'manifest.xml', '--target-org', alias, '--wait', '30', '--ignore-conflicts'], timeout=2100, allow_failure=True, cwd=work)
    seconds = int(time.time() - started)
    # A retrieve is one request to start, one to fetch, and one status check about every second in between.
    requests = 2 + seconds
    USAGE['requests'] += requests
    files = sum(len(names) for _, _, names in os.walk(os.path.join(work, 'org')))
    result = reply.get('result') or {}
    notes = []
    for holder in (reply.get('warnings'), result.get('warnings'), result.get('messages'), (result.get('response') or {}).get('messages')):
        for note in holder if isinstance(holder, list) else []:
            notes.append(str(note.get('problem') or note.get('message') or note) if isinstance(note, dict) else str(note))
    os.makedirs(os.path.dirname(folder), exist_ok=True)
    shutil.move(work, folder)
    if not files:
        # Kept for whoever has to find out why: the org's answer, without the list of files.
        with open(os.path.join(folder, 'pull-refused.json'), 'w') as handle:
            json.dump({key: value for key, value in dict(reply, result={key: value for key, value in result.items() if key not in ('files', 'fileProperties')}).items() if key != 'stack'}, handle, indent=2, default=str)
        raise SetupError('The org gave back no metadata (%s). Its full answer is in %s.' % (
            str(reply.get('message') or '; '.join(notes[:3]) or 'no reason given')[:400], os.path.relpath(os.path.join(folder, 'pull-refused.json'), KIT_ROOT)))
    not_there = [note for note in notes if 'cannot be found' in note or 'not found' in note.lower() or 'not available' in note]
    other = [note for note in notes if note not in not_there]
    summary = {'folder': os.path.relpath(folder, KIT_ROOT), 'files': files, 'seconds': seconds, 'requests': requests, 'notInOrg': len(not_there),
               'warnings': other[:20], 'complete': reply.get('status', 0) == 0}
    with open(os.path.join(folder, 'pull.json'), 'w') as handle:
        json.dump(summary, handle, indent=2, sort_keys=True)
    return summary


# ---------------------------------------------------------------- reading metadata files

def tag_of(element):
    return element.tag.split('}', 1)[-1]


def parse(path):
    try:
        return ElementTree.parse(path).getroot()
    except (ElementTree.ParseError, OSError):
        return None


def text_of(element, name, default=None):
    """The text of the first child with this tag."""
    if element is None:
        return default
    for child in element:
        if tag_of(child) == name:
            return (child.text or '').strip()
    return default


def children(element, name):
    return [child for child in (element if element is not None else []) if tag_of(child) == name]


def name_of(file_name):
    """A component's name from its file name: 'A.Default.md-meta.xml' is 'A.Default', 'X.cls' is 'X'."""
    base = file_name[:-len('-meta.xml')] if file_name.endswith('-meta.xml') else file_name
    return base.rsplit('.', 1)[0] if '.' in base else base


def listed(folder, suffix):
    if not os.path.isdir(folder):
        return []
    return sorted(name for name in os.listdir(folder) if name.endswith(suffix))


def read_inventory(root):
    """What the pulled files say the org has, in the shape the checks and the conventions read."""
    found = {'objects': {}, 'layouts': {}, 'triggers': {}, 'apps': {}, 'pages': {}, 'tabs': [], 'namedCredentials': [], 'externalCredentials': [],
             'globalValueSets': [], 'themes': [], 'valueSets': {}}
    objects = os.path.join(root, 'objects')
    for name in sorted(os.listdir(objects)) if os.path.isdir(objects) else []:
        base = os.path.join(objects, name)
        own = parse(os.path.join(base, name + '.object-meta.xml'))
        entry = {'label': text_of(own, 'label'), 'setting': text_of(own, 'customSettingsType') is not None, 'fields': {}, 'recordTypes': {},
                 'validationRules': {}, 'businessProcesses': [name_of(one) for one in listed(os.path.join(base, 'businessProcesses'), '-meta.xml')]}
        for one in listed(os.path.join(base, 'fields'), '.field-meta.xml'):
            field = parse(os.path.join(base, 'fields', one))
            entry['fields'][name_of(one)] = {
                'type': text_of(field, 'type'), 'label': text_of(field, 'label'), 'required': text_of(field, 'required') == 'true',
                'described': bool(text_of(field, 'description')), 'helped': bool(text_of(field, 'inlineHelpText')),
                'hasDefault': bool(text_of(field, 'defaultValue')), 'formula': text_of(field, 'formula') is not None}
        for one in listed(os.path.join(base, 'recordTypes'), '.recordType-meta.xml'):
            kind = parse(os.path.join(base, 'recordTypes', one))
            entry['recordTypes'][name_of(one)] = {'label': text_of(kind, 'label'), 'active': text_of(kind, 'active') != 'false'}
        for one in listed(os.path.join(base, 'validationRules'), '.validationRule-meta.xml'):
            rule = parse(os.path.join(base, 'validationRules', one))
            entry['validationRules'][name_of(one)] = {'active': text_of(rule, 'active') == 'true', 'formula': text_of(rule, 'errorConditionFormula') or '',
                                                      'message': text_of(rule, 'errorMessage') or ''}
        found['objects'][name] = entry
    for one in listed(os.path.join(root, 'layouts'), '.layout-meta.xml'):
        layout = parse(os.path.join(root, 'layouts', one))
        full = name_of(one)
        required = sorted({text_of(item, 'field') for item in (layout.iter('{%s}layoutItems' % NAMESPACE) if layout is not None else [])
                           if text_of(item, 'behavior') == 'Required' and text_of(item, 'field')})
        found['layouts'].setdefault(full.split('-', 1)[0], []).append({'name': full, 'required': required})
    for one in listed(os.path.join(root, 'triggers'), '.trigger'):
        with open(os.path.join(root, 'triggers', one), encoding='utf-8', errors='replace') as handle:
            body = handle.read()
        code = re.sub(r'/\*.*?\*/|//[^\n]*', '', body, flags=re.S)
        head = re.search(r'\btrigger\s+(\w+)\s+on\s+(\w+)\s*\(([^)]*)\)', code, re.I)
        meta = parse(os.path.join(root, 'triggers', one + '-meta.xml'))
        found['triggers'][name_of(one)] = {
            'object': head.group(2) if head else None, 'events': [' '.join(event.split()).lower() for event in head.group(3).split(',')] if head else [],
            'active': text_of(meta, 'status', 'Active') == 'Active', 'apiVersion': text_of(meta, 'apiVersion'),
            'lines': len([line for line in code.splitlines() if line.strip()]),
            'handsOff': bool(re.search(r'\b\w*(Handler|Dispatcher|Factory|Domain|Service|Automation|Manager)\w*\s*[.(]', code))}
    for one in listed(os.path.join(root, 'applications'), '.app-meta.xml'):
        app = parse(os.path.join(root, 'applications', one))
        found['apps'][name_of(one)] = {'label': text_of(app, 'label'), 'utilityBar': text_of(app, 'utilityBar'), 'lightning': text_of(app, 'uiType') == 'Lightning',
                                      'console': text_of(app, 'navType') == 'Console'}
    for one in listed(os.path.join(root, 'flexipages'), '.flexipage-meta.xml'):
        page = parse(os.path.join(root, 'flexipages', one))
        found['pages'][name_of(one)] = {'type': text_of(page, 'type'), 'object': text_of(page, 'sobjectType'), 'label': text_of(page, 'masterLabel')}
    for key, folder, suffix in (('tabs', 'tabs', '.tab-meta.xml'), ('namedCredentials', 'namedCredentials', '.namedCredential-meta.xml'),
                                ('externalCredentials', 'externalCredentials', '.externalCredential-meta.xml'),
                                ('globalValueSets', 'globalValueSets', '.globalValueSet-meta.xml'), ('themes', 'lightningExperienceThemes', '.lightningExperienceTheme-meta.xml')):
        found[key] = [name_of(one) for one in listed(os.path.join(root, folder), suffix)]
    for one in listed(os.path.join(root, 'standardValueSets'), '.standardValueSet-meta.xml'):
        found['valueSets'][name_of(one)] = read_value_set(os.path.join(root, 'standardValueSets', one))
    return found


def read_value_set(path):
    root = parse(path)
    return [{tag_of(part): (part.text or '').strip() for part in value} for value in children(root, 'standardValue')]


# ---------------------------------------------------------------- compare ours with theirs

def canon(element):
    """An element as a value that ignores the order of its children."""
    parts = [part for part in element if tag_of(part) not in REWRITTEN_BY_THE_ORG]
    if not parts:
        text = ' '.join((element.text or '').split())
        return (tag_of(element), text.split(':')[0] if tag_of(element) == 'motif' else text)
    return (tag_of(element), tuple(sorted((canon(part) for part in parts), key=repr)))


def within(ours, theirs):
    """Whether everything our file says is also in the org's file. The org may say more: it fills in defaults."""
    if ours == theirs:
        return True
    if ours[0] != theirs[0]:
        return False
    mine, yours = ours[1], theirs[1]
    if isinstance(mine, str) or isinstance(yours, str):
        # A blank the installer fills in ({{RUNNING_USER}}) matches whatever the org holds.
        return isinstance(mine, str) and isinstance(yours, str) and ('{{' in mine or same_value(mine, yours))
    left = Counter(yours)
    waiting = []
    for part in mine:
        if left[part] > 0:
            left[part] -= 1
        else:
            waiting.append(part)
    tags = {other[0] for other in yours}
    for part in waiting:
        match = next((other for other in left if left[other] > 0 and other[0] == part[0] and within(part, other)), None)
        if match is None:
            if isinstance(part[1], str) and part[1] in DEFAULTS_LEFT_OUT and part[0] not in tags:
                continue
            return False
        left[match] -= 1
    return True


def same_value(mine, yours):
    if mine == yours or (mine, yours) in STORED_AS:
        return True
    try:
        return float(mine) == float(yours)
    except ValueError:
        return False


def what_differs(ours, theirs):
    """The top-level settings of ours that the org's file does not hold, by tag, for a one-line reason."""
    if isinstance(ours[1], str) or isinstance(theirs[1], str):
        return []
    left = Counter(theirs[1])
    there = {other[0] for other in theirs[1]}
    tags = []
    for part in ours[1]:
        if left[part] > 0:
            left[part] -= 1
        elif isinstance(part[1], str) and part[1] in DEFAULTS_LEFT_OUT and part[0] not in there:
            continue
        elif not any(left[other] > 0 and other[0] == part[0] and within(part, other) for other in left):
            tags.append(part[0])
    return sorted(set(tags))


def same_file(ours, theirs):
    """(same, reason). XML is compared by what it says, code by its text with line endings and trailing spaces evened out."""
    try:
        with open(ours, encoding='utf-8') as handle:
            mine = handle.read()
        with open(theirs, encoding='utf-8') as handle:
            yours = handle.read()
    except UnicodeDecodeError:
        with open(ours, 'rb') as one, open(theirs, 'rb') as two:
            return one.read() == two.read(), 'the file'
    if ours.endswith('.xml'):
        try:
            a, b = canon(ElementTree.fromstring(mine)), canon(ElementTree.fromstring(yours))
        except ElementTree.ParseError:
            return mine == yours, 'the file'
        if within(a, b):
            return True, None
        return False, ', '.join(what_differs(a, b)[:4]) or 'its settings'

    def even(text):
        return '\n'.join(line.rstrip() for line in text.replace('\r\n', '\n').strip().split('\n'))
    return even(mine) == even(yours), os.path.basename(ours)


def component_of(rel):
    """(kind, name) of the component a file of ours belongs to, from its path under the metadata folder."""
    parts = rel.split(os.sep)
    if parts[0] == 'objects':
        if len(parts) == 3:
            return 'object', parts[1]
        return parts[2], '%s.%s' % (parts[1], name_of(parts[-1]))
    if parts[0] in BUNDLES:
        return parts[0], parts[1]
    return parts[0], name_of(parts[-1])


def compare(kit_root, pulled_root, roots=None):
    """Every component of ours, sorted into the same as the org's, different from it, or not in the org.

    `roots` are the kit folders to compare: the whole app unless one part of it is what the org has.
    Returns {'same': [...], 'different': [...], 'absent': n}; each entry is {kind, name, reason}.
    """
    components = {}
    for base in roots or OUR_ROOTS:
        top = os.path.join(kit_root, base)
        for folder, dirs, names in os.walk(top):
            dirs[:] = sorted(name for name in dirs if name != '__tests__')
            for name in sorted(names):
                rel = os.path.relpath(os.path.join(folder, name), top)
                if rel.split(os.sep)[0] in NOT_COMPARED or name.startswith('.') or name in ('jsconfig.json', '.eslintrc.json'):
                    continue
                components.setdefault(component_of(rel), []).append((os.path.join(folder, name), os.path.join(pulled_root, rel)))
    result = {'same': [], 'different': [], 'absent': 0}
    for (kind, name), files in sorted(components.items()):
        there = [(ours, theirs) for ours, theirs in files if os.path.exists(theirs)]
        if not there:
            result['absent'] += 1
            continue
        reasons = []
        if len(there) < len(files):
            reasons.append('a file of ours is not in the org')
        for ours, theirs in there:
            same, reason = same_file(ours, theirs)
            if not same:
                reasons.append(reason)
        entry = {'kind': kind, 'name': name}
        if reasons:
            result['different'].append(dict(entry, reason='; '.join(sorted(set(reasons))[:3])))
        else:
            result['same'].append(entry)
    return result


def field_types(kit_root, pulled_root, kit):
    """Fields of ours on standard objects that the org already has as another type: [(Object.Field, theirs, ours)]."""
    clashes = []
    for name, fields in sorted(kit['ours'].get('standardObjectFields', {}).items()):
        for field in fields:
            rel = os.path.join('objects', name, 'fields', field + '.field-meta.xml')
            theirs = parse(os.path.join(pulled_root, rel))
            ours = parse(os.path.join(kit_root, OUR_ROOTS[0], rel))
            if theirs is None or ours is None:
                continue
            mine, yours = text_of(ours, 'type'), text_of(theirs, 'type')
            if mine and yours and mine != yours:
                clashes.append(('%s.%s' % (name, field), yours, mine))
    return clashes


def our_triggers(kit_root):
    """{object: [our trigger names]} read from the kit's own trigger files."""
    by_object = {}
    for base in OUR_ROOTS:
        folder = os.path.join(kit_root, base, 'triggers')
        for one in listed(folder, '.trigger'):
            with open(os.path.join(folder, one), encoding='utf-8') as handle:
                head = re.search(r'\btrigger\s+(\w+)\s+on\s+(\w+)', re.sub(r'/\*.*?\*/|//[^\n]*', '', handle.read(), flags=re.S), re.I)
            if head:
                by_object.setdefault(head.group(2), []).append(head.group(1))
    return by_object


def value_set_collisions(kit_root, pulled):
    """Values of ours the org already has under the same name but meaning something else: [(set, value, what differs)].

    The installer keeps the org's value as it is, so ours is not added and the app would read theirs.
    """
    found = []
    folder = os.path.join(kit_root, 'optional', 'value-sets', 'standardValueSets')
    for one in listed(folder, '.standardValueSet-meta.xml'):
        name = name_of(one)
        theirs = {value.get('fullName', '').lower(): value for value in pulled.get(name, [])}
        for value in read_value_set(os.path.join(folder, one)):
            other = theirs.get(value.get('fullName', '').lower())
            if other is None:
                continue
            notes = []
            if other.get('fullName') != value.get('fullName'):
                notes.append('yours is written "%s"' % other.get('fullName'))
            for flag, word in (('closed', 'closed'), ('won', 'won'), ('converted', 'converted')):
                if flag in value and flag in other and value[flag] != other[flag]:
                    notes.append('yours is %s%s and ours is %s%s' % ('' if other[flag] == 'true' else 'not ', word, '' if value[flag] == 'true' else 'not ', word))
            if 'forecastCategory' in value and 'forecastCategory' in other and value['forecastCategory'] != other['forecastCategory']:
                notes.append('yours forecasts as %s and ours as %s' % (other['forecastCategory'], value['forecastCategory']))
            if notes:
                found.append((name, value.get('fullName'), '; '.join(notes)))
    return found


# ---------------------------------------------------------------- conventions

def is_managed(name):
    """A name that carries a package's namespace: ns__Thing__c, ns__Thing."""
    stem = re.sub(r'__(c|mdt|e|x|b|r|kav|ka|share|history|feed)$', '', name, flags=re.I)
    return '__' in stem


def stem_of(name):
    return re.sub(r'__(c|mdt|e|x|b)$', '', name, flags=re.I)


def style_of(name):
    """How a name is written: Capital_Words, PascalCase, camelCase, lower_words, or one word (which fits any)."""
    if '_' in name.strip('_'):
        words = [word for word in name.split('_') if word]
        if all(word[:1].isupper() or word[:1].isdigit() for word in words):
            return 'Capital_Words'
        return 'lower_words' if name == name.lower() else 'Mixed_words'
    inner_capital = any(char.isupper() for char in name[1:]) and not name.isupper()
    if name[:1].islower():
        return 'camelCase' if inner_capital else 'one word'
    return 'PascalCase' if inner_capital else 'one word'


def first_token(name):
    """The leading piece a prefix would be: 'ACME_' of ACME_Invoice, 'Acme' of AcmeInvoice, 'acme' of acmeInvoiceList."""
    if '_' in name.strip('_'):
        return name.split('_')[0] + '_'
    found = re.match(r'[A-Z]{2,}(?![a-z])|[A-Z]?[a-z0-9]+', name)
    return found.group(0) if found else name


def how_sure(matching, of):
    if not of:
        return 'nothing to go on'
    if of < 5:
        return 'a guess'
    share = matching / of
    if share >= 0.8:
        return 'sure' if of >= 20 else 'fairly sure'
    return 'fairly sure' if share >= 0.6 else 'mixed'


def observe(what, names, classify=style_of, ignore=('one word',), note=None):
    """One observation: the commonest way these names are written, how many fit, and how sure that makes it."""
    names = sorted(set(names))
    styles = Counter(classify(name) for name in names)
    counted = {style: count for style, count in styles.items() if style not in ignore and style}
    of = sum(counted.values())
    if not of:
        return {'what': what, 'does': 'Nothing of its own to read.' if not names else 'No pattern: %d example%s, none telling.' % (len(names), '' if len(names) == 1 else 's'),
                'matching': 0, 'of': len(names), 'sure': 'nothing to go on', 'examples': names[:3], 'style': None}
    style, matching = max(counted.items(), key=lambda item: (item[1], item[0]))
    examples = [name for name in names if classify(name) == style][:3]
    line = {'what': what, 'does': style, 'matching': matching, 'of': of, 'sure': how_sure(matching, of), 'examples': examples, 'style': style}
    if note:
        line['note'] = note
    return line


def prefix_of(names, least=3):
    """A leading piece at least half the names share, or None. Returns (prefix, how many, of how many)."""
    names = sorted(set(names))
    if len(names) < least:
        return None
    token, count = Counter(first_token(name) for name in names).most_common(1)[0]
    if count >= least and count * 2 >= len(names) and len(token.strip('_')) >= 2:
        return token, count, len(names)
    return None


def suffix_counts(names, endings):
    counts = Counter()
    for name in names:
        for ending in endings:
            if name.endswith(ending) and len(name) > len(ending):
                counts[ending] += 1
                break
    return counts


def label_style(label):
    words = [word for word in re.findall(r"[A-Za-z][A-Za-z']*", label or '')]
    if len(words) < 2:
        return 'one word'
    small = {'a', 'an', 'and', 'as', 'at', 'by', 'for', 'in', 'of', 'on', 'or', 'the', 'to', 'with', 'per', 'vs'}
    rest = [word for word in words[1:] if word.lower() not in small and not word.isupper()]
    if not rest:
        return 'one word'
    capitals = sum(1 for word in rest if word[:1].isupper())
    return 'Title Case' if capitals == len(rest) else 'Sentence case' if capitals == 0 else 'mixed'


def versions(values):
    counts = Counter(str(value).split('.')[0] for value in values if value)
    return ', '.join('%s (%d)' % (version, count) for version, count in sorted(counts.items(), key=lambda item: -item[1])[:5])


def read_conventions(kit, inventory, listing):
    """How the org names and builds things. Ours, managed packages and Salesforce's sample fields are left out.

    `listing` is what the queries found by name: classes, components, auras, flows, sets, setGroups, resources, each a
    list of rows. `inventory` is what the pull found. Either may be thin; every line says how many examples it rests on.
    """
    ours = kit['ours']
    mine = {key: set(ours.get(key, [])) for key in ('customObjects', 'apexClasses', 'portalClasses', 'lwc', 'flows', 'permissionSets', 'apexTriggers', 'apps', 'tabs', 'flexipages')}
    our_fields = {name: set(fields) for name, fields in ours.get('standardObjectFields', {}).items()}
    objects = inventory.get('objects', {})
    their_objects = [name for name in objects if name.endswith(('__c', '__mdt', '__e')) and name not in mine['customObjects'] and not is_managed(name)]
    fields, labels, described, helped, required = [], [], 0, 0, 0
    for name, entry in objects.items():
        if name in mine['customObjects'] or is_managed(name):
            continue
        for field, facts in entry['fields'].items():
            if not field.endswith('__c') or is_managed(field) or field in our_fields.get(name, ()) or field in SAMPLE_FIELDS.get(name, ()):
                continue
            fields.append(field)
            labels.append(facts.get('label'))
            described += 1 if facts.get('described') else 0
            helped += 1 if facts.get('helped') else 0
            required += 1 if facts.get('required') else 0
        if name in their_objects and entry.get('label'):
            labels.append(entry['label'])
    classes = [row['Name'] for row in listing.get('classes', []) if row.get('Name') and not is_ours(row['Name'], mine['apexClasses'] | mine['portalClasses']) and row['Name'] not in STOCK_CLASSES]
    tests = [name for name in classes if re.search(r'(?i)(^test|tests?$)', name)]
    working = [name for name in classes if name not in tests]
    triggers = {name: facts for name, facts in inventory.get('triggers', {}).items() if not is_ours(name, mine['apexTriggers'])}
    components = [row['DeveloperName'] for row in listing.get('components', []) if row.get('DeveloperName') and not is_ours(row['DeveloperName'], mine['lwc'])]
    auras = [row['DeveloperName'] for row in listing.get('auras', []) if row.get('DeveloperName') and not is_ours(row['DeveloperName'])]
    flows = [row['ApiName'] for row in listing.get('flows', []) if row.get('ApiName') and not row.get('NamespacePrefix') and row['ApiName'] not in mine['flows']]
    # Only sets an administrator made: the ones behind a permission set group or a session are Salesforce's own.
    sets = [row['Name'] for row in listing.get('sets', []) if row.get('Name') and not is_ours(row['Name'], mine['permissionSets']) and not re.match(r'^X?00e', row['Name'])
            and row.get('Type', 'Regular') == 'Regular' and not row['Name'].startswith('sfdc_')]
    apps = [name for name in inventory.get('apps', {}) if not is_ours(name, mine['apps']) and not name.startswith('standard__')]

    lines = []
    lines.append(observe('Custom object API names', [stem_of(name) for name in their_objects]))
    lines.append(observe('Custom field API names', [stem_of(name) for name in fields]))
    lines.append(observe('Labels', [label for label in labels if label], classify=label_style))
    lines.append(observe('Apex class names', working))
    lines.append(observe('Lightning web component names', components))
    if auras:
        lines.append(observe('Aura component names', auras))
    lines.append(observe('Flow API names', flows))
    lines.append(observe('Permission set API names', sets))
    lines.append(observe('App API names', apps))
    for line, names in zip(lines, ([stem_of(name) for name in their_objects], [stem_of(name) for name in fields], [], working, components) + ((auras,) if auras else ()) + (flows, sets, apps)):
        found = prefix_of(names)
        if found:
            line['prefix'] = {'text': found[0], 'matching': found[1], 'of': found[2], 'sure': how_sure(found[1], found[2])}

    # Tests: where "Test" goes in the name.
    if tests:
        test_styles = Counter('_Test at the end' if re.search(r'_Tests?$', name) else 'Test at the end' if re.search(r'Tests?$', name) else 'Test at the start' for name in tests)
        style, matching = test_styles.most_common(1)[0]
        lines.append({'what': 'Apex test class names', 'does': style, 'matching': matching, 'of': len(tests), 'sure': how_sure(matching, len(tests)),
                      'examples': [name for name in tests if (('_Test' in name[-6:]) == (style == '_Test at the end'))][:3], 'style': style})
    else:
        lines.append({'what': 'Apex test class names', 'does': 'No test classes of its own.', 'matching': 0, 'of': 0, 'sure': 'nothing to go on', 'examples': [], 'style': None})

    # Layers: the endings classes carry.
    endings = suffix_counts(working, ['TriggerHandler', 'Controller', 'Service', 'Selector', 'Handler', 'Helper', 'Utils', 'Util', 'Utility', 'Batch', 'Queueable',
                                      'Schedulable', 'Scheduler', 'Job', 'Domain', 'Wrapper', 'DTO', 'Exception', 'Factory', 'Callout', 'Client'])
    shown = ', '.join('%s (%d)' % (ending, count) for ending, count in endings.most_common(8))
    lines.append({'what': 'Apex class roles', 'does': shown or 'No endings that mark a role.', 'matching': sum(endings.values()), 'of': len(working),
                  'sure': how_sure(sum(endings.values()), len(working)) if working else 'nothing to go on', 'examples': [], 'style': None,
                  'roles': dict(endings)})

    # Triggers: one per object, and whether the logic lives in a handler.
    by_object = Counter(facts['object'] for facts in triggers.values() if facts.get('active') and facts.get('object'))
    crowded = sorted(name for name, count in by_object.items() if count > 1)
    framework = sorted(name for name in classes if re.search(r'(?i)^(fflib_|sfab_)|trigger(handler|dispatcher|factory|framework|base|manager|service|settings|context)|^(I)?TriggerHandler$|^Triggers?$', name)
                       and name not in tests)[:6]
    hands_off = [name for name, facts in triggers.items() if facts.get('handsOff') and facts.get('lines', 99) <= 25]
    if triggers:
        does = ('One trigger per object' if not crowded else 'More than one trigger on %s' % ', '.join(crowded[:4]))
        does += '; the logic is in handler classes' if len(hands_off) * 2 >= len(triggers) else '; the logic is in the trigger itself'
        if framework:
            does += '; a trigger framework is in use (%s)' % ', '.join(framework[:3])
        lines.append({'what': 'Triggers', 'does': does, 'matching': len(by_object) - len(crowded), 'of': len(by_object), 'sure': how_sure(len(by_object) - len(crowded), len(by_object)),
                      'examples': sorted(triggers)[:3], 'style': None, 'onePerObject': not crowded, 'handlers': len(hands_off), 'framework': framework})
        lines.append(observe('Trigger names', list(triggers)))
    else:
        lines.append({'what': 'Triggers', 'does': 'No triggers of its own.', 'matching': 0, 'of': 0, 'sure': 'nothing to go on', 'examples': [], 'style': None,
                      'onePerObject': None, 'handlers': 0, 'framework': framework})

    total = len(fields)
    lines.append({'what': 'Field descriptions', 'does': '%d of %d custom fields carry a description' % (described, total) if total else 'No custom fields of its own.',
                  'matching': described, 'of': total, 'sure': how_sure(max(described, total - described), total), 'examples': [], 'style': None})
    lines.append({'what': 'Field help text', 'does': '%d of %d custom fields carry help text' % (helped, total) if total else 'No custom fields of its own.',
                  'matching': helped, 'of': total, 'sure': how_sure(max(helped, total - helped), total), 'examples': [], 'style': None})
    groups = [row.get('DeveloperName') for row in listing.get('setGroups', []) if row.get('DeveloperName')]
    lines.append({'what': 'Permission set groups', 'does': 'In use: %s' % ', '.join(groups[:4]) if groups else 'Not used: access is given with single permission sets.',
                  'matching': len(groups), 'of': len(groups) + len(sets), 'sure': 'fairly sure' if groups else how_sure(len(sets), len(sets)), 'examples': groups[:3], 'style': None})
    api = {'Apex classes': versions(row.get('ApiVersion') for row in listing.get('classes', []) if row.get('Name') in set(classes)),
           'Triggers': versions(facts.get('apiVersion') for facts in triggers.values()),
           'Lightning web components': versions(row.get('ApiVersion') for row in listing.get('components', []) if row.get('DeveloperName') in set(components))}
    api = {name: text for name, text in api.items() if text}
    lines.append({'what': 'API versions in use', 'does': '; '.join('%s: %s' % (name, text) for name, text in api.items()) or 'Nothing of its own to read a version from.',
                  'matching': 0, 'of': len(classes) + len(triggers) + len(components), 'sure': 'sure' if api else 'nothing to go on', 'examples': [], 'style': None, 'versions': api})
    counts = {'customObjects': len(their_objects), 'customFields': total, 'requiredCustomFields': required, 'apexClasses': len(working), 'apexTestClasses': len(tests),
              'triggers': len(triggers), 'lightningWebComponents': len(components), 'auraComponents': len(auras), 'flows': len(flows), 'permissionSets': len(sets),
              'permissionSetGroups': len(groups), 'apps': len(apps)}
    return {'observations': lines, 'counts': counts, 'rules': RULES, 'notRead': sorted(listing.get('notRead', []))}


RULES = [
    'What Antsurance ships keeps its `Antsurance` and `antsurance` prefix. The prefix works as a namespace: nothing of the org\'s is overwritten, and everything of ours can be found and removed.',
    'Anything NEW built in this org, by a person or by Claude, follows this org\'s own conventions as observed below: its naming, its layering, its test naming, its use of descriptions and help text, its API version.',
    'Nothing of the org\'s is ever renamed, moved or restyled to fit ours.',
    'Where a line below says "a guess" or "nothing to go on", ask the person how they want it done before building, and do not invent a convention for them.',
]


def conventions_markdown(found, org_facts, pulled, when):
    lines = ['# How this org names and builds things', '',
             'Read from %s on %s. Nothing in the org was changed.' % (org_facts.get('name') or org_facts.get('alias'), when),
             'What Antsurance installed, managed packages and Salesforce\'s sample fields are left out of every count.', '']
    if pulled:
        lines += ['The metadata this was read from is in `%s` (%d files).' % (pulled.get('folder'), pulled.get('files', 0)), '']
    lines += ['## The rules', '']
    lines += ['%d. %s' % (number, rule) for number, rule in enumerate(found['rules'], 1)]
    lines += ['', 'Classes Salesforce adds by itself for sites and portals (`SiteLoginController` and the like) and its own apps (`standard__...`) are left out too.']
    lines += ['', '## What was observed', '', '| What | This org does | Seen in | How sure |', '|---|---|---|---|']
    for line in found['observations']:
        does = line['does']
        if line.get('examples') and line.get('style'):
            does += ' (%s)' % ', '.join('`%s`' % example for example in line['examples'])
        if line.get('prefix'):
            does += '. Prefix `%s` on %d of %d' % (line['prefix']['text'], line['prefix']['matching'], line['prefix']['of'])
        seen = '%d of %d' % (line['matching'], line['of']) if line['of'] and line.get('style') else str(line['of']) if line['of'] else 'none'
        lines.append('| %s | %s | %s | %s |' % (line['what'], does.replace('|', '/'), seen, line['sure']))
    counts = found['counts']
    lines += ['', '## What the org holds of its own', '',
              '%d custom objects, %d custom fields (%d required), %d Apex classes and %d test classes, %d triggers, %d Lightning web components, %d Aura components, %d flows, %d permission sets, %d permission set groups, %d apps.'
              % (counts['customObjects'], counts['customFields'], counts['requiredCustomFields'], counts['apexClasses'], counts['apexTestClasses'], counts['triggers'],
                 counts['lightningWebComponents'], counts['auraComponents'], counts['flows'], counts['permissionSets'], counts['permissionSetGroups'], counts['apps']), '']
    if not any(counts.values()):
        lines += ['The org has nothing of its own to read a convention from. Until it does, new work here can follow the kit\'s own style, and the person decides.', '']
    if found.get('notRead'):
        lines += ['Could not be read, so not counted above: %s.' % ', '.join(found['notRead']), '']
    return '\n'.join(lines) + '\n'


def write_conventions(found, org_facts, pulled, when):
    with open(os.path.join(KIT_ROOT, 'org-conventions.json'), 'w') as handle:
        json.dump(dict(found, org=org_facts.get('alias'), readOn=when), handle, indent=2, sort_keys=True)
    with open(os.path.join(KIT_ROOT, 'org-conventions.md'), 'w') as handle:
        handle.write(conventions_markdown(found, org_facts, pulled, when))
