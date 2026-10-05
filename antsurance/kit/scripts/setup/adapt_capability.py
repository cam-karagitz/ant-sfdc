#!/usr/bin/env python3
"""Writes a copy of one part of the app that names an org's own objects and fields in place of ours.

It does the mechanical half of fitting a part to another data model, and writes down the other half. It reads the
kit and a mapping file, writes into a folder you name, and never edits force-app/ and never calls an org.

  python3 scripts/setup/adapt_capability.py --capability automation --mapping mapping.json --out adapted/
  python3 scripts/setup/adapt_capability.py --capability automation --mapping mapping.json --out adapted/ --org-metadata .install/org-metadata/<alias>
  python3 scripts/setup/adapt_capability.py --capability automation --mapping mapping.json --check      (says what the mapping still lacks; writes nothing)

What it does by itself: renames our objects, fields, relationships, record types and picklist values to the org's,
in Apex, triggers, flows, screen components and document pages; renames the copied classes, triggers, flows and
components by the org's conventions (org-conventions.json when it is there, or "prefix" in the mapping); copies our
field or object beside theirs where the mapping says "createOurs".

What it leaves for judgment, each written to <out>/ADAPT-REPORT.md with its file, line and reason: a field whose
type differs, a master-detail that is a lookup on their side, a picklist value with no match, a record type they do
not have, a name that could be one of two things, anything the mapping leaves out, every test that builds records,
a field or a class of ours that the copy names and the mapping or the copy does not hold, a picklist value in a
screen component's script, and every line that still says Antsurance.

It refuses a mapping that leaves out something the part names, and says what. mapping.example.json shows the format;
describe_capability.py lists what has to be in it.
"""
import argparse
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capabilities  # noqa: E402
import describe_capability  # noqa: E402
from _common import KIT_ROOT, SetupError, main, manifest  # noqa: E402

SOURCE = os.path.join(KIT_ROOT, 'force-app', 'main', 'default')
CUSTOM = re.compile(r'\b[A-Za-z][A-Za-z0-9_]*__(?:c|r|mdt|e)\b')
WORD = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
TYPE_WORDS = {('MasterDetail', 'Lookup'): 'Ours is a master-detail and theirs is a lookup: their record can have no parent, is not deleted with it, and is not shared through it. '
                                         'Code that assumes a parent is always there, and any roll-up summary on the parent, needs another way.'}


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)


def choice(entry):
    """What a mapping says about one of our things: ('to', theirs), ('create', None), ('leave', None), or None when it says nothing."""
    if isinstance(entry, str):
        return ('to', entry)
    if not isinstance(entry, dict):
        return None
    if entry.get('to'):
        return ('to', entry['to'])
    if entry.get('toFieldValue'):
        return ('value', entry['toFieldValue'])
    if entry.get('createOurs'):
        return ('create', None)
    if entry.get('leaveOut'):
        return ('leave', None)
    return None


class Plan:
    """A mapping, checked against what the part names."""

    def __init__(self, mapping, scan, nodes, named, conventions=None):
        self.mapping, self.scan, self.nodes, self.named = mapping, scan, nodes, named
        self.objects = {name: choice(entry) for name, entry in (mapping.get('objects') or {}).items()}
        self.fields = {name: choice(entry) for name, entry in (mapping.get('fields') or {}).items()}
        self.record_types = {name: choice(entry) for name, entry in (mapping.get('recordTypes') or {}).items()}
        self.values = mapping.get('picklistValues') or {}
        self.child = {name: entry.get('childRelationship') for name, entry in (mapping.get('fields') or {}).items() if isinstance(entry, dict)}
        self.owners = {}
        for obj, facts in scan['objects'].items():
            for field in facts['fields']:
                self.owners.setdefault(field, set()).add(obj)
        self.relationships, self.children = {}, {}
        for obj, facts in scan['objects'].items():
            for field, one in facts['fields'].items():
                if one.get('referenceTo'):
                    self.relationships.setdefault(re.sub(r'__c$', '__r', field), set()).add(obj)
                    if one.get('relationshipName'):
                        self.children.setdefault(one['relationshipName'] + '__r', set()).add('%s.%s' % (obj, field))
        self.prefix, self.test_style = naming(mapping, conventions)

    def object_choice(self, name):
        found = self.objects.get(name)
        if found is None and not self.scan['objects'].get(name, {}).get('custom'):
            return ('same', None)   # a standard object is theirs already
        return found

    def field_choice(self, obj, field):
        found = self.fields.get('%s.%s' % (obj, field))
        if found is None:
            whole = self.object_choice(obj)
            if whole and whole[0] in ('create', 'leave'):
                return whole        # a field goes the way of its object
        return found

    def problems(self):
        """What the mapping lacks or gets wrong, one line each. An empty list means the adapter can run."""
        lines = []
        for name, entry in sorted(self.named['objects'].items()):
            if entry['ours'] and self.object_choice(name) is None:
                lines.append('object %s (%s): say where it lives in the org ("to"), or "createOurs", or "leaveOut"' % (name, entry['label']))
            for field in sorted(entry['fields']):
                found = self.field_choice(name, field)
                if found is None:
                    lines.append('field %s.%s (%s): say which field of theirs it is ("to": "Object.Field"), or "createOurs", or "leaveOut"'
                                 % (name, field, describe_capability.type_words(entry['fields'][field])))
                elif found[0] == 'to' and '.' not in found[1]:
                    lines.append('field %s.%s: "to" must name the object too, as in "Their_Object__c.Their_Field__c"; it says "%s"' % (name, field, found[1]))
            for record_type in sorted(entry['recordTypes']):
                if self.record_types.get('%s.%s' % (name, record_type)) is None:
                    lines.append('record type %s.%s: say which record type of theirs it is ("to": "Object.Name"), or the field value that marks such a record ("toFieldValue"), or "leaveOut"' % (name, record_type))
        for field, values in sorted(self.named['picklistValues'].items()):
            obj, one = field.split('.', 1)
            found = self.field_choice(obj, one) if one in self.scan['objects'].get(obj, {}).get('fields', {}) else ('same', None)
            if found and found[0] in ('create', 'leave'):
                continue
            given = self.values.get(field) or {}
            missing = [value for value in values if value not in given]
            if missing:
                lines.append('picklist values of %s named in the code: %s. For each, give their value, or null when they have none ("picklistValues": {"%s": {"%s": "..."}})'
                             % (field, ', '.join(missing), field, missing[0]))
        return lines


