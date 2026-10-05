#!/usr/bin/env python3
"""Says what one part of the app names: every object, field, record type, picklist value, class and component.

This is the list to map when a part is to work on an org's own data model instead of ours (the antsurance-adapt
skill). It reads the kit's scan (kit-scan.json) and calls no org.

Usage:
  python3 scripts/setup/describe_capability.py --capability automation
  python3 scripts/setup/describe_capability.py --capability automation --json
  python3 scripts/setup/describe_capability.py --capability automation --only ApexTrigger:AntsurancePolicyTrigger
  python3 scripts/setup/describe_capability.py --list

--only narrows it to the components named (Type:Name, as kit-scan.json writes them) and the code they need, which
is the way to fit a small piece first. deploy_phase.py --list says what each part is and what it brings.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capabilities  # noqa: E402
from _common import KIT_ROOT, SetupError, main, manifest  # noqa: E402

# The kinds of component that are the data model itself. Everything else is what works on it.
MODEL_KINDS = {'CustomObject', 'CustomField', 'RecordType', 'BusinessProcess', 'CompactLayout', 'ListView', 'ValidationRule', 'WebLink', 'GlobalValueSet',
               'StandardValueSet', 'Group', 'CustomMetadata', 'StandardObjectSettings'}
CODE_KINDS = ('ApexTrigger', 'ApexClass', 'Flow', 'LightningComponentBundle', 'AuraDefinitionBundle', 'ApexPage')
WORDS = {'ApexTrigger': 'Triggers', 'ApexClass': 'Apex classes', 'Flow': 'Flows', 'LightningComponentBundle': 'Screen components', 'AuraDefinitionBundle': 'Aura components',
         'ApexPage': 'Document pages', 'FlexiPage': 'Lightning pages', 'Layout': 'Page layouts', 'QuickAction': 'Buttons (quick actions)', 'CustomTab': 'Tabs',
         'CustomApplication': 'Apps', 'PathAssistant': 'Paths', 'PermissionSet': 'Permission sets', 'StaticResource': 'Static resources',
         'CustomNotificationType': 'Notification types', 'ExternalCredential': 'External credentials', 'NamedCredential': 'Named credentials', 'CustomPermission': 'Custom permissions',
         'CspTrustedSite': 'Trusted sites', 'RemoteSiteSetting': 'Remote sites', 'ContentAsset': 'Logo files', 'CustomObject': 'Objects', 'CustomField': 'Fields',
         'RecordType': 'Record types', 'BusinessProcess': 'Processes', 'CompactLayout': 'Compact layouts', 'ListView': 'List views', 'ValidationRule': 'Validation rules',
         'GlobalValueSet': 'Shared picklists', 'Group': 'Public groups', 'CustomMetadata': 'Settings records'}


def load_scan():
    path = os.path.join(KIT_ROOT, 'kit-scan.json')
    if not os.path.exists(path):
        raise SetupError('kit-scan.json is missing from ' + KIT_ROOT + '. Run this from an unpacked kit.')
    with open(path, encoding='utf-8') as handle:
        return json.load(handle)


def nodes_of(name, scan, kit=None):
    """The components a choice holds, as the scan names them."""
    entry = capabilities.named(name, kit)
    if entry['kind'] == 'slice':
        found = ['%s:%s' % (kind, one) for kind, names in (entry.get('members') or {}).items() for one in names]
        return [node for node in found if node in scan['nodes']]
    if entry['kind'] in ('layer', 'phase'):
        return list(capabilities.detail(name, kit)['nodes'])
    if entry['kind'] == 'whole':
        return [node for node, facts in scan['nodes'].items() if facts['bucket'] == 'core']
    raise SetupError('"%s" is a step of its own, not a set of components. It is built on: %s.' % (entry['label'], ', '.join(entry.get('brings', [])) or 'nothing'))


def with_code_it_needs(scan, nodes, within):
    """The components named and the code they use, inside the part: a trigger brings its handler, a handler its helpers and its test."""
    seen, queue = list(dict.fromkeys(nodes)), list(nodes)
    inside = set(within)
    while queue:
        node = queue.pop(0)
        for target, edge in sorted(scan['edges'].get(node, {}).items()):
            if target in inside and target not in seen and scan['nodes'][target]['type'] not in MODEL_KINDS and edge['how'] == 'hard':
                seen.append(target)
                queue.append(target)
    # A test of something chosen comes with it: the test that carries its name, and any test that names it.
    for node in sorted(inside):
        facts = scan['nodes'][node]
        if facts.get('test') and node not in seen and (node[:-4] in seen or any(target in seen for target in scan['edges'].get(node, {}))):
            seen.append(node)
    return seen


def what_it_names(scan, nodes):
    """The data model a set of components names. Returns plain data, ready to print or to check a mapping against."""
    objects, kinds = {}, {}
    code = [node for node in nodes if scan['nodes'][node]['type'] not in MODEL_KINDS]
    model_only = not code
    for node in nodes:
        kinds.setdefault(scan['nodes'][node]['type'], []).append(scan['nodes'][node]['name'])

    def obj(name):
        facts = scan['objects'].get(name) or {}
        return objects.setdefault(name, {'ours': bool(facts.get('custom')), 'kind': facts.get('kind', 'standard'), 'label': facts.get('label', name),
                                         'namedBy': set(), 'fields': {}, 'recordTypes': {}})
    for node in (nodes if model_only else code):
        for target, edge in scan['edges'].get(node, {}).items():
            kind, name = target.split(':', 1)
            if kind == 'CustomObject':
                obj(name)['namedBy'].add(node)
            elif kind == 'CustomField':
                owner, field = name.split('.', 1)
                facts = dict(scan['objects'][owner]['fields'].get(field, {}))
                entry = obj(owner)['fields'].setdefault(field, dict(facts, namedBy=set(), unsure=set()))
                entry['namedBy'].add(node)
                if edge.get('oneOf'):
                    entry['unsure'].add(node)
            elif kind == 'RecordType':
                owner, record_type = name.split('.', 1)
                obj(owner)['recordTypes'].setdefault(record_type, set()).add(node)
        for name in scan['standardObjects'].get(node, []):
            obj(name)['namedBy'].add(node)
    if model_only:
        for node in nodes:
            kind, name = node.split(':', 1)
            if kind == 'CustomObject':
                obj(name)
            elif kind == 'CustomField':
                owner, field = name.split('.', 1)
                obj(owner)['fields'].setdefault(field, dict(scan['objects'][owner]['fields'].get(field, {}), namedBy=set(), unsure=set()))
            elif kind == 'RecordType':
                owner, record_type = name.split('.', 1)
                obj(owner)['recordTypes'].setdefault(record_type, set())
    values = {}
    for node in code:
        for field, named in scan['valuesNamed'].get(node, {}).items():
            for value in named:
                values.setdefault(field, {}).setdefault(value, set()).add(node)
    return {'objects': objects, 'values': values, 'components': kinds, 'code': code}


def as_data(found):
    """The same with sets turned to sorted lists and counts, for --json and for the adapter's report."""
    objects = {}
    for name, entry in sorted(found['objects'].items()):
        objects[name] = {
            'ours': entry['ours'], 'kind': entry['kind'], 'label': entry['label'], 'namedByCount': len(entry['namedBy']),
            'fields': {field: dict({key: value for key, value in facts.items() if key not in ('namedBy', 'unsure')}, namedByCount=len(facts['namedBy']),
                                   namedBy=sorted(facts['namedBy'])[:12], unsure=bool(facts['unsure']) and facts['unsure'] == facts['namedBy'])
                       for field, facts in sorted(entry['fields'].items())},
            'recordTypes': {record_type: sorted(by) for record_type, by in sorted(entry['recordTypes'].items())},
        }
    counts = {'objectsOfOurs': len([1 for entry in objects.values() if entry['ours']]), 'standardObjects': len([1 for entry in objects.values() if not entry['ours']]),
              'fields': sum(len(entry['fields']) for entry in objects.values()), 'recordTypes': sum(len(entry['recordTypes']) for entry in objects.values()),
              'picklistValues': sum(len(named) for named in found['values'].values()), 'components': {kind: len(names) for kind, names in sorted(found['components'].items())}}
    return {'counts': counts, 'objects': objects, 'picklistValues': {field: sorted(named) for field, named in sorted(found['values'].items())},
            'components': {kind: sorted(names) for kind, names in sorted(found['components'].items())}}


