"""Checks of the preflight and the coverage gate, run by selftest.py. No org and no key.

A stand-in kit and a stand-in pull are written to a temporary folder, and the org's answers are made up, so the
clash logic, the conventions and the coverage arithmetic are exercised the way a customer's org would exercise them.
"""
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_org  # noqa: E402
import preflight  # noqa: E402
from _common import apex_has_code, coverage_gate, coverage_rows, low_coverage_lines, our_coverage  # noqa: E402

HEAD = '<?xml version="1.0" encoding="UTF-8"?>\n'
NS = ' xmlns="http://soap.sforce.com/2006/04/metadata"'


def field(name, kind, extra=''):
    return HEAD + '<CustomField%s>\n    <fullName>%s</fullName>\n    <label>%s</label>\n    <type>%s</type>\n%s</CustomField>\n' % (NS, name, name.replace('__c', '').replace('_', ' '), kind, extra)


def rule(name, formula, active='true'):
    return HEAD + '<ValidationRule%s>\n    <fullName>%s</fullName>\n    <active>%s</active>\n    <errorConditionFormula>%s</errorConditionFormula>\n    <errorMessage>No.</errorMessage>\n</ValidationRule>\n' % (NS, name, active, formula)


def value_set(values):
    body = ''.join('    <standardValue>\n        <fullName>%s</fullName>\n        <default>false</default>\n        <label>%s</label>\n        <closed>%s</closed>\n    </standardValue>\n' % (name, name, closed) for name, closed in values)
    return HEAD + '<StandardValueSet%s>\n    <sorted>false</sorted>\n%s</StandardValueSet>\n' % (NS, body)


CLASS_META = HEAD + '<ApexClass%s>\n    <apiVersion>67.0</apiVersion>\n    <status>Active</status>\n</ApexClass>\n' % NS
OUR_CLASS = 'public with sharing class AntsuranceThing {\n    public static Integer one() {\n        return 1;\n    }\n}\n'
OUR_TRIGGER = 'trigger AntsuranceCaseTrigger on Case (before insert) {\n    AntsuranceCaseAutomation.run(Trigger.new);\n}\n'