def naming(mapping, conventions):
    """The prefix for the copies and how the org names its tests. The mapping's own word wins; then the org's conventions."""
    prefix, style = mapping.get('prefix'), mapping.get('testNames')
    for line in (conventions or {}).get('observations', []):
        if line.get('what') == 'Apex class names' and prefix is None and (line.get('prefix') or {}).get('sure') in ('sure', 'fairly sure'):
            prefix = line['prefix']['text']
        if line.get('what') == 'Apex test class names' and style is None and line.get('style'):
            style = line['style']
    return prefix, style or 'Test at the end'


def new_class_name(name, is_test, plan):
    base = name[len('Antsurance'):] if name.startswith('Antsurance') else name
    if is_test and base.endswith('Test'):
        base = base[:-4]
    out = (plan.prefix or '') + base
    if not is_test:
        return out
    return {'_Test at the end': out + '_Test', 'Test at the start': 'Test' + out}.get(plan.test_style, out + 'Test')


def new_bundle_name(name, plan):
    base = name[len('antsurance'):] if name.startswith('antsurance') else name[:1].upper() + name[1:]
    lead = re.sub(r'[^A-Za-z0-9]', '', plan.prefix or '')
    if not lead:
        return base[:1].lower() + base[1:]
    return lead[:1].lower() + lead[1:] + base


def relationship_of(field):
    return field[:-3] + '__r' if field.endswith('__c') else field[:-2] if field.endswith('Id') else field


# ---------------------------------------------------------------- reading what the org has, when its metadata was pulled

def their_model(folder):
    """Field types and name fields from a folder of pulled metadata in source format. {} when there is none."""
    if not folder:
        return None
    for base in (folder, os.path.join(folder, 'main', 'default'), os.path.join(folder, 'force-app', 'main', 'default')):
        if os.path.isdir(os.path.join(base, 'objects')):
            break
    else:
        raise SetupError('%s holds no objects/ folder. Give the folder the preflight pulled the org\'s metadata into (.install/org-metadata/<alias>).' % folder)
    found = {}
    for obj in sorted(os.listdir(os.path.join(base, 'objects'))):
        root = os.path.join(base, 'objects', obj)
        if not os.path.isdir(root):
            continue
        entry = {'fields': {}, 'recordTypes': set(), 'nameType': None}
        meta = os.path.join(root, obj + '.object-meta.xml')
        if os.path.exists(meta):
            name_field = re.search(r'<nameField>.*?<type>(\w+)</type>', read(meta), re.S)
            entry['nameType'] = name_field.group(1) if name_field else None
        for file_name in sorted(os.listdir(os.path.join(root, 'fields'))) if os.path.isdir(os.path.join(root, 'fields')) else []:
            if file_name.endswith('.field-meta.xml'):
                text = read(os.path.join(root, 'fields', file_name))
                entry['fields'][file_name[:-len('.field-meta.xml')]] = {
                    'type': (re.search(r'<type>(\w+)</type>', text) or [None, None])[1], 'required': '<required>true</required>' in text,
                    'referenceTo': (re.search(r'<referenceTo>(\w+)</referenceTo>', text) or [None, None])[1],
                    'length': int((re.search(r'<length>(\d+)</length>', text) or [None, 0])[1]),
                    'values': re.findall(r'<value>\s*<fullName>([^<]*)</fullName>', text), 'relationshipName': (re.search(r'<relationshipName>(\w+)</relationshipName>', text) or [None, None])[1]}
        if os.path.isdir(os.path.join(root, 'recordTypes')):
            entry['recordTypes'] = {name[:-len('.recordType-meta.xml')] for name in os.listdir(os.path.join(root, 'recordTypes')) if name.endswith('.recordType-meta.xml')}
        found[obj] = entry
    return found


# ---------------------------------------------------------------- the rewriting

