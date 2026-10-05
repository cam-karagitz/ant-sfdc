"""Checks of the install menu and of fitting a part to another data model, run by selftest.py. No org is touched.

What a person can choose, what each choice brings, what an org holds of it, removing a part, access to a part, the
preflight's reading of an org that holds parts, what a part names, and the adapter. Everything here reads the kit's
own description of itself (kit-manifest.json, kit-scan.json, capabilities/), so it needs a built kit and is skipped
in a folder that has none.
"""
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import adapt_capability  # noqa: E402
import analyze_org  # noqa: E402
import assign_access  # noqa: E402
import capabilities  # noqa: E402
import deploy_phase  # noqa: E402
import describe_capability  # noqa: E402
import uninstall  # noqa: E402
import verify  # noqa: E402
from _common import KIT_ROOT, SetupError  # noqa: E402

BUILT = os.path.exists(os.path.join(KIT_ROOT, 'kit-manifest.json')) and os.path.exists(os.path.join(KIT_ROOT, 'kit-scan.json'))
__all__ = ['TheMenu', 'WhatAnOrgHolds', 'InstallingAndRemovingAPart', 'CheckingAndAccess', 'WhatAPartNames', 'TheAdapter', 'SeenInAnOrg', 'ThePortalTakenOutAgain', 'TheAdapterSaysWhatItLeaves']


def kit():
    with open(os.path.join(KIT_ROOT, 'kit-manifest.json')) as handle:
        return json.load(handle)


def holding(*names, extra=None, mine=()):
    """What an org that holds these choices answers, in the shape capabilities.read_standing gives."""
    all_of = kit()['capabilities']
    have = {kind: set() for kind in capabilities.ASKED}
    for name in names:
        if name == 'everything':
            ours = kit()['ours']
            for kind, key in (('ApexClass', 'apexClasses'), ('ApexTrigger', 'apexTriggers'), ('Flow', 'flows'), ('CustomObject', 'customObjects'), ('PermissionSet', 'permissionSets'),
                              ('CustomTab', 'tabs'), ('CustomApplication', 'apps'), ('ApexPage', 'apexPages'), ('StaticResource', 'staticResources')):
                have[kind] |= set(ours.get(key, []))
            continue
        for kind in capabilities.ASKED:
            have[kind] |= set((all_of[name].get('detect') or {}).get(kind, []))
    for kind, found in (extra or {}).items():
        have[kind] |= set(found)
    have.update({'LightningComponentBundle': None, 'mine': set(mine), 'quotes': True, 'path': True, 'missingValues': {}, 'unanswered': []})
    return have


@unittest.skipUnless(BUILT, 'needs a built kit')
class TheMenu(unittest.TestCase):
    def test_every_choice_says_what_it_is_what_it_brings_and_how_to_install_it(self):
        found = capabilities.listed()
        self.assertEqual(['everything', 'data-model', 'automation', 'components', 'pages', 'ask-claude', 'portal', 'look-and-feel', 'sample-data', 'coverage-agent'], capabilities.order())
        for name in capabilities.order():
            for key in ('kind', 'label', 'option', 'summary'):
                self.assertTrue(found[name].get(key), '%s has no %s' % (name, key))
            self.assertTrue(found[name].get('command') or found[name].get('how'), '%s does not say how it is installed' % name)
        text = '\n'.join(capabilities.menu())
        for name in capabilities.order():
            self.assertIn(found[name]['label'], text)
        self.assertIn('How the parts stack', text)
        self.assertIn('Its tests work with records of', text, 'the menu says why the components come with the automations')
        self.assertIn('Digital Experiences', text, 'the portal says what it switches on')

    def test_the_shape_is_the_one_the_scan_found(self):
        self.assertEqual(['data-model'], capabilities.chain('data-model'))
        self.assertEqual(['data-model', 'automation'], capabilities.chain('automation'))
        self.assertEqual(['data-model', 'automation', 'components'], capabilities.chain('components'), 'the components come with the automations')
        self.assertEqual(['data-model', 'automation', 'components', 'pages'], capabilities.chain('pages'))
        self.assertEqual(['ask-claude'], capabilities.chain('ask-claude'))
        self.assertEqual(['data-model', 'automation', 'components', 'portal'], capabilities.chain('portal'), 'the portal does not need the staff pages')
        self.assertEqual(['everything', 'sample-data'], capabilities.chain('sample-data'))
        found = capabilities.listed()
        counts_on = found['components']['testsCountOn']['automation']
        self.assertIn('Case', counts_on['objects'], 'the components come with the automations because their tests save claims, not because of a name')
        self.assertNotIn('it names', found['components']['bringsWhy']['automation'].split(';')[0])
        self.assertIn('AntsuranceClaimsAssistantIntakeTest', counts_on['tests'])
        self.assertNotIn('ApexClass:AntsuranceAiClient', capabilities.detail('components')['nodes'], 'what the automations hold is not held twice')
        self.assertIn('NamedCredential', found['automation']['members'], 'the automations carry the connection to Claude, and say so')
        self.assertIn('connection to Claude', found['automation']['carriedWords'])

    def test_a_part_that_is_not_in_the_kit_is_refused_with_the_ones_that_are(self):
        with self.assertRaises(SetupError) as refused:
            capabilities.named('half-of-it')
        self.assertIn('data-model', str(refused.exception))
        self.assertIn('ask-claude', str(refused.exception))

    def test_every_part_stands_alone_with_what_it_brings(self):
        """The build proves this before it writes the kit. This reads the written kit again, as the installer will."""
        scan = describe_capability.load_scan()
        base = os.path.join(KIT_ROOT, 'force-app', 'main', 'default')
        for name in kit()['capabilityLayers']:
            whole = set()
            for other in capabilities.chain(name):
                part = capabilities.detail(other)
                whole |= set(part['nodes'])
                for path in part['fileList']:
                    self.assertTrue(os.path.exists(os.path.join(base, path)), '%s lists %s, which the kit does not have' % (other, path))
            for node in sorted(whole):
                for target, edge in scan['edges'].get(node, {}).items():
                    if edge['how'] == 'hard' and scan['nodes'][target]['type'] != 'StandardValueSet':
                        self.assertIn(target, whole, '%s needs %s, which "%s" does not hold or bring' % (node, target, name))

    def test_a_parts_permission_set_grants_only_what_the_part_holds(self):
        for name in kit()['capabilityLayers']:
            part = capabilities.detail(name)
            if not part['permissionSet']:
                continue
            with open(os.path.join(KIT_ROOT, part['path'], 'main', 'default', 'permissionsets', part['permissionSet'] + '.permissionset-meta.xml'), encoding='utf-8') as handle:
                text = handle.read()
            own = set(part['nodes'])
            for tag, kind in (('apexClass', 'ApexClass'), ('field', 'CustomField'), ('recordType', 'RecordType'), ('apexPage', 'ApexPage')):
                for value in re.findall(r'<%s>([^<]+)</%s>' % (tag, tag), text):
                    self.assertIn('%s:%s' % (kind, value), own, '%s grants %s, which "%s" does not hold' % (part['permissionSet'], value, name))
            for value in re.findall(r'<tab>([^<]+)</tab>', text):
                self.assertTrue(value.startswith('standard-') or 'CustomTab:' + value in own)
            self.assertTrue(part['permissionSet'].startswith('Antsurance_'), 'our sets carry our prefix')
        sets = [capabilities.named(name)['permissionSet'] for name in kit()['capabilityLayers']]
        self.assertEqual(len(sets), len(set(sets)))


