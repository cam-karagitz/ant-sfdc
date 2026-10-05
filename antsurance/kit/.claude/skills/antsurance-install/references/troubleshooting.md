# When a step fails

Report the failure in the script's own words first. Then use this page.

## The preflight says the metadata could not be pulled

**Sign:** a DECIDE line under Metadata: "its metadata could not be pulled", with the org's reason.

The questions were still asked, so the report stands, but field types, picklist meanings and what differs from this kit are unknown. The org's full answer is kept in `.install/org-metadata/<alias>/pull-refused.json`. The usual causes: the person signed in cannot read metadata (they need Modify Metadata or to be a System Administrator), or the org was busy. Fix it, then run `analyze_org.py --target-org <alias> --pull-again`, which keeps the answers and repeats only the pull.

If you retrieve metadata by hand for any reason, do it in a folder with no dot at the start of any folder name below the project. The Salesforce CLI ignores every file under a dot folder: the retrieve finishes, reports no error and writes nothing.

## The preflight shows "differs" for things nobody changed

**Sign:** "Antsurance is already installed here" with a count of components that differ from the kit.

That is expected when the org was installed from an older kit: the count is what an update would replace. The comparison already allows for what Salesforce rewrites by itself (where a flow's boxes sit, defaults it leaves out). The names are in `setup-report.json` under `facts.comparison.different`, each with what differs.

## Coverage is under 75 percent

**Sign:** `verify.py` prints `FAIL  Coverage:` and lines such as "AntsuranceSalesforceNotes is 62 percent covered (124 of 200 lines). The bar is 75." Or the core deploy fails with `COVERAGE <class>: Test coverage of selected Apex Class is 62%, at least 75% test coverage is required`.

Salesforce asks 75 percent of every class and trigger in a deploy that names its tests, and refuses production under it. Do not go around it with `--test-level NoTestRun` or by leaving tests out.

1. **Check for a feature that is off first.** A test that returns early because a feature is off in this org passes and covers nothing. Salesforce Notes is the known case: the preflight says "Salesforce Notes is off", and the classes that read notes are then the ones under the bar. That is a defect in the kit's tests for that org, not in the org. Report the class, its figure and that Notes is off. Do not switch Notes on in a working org to make a number move.
2. **Otherwise add tests.** Open the class and its test (`<Name>Test`). Find the branches no test runs, usually error paths and "nothing found" paths. Add test methods that run them and assert the result. Stand in for Claude with `Test.setMock(HttpCalloutMock.class, ...)` as the tests beside it do.
3. **Deploy the class with its test, then run `verify.py` again.**

Optional help, if it is installed: Salesforce's `salesforce-development` plugin for Claude Code has `platform-apex-test-run` (runs tests, reads coverage, works a fix loop) and `platform-apex-test-generate` (writes test classes). The steps above stand without it.

## State and country picklists

**Sign:** the analysis says "State and country picklists are off", or someone asks whether to switch them on.

Nothing to fix. The app works with them on or off: with them off it stores a state as text. Do not switch them on in a working org, because that converts every address in it.

If a deploy fails with "No such column 'BillingStateCode'", some code names a code field directly. In this kit only `AntsuranceAddress` may do that, by name at run time. Report the class the error names; it is a defect in the kit.

To try the app in a scratch org without the picklists: `scripts/setup/test_in_scratch_org.sh --dev-hub <hub> --definition config/project-scratch-def-plain.json`.

## A dashboard is refused

**Sign:** the core deploy fails on a dashboard with a message about dashboards that run as the logged-in user, or about a limit on dynamic dashboards.

Three of our six dashboards run as whoever is looking at them (Claims Operations, Service and Operations, Sales Pipeline and Quotes). An org allows only a few of those, and this one already uses its allowance. In the staged copy the installer deploys (`stage/`), change `<dashboardType>LoggedInUser</dashboardType>` to `SpecifiedUser` in the dashboard the error names and add `<runningUser>` with the installing person's username above `<textColor>`, as the other three have it. Then deploy core again. Tell the person which dashboards now show the installer's view of the data.

## Tests fail with "fields being inaccessible"

**Sign:** many tests fail with "Operation failed due to fields being inaccessible on Sobject Policy__c".

The person running the tests does not hold our permission sets. This happens if the code was deployed some other way than `deploy_phase.py --phase core`, or by a different person than the one who ran step 1. Run `assign_access.py --only-me --yes` as the person deploying, then deploy core again.

## The dry run or deploy fails on a picklist value

**Sign:** "Picklist value: Bound in picklist: StageName not found" or the same for a case status.

The picklist values phase has not run. Run `deploy_phase.py --phase value-sets`, then the dry run again.

## The deploy fails on Quote

**Sign:** "Entity of type 'Quote' is not available" or "sObject type 'Quote' is not supported".

Quotes are off. With the person's yes: `deploy_phase.py --phase prerequisites --enable quotes`.

## A test fails with a validation rule or a required field of theirs

**Sign:** "FIELD_CUSTOM_VALIDATION_EXCEPTION" or "REQUIRED_FIELD_MISSING" naming a rule or field that is not ours.

One of their rules applies to every record type, so it rejects our records. Do not switch their rule off. Tell them which rule, and suggest narrowing it to their own record types, or use a scratch org.

## A test fails with a duplicate rule

**Sign:** "DUPLICATES_DETECTED".

A duplicate rule of theirs is set to block. Same advice: narrow it, or use a scratch org.

## "This schedulable class has jobs pending"

`AntsuranceRenewalJob` is scheduled in the org, and Salesforce will not replace code while one of its jobs is waiting. It names every class in the deploy, but the cause is that one job. Two ways through, the person's choice:

- Setup, Scheduled Jobs, delete the Antsurance renewal job, deploy, then schedule it again.
- Or Setup, Deployment Settings, tick "Allow deployments of components when corresponding Apex jobs are pending or in progress", and deploy.

## The smoke test says the key was refused

The key stored in the org is wrong, revoked or from another workspace. The person runs `set_api_key.py` again with a working key.

## The smoke test says Claude turned the request down

Usually the model. Their Anthropic account may not have the model or fast mode the app asks for. Setup, Custom Metadata Types, Antsurance AI Setting, Manage Records, Default: set a model id they have and untick Fast Mode. Run the smoke test again.

## The smoke test says the org failed before it reached Claude

No key stored yet, or the person does not hold the "Antsurance Claude" permission set. Run `assign_access.py --only-me --yes`, then `set_api_key.py`.

## STORAGE_LIMIT_EXCEEDED

The org is full. A Developer Edition org has 5 MB. Do not load the sample records there twice. Salesforce recounts storage about a minute behind, so wait after deleting before loading.

## REQUEST_LIMIT_EXCEEDED

The org's daily API allowance is spent. Nothing is broken. Wait a few hours. The browser still works.

## The page looks unchanged after a deploy

Reload. If it still shows the old page, clear the browser's stored data for the org's address and reload.

## The coverage agent was not set up

**Sign:** `setup_coverage_agent.py --yes` stops with "The coverage agent was not set up" and a reason.

- "This Claude API key cannot use Managed Agents": the key's Anthropic workspace does not have Claude Managed Agents. Nothing was changed. The app works without the agent: claims keep "Check coverage". The person can ask Anthropic for access, or use a key from a workspace that has it, and run the step again. Do not try another route.
- The key was refused, or no key is stored: store the key first (`set_api_key.py`), pass `smoke_test.py`, then run it again.
- "This Claude workspace holds more ... than setup can search": the workspace is busy with other work. A workspace of its own for this is the fix.

## Preparing the showcase claims stops at a Claude step

**Sign:** `prepare_demo.py` stops with the name of a step and a claim number.

Everything before that step is kept. If the message is about the key, store the key and pass the smoke test first, or run it with `--without-claude` to do the files and the estimate only. If it is a timeout, run the same command again; it carries on from the step that failed.

## The scratch script will not start where it was told to

**Sign:** `test_in_scratch_org.sh --org <alias> --from N` stops with "step M failed in the last run ... and starting at step N would skip it".

That is on purpose: a failed step is never skipped quietly. Run the command it prints, which starts at the failed step with what the run was started with. If the step is an extra (steps 9 to 12: the portal, Claude, the coverage agent) and the person decides to go on without it, add `--leave-out-failed` to that command; the output and the install report say what was left out. A step that is part of the app itself (2 to 8, 13, 14) cannot be left out. Do not delete the notes in `.install/` to get past this.

## Creating the scratch org fails

- "You do not have access to the [ScratchOrgInfo] object": Dev Hub is not switched on in the org named with `--dev-hub`.
- "LIMIT_EXCEEDED": the Dev Hub's daily or active scratch org allowance is used up. Delete one (`sf org list`, then `sf org delete scratch`) or wait a day.
- A feature in `config/project-scratch-def.json` is not available to that Dev Hub: the error names it. Tell the person; do not remove features without saying what will be missing.
