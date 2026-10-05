#!/usr/bin/env python3
"""Reads a Salesforce source tree and works out what names what.

    python3 -I scripts/kit_scan.py                      scan force-app/main/default, print a summary
    python3 -I scripts/kit_scan.py --json out.json      also write the whole scan
    python3 -I scripts/kit_scan.py --why ApexClass:AntsuranceCaseAutomation     what one component names, and how

build_kit.py runs this over the built kit and writes the result to kit-scan.json, beside kit-manifest.json. The
installer and the person's Claude read that file: it is how a capability knows what it must bring with it, and how
describe_capability.py lists what has to be mapped onto an org's own data model.

What it reads, for every component under each root it is given:

  objects/         every object, field (with its type), record type, process, compact layout, list view, validation
                   rule; what each field points at, which value set it uses, what a formula names
  classes/         each class and what it names: other classes, objects, fields, record types (by name in a string),
                   pages, static resources, credentials, picklist values (as string literals)
  triggers/        the same, and the object each trigger is on
  lwc/, aura/      the Apex methods and the other components each one imports, the fields and objects it names
  flows/           the objects, fields, record types, Apex actions and components each flow names
  flexipages/, layouts/, quickActions/, tabs/, applications/, pathAssistants/, pages/, permissionsets/,
  reportTypes/, reports/, dashboards/, customMetadata/, namedCredentials/, and the rest: what each names

A component is "Type:Name" with the Metadata API's own type names (ApexClass:AntsuranceAiClient,
CustomField:Case.Policy__c, RecordType:Case.Claim). An edge says how one names another:

  hard   it does not deploy, compile or work without the other
  soft   it names the other in a string and looks it up at run time (Type.forName, a tab's name in a link); it
         deploys without it

A field named without its object (claim.Reserve_Amount__c in Apex) is matched to the objects that have a field of
that name and that the file also names. When more than one object fits, each gets an edge, marked "one of".

Python 3 standard library only.
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
BINARY = ('.jpg', '.jpeg', '.png', '.gif', '.pdf', '.woff', '.woff2', '.ttf', '.otf', '.ico', '.zip', '.asset', '.webp', '.mp4')
CUSTOM_NAME = re.compile(r'\b[A-Za-z][A-Za-z0-9_]*__(?:c|r|mdt|e)\b')
QUALIFIED = re.compile(r'\b([A-Za-z][A-Za-z0-9_]*)\.([A-Za-z][A-Za-z0-9_]*__c)\b')
# Standard objects a class or a flow may name. Used to say which objects a capability works on, and to place a field
# that is named without its object.
STANDARD_OBJECTS = ['Account', 'Contact', 'Lead', 'Case', 'Opportunity', 'Quote', 'Task', 'Event', 'User', 'Product2', 'Pricebook2', 'PricebookEntry',
                    'QuoteLineItem', 'OpportunityLineItem', 'OpportunityContactRole', 'ContentVersion', 'ContentDocument', 'ContentDocumentLink', 'ContentNote',
                    'EmailMessage', 'CaseComment', 'FeedItem', 'Group', 'GroupMember', 'Profile', 'PermissionSet', 'PermissionSetAssignment', 'RecordType',
                    'Organization', 'Network', 'Campaign', 'Contract', 'Order', 'Asset', 'Attachment', 'Note', 'CustomNotificationType', 'UserRole']
# Which standard value set a standard picklist field takes its values from.
STANDARD_VALUE_SETS = {('Case', 'Status'): 'CaseStatus', ('Case', 'Origin'): 'CaseOrigin', ('Case', 'Priority'): 'CasePriority', ('Case', 'Type'): 'CaseType',
                       ('Case', 'Reason'): 'CaseReason', ('Opportunity', 'StageName'): 'OpportunityStage', ('Opportunity', 'Type'): 'OpportunityType',
                       ('Quote', 'Status'): 'QuoteStatus', ('Lead', 'Status'): 'LeadStatus', ('Lead', 'LeadSource'): 'LeadSource', ('Task', 'Status'): 'TaskStatus',
                       ('Task', 'Priority'): 'TaskPriority', ('Account', 'Industry'): 'Industry', ('Account', 'Type'): 'AccountType'}

# folder -> (Metadata API type, suffix of the file that names a component, or None when the component is a folder)
SIMPLE = {
    'classes': ('ApexClass', '.cls'), 'triggers': ('ApexTrigger', '.trigger'), 'pages': ('ApexPage', '.page'), 'flows': ('Flow', '.flow-meta.xml'),
    'flexipages': ('FlexiPage', '.flexipage-meta.xml'), 'layouts': ('Layout', '.layout-meta.xml'), 'quickActions': ('QuickAction', '.quickAction-meta.xml'),
    'tabs': ('CustomTab', '.tab-meta.xml'), 'applications': ('CustomApplication', '.app-meta.xml'), 'pathAssistants': ('PathAssistant', '.pathAssistant-meta.xml'),
    'permissionsets': ('PermissionSet', '.permissionset-meta.xml'), 'customMetadata': ('CustomMetadata', '.md-meta.xml'),
    'namedCredentials': ('NamedCredential', '.namedCredential-meta.xml'), 'externalCredentials': ('ExternalCredential', '.externalCredential-meta.xml'),
    'groups': ('Group', '.group-meta.xml'), 'globalValueSets': ('GlobalValueSet', '.globalValueSet-meta.xml'),
    'standardValueSets': ('StandardValueSet', '.standardValueSet-meta.xml'), 'cspTrustedSites': ('CspTrustedSite', '.cspTrustedSite-meta.xml'),
    'remoteSiteSettings': ('RemoteSiteSetting', '.remoteSite-meta.xml'), 'notificationtypes': ('CustomNotificationType', '.notiftype-meta.xml'),
    'customPermissions': ('CustomPermission', '.customPermission-meta.xml'), 'contentassets': ('ContentAsset', '.asset-meta.xml'),
    'reportTypes': ('ReportType', '.reportType-meta.xml'), 'staticresources': ('StaticResource', '.resource-meta.xml'),
    'networks': ('Network', '.network-meta.xml'), 'sites': ('CustomSite', '.site-meta.xml'), 'profiles': ('Profile', '.profile-meta.xml'),
    'platformEventSubscriberConfigs': ('PlatformEventSubscriberConfig', '.platformEventSubscriberConfig-meta.xml'),
    'digitalExperienceConfigs': ('DigitalExperienceConfig', '.digitalExperienceConfig-meta.xml'), 'settings': ('Settings', '.settings-meta.xml'),
    'lightningExperienceThemes': ('LightningExperienceTheme', '.lightningExperienceTheme-meta.xml'), 'brandingSets': ('BrandingSet', '.brandingSet-meta.xml'),
    'objectTranslations': ('CustomObjectTranslation', None),
}
OBJECT_PARTS = {'fields': ('CustomField', '.field-meta.xml'), 'recordTypes': ('RecordType', '.recordType-meta.xml'),
                'businessProcesses': ('BusinessProcess', '.businessProcess-meta.xml'), 'compactLayouts': ('CompactLayout', '.compactLayout-meta.xml'),
                'listViews': ('ListView', '.listView-meta.xml'), 'validationRules': ('ValidationRule', '.validationRule-meta.xml'),
                'webLinks': ('WebLink', '.webLink-meta.xml')}


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def is_binary(path):
    return path.lower().endswith(BINARY)


def code_and_strings(text):
    """Apex or JavaScript with its comments taken out: (the code with string contents blanked, the string contents)."""
    code, strings, position = [], [], 0
    for match in re.finditer(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\\n])*'", text, re.S):
        code.append(text[position:match.start()])
        position = match.end()
        if match.group(0).startswith("'"):
            strings.append(match.group(0)[1:-1])
            code.append("''")
    code.append(text[position:])
    return ''.join(code), strings


def tags(text, name):
    return [value.strip() for value in re.findall(r'<%s>([^<]*)</%s>' % (name, name), text)]


def first(text, name, default=None):
    found = tags(text, name)
    return found[0] if found else default


class Scan:
    def __init__(self):
        self.nodes = {}        # id -> {'type', 'name', 'bucket', 'files': [paths under the bucket's root]}
        self.edges = {}        # id -> {target id -> {'how': 'hard'|'soft', 'via': words, 'oneOf': n}}
        self.standard = {}     # id -> sorted standard objects it names
        self.values = {}       # id -> {'Object.Field': [picklist values it names as string literals]}
        self.unknown = {}      # id -> custom names it uses that nothing in the tree defines
        self.objects = {}      # object -> {'custom', 'kind', 'label', 'fields': {name: {...}}, 'recordTypes': {...}}
        self.value_sets = {}   # global or standard value set -> [values]
        self.relationships = {}    # Something__r -> set of objects it leads to
        self.field_owners = {}     # Field__c -> set of objects that have it
        self.texts = {}        # id -> [(file, text)], dropped before the result is written

    # ------------------------------------------------------------ pass 1: what exists

    def add(self, kind, name, bucket, path):
        node = '%s:%s' % (kind, name)
        entry = self.nodes.setdefault(node, {'type': kind, 'name': name, 'bucket': bucket, 'files': []})
        if entry['bucket'] != bucket:
            # A later folder carries its own copy of something an earlier one has (the portal's fuller permission set).
            entry['alsoIn'] = sorted(set(entry.get('alsoIn', [])) | {bucket})
            return None
        if path not in entry['files']:
            entry['files'].append(path)
        return node

    def collect(self, bucket, root):
        for folder in sorted(os.listdir(root)) if os.path.isdir(root) else []:
            base = os.path.join(root, folder)
            if not os.path.isdir(base):
                continue
            if folder == 'objects':
                self.collect_objects(bucket, root, base)
            elif folder in ('lwc', 'aura'):
                kind = 'LightningComponentBundle' if folder == 'lwc' else 'AuraDefinitionBundle'
                for name in sorted(os.listdir(base)):
                    if os.path.isdir(os.path.join(base, name)):
                        node = None
                        for sub, _, files in os.walk(os.path.join(base, name)):
                            if '__tests__' in sub:
                                continue
                            for file_name in sorted(files):
                                if file_name != '.DS_Store':
                                    node = self.add(kind, name, bucket, os.path.relpath(os.path.join(sub, file_name), root))
                                    self.keep(node, os.path.join(sub, file_name), root)
            elif folder in ('reports', 'dashboards'):
                kind = 'Report' if folder == 'reports' else 'Dashboard'
                for name in sorted(os.listdir(base)):
                    path = os.path.join(base, name)
                    if os.path.isdir(path):
                        for file_name in sorted(os.listdir(path)):
                            if file_name.endswith('-meta.xml'):
                                node = self.add(kind, '%s/%s' % (name, file_name.split('.')[0]), bucket, os.path.relpath(os.path.join(path, file_name), root))
                                self.keep(node, os.path.join(path, file_name), root)
                    elif name.endswith('Folder-meta.xml'):
                        node = self.add(kind + 'Folder', name.split('.')[0], bucket, os.path.relpath(path, root))
                        self.keep(node, path, root)
            elif folder == 'digitalExperiences':
                for kind_folder in sorted(os.listdir(base)):
                    for name in sorted(os.listdir(os.path.join(base, kind_folder))) if os.path.isdir(os.path.join(base, kind_folder)) else []:
                        for sub, _, files in os.walk(os.path.join(base, kind_folder, name)):
                            for file_name in sorted(files):
                                if file_name != '.DS_Store':
                                    node = self.add('DigitalExperienceBundle', '%s/%s' % (kind_folder, name), bucket, os.path.relpath(os.path.join(sub, file_name), root))
                                    self.keep(node, os.path.join(sub, file_name), root)
            elif folder in SIMPLE:
                kind, suffix = SIMPLE[folder]
                for name in sorted(os.listdir(base)):
                    path = os.path.join(base, name)
                    if name == '.DS_Store':
                        continue
                    if folder == 'staticresources':
                        # One resource is a meta file and, beside it, one file of any type or a folder.
                        stem = name[:-len(suffix)] if name.endswith(suffix) else name.split('.')[0]
                        if os.path.isdir(path):
                            for sub, _, files in os.walk(path):
                                for file_name in sorted(files):
                                    if file_name != '.DS_Store':
                                        self.add(kind, stem, bucket, os.path.relpath(os.path.join(sub, file_name), root))
                        else:
                            self.add(kind, stem, bucket, os.path.relpath(path, root))
                        continue
                    if os.path.isdir(path):
                        for sub, _, files in os.walk(path):
                            for file_name in sorted(files):
                                if file_name != '.DS_Store':
                                    node = self.add(kind, name, bucket, os.path.relpath(os.path.join(sub, file_name), root))
                                    self.keep(node, os.path.join(sub, file_name), root)
                        continue
                    if suffix and name.endswith(suffix):
                        stem = name[:-len(suffix)]
                    elif suffix and name.endswith(suffix + '-meta.xml'):
                        stem = name[:-len(suffix + '-meta.xml')]
                    elif folder == 'contentassets':
                        stem = name.split('.')[0]
                    else:
                        continue
                    node = self.add(kind, stem, bucket, os.path.relpath(path, root))
                    self.keep(node, path, root)

    def keep(self, node, path, root):
        if node is None or is_binary(path):
            return
        try:
            self.texts.setdefault(node, []).append((os.path.relpath(path, root), read(path)))
        except UnicodeDecodeError:
            pass

    def collect_objects(self, bucket, root, base):
        for name in sorted(os.listdir(base)):
            folder = os.path.join(base, name)
            if not os.path.isdir(folder):
                continue
            custom = '__' in name
            entry = self.objects.setdefault(name, {'custom': custom, 'kind': 'standard', 'label': name, 'fields': {}, 'recordTypes': {}, 'bucket': bucket})
            meta = os.path.join(folder, name + '.object-meta.xml')
            if os.path.exists(meta):
                text = read(meta)
                if custom:
                    node = self.add('CustomObject', name, bucket, os.path.relpath(meta, root))
                    self.keep(node, meta, root)
                    entry['label'] = first(text, 'label', name)
                    entry['kind'] = ('setting' if '<customSettingsType>' in text else 'metadata type' if name.endswith('__mdt')
                                     else 'platform event' if name.endswith('__e') else 'object')
                    entry['sharing'] = first(text, 'sharingModel')
                    entry['bucket'] = bucket
                else:
                    # What a kit says about a standard object itself (its search layouts, its renamed label).
                    node = self.add('StandardObjectSettings', name, bucket, os.path.relpath(meta, root))
                    self.keep(node, meta, root)
            for part, (kind, suffix) in OBJECT_PARTS.items():
                sub = os.path.join(folder, part)
                for file_name in sorted(os.listdir(sub)) if os.path.isdir(sub) else []:
                    if not file_name.endswith(suffix):
                        continue
                    one = file_name[:-len(suffix)]
                    path = os.path.join(sub, file_name)
                    node = self.add(kind, '%s.%s' % (name, one), bucket, os.path.relpath(path, root))
                    self.keep(node, path, root)
                    text = read(path)
                    if kind == 'CustomField':
                        self.note_field(name, one, text)
                    elif kind == 'RecordType':
                        entry['recordTypes'][one] = {'label': first(text, 'label', one), 'businessProcess': first(text, 'businessProcess')}

    def note_field(self, obj, name, text):
        kind = first(text, 'type', 'Unknown')
        field = {'type': kind, 'label': first(text, 'label', name)}
        if first(text, 'required') == 'true' or kind == 'MasterDetail':
            field['required'] = True
        if '<formula>' in text:
            field['formula'] = True
        target = first(text, 'referenceTo')
        if target:
            field['referenceTo'] = target
            self.relationships.setdefault(re.sub(r'__c$', '__r', name), set()).add(target)
            child = first(text, 'relationshipName')
            if child:
                field['relationshipName'] = child
                # A child relationship is read from the parent: SELECT (SELECT ... FROM Coverages__r) FROM Policy__c.
                self.relationships.setdefault(child + '__r', set()).add(obj)
                self.child_fields.setdefault(child + '__r', set()).add('CustomField:%s.%s' % (obj, name))
        if kind == 'Summary':
            field['summarizes'] = first(text, 'summarizedField') or first(text, 'summaryForeignKey')
        value_set = first(text, 'valueSetName')
        if value_set:
            field['valueSet'] = value_set
        values = re.findall(r'<value>\s*<fullName>([^<]*)</fullName>', text)
        if values:
            field['values'] = [html_unescape(value) for value in values]
        for key in ('length', 'precision', 'scale'):
            if first(text, key):
                field[key] = int(first(text, key))
        self.objects[obj]['fields'][name] = field
        self.field_owners.setdefault(name, set()).add(obj)

    child_fields = {}

    def collect_value_sets(self):
        for node, entry in self.nodes.items():
            if entry['type'] in ('GlobalValueSet', 'StandardValueSet'):
                text = self.texts.get(node, [('', '')])[0][1]
                found = re.findall(r'<(?:customValue|standardValue)>\s*<fullName>([^<]*)</fullName>', text)
                self.value_sets[entry['name']] = [html_unescape(value) for value in found]

    # ------------------------------------------------------------ pass 2: what names what

    def edge(self, source, target, how='hard', via='', one_of=0):
        if target == source or target not in self.nodes:
            return False
        known = self.edges.setdefault(source, {}).get(target)
        if known and (known['how'] == 'hard' or how == 'soft'):
            return True
        entry = {'how': how}
        if via:
            entry['via'] = via
        if one_of > 1:
            entry['oneOf'] = one_of
        self.edges[source][target] = entry
        return True

    def names_of(self, kind):
        return sorted(entry['name'] for entry in self.nodes.values() if entry['type'] == kind)

    def prepare(self):
        self.classes = set(self.names_of('ApexClass'))
        self.bundles = set(self.names_of('LightningComponentBundle'))
        self.resources = set(self.names_of('StaticResource'))
        self.class_pattern = re.compile(r'\b(%s)\b' % '|'.join(sorted(map(re.escape, self.classes), key=len, reverse=True))) if self.classes else None
        self.record_types = {}
        for obj, entry in self.objects.items():
            for name in entry['recordTypes']:
                self.record_types.setdefault(name, set()).add(obj)
        self.by_string = {}
        for kind in ('StaticResource', 'CustomTab', 'Flow', 'CustomPermission', 'CustomNotificationType', 'Group', 'ApexPage', 'NamedCredential', 'QuickAction', 'CustomApplication', 'PermissionSet'):
            for name in self.names_of(kind):
                # An object's tab has the object's name: a string holding that name means the object, not the tab.
                if not (kind == 'CustomTab' and '__' in name):
                    self.by_string.setdefault(name, []).append(kind)

    def objects_named(self, text):
        found = {name for name in self.objects if re.search(r'\b%s\b' % re.escape(name), text)}
        found |= {name for name in STANDARD_OBJECTS if re.search(r'\b%s\b' % name, text)}
        return found

    def model_edges(self, source, text, how='hard', context=None, via='names'):
        """Edges for every custom object and field a text names. `context` is the objects a bare field name may belong to."""
        placed = set()
        named = set(context or ()) | self.objects_named(text)
        home = self.nodes[source]['bucket']

        def nearest(owners):
            # Of the objects a bare field name could belong to: the ones this file names, and of those the ones that
            # ship in the same part of the kit as the file itself.
            fits = (owners & named) or owners
            return {obj for obj in fits if self.objects[obj].get('bucket') == home} or fits
        for left, field in QUALIFIED.findall(text):
            owners = set()
            if left in self.objects and field in self.objects[left]['fields']:
                owners = {left}
            elif left in self.relationships:
                owners = {obj for obj in self.relationships[left] if field in self.objects.get(obj, {}).get('fields', {})}
            for obj in owners:
                self.edge(source, 'CustomField:%s.%s' % (obj, field), how, via)
            if owners:
                placed.add((left, field))
        qualified_fields = {field for _, field in placed}
        unknown = set()
        for name in sorted(set(CUSTOM_NAME.findall(text))):
            if name in self.objects:
                if self.objects[name]['custom']:
                    self.edge(source, 'CustomObject:' + name, how, via)
                # The same word can be a field as well: Policy__c is our object, and Case.Policy__c is a claim's
                # policy. Where the text also names an object that has such a field, it may mean the field, so the
                # field is recorded too, as one of several things the word could be.
                also = sorted(obj for obj in self.field_owners.get(name, set()) & named if obj != name)
                for obj in also:
                    self.edge(source, 'CustomField:%s.%s' % (obj, name), how, via, len(also) + 1)
                continue
            if name.endswith('__r'):
                as_field = re.sub(r'__r$', '__c', name)
                owners = self.field_owners.get(as_field, set())
                fits = nearest(owners)
                for obj in fits:
                    self.edge(source, 'CustomField:%s.%s' % (obj, as_field), how, via, len(fits))
                for child in self.child_fields.get(name, ()):
                    self.edge(source, child, how, via + ' (child relationship)')
                if not owners and name not in self.child_fields:
                    unknown.add(name)
                continue
            owners = self.field_owners.get(name, set())
            if not owners:
                if 'ReportType:' + name[:-3] not in self.nodes:
                    unknown.add(name)
                continue
            if name in qualified_fields and not re.search(r'(?<![\w.])%s\b' % re.escape(name), text):
                continue
            fits = nearest(owners)
            for obj in fits:
                self.edge(source, 'CustomField:%s.%s' % (obj, name), how, via, len(fits))
        if unknown:
            self.unknown.setdefault(source, set()).update(unknown)
        standard = {name for name in named if name in STANDARD_OBJECTS or (name in self.objects and not self.objects[name]['custom'])}
        if standard:
            self.standard.setdefault(source, set()).update(standard)

    def string_edges(self, source, strings, text):
        """What a piece of code names in its string literals: record types, pages, tabs, flows, resources, values."""
        whole = set(strings)
        if re.search(r'RecordType|recordType', text):
            for name in sorted(whole & set(self.record_types)):
                for obj in self.record_types[name]:
                    self.edge(source, 'RecordType:%s.%s' % (obj, name), 'hard', 'record type by name in a string')
        for value in sorted(whole):
            for kind in self.by_string.get(value, []):
                self.edge(source, '%s:%s' % (kind, value), 'soft', 'named in a string')
            match = re.match(r'callout:(\w+)', value)
            if match:
                self.edge(source, 'NamedCredential:' + match.group(1), 'hard', 'callout')
            match = re.match(r'/apex/(\w+)', value)
            if match:
                self.edge(source, 'ApexPage:' + match.group(1), 'hard', 'page address')
        quoted = '\n'.join(strings)
        if self.class_pattern:
            for name in set(self.class_pattern.findall(quoted)):
                self.edge(source, 'ApexClass:' + name, 'soft', 'class named in a string')
        self.model_edges(source, quoted, 'hard', context=self.objects_named(text), via='named in a string or a query')
        # Picklist values this code names, for the fields it names. This is what a mapping of values has to cover.
        for target in list(self.edges.get(source, {})):
            if target.startswith('CustomField:'):
                obj, field = target[len('CustomField:'):].split('.')
                named = sorted(whole & set(self.values_of(obj, field)))
                if named:
                    self.values.setdefault(source, {})['%s.%s' % (obj, field)] = named
        for (obj, field), value_set in STANDARD_VALUE_SETS.items():
            if obj in self.standard.get(source, ()) and value_set in self.value_sets:
                named = sorted(whole & set(self.value_sets[value_set]))
                if named and re.search(r'\b%s\b' % field, text):
                    self.values.setdefault(source, {})['%s.%s' % (obj, field)] = named

    def values_of(self, obj, field):
        entry = self.objects.get(obj, {}).get('fields', {}).get(field, {})
        if entry.get('valueSet'):
            return self.value_sets.get(entry['valueSet'], [])
        return entry.get('values', [])

    def scan_apex(self, node, text, trigger=False):
        code, strings = code_and_strings(text)
        if self.class_pattern:
            for name in set(self.class_pattern.findall(code)):
                self.edge(node, 'ApexClass:' + name, 'hard', 'uses the class')
        for page in re.findall(r'\bPage\.(\w+)', code):
            self.edge(node, 'ApexPage:' + page, 'hard', 'Page.' + page)
        context = set()
        if trigger:
            on = re.search(r'\btrigger\s+\w+\s+on\s+(\w+)', code)
            if on:
                context.add(on.group(1))
                self.nodes[node]['object'] = on.group(1)
                if on.group(1) in self.objects and self.objects[on.group(1)]['custom']:
                    self.edge(node, 'CustomObject:' + on.group(1), 'hard', 'the trigger is on it')
                else:
                    self.standard.setdefault(node, set()).add(on.group(1))
        self.model_edges(node, code, 'hard', context=context, via='names it in code')
        self.string_edges(node, strings, code + '\n' + '\n'.join(strings))
        if re.search(r'@IsTest', text, re.I) and not trigger:
            self.nodes[node]['test'] = bool(re.search(r'@IsTest\s*(\([^)]*\))?\s*(private|public|global)?\s*(with sharing|without sharing|inherited sharing)?\s*class', text, re.I))
        methods = re.findall(r'@AuraEnabled[^;{]*?\b(\w+)\s*\(', text, re.S)
        if methods:
            self.nodes[node]['auraEnabled'] = sorted(set(methods))
        if re.search(r'@Invocable(Method|Variable)', text):
            self.nodes[node]['invocable'] = True
        parent = re.search(r'\bclass\s+\w+\s+extends\s+(\w+)', code)
        if parent:
            self.nodes[node]['extends'] = parent.group(1)

    def scan_bundle(self, node, files):
        methods = set()
        for path, text in files:
            for other in re.findall(r"""['"]c/(\w+)['"]""", text):
                self.edge(node, 'LightningComponentBundle:' + other, 'hard', 'imports it')
            if path.endswith(('.html', '.cmp')):
                for tag in re.findall(r'<c-([a-z0-9-]+)', text):
                    self.edge(node, 'LightningComponentBundle:' + re.sub(r'-(\w)', lambda m: m.group(1).upper(), tag), 'hard', 'child component')
                for other in re.findall(r'<c:(\w+)', text):
                    self.edge(node, 'LightningComponentBundle:' + other, 'hard', 'child component')
                for flow in re.findall(r'flow-api-name="(\w+)"', text):
                    self.edge(node, 'Flow:' + flow, 'hard', 'runs the flow')
            for apex, method in re.findall(r'@salesforce/apex/(\w+)\.(\w+)', text):
                self.edge(node, 'ApexClass:' + apex, 'hard', 'calls its methods')
                methods.add('%s.%s' % (apex, method))
            for controller in re.findall(r'controller="(\w+)"', text):
                self.edge(node, 'ApexClass:' + controller, 'hard', 'controller')
            for obj, field in re.findall(r'@salesforce/schema/(\w+)(?:\.(\w+))?', text):
                if field and field in self.objects.get(obj, {}).get('fields', {}):
                    self.edge(node, 'CustomField:%s.%s' % (obj, field), 'hard', 'schema import')
                elif obj in self.objects and self.objects[obj]['custom']:
                    self.edge(node, 'CustomObject:' + obj, 'hard', 'schema import')
            for resource in re.findall(r'@salesforce/resourceUrl/(\w+)', text) + re.findall(r'\$Resource\.(\w+)', text):
                self.edge(node, 'StaticResource:' + resource, 'hard', 'loads it')
            for asset in re.findall(r'@salesforce/contentAssetUrl/(\w+)', text):
                self.edge(node, 'ContentAsset:' + asset, 'hard', 'loads it')
            for permission in re.findall(r'@salesforce/customPermission/(\w+)', text):
                self.edge(node, 'CustomPermission:' + permission, 'hard', 'checks it')
            if path.endswith('.js'):
                code, strings = code_and_strings(text)
                doubles = re.findall(r'"((?:\\.|[^"\\\n])*)"', code)
                self.model_edges(node, code, 'hard', via='names it in code')
                self.string_edges(node, strings + doubles, text)
            elif path.endswith(('.html', '.cmp', '.xml', '.design')):
                self.model_edges(node, text, 'hard', via='names it in markup')
                for obj in tags(text, 'object'):
                    if obj in self.objects and self.objects[obj]['custom']:
                        self.edge(node, 'CustomObject:' + obj, 'hard', 'offered on its pages')
        if methods:
            self.nodes[node]['apexMethods'] = sorted(methods)

    def component(self, node, value, via):
        name = value[2:] if value.startswith('c:') else value
        if ':' in name:
            return
        if not self.edge(node, 'LightningComponentBundle:' + name, 'hard', via):
            self.edge(node, 'AuraDefinitionBundle:' + name, 'hard', via)

    def action(self, node, value, obj, via):
        """A quick action named on a page or a layout: Case.Record_Payment, or Record_Payment on the page's own object."""
        for name in ([value] if '.' in value else ['%s.%s' % (obj, value), value]):
            if self.edge(node, 'QuickAction:' + name, 'hard', via):
                return

    def scan_xml(self, node, entry, text):
        kind, name = entry['type'], entry['name']
        # Words written for people (a description, help text, a comment) name things without needing them.
        text = re.sub(r'<(description|inlineHelpText|helpText|comment|info|label|masterLabel|errorMessage|fieldText|pausedText|relationshipLabel|pluralLabel)>.*?</\1>', '', text, flags=re.S)
        # Every kind of file: the classes and the model it names.
        if self.class_pattern and kind not in ('PermissionSet', 'Profile'):
            for found in set(self.class_pattern.findall(text)):
                self.edge(node, 'ApexClass:' + found, 'hard', 'names the class')
        # A file kept in the org and shown by its address, as a theme shows its logo.
        for asset in set(re.findall(r'/file-asset/(\w+)', text)):
            self.edge(node, 'ContentAsset:' + asset, 'hard', 'shows the file')
        context = set()
        if kind in ('CustomField', 'RecordType', 'BusinessProcess', 'CompactLayout', 'ListView', 'ValidationRule', 'WebLink'):
            obj, one = name.split('.', 1)
            context.add(obj)
            if self.objects[obj]['custom']:
                self.edge(node, 'CustomObject:' + obj, 'hard', 'belongs to it')
            else:
                self.standard.setdefault(node, set()).add(obj)
            if kind == 'CustomField':
                field = self.objects[obj]['fields'][one]
                target = field.get('referenceTo')
                if target and target in self.objects and self.objects[target]['custom']:
                    self.edge(node, 'CustomObject:' + target, 'hard', 'points at it')
                elif target:
                    self.standard.setdefault(node, set()).add(target)
                if field.get('valueSet'):
                    self.edge(node, 'GlobalValueSet:' + field['valueSet'], 'hard', 'takes its values from it')
                for summed in tags(text, 'summarizedField') + tags(text, 'summaryForeignKey'):
                    if '.' in summed:
                        self.edge(node, 'CustomField:' + summed, 'hard', 'sums it up')
                        self.edge(node, 'CustomObject:' + summed.split('.')[0], 'hard', 'sums its records')
            if kind == 'RecordType':
                process = first(text, 'businessProcess')
                if process:
                    self.edge(node, 'BusinessProcess:%s.%s' % (obj, process), 'hard', 'its process')
                layout = first(text, 'compactLayoutAssignment')
                if layout:
                    self.edge(node, 'CompactLayout:%s.%s' % (obj, layout), 'hard', 'its compact layout')
                for picklist in tags(text, 'picklist'):
                    if not self.edge(node, 'CustomField:%s.%s' % (obj, picklist), 'hard', 'offers its values'):
                        self.value_set_edge(node, obj, picklist)
            if kind == 'BusinessProcess':
                for (owner, field), value_set in STANDARD_VALUE_SETS.items():
                    if owner == obj and field in ('Status', 'StageName'):
                        self.edge(node, 'StandardValueSet:' + value_set, 'hard', 'offers its values')
            if kind == 'ListView':
                for group in tags(text, 'group'):
                    self.edge(node, 'Group:' + group, 'hard', 'shared with the group')
                for value in tags(text, 'value'):
                    for part in value.split(','):
                        self.edge(node, 'RecordType:' + part.strip(), 'hard', 'filters on the record type')
                for column in tags(text, 'columns') + tags(text, 'field'):
                    self.edge(node, 'CustomField:%s.%s' % (obj, column), 'hard', 'shows the field')
            if kind == 'CompactLayout':
                for field in tags(text, 'fields'):
                    self.edge(node, 'CustomField:%s.%s' % (obj, field), 'hard', 'shows the field')
        elif kind in ('CustomObject', 'StandardObjectSettings'):
            context.add(name)
            layout = first(text, 'compactLayoutAssignment')
            if layout and layout != 'SYSTEM':
                self.edge(node, 'CompactLayout:%s.%s' % (name, layout), 'hard', 'its compact layout')
            for content in tags(text, 'content'):
                self.edge(node, 'FlexiPage:' + content, 'hard', 'its page override')
            for field in re.findall(r'<\w*AdditionalFields>([^<]+)<', text):
                self.edge(node, 'CustomField:%s.%s' % (name, field), 'hard', 'in its search layout')
        elif kind == 'CustomMetadata':
            owner = name.split('.')[0] + '__mdt'
            context.add(owner)
            self.edge(node, 'CustomObject:' + owner, 'hard', 'a record of it')
            for field in tags(text, 'field'):
                self.edge(node, 'CustomField:%s.%s' % (owner, field), 'hard', 'sets the field')
        elif kind == 'Flow':
            for obj in tags(text, 'object') + tags(text, 'objectType'):
                context.add(obj)
                if obj in self.objects and self.objects[obj]['custom']:
                    self.edge(node, 'CustomObject:' + obj, 'hard', 'reads or saves its records')
            for block in re.findall(r'<actionCalls>.*?</actionCalls>', text, re.S):
                action, action_type = first(block, 'actionName'), first(block, 'actionType')
                if action_type == 'apex':
                    self.edge(node, 'ApexClass:' + action, 'hard', 'Apex action')
                elif action_type == 'quickAction':
                    self.edge(node, 'QuickAction:' + action, 'hard', 'quick action')
                elif action_type == 'flow':
                    self.edge(node, 'Flow:' + action, 'hard', 'subflow')
            for other in tags(text, 'flowName'):
                self.edge(node, 'Flow:' + other, 'hard', 'subflow')
            for component in tags(text, 'extensionName'):
                self.component(node, component, 'screen component')
            self.nodes[node]['processType'] = first(text, 'processType')
            start = re.search(r'<start>.*?</start>', text, re.S)
            if start and first(start.group(0), 'object'):
                self.nodes[node]['object'] = first(start.group(0), 'object')
                self.nodes[node]['trigger'] = first(start.group(0), 'recordTriggerType') or first(start.group(0), 'triggerType')
            for field in tags(text, 'field') + tags(text, 'queriedFields') + tags(text, 'sortField'):
                self.model_edges(node, field, 'hard', context=context, via='names the field')
            if 'RecordType' in text:
                for value in set(tags(text, 'stringValue')) & set(self.record_types):
                    for obj in self.record_types[value]:
                        self.edge(node, 'RecordType:%s.%s' % (obj, value), 'hard', 'record type by name')
            literal = set(tags(text, 'stringValue'))
            for target in list(self.edges.get(node, {})):
                if target.startswith('CustomField:'):
                    obj, field = target[len('CustomField:'):].split('.')
                    named = sorted(literal & set(self.values_of(obj, field)))
                    if named:
                        self.values.setdefault(node, {})['%s.%s' % (obj, field)] = named
            for (obj, field), value_set in STANDARD_VALUE_SETS.items():
                if obj in context and value_set in self.value_sets and '<field>%s</field>' % field in text:
                    named = sorted(literal & set(self.value_sets[value_set]))
                    if named:
                        self.values.setdefault(node, {})['%s.%s' % (obj, field)] = named
        elif kind == 'FlexiPage':
            obj = first(text, 'sobjectType')
            if obj:
                context.add(obj)
                self.nodes[node]['object'] = obj
                if obj in self.objects and self.objects[obj]['custom']:
                    self.edge(node, 'CustomObject:' + obj, 'hard', 'the page is for it')
            for component in tags(text, 'componentName'):
                self.component(node, component, 'holds the component')
            for value in tags(text, 'value'):
                if re.fullmatch(r'[A-Za-z_]\w*(\.\w+)?', value):
                    self.action(node, value, obj, 'offers the action')
                    if value in self.nodes.get('Flow:' + value, {}).get('name', ''):
                        self.edge(node, 'Flow:' + value, 'hard', 'runs the flow')
            for item in tags(text, 'fieldItem'):
                field = item.split('.')[-1]
                if obj:
                    self.edge(node, 'CustomField:%s.%s' % (obj, field), 'hard', 'shows the field')
            template = first(text, 'name', '')
            for block in re.findall(r'<template>.*?</template>', text, re.S):
                self.component(node, first(block, 'name', ''), 'its template')
            parent = first(text, 'parentFlexiPage')
            if parent:
                self.edge(node, 'FlexiPage:' + parent, 'hard', 'its parent page')
            del template
        elif kind == 'Layout':
            obj = name.split('-')[0]
            context.add(obj)
            self.nodes[node]['object'] = obj
            if obj in self.objects and self.objects[obj]['custom']:
                self.edge(node, 'CustomObject:' + obj, 'hard', 'the layout is for it')
            for field in tags(text, 'field'):
                self.edge(node, 'CustomField:%s.%s' % (obj, field), 'hard', 'shows the field')
            for action in tags(text, 'quickActionName') + tags(text, 'actionName'):
                self.action(node, action, obj, 'offers the action')
            for related in tags(text, 'relatedList'):
                if '.' in related:
                    self.edge(node, 'CustomField:' + related, 'hard', 'related list')
                    self.edge(node, 'CustomObject:' + related.split('.')[0], 'hard', 'related list')
            for column in tags(text, 'fields'):
                if '.' in column:
                    self.edge(node, 'CustomField:' + column, 'hard', 'related list column')
        elif kind == 'QuickAction':
            obj = name.split('.')[0] if '.' in name else None
            if obj:
                context.add(obj)
                self.nodes[node]['object'] = obj
                if obj in self.objects and self.objects[obj]['custom']:
                    self.edge(node, 'CustomObject:' + obj, 'hard', 'the action is on it')
            flow = first(text, 'flowDefinition')
            if flow:
                self.edge(node, 'Flow:' + flow, 'hard', 'runs the flow')
            component = first(text, 'lightningWebComponent')
            if component:
                self.component(node, component, 'opens the component')
            target = first(text, 'targetObject')
            if target:
                context.add(target)
                if target in self.objects and self.objects[target]['custom']:
                    self.edge(node, 'CustomObject:' + target, 'hard', 'creates one')
            record_type = first(text, 'targetRecordType')
            if record_type:
                self.edge(node, 'RecordType:' + record_type, 'hard', 'creates one of that record type')
            for field in tags(text, 'field'):
                for owner in ([target] if target else []) + ([obj] if obj else []):
                    self.edge(node, 'CustomField:%s.%s' % (owner, field), 'hard', 'sets the field')
        elif kind == 'CustomTab':
            if '__' in name:
                self.edge(node, 'CustomObject:' + name, 'hard', 'the tab of the object')
            for tag, target in (('lwcComponent', 'LightningComponentBundle'), ('flexiPage', 'FlexiPage'), ('page', 'ApexPage'), ('auraComponent', 'AuraDefinitionBundle')):
                for value in tags(text, tag):
                    self.edge(node, '%s:%s' % (target, value), 'hard', 'shows it')
        elif kind == 'CustomApplication':
            for tab in tags(text, 'tabs'):
                self.edge(node, 'CustomTab:' + tab, 'hard', 'lists the tab')
            for page in tags(text, 'utilityBar') + tags(text, 'content'):
                self.edge(node, 'FlexiPage:' + page, 'hard', 'uses the page')
            for record_type in tags(text, 'recordType'):
                self.edge(node, 'RecordType:' + record_type, 'hard', 'assigns a page by record type')
            for obj in tags(text, 'pageOrSobjectType'):
                if obj in self.objects and self.objects[obj]['custom']:
                    self.edge(node, 'CustomObject:' + obj, 'hard', 'assigns its record page')
                elif obj in self.objects or obj in STANDARD_OBJECTS:
                    self.standard.setdefault(node, set()).add(obj)
            for logo in tags(text, 'logo'):
                self.edge(node, 'ContentAsset:' + logo, 'hard', 'its logo')
            self.nodes[node]['profiles'] = sorted(set(tags(text, 'profile')))
        elif kind == 'PathAssistant':
            obj = first(text, 'entityName')
            context.add(obj)
            self.nodes[node]['object'] = obj
            if obj in self.objects and self.objects[obj]['custom']:
                self.edge(node, 'CustomObject:' + obj, 'hard', 'the path is on it')
            record_type = first(text, 'recordTypeName')
            if record_type and record_type != '__MASTER__':
                self.edge(node, 'RecordType:%s.%s' % (obj, record_type), 'hard', 'the path is for it')
            for field in tags(text, 'fieldName') + tags(text, 'fieldNames'):
                if not self.edge(node, 'CustomField:%s.%s' % (obj, field), 'hard', 'shows the field'):
                    self.value_set_edge(node, obj, field)
            steps = tags(text, 'picklistValueName')
            if steps:
                self.values.setdefault(node, {})['%s.%s' % (obj, first(text, 'fieldName'))] = [html_unescape(step) for step in steps]
        elif kind == 'ApexPage':
            for attribute in ('controller', 'extensions'):
                for value in re.findall(r'\b%s="([^"]+)"' % attribute, text):
                    for one in value.split(','):
                        self.edge(node, 'ApexClass:' + one.strip(), 'hard', attribute)
            for obj in re.findall(r'\bstandardController="(\w+)"', text):
                context.add(obj)
                if obj in self.objects and self.objects[obj]['custom']:
                    self.edge(node, 'CustomObject:' + obj, 'hard', 'standard controller')
            for resource in re.findall(r'\$Resource\.(\w+)', text):
                self.edge(node, 'StaticResource:' + resource, 'hard', 'loads it')
        elif kind in ('PermissionSet', 'Profile'):
            for tag, target in (('apexClass', 'ApexClass'), ('application', 'CustomApplication'), ('tab', 'CustomTab'), ('apexPage', 'ApexPage'), ('flow', 'Flow'),
                                ('field', 'CustomField'), ('object', 'CustomObject'), ('recordType', 'RecordType'), ('layout', 'Layout')):
                for value in tags(text, tag):
                    self.edge(node, '%s:%s' % (target, value), 'hard', 'grants it')
            for block in re.findall(r'<customPermissions>.*?</customPermissions>', text, re.S):
                self.edge(node, 'CustomPermission:' + first(block, 'name', ''), 'hard', 'grants it')
            for block in re.findall(r'<custom(?:MetadataType|Setting)Accesses>.*?</custom(?:MetadataType|Setting)Accesses>', text, re.S):
                self.edge(node, 'CustomObject:' + first(block, 'name', ''), 'hard', 'grants it')
            for value in tags(text, 'externalCredentialPrincipal'):
                self.edge(node, 'ExternalCredential:' + value.split('-')[0], 'hard', 'grants use of the stored key')
            return
        elif kind == 'NamedCredential':
            for value in tags(text, 'externalCredential'):
                self.edge(node, 'ExternalCredential:' + value, 'hard', 'reads the key from it')
        elif kind == 'ReportType':
            base = first(text, 'baseObject')
            for obj in [base] + tags(text, 'table'):
                if obj:
                    for part in obj.split('.'):
                        if part in self.objects and self.objects[part]['custom']:
                            self.edge(node, 'CustomObject:' + part, 'hard', 'reports on it')
                        elif part in self.objects or part in STANDARD_OBJECTS:
                            self.standard.setdefault(node, set()).add(part)
            for block in re.findall(r'<columns>.*?</columns>', text, re.S):
                field, table = first(block, 'field', ''), first(block, 'table', '')
                self.report_field(node, table, field, base)
        elif kind in ('Report', 'Dashboard'):
            folder = name.split('/')[0]
            self.edge(node, '%sFolder:%s' % (kind, folder), 'hard', 'kept in the folder')
            if kind == 'Report':
                report_type = first(text, 'reportType', '')
                if report_type.endswith('__c'):
                    self.edge(node, 'ReportType:' + report_type[:-3], 'hard', 'its report type')
                self.nodes[node]['reportType'] = report_type
            else:
                for report in tags(text, 'report'):
                    self.edge(node, 'Report:' + report, 'hard', 'draws the report')
        elif kind in ('ReportFolder', 'DashboardFolder'):
            for group in tags(text, 'sharedTo'):
                self.edge(node, 'Group:' + group, 'hard', 'shared with the group')
        elif kind == 'PlatformEventSubscriberConfig':
            for trigger in tags(text, 'platformEventConsumer'):
                self.edge(node, 'ApexTrigger:' + trigger, 'hard', 'configures the trigger')
        elif kind in ('Network', 'CustomSite', 'DigitalExperienceConfig', 'DigitalExperienceBundle'):
            for tag, target in (('site', 'CustomSite'), ('picassoSite', 'CustomSite'), ('profile', 'Profile'), ('selfRegProfile', 'Profile'), ('guestProfile', 'Profile')):
                for value in tags(text, tag):
                    self.edge(node, '%s:%s' % (target, value), 'hard', tag)
            for component in re.findall(r'"definition"\s*:\s*"c:(\w+)"', text) + re.findall(r'\bc:(antsurance\w+)', text):
                self.component(node, component, 'the site holds the component')
        self.model_edges(node, text, 'hard', context=context, via='names it')

    def report_field(self, node, table, field, base):
        owner = table.split('.')[-1] if table else base
        candidates = [owner]
        if owner in self.relationships or (owner + '__r') in self.relationships:
            candidates += sorted(self.relationships.get(owner, set()) | self.relationships.get(owner + '__r', set()))
        for obj in candidates:
            if self.edge(node, 'CustomField:%s.%s' % (obj, field), 'hard', 'a column'):
                return

    def value_set_edge(self, node, obj, field):
        value_set = STANDARD_VALUE_SETS.get((obj, field))
        if value_set:
            self.edge(node, 'StandardValueSet:' + value_set, 'hard', 'offers its values')

    def link(self):
        self.collect_value_sets()
        self.prepare()
        for node, entry in sorted(self.nodes.items()):
            files = self.texts.get(node, [])
            kind = entry['type']
            if kind in ('ApexClass', 'ApexTrigger'):
                for path, text in files:
                    if path.endswith(('.cls', '.trigger')):
                        self.scan_apex(node, text, trigger=kind == 'ApexTrigger')
            elif kind in ('LightningComponentBundle', 'AuraDefinitionBundle'):
                self.scan_bundle(node, files)
            elif kind == 'DigitalExperienceBundle':
                self.scan_xml(node, entry, '\n'.join(text for _, text in files))
            else:
                for path, text in files:
                    self.scan_xml(node, entry, text)

    def result(self):
        return {
            'nodes': {node: dict(entry, files=sorted(entry['files'])) for node, entry in sorted(self.nodes.items())},
            'edges': {node: dict(sorted(targets.items())) for node, targets in sorted(self.edges.items())},
            'standardObjects': {node: sorted(found) for node, found in sorted(self.standard.items())},
            'valuesNamed': dict(sorted(self.values.items())),
            'unknownNames': {node: sorted(found) for node, found in sorted(self.unknown.items())},
            'objects': {name: dict(entry, fields=dict(sorted(entry['fields'].items()))) for name, entry in sorted(self.objects.items())},
            'valueSets': dict(sorted(self.value_sets.items())),
        }