@unittest.skipUnless(BUILT, 'needs a built kit')
class WhatAnOrgHolds(unittest.TestCase):
    def test_an_empty_org_holds_nothing_of_ours(self):
        state = capabilities.judge(kit(), holding())
        self.assertEqual(([], {}, {}, False), (state['installed'], state['partly'], state['outside'], state['whole']))

    def test_the_data_model_alone(self):
        have = holding('data-model')
        state = capabilities.judge(kit(), have)
        self.assertEqual(['data-model'], state['installed'])
        self.assertEqual({}, state['outside'])
        lines = '\n'.join(capabilities.standing_lines(kit(), have, state))
        self.assertIn('In the org now: Insurance data model.', lines)
        self.assertIn('Nothing else of ours is in the org', lines)

    def test_the_automations_on_the_data_model_do_not_look_like_half_the_components(self):
        state = capabilities.judge(kit(), holding('data-model', 'automation'))
        self.assertEqual(['data-model', 'automation'], state['installed'])
        self.assertEqual(({}, {}), (state['partly'], state['outside']), 'the classes the two share are explained by the one that is installed')

    def test_something_of_ours_that_no_installed_part_holds_is_named(self):
        have = holding('data-model', extra={'ApexClass': ['AntsuranceDeskController']})
        state = capabilities.judge(kit(), have)
        self.assertEqual(['data-model'], state['installed'])
        self.assertIn('components', state['partly'])
        self.assertIn('AntsuranceDeskController', '\n'.join(capabilities.standing_lines(kit(), have, state)))

    def test_an_app_is_in_the_org_whether_or_not_the_person_asking_may_open_it(self):
        asks = dict(capabilities.standing_questions(kit(), 'me@example.com'))
        self.assertIn('FROM%20CustomApplication', asks['app:Antsurance'], 'apps are counted in the org, not read from the list of apps this person may open')
        self.assertNotIn('AppDefinition', ' '.join(asks.values()))
        answers = {name: (True, {'records': [], 'totalSize': 0}) for name in asks}
        answers['app:Antsurance'] = (True, {'totalSize': 1})
        have = capabilities.read_standing(kit(), answers)
        self.assertEqual({'Antsurance'}, have['CustomApplication'])
        answers['app:Ask_Claude'] = (False, 'refused')
        self.assertIsNone(capabilities.read_standing(kit(), answers)['CustomApplication'], 'an answer the org refuses is unknown, not absent')

    def test_the_portal_and_what_it_put_in_are_not_strays(self):
        have = holding('data-model', 'automation', 'components', 'pages', 'portal', extra={'PermissionSet': ['Antsurance_Portal_Staff']})
        state = capabilities.judge(kit(), have)
        self.assertEqual(['data-model', 'automation', 'components', 'pages', 'portal'], state['installed'])
        self.assertEqual(({}, {}), (state['partly'], state['outside']), 'the portal\'s event, its permission sets and the shared chat tab are all explained')

    def test_the_whole_app_is_the_whole_app_not_four_parts(self):
        state = capabilities.judge(kit(), holding('everything'))
        self.assertTrue(state['whole'])
        self.assertEqual(['everything'], state['installed'])
        self.assertEqual({}, state['outside'])

    def test_what_a_part_needs_first_is_asked_of_the_org(self):
        have = dict(holding(), quotes=False, path=False, missingValues={'CaseStatus': ['Under Investigation', 'Appraisal']})
        lines = ' '.join(capabilities.missing_first(kit(), 'automation', have))
        self.assertIn('--enable quotes', lines)
        self.assertIn('--phase value-sets', lines)
        self.assertIn('Under Investigation', lines)
        self.assertNotIn('--enable path', lines, 'only the pages need Path')
        self.assertIn('--enable path', ' '.join(capabilities.missing_first(kit(), 'pages', have)))
        self.assertEqual([], capabilities.missing_first(kit(), 'automation', holding()))

    def test_the_preflight_does_not_take_installed_parts_for_a_clash(self):
        have = holding('data-model', 'automation')
        answers = {'classes': (True, {'records': [{'Name': name} for name in sorted(have['ApexClass'])]}),
                   'triggers': (True, {'records': [{'Name': name} for name in sorted(have['ApexTrigger'])] + [{'Name': 'TheirCaseTrigger'}]}),
                   'flows': (True, {'records': [{'ApiName': name} for name in sorted(have['Flow'])]}),
                   'ourObjects': (True, {'records': [{'QualifiedApiName': name} for name in sorted(have['CustomObject'])]}),
                   'tabs': (True, {'records': []}), 'apps': (True, {'records': []}), 'pages': (True, {'records': []}), 'resourceList': (True, {'records': []}),
                   'permissionSets': (True, {'records': []}), 'setList': (True, {'records': [{'Name': name} for name in sorted(have['PermissionSet'])]})}
        part = analyze_org.installed_part(kit(), answers)
        self.assertIsNotNone(part, 'an org that holds two parts holds parts')
        self.assertEqual(['data-model', 'automation'], part['installed'])
        self.assertEqual('Insurance data model and Automations', part['label'])
        self.assertIn('Policy__c', part['names'])
        self.assertIn('AntsuranceCaseAutomation', part['names'])
        answers['setList'] = (True, {'records': [{'Name': 'Antsurance_CRM'}]})
        self.assertIsNone(analyze_org.installed_part(kit(), answers), 'the whole app is not a part')


@unittest.skipUnless(BUILT, 'needs a built kit')
class InstallingAndRemovingAPart(unittest.TestCase):
    def test_asking_for_a_part_says_what_it_brings_before_anything_is_deployed(self):
        todo, lines = capabilities.plan(kit(), 'automation', capabilities.judge(kit(), holding()))
        self.assertEqual(['data-model', 'automation'], todo)
        said = ' '.join(lines)
        self.assertIn('"Automations" needs "Insurance data model"', said)
        self.assertIn('it will be installed first', said)
        self.assertIn('So 2 sets will be installed', said)

    def test_what_is_already_there_is_not_installed_twice(self):
        todo, lines = capabilities.plan(kit(), 'automation', capabilities.judge(kit(), holding('data-model')))
        self.assertEqual(['automation'], todo)
        self.assertIn('it is already there', ' '.join(lines))
        todo, _ = capabilities.plan(kit(), 'pages', capabilities.judge(kit(), holding('data-model', 'automation')))
        self.assertEqual(['components', 'pages'], todo)

    def test_what_is_staged_for_a_part_is_its_own_files_and_its_permission_set(self):
        for name in kit()['capabilityLayers']:
            part = capabilities.detail(name)
            staged = deploy_phase.stage_layer(name)
            found = sorted(os.path.relpath(os.path.join(folder, one), os.path.join(staged, 'main', 'default')).replace(os.sep, '/') for folder, _, files in os.walk(staged) for one in files)
            wanted = sorted(part['fileList'] + (['permissionsets/%s.permissionset-meta.xml' % part['permissionSet']] if part['permissionSet'] else []))
            self.assertEqual(wanted, found, '%s stages exactly its own files' % name)
            shutil.rmtree(staged)

    def test_a_part_runs_its_own_tests_and_they_are_in_it(self):
        for name in kit()['capabilityLayers']:
            part = capabilities.detail(name)
            self.assertEqual(part['tests'], deploy_phase.tests_for(deploy_phase.ONLY + name))
            self.assertTrue(set(part['tests']) <= set(part['members'].get('ApexClass', [])))
            for one in part['covered']['classes']:
                self.assertNotIn(one, part['tests'])
        self.assertEqual([], deploy_phase.tests_for(deploy_phase.ONLY + 'data-model'), 'the data model holds no code')
        self.assertEqual(deploy_phase.slice_named('ask-claude')['tests'], deploy_phase.tests_for(deploy_phase.ONLY + 'ask-claude'), 'Ask Claude is installed as it was')

    def test_a_class_under_the_bar_is_named_with_its_figure(self):
        part = capabilities.named('automation')
        rows = [{'name': name, 'numLocations': '100', 'numLocationsNotCovered': '5'} for name in part['covered']['classes'] + part['covered']['triggers']]
        rows[0] = {'name': part['covered']['classes'][0], 'numLocations': '120', 'numLocationsNotCovered': '89'}
        line = deploy_phase.coverage_line({'details': {'runTestResult': {'codeCoverage': rows}}}, part)
        self.assertIn('short of the bar', line)
        self.assertIn('%s is 25 percent covered (31 of 120 lines). The bar is 75.' % part['covered']['classes'][0], line)
        rows[0]['numLocationsNotCovered'] = '10'
        self.assertIn('Every class and trigger in this set is at 75 percent or more', deploy_phase.coverage_line({'details': {'runTestResult': {'codeCoverage': rows}}}, part))

    def test_a_set_one_of_a_parts_tests_needs_the_installer_to_hold_goes_in_first(self):
        deployed, assigned = [], []
        saved = (deploy_phase.deploy, deploy_phase.assign_set)
        def stand_in(org, phase, staged, *rest):
            with open(os.path.join(staged, 'main', 'default', 'permissionsets', 'Antsurance_Desk.permissionset-meta.xml'), encoding='utf-8') as handle:
                deployed.append((phase, sorted(os.listdir(os.path.join(staged, 'main', 'default', 'permissionsets'))), handle.read()))
            return {'status': 0, 'result': {'status': 'Succeeded'}}
        deploy_phase.deploy = stand_in
        deploy_phase.assign_set = lambda org, name: assigned.append(name)

        class Args:
            wait, test_level = 5, 'RunSpecifiedTests'
        try:
            import contextlib
            import io
            have = {'mine': {'Antsurance_Data_Model'}}
            with contextlib.redirect_stdout(io.StringIO()):
                given = deploy_phase.hold_first({'alias': 'any', 'isProduction': False}, capabilities.named('components'), have, Args)
                again = deploy_phase.hold_first({'alias': 'any', 'isProduction': False}, capabilities.named('components'), have, Args)
                none = deploy_phase.hold_first({'alias': 'any', 'isProduction': False}, capabilities.named('automation'), {'mine': set()}, Args)
        finally:
            deploy_phase.deploy, deploy_phase.assign_set = saved
        self.assertEqual((['Antsurance_Desk'], [], []), (given, again, none))
        self.assertEqual(['Antsurance_Desk'], assigned)
        self.assertEqual(1, len(deployed))
        self.assertIn('<fieldPermissions>', deployed[0][2])
        self.assertNotIn('<customPermissions>', deployed[0][2], 'only its object and field access goes in first: the rest arrives with the part')
        self.assertNotIn('<classAccesses>', deployed[0][2])
        self.assertEqual([], deploy_phase.tests_for(deploy_phase.ONLY + 'held-first'))

    def test_a_part_cannot_be_removed_from_under_one_that_is_built_on_it(self):
        state = capabilities.judge(kit(), holding('data-model', 'automation', 'components', 'pages'))
        self.assertEqual(['pages'], capabilities.built_on(kit(), 'components', state))
        self.assertEqual(['automation', 'components', 'pages'], capabilities.built_on(kit(), 'data-model', state))
        self.assertEqual(['components', 'pages'], capabilities.built_on(kit(), 'automation', state))
        self.assertEqual([], capabilities.built_on(kit(), 'pages', state))

    def run_removal(self, name, *installed):
        have = holding(*installed)
        said = []
        saved = (deploy_phase.say_standing, deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch)
        deploy_phase.say_standing = lambda kit_, org, title=None: (have, capabilities.judge(kit_, have))
        deploy_phase.announce = lambda org, action: said.append(action)
        deploy_phase.guard_production = lambda org, allowed: None
        deploy_phase.batch = lambda org, asks: {name_: (True, {'records': []}) for name_, _ in asks}

        class Args:
            yes, allow_production, target_org, wait, test_level = False, False, 'any', 45, 'RunSpecifiedTests'
        try:
            import contextlib
            import io
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                deploy_phase.remove_layer({'alias': 'any', 'username': 'me@example.com', 'name': 'Any'}, name, Args)
            return out.getvalue()
        finally:
            deploy_phase.say_standing, deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch = saved

    def test_removal_refuses_and_names_what_is_built_on_the_part(self):
        with self.assertRaises(SetupError) as refused:
            self.run_removal('components', 'data-model', 'automation', 'components', 'pages')
        self.assertIn('"Page layouts, record pages and the app" is built on "Screen components and the Claude features"', str(refused.exception))
        with self.assertRaises(SetupError) as absent:
            self.run_removal('automation', 'data-model')
        self.assertIn('is not installed', str(absent.exception))
        with self.assertRaises(SetupError) as whole:
            self.run_removal('automation', 'everything')
        self.assertIn('uninstall.py', str(whole.exception))

    def test_removal_leaves_what_another_part_in_the_org_holds(self):
        alone = self.run_removal('automation', 'data-model', 'automation')
        self.assertIn('AntsuranceCaseTrigger', alone)
        self.assertIn('AntsuranceAiClient', alone, 'with nothing else there, the shared classes go with it')
        self.assertIn('Nothing was changed', alone)
        with self.assertRaises(SetupError) as refused:
            self.run_removal('automation', 'data-model', 'automation', 'components')
        self.assertIn('"Screen components and the Claude features" is built on "Automations"', str(refused.exception))
        above = self.run_removal('components', 'data-model', 'automation', 'components')
        self.assertIn('ApexClass (89)', above)
        self.assertIn('PermissionSet (2): Antsurance_Components, Antsurance_Desk', above)
        self.assertNotIn('ApexTrigger', above, 'what the automations hold stays when the components go')
        self.assertNotIn('NamedCredential', above, 'and so does the connection to Claude')

    def test_the_data_model_is_removed_by_the_uninstall_not_by_itself(self):
        with self.assertRaises(SetupError) as refused:
            self.run_removal('data-model', 'data-model')
        self.assertIn('uninstall.py', str(refused.exception))

    def test_the_uninstall_knows_the_parts_permission_sets(self):
        sets = uninstall.part_sets(kit())
        for one in ('Antsurance_Data_Model', 'Antsurance_Automation', 'Antsurance_Components', 'Antsurance_Pages', 'Antsurance_Portal_Staff', 'Antsurance_Ask_Claude'):
            self.assertIn(one, sets)
        listed = [name for step in uninstall.steps()['steps'] for name in step['types'].get('PermissionSet', [])]
        for one in ('Antsurance_Data_Model', 'Antsurance_Automation', 'Antsurance_Components', 'Antsurance_Pages', 'Antsurance_CRM'):
            self.assertIn(one, listed, 'the whole uninstall removes the sets a part left behind')