class Adapter:
    def __init__(self, plan, class_names, bundle_names, flow_names, theirs=None):
        self.plan, self.class_names, self.bundle_names, self.flow_names, self.theirs = plan, class_names, bundle_names, flow_names, theirs
        # Classes and screen components of ours that are not part of this copy. A file that names one will not
        # compile in an org that does not hold ours.
        nodes = plan.scan.get('nodes', {})
        self.ours_not_copied = {facts['name'] for facts in nodes.values() if facts['type'] in ('ApexClass', 'ApexTrigger') and facts['name'] not in class_names}
        self.bundles_not_copied = {facts['name'] for facts in nodes.values() if facts['type'] == 'LightningComponentBundle' and facts['name'] not in bundle_names}
        self.done = []       # (file, line, kind, from, to)
        self.judgment = []   # (file, line, kind, why)
        self.objects = plan.scan['objects']

    # ---- bookkeeping

    def did(self, where, line, kind, old, new):
        self.done.append({'file': where, 'line': line, 'kind': kind, 'from': old, 'to': new})

    def flag(self, where, line, kind, why):
        item = {'file': where, 'line': line, 'kind': kind, 'why': why}
        if item not in self.judgment:
            self.judgment.append(item)

    def needs_ours(self, where, line, name, kind='class'):
        self.flag(where, line, 'needs ours', 'This line names %s, a %s of ours that is not part of this copy. The copy will not compile in an org that does not hold it: do without it here (a test builds its own records), or adapt it too by naming it under "only".' % (name, kind))

    # ---- what a name becomes

    def object_to(self, name, where, line):
        found = self.plan.object_choice(name)
        if not found or found[0] in ('same', 'create'):
            return name
        if found[0] == 'leave':
            self.flag(where, line, 'left out', 'This line names %s, which the mapping leaves out. Take the line out, or what it does, by hand.' % name)
            return name
        self.did(where, line, 'object', name, found[1])
        return found[1]

    def field_to(self, obj, field, where, line, as_relationship=False):
        token = relationship_of(field) if as_relationship else field
        found = self.plan.field_choice(obj, field)
        if not found and self.objects.get(obj, {}).get('fields', {}).get(field) is not None and field.endswith('__c'):
            # The list of what a part names comes from the kit's scan, and a mapping is checked against that list. A
            # field the scan did not see here is still a field of ours: say so, and never pass it over.
            self.flag(where, line, 'not in the mapping', 'This line names %s.%s, a field of ours the mapping says nothing about. Give it a line in the mapping ("to", "createOurs" or "leaveOut") and run again, or change the line by hand.' % (obj, field))
            return token
        if not found or found[0] in ('same', 'create'):
            return token
        if found[0] == 'leave':
            self.flag(where, line, 'left out', 'This line names %s.%s, which the mapping leaves out. Take the line out, or what it does, by hand.' % (obj, field))
            return token
        theirs = found[1].split('.', 1)[1]
        new = relationship_of(theirs) if as_relationship else theirs
        self.did(where, line, 'relationship' if as_relationship else 'field', '%s.%s' % (obj, token), '%s.%s' % (found[1].split('.', 1)[0], new))
        return new

    def owners_in(self, field, named):
        owners = self.plan.owners.get(field, set())
        return sorted((owners & named) or owners)

    def by_file(self, field, named, where, line, as_relationship=False):
        """A field named without its object: the one object in this file that has it, or the same answer from all that do."""
        owners = self.owners_in(field, named)
        results = {}
        for obj in owners:
            found = self.plan.field_choice(obj, field)
            results[obj] = found
        answers = {str(found) for found in results.values()}
        if len(answers) == 1 and owners:
            return self.field_to(owners[0], field, where, line, as_relationship)
        self.flag(where, line, 'which object', '%s could be a field of %s here, and the mapping treats them differently. Nothing was changed on this line: put the right name in by hand.' % (field, ' or '.join(owners)))
        return relationship_of(field) if as_relationship else field

    # ---- Apex

    def apex(self, where, text):
        spans = [(match.start(), match.end(), match.group(0)) for match in re.finditer(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\\n])*'", text, re.S)]
        blank = list(text)
        strings = []
        for start, end, found in spans:
            if found.startswith("'"):
                strings.append((start, end))
                blank[start + 1:end - 1] = ' ' * (end - start - 2)
            else:
                blank[start:end] = [char if char == '\n' else ' ' for char in found]
        blank = ''.join(blank)
        named = self.named_objects(blank + ' ' + ' '.join(text[start:end] for start, end in strings))
        queries = self.queries(blank)
        edits = []

        def line_of(position):
            return text.count('\n', 0, position) + 1

        for match in WORD.finditer(blank):
            token, start, end = match.group(0), match.start(), match.end()
            if token in self.class_names:
                edits.append((start, end, self.class_names[token]))
                self.did(where, line_of(start), 'class name', token, self.class_names[token])
                continue
            if token in self.ours_not_copied:
                self.needs_ours(where, line_of(start), token)
                continue
            if not CUSTOM.fullmatch(token) and token not in self.plan.objects:
                continue
            new = self.apex_token(where, line_of(start), token, start, end, blank, named, queries)
            if new != token:
                edits.append((start, end, new))
        for start, end in strings:
            content = text[start + 1:end - 1]
            new = self.literal(where, line_of(start), content, named, blank)
            if new != content:
                edits.append((start + 1, end - 1, new))
        for start, end, new in sorted(edits, reverse=True):
            text = text[:start] + new + text[end:]
        # A comment that names a class we renamed should name the copy.
        for old, new in self.class_names.items():
            text = re.sub(r'\b%s\b' % re.escape(old), new, text)
        return text

    def named_objects(self, text):
        return {name for name in self.objects if re.search(r'\b%s\b' % re.escape(name), text)}

    def queries(self, blank):
        """Each [SELECT ...] and each (SELECT ...) inside one: (start, end, the object it reads from)."""
        found = []
        for match in re.finditer(r'[\[(]\s*SELECT\b', blank, re.I):
            opener = blank[match.start()]
            closer = ']' if opener == '[' else ')'
            depth, position = 0, match.start()
            while position < len(blank):
                if blank[position] == opener:
                    depth += 1
                elif blank[position] == closer:
                    depth -= 1
                    if depth == 0:
                        break
                position += 1
            body = blank[match.start():position]
            # The FROM of this query, not of a query inside it.
            flat, level = [], 0
            for char in body[1:]:
                level += char == '('
                flat.append(char if level == 0 else ' ')
                level -= char == ')'
            source = re.search(r'\bFROM\s+(\w+)', ''.join(flat), re.I)
            found.append((match.start(), position, source.group(1) if source else None))
        return found

    def query_object(self, position, queries):
        inside = [(end - start, source) for start, end, source in queries if start <= position < end]
        if not inside:
            return None, False
        source = min(inside)[1]
        if source in self.plan.children:
            return sorted({one.split('.')[0] for one in self.plan.children[source]})[0], True
        return source, True

    def variable_type(self, name, blank, position):
        best = None
        for match in re.finditer(r'\b([A-Za-z_]\w*)\s+%s\b\s*(?=[=;:,)])' % re.escape(name), blank[:position]):
            if match.group(1) in self.objects:
                best = match.group(1)
        return best

    def constructed(self, blank, position):
        """The object being built when `position` is inside new Something( ... )."""
        depth = 0
        for index in range(position - 1, max(position - 4000, -1), -1):
            char = blank[index]
            if char == ')':
                depth += 1
            elif char == '(':
                if depth == 0:
                    before = re.search(r'\bnew\s+(\w+)\s*$', blank[:index])
                    return before.group(1) if before and before.group(1) in self.objects else None
                depth -= 1
            elif char in ';{}':
                return None
        return None

    def apex_token(self, where, line, token, start, end, blank, named, queries):
        before, after = blank[:start].rstrip(), blank[end:].lstrip()
        prev_char, next_char = before[-1:], after[:1]
        prev_word = (re.search(r'(\w+)$', before) or [None, ''])[1]
        relationship = token.endswith('__r')
        field = token[:-3] + '__c' if relationship else token
        is_object = token in self.objects
        is_field = field in self.plan.owners
        source, in_query = self.query_object(start, queries)
        if relationship and token in self.plan.children and not is_field:
            return self.child_relationship(where, line, token)
        if prev_char == '.':
            left = (re.search(r'([A-Za-z_]\w*)\s*\.$', before) or [None, None])[1]
            owner = None
            if left in self.objects and field in self.objects[left]['fields']:
                owner = left
            elif left and left.endswith('__r') and left in self.plan.relationships:
                base = left[:-3] + '__c'
                targets = {self.objects[obj]['fields'][base]['referenceTo'] for obj in self.plan.owners.get(base, ()) if self.objects[obj]['fields'][base].get('referenceTo')}
                fits = [obj for obj in sorted(targets) if field in self.objects.get(obj, {}).get('fields', {})]
                owner = fits[0] if len(fits) == 1 else None
            elif left:
                kind = self.variable_type(left, blank, start)
                owner = kind if kind and field in self.objects[kind]['fields'] else None
            if owner:
                return self.field_to(owner, field, where, line, relationship)
            if is_field:
                return self.by_file(field, named, where, line, relationship)
            return token
        if in_query:
            if prev_word.upper() == 'FROM':
                if is_object:
                    return self.object_to(token, where, line)
                return self.child_relationship(where, line, token) if token in self.plan.children else token
            if source in self.objects and field in self.objects[source]['fields']:
                return self.field_to(source, field, where, line, relationship)
            return self.by_file(field, named, where, line, relationship) if is_field else token
        if is_object and not is_field:
            return self.object_to(token, where, line)
        building = self.constructed(blank, start) if next_char == '=' else None
        if building and field in self.objects[building]['fields']:
            return self.field_to(building, field, where, line, relationship)
        if is_object and is_field:
            next_word = re.match(r'[A-Za-z_]\w*', after)
            if prev_word in ('new', 'instanceof') or next_word or (prev_char in '<,(' and next_char in '>,)') or next_char in ('>', '[', '('):
                return self.object_to(token, where, line)
            self.flag(where, line, 'object or field', '%s is both one of our objects and a field on %s. Which is meant here could not be told, so the line is unchanged.'
                      % (token, ', '.join(sorted(self.plan.owners[field] - {token}))))
            return token
        if is_field:
            return self.by_file(field, named, where, line, relationship)
        return token

    def child_relationship(self, where, line, token):
        fields = sorted(self.plan.children.get(token, ()))
        given = {self.plan.child.get(field) for field in fields} - {None}
        if len(given) == 1:
            new = given.pop()
            self.did(where, line, 'relationship', token, new)
            return new
        choices = [self.plan.fields.get(field) for field in fields]
        if all(found and found[0] in ('create', 'same') for found in choices):
            return token
        self.flag(where, line, 'child relationship', '%s reads the children of a record through %s. Give the name of that relationship in the org ("childRelationship" beside the field in the mapping), or change the line by hand.'
                  % (token, ' or '.join(fields)))
        return token

    def literal(self, where, line, content, named, text):
        """A string: a record type by name, a picklist value, a bare object or field name, or a query written as text."""
        record_types = {name.split('.', 1)[1]: (name, found) for name, found in self.plan.record_types.items()}
        if content in record_types and re.search(r'RecordType', text, re.I):
            name, found = record_types[content]
            if found and found[0] == 'to':
                new = found[1].split('.')[-1]
                self.did(where, line, 'record type', name, found[1])
                return new
            if found and found[0] == 'value':
                self.flag(where, line, 'record type', 'Ours asks whether the record type is %s. In the org that is the field value %s = "%s", so this test has to become a check of that field, by hand.'
                          % (name, found[1].get('field'), found[1].get('value')))
            elif found and found[0] == 'leave':
                self.flag(where, line, 'record type', 'This line asks for the record type %s, which the mapping leaves out: the org has no such kind of record. Decide what the code should do instead.' % name)
            return content
        hits = {}
        for field, values in self.plan.values.items():
            obj = field.split('.')[0]
            if content in values and (obj in named or not self.objects.get(obj, {}).get('custom', True)) and re.search(r'\b%s\b' % re.escape(field.split('.')[1]), text):
                hits[field] = values[content]
        if hits:
            answers = set(hits.values())
            if len(answers) == 1 and None not in answers:
                new = answers.pop()
                if new != content:
                    self.did(where, line, 'picklist value', '%s "%s"' % (sorted(hits)[0], content), new)
                return new
            if None in answers:
                self.flag(where, line, 'picklist value', 'The value "%s" of %s has no match in the org (the mapping says null). Decide what this line should do there.' % (content, ' or '.join(sorted(hits))))
            else:
                self.flag(where, line, 'picklist value', '"%s" is a value of %s, mapped to different values. The line is unchanged.' % (content, ' and '.join(sorted(hits))))
            return content
        if not CUSTOM.search(content):
            return content
        source = re.search(r'\bFROM\s+(\w+)', content, re.I)
        scope = named | ({source.group(1)} if source and source.group(1) in self.objects else set())

        def swap(match):
            token = match.group(0)
            relationship = token.endswith('__r')
            field = token[:-3] + '__c' if relationship else token
            left = (re.search(r'(\w+)\.$', content[:match.start()]) or [None, None])[1]
            after_from = re.search(r'\bFROM\s+$', content[:match.start()], re.I)
            if token in self.objects and (after_from or field not in self.plan.owners):
                return self.object_to(token, where, line)
            if token in self.objects and content.strip() == token:
                self.flag(where, line, 'object or field', 'The text "%s" is both one of our objects and a field. Which is meant here could not be told, so it is unchanged.' % token)
                return token
            if left in self.objects and field in self.objects[left]['fields']:
                return self.field_to(left, field, where, line, relationship)
            if source and source.group(1) in self.objects and field in self.objects[source.group(1)]['fields'] and not left:
                return self.field_to(source.group(1), field, where, line, relationship)
            if relationship and token in self.plan.children and field not in self.plan.owners:
                return self.child_relationship(where, line, token)
            return self.by_file(field, scope, where, line, relationship) if field in self.plan.owners else token
        return CUSTOM.sub(swap, content)

    # ---- flows, components, pages

    def markup(self, where, text, context=()):
        """Anything that is not Apex: a field written with its object is certain; one without is matched to the objects the file names."""
        named = self.named_objects(text) | set(context)
        record_types = {name.split('.', 1)[1]: (name, found) for name, found in self.plan.record_types.items()}
        lines = text.split('\n')
        for number, line in enumerate(lines, 1):
            def swap(match, number=number, line=line):
                token = match.group(0)
                relationship = token.endswith('__r')
                field = token[:-3] + '__c' if relationship else token
                left = (re.search(r'([A-Za-z_]\w*)\.$', line[:match.start()]) or [None, None])[1]
                tag = (re.search(r'<(\w+)>$', line[:match.start()]) or [None, None])[1]
                if token in self.objects and (tag in ('object', 'objectType', 'sobjectType', 'targetObject', 'referenceTo') or field not in self.plan.owners):
                    return self.object_to(token, where, number)
                if left in self.objects and field in self.objects[left]['fields']:
                    return self.field_to(left, field, where, number, relationship)
                if left in self.element_objects and field in self.objects.get(self.element_objects[left], {}).get('fields', {}):
                    return self.field_to(self.element_objects[left], field, where, number, relationship)
                if self.block_object and field in self.objects.get(self.block_object.get(number), {}).get('fields', {}):
                    return self.field_to(self.block_object[number], field, where, number, relationship)
                if relationship and token in self.plan.children and field not in self.plan.owners:
                    return self.child_relationship(where, number, token)
                if token in self.objects and field in self.plan.owners:
                    self.flag(where, number, 'object or field', '%s is both one of our objects and a field. Which is meant here could not be told, so the line is unchanged.' % token)
                    return token
                return self.by_file(field, named, where, number, relationship) if field in self.plan.owners else token
            # An address of a record page or a list names an object: /lightning/r/Policy__c/... and /lightning/o/Policy__c/...
            line = re.sub(r'(/lightning/[ro]/)(\w+__c)\b', lambda found, number=number: found.group(1) + (self.object_to(found.group(2), where, number) if found.group(2) in self.objects else found.group(2)), line)
            new = CUSTOM.sub(swap, line)
            for imported in re.findall(r'@salesforce/apex/(\w+)\.', new) + re.findall(r'\bcontroller="(\w+)"', new):
                if imported in self.ours_not_copied:
                    self.needs_ours(where, number, imported)
            for imported in re.findall(r"""['"]c/(\w+)['"]""", new):
                if imported in self.bundles_not_copied:
                    self.needs_ours(where, number, imported, 'screen component')
            if where.endswith(('.js', '.html')):
                self.values_in_script(where, number, new)
            for tag in ('stringValue', 'value', 'recordTypeName', 'picklistValueName'):
                for value in re.findall(r'<%s>([^<]+)</%s>' % (tag, tag), new):
                    if value in record_types and ('RecordType' in text or tag == 'recordTypeName'):
                        swapped = self.literal(where, number, value, named, 'RecordType')
                    else:
                        swapped = self.literal(where, number, value, named, text) if any(value in values for values in self.plan.values.values()) else value
                    if swapped != value:
                        new = new.replace('<%s>%s</%s>' % (tag, value, tag), '<%s>%s</%s>' % (tag, swapped, tag))
            for old, fresh in list(self.class_names.items()) + list(self.flow_names.items()):
                if re.search(r'\b%s\b' % re.escape(old), new):
                    new = re.sub(r'\b%s\b' % re.escape(old), fresh, new)
                    self.did(where, number, 'class name' if old in self.class_names else 'flow name', old, fresh)
            for old, fresh in self.bundle_names.items():
                kebab = lambda name: re.sub(r'([A-Z])', lambda m: '-' + m.group(1).lower(), name)  # noqa: E731
                for pattern, replacement in ((r'\bc/%s\b' % old, 'c/' + fresh), (r'\bc:%s\b' % old, 'c:' + fresh), (r'<(/?)c-%s\b' % kebab(old), r'<\1c-' + kebab(fresh))):
                    if re.search(pattern, new):
                        new = re.sub(pattern, replacement, new)
                        self.did(where, number, 'component name', old, fresh)
            lines[number - 1] = new
        return '\n'.join(lines)

    def values_in_script(self, where, number, line):
        """A screen component gets a record's values from Apex without the field's name beside them, so a value it
        compares or keys on cannot be changed for sure. Each one the mapping changes, or has no match for, is flagged."""
        words = set(re.findall(r'\'([^\'\n]{1,60})\'|"([^"\n]{1,60})"', line))
        texts = {one for pair in words for one in pair if one} | set(re.findall(r'[{,]\s*([A-Za-z_]\w*)\s*:', line))
        for field, values in sorted(self.plan.values.items()):
            for value in sorted(texts & set(values)):
                if values[value] != value:
                    self.flag(where, number, 'picklist value', 'This line has the text "%s", which is a value of %s with us (%s in the org). A component is handed values without the field\'s name, so the adapter does not change them: check what this line compares or looks up, and change it by hand.'
                              % (value, field, '"%s"' % values[value] if values[value] is not None else 'no match'))

    element_objects = {}
    block_object = {}

    def flow(self, where, text):
        """A flow: each element that reads or saves records names its object, and its fields belong to that object."""
        self.element_objects, self.block_object = {}, {}
        start = re.search(r'<start>.*?</start>', text, re.S)
        if start and re.search(r'<object>(\w+)</object>', start.group(0)):
            self.element_objects['$Record'] = self.element_objects['Record'] = re.search(r'<object>(\w+)</object>', start.group(0)).group(1)
        for block in re.finditer(r'<(recordLookups|recordCreates|recordUpdates|recordDeletes|dynamicChoiceSets|variables|start)>.*?</\1>', text, re.S):
            body = block.group(0)
            obj = re.search(r'<(?:object|objectType)>(\w+)</(?:object|objectType)>', body)
            name = re.search(r'<name>(\w+)</name>', body)
            if obj and name:
                self.element_objects[name.group(1)] = obj.group(1)
            if obj and block.group(1) != 'variables':
                first = text.count('\n', 0, block.start()) + 1
                for number in range(first, first + body.count('\n') + 1):
                    self.block_object[number] = obj.group(1)
        try:
            return self.markup(where, text)
        finally:
            self.element_objects, self.block_object = {}, {}

    # ---- what the code cannot tell by itself

    def compare_types(self, where, text, named):
        """For each mapped field this file names: a type that differs on their side, a field they do not have."""
        for obj, entry in sorted(named['objects'].items()):
            for field, facts in sorted(entry['fields'].items()):
                found = self.plan.field_choice(obj, field)
                if not found or found[0] != 'to':
                    continue
                their_obj, their_field = found[1].split('.', 1)
                seen = re.search(r'\b%s\b' % re.escape(their_field), text) or re.search(r'\b%s\b' % re.escape(relationship_of(their_field)), text)
                if not seen:
                    continue
                line = text.count('\n', 0, seen.start()) + 1
                override = (self.plan.mapping.get('fields', {}).get('%s.%s' % (obj, field)) or {})
                override = override if isinstance(override, dict) else {}
                their = None
                if self.theirs is not None:
                    their = (self.theirs.get(their_obj) or {}).get('fields', {}).get(their_field)
                    if their is None and their_field.endswith('__c'):
                        self.flag(where, line, 'no such field', 'The mapping sends %s.%s to %s.%s, and the org\'s pulled metadata has no such field. A query on it will not compile.' % (obj, field, their_obj, their_field))
                        continue
                their_type = override.get('type') or (their or {}).get('type')
                if their_type and their_type != facts.get('type'):
                    words = TYPE_WORDS.get((facts.get('type'), their_type), 'Check every line that reads or writes it: a comparison, a sum or an assignment that is right for one type can be wrong for the other.')
                    self.flag(where, line, 'type differs', '%s.%s is %s with us and %s.%s is %s in the org. %s' % (obj, field, facts.get('type'), their_obj, their_field, their_type, words))
                elif their and facts.get('length') and their.get('length') and their['length'] < facts['length']:
                    self.flag(where, line, 'type differs', '%s.%s holds %d characters with us and %s.%s holds %d. Text written to it can be cut or refused.' % (obj, field, facts['length'], their_obj, their_field, their['length']))
                if their and their.get('required') and not facts.get('required'):
                    self.flag(where, line, 'required', '%s.%s is required in the org and not with us. Anything that creates such a record must set it.' % (their_obj, their_field))
        if self.theirs is not None:
            for name, found in self.plan.objects.items():
                if found and found[0] == 'to' and (self.theirs.get(found[1]) or {}).get('nameType') == 'AutoNumber':
                    for match in re.finditer(r'\bnew\s+%s\s*\([^;]*?\bName\s*=' % re.escape(found[1]), text, re.S):
                        self.flag(where, text.count('\n', 0, match.start()) + 1, 'name is a number', 'This line gives a record of %s a name, and in the org its name is an auto number that cannot be set. Take the name out, and change anything that later finds the record by that name.' % found[1])
                # A field the org requires and nothing of ours sets: anything that creates such a record fails until it is given.
                if found and found[0] == 'to' and found[1] in self.theirs:
                    targets = {one[1].split('.', 1)[1] for one in self.plan.fields.values() if one and one[0] == 'to' and one[1].startswith(found[1] + '.')}
                    asked = sorted(field for field, facts in self.theirs[found[1]]['fields'].items() if facts.get('required') and facts.get('type') != 'MasterDetail' and field not in targets)
                    built = re.search(r'\bnew\s+%s\s*\(' % re.escape(found[1]), text)
                    if asked and built:
                        self.flag(where, text.count('\n', 0, built.start()) + 1, 'required', 'The org requires %s on %s, and nothing of ours sets %s. Every place here that creates a record of %s must give it a value.'
                                  % (', '.join(asked), found[1], 'it' if len(asked) == 1 else 'them', found[1]))

    def test_notes(self, where, text):
        builds = sorted({match.group(1) for match in re.finditer(r'\bnew\s+(\w+)\s*\(', text) if match.group(1) in self.objects or match.group(1) in [found[1] for found in self.plan.objects.values() if found and found[0] == 'to']})
        if builds:
            first = re.search(r'\bnew\s+(%s)\s*\(' % '|'.join(map(re.escape, builds)), text)
            self.flag(where, text.count('\n', 0, first.start()) + 1, 'test builds records', 'This test builds %s. In the org those records must satisfy its own required fields, validation rules and automation: read the preflight\'s list, give each record what the org asks for, and keep every assertion.' % ', '.join(builds))


