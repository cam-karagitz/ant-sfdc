"""Checks of the one-part install (deploy_phase.py --only), run by selftest.py. No org is touched.

The checks that read the kit's own description of its parts need a built kit, with its kit-manifest.json, and are
skipped in a folder that has none.
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_phase  # noqa: E402
from _common import KIT_ROOT, SetupError  # noqa: E402

BUILT = os.path.exists(os.path.join(KIT_ROOT, 'kit-manifest.json'))


class DeploySummary(unittest.TestCase):
    def test_a_deploy_that_fails_on_coverage_names_the_class_its_figure_and_the_bar(self):
        reply = {'status': 1, 'result': {'status': 'Failed', 'numberComponentsDeployed': 0, 'numberComponentsTotal': 3, 'numberTestsCompleted': 4, 'numberTestErrors': 0, 'details': {'runTestResult': {
            'codeCoverageWarnings': [{'name': 'AntsuranceThing', 'message': 'Test coverage of selected Apex Class is 25%, at least 75% test coverage is required'}],
            'codeCoverage': [{'name': 'AntsuranceThing', 'numLocations': '120', 'numLocationsNotCovered': '89'}, {'name': 'AntsuranceOther', 'numLocations': '10', 'numLocationsNotCovered': '1'}]}}}}
        ok, lines, _ = deploy_phase.summarize(reply)
        self.assertFalse(ok)
        self.assertIn('  COVERAGE AntsuranceThing is 25 percent covered (31 of 120 lines). The bar is 75 percent for every class and trigger in a deploy.', lines)
        self.assertEqual([], [line for line in lines if 'AntsuranceOther' in line], 'a class at the bar is not mentioned')

    def test_a_deploy_at_the_bar_gets_no_coverage_line(self):
        reply = {'status': 0, 'result': {'status': 'Succeeded', 'details': {'runTestResult': {'codeCoverage': [{'name': 'AntsuranceThing', 'numLocations': '100', 'numLocationsNotCovered': '5'}]}}}}
        ok, lines, _ = deploy_phase.summarize(reply)
        self.assertTrue(ok)
        self.assertEqual(1, len(lines))


@unittest.skipUnless(BUILT, 'needs a built kit')
class OnePart(unittest.TestCase):
    def test_a_part_that_is_not_in_the_kit_is_refused_by_name(self):
        with self.assertRaises(SetupError) as refused:
            deploy_phase.slice_named('everything-else')
        self.assertIn('ask-claude', str(refused.exception), 'the refusal says which parts there are')

    def test_each_part_says_what_a_person_needs_to_install_it(self):
        for name in deploy_phase.slices():
            part = deploy_phase.slice_named(name)
            for key in ('label', 'path', 'permissionSet', 'app', 'tests', 'members', 'changes'):
                self.assertTrue(part.get(key), '%s has no %s' % (name, key))
            self.assertIn(part['permissionSet'], part['members']['PermissionSet'])
            self.assertIn(part['app'], part['members']['CustomApplication'])

    def test_a_part_runs_its_own_tests_and_only_those(self):
        for name in deploy_phase.slices():
            part = deploy_phase.slice_named(name)
            tests = deploy_phase.tests_for(deploy_phase.ONLY + name)
            self.assertEqual(part['tests'], tests)
            self.assertTrue(set(tests) <= set(part['members']['ApexClass']), 'every test a part runs is in the part')

    def test_every_kind_of_thing_a_part_holds_has_its_place_in_the_removal(self):
        ordered = [kind for step in deploy_phase.REMOVAL_STEPS for kind in step]
        self.assertEqual(len(ordered), len(set(ordered)), 'no kind is removed twice')
        for name in deploy_phase.slices():
            self.assertEqual([], sorted(set(deploy_phase.slice_named(name)['members']) - set(ordered)))

    def test_what_is_staged_is_the_part_and_nothing_else(self):
        for name in deploy_phase.slices():
            part = deploy_phase.slice_named(name)
            staged = deploy_phase.stage_slice(name)
            classes = sorted(one[:-4] for one in os.listdir(os.path.join(staged, 'main', 'default', 'classes')) if one.endswith('.cls'))
            self.assertEqual(sorted(part['members']['ApexClass']), classes)
            self.assertFalse(os.path.exists(os.path.join(staged, 'slice.json')), 'the part\'s description is not deployed')
            self.assertEqual(part['files'], sum(len(files) for _, _, files in os.walk(staged)))
