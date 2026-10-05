#!/usr/bin/env python3
"""Checks the installer's own logic without touching any org and without any real key.

    python3 scripts/setup/selftest.py

It runs the API key script against a stand-in for the org, the picklist merge against sample files, the
smoke test's reading of each kind of answer, the uninstall's sorting of what the org holds into records
and the app's own settings, how the uninstall carries on when Salesforce refuses to delete one component of a
step, and what the install report says about a step that was left out. Exit code 0
when every check passes.
"""
import contextlib
import io
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import deploy_phase  # noqa: E402
import set_api_key  # noqa: E402
import smoke_test  # noqa: E402
import uninstall  # noqa: E402
import write_report  # noqa: E402
from _common import SetupError  # noqa: E402

FAKE_KEY = 'not-a-real-key-0123456789'


class StandInOrg:
    """Plays the org's credential service. Remembers what it was sent so the tests can look."""

    def __init__(self, has_key=False, refuse=None):
        self.has_key = has_key
        self.refuse = refuse
        self.calls = []

    def __call__(self, org, path, method='GET', body=None):
        self.calls.append((method, path, body))
        if method == 'GET':
            return {'externalCredential': 'Anthropic', 'credentials': {'ApiKey': {'encrypted': True}} if self.has_key else {}}
        if self.refuse:
            return [{'errorCode': 'INVALID_INPUT', 'message': self.refuse}]
        self.has_key = True
        return {'externalCredential': 'Anthropic', 'credentials': {'ApiKey': {'encrypted': True}}}