def adapt(capability, mapping, out, org_metadata=None, conventions=None, check_only=False, kit=None, scan=None):
    """Runs the adapter. Returns the report as data. Raises SetupError, naming each gap, when the mapping is not complete."""
    kit = kit or manifest()
    scan = scan or describe_capability.load_scan()
    only = mapping.get('only') or []
    nodes, _, _ = describe_capability.describe(capability, only, kit, scan)
    named = describe_capability.as_data(describe_capability.what_it_names(scan, nodes))
    plan = Plan(mapping, scan, nodes, named, conventions)
    gaps = plan.problems()
    if gaps:
        raise SetupError('The mapping leaves out %d thing%s that "%s" names. Nothing was written.\n  %s\n  describe_capability.py --capability %s%s lists them all with their types.' % (
            len(gaps), '' if len(gaps) == 1 else 's', capabilities.named(capability, kit)['label'], '\n  '.join(gaps), capability, ''.join(' --only ' + one for one in only)))
    if check_only:
        return {'ok': True, 'nodes': nodes}
    code = [node for node in nodes if scan['nodes'][node]['type'] in describe_capability.CODE_KINDS]
    class_names = {scan['nodes'][node]['name']: new_class_name(scan['nodes'][node]['name'], bool(scan['nodes'][node].get('test')), plan) for node in code if scan['nodes'][node]['type'] in ('ApexClass', 'ApexTrigger')}
    bundle_names = {scan['nodes'][node]['name']: new_bundle_name(scan['nodes'][node]['name'], plan) for node in code if scan['nodes'][node]['type'] == 'LightningComponentBundle'}
    flow_names = {scan['nodes'][node]['name']: '%s%s' % ((plan.prefix.rstrip('_') + '_') if plan.prefix else '', scan['nodes'][node]['name']) for node in code if scan['nodes'][node]['type'] == 'Flow'}
    theirs = their_model(org_metadata)
    adapter = Adapter(plan, class_names, bundle_names, flow_names, theirs)
    target = os.path.join(out, 'main', 'default')
    if os.path.isdir(out) and os.listdir(out):
        if not os.path.exists(os.path.join(out, 'ADAPT-REPORT.md')):
            raise SetupError('%s is not empty and was not written by this script. Name a new folder.' % out)
        shutil.rmtree(out)
    written = []
    for node in code:
        facts = scan['nodes'][node]
        own = describe_capability.as_data(describe_capability.what_it_names(scan, [node]))
        for path in facts['files']:
            source = os.path.join(SOURCE, path)
            folder, name = path.split('/', 1)
            if facts['type'] in ('ApexClass', 'ApexTrigger'):
                new_path = '%s/%s' % (folder, name.replace(facts['name'], class_names[facts['name']], 1))
            elif facts['type'] == 'LightningComponentBundle':
                new_path = '%s/%s' % (folder, name.replace(facts['name'], bundle_names[facts['name']]))
            elif facts['type'] == 'Flow':
                new_path = '%s/%s' % (folder, name.replace(facts['name'], flow_names[facts['name']], 1))
            else:
                new_path = path
            where = 'main/default/' + new_path
            try:
                text = read(source)
            except UnicodeDecodeError:
                os.makedirs(os.path.dirname(os.path.join(target, new_path)), exist_ok=True)
                shutil.copyfile(source, os.path.join(target, new_path))
                continue
            if path.endswith(('.cls', '.trigger')):
                new = adapter.apex(where, text)
                adapter.compare_types(where, new, own)
                if facts.get('test'):
                    adapter.test_notes(where, new)
            elif path.endswith('.flow-meta.xml'):
                new = adapter.flow(where, text)
                adapter.compare_types(where, new, own)
            elif path.endswith('-meta.xml') and facts['type'] in ('ApexClass', 'ApexTrigger'):
                new = text
            else:
                new = adapter.markup(where, text)
                adapter.compare_types(where, new, own)
            if new_path != path:
                adapter.did(where, 0, 'file name', path, new_path)
            write(os.path.join(target, new_path), new)
            written.append(new_path)
    # A file of ours that the copied code loads (a font, a style sheet) travels with the copy, under its own name.
    for node in nodes:
        facts = scan['nodes'][node]
        if facts['type'] != 'StaticResource':
            continue
        for path in facts['files']:
            source = os.path.join(SOURCE, path)
            if os.path.isdir(source):
                shutil.copytree(source, os.path.join(target, path), dirs_exist_ok=True)
            elif os.path.exists(source):
                os.makedirs(os.path.dirname(os.path.join(target, path)), exist_ok=True)
                shutil.copyfile(source, os.path.join(target, path))
            written.append(path)
        adapter.flag('main/default/staticresources/' + facts['name'], 0, 'carried as it is', 'The copied code loads the file %s, so it is in the copy under our name. It is not renamed: the code names it in several ways. Keep the name, or rename the file and every line that loads it, by hand.' % facts['name'])
    # What a person would still read as ours: a label in the App Builder, a comment, a class name inside a script.
    for path in sorted(written):
        full = os.path.join(target, path)
        if os.path.isdir(full) or path.startswith('staticresources/'):
            continue
        try:
            lines = read(full).split('\n')
        except UnicodeDecodeError:
            continue
        flagged = {item['line'] for item in adapter.judgment if item['file'] == 'main/default/' + path}
        said = [number for number, line in enumerate(lines, 1) if re.search(r'antsurance', line, re.I) and number not in flagged]
        if said:
            adapter.flag('main/default/' + path, said[0], 'still says Antsurance', '%d line%s still say%s Antsurance (line%s %s): a label a person sees, a comment, or a name the adapter does not change. Change the ones a person reads; a name the code uses must change everywhere it is used.'
                         % (len(said), '' if len(said) == 1 else 's', 's' if len(said) == 1 else '', '' if len(said) == 1 else 's', ', '.join(str(number) for number in said[:12]) + (' and more' if len(said) > 12 else '')))
    # Ours, created beside theirs where the mapping says so.
    created = []
    for obj, entry in sorted(named['objects'].items()):
        whole = plan.object_choice(obj)
        if entry['ours'] and whole and whole[0] == 'create':
            for node in scan['nodes']:
                facts = scan['nodes'][node]
                if facts['bucket'] == 'core' and ((facts['type'] == 'CustomObject' and facts['name'] == obj) or (facts['type'] == 'CustomField' and facts['name'].startswith(obj + '.'))):
                    for path in facts['files']:
                        write(os.path.join(target, path), adapter.markup('main/default/' + path, read(os.path.join(SOURCE, path))))
                        created.append(path)
            continue
        for field in sorted(entry['fields']):
            found = plan.field_choice(obj, field)
            if found and found[0] == 'create' and not (whole and whole[0] == 'leave'):
                home = whole[1] if whole and whole[0] == 'to' else obj
                path = 'objects/%s/fields/%s.field-meta.xml' % (obj, field)
                new_path = 'objects/%s/fields/%s.field-meta.xml' % (home, field)
                text = read(os.path.join(SOURCE, path))
                if '<type>MasterDetail</type>' in text or '<type>Summary</type>' in text:
                    adapter.flag('main/default/' + new_path, 1, 'created beside theirs', 'Our %s.%s is a %s. Salesforce adds such a field to an object that already holds records only under conditions; check it deploys, or make it a lookup.' % (obj, field, 'master-detail' if 'MasterDetail' in text else 'roll-up summary'))
                write(os.path.join(target, new_path), adapter.markup('main/default/' + new_path, text))
                created.append(new_path)
    if created:
        adapter.flag('main/default/objects', 0, 'access', '%d files of ours were written to be created in the org (%s). Nobody can see a new field until a permission set of the org grants it: add them to one of yours.' % (len(created), ', '.join(created[:4]) + (' and others' if len(created) > 4 else '')))
    if not plan.prefix:
        adapter.flag('mapping.json', 0, 'names', 'No prefix was given and the org\'s conventions name none, so the copies carry our names without "Antsurance". Check none of them is the name of something the org already has.')
    write(os.path.join(out, 'sfdx-project.json'), json.dumps({'packageDirectories': [{'path': 'main', 'default': True}], 'namespace': '', 'sourceApiVersion': kit.get('apiVersion', '67.0')}, indent=2) + '\n')
    by_kind, judged = {}, {}
    for item in adapter.done:
        by_kind[item['kind']] = by_kind.get(item['kind'], 0) + 1
    for item in adapter.judgment:
        judged[item['kind']] = judged.get(item['kind'], 0) + 1
    report = {'capability': capability, 'only': only, 'prefix': plan.prefix, 'testNames': plan.test_style, 'files': sorted(written), 'created': sorted(created),
              'renamed': by_kind, 'renames': adapter.done, 'judgment': adapter.judgment, 'judgmentByKind': judged,
              'typesChecked': theirs is not None, 'counts': {'files': len(written) + len(created), 'renames': len(adapter.done), 'judgment': len(adapter.judgment)}}
    write(os.path.join(out, 'adapt-report.json'), json.dumps(report, indent=2, sort_keys=True) + '\n')
    write(os.path.join(out, 'ADAPT-REPORT.md'), report_text(report, capabilities.named(capability, kit)['label'], class_names, bundle_names, flow_names))
    return report