def type_words(facts):
    words = facts.get('type', 'Unknown')
    if facts.get('referenceTo'):
        words += ' to ' + facts['referenceTo']
    if facts.get('formula'):
        words += ', a formula'
    if facts.get('length'):
        words += ', %s long' % facts['length']
    if facts.get('precision'):
        words += ', %s digits%s' % (facts['precision'], ' with %s decimals' % facts['scale'] if facts.get('scale') else '')
    if facts.get('required') and facts.get('type') != 'MasterDetail':
        words += ', required'
    if facts.get('valueSet'):
        words += ', values from the shared list %s' % facts['valueSet']
    return words


def as_text(entry, data, narrowed):
    counts = data['counts']
    lines = ['%s: what it names%s' % (entry['label'], ' (narrowed to %d components and the code they need)' % narrowed if narrowed else ''), '']
    lines.append('In all: %d of our objects, %d standard objects, %d fields, %d record types, %d picklist values named in code.'
                 % (counts['objectsOfOurs'], counts['standardObjects'], counts['fields'], counts['recordTypes'], counts['picklistValues']))
    lines.append('Made of: ' + ', '.join('%d %s' % (count, WORDS.get(kind, kind).lower()) for kind, count in sorted(counts['components'].items(), key=lambda item: -item[1])) + '.')
    if not counts['objectsOfOurs'] and not counts['fields']:
        lines += ['', 'It names no object or field of ours. Nothing has to be mapped for it to work in an org with another data model.']
    for title, ours in (('Our objects (each needs a place in your model, or to be created, or to be left out)', True), ('Standard objects it works on (yours already)', False)):
        chosen = [(name, found) for name, found in data['objects'].items() if found['ours'] == ours]
        if not chosen:
            continue
        lines += ['', title, '']
        for name, found in chosen:
            lines.append('%s  (%s%s; named by %d components)' % (name, found['kind'], ', "%s"' % found['label'] if found['label'] != name else '', found['namedByCount']))
            for field, facts in found['fields'].items():
                lines.append('    %-34s %s; named by %d%s' % (field, type_words(facts), facts['namedByCount'], '; which object it is on was a guess from the code around it' if facts['unsure'] else ''))
                named = data['picklistValues'].get('%s.%s' % (name, field))
                if named:
                    lines.append('    %-34s values named in code: %s' % ('', ', '.join(named)))
                elif facts.get('values'):
                    lines.append('    %-34s values: %s' % ('', ', '.join(facts['values'][:12]) + (' and %d more' % (len(facts['values']) - 12) if len(facts['values']) > 12 else '')))
            for record_type, by in found['recordTypes'].items():
                lines.append('    record type %-22s named by %d' % (record_type, len(by)))
            for field, named in data['picklistValues'].items():
                if field.split('.')[0] == name and field.split('.')[1] not in found['fields']:
                    lines.append('    %-34s standard picklist; values named in code: %s' % (field.split('.')[1], ', '.join(named)))
    lines += ['', 'Its components', '']
    for kind in list(CODE_KINDS) + sorted(set(data['components']) - set(CODE_KINDS) - MODEL_KINDS):
        names = data['components'].get(kind)
        if names:
            lines.append('%s (%d): %s' % (WORDS.get(kind, kind), len(names), ', '.join(names)))
    return lines


