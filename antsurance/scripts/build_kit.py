#!/usr/bin/env python3
"""Builds the customer kit: dist/antsurance-kit/ and dist/antsurance-kit.zip.

    python3 -I scripts/build_kit.py            build, then scan; exits non-zero if the scan finds anything
    python3 -I scripts/build_kit.py --scan     scan an already built kit again
    python3 -I scripts/build_kit.py --dist DIR build into DIR instead of dist/, so two builds at once do not collide

The kit is what a customer unpacks and opens in Claude Code. It holds the metadata, split into install phases,
the installer (kit/ in this repo, laid at the kit's root), and nothing internal. What goes where:

  force-app/                 core: safe to deploy into an org that already has a life of its own
  optional/value-sets/       our values for five standard picklists; the installer merges them into the org's own
  optional/settings/         Quotes and Path switches; deployed only when asked for
  optional/look-and-feel/    theme, branding, object renames, search layouts, restyled stock list views
  optional/portal/           the customer portal: site, portal code, portal profile
  skills/                    the coverage agent's skill, as source; the same text ships in core as a static resource,
                             and the optional setup step uploads it to the customer's own Anthropic workspace
  slices/<name>/             a part of the app that installs alone, complete in its own folder. scripts/kit_capabilities.json
                             says what each takes from core; slices/<name>/ in this repo holds what it adds or replaces.
                             The build fails unless every class, component, object, field and resource a slice names
                             is inside it.
  capabilities/<name>/       one folder for each choice on the install menu (scripts/kit_capabilities.json): what it holds,
                             what it brings with it, its tests, and a permission set that grants only what it holds, cut
                             from ours. The sets cut from force-app/ are worked out by scanning the kit
                             (scripts/kit_scan.py, written out as kit-scan.json), and the build fails unless each stands alone.
  (dropped)                  the Admin profile, and everything outside force-app and kit/

On the way through, the build rewrites every street address in the seed to an invented one, rounds the map
coordinates that went with the real ones, replaces this org's usernames with blanks the installer fills in,
shares our reports and list views with a group of ours instead of with everyone, and makes the seed's clear()
refuse to run in a sandbox. Then it scans every file and fails loudly, naming file and line, on anything that
must not leave: this org, record ids, local paths, the owner, internal words, key-shaped strings, real addresses,
and em dashes in documents a customer reads.
"""
import json
import os
import re
import shutil
import sys
import zipfile
from datetime import date

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
SRC = os.path.join(ROOT, 'force-app', 'main', 'default')
KIT_SRC = os.path.join(ROOT, 'kit')
DIST = os.path.abspath(sys.argv[sys.argv.index('--dist') + 1]) if '--dist' in sys.argv[:-1] else os.path.join(ROOT, 'dist')
OUT = os.path.join(DIST, 'antsurance-kit')
CORE = os.path.join(OUT, 'force-app', 'main', 'default')
SKILLS_SRC = os.path.join(ROOT, 'skills')
# Each skill that Apex uploads from a static resource: (folder under skills/, static resource file under staticresources/).
UPLOADED_SKILLS = [('antsurance-coverage', 'antsuranceCoverageSkill.txt')]
OPTIONAL = os.path.join(OUT, 'optional')
CAPABILITIES_FILE = os.path.join(ROOT, 'scripts', 'kit_capabilities.json')
CAPABILITIES_OUT = os.path.join(OUT, 'capabilities')
SLICES_OUT = os.path.join(OUT, 'slices')
sys.path.insert(0, os.path.join(ROOT, 'scripts'))
import kit_scan  # noqa: E402
# Where each kind of thing a slice takes from core lives, and the files that make up one of them.
SLICE_KINDS = {
    'classes': ('classes', ['%s.cls', '%s.cls-meta.xml']),
    'testClasses': ('classes', ['%s.cls', '%s.cls-meta.xml']),
    'lwc': ('lwc', ['%s/']),
    'staticresources': ('staticresources', ['%s.resource-meta.xml', '%s*']),
    'objects': ('objects', ['%s/']),
    'customMetadata': ('customMetadata', ['%s.md-meta.xml']),
    'namedCredentials': ('namedCredentials', ['%s.namedCredential-meta.xml']),
    'externalCredentials': ('externalCredentials', ['%s.externalCredential-meta.xml']),
    'flexipages': ('flexipages', ['%s.flexipage-meta.xml']),
    'tabs': ('tabs', ['%s.tab-meta.xml']),
}
# The Metadata API name of what each folder of a slice holds, for removing a slice again.
SLICE_TYPES = [
    ('applications', '.app-meta.xml', 'CustomApplication'), ('permissionsets', '.permissionset-meta.xml', 'PermissionSet'),
    ('tabs', '.tab-meta.xml', 'CustomTab'), ('flexipages', '.flexipage-meta.xml', 'FlexiPage'), ('lwc', None, 'LightningComponentBundle'),
    ('classes', '.cls', 'ApexClass'), ('customMetadata', '.md-meta.xml', 'CustomMetadata'), ('objects', None, 'CustomObject'),
    ('namedCredentials', '.namedCredential-meta.xml', 'NamedCredential'), ('externalCredentials', '.externalCredential-meta.xml', 'ExternalCredential'),
    ('staticresources', '.resource-meta.xml', 'StaticResource'),
]

STANDARD_OBJECTS = {'Account', 'Case', 'Contact', 'Lead', 'Opportunity', 'Quote', 'Task', 'User'}
# Stock list views this org restyled. They belong to the org, so a customer only gets them with the look and feel.
STOCK_LIST_VIEWS = {'AllAccounts', 'AllContacts', 'AllOpportunities', 'AllOpenLeads', 'OpenTasks', 'AllCases', 'AllLeads'}
GROUP = 'Antsurance_Users'
BINARY = ('.jpg', '.jpeg', '.png', '.gif', '.pdf', '.woff', '.woff2', '.ttf', '.otf', '.ico', '.zip', '.asset', '.webp', '.mp4')
INSERTS_INTO = ['Account', 'Contact', 'Case', 'Opportunity', 'Quote', 'Task', 'Lead']

# American spelling in everything a customer reads. scripts/ui_checks/us_spelling.py is the shared checker and is run
# as well when it exists; this list is the kit's own floor.
BRITISH = re.compile(r'\b(analys(e|ed|es|ing)|organis\w+|summaris\w+|licen[c]e\w*|centre\w*|behaviour\w*|labell\w+|modell\w+|grey|colour\w*|cancell\w+|recognis\w+|'
                     r'favour\w*|neighbour\w*|catalogue|programme|defence|honour\w*|customis\w+|prioritis\w+|initialis\w+|normalis\w+|optimis\w+|authoris\w+|'
                     r'apologis\w+|realis\w+|minimis\w+|travell\w+|judgement|whilst|learnt|artefact\w*)\b', re.I)
SHARED_SPELLING_CHECK = os.path.join(ROOT, 'scripts', 'ui_checks', 'us_spelling.py')

STREET = re.compile(r"\b\d{1,5} (?:[NSEW] )?(?:(?:[A-Z][A-Za-z]+|\d+(?:st|nd|rd|th)) ){1,3}(?:St|Ave|Rd|Blvd|Ln|Dr|Ct|Way|Pl|Pkwy|Hwy)\b(?: (?:Apt|Ste|Unit) \w+)?")
INVENTED = ('Alderquill Bellmarrow Copperfen Dunwillow Eastmantle Fallowgate Greywick Hollowmere Islewood Jadebarrow Kettlefold Lowquay Mistleholt '
            'Northlantern Oxbeck Plumwick Quietfold Ravenquay Stonewillow Tidemantle Underholt Vinebarrow Westquill Yewlantern Zinniafold Ashmarrow '
            'Brookmantle Cloverquay Driftbarrow Elmlantern Frostwick Glenmarrow Harborquill Ivyfold Junebarrow Knollwick Lakemantle Meadowquay').split()


def fail(message):
    print('BUILD FAILED: ' + message, file=sys.stderr)
    sys.exit(1)


def read(path):
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as handle:
        handle.write(text)


def is_binary(path):
    return path.lower().endswith(BINARY)


# ---------------------------------------------------------------- where each source file goes

def route(rel):
    """Returns (bucket, path inside the bucket) for a file under force-app/main/default, or (None, reason) to drop it."""
    parts = rel.split('/')
    top = parts[0]
    name = parts[-1]
    if rel == 'profiles/Admin.profile-meta.xml':
        return None, 'the Admin profile never goes to a customer'
    if top in ('networks', 'sites', 'digitalExperiences', 'digitalExperienceConfigs', 'platformEventSubscriberConfigs', 'profiles'):
        return 'portal', rel
    if top == 'settings':
        if name.startswith('Communities'):
            return 'portal', rel
        if name.startswith('LightningExperience'):
            return 'look-and-feel', rel
        return 'settings', name
    if top == 'standardValueSets':
        return 'value-sets', rel
    if top in ('lightningExperienceThemes', 'brandingSets', 'objectTranslations'):
        return 'look-and-feel', rel
    if top == 'objects' and len(parts) >= 3 and parts[1] in STANDARD_OBJECTS:
        if name == parts[1] + '.object-meta.xml':
            return 'look-and-feel', rel
        if parts[2] == 'listViews' and name.split('.')[0] in STOCK_LIST_VIEWS:
            return 'look-and-feel', rel
    if (top == 'classes' and name.startswith('AntsurancePortal')) or (top == 'lwc' and parts[1].startswith('antsurancePortal')) \
            or (top == 'triggers' and name.startswith('AntsurancePortal')) or (top == 'objects' and parts[1] == 'Antsurance_Portal_Submission__e') \
            or (top == 'permissionsets' and name.startswith('Antsurance_Portal')):
        return 'portal', rel
    return 'core', rel


def destination(bucket, inner):
    if bucket == 'core':
        return os.path.join(CORE, inner)
    return os.path.join(OPTIONAL, bucket, inner)


# ---------------------------------------------------------------- addresses

def collect_addresses():
    """Every street address in the source Apex, the households keyed as the seed keys them, and the precise coordinates."""
    seed = read(os.path.join(SRC, 'classes', 'AntsuranceDemoData.cls'))
    by_key = {}
    for match in re.finditer(r"household\('(\w+)', '[^']+', '([^']+)'", seed):
        by_key[match.group(1)] = match.group(2)
    rows = seed[seed.index('HOUSEHOLD_ROWS = new List<String>{'):seed.index('BUSINESS_ROWS')]
    for match in re.finditer(r"'(\w+)\|[^|]*\|[^|]*\|[^|]*\|([^|]+)\|", rows):
        by_key[match.group(1)] = match.group(2)
    coordinates = {}
    block = seed[seed.index('ADDRESS_COORDINATES = new Map'):]
    block = block[:block.index('};')]
    for match in re.finditer(r"'([^']+)' => new List<Decimal>\{ (-?[\d.]+), (-?[\d.]+) \}", block):
        coordinates[match.group(1)] = (match.group(2), match.group(3))
    streets = set(by_key.values()) | set(coordinates)
    for path in sorted(os.listdir(os.path.join(SRC, 'classes'))):
        if path.endswith('.cls'):
            streets |= set(STREET.findall(read(os.path.join(SRC, 'classes', path))))
    samples_class = read(os.path.join(SRC, 'classes', 'AntsuranceDemoAddresses.cls'))
    sample_by_key = dict(re.findall(r"'(\w+)' => '([^']+)'", samples_class))
    invented = set(sample_by_key.values())
    streets -= invented
    # Test fixtures that are plainly not places.
    streets = {street for street in streets if not re.match(r'\d+ (Test|Given|Trade|Main|Example|Sample) ', street)}
    return by_key, coordinates, streets, sample_by_key


def address_plan(by_key, coordinates, streets, sample_by_key):
    """real street -> invented street, for every street; and precise coordinate -> rounded."""
    mapping = {}
    for key, street in by_key.items():
        if key not in sample_by_key:
            fail('household "%s" has no invented street in AntsuranceDemoAddresses. Add one.' % key)
        mapping[street] = sample_by_key[key]
    others = sorted(streets - set(mapping))
    if len(others) > len(INVENTED):
        fail('%d streets need an invented name and only %d names are listed in build_kit.py.' % (len(others), len(INVENTED)))
    for index, street in enumerate(others):
        match = re.match(r"(\d+) (?:[NSEW] )?(.+?) (St|Ave|Rd|Blvd|Ln|Dr|Ct|Way|Pl|Pkwy|Hwy)((?: (?:Apt|Ste|Unit) \w+)?)$", street)
        if not match:
            fail('cannot parse the street "%s"' % street)
        mapping[street] = '%d %s %s%s' % (120 + (index * 173 + 59) % 870, INVENTED[index], match.group(3), match.group(4))
    numbers = {}
    for latitude, longitude in coordinates.values():
        for value in (latitude, longitude):
            numbers[value] = '%.2f' % float(value)
    return mapping, numbers