def report_text(report, label, class_names, bundle_names, flow_names):
    counts = report['counts']
    lines = ['# Adapt report: %s' % label, '',
             '**%d files written. %d names changed by the adapter. %d places need a decision.**' % (counts['files'], counts['renames'], counts['judgment']), '',
             'This folder is a copy. Nothing in `force-app/` was edited and no org was called. Work through "Needs judgment" below, in these files, then deploy this folder with its tests.', '']
    if report['only']:
        lines += ['Narrowed to: %s, and the code they need.' % ', '.join('`%s`' % one for one in report['only']), '']
    lines += ['## Done by the adapter', '']
    words = {'object': 'object names', 'field': 'field names', 'relationship': 'relationship names', 'record type': 'record types', 'picklist value': 'picklist values',
             'class name': 'class and trigger names', 'component name': 'component names', 'flow name': 'flow names', 'file name': 'files renamed'}
    for number, (kind, count) in enumerate(sorted(report['renamed'].items(), key=lambda item: -item[1]), 1):
        lines.append('%d. %d %s.' % (number, count, words.get(kind, kind)))
    if not report['renamed']:
        lines.append('Nothing needed renaming.')
    lines += ['', 'What each of ours became:', '', '| Ours | In this copy |', '|---|---|']
    seen = set()
    for item in report['renames']:
        pair = (item['from'], item['to'])
        if pair not in seen and item['kind'] != 'file name':
            seen.add(pair)
            lines.append('| `%s` | `%s` |' % pair)
    if report['created']:
        lines += ['', 'Created beside theirs, as the mapping asked (our own files, to deploy with the rest):', ''] + ['%d. `%s`' % (number, path) for number, path in enumerate(report['created'], 1)]
    lines += ['', 'Every single change, with its file and line, is in `adapt-report.json` under "renames". Picklist values and record types were changed where a string was exactly the value: read those lines.', '']
    lines += ['## Needs judgment', '']
    if not report['judgment']:
        lines.append('Nothing was flagged. Read the files all the same before deploying.')
    by_kind = {}
    for item in report['judgment']:
        by_kind.setdefault(item['kind'], []).append(item)
    titles = {'type differs': 'A type that differs', 'no such field': 'A field the org does not have', 'required': 'Required in the org', 'left out': 'Left out by the mapping',
              'record type': 'A record type the org does not have as one', 'picklist value': 'A picklist value with no match', 'which object': 'A field that could be on one of two objects',
              'object or field': 'A name that is both an object and a field', 'child relationship': 'A child relationship with no name in the org', 'test builds records': 'A test that builds records',
              'name is a number': 'A name that is an auto number in the org', 'created beside theirs': 'Ours created beside theirs', 'access': 'Access', 'names': 'Names',
              'not in the mapping': 'A field of ours the mapping does not mention', 'needs ours': 'Something of ours that is not in the copy', 'carried as it is': 'A file of ours carried as it is',
              'still says Antsurance': 'Text that still says Antsurance'}
    for kind, items in sorted(by_kind.items(), key=lambda item: -len(item[1])):
        lines += ['### %s (%d)' % (titles.get(kind, kind), len(items)), '']
        for number, item in enumerate(items, 1):
            lines.append('%d. `%s`%s' % (number, item['file'], ', line %d' % item['line'] if item['line'] else ''))
            lines.append('   %s' % item['why'])
        lines.append('')
    if not report['typesChecked']:
        lines += ['Types were not compared: no pulled metadata was given (`--org-metadata`). Give the folder the preflight wrote, or put `"type"` beside a field in the mapping, and run again.', '']
    lines += ['## Rules for finishing it', '',
              '1. What is in this folder is the org\'s own now. It follows the org\'s conventions, and it is theirs to keep.',
              '2. Nothing of the org\'s is renamed or altered to make this fit without a yes from the person.',
              '3. The kit\'s own files are not edited.',
              '4. Something flagged here is never made to pass by deleting a test or an assertion. Change the test so that it builds the org\'s own records and still proves the same thing.',
              '5. Deploy with the tests named, and hold every class and trigger to 75 percent.', '']
    return '\n'.join(lines)