@unittest.skipUnless(BUILT, 'needs a built kit')
class CheckingAndAccess(unittest.TestCase):
    def test_a_part_that_is_all_there_passes_its_checks(self):
        have = holding('data-model', 'automation', mine=['Antsurance_Data_Model', 'Antsurance_Automation'])
        lines = verify.capability_checks(kit(), 'automation', have, capabilities.judge(kit(), have))
        self.assertEqual([True, True, True], [passed for passed, _ in lines], lines)

    def test_a_missing_part_a_missing_set_and_a_stray_class_each_fail(self):
        have = holding('data-model', mine=['Antsurance_Data_Model'], extra={'ApexClass': ['AntsuranceDeskController']})
        lines = verify.capability_checks(kit(), 'automation', have, capabilities.judge(kit(), have))
        self.assertEqual([False, False, False], [passed for passed, _ in lines])
        self.assertIn('"Automations" is not in the org in full', lines[0][1])
        self.assertIn('Antsurance_Automation', lines[1][1])
        self.assertIn('--capability automation --only-me --yes', lines[1][1])
        self.assertIn('AntsuranceDeskController', lines[2][1])

    def test_the_bar_is_held_for_the_part_and_what_it_brings(self):
        part = capabilities.named('automation')
        names = part['covered']['classes'] + part['covered']['triggers']
        result = {'coverage': {'coverage': [{'name': name, 'totalLines': 100, 'totalCovered': 90} for name in names]}}
        self.assertTrue(verify.capability_coverage(kit(), 'automation', result)[0])
        result['coverage']['coverage'][0]['totalCovered'] = 40
        passed, lines = verify.capability_coverage(kit(), 'automation', result)
        self.assertFalse(passed)
        self.assertIn('%s is 40 percent covered (40 of 100 lines). The bar is 75.' % names[0], '\n'.join(lines))
        result['coverage']['coverage'] = result['coverage']['coverage'][1:]
        passed, lines = verify.capability_coverage(kit(), 'automation', result)
        self.assertFalse(passed, 'a class the run says nothing about is not at the bar')

    def test_access_to_a_part_is_its_own_sets_and_those_it_is_built_on(self):
        saved = (assign_access.BASE_SETS, assign_access.DESK_SET, assign_access.PAGES_SET, assign_access.WHAT)
        try:
            assign_access.for_capability('automation')
            self.assertEqual((['Antsurance_Data_Model', 'Antsurance_Automation'], None, None), (assign_access.BASE_SETS, assign_access.DESK_SET, assign_access.PAGES_SET))
            assign_access.for_capability('components')
            self.assertEqual((['Antsurance_Data_Model', 'Antsurance_Automation', 'Antsurance_Components'], 'Antsurance_Desk', None), (assign_access.BASE_SETS, assign_access.DESK_SET, assign_access.PAGES_SET))
            assign_access.for_capability('pages')
            self.assertEqual('Antsurance_Pages', assign_access.PAGES_SET, 'the people who hold the pages are the ones the app shows our record pages to')
            self.assertEqual(4, len(assign_access.BASE_SETS))
            assign_access.for_capability('ask-claude')
            self.assertEqual(['Antsurance_Ask_Claude'], assign_access.BASE_SETS)
            with self.assertRaises(SetupError):
                assign_access.for_capability('sample-data')
        finally:
            assign_access.BASE_SETS, assign_access.DESK_SET, assign_access.PAGES_SET, assign_access.WHAT = saved
        self.assertEqual(['Antsurance_CRM', 'Antsurance_Claude'], assign_access.BASE_SETS, 'without --capability it is the whole app, as before')


@unittest.skipUnless(BUILT, 'needs a built kit')
class WhatAPartNames(unittest.TestCase):
    def test_one_trigger_and_the_code_it_needs(self):
        nodes, data, narrowed = describe_capability.describe('automation', ['ApexTrigger:AntsurancePolicyTrigger'])
        self.assertEqual(['ApexClass:AntsurancePolicyAutomation', 'ApexClass:AntsurancePolicyAutomationTest', 'ApexTrigger:AntsurancePolicyTrigger'], sorted(nodes))
        self.assertEqual(1, narrowed)
        policy = data['objects']['Policy__c']
        self.assertEqual(['Account__c', 'Effective_Date__c', 'Expiration_Date__c', 'Policyholder_Name__c', 'Status__c'], sorted(policy['fields']))
        self.assertEqual('MasterDetail', policy['fields']['Account__c']['type'])
        self.assertEqual('Account', policy['fields']['Account__c']['referenceTo'])
        self.assertEqual({'Policy__c.Status__c': ['Active']}, data['picklistValues'])
        self.assertFalse(data['objects']['Account']['ours'])
        text = '\n'.join(describe_capability.as_text(capabilities.named('automation'), data, narrowed))
        self.assertIn('MasterDetail to Account', text)
        self.assertIn('values named in code: Active', text)

    def test_a_whole_part_with_counts(self):
        _, data, _ = describe_capability.describe('automation')
        counts = data['counts']
        self.assertEqual(3, counts['components']['ApexTrigger'])
        self.assertEqual(5, counts['components']['Flow'])
        self.assertGreater(counts['fields'], 50)
        self.assertIn('Claim', data['objects']['Case']['recordTypes'])
        self.assertIn('Case.Status', data['picklistValues'], 'values of a standard picklist that the code names are listed too')

    def test_ask_claude_names_nothing_of_ours_but_its_setting(self):
        _, data, _ = describe_capability.describe('ask-claude')
        ours = sorted(name for name, found in data['objects'].items() if found['ours'])
        self.assertEqual(['Antsurance_AI_Setting__mdt'], ours, 'the chat names its own setting and no insurance object')

    def test_a_component_that_is_not_in_the_part_is_refused(self):
        with self.assertRaises(SetupError):
            describe_capability.describe('automation', ['ApexClass:AntsuranceDeskController'])