def without_suffix(street):
    return re.sub(r" (St|Ave|Rd|Blvd|Ln|Dr|Ct|Way|Pl|Pkwy|Hwy)((?: (?:Apt|Ste|Unit) \w+)?)$", '', street)


def rewrite_addresses(text, mapping, numbers):
    for real in sorted(mapping, key=len, reverse=True):
        text = text.replace(real, mapping[real])
    for real in sorted(mapping, key=len, reverse=True):
        short = without_suffix(real)
        if short != real and short in text:
            text = re.sub(r'\b%s\b' % re.escape(short), without_suffix(mapping[real]), text)
    for precise, rounded in numbers.items():
        text = re.sub(r'(?<![\d.])%s(?![\d])' % re.escape(precise), rounded, text)
    text = text.replace('real addresses', 'sample addresses').replace('real address', 'sample address').replace('the actual home', 'the sample home')
    return text


# ---------------------------------------------------------------- transforms

# Nothing is reworded on the way into the kit any more: a name, a path into this repo's notes or a British
# spelling is fixed in the source file, and the scan below fails the build if one comes back.
SCRUB = []


def transform(rel, bucket, text, context):
    mapping, numbers = context['addresses']
    for pattern, replacement in SCRUB:
        text = pattern.sub(replacement, text)
    if bucket == 'portal' and rel.endswith('content.json') and '/sfdc_cms__styles/' in rel:
        # The stored file id belongs to the org it was read from. The style sheet itself travels beside this file.
        sheet = next((name for name in os.listdir(os.path.join(SRC, os.path.dirname(rel))) if name.endswith('.css')), None)
        if sheet:
            text = re.sub(r'("ref"\s*:\s*")[0-9A-Za-z]{15,18}(")', r'\g<1>%s\g<2>' % sheet, text)
    if rel.startswith('classes/') or rel.startswith('lwc/') or rel.startswith('staticresources/'):
        text = rewrite_addresses(text, mapping, numbers)
    if rel.startswith('staticresources/') and rel.endswith(('.md', '.txt')):
        text = american(text)
    if rel == 'classes/AntsuranceDemoData.cls':
        check_clear(text)
    if rel.startswith('dashboards/') and rel.endswith('.dashboard-meta.xml'):
        # A dashboard that runs as a named person names this org's user. In the kit it runs as whoever installs.
        # The source keeps at most three that run as the viewer, which is what a new Developer Edition org allows.
        if '<dashboardType>SpecifiedUser</dashboardType>' in text:
            if len(re.findall(r'<runningUser>[^<]*</runningUser>', text)) != 1:
                fail('the dashboard %s runs as a named person but does not name one the way build_kit.py expects.' % rel)
            text = re.sub(r'<runningUser>[^<]*</runningUser>', '<runningUser>{{RUNNING_USER}}</runningUser>', text)
        elif '<dashboardType>LoggedInUser</dashboardType>' in text:
            context['viewer_dashboards'].append(rel)
        else:
            fail('the dashboard %s does not say who it runs as.' % rel)
    if rel.startswith('applications/'):
        logo = re.search(r'<logo>([^<]+)</logo>', text)
        if logo and not os.path.exists(os.path.join(SRC, 'contentassets', logo.group(1) + '.asset-meta.xml')):
            # The app's logo must be a file that travels with the kit. Name one in contentassets/ in scripts/gen_pages.py.
            fail('the app names the logo "%s", which is not in contentassets/, so it would not exist in a customer\'s org.' % logo.group(1))
    if bucket == 'core' and rel.startswith('permissionsets/'):
        # Portal code installs with the portal. The portal phase carries the full permission set.
        text = re.sub(r'[ \t]*<classAccesses>\s*<apexClass>AntsurancePortal\w*</apexClass>.*?</classAccesses>\n', '', text, flags=re.S)
    if rel.endswith('Folder-meta.xml'):
        text = re.sub(r'<folderShares>.*?</folderShares>', '<folderShares>\n        <accessLevel>View</accessLevel>\n        <sharedTo>%s</sharedTo>\n        <sharedToType>Group</sharedToType>\n    </folderShares>' % GROUP, text, flags=re.S)
        if GROUP not in text:
            text = text.replace('    <name>', '    <folderShares>\n        <accessLevel>View</accessLevel>\n        <sharedTo>%s</sharedTo>\n        <sharedToType>Group</sharedToType>\n    </folderShares>\n    <name>' % GROUP, 1)
    parts = rel.split('/')
    if bucket == 'core' and parts[0] == 'objects' and parts[1] in STANDARD_OBJECTS and len(parts) > 3 and parts[2] == 'listViews' and '<sharedTo>' not in text:
        text = text.replace('</ListView>', '    <sharedTo>\n        <group>%s</group>\n    </sharedTo>\n</ListView>' % GROUP)
    if bucket == 'portal':
        text = re.sub(r'<user>[^<]*</user>', '<user>{{RUNNING_USER}}</user>', text)
        text = re.sub(r'<siteAdmin>[^<]*</siteAdmin>', '<siteAdmin>{{RUNNING_USER}}</siteAdmin>', text)
        text = re.sub(r'<siteGuestRecordDefaultOwner>[^<]*</siteGuestRecordDefaultOwner>', '<siteGuestRecordDefaultOwner>{{RUNNING_USER}}</siteGuestRecordDefaultOwner>', text)
        text = re.sub(r'<emailSenderAddress>[^<]*</emailSenderAddress>', '<emailSenderAddress>{{SENDER_EMAIL}}</emailSenderAddress>', text)
    return text


def american(text):
    """American spelling for the notes that travel with the sample photos and fonts. Links are left alone."""
    words = {'licence': 'license', 'licences': 'licenses', 'licenced': 'licensed', 'centre': 'center', 'centred': 'centered', 'mouldy': 'moldy', 'colour': 'color', 'colours': 'colors', 'grey': 'gray'}

    def swap(match):
        word = match.group(0)
        new = words[word.lower()]
        return new.upper() if word.isupper() else new.capitalize() if word[0].isupper() else new
    return re.sub(r'(?<![/\w.-])(%s)(?![/\w-])' % '|'.join(sorted(words, key=len, reverse=True)), swap, text, flags=re.I)


def check_clear(text):
    """clear() deletes by object, so it may run only in a scratch org or a Developer Edition org, never in a sandbox
    holding a copy of real records. The class carries that guard itself; this fails the build if it goes."""
    guard = "Boolean isThrowaway = (org.IsSandbox && org.TrialExpirationDate != null) || org.OrganizationType == 'Developer Edition';"
    if text.count(guard) != 1 or text.count('if (!isThrowaway && !Test.isRunningTest()) {') != 1:
        fail('AntsuranceDemoData.clear() no longer refuses to run outside a scratch org or a Developer Edition org. Put the guard back before building a kit.')


# ---------------------------------------------------------------- copy

def copy_installer():
    for folder, dirs, files in os.walk(KIT_SRC):
        dirs[:] = [name for name in dirs if name not in ('__pycache__', 'stage', '.install')]
        for name in files:
            if name in ('.DS_Store', 'setup-report.md', 'setup-report.json', 'install-report.md', 'org-conventions.md', 'org-conventions.json') or name.endswith('.pyc'):
                continue
            source = os.path.join(folder, name)
            target = os.path.join(OUT, os.path.relpath(source, KIT_SRC))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target)


def copy_skills():
    """The skills the app uploads to Claude Managed Agents, as readable text at the kit's root.

    Apex uploads the static resource, not this folder, so the two must hold the same words: a skill someone edits in
    one place and not the other would upload something other than what they read. In the source that is checked. In
    the kit it is true by construction: the readable copy is the built static resource itself, copied byte for byte
    after copy_metadata() has put it through the address and spelling passes.
    """
    for folder, resource in UPLOADED_SKILLS:
        source = os.path.join(SKILLS_SRC, folder, 'SKILL.md')
        uploaded = os.path.join(SRC, 'staticresources', resource)
        if not os.path.exists(source) or not os.path.exists(uploaded):
            fail('the skill %s needs both skills/%s/SKILL.md and staticresources/%s.' % (folder, folder, resource))
        if read(source) != read(uploaded):
            fail('skills/%s/SKILL.md and staticresources/%s differ. They must be the same file: copy the one you changed over the other, then deploy the static resource.' % (folder, resource))
        # Apex uploads that one file and nothing else. A second file here would be read by people and never reach the agent.
        extra = sorted(name for name in os.listdir(os.path.join(SKILLS_SRC, folder)) if name not in ('SKILL.md', '.DS_Store'))
        if extra:
            fail('skills/%s holds more than SKILL.md (%s). Only the static resource %s is uploaded, so the kit carries that one file.' % (folder, ', '.join(extra), resource))
        target = os.path.join(OUT, 'skills', folder, 'SKILL.md')
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(os.path.join(CORE, 'staticresources', resource), target)
    return len(UPLOADED_SKILLS)


def copy_metadata(context):
    counts, dropped = {}, []
    for folder, dirs, files in os.walk(SRC):
        dirs[:] = sorted(name for name in dirs if name != '__tests__')
        for name in sorted(files):
            if name == '.DS_Store' or name in ('jsconfig.json', '.eslintrc.json'):
                continue
            source = os.path.join(folder, name)
            rel = os.path.relpath(source, SRC).replace(os.sep, '/')
            bucket, inner = route(rel)
            if bucket is None:
                dropped.append('%s (%s)' % (rel, inner))
                continue
            target = destination(bucket, inner)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if is_binary(source):
                shutil.copyfile(source, target)
            else:
                try:
                    text = read(source)
                except UnicodeDecodeError:
                    shutil.copyfile(source, target)
                else:
                    write(target, transform(rel, bucket, text, context))
            counts[bucket] = counts.get(bucket, 0) + 1
            if bucket == 'core' and rel.startswith('permissionsets/') and not is_binary(source) and 'AntsurancePortal' in read(source):
                # The same permission set, unstripped, goes with the portal so staff can open the portal's own screens.
                write(destination('portal', rel), transform(rel, 'portal', read(source), context))
                counts['portal'] = counts.get('portal', 0) + 1
    return counts, dropped


def generated_files():
    write(os.path.join(CORE, 'groups', GROUP + '.group-meta.xml'),
          '<?xml version="1.0" encoding="UTF-8"?>\n<Group xmlns="http://soap.sforce.com/2006/04/metadata">\n    <doesIncludeBosses>false</doesIncludeBosses>\n    <name>Antsurance Users</name>\n</Group>\n')
    project = json.load(open(os.path.join(ROOT, 'sfdx-project.json')))
    version = project.get('sourceApiVersion', '67.0')
    write(os.path.join(OUT, 'sfdx-project.json'), json.dumps({
        'packageDirectories': [{'path': 'force-app', 'default': True}], 'name': 'antsurance', 'namespace': '',
        'sfdcLoginUrl': 'https://login.salesforce.com', 'sourceApiVersion': version}, indent=2) + '\n')
    write(os.path.join(OUT, '.forceignore'), read(os.path.join(ROOT, '.forceignore')).rstrip() + '\n')
    write(os.path.join(OUT, '.gitignore'), 'stage/\n.install/\nsetup-report.md\nsetup-report.json\ninstall-report.md\norg-conventions.md\norg-conventions.json\n.sf/\n.sfdx/\n__pycache__/\n')
    notes = os.path.join(OUT, 'licenses')
    for folder, _, files in os.walk(os.path.join(CORE, 'staticresources')):
        for name in files:
            if name.upper().startswith(('LICENSE', 'LICENCE', 'SOURCES', 'NOTICE', 'ATTRIBUTION')) or name.lower() in ('readme.md', 'sources.md', 'credits.md'):
                label = os.path.basename(folder)
                os.makedirs(notes, exist_ok=True)
                shutil.copyfile(os.path.join(folder, name), os.path.join(notes, '%s-%s' % (label, name)))
    return version


# ---------------------------------------------------------------- slices: a part of the app that installs alone

def load_capabilities():
    if not os.path.exists(CAPABILITIES_FILE):
        fail('scripts/kit_capabilities.json is missing: it is the list of what a person can choose to install.')
    return json.load(open(CAPABILITIES_FILE, encoding='utf-8'))


