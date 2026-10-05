# Kit checks: the installer's decisions, checked without an org

These checks run the customer kit's installer logic against stand-ins. No org is reached, no `sf` command runs and no key is used, so they cost nothing and take about two seconds. They live in the repo, not in the kit: a customer never gets this folder.

Run them after any change to `kit/scripts/setup/` or to `copy_skills` in `scripts/build_kit.py`:

    scripts/kit_checks/run_all.sh          (from antsurance/; add -v to see every case)

It reads the installer in the working tree (`kit/scripts/setup/`), and exits 0 only when every part passes. Part 4 also needs the last build in `dist/`, for the manifest.

## What it proves

1. **The scratch script decides correctly** (`scratch_script.sh`, 25 runs of `kit/scripts/setup/test_in_scratch_org.sh`). The script runs from a throwaway folder with stand-ins for `python3` and `sf` on the `PATH` (`stubs/`): each logs its call and fails on cue. Checked for each run: the exit code, which setup scripts ran and in what order, the command it prints to carry on with, what it keeps in `.install/`, and what it tells the install report. The cases:
   - a failed step prints a command that keeps `--key-env NAME`, `--with-portal` and `--with-coverage-agent`;
   - the same command typed without its options still runs with them;
   - a run cannot start past a failed step, and cannot end "installed" with a failed step on record;
   - `--leave-out-failed` works for the extras (steps 9 to 12) only, says what it left out and tells the report;
   - a key given where a name belongs is refused without being shown, and the marker that stands for the key appears in no output and no notes file;
   - `--stop-after`, a plain run, and `--help`;
   - off a terminal, sf's progress display is shown once, not once for every time sf redrew it, and a failed create still stops the run.
2. **The uninstall sorts what the org holds** (`uninstall_offline.py`, 7 cases of `kit/scripts/setup/uninstall.py`). Rows in the app's own custom settings are listed on their own line and never ask for `--delete-our-records`; records people made still do; a manifest that does not name the settings keeps the old, careful behavior.
3. **The build carries the skill as one file** (`build_skills_offline.py`, 5 cases of `copy_skills`). The kit's readable skill is the same bytes as the kit's static resource, and the build stops when the two sources differ, when a second file sits beside `SKILL.md`, or when either is missing.
4. **The kit's own self-test passes** (`kit/scripts/setup/selftest.py`): the API key script, the picklist merge, the smoke test's reading of answers, the uninstall's sorting of records and settings, the uninstall running a step again without a component Salesforce refused, and the report's words for a step that was left out. It also runs the capability cases (`selftest_capabilities.py`, 65 checks; the 25 added on 2026-10-05 each keep a fault that a scratch org showed from coming back, and are listed below): the install menu and what each choice brings, that each part stands alone and its permission set grants only what it holds, what an org holds by name, installing a part on what is already there, removing a part and refusing when another is built on it, `verify.py` and `assign_access.py` for one part, the preflight on an org that holds parts, what a part names, and the adapter on the example in `kit/examples/acme/`. Those read the build's manifest and scan, so they are skipped, not failed, beside a build that predates them. The scripts are the working tree's; the manifest and the other files they read are the last build's (`dist/antsurance-kit`), because only a build writes them. With no build in `dist/` this part fails and says so: run `python3 -I scripts/build_kit.py` first. A check that reads the manifest can fail on a stale build; rebuild before believing it.
5. **Every installer script parses.**

### The cases a scratch org's faults left behind

Each was written from what the org did, and was checked to fail with its fix taken out.

1. An app or a tab is counted in the org through the Tooling API, not read from the list of what the person asking may open; the preflight does the same.
2. A tab that two choices hold does not make both look half installed, and the pages do not borrow the components' reason for bringing the automations.
3. A removal that stopped part-way can be run again, a part that is half there still stands on what it needs, and a refusal prints the command to run first.
4. A class of the org's own that uses one of ours stops a removal before anything changes: a part, Ask Claude alone, or everything.
5. The portal's removal: what its dry run says, the order (empty the pages, remove, switch off last), the two ways Salesforce reports a published site, publishing and waiting, not waiting when the publish is refused, running it again, and the whole uninstall taking the portal first.
6. Report and dashboard folders go as members of `Report` and `Dashboard`; a record type is switched off without its picklist values; the logo stays while the theme shows it; the look and feel carries its logo.
7. The preflight names an installed part as installed and only what is in none of the parts as a clash.
8. The adapter on a flow and on a screen component with its Apex: the renames, and that a field the mapping does not mention, a class of ours that is not in the copy, a picklist value in a script, a file the code loads and text that still says Antsurance are each written in the report.
9. An org the app was removed from still holds our record types, switched off. The preflight does not stop for them: a note when the kit's own notes show its uninstall ran there, a decision for the person when they do not, and still a stop when one is in use beside another or anything else of ours is there. One class of the org's own in the way is "it", two are "them". The portal's list of what stays names what Salesforce made with the site.

## What only a scratch org can prove

The stand-ins pass or fail on cue. They say nothing about what Salesforce or the real setup scripts do. These need a scratch org:

1. That a real failure reaches the script as a failure: for example that `set_api_key.py` exits non-zero when the named variable is not set, so step 10 stops the run.
2. That a resumed run works in a new shell, against a real org, with the notes the first run left.
3. That `verify.py` and `write_report.py` accept an install with a step left out, and what `install-report.md` then says.
4. That the uninstall's counting questions get the answers the stand-in gives: that the org really reports a custom setting's row, and reports no records once the sample records are gone.
5. What Salesforce removes and what it leaves: whether it deletes a custom setting that holds a row, which components it refuses and in what words, and that one refusal fails a whole step's deletions (the stand-in for this in the self-test was written from what the scratch org did on 2026-10-05).
6. Anything about the deploy itself, the tests, the sample records or Claude.
7. What Salesforce does NOT refuse. It deleted a class that a class of the org's own extended, and reported success. A stand-in written from what one expects would have refused.

## Adding a case

In `scratch_script.sh`, a case is one `run <label> <pattern of the call to fail> <the script's arguments>` followed by what must hold: `exits`, `prints`, `never_prints`, `runs`, `keeps`, `reports`. Use `@@` as the pattern when nothing should fail. In the two Python files, a case is one `case(...)` line. When you fix a bug in the installer, add the case that would have caught it, and check that it fails without the fix.