def describe(name, only=None, kit=None, scan=None):
    kit = kit or manifest()
    scan = scan or load_scan()
    nodes = nodes_of(name, scan, kit)
    narrowed = 0
    if only:
        unknown = [node for node in only if node not in nodes]
        if unknown:
            raise SetupError('%s %s not in "%s". Its components are listed by this script without --only.' % (', '.join(unknown), 'is' if len(unknown) == 1 else 'are', capabilities.named(name, kit)['label']))
        nodes = with_code_it_needs(scan, only, nodes)
        narrowed = len(only)
    return nodes, as_data(what_it_names(scan, nodes)), narrowed


def run():
    parser = argparse.ArgumentParser(description='Say what one part of the app names: objects, fields, record types, picklist values, classes and components.')
    parser.add_argument('--capability', metavar='PART')
    parser.add_argument('--only', action='append', default=[], metavar='Type:Name', help='Narrow it to this component and the code it needs. Repeat for more.')
    parser.add_argument('--json', action='store_true', help='The same as data')
    parser.add_argument('--list', action='store_true', help='Print the parts and stop')
    args = parser.parse_args()
    if args.list or not args.capability:
        print('\n'.join(capabilities.menu()))
        return
    nodes, data, narrowed = describe(args.capability, args.only)
    entry = capabilities.named(args.capability)
    if args.json:
        print(json.dumps(dict(data, capability=args.capability, label=entry['label'], nodes=sorted(nodes)), indent=2, sort_keys=True))
    else:
        print('\n'.join(as_text(entry, data, narrowed)))


if __name__ == '__main__':
    main(run)