def load_slices():
    """The choices that are a part with a folder of its own."""
    return {name: spec for name, spec in load_capabilities()['capabilities'].items() if spec.get('kind') == 'slice'}


def copy_tree(source, target):
    for folder, dirs, files in os.walk(source):
        dirs[:] = sorted(name for name in dirs if name != '__tests__')
        for name in sorted(files):
            if name == '.DS_Store':
                continue
            to_path = os.path.join(target, os.path.relpath(os.path.join(folder, name), source))
            os.makedirs(os.path.dirname(to_path), exist_ok=True)
            shutil.copyfile(os.path.join(folder, name), to_path)


def compose_slice(name, spec):
    """Lays a slice out under slices/<name>/main/default: what it takes from the built core, then its own files."""
    target = os.path.join(SLICES_OUT, name, 'main', 'default')
    for kind, members in sorted(spec.get('fromCore', {}).items()):
        if kind not in SLICE_KINDS:
            fail('the slice "%s" takes "%s" from core, which build_kit.py does not know how to copy.' % (name, kind))
        folder, patterns = SLICE_KINDS[kind]
        for member in members:
            found = False
            for pattern in patterns:
                wanted = pattern % member
                base = os.path.join(CORE, folder)
                if wanted.endswith('/'):
                    if os.path.isdir(os.path.join(base, member)):
                        copy_tree(os.path.join(base, member), os.path.join(target, folder, member))
                        found = True
                elif wanted.endswith('*'):
                    # A static resource is one file of any type, or a folder, beside its meta file.
                    for entry in sorted(os.listdir(base)) if os.path.isdir(base) else []:
                        if entry == member or (entry.startswith(member + '.') and not entry.endswith('.resource-meta.xml')):
                            source = os.path.join(base, entry)
                            if os.path.isdir(source):
                                copy_tree(source, os.path.join(target, folder, entry))
                            else:
                                os.makedirs(os.path.join(target, folder), exist_ok=True)
                                shutil.copyfile(source, os.path.join(target, folder, entry))
                elif os.path.exists(os.path.join(base, wanted)):
                    os.makedirs(os.path.join(target, folder), exist_ok=True)
                    shutil.copyfile(os.path.join(base, wanted), os.path.join(target, folder, wanted))
                    found = True
            if not found:
                fail('the slice "%s" names %s "%s", which is not in the kit\'s core.' % (name, kind, member))
    own = os.path.join(ROOT, spec['own'], 'main', 'default') if spec.get('own') else None
    replaces = list(spec.get('replaces', []))
    used = set()
    for path in replaces:
        # What is replaced is replaced whole: nothing of core's version stays beside the slice's own.
        taken = os.path.join(target, path)
        if os.path.isdir(taken):
            shutil.rmtree(taken)
        elif os.path.exists(taken):
            os.remove(taken)
    if own and os.path.isdir(own):
        for folder, dirs, files in os.walk(own):
            dirs.sort()
            for file_name in sorted(files):
                if file_name == '.DS_Store':
                    continue
                rel = os.path.relpath(os.path.join(folder, file_name), own).replace(os.sep, '/')
                replaced = next((path for path in replaces if rel == path or rel.startswith(path + '/')), None)
                in_core = os.path.exists(os.path.join(CORE, rel))
                if in_core and not replaced:
                    fail('the slice "%s" has its own %s, which is also in core. List it under "replaces" in scripts/kit_capabilities.json if that is meant.' % (name, rel))
                if replaced:
                    used.add(replaced)
                to_path = os.path.join(target, rel)
                os.makedirs(os.path.dirname(to_path), exist_ok=True)
                shutil.copyfile(os.path.join(folder, file_name), to_path)
    for path in replaces:
        if path not in used:
            fail('the slice "%s" says it replaces %s, but has no such file of its own under %s.' % (name, path, spec.get('own')))
        if not os.path.exists(os.path.join(CORE, path)):
            fail('the slice "%s" says it replaces %s, which core does not have. Take it out of "replaces".' % (name, path))
    extra = os.path.join(ROOT, spec['own'], 'scratch-def.json') if spec.get('own') else None
    if extra and os.path.exists(extra):
        shutil.copyfile(extra, os.path.join(SLICES_OUT, name, 'scratch-def.json'))
    return target


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


CUSTOM_NAME = re.compile(r'\b[A-Za-z][A-Za-z0-9_]*__(?:c|r|mdt|e|s|x|b)\b')
# Words written for people (a description, help text, a label) name things without needing them.
PLAIN_WORDS = re.compile(r'<(description|inlineHelpText|helpText|comment|info|label|masterLabel|errorMessage|fieldText|pausedText|relationshipLabel|pluralLabel)>.*?</\1>', re.S)


def our_model():
    """Every custom name the full app defines: objects, fields, relationships, and record type names."""
    names, record_types = set(), set()
    objects = os.path.join(SRC, 'objects')
    for name in sorted(os.listdir(objects)):
        if '__' in name:
            names.add(name)
            names.add(re.sub(r'__(c|mdt|e)$', '__r', name))
        fields = os.path.join(objects, name, 'fields')
        for field in names_in(fields, '.field-meta.xml'):
            names.add(field)
            names.add(re.sub(r'__c$', '__r', field))
            for relationship in re.findall(r'<relationshipName>(\w+)</relationshipName>', read(os.path.join(fields, field + '.field-meta.xml'))):
                names.add(relationship + '__r')
        record_types |= set(names_in(os.path.join(objects, name, 'recordTypes'), '.recordType-meta.xml'))
    return names, record_types