KIT_FILES = {
    'force-app/main/default/classes/AntsuranceThing.cls': OUR_CLASS,
    'force-app/main/default/classes/AntsuranceThing.cls-meta.xml': CLASS_META,
    'force-app/main/default/triggers/AntsuranceCaseTrigger.trigger': OUR_TRIGGER,
    'force-app/main/default/objects/Case/fields/Reserve__c.field-meta.xml': field('Reserve__c', 'Currency', '    <precision>18</precision>\n    <scale>2</scale>\n'),
    'force-app/main/default/objects/Case/fields/Claim_Number__c.field-meta.xml': field('Claim_Number__c', 'Text', '    <length>20</length>\n'),
    'force-app/main/default/objects/Policy__c/Policy__c.object-meta.xml': HEAD + '<CustomObject%s>\n    <label>Policy</label>\n    <pluralLabel>Policies</pluralLabel>\n</CustomObject>\n' % NS,
    'force-app/main/default/permissionsets/Antsurance_CRM.permissionset-meta.xml': HEAD + '<PermissionSet%s>\n    <label>Antsurance CRM</label>\n</PermissionSet>\n' % NS,
    'optional/value-sets/standardValueSets/CaseStatus.standardValueSet-meta.xml': value_set([('New', 'false'), ('Appraisal', 'false'), ('Closed', 'true')]),
}
KIT = {
    'apiVersion': '67.0', 'insertsInto': ['Account', 'Contact', 'Case', 'Opportunity', 'Quote', 'Task', 'Lead'], 'requirements': {},
    'standardValueSets': {'CaseStatus': [{'fullName': 'New'}, {'fullName': 'Appraisal'}, {'fullName': 'Closed'}]},
    'ours': {
        'customObjects': ['Policy__c'], 'apexClasses': ['AntsuranceThing', 'AntsuranceThingTest'], 'apexTestClasses': ['AntsuranceThingTest'], 'portalClasses': [],
        'apexTriggers': ['AntsuranceCaseTrigger'], 'lwc': ['antsuranceClaude'], 'flows': ['File_a_Claim'], 'permissionSets': ['Antsurance_CRM'], 'apps': ['Antsurance'],
        'tabs': ['Antsurance_Home'], 'flexipages': ['Antsurance_Home_Page'], 'namedCredentials': ['Anthropic_API'], 'externalCredentials': ['Anthropic'], 'groups': ['Antsurance_Users'],
        'standardObjectFields': {'Case': ['Reserve__c', 'Claim_Number__c']}, 'recordTypes': {'Case': ['Claim', 'Policy_Service']}, 'validationRules': ['Case.Paid_Within_Reserve'],
        'layouts': ['Case-Claim Layout'], 'staticResources': ['antsuranceFonts'], 'reportFolders': ['Ants_Claims'], 'dashboardFolders': [],
    },
}
# A customer's org: its own naming, a field that carries one of our names as another type, a rule for every record
# type and one for its own, a trigger on Case, an app with a utility bar, and a case status that means something else.
THEIR_FILES = {
    'objects/Case/fields/Reserve__c.field-meta.xml': field('Reserve__c', 'Text', '    <length>80</length>\n'),
    'objects/Case/fields/ACME_Region__c.field-meta.xml': field('ACME_Region__c', 'Text', '    <description>Sales region.</description>\n    <inlineHelpText>Pick one.</inlineHelpText>\n'),
    'objects/Case/fields/ACME_Tier__c.field-meta.xml': field('ACME_Tier__c', 'Picklist', '    <description>Support tier.</description>\n'),
    'objects/Case/recordTypes/Warranty_Claim.recordType-meta.xml': HEAD + '<RecordType%s>\n    <fullName>Warranty_Claim</fullName>\n    <active>true</active>\n    <label>Claim</label>\n</RecordType>\n' % NS,
    'objects/Case/validationRules/ACME_Needs_Region.validationRule-meta.xml': rule('ACME_Needs_Region', 'ISBLANK(ACME_Region__c)'),
    'objects/Case/validationRules/ACME_Warranty_Only.validationRule-meta.xml': rule('ACME_Warranty_Only', 'AND(RecordType.DeveloperName = "Warranty_Claim", ISBLANK(Subject))'),
    'objects/Case/validationRules/ACME_Old.validationRule-meta.xml': rule('ACME_Old', 'TRUE', active='false'),
    'objects/ACME_Invoice__c/ACME_Invoice__c.object-meta.xml': HEAD + '<CustomObject%s>\n    <label>Invoice</label>\n</CustomObject>\n' % NS,
    'objects/ACME_Invoice__c/fields/ACME_Amount_Due__c.field-meta.xml': field('ACME_Amount_Due__c', 'Currency', '    <description>What is owed.</description>\n'),
    'objects/ACME_Invoice_Line__c/ACME_Invoice_Line__c.object-meta.xml': HEAD + '<CustomObject%s>\n    <label>Invoice Line</label>\n</CustomObject>\n' % NS,
    'objects/ACME_Shipment__c/ACME_Shipment__c.object-meta.xml': HEAD + '<CustomObject%s>\n    <label>Shipment</label>\n</CustomObject>\n' % NS,
    'triggers/ACME_CaseTrigger.trigger': 'trigger ACME_CaseTrigger on Case (before insert, after update) {\n    new ACME_CaseTriggerHandler().run();\n}\n',
    'triggers/ACME_CaseTrigger.trigger-meta.xml': HEAD + '<ApexTrigger%s>\n    <apiVersion>58.0</apiVersion>\n    <status>Active</status>\n</ApexTrigger>\n' % NS,
    'applications/ACME_Service.app-meta.xml': HEAD + '<CustomApplication%s>\n    <label>ACME Service</label>\n    <navType>Console</navType>\n    <uiType>Lightning</uiType>\n    <utilityBar>ACME_Service_UtilityBar</utilityBar>\n</CustomApplication>\n' % NS,
    'flexipages/ACME_Home.flexipage-meta.xml': HEAD + '<FlexiPage%s>\n    <masterLabel>ACME Home</masterLabel>\n    <type>HomePage</type>\n</FlexiPage>\n' % NS,
    'layouts/Case-ACME Case Layout.layout-meta.xml': HEAD + '<Layout%s>\n    <layoutSections>\n        <layoutColumns>\n            <layoutItems>\n                <behavior>Required</behavior>\n                <field>ACME_Region__c</field>\n            </layoutItems>\n        </layoutColumns>\n    </layoutSections>\n</Layout>\n' % NS,
    'standardValueSets/CaseStatus.standardValueSet-meta.xml': value_set([('New', 'false'), ('Triage', 'false'), ('Appraisal', 'true'), ('closed', 'true')]),
}
THEIR_CLASSES = ['ACME_CaseTriggerHandler', 'ACME_CaseService', 'ACME_InvoiceService', 'ACME_InvoiceSelector', 'ACME_InvoiceController', 'ACME_CaseService_Test', 'ACME_InvoiceService_Test']