def run():
    parser = argparse.ArgumentParser(description='Write a copy of one part of the app that names an org\'s own objects and fields.')
    parser.add_argument('--capability', required=True, metavar='PART')
    parser.add_argument('--mapping', required=True, help='The mapping file. mapping.example.json shows the format.')
    parser.add_argument('--out', default='adapted', help='The folder to write (default adapted/). It is replaced when this script wrote it before.')
    parser.add_argument('--org-metadata', help='The org\'s pulled metadata (.install/org-metadata/<alias>), to compare field types with ours')
    parser.add_argument('--check', action='store_true', help='Only say whether the mapping is complete. Writes nothing.')
    args = parser.parse_args()
    if not os.path.exists(args.mapping):
        raise SetupError('%s is not there. Copy scripts/setup/mapping.example.json and fill it in.' % args.mapping)
    with open(args.mapping, encoding='utf-8') as handle:
        mapping = json.load(handle)
    if mapping.get('capability') and mapping['capability'] != args.capability:
        raise SetupError('The mapping says it is for "%s" and the command says "%s".' % (mapping['capability'], args.capability))
    out = os.path.abspath(args.out)
    if out.startswith(os.path.join(KIT_ROOT, 'force-app')) or out.startswith(os.path.join(KIT_ROOT, 'optional')) or out.startswith(os.path.join(KIT_ROOT, 'slices')):
        raise SetupError('The copy cannot be written into the kit\'s own metadata folders. Name a folder of its own, such as adapted/.')
    conventions = None
    path = os.path.join(KIT_ROOT, 'org-conventions.json')
    if os.path.exists(path):
        with open(path, encoding='utf-8') as handle:
            conventions = json.load(handle)
    report = adapt(args.capability, mapping, out, args.org_metadata, conventions, args.check)
    if args.check:
        print('The mapping covers everything "%s" names (%d components). Run again without --check to write the copy.' % (capabilities.named(args.capability)['label'], len(report['nodes'])))
        return
    counts = report['counts']
    print('Wrote %d files to %s.' % (counts['files'], os.path.relpath(out)))
    print('Done by the adapter: %d names changed (%s).' % (counts['renames'], ', '.join('%d %s' % (count, kind) for kind, count in sorted(report['renamed'].items(), key=lambda item: -item[1])) or 'none'))
    print('Needs judgment: %d places (%s).' % (counts['judgment'], ', '.join('%d %s' % (count, kind) for kind, count in sorted(report['judgmentByKind'].items(), key=lambda item: -item[1])) or 'none'))
    print('Read %s next. Nothing in force-app/ was edited and no org was called.' % os.path.relpath(os.path.join(out, 'ADAPT-REPORT.md')))


if __name__ == '__main__':
    main(run)