def check_slice(name, spec, root):
    """Everything a slice names must be inside it. Returns the problems, one line each; an empty list means it stands alone.

    The same check proves a capability cut from force-app/ (build_capabilities lays its files out in a folder first):
    there it also reads triggers, flows, quick actions, layouts, paths, document pages and the objects themselves.
    """
    problems = []

    def here(folder, suffix):
        return set(names_in(os.path.join(root, folder), suffix))
    classes = here('classes', '.cls')
    bundles = set(os.listdir(os.path.join(root, 'lwc'))) if os.path.isdir(os.path.join(root, 'lwc')) else set()
    auras = set(os.listdir(os.path.join(root, 'aura'))) if os.path.isdir(os.path.join(root, 'aura')) else set()
    flows, quick_actions, vf_pages, assets = here('flows', '.flow-meta.xml'), here('quickActions', '.quickAction-meta.xml'), here('pages', '.page'), here('contentassets', '.asset-meta.xml')
    groups, value_sets = here('groups', '.group-meta.xml'), here('globalValueSets', '.globalValueSet-meta.xml')
    resources = here('staticresources', '.resource-meta.xml')
    tabs, pages, apps = here('tabs', '.tab-meta.xml'), here('flexipages', '.flexipage-meta.xml'), here('applications', '.app-meta.xml')
    credentials = here('externalCredentials', '.externalCredential-meta.xml')
    objects = set(os.listdir(os.path.join(root, 'objects'))) if os.path.isdir(os.path.join(root, 'objects')) else set()
    own_names = set(objects) | {re.sub(r'__(c|mdt|e)$', '__r', one) for one in objects}
    own_fields, own_record_types = set(), set()
    for one in objects:
        for field in names_in(os.path.join(root, 'objects', one, 'fields'), '.field-meta.xml'):
            own_names |= {field, re.sub(r'__c$', '__r', field)}
            own_fields.add('%s.%s' % (one, field))
            for relationship in re.findall(r'<relationshipName>(\w+)</relationshipName>', read(os.path.join(root, 'objects', one, 'fields', field + '.field-meta.xml'))):
                own_names.add(relationship + '__r')
        own_record_types |= set(names_in(os.path.join(root, 'objects', one, 'recordTypes'), '.recordType-meta.xml'))
    model, record_types = our_model()
    # A record type the set itself holds may be named; one it does not hold may not.
    record_types = record_types - own_record_types
    foreign = model - own_names
    all_classes = set(names_in(os.path.join(SRC, 'classes'), '.cls'))
    all_quick_actions = set(names_in(os.path.join(SRC, 'quickActions'), '.quickAction-meta.xml'))
    run_time = set(spec.get('foundAtRunTime', []))

    def custom_names(where, text):
        for found in sorted(set(CUSTOM_NAME.findall(text)) & foreign):
            problems.append('%s names %s, which belongs to the full app and is not in the slice' % (where, found))

    # Apex: no class outside the slice, none of our model's names even in a string, no record type of ours by name.
    triggers = here('triggers', '.trigger')
    for one, folder, suffix in [(one, 'classes', '.cls') for one in sorted(classes)] + [(one, 'triggers', '.trigger') for one in sorted(triggers)]:
        where = '%s/%s%s' % (folder, one, suffix)
        if not os.path.exists(os.path.join(root, folder, one + suffix + '-meta.xml')):
            problems.append('%s has no meta file' % where)
        code, strings = code_and_strings(read(os.path.join(root, folder, one + suffix)))
        quoted = '\n'.join(strings)
        for other in sorted(all_classes - classes):
            if re.search(r'\b%s\b' % re.escape(other), code):
                problems.append('%s uses the class %s, which is not in the slice' % (where, other))
            elif other not in run_time and re.search(r'\b%s\b' % re.escape(other), quoted):
                problems.append('%s names the class %s in a string. If it is looked up at run time on purpose, list it under "foundAtRunTime"' % (where, other))
        custom_names(where, code + '\n' + quoted)
        for record_type in sorted(record_types & set(strings)):
            problems.append("%s names the record type '%s', which only the full app has" % (where, record_type))
        for page in re.findall(r'\bPage\.(\w+)', code):
            if page not in vf_pages:
                problems.append('%s opens the page %s, which is not in the slice' % (where, page))
    for one in sorted(spec.get('fromCore', {}).get('testClasses', [])):
        if one not in classes or not is_test_class(os.path.join(root, 'classes', one + '.cls')):
            problems.append('%s is listed as a test class of the slice and is not one' % one)

    # Components: every import, child component, Apex method and static resource is in the slice.
    granted = set()
    for bundle in sorted(bundles):
        folder = os.path.join(root, 'lwc', bundle)
        if not os.path.exists(os.path.join(folder, bundle + '.js-meta.xml')):
            problems.append('lwc/%s has no meta file' % bundle)
        for file_name in sorted(os.listdir(folder)):
            path = os.path.join(folder, file_name)
            if os.path.isdir(path) or is_binary(path):
                continue
            where, text = 'lwc/%s/%s' % (bundle, file_name), read(path)
            needed = set(re.findall(r"""['"]c/(\w+)['"]""", text))
            if file_name.endswith('.html'):
                needed |= {re.sub(r'-(\w)', lambda m: m.group(1).upper(), tag) for tag in re.findall(r'<c-([a-z0-9-]+)', text)}
            for other in sorted(needed - bundles - auras):
                problems.append('%s uses the component %s, which is not in the slice' % (where, other))
            for apex, method in re.findall(r'@salesforce/apex/(\w+)\.(\w+)', text):
                granted.add(apex)
                if apex not in classes:
                    problems.append('%s calls %s.%s, and that class is not in the slice' % (where, apex, method))
                elif not re.search(r'@AuraEnabled[^;{]*\b%s\s*\(' % re.escape(method), read(os.path.join(root, 'classes', apex + '.cls')), re.S):
                    problems.append('%s calls %s.%s, which is not an @AuraEnabled method' % (where, apex, method))
            for resource in re.findall(r'@salesforce/resourceUrl/(\w+)', text):
                if resource not in resources:
                    problems.append('%s loads the static resource %s, which is not in the slice' % (where, resource))
            for kind in re.findall(r'@salesforce/(customPermission|label|messageChannel|contentAssetUrl)/', text):
                problems.append('%s imports a %s, which build_kit.py does not check for a slice' % (where, kind))
            custom_names(where, text)

    # Metadata: a tab's component, a page's components, an app's tabs and bar, what a permission set grants.
    def xml_values(folder, suffix, tag):
        for one in sorted(names_in(os.path.join(root, folder), suffix)):
            text = PLAIN_WORDS.sub('', read(os.path.join(root, folder, one + suffix)))
            custom_names('%s/%s' % (folder, one), text)
            for value in re.findall(r'<%s>([^<]+)</%s>' % (tag, tag), text):
                yield '%s/%s' % (folder, one), value.strip()
    for where, component in xml_values('tabs', '.tab-meta.xml', 'lwcComponent'):
        if component not in bundles:
            problems.append('%s shows the component %s, which is not in the slice' % (where, component))
    for where, component in xml_values('flexipages', '.flexipage-meta.xml', 'componentName'):
        ours = component[2:] if component.startswith('c:') else component if ':' not in component else None
        if ours and ours not in bundles and ours not in auras:
            problems.append('%s holds the component %s, which is not in the slice' % (where, ours))
    for where, tab in xml_values('applications', '.app-meta.xml', 'tabs'):
        if not tab.startswith('standard-') and tab not in tabs and tab not in objects:
            problems.append('%s lists the tab %s, which is not in the slice' % (where, tab))
    for tag, known, what in (('utilityBar', pages, 'utility bar'), ('content', pages, 'page'), ('logo', assets, 'logo')):
        for where, value in xml_values('applications', '.app-meta.xml', tag):
            if value not in known:
                problems.append('%s names the %s %s, which is not in the slice' % (where, what, value))
    permission_sets = here('permissionsets', '.permissionset-meta.xml')
    for tag, known, what in (('apexClass', classes, 'class'), ('application', apps, 'app'), ('tab', tabs | objects, 'tab'), ('apexPage', vf_pages, 'page'), ('flow', flows, 'flow'),
                             ('field', own_fields, 'field'), ('recordType', {'%s.%s' % (one, record_type) for one in objects for record_type in names_in(os.path.join(root, 'objects', one, 'recordTypes'), '.recordType-meta.xml')}, 'record type')):
        for where, value in xml_values('permissionsets', '.permissionset-meta.xml', tag):
            if value not in known and not value.startswith('standard-'):
                problems.append('%s grants the %s %s, which is not in the slice' % (where, what, value))
    for where, value in xml_values('permissionsets', '.permissionset-meta.xml', 'externalCredentialPrincipal'):
        if value.split('-')[0] not in credentials:
            problems.append('%s grants the credential %s, which is not in the slice' % (where, value))
    for where, value in xml_values('namedCredentials', '.namedCredential-meta.xml', 'externalCredential'):
        if value not in credentials:
            problems.append('%s uses the external credential %s, which is not in the slice' % (where, value))
    for record in sorted(names_in(os.path.join(root, 'customMetadata'), '.md-meta.xml')):
        kind = record.split('.')[0] + '__mdt'
        if kind not in objects:
            problems.append('customMetadata/%s is a record of %s, which is not in the slice' % (record, kind))
            continue
        fields = set(names_in(os.path.join(root, 'objects', kind, 'fields'), '.field-meta.xml'))
        for field in re.findall(r'<field>([^<]+)</field>', read(os.path.join(root, 'customMetadata', record + '.md-meta.xml'))):
            if field not in fields:
                problems.append('customMetadata/%s sets %s, a field the slice does not have' % (record, field))
    for one in sorted(resources):
        custom_names('staticresources/%s' % one, '')

    # What only a set cut from force-app/ holds: flows, buttons, layouts, paths, document pages, and the model itself.
    for where, action in xml_values('quickActions', '.quickAction-meta.xml', 'flowDefinition'):
        if action not in flows:
            problems.append('%s runs the flow %s, which is not in the slice' % (where, action))
    for where, component in xml_values('quickActions', '.quickAction-meta.xml', 'lightningWebComponent'):
        if component not in bundles:
            problems.append('%s opens the component %s, which is not in the slice' % (where, component))
    for one in sorted(flows):
        text = PLAIN_WORDS.sub('', read(os.path.join(root, 'flows', one + '.flow-meta.xml')))
        custom_names('flows/%s' % one, text)
        for block in re.findall(r'<actionCalls>.*?</actionCalls>', text, re.S):
            action, kind = (re.search(r'<actionName>([^<]+)<', block) or [None, ''])[1], (re.search(r'<actionType>([^<]+)<', block) or [None, ''])[1]
            if kind == 'apex' and action not in classes:
                problems.append('flows/%s calls the class %s, which is not in the slice' % (one, action))
            if kind == 'flow' and action not in flows:
                problems.append('flows/%s runs the flow %s, which is not in the slice' % (one, action))
        for component in re.findall(r'<extensionName>c:(\w+)<', text):
            if component not in bundles:
                problems.append('flows/%s shows the component %s, which is not in the slice' % (one, component))
        for record_type in sorted(record_types & set(re.findall(r'<stringValue>([^<]+)</stringValue>', text))) if 'RecordType' in text else []:
            problems.append("flows/%s names the record type '%s', which is not in the slice" % (one, record_type))
    for folder, suffix in (('layouts', '.layout-meta.xml'), ('pathAssistants', '.pathAssistant-meta.xml'), ('reportTypes', '.reportType-meta.xml')):
        for one in sorted(names_in(os.path.join(root, folder), suffix)):
            custom_names('%s/%s' % (folder, one), PLAIN_WORDS.sub('', read(os.path.join(root, folder, one + suffix))))
    for where, action in xml_values('layouts', '.layout-meta.xml', 'quickActionName'):
        if '.' in action and action not in quick_actions:
            problems.append('%s offers the action %s, which is not in the slice' % (where, action))
    for where, value in xml_values('flexipages', '.flexipage-meta.xml', 'value'):
        if re.fullmatch(r'\w+\.\w+', value) and value.split('.')[0] in (objects | STANDARD_OBJECTS) and value not in quick_actions and value in all_quick_actions:
            problems.append('%s offers the action %s, which is not in the slice' % (where, value))
    for one in sorted(vf_pages):
        text = read(os.path.join(root, 'pages', one + '.page'))
        custom_names('pages/%s' % one, text)
        for value in re.findall(r'\b(?:controller|extensions)="([^"]+)"', text):
            for controller in value.split(','):
                if controller.strip() not in classes:
                    problems.append('pages/%s is run by the class %s, which is not in the slice' % (one, controller.strip()))
        for resource in re.findall(r'\$Resource\.(\w+)', text):
            if resource not in resources:
                problems.append('pages/%s loads the static resource %s, which is not in the slice' % (one, resource))
    for one in sorted(objects):
        for folder, _, files in os.walk(os.path.join(root, 'objects', one)):
            for file_name in sorted(files):
                text = PLAIN_WORDS.sub('', read(os.path.join(folder, file_name)))
                where = 'objects/%s/%s' % (one, file_name)
                custom_names(where, text)
                for target in re.findall(r'<referenceTo>([^<]+)<', text):
                    if '__' in target and target not in objects:
                        problems.append('%s points at %s, which is not in the slice' % (where, target))
                for value_set in re.findall(r'<valueSetName>([^<]+)<', text):
                    if value_set not in value_sets:
                        problems.append('%s takes its values from %s, which is not in the slice' % (where, value_set))
                for group in re.findall(r'<group>([^<]+)<', text):
                    if group not in groups:
                        problems.append('%s is shared with the group %s, which is not in the slice' % (where, group))
                for page in re.findall(r'<content>([^<]+)<', text):
                    if page not in pages:
                        problems.append('%s is overridden by the page %s, which is not in the slice' % (where, page))

    wanted = spec.get('permissionSet')
    if spec.get('accessFromAnySet'):
        # A set cut from force-app/ is reached through several permission sets: its own and those of what it brings.
        text = ''.join(read(os.path.join(root, 'permissionsets', one + '.permissionset-meta.xml')) for one in sorted(permission_sets))
        for apex in sorted(granted):
            if '<apexClass>%s</apexClass>' % apex not in text:
                problems.append('no permission set in the set grants %s, which a component calls' % apex)
    elif wanted not in permission_sets:
        problems.append('the permission set %s, which gives access to the slice, is not in it' % wanted)
    else:
        text = read(os.path.join(root, 'permissionsets', wanted + '.permissionset-meta.xml'))
        for apex in sorted(granted):
            if '<apexClass>%s</apexClass>' % apex not in text:
                problems.append('the permission set %s does not grant %s, which a component calls' % (wanted, apex))
    if spec.get('app') and spec['app'] not in apps:
        problems.append('the app %s is not in the slice' % spec['app'])
    return list(dict.fromkeys(problems))


def build_slices(version):
    """Composes and checks each slice. Returns what the manifest says about them."""
    described = {}
    for name, spec in sorted(load_slices().items()):
        root = compose_slice(name, spec)
        problems = check_slice(name, spec, root)
        if problems:
            fail('the slice "%s" does not stand alone (%d problems):\n  %s' % (name, len(problems), '\n  '.join(problems[:40])))
        members = {}
        for folder, suffix, kind in SLICE_TYPES:
            base = os.path.join(root, folder)
            if not os.path.isdir(base):
                continue
            found = sorted(os.listdir(base)) if suffix is None else names_in(base, suffix)
            members[kind] = [one for one in found if one != '.DS_Store']
        tests = sorted(spec.get('fromCore', {}).get('testClasses', []))
        # A person finds a part through FEATURES.md, so it must give the part's command and the name of its permission set.
        features = os.path.join(KIT_SRC, 'FEATURES.md')
        said = read(features) if os.path.exists(features) else ''
        for must in ('--only %s' % name, spec.get('permissionSet') or '', spec.get('app') or ''):
            if must not in said:
                fail('kit/FEATURES.md does not mention "%s", which a person needs to install the slice "%s".' % (must, name))
        described[name] = {
            'label': spec['label'], 'summary': spec['summary'], 'path': 'slices/%s' % name, 'app': spec.get('app'), 'permissionSet': spec.get('permissionSet'),
            'tests': tests, 'members': members, 'needs': spec.get('needs', []), 'changes': spec.get('changes', []), 'apiVersion': version,
            'files': sum(len(files) for _, _, files in os.walk(root)),
        }
        write(os.path.join(SLICES_OUT, name, 'slice.json'), json.dumps(described[name], indent=2, sort_keys=True) + '\n')
        print('  slice %s: %d files, %s. Stands alone: every class, component, object, field and resource it names is in it.'
              % (name, described[name]['files'], ', '.join('%d %s' % (len(found), kind) for kind, found in sorted(members.items()))))
    return described


# ---------------------------------------------------------------- capabilities: what a person can choose to install

# The kinds of thing the installer can ask an org about by name, to tell which capabilities it holds.
DETECTABLE = ('ApexClass', 'ApexTrigger', 'Flow', 'CustomObject', 'PermissionSet', 'CustomTab', 'CustomApplication', 'ApexPage', 'StaticResource', 'LightningComponentBundle')
# What a permission set grants, and the component each grant is for.
GRANTS = {'classAccesses': ('apexClass', 'ApexClass'), 'fieldPermissions': ('field', 'CustomField'), 'objectPermissions': ('object', 'CustomObject'),
          'pageAccesses': ('apexPage', 'ApexPage'), 'recordTypeVisibilities': ('recordType', 'RecordType'), 'tabSettings': ('tab', 'CustomTab'),
          'applicationVisibilities': ('application', 'CustomApplication'), 'customPermissions': ('name', 'CustomPermission'),
          'customMetadataTypeAccesses': ('name', 'CustomObject'), 'customSettingAccesses': ('name', 'CustomObject'), 'flowAccesses': ('flow', 'Flow'),
          'externalCredentialPrincipalAccesses': ('externalCredentialPrincipal', 'ExternalCredential')}


def reach(result, seeds, follow, bucket='core'):
    """Everything the seeds need inside one bucket of the kit. Returns (who asked for each, what lies outside, what is only named at run time)."""
    nodes, edges = result['nodes'], result['edges']
    asked = {seed: None for seed in seeds}
    outside, run_time, queue = [], [], list(asked)
    while queue:
        node = queue.pop(0)
        for target, edge in sorted(edges.get(node, {}).items()):
            if target in asked:
                continue
            kind = nodes[target]['type']
            if edge['how'] == 'soft' and (kind not in follow or nodes[target]['bucket'] != bucket):
                run_time.append((node, target))
                continue
            if nodes[target]['bucket'] != bucket:
                outside.append((node, target))
                continue
            asked[target] = node
            queue.append(target)
    return asked, outside, run_time


def by_type(result, nodes):
    found = {}
    for node in sorted(nodes):
        found.setdefault(result['nodes'][node]['type'], []).append(result['nodes'][node]['name'])
    return found


def counted(result, nodes, limit=6):
    kinds = sorted(by_type(result, nodes).items(), key=lambda item: -len(item[1]))
    return ', '.join('%d %s' % (len(names), kind) for kind, names in kinds[:limit]) + (' and %d more kinds' % (len(kinds) - limit) if len(kinds) > limit else '')