def lay_out(root, files):
    for rel, text in files.items():
        path = os.path.join(root, *rel.split('/'))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write(text)


def answers_for(classes=(), triggers=(), case_fields=(), record_types=(), flows=(), sets=(), components=()):
    """The org's answers to every question the analysis asks, empty unless said otherwise."""
    answers = {name: (True, {'records': [], 'totalSize': 0}) for name, _ in analyze_org.questions(KIT['ours'])}
    answers['limits'] = (True, {name: {'Max': 15000, 'Remaining': 14000} for name in ('DataStorageMB', 'FileStorageMB', 'DailyApiRequests')})
    answers['permissions'] = (True, {'records': [{name: True for name in analyze_org.DEPLOY_PERMISSIONS}]})
    for name in analyze_org.STANDARD_OBJECTS:
        answers['describe' + name] = (True, {'fields': [], 'recordTypeInfos': []})
    answers['describeCase'] = (True, {
        'fields': [{'name': one, 'custom': True, 'createable': True, 'nillable': True, 'type': 'string'} for one in case_fields],
        'recordTypeInfos': [{'developerName': one, 'master': False} for one in record_types]})
    answers['classes'] = (True, {'records': [{'Name': name} for name in classes if name.startswith('Antsurance')]})
    answers['classList'] = (True, {'records': [{'Name': name, 'ApiVersion': 58.0} for name in classes]})
    answers['triggers'] = (True, {'records': [{'Name': name, 'TableEnumOrId': table, 'Status': 'Active', 'NamespacePrefix': None} for name, table in triggers]})
    answers['flowList'] = (True, {'records': list(flows)})
    answers['setList'] = (True, {'records': [{'Name': name} for name in sets]})
    answers['permissionSets'] = (True, {'records': [{'Name': name} for name in sets if name in KIT['ours']['permissionSets']]})
    answers['components'] = (True, {'records': [{'DeveloperName': name, 'ApiVersion': 58.0} for name in components]})
    return answers


FACTS = {'alias': 'their-sandbox', 'name': 'ACME', 'username': 'admin@acme.example', 'edition': 'Enterprise Edition', 'isProduction': False, 'isScratch': False,
         'isSandbox': True, 'isDeveloperEdition': False, 'namespace': None}
COST = {'pulled': True, 'mode': 'auto', 'why': ['Apex classes of its own'], 'pull': {'files': 20, 'folder': '.install/org-metadata/their-sandbox', 'seconds': 12, 'complete': True}}