@unittest.skipUnless(BUILT, 'needs a built kit')
class TheAdapter(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.mkdtemp(prefix='antsurance-adapt-')
        with open(os.path.join(KIT_ROOT, 'examples', 'acme', 'mapping.json'), encoding='utf-8') as handle:
            self.mapping = json.load(handle)
        self.model = os.path.join(KIT_ROOT, 'examples', 'acme', 'model')

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def read(self, path):
        with open(os.path.join(self.out, 'main', 'default', path), encoding='utf-8') as handle:
            return handle.read()

    def test_a_mapping_that_leaves_something_out_is_refused_by_name(self):
        for missing, words in ((('objects', 'Policy__c'), 'object Policy__c'), (('fields', 'Policy__c.Account__c'), 'field Policy__c.Account__c (MasterDetail to Account)'),
                               (('picklistValues', 'Policy__c.Status__c'), 'picklist values of Policy__c.Status__c named in the code: Active')):
            mapping = json.loads(json.dumps(self.mapping))
            del mapping[missing[0]][missing[1]]
            with self.assertRaises(SetupError) as refused:
                adapt_capability.adapt('automation', mapping, self.out, self.model)
            self.assertIn(words, str(refused.exception))
            self.assertIn('Nothing was written', str(refused.exception))
            self.assertEqual([], os.listdir(self.out))

    def test_the_sure_renames_are_done_and_the_kit_is_not_touched(self):
        source = os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'classes', 'AntsurancePolicyAutomation.cls')
        with open(source, 'rb') as handle:
            before = hashlib.sha256(handle.read()).hexdigest()
        report = adapt_capability.adapt('automation', self.mapping, self.out, self.model)
        with open(source, 'rb') as handle:
            self.assertEqual(before, hashlib.sha256(handle.read()).hexdigest(), 'our own file is as it was')
        self.assertEqual(['classes/AcmePolicyAutomation.cls', 'classes/AcmePolicyAutomation.cls-meta.xml', 'classes/AcmePolicyAutomationTest.cls', 'classes/AcmePolicyAutomationTest.cls-meta.xml',
                          'triggers/AcmePolicyTrigger.trigger', 'triggers/AcmePolicyTrigger.trigger-meta.xml'], report['files'])
        trigger, handler, test = self.read('triggers/AcmePolicyTrigger.trigger'), self.read('classes/AcmePolicyAutomation.cls'), self.read('classes/AcmePolicyAutomationTest.cls')
        self.assertIn('trigger AcmePolicyTrigger on Acme_Policy__c(before insert, before update)', trigger)
        self.assertIn('AcmePolicyAutomation.stampPolicyholder(Trigger.new);', trigger)
        self.assertIn('public static void stampPolicyholder(List<Acme_Policy__c> policies)', handler)
        self.assertIn('String.isBlank(policy.Customer_Name__c) && policy.Customer__c != null', handler)
        self.assertIn("new Acme_Policy__c(Name = name, Customer__c = customer.Id, Policy_Status__c = 'In Force', Start_Date__c = start, End_Date__c = start.addYears(1))", test)
        self.assertIn('[SELECT Name, Customer_Name__c FROM Acme_Policy__c]', test)
        for text in (trigger, handler, test):
            self.assertNotIn('Antsurance', text)
            self.assertIsNone(re.search(r'\bPolicy__c\b|Policyholder_Name__c|\bAccount__c\b', text))
        self.assertGreater(report['counts']['renames'], 30)
        self.assertEqual({'field', 'object', 'file name', 'class name', 'picklist value'}, set(report['renamed']))

    def test_what_needs_judgment_is_written_down_with_file_line_and_reason(self):
        report = adapt_capability.adapt('automation', self.mapping, self.out, self.model)
        kinds = report['judgmentByKind']
        self.assertEqual({'type differs', 'name is a number', 'required', 'test builds records'}, set(kinds))
        for item in report['judgment']:
            self.assertTrue(item['file'].startswith('main/default/') and item['line'] > 0 and len(item['why']) > 40, item)
        said = '\n'.join(item['why'] for item in report['judgment'])
        self.assertIn('Ours is a master-detail and theirs is a lookup', said)
        self.assertIn('holds 255 characters with us and Acme_Policy__c.Customer_Name__c holds 120', said)
        self.assertIn('The org requires Region__c on Acme_Policy__c', said)
        self.assertIn('its name is an auto number', said)
        with open(os.path.join(self.out, 'ADAPT-REPORT.md'), encoding='utf-8') as handle:
            text = handle.read()
        self.assertIn('never made to pass by deleting a test or an assertion', text)
        self.assertIn('`main/default/classes/AcmePolicyAutomationTest.cls`, line 5', text)

    def test_without_the_orgs_metadata_it_says_types_were_not_compared(self):
        report = adapt_capability.adapt('automation', self.mapping, self.out, None)
        self.assertFalse(report['typesChecked'])
        self.assertNotIn('type differs', report['judgmentByKind'])
        with open(os.path.join(self.out, 'ADAPT-REPORT.md'), encoding='utf-8') as handle:
            self.assertIn('Types were not compared', handle.read())

    def test_the_copies_are_named_by_the_orgs_conventions(self):
        mapping = {key: value for key, value in self.mapping.items() if key != 'prefix'}
        conventions = {'observations': [{'what': 'Apex class names', 'prefix': {'text': 'ACME_', 'sure': 'sure'}}, {'what': 'Apex test class names', 'style': '_Test at the end'}]}
        report = adapt_capability.adapt('automation', mapping, self.out, self.model, conventions)
        self.assertIn('classes/ACME_PolicyAutomation.cls', report['files'])
        self.assertIn('classes/ACME_PolicyAutomation_Test.cls', report['files'])
        self.assertIn('triggers/ACME_PolicyTrigger.trigger', report['files'])
        shutil.rmtree(self.out)
        os.makedirs(self.out)
        bare = adapt_capability.adapt('automation', mapping, self.out, self.model, {'observations': []})
        self.assertIn('classes/PolicyAutomation.cls', bare['files'])
        self.assertIn('names', bare['judgmentByKind'], 'with no prefix to go on it says so')

    def adapter(self, mapping):
        scan = describe_capability.load_scan()
        nodes, _, _ = describe_capability.describe('automation', None, None, scan)
        named = describe_capability.as_data(describe_capability.what_it_names(scan, nodes))
        return adapt_capability.Adapter(adapt_capability.Plan(mapping, scan, nodes, named), {}, {}, {})

    def test_a_name_that_is_both_an_object_and_a_field_is_told_apart_by_where_it_stands(self):
        mapping = {'objects': {'Policy__c': 'Acme_Policy__c'}, 'recordTypes': {'Case.Claim': {'to': 'Case.Loss'}, 'Case.Policy_Service': {'toFieldValue': {'field': 'Case.Type', 'value': 'Service'}}},
                   'fields': {'Case.Policy__c': 'Case.Acme_Policy_Ref__c', 'Policy__c.Status__c': 'Acme_Policy__c.Policy_Status__c', 'Policy__c.Account__c': 'Acme_Policy__c.Customer__c',
                              'Case.Reserve_Amount__c': {'leaveOut': True}},
                   'picklistValues': {'Policy__c.Status__c': {'Active': 'In Force', 'Lapsed': None}}}
        apex = '''public class X {
    void run(Id policyId, Account customer) {
        Case claim = [SELECT Id, Policy__c, Policy__r.Status__c FROM Case WHERE Policy__c = :policyId AND RecordType.DeveloperName = 'Claim' LIMIT 1];
        Policy__c policy = new Policy__c(Account__c = customer.Id, Status__c = 'Active');
        claim.Policy__c = policy.Id;
        Map<Id, Policy__c> byId = new Map<Id, Policy__c>([SELECT Id, Status__c FROM Policy__c WHERE Account__c = :customer.Id]);
        if (policy.Status__c == 'Lapsed' || claim.Reserve_Amount__c > 0) { return; }
        Id service = Schema.SObjectType.Case.getRecordTypeInfosByDeveloperName().get('Policy_Service').getRecordTypeId();
    }
}'''
        adapter = self.adapter(mapping)
        new = adapter.apex('X.cls', apex)
        self.assertIn("[SELECT Id, Acme_Policy_Ref__c, Acme_Policy_Ref__r.Policy_Status__c FROM Case WHERE Acme_Policy_Ref__c = :policyId AND RecordType.DeveloperName = 'Loss' LIMIT 1]", new)
        self.assertIn("Acme_Policy__c policy = new Acme_Policy__c(Customer__c = customer.Id, Policy_Status__c = 'In Force');", new)
        self.assertIn('claim.Acme_Policy_Ref__c = policy.Id;', new)
        self.assertIn('Map<Id, Acme_Policy__c> byId = new Map<Id, Acme_Policy__c>([SELECT Id, Policy_Status__c FROM Acme_Policy__c WHERE Customer__c = :customer.Id]);', new)
        self.assertIn("policy.Policy_Status__c == 'Lapsed' || claim.Reserve_Amount__c > 0", new, 'a value with no match and a field left out are not changed')
        kinds = sorted({(item['kind'], item['line']) for item in adapter.judgment})
        self.assertEqual([('left out', 7), ('picklist value', 7), ('record type', 8)], kinds)
        self.assertIn('Case.Type = "Service"', [item['why'] for item in adapter.judgment if item['kind'] == 'record type'][0])

    def test_a_flow_names_their_object_and_fields(self):
        scan = describe_capability.load_scan()
        with open(os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'flows', 'Policy_Past_Due_Follow_Up.flow-meta.xml'), encoding='utf-8') as handle:
            flow = handle.read()
        mapping = {'objects': {'Policy__c': 'Acme_Policy__c'}, 'fields': {'Policy__c.Payment_Status__c': 'Acme_Policy__c.Billing_State__c', 'Policy__c.Account__c': 'Acme_Policy__c.Customer__c'},
                   'picklistValues': {'Policy__c.Payment_Status__c': {'Past Due': 'Overdue'}}}
        adapter = self.adapter(mapping)
        new = adapter.flow('flow.xml', flow)
        self.assertIn('<object>Acme_Policy__c</object>', new)
        self.assertNotIn('<object>Policy__c</object>', new)
        self.assertIn('Billing_State__c', new)
        self.assertNotIn('Payment_Status__c', new)
        if '<stringValue>Past Due</stringValue>' in flow:
            self.assertIn('<stringValue>Overdue</stringValue>', new)
        del scan