def permission_blocks(text):
    """(tag, the name it grants, the whole block) for each grant in a permission set file."""
    for match in re.finditer(r'    <(\w+)>\n.*?    </\1>\n', text, re.S):
        tag = match.group(1)
        if tag in GRANTS:
            key = re.search(r'<%s>([^<]+)</%s>' % (GRANTS[tag][0], GRANTS[tag][0]), match.group(0))
            yield tag, key.group(1) if key else None, match.group(0)


def derive_permission_set(spec, name, label, summary, own, result, takes_standard, has_tabs):
    """A permission set that grants what one capability holds and nothing else, cut from ours. Returns (xml or None, what it grants)."""
    kept, granted = {}, {}
    for source in spec['permissionSetsFrom']:
        path = os.path.join(CORE, 'permissionsets', source + '.permissionset-meta.xml')
        if not os.path.exists(path):
            fail('scripts/kit_capabilities.json cuts permission sets from %s, which is not in the kit.' % source)
        for tag, key, block in permission_blocks(read(path)):
            if source in spec.get('keptWhole', {}) and tag not in ('objectPermissions', 'fieldPermissions'):
                continue
            kind = GRANTS[tag][1]
            node = '%s:%s' % (kind, key.split('-')[0] if tag == 'externalCredentialPrincipalAccesses' else key)
            standard_object = tag == 'objectPermissions' and '__' not in key
            standard_tab = tag == 'tabSettings' and key.startswith('standard-')
            if node in own or (standard_object and takes_standard) or (standard_tab and has_tabs):
                kept.setdefault((tag, key), block)
                granted.setdefault(tag, []).append(key)
    if not kept:
        return None, {}
    kept[('description', '')] = '    <description>%s</description>\n' % escape_xml('Access to the "%s" part of Antsurance and nothing else of it. %s' % (label, summary))
    kept[('hasActivationRequired', '')] = '    <hasActivationRequired>false</hasActivationRequired>\n'
    kept[('label', '')] = '    <label>%s</label>\n' % escape_xml(name.replace('_', ' '))
    body = ''.join(block for _, block in sorted(kept.items()))
    return '<?xml version="1.0" encoding="UTF-8"?>\n<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">\n%s</PermissionSet>\n' % body, granted


def escape_xml(text):
    return text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


def build_examples():
    """The worked example of an org's own model for the chat names its class in the AI setting. That record is the
    kit's own Default record with one value added, written here so that it never falls behind the kit's."""
    folder = os.path.join(OUT, 'examples', 'acme', 'ask-claude-model', 'main', 'default')
    record = os.path.join(CORE, 'customMetadata', 'Antsurance_AI_Setting.Default.md-meta.xml')
    if not os.path.isdir(folder):
        return
    if not os.path.exists(record) or not os.path.exists(os.path.join(CORE, 'objects', 'Antsurance_AI_Setting__mdt', 'fields', 'Chat_Model_Class__c.field-meta.xml')):
        fail('the example under kit/examples/acme/ names its class in Antsurance_AI_Setting__mdt.Chat_Model_Class__c, and the kit no longer has that field or the Default record.')
    text = read(record)
    if 'Chat_Model_Class__c' in text:
        text = re.sub(r'[ \t]*<values>\s*<field>Chat_Model_Class__c</field>.*?</values>\n', '', text, flags=re.S)
    named = '    <values>\n        <field>Chat_Model_Class__c</field>\n        <value xsi:type="xsd:string">AcmeClaudeModel</value>\n    </values>\n'
    first = text.index('    <values>')
    write(os.path.join(folder, 'customMetadata', 'Antsurance_AI_Setting.Default.md-meta.xml'), text[:first] + named + text[first:])