class Preflight(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.mkdtemp(prefix='antsurance-selftest-')
        self.kit_root, self.pulled = os.path.join(self.work, 'kit'), os.path.join(self.work, 'pulled')
        lay_out(self.kit_root, KIT_FILES)
        os.makedirs(self.pulled)

    def tearDown(self):
        shutil.rmtree(self.work, ignore_errors=True)

    def judge(self, answers, cost=COST):
        return analyze_org.judge(KIT, dict(FACTS), answers, dict(cost), kit_root=self.kit_root, pulled_root=self.pulled)

    def keys(self, report, level):
        return [finding['key'] for finding in report.findings if finding['level'] == level]

    def test_the_pull_asks_for_theirs_whole_and_ours_by_name(self):
        text = preflight.manifest_xml(KIT)
        for wanted in ('<members>*</members>\n        <members>Account</members>', '<members>Case</members>', '<members>AntsuranceThing</members>', '<name>ApexClass</name>',
                       '<members>CaseStatus</members>', '<name>Layout</name>', '<name>LightningExperienceTheme</name>', '<version>67.0</version>'):
            self.assertIn(wanted, text)
        classes = text[:text.index('<name>ApexClass</name>')].rsplit('<types>', 1)[1]
        self.assertNotIn('*', classes, 'the org\'s own Apex is listed by name with a query, never pulled whole')

    def test_the_pull_names_only_what_the_questions_found_in_the_org(self):
        kit = dict(KIT, ours=dict(KIT['ours'], customMetadata=['Antsurance_AI_Setting.Default', 'Antsurance_Event.Storm']))
        answers = answers_for(classes=['AntsuranceThing', 'ACME_CaseService'])
        answers['ourObjects'] = (True, {'records': [{'QualifiedApiName': 'Antsurance_AI_Setting__mdt'}]})
        answers['quotes'] = (False, 'INVALID_TYPE: sObject type Quote is not supported')
        text = preflight.manifest_xml(kit, analyze_org.ours_in_org(answers, kit['ours']))
        self.assertIn('<members>AntsuranceThing</members>', text)
        self.assertNotIn('AntsuranceThingTest', text, 'a class the org does not have is not asked for')
        self.assertIn('<members>Antsurance_AI_Setting.Default</members>', text)
        self.assertNotIn('Antsurance_Event.Storm', text, 'a settings record whose type the org lacks would fail the whole pull')
        self.assertNotIn('<members>Quote</members>', text, 'Quotes are off in this org')
        self.assertNotIn('QuoteStatus', preflight.manifest_xml(dict(kit, standardValueSets={'QuoteStatus': [], 'CaseStatus': []}), analyze_org.ours_in_org(answers, kit['ours'])))

    def test_a_pull_the_org_refuses_is_a_decision_and_not_a_pass(self):
        answers = answers_for(classes=['ACME_CaseService'])
        for single in ('externalCredentials', 'validationRules', 'theme'):
            answers[single] = (True, {'records': []})
        report = self.judge(answers, {'pulled': False, 'mode': 'auto', 'why': ['Apex classes of its own'], 'pullFailed': 'The org gave back no metadata. Not allowed.'})
        self.assertIn('pullFailed', self.keys(report, 'change'))
        self.assertEqual('GO WITH CHANGES', report.verdict())

    def test_a_customers_org_gets_each_clash_once_with_its_reason(self):
        lay_out(self.pulled, THEIR_FILES)
        answers = answers_for(classes=THEIR_CLASSES, triggers=[('ACME_CaseTrigger', 'Case'), ('ACME_AssetTrigger', 'Asset')], case_fields=['Reserve__c', 'ACME_Region__c'],
                              record_types=['Warranty_Claim'])
        report = self.judge(answers)
        self.assertEqual('STOP', report.verdict())
        stops, decides, notes = self.keys(report, 'stop'), self.keys(report, 'change'), self.keys(report, 'note')
        self.assertIn('fieldTypeClash', stops)
        self.assertEqual([{'field': 'Case.Reserve__c', 'theirs': 'Text', 'ours': 'Currency'}], report.facts['fieldTypeClashes'])
        self.assertIn('nameClash', stops)
        for key in ('theirTriggers', 'validationRules', 'valueSetCollision', 'recordTypeLabels'):
            self.assertIn(key, decides)
        for key in ('validationRulesNarrow', 'besideYours', 'layoutRequired'):
            self.assertIn(key, notes)
        self.assertEqual(['Case.ACME_Needs_Region'], report.facts['validationRulesForEveryRecordType'], 'the rule for their own record type and the inactive one are not counted')
        triggers = next(finding for finding in report.findings if finding['key'] == 'theirTriggers')
        self.assertIn('ACME_CaseTrigger on Case', triggers['finding'])
        self.assertNotIn('Asset', triggers['finding'], 'a trigger on an object we never save to is not ours to report')
        self.assertIn('both sides have triggers', triggers['action'])
        collisions = {(one['set'], one['value']): one['differs'] for one in report.facts['valueSetCollisions']}
        self.assertIn('yours is closed and ours is not closed', collisions[('CaseStatus', 'Appraisal')])
        self.assertIn('yours is written "closed"', collisions[('CaseStatus', 'Closed')])
        self.assertEqual(['ACME_Service'], [app['name'] for app in report.facts['apps']])
        self.assertEqual('ACME_Service_UtilityBar', report.facts['apps'][0]['utilityBar'])

    def test_an_org_that_has_our_install_is_already_installed_and_not_a_wall_of_clashes(self):
        org = {rel.replace('force-app/main/default/', ''): text for rel, text in KIT_FILES.items() if rel.startswith('force-app/')}
        # The org fills in defaults our file does not spell out, and one class was changed since.
        org['objects/Case/fields/Reserve__c.field-meta.xml'] = field('Reserve__c', 'Currency', '    <precision>18</precision>\n    <scale>2</scale>\n    <trackHistory>false</trackHistory>\n    <required>false</required>\n')
        org['classes/AntsuranceThing.cls'] = OUR_CLASS.replace('return 1', 'return 2')
        org['standardValueSets/CaseStatus.standardValueSet-meta.xml'] = KIT_FILES['optional/value-sets/standardValueSets/CaseStatus.standardValueSet-meta.xml']
        lay_out(self.pulled, org)
        answers = answers_for(classes=['AntsuranceThing', 'AntsuranceThingTest'], triggers=[('AntsuranceCaseTrigger', 'Case')], case_fields=['Reserve__c', 'Claim_Number__c'],
                              record_types=['Claim', 'Policy_Service'], sets=['Antsurance_CRM'])
        report = self.judge(answers)
        self.assertTrue(report.facts['previousInstall'])
        self.assertEqual([], self.keys(report, 'stop'))
        self.assertNotIn('nameClash', [finding['key'] for finding in report.findings])
        self.assertEqual(['AntsuranceThing'], [entry['name'] for entry in report.facts['comparison']['different']])
        self.assertEqual(5, report.facts['comparison']['same'])
        installed = next(finding for finding in report.findings if finding['key'] == 'alreadyInstalled')
        self.assertEqual('note', installed['level'])
        self.assertIn('1 are in the org but differ', installed['finding'])
        self.assertEqual({'customObjects': 0, 'customFields': 0, 'apexClasses': 0, 'triggers': 0}, {key: report.conventions['counts'][key] for key in ('customObjects', 'customFields', 'apexClasses', 'triggers')},
                         'what we installed is never read as the org\'s own convention')

    def test_notes_on_or_off_is_a_note_and_never_a_decision(self):
        for answer, key in (((True, {'totalSize': 0}), 'notesOn'), ((False, 'INVALID_TYPE: sObject type ContentNote is not supported'), 'notesOff')):
            answers = answers_for()
            answers['notes'] = answer
            for single in ('externalCredentials', 'validationRules', 'theme'):
                answers[single] = (True, {'records': []})
            report = self.judge(answers, {'pulled': False, 'mode': 'auto', 'why': []})
            self.assertIn(key, self.keys(report, 'note'))
            self.assertNotIn('notChecked', [finding['key'] for finding in report.findings])

    def test_an_org_that_holds_one_part_of_the_app_is_not_a_clash(self):
        part_files = {'slices/ask-claude/main/default/classes/AntsuranceThing.cls': OUR_CLASS.replace('return 1', 'return 7'),
                      'slices/ask-claude/main/default/classes/AntsuranceThing.cls-meta.xml': CLASS_META}
        lay_out(self.kit_root, part_files)
        lay_out(self.pulled, {'classes/AntsuranceThing.cls': OUR_CLASS.replace('return 1', 'return 7'), 'classes/AntsuranceThing.cls-meta.xml': CLASS_META})
        kit = dict(KIT, slices={'ask-claude': {'label': 'Ask Claude', 'path': 'slices/ask-claude', 'permissionSet': 'Antsurance_Ask_Claude',
                                               'members': {'ApexClass': ['AntsuranceThing'], 'PermissionSet': ['Antsurance_Ask_Claude']}}},
                   ours=dict(KIT['ours'], apexClasses=['AntsuranceThing', 'AntsuranceThingTest', 'AntsuranceOther', 'AntsuranceMore']))
        answers = answers_for(classes=['AntsuranceThing'], sets=['Antsurance_Ask_Claude'])
        report = analyze_org.judge(kit, dict(FACTS), answers, dict(COST), kit_root=self.kit_root, pulled_root=self.pulled)
        self.assertEqual([], self.keys(report, 'stop'))
        part = next(finding for finding in report.findings if finding['key'] == 'partInstalled')
        self.assertIn('The Ask Claude part of Antsurance is installed here by itself (1 of its 1 classes found)', part['finding'])
        self.assertIn('1 components are in the org as this kit has them and 0 differ', part['finding'], 'compared with the part\'s own files, where the class returns 7')
        self.assertFalse(report.facts['previousInstall'])
        # The same class with no permission set of the part beside it is still somebody's class with our name.
        report = analyze_org.judge(kit, dict(FACTS), answers_for(classes=['AntsuranceThing']), dict(COST), kit_root=self.kit_root, pulled_root=self.pulled)
        self.assertIn('nameClash', self.keys(report, 'stop'))

    def test_a_new_empty_org_needs_no_pull_and_says_so(self):
        answers = answers_for()
        describes = {name: answers['describe' + name] for name in analyze_org.STANDARD_OBJECTS}
        self.assertEqual([], analyze_org.holds_anything(answers, describes, KIT['ours']))
        for single in ('externalCredentials', 'validationRules', 'theme'):
            answers[single] = (True, {'records': []})
        report = self.judge(answers, {'pulled': False, 'mode': 'auto', 'why': []})
        self.assertEqual([], self.keys(report, 'stop'))
        self.assertIn('No metadata was pulled', ' '.join(finding['finding'] for finding in report.findings))
        busy = answers_for(classes=['ACME_CaseService'])
        self.assertEqual(['Apex classes of its own'], analyze_org.holds_anything(busy, describes, KIT['ours']))

    def test_the_orgs_conventions_are_read_with_how_many_examples_each_rests_on(self):
        lay_out(self.pulled, THEIR_FILES)
        listing = {'classes': [{'Name': name, 'ApiVersion': 58.0} for name in THEIR_CLASSES + ['AntsuranceThing']],
                   'components': [{'DeveloperName': name, 'ApiVersion': 59.0} for name in ('acmeCaseList', 'acmeInvoiceCard', 'acmeHeader', 'antsuranceClaude')],
                   'flows': [{'ApiName': 'ACME_Case_Escalation'}, {'ApiName': 'File_a_Claim'}],
                   'sets': [{'Name': 'ACME_Service_Agent', 'Type': 'Regular'}, {'Name': 'Antsurance_CRM', 'Type': 'Regular'}, {'Name': 'SubscriptionManagementTaxAdmin', 'Type': 'Group'}],
                   'setGroups': [{'DeveloperName': 'ACME_Service_Team'}], 'auras': [], 'resources': [], 'notRead': []}
        found = preflight.read_conventions(KIT, preflight.read_inventory(self.pulled), listing)
        by_name = {line['what']: line for line in found['observations']}
        objects = by_name['Custom object API names']
        self.assertEqual(('Capital_Words', 3, 3, 'a guess'), (objects['does'], objects['matching'], objects['of'], objects['sure']))
        self.assertEqual('ACME_', objects['prefix']['text'])
        self.assertEqual('ACME_', by_name['Apex class names']['prefix']['text'])
        self.assertEqual('_Test at the end', by_name['Apex test class names']['does'])
        self.assertEqual({'Service': 2, 'Selector': 1, 'Controller': 1, 'TriggerHandler': 1}, by_name['Apex class roles']['roles'])
        self.assertEqual('acme', by_name['Lightning web component names']['prefix']['text'])
        self.assertNotIn('antsuranceClaude', by_name['Lightning web component names']['examples'])
        self.assertTrue(by_name['Triggers']['onePerObject'])
        self.assertIn('the logic is in handler classes', by_name['Triggers']['does'])
        self.assertEqual('3 of 3 custom fields carry a description', by_name['Field descriptions']['does'], 'the field that carries our name is not theirs to count')
        self.assertEqual('1 of 3 custom fields carry help text', by_name['Field help text']['does'])
        self.assertIn('In use', by_name['Permission set groups']['does'])
        self.assertEqual(1, found['counts']['permissionSets'], 'a set behind a permission set group is Salesforce\'s, not the org\'s')
        self.assertIn('Apex classes: 58 (7)', by_name['API versions in use']['does'])
        text = preflight.conventions_markdown(found, FACTS, COST['pull'], 'today')
        self.assertIn('keeps its `Antsurance` and `antsurance` prefix', text)
        self.assertIn('follows this org\'s own conventions', text)
        self.assertIn('Nothing of the org\'s is ever renamed', text)

    def test_what_the_org_rewrites_in_a_file_is_not_a_difference(self):
        flow = HEAD + '<Flow%s>\n    <assignments>\n        <name>Set</name>\n        <locationX>%s</locationX>\n        <locationY>%s</locationY>\n    </assignments>\n    <label>%s</label>\n</Flow>\n'
        tab = HEAD + '<CustomTab%s>\n    <customObject>true</customObject>\n    <motif>Custom77: %s</motif>\n</CustomTab>\n'
        page = HEAD + '<FlexiPage%s>\n    <fieldInstanceProperties>\n        <name>uiBehavior</name>\n        <value>%s</value>\n    </fieldInstanceProperties>\n</FlexiPage>\n'
        lay_out(self.kit_root, {'a/f.flow-meta.xml': flow % (NS, 176, 648, 'Add'), 'a/t.tab-meta.xml': tab % (NS, 'Shield'), 'a/p.flexipage-meta.xml': page % (NS, 'none'),
                                'a/g.flow-meta.xml': flow % (NS, 176, 648, 'Add')})
        lay_out(self.pulled, {'a/f.flow-meta.xml': flow % (NS, 0, 0, 'Add'), 'a/t.tab-meta.xml': tab % (NS, 'Locked'), 'a/p.flexipage-meta.xml': page % (NS, 'required'),
                              'a/g.flow-meta.xml': flow % (NS, 0, 0, 'Add a driver')})
        for name in ('f.flow-meta.xml', 't.tab-meta.xml', 'p.flexipage-meta.xml'):
            self.assertEqual((True, None), preflight.same_file(os.path.join(self.kit_root, 'a', name), os.path.join(self.pulled, 'a', name)), name)
        self.assertEqual((False, 'label'), preflight.same_file(os.path.join(self.kit_root, 'a', 'g.flow-meta.xml'), os.path.join(self.pulled, 'a', 'g.flow-meta.xml')))

    def test_names_are_sorted_by_how_they_are_written(self):
        for name, style in (('Policy_Coverage', 'Capital_Words'), ('PolicyCoverage', 'PascalCase'), ('policyCoverage', 'camelCase'), ('policy_coverage', 'lower_words'), ('Policy', 'one word')):
            self.assertEqual(style, preflight.style_of(name))
        self.assertEqual(('Sentence case', 'Title Case'), (preflight.label_style('Date of loss'), preflight.label_style('Date of Loss')))
        self.assertTrue(preflight.is_managed('npsp__Gift__c'))
        self.assertFalse(preflight.is_managed('ACME_Invoice__c'))
        self.assertIsNone(preflight.prefix_of(['CaseService', 'InvoiceService', 'OrderSelector', 'Billing']))


def run_result(rows):
    """What a test run with code coverage gives back, as the Salesforce CLI writes it."""
    return {'summary': {'outcome': 'Passed', 'testsRan': 4, 'testRunCoverage': '81%', 'orgWideCoverage': '79%'},
            'coverage': {'coverage': [{'id': '01p000000000000', 'name': name, 'totalLines': lines, 'totalCovered': covered, 'coveredPercent': 0, 'lines': {}} for name, covered, lines in rows]}}


class CoverageGate(unittest.TestCase):
    CLASSES = ['AntsuranceAiClient', 'AntsuranceClaimRules', 'AntsuranceShape']
    TRIGGERS = ['AntsuranceCaseTrigger']

    def test_the_message_names_the_class_its_figure_and_the_bar(self):
        ours = {'apexClasses': ['AntsuranceSalesforceNotes', 'AntsuranceSalesforceNotesTest'], 'apexTestClasses': ['AntsuranceSalesforceNotesTest'], 'apexTriggers': []}
        passed, lines = our_coverage(run_result([('AntsuranceSalesforceNotes', 31, 120)]), ours)
        self.assertFalse(passed)
        self.assertTrue(lines[0].startswith('FAIL  Coverage: our code is 25 percent covered overall'))
        self.assertIn('      AntsuranceSalesforceNotes is 25 percent covered (31 of 120 lines). The bar is 75.', lines)
        self.assertTrue(any('returns early because a feature is off' in line for line in lines), 'the usual cause in an org with a feature off is said')
        passed, lines = our_coverage(run_result([('AntsuranceSalesforceNotes', 100, 120)]), ours)
        self.assertEqual((True, 1), (passed, len(lines)))
        self.assertTrue(lines[0].startswith('PASS  Coverage: our code is 83 percent covered overall'))

    def test_every_shape_of_result_is_read(self):
        self.assertEqual({'AntsuranceAiClient': (90, 100)}, coverage_rows(run_result([('AntsuranceAiClient', 90, 100)])))
        self.assertEqual({'AntsuranceAiClient': (90, 100)}, coverage_rows({'codecoverage': [{'name': 'AntsuranceAiClient', 'numLinesCovered': 90, 'numLinesUncovered': 10, 'percentage': '90%'}]}))
        deploy = {'details': {'runTestResult': {'codeCoverage': [{'name': 'AntsuranceAiClient', 'type': 'Class', 'numLocations': '100', 'numLocationsNotCovered': '10'}]}}}
        self.assertEqual({'AntsuranceAiClient': (90, 100)}, coverage_rows(deploy))
        one = {'details': {'runTestResult': {'codeCoverage': {'name': 'AntsuranceCaseTrigger', 'type': 'Trigger', 'numLocations': 8, 'numLocationsNotCovered': 0}}}}
        self.assertEqual({'AntsuranceCaseTrigger': (8, 8)}, coverage_rows(one))
        self.assertEqual({}, coverage_rows({'summary': {'outcome': 'Passed'}}))

    def test_a_deploy_that_fails_on_coverage_names_the_class_its_figure_and_the_bar(self):
        deploy = {'status': 'Failed', 'details': {'runTestResult': {'codeCoverage': [
            {'name': 'AntsuranceSalesforceNotes', 'type': 'Class', 'numLocations': '120', 'numLocationsNotCovered': '89'},
            {'name': 'AntsuranceAiClient', 'type': 'Class', 'numLocations': '100', 'numLocationsNotCovered': '10'},
            {'name': 'TheirOwnClass', 'type': 'Class', 'numLocations': '100', 'numLocationsNotCovered': '100'}]}}}
        self.assertEqual(['  COVERAGE AntsuranceSalesforceNotes is 25 percent covered (31 of 120 lines). The bar is 75 percent for every class and trigger in a deploy.'], low_coverage_lines(deploy))
        self.assertEqual([], low_coverage_lines({'details': {}}))

    def test_a_covered_install_passes_and_says_the_overall_figure(self):
        rows = coverage_rows(run_result([('AntsuranceAiClient', 90, 100), ('AntsuranceClaimRules', 75, 100), ('AntsuranceCaseTrigger', 8, 8), ('SomebodyElses', 0, 500)]))
        found, problems = coverage_gate(rows, self.CLASSES, self.TRIGGERS, has_code=lambda name: name != 'AntsuranceShape')
        self.assertEqual([], problems)
        self.assertEqual(83, int(found['overall']), 'only our classes and triggers count toward our figure')
        self.assertEqual(['AntsuranceShape'], found['nothing'])
        self.assertTrue(found['lowest'].startswith('AntsuranceClaimRules 75'))

    def test_a_class_under_75_fails_and_is_named(self):
        rows = coverage_rows(run_result([('AntsuranceAiClient', 90, 100), ('AntsuranceClaimRules', 149, 200), ('AntsuranceCaseTrigger', 8, 8)]))
        found, problems = coverage_gate(rows, self.CLASSES, self.TRIGGERS, has_code=lambda name: name != 'AntsuranceShape')
        self.assertEqual(['1 under 75 percent'], problems)
        self.assertEqual('AntsuranceClaimRules is 74 percent covered (149 of 200 lines). The bar is 75.', found['lines'][0])

    def test_a_trigger_with_no_coverage_fails_and_so_does_a_class_no_test_reaches(self):
        rows = coverage_rows(run_result([('AntsuranceAiClient', 90, 100), ('AntsuranceClaimRules', 80, 100)]))
        found, problems = coverage_gate(rows, self.CLASSES, self.TRIGGERS, has_code=lambda name: True)
        self.assertEqual(['2 with no coverage'], problems)
        self.assertIn('Trigger AntsuranceCaseTrigger has no coverage recorded: no test that ran reaches it. The bar is 75.', found['lines'])
        self.assertTrue(any('AntsuranceShape' in line for line in found['lines']))

    def test_a_low_overall_figure_fails_and_a_run_without_coverage_is_not_a_pass(self):
        rows = {'AntsuranceAiClient': (10, 1000), 'AntsuranceClaimRules': (100, 100), 'AntsuranceCaseTrigger': (8, 8)}
        _, problems = coverage_gate(rows, self.CLASSES, self.TRIGGERS, has_code=lambda name: name != 'AntsuranceShape')
        self.assertEqual(['1 under 75 percent', '10 percent overall'], problems)
        _, problems = coverage_gate({}, [], [], has_code=lambda name: False)
        self.assertEqual(['the run reported no coverage at all'], problems)

    def test_code_is_told_from_a_class_with_nothing_to_cover(self):
        for text in ('public interface Shape { Decimal area(); }', 'public class Oops extends Exception {}', 'public enum Line { AUTO, HOME }',
                     'public class Row { public String name; public Integer count { get; set; } public class Inner { public Id who; } }'):
            self.assertFalse(apex_has_code(text), text)
        for text in ("public class K { public static final String A = 'x;y'; }", 'public class S { /* note; */ public static Integer f() { return 1; } }'):
            self.assertTrue(apex_has_code(text), text)


__all__ = ['Preflight', 'CoverageGate']