class Quiet:
    """Runs a function with the installer's words caught, and hands them back."""
    def __call__(self, function, *args, **kwargs):
        import contextlib
        import io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.result = function(*args, **kwargs)
        return out.getvalue()


@unittest.skipUnless(BUILT, 'needs a built kit')
class SeenInAnOrg(unittest.TestCase):
    """Each of these is a fault a scratch org showed on 2026-10-05, kept from coming back."""

    def test_a_tab_is_in_the_org_whether_or_not_the_person_asking_may_open_it(self):
        asks = dict(capabilities.standing_questions(kit(), 'me@example.com'))
        self.assertNotIn('TabDefinition', ' '.join(asks.values()), 'the list of tabs holds only the tabs this person may open')
        self.assertIn('FROM%20CustomTab', asks['tab:Antsurance_Home'])
        self.assertIn('tooling/', asks['tab:Antsurance_Home'])
        self.assertNotIn('tab:Policy__c', asks, 'the tab of an object is named after the object and is not asked for')
        self.assertLessEqual(len(asks), 25, 'one call to the org')
        answers = {name: (True, {'records': [], 'totalSize': 0}) for name in asks}
        answers['PermissionSet'] = (True, {'records': [{'Name': 'Antsurance_Pages'}]})
        answers['app:Antsurance'] = (True, {'totalSize': 1})
        have = capabilities.read_standing(kit(), answers)
        self.assertEqual(set(), have['CustomTab'])
        self.assertIn('pages', capabilities.judge(kit(), have)['partly'])
        for name in asks:
            if name.startswith('tab:'):
                answers[name] = (True, {'totalSize': 1})
        have = capabilities.read_standing(kit(), answers)
        self.assertIn('Antsurance_Home', have['CustomTab'])
        self.assertIn('pages', capabilities.judge(kit(), have)['installed'], 'the app, the named tabs and the set are the pages, whoever asks')
        answers['tab:Antsurance_Home'] = (False, 'refused')
        self.assertIsNone(capabilities.read_standing(kit(), answers)['CustomTab'], 'an answer the org refuses is unknown, not absent')

    def test_the_preflight_counts_apps_and_tabs_too(self):
        asks = dict(analyze_org.questions(kit()['ours']))
        self.assertNotIn('TabDefinition', ' '.join(str(one) for one in asks.values()))
        self.assertNotIn('AppDefinition', ' '.join(str(one) for one in asks.values()))
        answers = {'app:Antsurance': (True, {'totalSize': 1}), 'tab:Antsurance_Home': (True, {'totalSize': 1}), 'tab:Antsurance_Tasks': (True, {'totalSize': 0})}
        analyze_org.from_counts(answers)
        self.assertEqual([{'DeveloperName': 'Antsurance'}], answers['apps'][1]['records'])
        self.assertEqual([{'Name': 'Antsurance_Home'}], answers['tabs'][1]['records'])
        kept = {'apps': (True, {'records': []}), 'tabs': (True, {'records': []}), 'app:Antsurance': (True, {'totalSize': 1})}
        analyze_org.from_counts(kept)
        self.assertEqual([], kept['apps'][1]['records'], 'an earlier read kept in .install/ is left as it was')

    def test_a_tab_two_choices_hold_does_not_make_both_look_half_installed(self):
        have = holding('data-model', 'automation', 'components', extra={'CustomApplication': ['Antsurance'], 'CustomTab': ['Antsurance_Claude', 'Antsurance_Home']})
        state = capabilities.judge(kit(), have)
        self.assertIn('pages', state['partly'])
        self.assertNotIn('ask-claude', state['partly'], 'the chat tab is part of the pages that are half there, not a sign of Ask Claude')
        alone = capabilities.judge(kit(), holding(extra={'CustomTab': ['Antsurance_Claude']}))
        self.assertEqual({'pages', 'ask-claude'}, set(alone['partly']), 'with nothing else to go on it could be either')

    def test_the_pages_do_not_borrow_the_components_reason(self):
        found = capabilities.listed()
        self.assertEqual({}, found['pages']['testsCountOn'], 'the pages hold no tests')
        self.assertNotIn('test classes', found['pages']['bringsWhy']['automation'])
        self.assertIn('automation', found['components']['testsCountOn'])

    def test_a_removal_that_stopped_part_way_can_be_run_again(self):
        remover = InstallingAndRemovingAPart('run_removal')
        have = holding('data-model', 'automation', 'components')
        have['PermissionSet'] -= {'Antsurance_Components'}
        state = capabilities.judge(kit(), have)
        self.assertIn('components', state['partly'])
        self.assertEqual(['components'], capabilities.built_on(kit(), 'automation', state), 'a part that is half there still stands on what it needs')
        saved = (deploy_phase.say_standing, deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch)
        deploy_phase.say_standing = lambda kit_, org, title=None: (have, capabilities.judge(kit_, have))
        deploy_phase.announce = lambda org, action: None
        deploy_phase.guard_production = lambda org, allowed: None
        deploy_phase.batch = lambda org, asks: {name_: (True, {'records': []}) for name_, _ in asks}

        class Args:
            yes, allow_production, target_org, wait, test_level = False, False, 'any', 45, 'RunSpecifiedTests'
        try:
            said = Quiet()(deploy_phase.remove_layer, {'alias': 'any', 'username': 'me@example.com', 'name': 'Any'}, 'components', Args)
            with self.assertRaises(SetupError) as refused:
                Quiet()(deploy_phase.remove_layer, {'alias': 'any', 'username': 'me@example.com', 'name': 'Any'}, 'automation', Args)
        finally:
            deploy_phase.say_standing, deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch = saved
        self.assertIn('Only part of "Screen components and the Claude features" is in the org', said)
        self.assertIn('ApexClass (89)', said)
        self.assertIn('uninstall.py --target-org any --capability components', str(refused.exception), 'the refusal gives the command to run first')
        del remover

    def test_a_class_of_the_orgs_own_that_uses_ours_stops_the_removal(self):
        asked = []

        def ids(org, asks):
            return {name: (True, {'records': [{'Id': 'id-of-ours-%d' % number, 'Name': 'AntsuranceAddress'} for number in range(1)]}) for name, _ in asks}

        def uses(org, text):
            asked.append(text)
            return True, [{'MetadataComponentName': 'AcmeAddressHelper', 'MetadataComponentType': 'ApexClass', 'RefMetadataComponentName': 'AntsuranceAddress'},
                          {'MetadataComponentName': 'AntsuranceCaseAutomation', 'MetadataComponentType': 'ApexClass', 'RefMetadataComponentName': 'AntsuranceAddress'}]
        found, caution = deploy_phase.used_by_theirs({'alias': 'any'}, kit(), ['AntsuranceAddress'], ids, uses)
        self.assertEqual(({'AcmeAddressHelper': ['AntsuranceAddress']}, None), (found, caution), 'ours using ours is not a finding')
        self.assertIn('MetadataComponentDependency', asked[0])
        self.assertIn('RefMetadataComponentId IN', asked[0], 'asked by id: the org does not let this be asked by name')
        lines, stop = deploy_phase.say_used_by_theirs(found, caution)
        self.assertIn('AcmeAddressHelper (uses AntsuranceAddress)', lines[0])
        self.assertIn('without a word', lines[1])
        self.assertIn('1 class of the org\'s own uses a class that would go', stop)
        self.assertIn('Change or remove it first', stop, 'one class is "it", as the org showed with one class of its own')
        self.assertIn('Nothing was changed', stop)
        two = dict(found, AcmeQuoteHelper=['AntsuranceAddress'])
        self.assertIn('2 classes of the org\'s own use a class that would go', deploy_phase.say_used_by_theirs(two, None)[1])
        self.assertIn('Change or remove them first', deploy_phase.say_used_by_theirs(two, None)[1])
        lines, stop = deploy_phase.say_used_by_theirs({}, None)
        self.assertIsNone(stop)
        self.assertIn('No class or trigger of the org', lines[0])
        found, caution = deploy_phase.used_by_theirs({'alias': 'any'}, kit(), ['AntsuranceAddress'], ids, lambda org, text: (False, 'refused'))
        self.assertEqual({}, found)
        self.assertIn('Look for yourself', caution, 'an org that will not answer is said, not passed')
        self.assertIsNone(deploy_phase.say_used_by_theirs(found, caution)[1])
        self.assertEqual(({}, None), deploy_phase.used_by_theirs({'alias': 'any'}, kit(), [], ids, uses))

    def test_the_removal_itself_stops_on_it_before_anything_changes(self):
        have = holding('data-model', 'automation')
        changed = []
        saved = (deploy_phase.say_standing, deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch, deploy_phase.tooling, deploy_phase.rest, deploy_phase.sf)
        deploy_phase.say_standing = lambda kit_, org, title=None: (have, capabilities.judge(kit_, have))
        deploy_phase.announce = lambda org, action: None
        deploy_phase.guard_production = lambda org, allowed: None
        deploy_phase.batch = lambda org, asks: {name_: (True, {'records': [{'Id': 'id-of-ours', 'Name': 'AntsuranceAddress'}] if name_.startswith('ids') else []}) for name_, _ in asks}
        deploy_phase.tooling = lambda org, text: (True, [{'MetadataComponentName': 'TheirHelper', 'MetadataComponentType': 'ApexClass', 'RefMetadataComponentName': 'AntsuranceAddress'}])
        deploy_phase.rest = lambda *args, **kwargs: changed.append('rest')
        deploy_phase.sf = lambda *args, **kwargs: changed.append('sf')

        class Args:
            yes, allow_production, target_org, wait, test_level = True, False, 'any', 45, 'RunSpecifiedTests'
        try:
            with self.assertRaises(SetupError) as stopped:
                Quiet()(deploy_phase.remove_layer, {'alias': 'any', 'username': 'me@example.com', 'name': 'Any'}, 'automation', Args)
        finally:
            (deploy_phase.say_standing, deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch, deploy_phase.tooling, deploy_phase.rest, deploy_phase.sf) = saved
        self.assertIn('TheirHelper (uses AntsuranceAddress)', str(stopped.exception))
        self.assertEqual([], changed, 'no access was taken away and nothing was deployed')

    def test_ask_claude_alone_is_not_taken_from_under_a_class_of_theirs_either(self):
        changed = []
        saved = (deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch, deploy_phase.tooling, deploy_phase.rest, deploy_phase.sf)
        deploy_phase.announce = lambda org, action: None
        deploy_phase.guard_production = lambda org, allowed: None
        deploy_phase.batch = lambda org, asks: {name_: (True, {'records': [{'Id': 'id-of-ours', 'Name': 'AntsuranceClaudeModel'}] if name_.startswith('ids') else []}) for name_, _ in asks}
        deploy_phase.tooling = lambda org, text: (True, [{'MetadataComponentName': 'AcmeClaudeModel', 'MetadataComponentType': 'ApexClass', 'RefMetadataComponentName': 'AntsuranceClaudeModel'}])
        deploy_phase.rest = lambda *args, **kwargs: changed.append('rest')
        deploy_phase.sf = lambda *args, **kwargs: changed.append('sf')

        class Args:
            allow_production, target_org, wait, test_level = False, 'any', 45, 'RunSpecifiedTests'
        try:
            Args.yes = False
            said = Quiet()(deploy_phase.remove_slice, {'alias': 'any', 'username': 'me@example.com', 'name': 'Any'}, 'ask-claude', Args)
            Args.yes = True
            with self.assertRaises(SetupError) as stopped:
                Quiet()(deploy_phase.remove_slice, {'alias': 'any', 'username': 'me@example.com', 'name': 'Any'}, 'ask-claude', Args)
        finally:
            deploy_phase.announce, deploy_phase.guard_production, deploy_phase.batch, deploy_phase.tooling, deploy_phase.rest, deploy_phase.sf = saved
        self.assertIn('AcmeClaudeModel (uses AntsuranceClaudeModel)', said)
        self.assertIn('this would stop there with --yes', said)
        self.assertIn('AcmeClaudeModel (uses AntsuranceClaudeModel)', str(stopped.exception))
        self.assertEqual([], changed, 'a model class of the org\'s own extends ours: removing the chat would break it')

    def test_report_and_dashboard_folders_are_removed_the_way_salesforce_takes_them(self):
        text = uninstall.package_xml({'ReportFolder': ['Ants_Book'], 'DashboardFolder': ['Ants_Leadership'], 'Report': ['Ants_Book/Billing_Plans'], 'ReportType': ['Ants_Cases']})
        self.assertNotIn('ReportFolder', text, 'asked for by that name, Salesforce ignores a folder without a word')
        self.assertNotIn('DashboardFolder', text)
        self.assertEqual(1, text.count('<name>Report</name>'))
        self.assertIn('<members>Ants_Book</members>', text)
        self.assertIn('<members>Ants_Book/Billing_Plans</members>', text)
        self.assertIn('<members>Ants_Leadership</members>\n        <name>Dashboard</name>', text)
        calls = []

        def delete(org, number, types):
            calls.append({kind: list(members) for kind, members in types.items()})
            if len(calls) == 1:
                return {'applied': False, 'failures': [{'componentType': 'Report', 'fullName': 'Ants_Book', 'problem': 'The folder is not empty.'}], 'message': None}
            return {'applied': True, 'failures': [], 'message': None}
        uninstall.LENIENT.append('--ignore-errors')
        try:
            ok, refused, _ = uninstall.remove_step('any', 2, {'name': 'x', 'types': {'ReportFolder': ['Ants_Book', 'Ants_Claims'], 'ReportType': ['Ants_Cases']}}, delete)
        finally:
            uninstall.LENIENT.clear()
        self.assertTrue(ok)
        self.assertEqual(['Ants_Claims'], calls[1]['ReportFolder'], 'a refused folder is set aside by the name Salesforce gave it, and the rest go')
        self.assertEqual(['Report Ants_Book: The folder is not empty.'], refused)

    def test_a_record_type_is_switched_off_without_naming_its_picklist_values(self):
        with open(os.path.join(KIT_ROOT, 'force-app', 'main', 'default', 'objects', 'Case', 'recordTypes', 'Claim.recordType-meta.xml'), encoding='utf-8') as handle:
            text = handle.read()
        self.assertIn('<picklistValues>', text)
        body = uninstall.switched_off(text)
        self.assertIn('<active>false</active>', body)
        self.assertIn('<businessProcess>Claims</businessProcess>', body)
        self.assertNotIn('picklistValues', body, 'a value the org\'s field does not have would refuse the whole change')
        self.assertNotIn('compactLayoutAssignment', body)

    def test_the_logo_stays_while_the_theme_shows_it(self):
        refused = {'result': {'details': {'componentFailures': {'componentType': 'ContentAsset', 'fullName': 'Claude_Spark', 'problem': 'This Asset File is referenced elsewhere in salesforce.com. Remove the usage and try again. : Branding Set Property - x'}}}}
        self.assertTrue(deploy_phase.held_by_the_theme(refused))
        other = {'result': {'details': {'componentFailures': [{'componentType': 'ContentAsset', 'fullName': 'Claude_Spark', 'problem': 'in use by a page of yours'}]}}}
        self.assertFalse(deploy_phase.held_by_the_theme(other))
        self.assertFalse(deploy_phase.held_by_the_theme({'result': {'details': {}}}))

    def test_the_look_and_feel_carries_the_logo_its_theme_shows(self):
        scan = describe_capability.load_scan()
        self.assertIn('ContentAsset:Claude_Spark', scan['edges']['BrandingSet:LEXTHEMINGAnthropic'], 'the theme names its logo by address, and the scan reads that')
        entry = capabilities.named('look-and-feel')
        self.assertEqual(['data-model'], entry['brings'], 'a theme does not have to bring the pages for the sake of a logo')
        self.assertEqual(['Claude_Spark'], entry['members']['ContentAsset'])
        self.assertTrue(os.path.exists(os.path.join(KIT_ROOT, 'optional', 'look-and-feel', 'contentassets', 'Claude_Spark.asset-meta.xml')))

    def test_the_preflight_names_a_part_as_installed_and_only_strays_as_clashes(self):
        ours = kit()['ours']
        have = holding('data-model')
        part = {'name': 'data-model', 'installed': ['data-model'], 'label': 'Insurance data model', 'members': capabilities.named('data-model')['members'],
                'names': {one.split('.')[-1] for group in capabilities.named('data-model')['members'].values() for one in group} | {'Antsurance_Data_Model'}}
        empty = (True, {'records': []})
        answers = {'ourObjects': (True, {'records': [{'QualifiedApiName': name} for name in sorted(have['CustomObject'])]}), 'classes': empty, 'components': empty, 'resourceList': empty,
                   'folders': (True, {'records': [{'DeveloperName': 'Ants_Book'}]}), 'flows': empty, 'permissionSets': empty, 'apps': empty, 'tabs': empty,
                   'namedCredentials': empty, 'externalCredentials': empty, 'groups': (True, {'records': [{'DeveloperName': 'Antsurance_Users'}]})}
        report = analyze_org.Report()
        analyze_org.check_names(report, answers, {}, ours, None, part)
        stops = [finding for finding in report.findings if finding['level'] == 'stop']
        self.assertEqual(1, len(stops), [finding['finding'] for finding in stops])
        self.assertIn('Ants_Book', stops[0]['finding'])
        self.assertIn('in none of the parts installed here', stops[0]['finding'])
        self.assertNotIn('Policy__c', ' '.join(finding['finding'] for finding in stops), 'what the installed part holds is not a clash')
        self.assertTrue(any('installed here by itself' in finding['finding'] for finding in report.findings))

    def test_the_record_types_an_uninstall_leaves_do_not_stop_the_next_install(self):
        ours = kit()['ours']
        empty = (True, {'records': []})
        answers = {name: empty for name in ('ourObjects', 'classes', 'components', 'resourceList', 'folders', 'flows', 'permissionSets', 'apps', 'tabs', 'namedCredentials', 'externalCredentials', 'groups')}

        def types(*pairs):
            return (True, {'fields': [], 'recordTypeInfos': [{'developerName': 'Master', 'active': True, 'master': True}] + [{'developerName': one, 'active': on, 'master': False} for one, on in pairs]})

        def judged(describes, org=None, also=None):
            report = analyze_org.Report()
            if org:
                report.facts['org'] = org
            analyze_org.check_names(report, dict(answers, **(also or {})), describes, ours)
            return [(finding['level'], finding['key']) for finding in report.findings], ' '.join(finding['finding'] + ' ' + finding['action'] for finding in report.findings)
        # As the org was after the whole uninstall on 2026-10-05: five switched off, the sale's still on as the last of its object.
        left = {'Account': types(('Agency', False), ('Business', False), ('Household', False)), 'Case': types(('Claim', False), ('Policy_Service', False)), 'Opportunity': types(('Policy_Sale', True))}
        saved = analyze_org.load_state
        try:
            analyze_org.load_state = lambda org: {'phases': {}}
            levels, said = judged(left, {'orgId': '00D-any', 'alias': 'any'})
            self.assertEqual([('change', 'leftByUninstall')], levels, 'with no note of an uninstall it is the person\'s to decide, and not a stop')
            self.assertIn('Opportunity.Policy_Sale', said)
            self.assertIn('switches them on again', said)
            analyze_org.load_state = lambda org: {'phases': {'uninstall': {'at': '2026-10-05 18:10 UTC', 'outcome': 'removed'}}}
            levels, said = judged(left, {'orgId': '00D-any', 'alias': 'any'})
            self.assertEqual([('note', 'leftByUninstall')], levels, 'the kit\'s own notes say it removed the app from this org')
            self.assertIn('2026-10-05 18:10 UTC', said)
            self.assertIn('Not a clash', said)
            theirs = dict(left, Case=types(('Claim', True), ('Support', True)))
            self.assertEqual([('stop', 'nameClash')], judged(theirs, {'orgId': '00D-any', 'alias': 'any'})[0], 'a Claim record type in use beside another is not what an uninstall leaves')
            more = {'classes': (True, {'records': [{'Name': ours['apexClasses'][0]}]})}
            self.assertEqual({('stop', 'nameClash')}, set(judged(left, {'orgId': '00D-any', 'alias': 'any'}, more)[0]), 'anything else of ours beside them is still a clash')
        finally:
            analyze_org.load_state = saved
        self.assertEqual([('change', 'leftByUninstall')], judged(left)[0], 'an org the notes cannot be looked up for is read by what it holds')

    def test_a_count_of_screen_components_that_differs_says_which_way(self):
        have = holding('data-model', 'automation', 'components')
        have['LightningComponentBundle'] = 82
        fewer = '\n'.join(capabilities.standing_lines(kit(), have, capabilities.judge(kit(), have)))
        self.assertIn('The org has 1 fewer', fewer)
        self.assertIn('Run its install again', fewer)
        have['LightningComponentBundle'] = 85
        self.assertIn('The org has 2 more', '\n'.join(capabilities.standing_lines(kit(), have, capabilities.judge(kit(), have))))