def build_capabilities(version, slices):
    """Scans the kit, works out what each choice on the menu holds and brings, proves each set stands alone, and writes
    capabilities/<name>/ and kit-scan.json. Returns what the manifest says about them."""
    spec = load_capabilities()
    wanted = spec['capabilities']
    roots = [('core', CORE)] + [(bucket, os.path.join(OPTIONAL, bucket)) for bucket in ('portal', 'look-and-feel', 'value-sets') if os.path.isdir(os.path.join(OPTIONAL, bucket))]
    result = kit_scan.scan(roots)
    nodes = result['nodes']
    follow = set(spec.get('followAtRunTime', []))
    layers = [name for name in spec['order'] if wanted[name]['kind'] == 'layer']

    def seeds_of(name):
        seeds = wanted[name]['seeds']
        found = {node for node, entry in nodes.items() if entry['bucket'] == 'core' and entry['type'] in seeds.get('types', [])}
        for extra in seeds.get('also', []):
            kind, one = extra.split(':', 1)
            matched = {node for node, entry in nodes.items() if entry['bucket'] == 'core' and entry['type'] == kind and (one == '*' or entry['name'] == one)}
            if not matched and one != '*':
                fail('the capability "%s" names %s, which is not in the kit.' % (name, extra))
            found |= matched
        return found

    seeds = {name: seeds_of(name) for name in layers}
    taken = {}
    for name in layers:
        for node in seeds[name]:
            if node in taken:
                fail('%s is a starting point of two capabilities, "%s" and "%s". It can be of one.' % (node, taken[node], name))
            taken[node] = name
    reached, outside, run_time = {}, {}, {}
    for name in layers:
        reached[name], outside[name], run_time[name] = reach(result, seeds[name], follow)

    # What each brings: any other capability whose own starting points it needs. That one is then installed whole.
    direct = {name: sorted({taken[node] for node in reached[name] if node in taken and taken[node] != name}, key=layers.index) for name in layers}
    all_tests = sorted(node for node, entry in nodes.items() if entry.get('test') and entry['bucket'] == 'core')

    # And what the names do not show. A test that works with records of an object runs whatever triggers the org has on
    # it, and ours are written counting on ours: a claim's test asserts what the case trigger did. So a part whose
    # tests work with an object that one of our triggers is on brings the part that holds that trigger.
    trigger_home = {nodes[node]['object']: taken[node] for node in taken if nodes[node]['type'] == 'ApexTrigger' and nodes[node].get('object')}

    def objects_worked_on(test):
        return set(result['standardObjects'].get(test, [])) | {target.split(':', 1)[1] for target in result['edges'].get(test, {}) if target.startswith('CustomObject:')}
    counts_on = {name: {} for name in layers}
    by_name = {name: list(direct[name]) for name in layers}
    for name in layers:
        code = {node for node in reached[name] if nodes[node]['type'] == 'ApexClass' and not nodes[node].get('test')}
        # Only the code that is the part's own. What it reaches through a part it already brings by name has that
        # part's tests, and that part says for itself what they count on.
        code -= set().union(*[set(reached[other]) for other in by_name[name]]) if by_name[name] else set()
        for test in all_tests:
            if not (test[:-4] in code or any(target in code for target in result['edges'].get(test, {}))):
                continue
            for obj in sorted(objects_worked_on(test) & set(trigger_home)):
                home = trigger_home[obj]
                if home != name and name not in direct[home]:
                    found = counts_on[name].setdefault(home, {'objects': set(), 'tests': set()})
                    found['objects'].add(obj)
                    found['tests'].add(nodes[test]['name'])
        for home in counts_on[name]:
            if home not in direct[name]:
                direct[name] = sorted(direct[name] + [home], key=layers.index)

    def brings(name, seen=()):
        if name in seen:
            fail('the capabilities %s need each other, so none of them can be installed without the rest. Make them one in scripts/kit_capabilities.json.' % ' and '.join(seen + (name,)))
        found = []
        for other in direct[name]:
            found += [one for one in brings(other, seen + (name,)) + [other] if one not in found]
        return found
    chain = {name: brings(name) for name in layers}

    def full_without_tests(name):
        return set(reached[name]).union(*[set(reached[other]) for other in chain[name]])

    # Tests: the test of each class by name, and every other test that names a class or trigger of this set and
    # needs nothing from outside it. What a test needs comes with it.
    tests_of = {}
    for name in layers:
        full = full_without_tests(name)
        own_code = {node for node in reached[name] if nodes[node]['type'] in ('ApexClass', 'ApexTrigger') and not nodes[node].get('test')}
        own_code -= set().union(*[set(reached[other]) for other in chain[name]]) if chain[name] else set()
        chosen = []
        for test in all_tests:
            needs, beyond, _ = reach(result, [test], follow)
            by_name = test[:-4] in own_code if test.endswith('Test') else False
            names_ours = any(target in own_code for target in result['edges'].get(test, {}))
            extra = [node for node in needs if node not in full and node != test]
            if by_name or (names_ours and not extra):
                foreign = sorted(node for node in extra if node in taken and taken[node] not in chain[name] + [name])
                beyond = [(source, target) for source, target in beyond if nodes[target]['type'] != 'StandardValueSet']
                if foreign or beyond:
                    fail('the test %s belongs to "%s" by its name, but needs %s, which that capability does not hold.' % (test, name, ', '.join(foreign[:5] or [target for _, target in beyond][:5])))
                chosen.append(test)
                for node, parent in needs.items():
                    reached[name].setdefault(node, parent)
        tests_of[name] = chosen

    full = {name: set(reached[name]).union(*[set(reached[other]) for other in chain[name]]) for name in layers}
    own = {name: set(reached[name]) - (set().union(*[full[other] for other in chain[name]]) if chain[name] else set()) for name in layers}
    described, lines = {}, []

    for name in layers:
        one = wanted[name]
        problems = ['%s names %s, which is in the "%s" part of the kit and not in the app itself' % (source, target, nodes[target]['bucket'])
                    for source, target in outside[name] if nodes[target]['type'] != 'StandardValueSet']
        # Access: a permission set cut from ours, holding only what this capability itself holds.
        has_tabs = 'CustomTab' in one['seeds'].get('types', [])
        xml, granted = derive_permission_set(spec, one['permissionSet'], one['label'], one['summary'], own[name], result, one.get('standardObjectAccess', False), has_tabs)
        target = os.path.join(CAPABILITIES_OUT, name)
        if xml:
            write(os.path.join(target, 'main', 'default', 'permissionsets', one['permissionSet'] + '.permissionset-meta.xml'), xml)
        described[name] = {'permissionSet': one['permissionSet'] if xml else None, 'grants': {tag: len(keys) for tag, keys in sorted(granted.items())}}

    for name in layers:
        one = wanted[name]
        # The proof: lay the whole set out in a folder, with what it brings, and read it the way a slice is read.
        proof = os.path.join(DIST, '.capability-proof', name)
        if os.path.isdir(proof):
            shutil.rmtree(proof)
        for node in sorted(full[name]):
            for path in nodes[node]['files']:
                to_path = os.path.join(proof, path)
                os.makedirs(os.path.dirname(to_path), exist_ok=True)
                shutil.copyfile(os.path.join(CORE, path), to_path)
        for other in chain[name] + [name]:
            if described[other]['permissionSet']:
                source = os.path.join(CAPABILITIES_OUT, other, 'main', 'default', 'permissionsets', described[other]['permissionSet'] + '.permissionset-meta.xml')
                os.makedirs(os.path.join(proof, 'permissionsets'), exist_ok=True)
                shutil.copyfile(source, os.path.join(proof, 'permissionsets', os.path.basename(source)))
        problems = ['%s names %s, which is in the "%s" part of the kit and not in the app itself' % (source, target, nodes[target]['bucket'])
                    for source, target in outside[name] if nodes[target]['type'] != 'StandardValueSet']
        problems += check_slice(name, {'accessFromAnySet': True, 'fromCore': {'testClasses': [test.split(':')[1] for other in chain[name] + [name] for test in tests_of[other]]},
                                       'foundAtRunTime': sorted({nodes[target]['name'] for _, target in run_time[name] if nodes[target]['type'] == 'ApexClass'})}, proof)
        # And by the scan itself: nothing in the set has a hard edge that leaves it.
        for node in sorted(full[name]):
            for target, edge in result['edges'].get(node, {}).items():
                if edge['how'] == 'hard' and target not in full[name] and nodes[target]['type'] != 'StandardValueSet':
                    problems.append('%s needs %s (%s), which is not in the set' % (node, target, edge.get('via', 'names it')))
        shutil.rmtree(proof)
        if problems:
            fail('the capability "%s" does not stand alone (%d problems):\n  %s' % (name, len(problems), '\n  '.join(list(dict.fromkeys(problems))[:40])))

        members = by_type(result, own[name])
        files = sorted(path for node in own[name] for path in nodes[node]['files'])
        tests = sorted(test.split(':')[1] for test in tests_of[name])
        code = sorted(node for node in own[name] if nodes[node]['type'] in ('ApexClass', 'ApexTrigger') and not nodes[node].get('test'))
        standard = sorted({obj for node in own[name] for obj in result['standardObjects'].get(node, [])})
        value_sets = sorted({nodes[target]['name'] for other in chain[name] + [name] for _, target in outside[other] if nodes[target]['type'] == 'StandardValueSet'})
        whole = full[name]
        needs_first = []
        if value_sets:
            needs_first.append('Our values in the standard picklists (%s): python3 scripts/setup/deploy_phase.py --target-org <alias> --phase value-sets' % ', '.join(value_sets))
        if any(node.startswith('CustomField:Quote.') for node in whole):
            needs_first.append('Quotes switched on: python3 scripts/setup/deploy_phase.py --target-org <alias> --phase prerequisites --enable quotes')
        if any(nodes[node]['type'] == 'PathAssistant' for node in whole):
            needs_first.append('Path switched on: python3 scripts/setup/deploy_phase.py --target-org <alias> --phase prerequisites --enable path')
        if one.get('needsKey') or any(nodes[node]['type'] == 'NamedCredential' for node in own[name]):
            needs_first.append('A Claude API key, stored after the install by the person at a hidden prompt, for anything that calls Claude')
        why = {}
        for other in direct[name]:
            used = [node for node in reached[name] if node in seeds[other]]
            said = []
            if used:
                said.append('it names %s of "%s" (%s of its %d starting points)' % (counted(result, used, 4), wanted[other]['label'], len(used), len(seeds[other])))
            if other in counts_on[name]:
                found = counts_on[name][other]
                said.append('%d of its test classes work with records of %s, which the triggers in "%s" act on, and assert what those triggers did' % (len(found['tests']), ', '.join(sorted(found['objects'])), wanted[other]['label']))
            why[other] = '; and '.join(said)
        carried = sorted(node for node in own[name] if node not in seeds[name] and not nodes[node].get('test'))
        shared = {other: sorted(own[name] & own[other]) for other in layers if other != name and own[name] & own[other]}
        detect = {kind: sorted(nodes[node]['name'] for node in own[name] if nodes[node]['type'] == kind) for kind in DETECTABLE}
        detect = {kind: found for kind, found in detect.items() if found}
        if described[name]['permissionSet']:
            detect['PermissionSet'] = sorted(detect.get('PermissionSet', []) + [described[name]['permissionSet']])
        entry = {
            'kind': 'layer', 'label': one['label'], 'option': one['option'], 'summary': one['summary'], 'path': 'capabilities/%s' % name, 'apiVersion': version,
            'brings': chain[name], 'bringsDirectly': direct[name], 'bringsWhy': why, 'needsFirst': needs_first,
            'testsCountOn': {other: {'objects': sorted(found['objects']), 'tests': sorted(found['tests'])} for other, found in sorted(counts_on[name].items())},
            'provenNote': one.get('provenNote', ''),
            'prerequisites': {'valueSets': value_sets, 'quotes': any(node.startswith('CustomField:Quote.') for node in whole), 'path': any(nodes[node]['type'] == 'PathAssistant' for node in whole)},
            'needsDataModel': bool(chain[name]) or name == 'data-model', 'installsAlone': True, 'command': 'python3 scripts/setup/deploy_phase.py --target-org <alias> --only %s' % name,
            'permissionSet': described[name]['permissionSet'], 'grants': described[name]['grants'],
            'accessSets': [described[other]['permissionSet'] for other in chain[name] + [name] if described[other]['permissionSet']],
            'alsoHolds': sorted(nodes[node]['name'] for node in own[name] if nodes[node]['type'] == 'PermissionSet'),
            'tests': tests, 'covered': {'classes': [node.split(':')[1] for node in code if node.startswith('ApexClass:')], 'triggers': [node.split(':')[1] for node in code if node.startswith('ApexTrigger:')]},
            'members': members, 'detect': detect, 'files': len(files), 'standardObjects': standard,
            'sharedWith': {other: len(found) for other, found in shared.items()},
            'carried': counted(result, carried) if carried else '', 'carriedWords': one.get('carriedWords', ''),
            'namedAtRunTime': sorted({'%s %s' % (nodes[target]['type'], nodes[target]['name']) for _, target in run_time[name] if target not in whole}),
        }
        described[name] = entry
        detail = dict(entry, fileList=files, nodes=sorted(own[name]), shared=shared,
                      carriedNodes={node: kit_scan.why(result, reached[name], node)[:3] for node in carried if nodes[node]['type'] in ('ApexClass', 'NamedCredential', 'ExternalCredential', 'ApexPage', 'CustomNotificationType', 'CustomPermission')})
        write(os.path.join(CAPABILITIES_OUT, name, 'capability.json'), json.dumps(detail, indent=1, sort_keys=True) + '\n')
        lines.append('  capability %s: %d components in %d files (%s), %d test classes%s. Stands alone with what it brings.' % (
            name, len(own[name]), len(files), counted(result, own[name], 5), len(tests), '; brings ' + ', '.join(chain[name]) if chain[name] else ''))

    in_some_layer = set().union(*full.values()) if full else set()
    top = [name for name in layers if not any(name in chain[other] for other in layers)]

    def needed_layers(needs):
        """The fewest capabilities that together hold these components, or None when something is in none of them."""
        if not needs <= in_some_layer:
            return None
        chosen, left = [], set(needs)
        while left:
            # The capability that holds the most of what is still needed; a tie goes to the earlier one.
            best = max(layers, key=lambda name: (len(left & full[name]) - len(left & set().union(*[full[other] for other in chain[name]])) if chain[name] else len(left & full[name]), -layers.index(name)))
            chosen.append(best)
            left -= full[best]
        found = []
        for name in chosen:
            found += [other for other in chain[name] + [name] if other not in found]
        return sorted(found, key=layers.index)

    for name in spec['order']:
        one = wanted[name]
        if one['kind'] == 'layer':
            continue
        entry = {'kind': one['kind'], 'label': one['label'], 'option': one['option'], 'summary': one['summary'], 'needsFirst': list(one.get('needsFirst', [])),
                 'how': one.get('how', []), 'ownYes': one.get('ownYes'), 'brings': [], 'needsDataModel': False, 'installsAlone': one['kind'] in ('slice', 'whole')}
        if one['kind'] == 'slice':
            part = slices[name]
            entry.update(path=part['path'], permissionSet=part['permissionSet'], accessSets=[part['permissionSet']], tests=part['tests'], members=part['members'], app=part.get('app'),
                         needsFirst=part.get('needs', []), command='python3 scripts/setup/deploy_phase.py --target-org <alias> --only %s' % name,
                         detect={kind: found for kind, found in part['members'].items() if kind in DETECTABLE})
        elif one['kind'] == 'whole':
            entry.update(accessSets=one.get('permissionSets', []), needsDataModel=True,
                         holdsBeyondTheLayers=counted(result, [node for node, found in nodes.items() if found['bucket'] == 'core' and node not in in_some_layer and not found.get('test')], 8),
                         command='the phases in INSTALL.md, in order')
        elif one['kind'] == 'phase':
            bucket_nodes = sorted(node for node, found in nodes.items() if found['bucket'] == one['bucket'])
            asked, beyond, _ = reach(result, bucket_nodes, follow, bucket=one['bucket'])
            needs = {target for _, target in beyond if nodes[target]['bucket'] == 'core'}
            # Something small of the app that the phase shows (the theme's logo) travels with the phase as well, so
            # that the phase does not have to bring the part of the app that holds it.
            carries = list(one.get('carries', []))
            for node in carries:
                if node not in nodes or nodes[node]['bucket'] != 'core':
                    fail('the capability "%s" is said to carry %s, which is not in the app.' % (name, node))
                if node not in needs:
                    fail('the capability "%s" is said to carry %s, and nothing in it names that any more. Take it out of "carries" in scripts/kit_capabilities.json.' % (name, node))
                for path in nodes[node]['files']:
                    to_path = os.path.join(OPTIONAL, one['bucket'], path)
                    os.makedirs(os.path.dirname(to_path), exist_ok=True)
                    shutil.copyfile(os.path.join(CORE, path), to_path)
            needs -= set(carries)
            closed = set(needs)
            for node in sorted(needs):
                closed |= set(reach(result, [node], follow)[0])
            found = needed_layers(closed)
            beyond_layers = sorted(closed - in_some_layer)
            triggered = sorted({obj for node in bucket_nodes if nodes[node].get('test') for obj in objects_worked_on(node) & set(trigger_home)})
            if found is not None and triggered:
                # Its tests work with records our triggers act on, so it also needs the part that holds those triggers.
                for obj in triggered:
                    home = trigger_home[obj]
                    found = sorted(set(found) | set(chain[home]) | {home}, key=layers.index)
                entry['testsCountOn'] = {'objects': triggered, 'why': 'its tests work with records of %s, which our triggers act on' % ', '.join(triggered)}
            if carries:
                entry['carries'] = ['%s %s' % (nodes[node]['type'], nodes[node]['name']) for node in carries]
            entry.update(phase=one['phase'], members=by_type(result, bucket_nodes + carries), needsOfTheApp=counted(result, closed, 8) if closed else '',
                         brings=found if found is not None else ['everything'], needsDataModel=bool(closed),
                         needsBeyondTheLayers=['%s %s' % (nodes[node]['type'], nodes[node]['name']) for node in beyond_layers][:40],
                         command='python3 scripts/setup/deploy_phase.py --target-org <alias> --only %s' % name,
                         detect={kind: sorted(nodes[node]['name'] for node in bucket_nodes if nodes[node]['type'] == kind) for kind in DETECTABLE if any(nodes[node]['type'] == kind for node in bucket_nodes)})
            whole = one.get('needsWhole')
            if whole:
                # The reason is checked, not taken on trust: when it stops being true the build says so.
                if whole['names'] not in result['edges'].get(whole['from'], {}):
                    fail('the capability "%s" is said to need the whole app because %s names %s, and it no longer does. Take "needsWhole" out of scripts/kit_capabilities.json.' % (name, whole['from'], whole['names']))
                entry.update(byItsCodeAlone=entry['brings'], brings=['everything'], whyEverything=whole['why'])
            staff = one.get('staffSet')
            if staff:
                # The phase carries the whole app's permission set in full. Where the whole app is not installed, staff
                # reach this phase's classes through a small set cut from that one.
                blocks = [block for tag, key, block in permission_blocks(read(os.path.join(SRC, 'permissionsets', staff['from'] + '.permissionset-meta.xml')))
                          if tag == 'classAccesses' and key.startswith(staff['classesStartingWith']) and 'ApexClass:' + key in bucket_nodes]
                if not blocks:
                    fail('the capability "%s" cuts a staff permission set from %s, which grants none of its classes.' % (name, staff['from']))
                body = ''.join(sorted(blocks)) + '    <description>%s</description>\n    <hasActivationRequired>false</hasActivationRequired>\n    <label>%s</label>\n' % (
                    escape_xml('Staff access to the classes of "%s", for an org that holds it without the whole app.' % one['label']), staff['name'].replace('_', ' '))
                write(os.path.join(CAPABILITIES_OUT, name, 'main', 'default', 'permissionsets', staff['name'] + '.permissionset-meta.xml'),
                      '<?xml version="1.0" encoding="UTF-8"?>\n<PermissionSet xmlns="http://soap.sforce.com/2006/04/metadata">\n%s</PermissionSet>\n' % body)
                entry.update(staffSet=staff['name'], staffSetInPlaceOf=staff['from'], staffSetWhy=staff['why'], path='capabilities/%s' % name, mayAlsoHold={'PermissionSet': [staff['name']]})
            write(os.path.join(CAPABILITIES_OUT, name, 'capability.json'), json.dumps(dict(entry, nodes=bucket_nodes, needs=sorted(closed)), indent=1, sort_keys=True) + '\n')
        elif one['kind'] == 'step':
            missing = [node for node in one.get('needsNodes', []) if node not in nodes]
            if missing:
                fail('the capability "%s" needs %s, which is not in the kit.' % (name, ', '.join(missing)))
            closed = set()
            for node in one.get('needsNodes', []):
                closed |= set(reach(result, [node], follow)[0])
            found = needed_layers(closed)
            entry.update(brings=found if found is not None else ['everything'], needsDataModel=True, command=(one.get('how') or [''])[0],
                         needsBeyondTheLayers=['%s %s' % (nodes[node]['type'], nodes[node]['name']) for node in sorted(closed - in_some_layer)][:40])
        described[name] = entry
        if one['kind'] != 'layer':
            lines.append('  capability %s (%s): %s' % (name, one['kind'], 'brings ' + ', '.join(entry['brings']) if entry['brings'] else 'needs nothing else of ours'))

    # A person finds each choice through FEATURES.md and the install skill, so each must be named there.
    said = read(os.path.join(KIT_SRC, 'FEATURES.md')) if os.path.exists(os.path.join(KIT_SRC, 'FEATURES.md')) else ''
    questions_path = os.path.join(KIT_SRC, '.claude', 'skills', 'antsurance-install', 'references', 'questions.md')
    asked_text = read(questions_path) if os.path.exists(questions_path) else ''
    for name, entry in described.items():
        if '--only %s' % name not in said and entry['kind'] in ('layer', 'slice', 'phase'):
            fail('kit/FEATURES.md does not mention "--only %s", which a person needs to install "%s".' % (name, entry['label']))
        if entry.get('permissionSet') and entry['permissionSet'] not in said:
            fail('kit/FEATURES.md does not mention the permission set %s of "%s".' % (entry['permissionSet'], entry['label']))
        if entry['label'] not in asked_text:
            fail('the install skill\'s questions.md does not offer "%s" in the question about what to install.' % entry['label'])

    build_examples()
    compact = dict(result, edges={node: {target: edge for target, edge in targets.items()} for node, targets in result['edges'].items()})
    write(os.path.join(OUT, 'kit-scan.json'), json.dumps(compact, separators=(',', ':'), sort_keys=True) + '\n')
    print('  scan: %d components, %d edges between them, written to kit-scan.json' % (len(nodes), sum(len(targets) for targets in result['edges'].values())))
    print('\n'.join(lines))
    return {'order': spec['order'], 'layers': layers, 'top': top, 'list': described}