def html_unescape(text):
    return text.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&apos;', "'").replace('&quot;', '"')


def scan(roots):
    """`roots` is a list of (bucket, folder). Returns the whole scan as plain data."""
    Scan.child_fields = {}
    found = Scan()
    for bucket, root in roots:
        found.collect(bucket, root)
    found.link()
    return found.result()


# ---------------------------------------------------------------- reading a scan

def closure(result, seeds, how=('hard',), stop=None):
    """Everything the seeds need, following edges of the given kinds. Returns {node: the node that first asked for it}."""
    seen = {seed: None for seed in seeds if seed in result['nodes']}
    queue = list(seen)
    while queue:
        node = queue.pop(0)
        for target, edge in result['edges'].get(node, {}).items():
            if target in seen or edge['how'] not in how or (stop and stop(node, target)):
                continue
            seen[target] = node
            queue.append(target)
    return seen


def why(result, asked, node):
    """The chain of components that made `node` part of a closure, nearest first."""
    chain = []
    while asked.get(node):
        parent = asked[node]
        chain.append('%s (%s)' % (parent, result['edges'][parent][node].get('via', 'names it')))
        node = parent
    return chain


def main():
    source = os.path.join(ROOT, 'force-app', 'main', 'default')
    result = scan([('core', source)])
    counts = {}
    for entry in result['nodes'].values():
        counts[entry['type']] = counts.get(entry['type'], 0) + 1
    print('%d components, %d of them name something else.' % (len(result['nodes']), len(result['edges'])))
    print('  ' + ', '.join('%d %s' % (count, kind) for kind, count in sorted(counts.items(), key=lambda item: -item[1])))
    print('  %d edges (%d soft).' % (sum(len(targets) for targets in result['edges'].values()),
                                    sum(1 for targets in result['edges'].values() for edge in targets.values() if edge['how'] == 'soft')))
    if '--why' in sys.argv[:-1]:
        node = sys.argv[sys.argv.index('--why') + 1]
        for target, edge in sorted(result['edges'].get(node, {}).items()):
            print('  %s %s  [%s%s]' % (edge['how'], target, edge.get('via', ''), ', one of %d' % edge['oneOf'] if edge.get('oneOf') else ''))
        print('  standard objects: ' + ', '.join(result['standardObjects'].get(node, [])))
        print('  values named: %s' % json.dumps(result['valuesNamed'].get(node, {})))
        print('  unknown names: ' + ', '.join(result['unknownNames'].get(node, [])))
    if '--json' in sys.argv[:-1]:
        with open(sys.argv[sys.argv.index('--json') + 1], 'w', encoding='utf-8') as handle:
            json.dump(result, handle, indent=1, sort_keys=True)


if __name__ == '__main__':
    main()