@unittest.skipUnless(BUILT, 'needs a built kit')
class ThePortalTakenOutAgain(unittest.TestCase):
    ORG = {'alias': 'any', 'username': 'me@example.com', 'name': 'Any', 'isProduction': False}

    def run_removal(self, have, yes, replies=(), publish_ok=True, from_uninstall=False):
        """Runs the portal's removal against stand-ins. Returns (what it said, what it did in order, the error or None)."""
        did, queue = [], list(replies)
        saved = {name: getattr(deploy_phase, name) for name in ('say_standing', 'announce', 'guard_production', 'batch', 'tooling', 'rest', 'sf', 'record', 'org_values', 'publish_site', 'destroy')}
        deploy_phase.say_standing = lambda kit_, org, title=None: (did.append('read'), (have, capabilities.judge(kit_, have)))[1]
        deploy_phase.announce = lambda org, action: None
        deploy_phase.guard_production = lambda org, allowed: None
        deploy_phase.batch = lambda org, asks: {name_: (True, {'records': [], 'totalSize': 0}) for name_, _ in asks}
        deploy_phase.tooling = lambda org, text: (True, [])
        deploy_phase.rest = lambda *args, **kwargs: {'results': []}
        deploy_phase.record = lambda *args, **kwargs: None
        deploy_phase.org_values = lambda org: {'RUNNING_USER': 'me@example.com', 'SENDER_EMAIL': 'me@example.com'}

        def deployed(args, **kwargs):
            folder = os.path.join(kwargs['cwd'], args[args.index('--source-dir') + 1])
            files = sorted(os.path.relpath(os.path.join(root, one), folder).replace(os.sep, '/') for root, _, names in os.walk(folder) for one in names)
            texts = {}
            for one in files:
                with open(os.path.join(folder, one), encoding='utf-8') as handle:
                    texts[one] = handle.read()
            did.append(('deploy', os.path.basename(folder), texts))
            return {'status': 0, 'result': {'status': 'Succeeded', 'numberComponentsDeployed': len(files), 'numberComponentsTotal': len(files)}}
        deploy_phase.sf = deployed

        def destroyed(org, folder_name, members, kinds, wait, test_level, flow_versions=()):
            did.append(('remove', tuple(kinds)))
            return queue.pop(0) if queue else {'status': 0, 'result': {'status': 'Succeeded'}}
        deploy_phase.destroy = destroyed
        deploy_phase.publish_site = lambda org, site: (did.append(('publish', site)), (publish_ok, 'Asked Salesforce to publish the site "%s"' % site if publish_ok else 'Salesforce would not publish the site "%s"' % site))[1]

        class Args:
            allow_production, target_org, wait, test_level = False, 'any', 45, 'RunSpecifiedTests'
        Args.yes = yes
        quiet, problem = Quiet(), None
        try:
            said = quiet(self.guarded, did, deploy_phase.remove_portal, self.ORG, 'portal', Args, pause=lambda seconds: did.append(('wait', seconds)), have=have if from_uninstall else None)
            problem = self.problem
        finally:
            for name, value in saved.items():
                setattr(deploy_phase, name, value)
        return said, did, problem

    def guarded(self, did, function, *args, **kwargs):
        self.problem = None
        try:
            function(*args, **kwargs)
        except SetupError as stopped:
            self.problem = str(stopped)

    def with_portal(self):
        return holding('data-model', 'automation', 'components', 'portal', extra={'PermissionSet': ['Antsurance_Portal_Staff']})

    def test_the_dry_run_says_what_goes_what_stays_and_changes_nothing(self):
        said, did, problem = self.run_removal(self.with_portal(), yes=False)
        self.assertIsNone(problem)
        self.assertEqual(['read'], did)
        self.assertIn('PermissionSet (2): Antsurance_Portal, Antsurance_Portal_Staff', said)
        self.assertIn('ApexClass (9)', said)
        self.assertIn('CustomObject (1): Antsurance_Portal_Submission__e', said)
        self.assertIn('Salesforce does not delete a site', said)
        self.assertIn('Digital Experiences, switched on. Salesforce does not let it be switched off again', said)
        self.assertIn('a guest profile named "Antsurance Profile", a guest group and a file named SiteSamples', said, 'the org kept these after the whole uninstall, and they are the site\'s')
        self.assertIn('The profile Antsurance Customer', said)
        self.assertIn('No record is deleted', said)
        self.assertIn('Nothing was changed', said)

    def test_the_order_is_empty_the_pages_remove_and_only_then_switch_the_site_off(self):
        said, did, problem = self.run_removal(self.with_portal(), yes=True)
        self.assertIsNone(problem)
        steps = [one[0] if isinstance(one, tuple) else one for one in did]
        self.assertEqual(['read', 'deploy', 'remove', 'remove', 'remove', 'remove', 'deploy', 'read'], steps)
        closed, off = [one for one in did if isinstance(one, tuple) and one[0] == 'deploy']
        home = closed[2]['digitalExperiences/site/Antsurance1/sfdc_cms__view/home/content.json']
        login = closed[2]['digitalExperiences/site/Antsurance1/sfdc_cms__view/login/content.json']
        self.assertNotIn('c:antsurance', home + login, 'Salesforce refuses to delete a component a page of a site shows')
        self.assertIn('This portal is closed.', home)
        self.assertIn('community_login:loginForm', login, 'what is not ours on the page stays')
        self.assertEqual(2, len([one for one in closed[2] if one.endswith('content.json')]), 'only the pages that show ours are saved again')
        self.assertIn('<status>Live</status>', closed[2]['networks/Antsurance.network-meta.xml'], 'Salesforce publishes only a live site, so it stays live until ours are out')
        self.assertEqual(['networks/Antsurance.network-meta.xml'], sorted(off[2]))
        self.assertIn('<status>DownForMaintenance</status>', off[2]['networks/Antsurance.network-meta.xml'])
        self.assertNotIn('{{', closed[2]['networks/Antsurance.network-meta.xml'])
        removed = [one[1] for one in did if isinstance(one, tuple) and one[0] == 'remove']
        self.assertEqual([('PermissionSet',), ('PlatformEventSubscriberConfig', 'ApexTrigger'), ('LightningComponentBundle', 'ApexClass'), ('CustomObject',)], removed)
        self.assertIn('is removed. The site, its profile and Digital Experiences stay', said)

    def published(self, words):
        return {'status': 1, 'result': {'status': 'Failed', 'details': {'componentFailures': [{'componentType': 'ApexClass', 'fullName': 'AntsurancePortalController', 'problem': words}]}}}

    def test_a_published_site_is_published_again_and_waited_for(self):
        both = ('This apex class is referenced elsewhere in Salesforce. Remove the usage and try again. : Web App Resource Dependency - its id.',
                'This component is found in 0 Development Instance(s) and 1 Published Instance(s).')
        for words in both:
            self.assertTrue(deploy_phase.still_published(self.published(words)), words)
        self.assertFalse(deploy_phase.still_published(self.published('This component is found in 1 Development Instance(s) and 0 Published Instance(s).')))
        self.assertFalse(deploy_phase.still_published(self.published('referenced by a class of yours')))
        ok = {'status': 0, 'result': {'status': 'Succeeded'}}
        said, did, problem = self.run_removal(self.with_portal(), yes=True, replies=[ok, ok, self.published(both[0]), self.published(both[0]), ok])
        self.assertIsNone(problem)
        steps = [one[0] if isinstance(one, tuple) else one for one in did]
        self.assertEqual(['read', 'deploy', 'remove', 'remove', 'remove', 'publish', 'wait', 'remove', 'wait', 'remove', 'remove', 'deploy', 'read'], steps)
        self.assertIn('Waiting 60 seconds', said)

    def test_a_site_salesforce_will_not_publish_stops_without_waiting(self):
        ok = {'status': 0, 'result': {'status': 'Succeeded'}}
        words = 'This apex class is referenced elsewhere in Salesforce. Remove the usage and try again. : Web App Resource Dependency - its id.'
        said, did, problem = self.run_removal(self.with_portal(), yes=True, replies=[ok, ok, self.published(words)], publish_ok=False)
        self.assertNotIn('wait', [one[0] for one in did if isinstance(one, tuple)])
        self.assertIn('step 3 of 4 failed', problem)
        self.assertIn('wait, and run this again', problem)
        self.assertIn('would not publish', said)

    def test_what_is_left_after_a_stop_can_be_removed_by_running_it_again(self):
        have = self.with_portal()
        have['PermissionSet'] -= {'Antsurance_Portal', 'Antsurance_Portal_Staff'}
        have['ApexTrigger'] -= {'AntsurancePortalSubmissionTrigger'}
        said, did, problem = self.run_removal(have, yes=True)
        self.assertIsNone(problem)
        self.assertIn('Only part of "Customer portal (Experience Cloud site)" is in the org', said)
        gone = holding('data-model', 'automation', 'components')
        said, did, problem = self.run_removal(gone, yes=True)
        self.assertIn('is not installed in this org', problem)
        self.assertEqual(['read'], did)

    def test_both_commands_reach_it_and_the_whole_uninstall_takes_the_portal_first(self):
        self.assertIs(deploy_phase.remove_portal, deploy_phase.REMOVABLE_PHASES['portal'])
        self.assertNotIn('look-and-feel', deploy_phase.REMOVABLE_PHASES)
        saved = capabilities.standing
        try:
            capabilities.standing = lambda alias, username, kit_=None: self.with_portal()
            self.assertIsNotNone(uninstall.portal_in_org('any', self.ORG, kit()))
            capabilities.standing = lambda alias, username, kit_=None: holding('everything')
            self.assertIsNone(uninstall.portal_in_org('any', self.ORG, kit()), 'no portal, nothing to take first')
        finally:
            capabilities.standing = saved
        said, did, problem = self.run_removal(self.with_portal(), yes=True, from_uninstall=True)
        self.assertIsNone(problem)
        self.assertNotIn('read', did, 'called from the uninstall it uses what the uninstall already read')
        with open(os.path.join(KIT_ROOT, 'uninstall', 'steps.json'), encoding='utf-8') as handle:
            stays = ' '.join(json.load(handle)['stays'])
        self.assertIn('does not let Digital Experiences be switched off', stays)
        self.assertIn('a guest profile named Antsurance Profile', stays)