# ---------------------------------------------------------------- manifest

def names_in(folder, suffix):
    if not os.path.isdir(folder):
        return []
    return sorted(name[:-len(suffix)] for name in os.listdir(folder) if name.endswith(suffix))


def is_test_class(path):
    return bool(re.search(r'@IsTest\s*(\([^)]*\))?\s*(private|public|global)?\s*(with sharing|without sharing|inherited sharing)?\s*class', read(path), re.I))


def is_custom_setting(objects, name):
    path = os.path.join(objects, name, name + '.object-meta.xml')
    return os.path.exists(path) and '<customSettingsType>' in read(path)


def build_manifest(version, slices, capabilities):
    portal = os.path.join(OPTIONAL, 'portal')
    look = os.path.join(OPTIONAL, 'look-and-feel')
    objects = os.path.join(CORE, 'objects')
    ours = {
        'customObjects': sorted([name for name in os.listdir(objects) if '__' in name] + [name for name in (os.listdir(os.path.join(portal, 'objects')) if os.path.isdir(os.path.join(portal, 'objects')) else []) if '__' in name]),
        'standardObjectFields': {}, 'recordTypes': {}, 'businessProcesses': {}, 'validationRules': [], 'compactLayouts': [], 'listViews': [],
    }
    # A custom setting holds what the app keeps for itself (the coverage agent's ids, the desk's switches), not records
    # people made. The uninstall lists those rows and removes them with the app; it never stops to ask about them.
    ours['customSettings'] = [name for name in ours['customObjects'] if is_custom_setting(objects, name)]
    for name in sorted(os.listdir(objects)):
        if name not in STANDARD_OBJECTS:
            continue
        base = os.path.join(objects, name)
        fields = names_in(os.path.join(base, 'fields'), '.field-meta.xml')
        if fields:
            ours['standardObjectFields'][name] = fields
        for kind, key, suffix in (('recordTypes', 'recordTypes', '.recordType-meta.xml'), ('businessProcesses', 'businessProcesses', '.businessProcess-meta.xml')):
            found = names_in(os.path.join(base, kind), suffix)
            if found:
                ours[key][name] = found
        ours['validationRules'] += ['%s.%s' % (name, one) for one in names_in(os.path.join(base, 'validationRules'), '.validationRule-meta.xml')]
        ours['compactLayouts'] += ['%s.%s' % (name, one) for one in names_in(os.path.join(base, 'compactLayouts'), '.compactLayout-meta.xml')]
        ours['listViews'] += ['%s.%s' % (name, one) for one in names_in(os.path.join(base, 'listViews'), '.listView-meta.xml')]

    classes = names_in(os.path.join(CORE, 'classes'), '.cls')
    ours['apexClasses'] = classes
    ours['apexTestClasses'] = [name for name in classes if is_test_class(os.path.join(CORE, 'classes', name + '.cls'))]
    portal_classes = names_in(os.path.join(portal, 'classes'), '.cls')
    ours['portalClasses'] = portal_classes
    ours['portalTestClasses'] = [name for name in portal_classes if is_test_class(os.path.join(portal, 'classes', name + '.cls'))]
    ours['apexTriggers'] = names_in(os.path.join(CORE, 'triggers'), '.trigger') + names_in(os.path.join(portal, 'triggers'), '.trigger')
    ours['apexPages'] = names_in(os.path.join(CORE, 'pages'), '.page')
    ours['lwc'] = sorted(os.listdir(os.path.join(CORE, 'lwc'))) + (sorted(os.listdir(os.path.join(portal, 'lwc'))) if os.path.isdir(os.path.join(portal, 'lwc')) else [])
    ours['flows'] = names_in(os.path.join(CORE, 'flows'), '.flow-meta.xml')
    ours['permissionSets'] = sorted(set(names_in(os.path.join(CORE, 'permissionsets'), '.permissionset-meta.xml') + names_in(os.path.join(portal, 'permissionsets'), '.permissionset-meta.xml')))
    ours['apps'] = names_in(os.path.join(CORE, 'applications'), '.app-meta.xml')
    ours['tabs'] = names_in(os.path.join(CORE, 'tabs'), '.tab-meta.xml')
    ours['flexipages'] = names_in(os.path.join(CORE, 'flexipages'), '.flexipage-meta.xml')
    ours['quickActions'] = names_in(os.path.join(CORE, 'quickActions'), '.quickAction-meta.xml')
    ours['layouts'] = names_in(os.path.join(CORE, 'layouts'), '.layout-meta.xml')
    ours['pathAssistants'] = names_in(os.path.join(CORE, 'pathAssistants'), '.pathAssistant-meta.xml')
    ours['namedCredentials'] = names_in(os.path.join(CORE, 'namedCredentials'), '.namedCredential-meta.xml')
    ours['externalCredentials'] = names_in(os.path.join(CORE, 'externalCredentials'), '.externalCredential-meta.xml')
    ours['groups'] = names_in(os.path.join(CORE, 'groups'), '.group-meta.xml')
    ours['globalValueSets'] = names_in(os.path.join(CORE, 'globalValueSets'), '.globalValueSet-meta.xml')
    ours['staticResources'] = names_in(os.path.join(CORE, 'staticresources'), '.resource-meta.xml')
    ours['contentAssets'] = names_in(os.path.join(CORE, 'contentassets'), '.asset-meta.xml')
    ours['cspTrustedSites'] = names_in(os.path.join(CORE, 'cspTrustedSites'), '.cspTrustedSite-meta.xml')
    ours['remoteSiteSettings'] = names_in(os.path.join(CORE, 'remoteSiteSettings'), '.remoteSite-meta.xml')
    ours['notificationTypes'] = names_in(os.path.join(CORE, 'notificationtypes'), '.notiftype-meta.xml')
    ours['customPermissions'] = names_in(os.path.join(CORE, 'customPermissions'), '.customPermission-meta.xml')
    ours['customMetadata'] = names_in(os.path.join(CORE, 'customMetadata'), '.md-meta.xml')
    ours['reportTypes'] = names_in(os.path.join(CORE, 'reportTypes'), '.reportType-meta.xml')
    for kind, suffix, folder_suffix in (('reports', '.report-meta.xml', '.reportFolder-meta.xml'), ('dashboards', '.dashboard-meta.xml', '.dashboardFolder-meta.xml')):
        base = os.path.join(CORE, kind)
        folders = names_in(base, folder_suffix)
        ours[kind[:-1] + 'Folders'] = folders
        ours[kind] = ['%s/%s' % (folder, name) for folder in folders for name in names_in(os.path.join(base, folder), suffix)]
        if kind == 'dashboards':
            ours['dashboardFolderLabels'] = [re.search(r'<name>([^<]+)</name>', read(os.path.join(base, folder + folder_suffix))).group(1) for folder in folders]

    value_sets = {}
    folder = os.path.join(OPTIONAL, 'value-sets', 'standardValueSets')
    for name in names_in(folder, '.standardValueSet-meta.xml'):
        text = read(os.path.join(folder, name + '.standardValueSet-meta.xml'))
        value_sets[name] = [{'fullName': value} for value in re.findall(r'<standardValue>\s*<fullName>([^<]+)</fullName>', text)]

    # Code that names a state or country code field outside a quoted string or a comment only compiles in an org
    # with state and country picklists. AntsuranceAddress reaches those fields by name at run time, so none should.
    def names_code_field(name):
        text = read(os.path.join(CORE, 'classes', name + '.cls'))
        text = re.sub(r"/\*.*?\*/|//[^\n]*|'(?:\\.|[^'\\\n])*'", '', text, flags=re.S)
        return re.search(r'\b\w*(?:State|Country)Code\b', text) is not None
    needs_picklists = any(names_code_field(name) for name in classes)
    manifest = {
        'product': 'Antsurance', 'apiVersion': version, 'built': date.today().isoformat(),
        'requirements': {'stateCountryPicklists': needs_picklists, 'quotes': True, 'path': True},
        'demoData': {'records': '2,100', 'dataStorageMB': 5},
        'insertsInto': INSERTS_INTO, 'ours': ours, 'standardValueSets': value_sets,
        # The coverage agent's code ships in core. Its setup is a step of its own, after the key: it creates an agent,
        # an environment and a skill in the customer's Anthropic workspace, so it is never run unasked.
        'coverageAgent': {'setting': 'Antsurance_Coverage_Agent__c', 'setupClass': 'AntsuranceCoverageAgentSetup',
                          'skills': ['skills/%s/SKILL.md' % folder for folder, _ in UPLOADED_SKILLS]},
        'phases': ['prerequisites', 'value-sets', 'core', 'access', 'claude', 'coverage-agent', 'look-and-feel', 'demo-data', 'demo-prep', 'portal', 'verify'],
        # A slice is a part of the app that installs alone: python3 scripts/setup/deploy_phase.py --only <name>. See FEATURES.md.
        'slices': slices,
        # Every choice on the install menu, in the order it is offered: what it holds, what it brings, its tests and its
        # permission set. scripts/kit_capabilities.json defines them and the scan (kit-scan.json) worked out the rest.
        'capabilities': capabilities['list'], 'capabilityOrder': capabilities['order'], 'capabilityLayers': capabilities['layers'],
    }
    write(os.path.join(OUT, 'kit-manifest.json'), json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return manifest


def build_uninstall(manifest):
    ours = manifest['ours']
    # The permission sets of the parts that install alone go with the app too. One the org does not hold is skipped.
    part_sets = sorted({one for entry in manifest.get('capabilities', {}).values() for one in (entry.get('permissionSet'), entry.get('staffSet')) if one} - set(ours['permissionSets']))
    std_fields = ['%s.%s' % (name, field) for name, fields in sorted(ours['standardObjectFields'].items()) for field in fields]
    std_layouts = [name for name in ours['layouts'] if name.split('-')[0] in STANDARD_OBJECTS]
    our_list_views = [name for name in ours['listViews'] if name.split('.')[1] not in STOCK_LIST_VIEWS]
    # Order matters: what uses a thing goes before the thing. Anything that one stubborn leftover could block
    # (a list view Salesforce insists on keeping, a logo the theme still uses) sits in a step of its own.
    steps = [
        {'name': 'The app, dashboards and reports', 'types': {'CustomApplication': ours['apps'], 'Dashboard': ours['dashboards'], 'Report': ours['reports']}},
        {'name': 'Pages, tabs, buttons and permission sets', 'types': {
            'FlexiPage': ours['flexipages'], 'QuickAction': ours['quickActions'], 'CustomTab': ours['tabs'], 'PathAssistant': ours['pathAssistants'],
            'Layout': std_layouts, 'DashboardFolder': ours['dashboardFolders'], 'ReportFolder': ours['reportFolders'],
            'ReportType': ours['reportTypes'], 'CustomNotificationType': ours['notificationTypes'], 'PermissionSet': ours['permissionSets'] + part_sets}},
        {'name': 'Our list views', 'types': {'ListView': our_list_views}},
        {'name': 'Flows and triggers', 'flows': ours['flows'], 'types': {'ApexTrigger': ours['apexTriggers'], 'PlatformEventSubscriberConfig': ['AntsurancePortalSubmissionTriggerConfig']}},
        {'name': 'Screen components, document pages and Apex code', 'types': {
            'LightningComponentBundle': ours['lwc'], 'ApexPage': ours['apexPages'], 'ApexClass': sorted(ours['apexClasses'] + ours['portalClasses'])}},
        {'name': 'Our fields and rules on standard objects', 'types': {'ValidationRule': ours['validationRules'], 'CompactLayout': ours['compactLayouts'], 'CustomField': std_fields}},
        {'name': 'Settings records and the connection to Claude', 'types': {'CustomMetadata': ours['customMetadata'], 'NamedCredential': ours['namedCredentials'], 'CustomPermission': ours['customPermissions']}},
        {'name': 'Our own objects and files', 'types': {
            'CustomObject': ours['customObjects'], 'ExternalCredential': ours['externalCredentials'],
            'StaticResource': ours['staticResources'], 'CspTrustedSite': ours['cspTrustedSites'], 'RemoteSiteSetting': ours['remoteSiteSettings']}},
        {'name': 'The shared picklist, the group and the logo', 'types': {'GlobalValueSet': ours['globalValueSets'], 'Group': ours['groups'], 'ContentAsset': ours['contentAssets']}},
    ]
    for step in steps:
        step['types'] = {kind: members for kind, members in step['types'].items() if members}
    stays = [
        'Our record types (Claim and Policy Service on Case, Policy Sale on Opportunity, Household, Business and Agency on Account). They are switched off where Salesforce allows it; an object keeps its last active record type. Delete them in Setup, Object Manager, the object, Record Types.',
        'One of our list views, if Salesforce refuses to delete it because the object would have none left. Delete it in the list view controls once you have another.',
        'The logo file (Claude Spark), while the look and feel still uses it, and the Line of Business picklist, while our deleted fields still name it. Salesforce keeps a deleted field for 15 days under each object\'s Deleted Fields, renamed with _del, in a scratch org too. Erase them there to be rid of them sooner.',
        'The support processes Claims and PolicyService and the sales process InsuranceSales. Delete them in Setup once the record types are gone.',
        'The picklist values the install added to Case Status, Case Origin, Opportunity Stage, Opportunity Type and Quote Status. The install report lists them. Deactivate or delete them in Setup, Object Manager, the field.',
        'Quotes and Path, if the install turned them on. Turn them off in Setup if nothing else uses them.',
        'The look and feel, if you applied it: pick your own theme in Setup, Themes and Branding, then delete ours; undo the renames in Setup, Rename Tabs and Labels.',
        'The customer portal site, if you set it up, emptied of our components and switched to down for maintenance, with its profile Antsurance Customer. Salesforce does not delete a site and does not let Digital Experiences be switched off. Archive the site in Setup, Digital Experiences, All Sites; delete the profile in Setup, Profiles, once no user is on it. What Salesforce itself made with the site stays with it and is not ours: a guest profile named Antsurance Profile, a guest group named Antsurance and a file named SiteSamples.',
        'The coverage agent, if you set it up: the agent "Antsurance claims coverage agent (Salesforce)", the environment "antsurance-crm-coverage", the skill "antsurance-coverage" and their past sessions are in your Anthropic workspace, not in Salesforce. Removing the app removes only the ids kept in the org. Archive them yourself in the Claude Console, under Managed Agents, if you want them gone; archiving there is permanent, so this installer never does it for you.',
    ]
    write(os.path.join(OUT, 'uninstall', 'steps.json'), json.dumps({'steps': steps, 'stays': stays}, indent=2) + '\n')
    return steps


# ---------------------------------------------------------------- the scan

def scan(real_streets, precise_numbers):
    """Reads every file in the kit. Returns {check name: [finding lines]}."""
    owner_email_parts = ('ck@', 'ck+', '@anthropic.com', 'agentforce.com')
    checks = [
        ('this org (alias or host)', re.compile('|'.join(['orgfarm-'] + ([re.escape(os.environ['SF_TARGET_ORG'])] if os.environ.get('SF_TARGET_ORG') else [])), re.I), None),
        ('Salesforce record ids', re.compile(r'(?<![A-Za-z0-9_/+=.-])[0-9a-zA-Z]{5}0000[0-9a-zA-Z]{6}(?:[0-9A-Z]{3})?(?![A-Za-z0-9_/+=-])'), 'id'),
        ('paths under /Users/', re.compile(r'/Users/'), None),
        ("the owner's name or email", re.compile('|'.join([re.escape(name) for name in os.environ.get('KIT_OWNER_NAMES', '').split(',') if name] + [re.escape(part) for part in owner_email_parts])), None),
        ('internal words', re.compile(r'\bslack\b|\bgo/[a-z][\w-]+|TRACKER\.md|KNOWLEDGE\.md|PRESENTER_GUIDE|docs/inbox|\bAKI\b|antfarm|undercover', re.I), None),
        ('anything shaped like an API key', re.compile(r'sk-ant-[A-Za-z0-9_-]{6,}|\bsk-[A-Za-z0-9]{24,}|AKIA[0-9A-Z]{16}|xox[abpr]-[A-Za-z0-9-]{10,}|gh[pousr]_[A-Za-z0-9]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|00D[A-Za-z0-9]{12,15}![A-Za-z0-9._]{20,}'), None),
        ('real street addresses and exact coordinates', None, 'address'),
        ('em dashes in documents a customer reads', re.compile('—'), 'docs'),
        ('blanks left for the installer only where it fills them', re.compile(r'\{\{[A-Z_]+\}\}'), 'blank'),
        ('British spellings in documents a customer reads', BRITISH, 'docs'),
    ]
    findings = {name: [] for name, _, _ in checks}
    address_needles = sorted(set(real_streets) | {without_suffix(street) for street in real_streets if len(without_suffix(street).split()) >= 3})
    files = 0
    for folder, dirs, names in os.walk(OUT):
        dirs.sort()
        for name in sorted(names):
            path = os.path.join(folder, name)
            rel = os.path.relpath(path, OUT)
            files += 1
            if is_binary(path):
                continue
            try:
                lines = read(path).splitlines()
            except UnicodeDecodeError:
                continue
            is_metadata = rel.startswith(('force-app' + os.sep, 'optional' + os.sep)) or (rel.startswith('slices' + os.sep) and (os.sep + 'main' + os.sep) in rel)
            is_doc = not is_metadata and rel.endswith(('.md', '.py', '.sh', '.json', '.txt'))
            for number, line in enumerate(lines, 1):
                for check, pattern, mode in checks:
                    if mode == 'address':
                        hit = next((needle for needle in address_needles if needle in line), None) or next((value for value in precise_numbers if re.search(r'(?<![\d.])%s(?!\d)' % re.escape(value), line)), None)
                        if hit:
                            findings[check].append('%s:%d: %s' % (rel, number, hit))
                        continue
                    if mode == 'docs' and not is_doc:
                        continue
                    # A skill names the org's stored values as they are stored ("Cancelled" is a policy status), so the
                    # kit's own spelling floor does not read it. The shared spelling check below does, and knows that word.
                    if pattern is BRITISH and rel.startswith('skills' + os.sep):
                        continue
                    # The scan and what the build says of each capability repeat the app's own names and stored values.
                    if pattern is BRITISH and (rel == 'kit-scan.json' or (rel.startswith('capabilities' + os.sep) and rel.endswith('capability.json'))):
                        continue
                    for match in pattern.finditer(line):
                        found = match.group(0)
                        # A made-up id that is a key prefix and then all zeros (the master record type, a test's stand-in) is the
                        # same in every org and names no record.
                        if mode == 'id' and (found.isdigit() or found.isalpha() or re.match(r'^[0-9a-zA-Z]{3}0{12}(AAA)?$', found)):
                            continue
                        if mode == 'blank' and (rel.startswith('optional' + os.sep + 'portal') or rel.startswith(os.path.join('force-app', 'main', 'default', 'dashboards')) or rel.startswith('scripts' + os.sep)):
                            continue
                        findings[check].append('%s:%d: %s' % (rel, number, found if 'key' not in check else found[:6] + '...'))
    return findings, files


def report(findings, files):
    bad = 0
    for check, lines in findings.items():
        if lines:
            bad += len(lines)
            print('FAIL  %s: %d found' % (check, len(lines)))
            for line in lines[:40]:
                print('        ' + line)
            if len(lines) > 40:
                print('        and %d more' % (len(lines) - 40))
        else:
            print('clean %s' % check)
    print('%d files scanned.' % files)
    return bad


def shared_spelling_check():
    """Runs the repo's shared American-spelling checker over the kit's documents, when the repo has it. Returns 1 on a hit."""
    if not os.path.exists(SHARED_SPELLING_CHECK):
        print('note  scripts/ui_checks/us_spelling.py is not in the repo yet, so only the built-in spelling list was checked')
        return 0
    import subprocess
    targets = [os.path.join(OUT, name) for name in ('README.md', 'INSTALL.md', 'CLAUDE.md', 'FEATURES.md', '.claude', 'scripts', 'skills') if os.path.exists(os.path.join(OUT, name))]
    done = subprocess.run([sys.executable, '-I', SHARED_SPELLING_CHECK] + targets, capture_output=True, text=True)
    if done.returncode != 0:
        print('FAIL  shared spelling check (scripts/ui_checks/us_spelling.py):')
        print('        ' + (done.stdout + done.stderr).strip().replace('\n', '\n        ')[:3000])
        return 1
    print('clean shared spelling check (scripts/ui_checks/us_spelling.py)')
    return 0


def make_zip():
    path = os.path.join(DIST, 'antsurance-kit.zip')
    if os.path.exists(path):
        os.remove(path)
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for folder, dirs, names in os.walk(OUT):
            dirs.sort()
            for name in sorted(names):
                full = os.path.join(folder, name)
                archive.write(full, os.path.join('antsurance-kit', os.path.relpath(full, OUT)))
    return path


def main():
    by_key, coordinates, streets, sample_by_key = collect_addresses()
    mapping, numbers = address_plan(by_key, coordinates, streets, sample_by_key)
    if '--scan' not in sys.argv:
        if os.path.isdir(OUT):
            shutil.rmtree(OUT)
        os.makedirs(OUT)
        copy_installer()
        context = {'addresses': (mapping, numbers), 'viewer_dashboards': []}
        counts, dropped = copy_metadata(context)
        counts['skills'] = copy_skills()
        if len(context['viewer_dashboards']) > 3:
            fail('%d dashboards run as the viewer and a new Developer Edition org allows three: %s. Make one run as a named user in scripts/gen_reports.py.'
                 % (len(context['viewer_dashboards']), ', '.join(sorted(context['viewer_dashboards']))))
        version = generated_files()
        print('Built %s' % (os.path.relpath(OUT, ROOT) if OUT.startswith(ROOT + os.sep) else OUT))
        slices = build_slices(version)
        manifest = build_manifest(version, slices, build_capabilities(version, slices))
        steps = build_uninstall(manifest)
        print('  files by phase: ' + ', '.join('%s %d' % (bucket, count) for bucket, count in sorted(counts.items())))
        print('  dropped: ' + '; '.join(dropped))
        print('  addresses rewritten: %d streets (%d households), %d exact coordinates rounded' % (len(mapping), len(by_key), len(numbers)))
        print('  manifest: %d classes, %d test classes, %d components, %d uninstall steps' % (len(manifest['ours']['apexClasses']), len(manifest['ours']['apexTestClasses']), len(manifest['ours']['lwc']), len(steps)))
    elif not os.path.isdir(OUT):
        fail('there is no built kit to scan. Run without --scan first.')
    findings, files = scan(set(mapping), set(numbers) - set(numbers.values()))
    bad = report(findings, files)
    bad += shared_spelling_check()
    if bad:
        print('SCAN FAILED: %d findings. The kit must not leave this machine. No zip was written.' % bad, file=sys.stderr)
        zipped = os.path.join(DIST, 'antsurance-kit.zip')
        if os.path.exists(zipped):
            os.remove(zipped)
        sys.exit(1)
    zipped = make_zip()
    print('Scan clean. Zip: %s' % (os.path.relpath(zipped, ROOT) if zipped.startswith(ROOT + os.sep) else zipped))


if __name__ == '__main__':
    main()