class ApiKey(unittest.TestCase):
    def test_first_key_is_created(self):
        org = StandInOrg()
        self.assertEqual('POST', set_api_key.store('any', FAKE_KEY, request=org))
        method, path, body = org.calls[-1]
        self.assertEqual(('POST', 'Anthropic', 'ApiUser'), (method, body['externalCredential'], body['principalName']))
        self.assertEqual({'value': FAKE_KEY, 'encrypted': True}, body['credentials']['ApiKey'])
        self.assertNotIn(FAKE_KEY, path, 'the key is never part of the address')

    def test_existing_key_is_replaced(self):
        org = StandInOrg(has_key=True)
        self.assertEqual('PUT', set_api_key.store('any', FAKE_KEY, request=org))

    def test_stored_says_yes_or_no_without_a_value(self):
        self.assertFalse(set_api_key.stored('any', request=StandInOrg()))
        self.assertTrue(set_api_key.stored('any', request=StandInOrg(has_key=True)))

    def test_a_refusal_is_reported_without_the_key(self):
        org = StandInOrg(refuse='Bad value %s for ApiKey' % FAKE_KEY)
        with self.assertRaises(SetupError) as caught:
            set_api_key.store('any', FAKE_KEY, request=org)
        self.assertNotIn(FAKE_KEY, str(caught.exception))
        self.assertIn('[key]', str(caught.exception))

    def test_key_comes_from_the_named_variable(self):
        self.assertEqual(FAKE_KEY, set_api_key.read_key('MY_VAR', environ={'MY_VAR': '  %s\n' % FAKE_KEY}))

    def test_empty_or_broken_keys_are_refused(self):
        for bad in ('', '   ', 'two words'):
            with self.assertRaises(SetupError):
                set_api_key.read_key('MY_VAR', environ={'MY_VAR': bad})
        with self.assertRaises(SetupError):
            set_api_key.read_key('MISSING', environ={})

    def test_nothing_prints_the_key(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            set_api_key.store('any', FAKE_KEY, request=StandInOrg())
            set_api_key.read_key('MY_VAR', environ={'MY_VAR': FAKE_KEY})
        self.assertNotIn(FAKE_KEY, out.getvalue() + err.getvalue())


THEIRS = """<?xml version="1.0" encoding="UTF-8"?>
<StandardValueSet xmlns="http://soap.sforce.com/2006/04/metadata">
    <sorted>false</sorted>
    <standardValue>
        <fullName>Triage</fullName>
        <default>true</default>
        <label>Triage</label>
        <closed>false</closed>
    </standardValue>
    <standardValue>
        <fullName>Closed</fullName>
        <default>false</default>
        <label>Closed</label>
        <closed>true</closed>
    </standardValue>
</StandardValueSet>
"""
OURS = THEIRS.replace('Triage', 'New').replace('<fullName>Closed</fullName>', '<fullName>closed</fullName>').replace(
    '</StandardValueSet>', '    <standardValue>\n        <fullName>Appraisal</fullName>\n        <default>false</default>\n        <label>Appraisal</label>\n        <closed>false</closed>\n    </standardValue>\n</StandardValueSet>')


class PicklistMerge(unittest.TestCase):
    def test_theirs_are_kept_in_order_and_ours_added_after(self):
        merged, added, kept = deploy_phase.merge_value_set(THEIRS, OURS)
        _, names = deploy_phase.parse_value_set(merged)
        self.assertEqual(['Triage', 'Closed', 'New', 'Appraisal'], names)
        self.assertEqual(['New', 'Appraisal'], added)
        self.assertEqual(['Triage', 'Closed'], kept)

    def test_their_default_stands(self):
        merged, _, _ = deploy_phase.merge_value_set(THEIRS, OURS)
        self.assertEqual(1, merged.count('<default>true</default>'))
        self.assertLess(merged.index('<fullName>Triage</fullName>'), merged.index('<default>true</default>'))

    def test_a_value_they_have_is_not_added_twice_whatever_its_case(self):
        _, added, _ = deploy_phase.merge_value_set(THEIRS, OURS)
        self.assertNotIn('closed', added)

    def test_nothing_to_add_leaves_their_file_alone(self):
        merged, added, _ = deploy_phase.merge_value_set(THEIRS, THEIRS)
        self.assertEqual((THEIRS, []), (merged, added))

    def test_an_org_without_the_picklist_gets_ours(self):
        merged, added, kept = deploy_phase.merge_value_set(None, OURS)
        self.assertEqual((OURS, []), (merged, kept))
        self.assertEqual(['New', 'closed', 'Appraisal'], added)


class SmokeTest(unittest.TestCase):
    def test_an_answer_passes(self):
        ok, message = smoke_test.explain(smoke_test.interpret('12:00 USER_DEBUG [9]|ERROR|SMOKE|ok|some-model|ready'), 'my-org')
        self.assertTrue(ok)
        self.assertIn('ready', message)

    def test_a_refused_key_is_said_in_plain_words(self):
        ok, message = smoke_test.explain(smoke_test.interpret('12:00 USER_DEBUG [9]|ERROR|SMOKE|auth|some-model|Claude rejected the API key stored in the Anthropic credential.'), 'my-org')
        self.assertFalse(ok)
        self.assertTrue(message.startswith('The key was refused.'))
        self.assertIn('set_api_key.py --target-org my-org', message)

    def test_every_kind_of_failure_has_advice(self):
        for kind in ('rate_limited', 'unavailable', 'timeout', 'unreachable', 'other', 'error', 'something-new'):
            ok, message = smoke_test.explain((kind, 'm', 'detail'), 'my-org')
            self.assertFalse(ok)
            self.assertGreater(len(message.splitlines()[0]), 20)

    def test_the_echoed_source_is_not_mistaken_for_the_answer(self):
        log = "Execute Anonymous:     line = 'SMOKE|ok|' + model + '|' + text;\n12:00 USER_DEBUG [9]|ERROR|SMOKE|auth|some-model|refused"
        self.assertEqual(('auth', 'some-model', 'refused'), smoke_test.interpret(log))

    def test_the_log_s_own_encoding_of_bars_is_read(self):
        log = '17:26:55.50 (263783199)|USER_DEBUG|[13]|ERROR|SMOKE&#124;auth&#124;some-model&#124;Claude rejected the API key. invalid x-api-key'
        ok, message = smoke_test.explain(smoke_test.interpret(log), 'my-org')
        self.assertFalse(ok)
        self.assertTrue(message.startswith('The key was refused.'))

    def test_no_result_line_is_a_failure_not_a_pass(self):
        ok, message = smoke_test.explain(smoke_test.interpret('nothing useful in this log'), 'my-org')
        self.assertFalse(ok)


def org_holding(totals, refused=()):
    """Plays the org answering the uninstall's counting questions. Remembers what it was asked."""
    asked = []

    def ask(org, requests):
        asked.extend(name for name, _ in requests)
        return {name: (False, 'INVALID_TYPE: gone') if name in refused else (True, {'totalSize': totals.get(name, 0)}) for name, _ in requests}
    ask.asked = asked
    return ask


class UninstallRecords(unittest.TestCase):
    OURS = {'customObjects': ['Antsurance_AI_Setting__mdt', 'Antsurance_Coverage_Agent__c', 'Antsurance_Portal_Submission__e', 'Claude_Autonomy__c', 'Policy__c'],
            'customSettings': ['Antsurance_Coverage_Agent__c', 'Claude_Autonomy__c']}

    def test_the_coverage_agent_s_ids_are_listed_as_settings_and_not_as_records(self):
        records, settings = uninstall.our_records('any', self.OURS, ask=org_holding({'Antsurance_Coverage_Agent__c': 1}))
        self.assertEqual({}, records, 'nothing here is a reason to ask for --delete-our-records')
        self.assertEqual({'Antsurance_Coverage_Agent__c': 1}, settings)

    def test_records_people_made_still_count_as_records(self):
        records, settings = uninstall.our_records('any', self.OURS, ask=org_holding({'Policy__c': 149, 'Case': 86, 'Claude_Autonomy__c': 2}))
        self.assertEqual({'Policy__c': 149, 'Case': 86}, records)
        self.assertEqual({'Claude_Autonomy__c': 2}, settings)

    def test_an_empty_org_and_an_object_that_is_already_gone_count_as_nothing(self):
        ask = org_holding({}, refused=('Antsurance_Coverage_Agent__c', 'Policy__c'))
        self.assertEqual(({}, {}), uninstall.our_records('any', self.OURS, ask=ask))
        self.assertNotIn('Antsurance_AI_Setting__mdt', ask.asked, 'settings types and events hold no rows to count')
        self.assertNotIn('Antsurance_Portal_Submission__e', ask.asked)

    def test_a_kit_that_does_not_say_which_objects_are_settings_stays_careful(self):
        ours = {'customObjects': self.OURS['customObjects']}
        records, settings = uninstall.our_records('any', ours, ask=org_holding({'Antsurance_Coverage_Agent__c': 1}))
        self.assertEqual(({'Antsurance_Coverage_Agent__c': 1}, {}), (records, settings))


def salesforce_deleting(refuses, gone=()):
    """Plays Salesforce deleting one step's components: a single refusal fails the deploy and nothing in it is removed."""
    asked = []

    def delete(org, number, types):
        asked.append({kind: list(members) for kind, members in types.items()})
        failures = [{'componentType': kind, 'fullName': name, 'problem': refuses[name]} for kind, members in types.items() for name in members if name in refuses]
        failures += [{'componentType': kind, 'fullName': name, 'problem': 'No %s named: %s found' % (kind, name)} for kind, members in types.items() for name in members if name in gone]
        # Salesforce lists a refusal twice.
        return {'applied': not failures, 'failures': failures + failures, 'message': None}
    delete.asked = asked
    return delete


class UninstallSteps(unittest.TestCase):
    STEP = {'name': 'Our list views', 'types': {'ListView': ['Case.All_Claims', 'Case.Open_Claims', 'Quote.Open_Quotes'], 'Group': ['Antsurance_Users']}}
    LAST_VIEW = 'cannot delete last filter'
    IN_USE = 'This custom field is referenced elsewhere in Salesforce. : Flow - Theirs'

    def setUp(self):
        self.lenient = list(uninstall.LENIENT)

    def tearDown(self):
        uninstall.LENIENT[:] = self.lenient

    def remove(self, delete, outside_production=True):
        uninstall.LENIENT[:] = ['--ignore-errors', '--purge-on-delete'] if outside_production else []
        return uninstall.remove_step('any', 3, self.STEP, delete=delete)

    def test_a_step_with_nothing_refused_is_one_deploy(self):
        delete = salesforce_deleting({})
        self.assertEqual((True, [], None), self.remove(delete))
        self.assertEqual([self.STEP['types']], delete.asked)

    def test_a_component_that_must_stay_does_not_keep_the_rest_of_its_step(self):
        for outside_production in (True, False):
            delete = salesforce_deleting({'Case.All_Claims': self.LAST_VIEW})
            gone, refused, _ = self.remove(delete, outside_production)
            self.assertTrue(gone)
            self.assertEqual(['ListView Case.All_Claims: ' + self.LAST_VIEW], refused)
            self.assertTrue(uninstall.expected_to_stay(refused[0]))
            self.assertEqual({'ListView': ['Case.Open_Claims', 'Quote.Open_Quotes'], 'Group': ['Antsurance_Users']}, delete.asked[-1], 'the step ran again without it')
            self.assertEqual(2, len(delete.asked))

    def test_outside_production_any_refusal_is_set_aside_and_reported(self):
        delete = salesforce_deleting({'Case.Open_Claims': self.IN_USE})
        gone, refused, _ = self.remove(delete)
        self.assertTrue(gone)
        self.assertEqual(['ListView Case.Open_Claims: ' + self.IN_USE], refused)
        self.assertFalse(uninstall.expected_to_stay(refused[0]), 'so the uninstall reports the step as not fully removed')

    def test_in_production_any_other_refusal_stops_the_step(self):
        delete = salesforce_deleting({'Case.Open_Claims': self.IN_USE, 'Case.All_Claims': self.LAST_VIEW})
        gone, refused, _ = self.remove(delete, outside_production=False)
        self.assertFalse(gone)
        self.assertEqual(2, len(refused))
        self.assertEqual(1, len(delete.asked), 'not run again: it would only be refused again')

    def test_what_is_already_gone_is_set_aside_without_a_word(self):
        delete = salesforce_deleting({}, gone=('Quote.Open_Quotes', 'Antsurance_Users'))
        self.assertEqual((True, [], None), self.remove(delete, outside_production=False))
        self.assertEqual({'ListView': ['Case.All_Claims', 'Case.Open_Claims']}, delete.asked[-1])

    def test_a_step_that_is_entirely_gone_or_staying_needs_no_last_deploy(self):
        delete = salesforce_deleting({'Case.All_Claims': self.LAST_VIEW}, gone=('Case.Open_Claims', 'Quote.Open_Quotes', 'Antsurance_Users'))
        gone, refused, _ = self.remove(delete)
        self.assertEqual((True, 1, 1), (gone, len(refused), len(delete.asked)))

    def test_settings_records_whose_type_is_already_gone_do_not_stop_a_second_run(self):
        step = {'name': 'Settings records', 'types': {'CustomMetadata': ['Antsurance_Event.Hail', 'Antsurance_AI_Setting.Default'], 'CustomPermission': ['Antsurance_Desk_Manager']}}
        asked = []

        def delete(org, number, types):
            asked.append({kind: list(members) for kind, members in types.items()})
            for record in types.get('CustomMetadata', []):
                return {'applied': False, 'failures': [], 'message': 'UNKNOWN_EXCEPTION: Custom metadata type %s__mdt is not available in this organization.' % record.split('.')[0]}
            return {'applied': True, 'failures': [], 'message': None}
        uninstall.LENIENT[:] = []
        self.assertEqual((True, [], None), uninstall.remove_step('any', 7, step, delete=delete))
        self.assertEqual({'CustomPermission': ['Antsurance_Desk_Manager']}, asked[-1])
        self.assertEqual(3, len(asked))

    def test_a_deploy_that_fails_without_naming_a_component_stops_with_its_message(self):
        def delete(org, number, types):
            return {'applied': False, 'failures': [], 'message': 'The org is locked.'}
        self.assertEqual((False, [], 'The org is locked.'), self.remove(delete))


class ReportLeftOut(unittest.TestCase):
    @staticmethod
    def state(left, at, phases=None):
        return {'answers': {'leftOut': {'answer': left, 'at': at}, 'portal': {'answer': 'no', 'at': at}}, 'phases': phases or {}}

    def test_what_was_left_out_is_said_in_words(self):
        line = write_report.answer_line('leftOut', {'answer': 'claude', 'at': '2026-10-05 16:09 UTC'})
        self.assertEqual('- Left out after it failed, because the person said to carry on without it: '
                         'connecting Claude (step 10); nothing that asks Claude works until a key is stored (2026-10-05 16:09 UTC).', line)
        self.assertIn(': no (', write_report.answer_line('portal', {'answer': 'no', 'at': 'now'}), 'other answers read as before')
        self.assertIn(': something-new (', write_report.answer_line('leftOut', {'answer': 'something-new', 'at': 'now'}))

    def test_every_step_the_scratch_script_can_leave_out_has_words(self):
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_in_scratch_org.sh')) as handle:
            named = set(re.findall(r'LEFT_WHAT=([a-z-]+)', handle.read()))
        self.assertEqual(set(write_report.LEFT_OUT), named)

    def test_a_step_still_left_out_stays_in_the_report(self):
        for phases in ({}, {'claude-key': {'outcome': 'stored', 'at': '2026-10-05 16:20 UTC'}},
                       {'claude-smoke-test': {'outcome': 'did not answer', 'at': '2026-10-05 16:20 UTC'}},
                       # Answered, then failed for another reason and was left out in the same minute or later.
                       {'claude-smoke-test': {'outcome': 'answered', 'at': '2026-10-05 16:09 UTC'}}):
            state = self.state('claude', '2026-10-05 16:09 UTC', phases)
            write_report.settle_left_out(state)
            self.assertIn('leftOut', state['answers'])

    def test_a_step_done_later_is_no_longer_reported_as_left_out(self):
        done = {'claude': ('claude-smoke-test', 'answered'), 'portal': ('portal', 'deployed'), 'coverage-agent': ('coverage-agent', 'set up'),
                'claude-work-on-showcase-claims': ('demo-prep', 'prepared')}
        for left, (phase, outcome) in done.items():
            state = self.state(left, '2026-10-05 16:09 UTC', {phase: {'outcome': outcome, 'at': '2026-10-05 16:31 UTC'}})
            write_report.settle_left_out(state)
            self.assertEqual(['portal'], sorted(state['answers']), left)

    def test_a_report_with_nothing_left_out_is_untouched(self):
        state = {'answers': {'portal': {'answer': 'yes', 'at': 'now'}}, 'phases': {'portal': {'outcome': 'deployed', 'at': 'later'}}}
        write_report.settle_left_out(state)
        self.assertEqual(['portal'], sorted(state['answers']))


# The preflight's clash and convention checks and the coverage gate. They live in selftest_preflight.py.
from selftest_preflight import CoverageGate, Preflight  # noqa: E402,F401
# The one-part install (deploy_phase.py --only) and the coverage line in a deploy's summary. They live in selftest_parts.py.
from selftest_parts import DeploySummary, OnePart  # noqa: E402,F401
# The install menu: what each choice brings, what an org holds of it, removal, access, and fitting a part to an org's own data model.
from selftest_capabilities import *  # noqa: E402,F401,F403


if __name__ == '__main__':
    unittest.main(verbosity=1)