@unittest.skipUnless(BUILT, 'needs a built kit')
class TheAdapterSaysWhatItLeaves(unittest.TestCase):
    """Fitting a flow and a screen component with its Apex to Acme's model: what the adapter does, and that
    nothing it cannot do is passed over in silence."""

    def setUp(self):
        self.out = tempfile.mkdtemp(prefix='antsurance-adapt-')
        self.model = os.path.join(KIT_ROOT, 'examples', 'acme', 'model')

    def tearDown(self):
        shutil.rmtree(self.out, ignore_errors=True)

    def mapping(self, name):
        with open(os.path.join(KIT_ROOT, 'examples', 'acme', name), encoding='utf-8') as handle:
            return json.load(handle)

    def read(self, path):
        with open(os.path.join(self.out, 'main', 'default', path), encoding='utf-8') as handle:
            return handle.read()

    def test_the_flow_is_renamed_whole_and_one_place_is_flagged(self):
        report = adapt_capability.adapt('automation', self.mapping('mapping-flow.json'), self.out, self.model)
        self.assertEqual(['flows/Acme_Policy_Past_Due_Follow_Up.flow-meta.xml'], report['files'])
        flow = self.read('flows/Acme_Policy_Past_Due_Follow_Up.flow-meta.xml')
        for words in ('<object>Acme_Policy__c</object>', '<field>Billing_State__c</field>', '<stringValue>Overdue</stringValue>', '$Record.Main_Contact__c', '$Record.Customer__r.OwnerId'):
            self.assertIn(words, flow)
        self.assertIsNone(re.search(r'\bPolicy__c\b|Payment_Status__c|Primary_Insured__c|Account__r|<stringValue>Past Due', flow))
        self.assertEqual({'type differs': 1}, report['judgmentByKind'])
        self.assertIn('Ours is a master-detail and theirs is a lookup', report['judgment'][0]['why'])
        self.assertEqual(6, report['counts']['renames'])

    def test_the_scan_sees_a_word_that_is_an_object_and_a_field(self):
        _, data, _ = describe_capability.describe('components', ['LightningComponentBundle:antsuranceCustomerSummary'])
        self.assertIn('Policy__c', data['objects']['Case']['fields'], 'the summary asks for the claims on a policy through Case.Policy__c')
        mapping = self.mapping('mapping-component.json')
        del mapping['fields']['Case.Policy__c']
        with self.assertRaises(SetupError) as refused:
            adapt_capability.adapt('components', mapping, self.out, self.model)
        self.assertIn('field Case.Policy__c', str(refused.exception))

    def test_the_component_and_its_apex_with_everything_left_written_down(self):
        report = adapt_capability.adapt('components', self.mapping('mapping-component.json'), self.out, self.model)
        kinds = report['judgmentByKind']
        handler, test, script = self.read('classes/AcmeInsightsController.cls'), self.read('classes/AcmeInsightsControllerTest.cls'), self.read('lwc/acmeCustomerSummary/acmeCustomerSummary.js')
        self.assertIn('WHERE Acme_Policy__c IN (SELECT Id FROM Acme_Policy__c WHERE Customer__c = :accountId)', handler, 'the field Case.Policy__c and the object Policy__c are told apart')
        self.assertIn("'Acme_Brokered_Policies__r' : 'Acme_Policies__r'", script, 'the lists of children carry the names the mapping gave')
        self.assertIn('/lightning/r/Acme_Policy__c/', script, 'an address of a record page names an object')
        self.assertIn("from 'c/acmeFonts'", script)
        # What it could not do is each in the report.
        why = {kind: [item for item in report['judgment'] if item['kind'] == kind] for kind in kinds}
        self.assertIn('AntsuranceDemoData', why['needs ours'][0]['why'], 'the test loads our sample records with a class that is not in the copy')
        self.assertTrue(why['needs ours'][0]['file'].endswith('AcmeInsightsControllerTest.cls'))
        in_script = [item for item in why['picklist value'] if item['file'].endswith('.js')]
        self.assertEqual({'Active', 'Lapsed', 'Pending Renewal', 'Homeowners', 'Personal Auto'}, {re.search(r'the text "([^"]+)"', item['why']).group(1) for item in in_script})
        self.assertIn('antsuranceFonts', why['carried as it is'][0]['why'])
        self.assertTrue(os.path.isdir(os.path.join(self.out, 'main', 'default', 'staticresources', 'antsuranceFonts')) or os.path.exists(os.path.join(self.out, 'main', 'default', 'staticresources', 'antsuranceFonts.resource')),
                        'the file the copied code loads travels with it')
        self.assertTrue(any(item['file'].endswith('acmeCustomerSummary.js-meta.xml') for item in why['still says Antsurance']), 'the label an admin sees in the App Builder')
        self.assertEqual(10, kinds['left out'])
        self.assertEqual(3, kinds['record type'])
        self.assertEqual(['objects/Case/fields/Paid_Amount__c.field-meta.xml', 'objects/Case/fields/Reserve_Amount__c.field-meta.xml'], report['created'])
        # Nothing of ours is left in the code without a flag on its file.
        flagged = {item['file'] for item in report['judgment']}
        for path in report['files']:
            full = os.path.join(self.out, 'main', 'default', path)
            if os.path.isdir(full) or path.startswith('staticresources/'):
                continue
            try:
                text = self.read(path)
            except UnicodeDecodeError:
                continue
            if re.search(r'antsurance', text, re.I) or re.search(r'\b(Policy__c|Policyholder_Name__c|Annual_Premium__c|Producer__c)\b', text):
                self.assertIn('main/default/' + path, flagged, '%s still names something of ours and the report does not mention the file' % path)

    def test_an_unmapped_field_of_ours_is_flagged_not_passed_over(self):
        scan = describe_capability.load_scan()
        nodes, _, _ = describe_capability.describe('automation', None, None, scan)
        named = describe_capability.as_data(describe_capability.what_it_names(scan, nodes))
        adapter = adapt_capability.Adapter(adapt_capability.Plan({'objects': {'Policy__c': 'Acme_Policy__c'}, 'fields': {}, 'picklistValues': {}}, scan, nodes, named), {}, {}, {})
        new = adapter.apex('X.cls', 'public class X { void run() { List<Case> found = [SELECT Id FROM Case WHERE Reserve_Amount__c > 0]; AntsuranceDemoData.load(); } }')
        self.assertIn('Reserve_Amount__c', new)
        kinds = {item['kind'] for item in adapter.judgment}
        self.assertEqual({'not in the mapping', 'needs ours'}, kinds)
