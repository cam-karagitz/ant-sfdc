---
name: antsurance-install
description: Installs the Antsurance insurance CRM with Claude into a Salesforce org, in safe phases, or the parts of it the person chooses (the data model, the automations, the components, the pages, Ask Claude, the portal), each with what it needs. Use whenever the person says "install this", "install", "deploy this to my org", "set this up", "set up Antsurance", "try this", "get this running", "put this in my sandbox", "give people access", "I only want Ask Claude", "just the data model", "only the triggers and flows", "just the utility bar" or "only one feature", or asks what installing would change in their org or whether it would clash with what they have, even if they do not name Antsurance.
---

# Install Antsurance

You are installing a Salesforce app for someone who may not know Salesforce deeply. Keep them oriented: say what you are about to do, do it, say what happened. Bottom line first, plain words.

Read `CLAUDE.md` in the kit root first. Its rules apply to every step here. The three that matter most:

- Say the target org before every change. Never production unless they ask for production in that message.
- The Claude API key never appears in chat, a file or a command line. The person runs `set_api_key.py` themselves.
- Show the plan, get a yes, then act. If a step fails, stop and report. Never skip quietly.
- In any org that is not new and empty, the preflight (`analyze_org.py`) comes before anything else, also when they want one feature only.
- What the kit ships keeps its `Antsurance` prefix. Anything new you build in their org follows `org-conventions.md`. Nothing of theirs is renamed.

All commands run from the kit root. Every script takes `--target-org <alias>`.

## Phase 1. Check tools

Run `sf --version`, `python3 --version` and `sf org list`.

- No `sf`: stop. Tell them: `npm install --global @salesforce/cli`.
- Python older than 3.8: stop and say so.
- Show which orgs they are signed in to, and which of them is a Dev Hub (the `sf org list` output marks it).

## Phase 2. Ask where to install

Ask with the AskUserQuestion tool. If that tool is not available, ask the same question in plain text with the same options and wait.

**Question: "Where should I install it?"**

1. **Try it in a scratch org first (Recommended).** A throwaway org made from your Dev Hub. Nothing touches your real org. Sample records included. Ready in about 15 minutes, gone when it expires.
2. **A sandbox of my org.** I read the sandbox first, show you what would change, and merge with what you have.
3. **A new Developer Edition or trial org.** An empty org of its own. Free to sign up for.

If they asked for part of it ("only Ask Claude", "just the data model"), the question is still where, and then Path D below.

## Phase 3. Ask what to install

In Path B, C and D, after the preflight and before any plan, ask which parts they want: question A in `references/questions.md`, then question B (our data model or theirs) when what they chose depends on a data model. Path A, the scratch org trial, installs everything and skips both.

1. Read the menu from the kit: `python3 scripts/setup/deploy_phase.py --list`. It says what each choice comes with and needs in this build.
2. Ask question A with AskUserQuestion. Each option's line says what it includes and what it brings with it.
3. Say back what will be installed and why, before anything else: "Automations needs the Insurance data model; both will be installed", or "the data model is already there".
4. Ask question B when it applies. On "fit it to my objects", stop this skill after the preflight and follow `antsurance-adapt`.
5. Everything chosen: carry on with Path B or C as written. Parts chosen: Path D.

Then follow the matching path below. Do not offer production. If they ask for production, say plainly that a sandbox comes first and why, and go ahead only if they repeat the request for production in that message.

## Path A. Scratch org (the simple one)

No analysis and no merging are needed: the org is new and empty, and `config/project-scratch-def.json` switches on everything the app needs.

1. **Find a Dev Hub.** A Dev Hub is the org that is allowed to create scratch orgs. Look at `sf org list`.
   - If one is listed, confirm with the person that it is the one to use.
   - If none: explain in one line what it is, that switching it on cannot be undone and changes nothing else in the org, and ask before going further. They switch it on themselves: Setup, search "Dev Hub", Enable. If they would rather not, offer Path C (a free Developer Edition org).
   - If they are not signed in: ask them to run `! sf org login web --alias my-hub` and sign in.
2. **Say what will happen and get a yes:** "I will create a scratch org called antsurance-trial from <hub>, install everything, load the sample records and give you access. Nothing touches <hub> beyond counting one scratch org against its daily allowance."
3. **Run it:** `scripts/setup/test_in_scratch_org.sh --dev-hub <hub>`
   It prints numbered steps. If one fails it stops and prints the command to carry on from that step after the fix. Report the failure in its own words.
   Run that command as printed: it carries what the run was started with (`--key-env` by name, `--with-portal`, `--with-coverage-agent`), and the run also keeps those in `.install/`, so a run carried on with `--org` does what the first one set out to do. It will not start past the step that failed.
   If the failed step is an extra (the portal, Claude, the coverage agent) and cannot be fixed, the script offers `--leave-out-failed`. That is the person's decision: ask, and add it only on a yes. The output and the install report then say what was left out.
4. **Connect Claude.** Tell the person to run this themselves, in their terminal, and type the key at the hidden prompt:
   `! python3 scripts/setup/set_api_key.py --target-org antsurance-trial`
   Then run `python3 scripts/setup/smoke_test.py --target-org antsurance-trial` and report its one-line answer.
5. **Have Claude do its work on the showcase claims.** The script already attached the sample files to five claims. Now that the key works, say that this step makes about a dozen Claude calls on their key (well under a dollar), then run:
   `python3 scripts/setup/prepare_demo.py --target-org antsurance-trial`
   It writes the photo assessments, coverage checks, the claim analysis and the briefs on those claims, and prints what each claim now says. If a step fails it stops and names it; running it again carries on from there.
6. **Ask about the coverage agent.** Question 9 in `references/questions.md`. Only on a yes: `python3 scripts/setup/setup_coverage_agent.py --target-org antsurance-trial --yes`. It creates an agent, an environment and a skill in the person's Anthropic workspace, so never run it unasked.
7. **Open it:** `sf org open --target-org antsurance-trial --path /lightning/app/c__Antsurance`
8. **Offer the next step:** "When you are ready, I can install it into a sandbox of your real org. I will read the sandbox first and show you what would change." That is Path B.

## Path B. A sandbox of their org

Read `references/phases.md` for the exact commands, what to show and when to stop. In outline:

1. **Connect.** They sign in: `! sf org login web --alias <alias> --instance-url https://test.salesforce.com`.
2. **Preflight. Mandatory, and before anything else.** `python3 scripts/setup/analyze_org.py --target-org <alias>`. It changes nothing: it asks the org questions, pulls a read-only copy of the metadata ours could meet into `.install/org-metadata/<alias>/`, compares it with the kit, and writes `setup-report.md`, `setup-report.json`, `org-conventions.md` and `org-conventions.json`. Read `setup-report.json` and show the person the verdict, every STOP and DECIDE line from `setup-report.md`, and the NOTE lines in one breath each.
   - Verdict STOP: do not install. Explain each stop. Offer Path A.
   - A clash (something in the org with one of our names, a field of ours that exists as another type, a picklist value that means something else) is the person's decision. Never rename ours to get past it and never touch theirs.
   - "Antsurance is already installed here" is not a clash. The report says how much of the org matches this kit and what an update would replace.
   - If the report says the metadata could not be pulled, say so plainly: the clash checks are then thinner. Fix what it names and run `analyze_org.py --target-org <alias> --pull-again`.
   - Read `org-conventions.md` yourself and keep to it for anything new you build in this org. Tell the person it exists.
3. **Ask what to install, then the decisions.** First Phase 3 above: which parts (question A) and whose data model (question B). Then the rest. Use AskUserQuestion, one question per decision, recommended option first, one line of consequence per option. See `references/questions.md` for the exact wording and for which questions to skip. Never ask what the analysis already answered. Never more than four questions in one go.
4. **Show the plan.** One short list: target org, what will be added, what org-wide things will change (only the ones they said yes to), who gets access, what will not be touched. Get a yes.
5. **Dry run.** `deploy_phase.py --phase core --dry-run`. If it fails, stop and show why.
6. **Deploy in order:** prerequisites (only what they agreed to), value-sets, core.
7. **Access.** `assign_access.py` with the mode they chose.
8. **Connect Claude.** The person runs `set_api_key.py`. Then you run `smoke_test.py`.
9. **Optional phases,** only the ones they said yes to: the coverage agent (needs the key working), look-and-feel, demo data and then `prepare_demo.py`, portal.
10. **Verify.** `verify.py`. It runs the tests with code coverage and fails if any class or trigger of ours is under 75 percent, the bar Salesforce holds a production deploy to.
11. **Report.** `write_report.py` with an `--answer` for every decision, then show them `install-report.md`.

## Path C. A new Developer Edition or trial org

Same as Path B, preflight included. In an org with nothing of its own the preflight pulls no metadata and says so; a new Developer Edition org has Salesforce's sample fields, so there it does pull, in a few seconds. Two things differ:

- They sign in with `! sf org login web --alias <alias>` (no instance URL).
- State and country picklists are off in a new org. That is fine: the app stores states as text there, and the analysis reports it as information. Do not switch them on.

A new Developer Edition org comes with Salesforce's own sample accounts, contacts and cases. The analysis and the loader will say the org holds records. Tell the person those are Salesforce's samples, and load our sample records beside them (`--into-org-with-records`) only if they say yes.

A Developer Edition org has room for the sample records once, and little else.

## Path D. Parts of it

When they want parts ("I just want Ask Claude", "only the data model and the automations"), not the whole app.

1. **Find the parts.** `python3 scripts/setup/deploy_phase.py --list`, and `FEATURES.md` in the kit root. They list every choice, what each brings with it, what it needs in the org first, and the exact command: `--only data-model`, `--only automation`, `--only components`, `--only pages`, `--only ask-claude`, `--only portal`, `--only look-and-feel`. If what they want is not there, say so; do not improvise a partial deploy by picking files.
2. **Preflight.** Same as Path B step 2, and just as mandatory in an org with things in it: a part still adds things that carry our names. A new, empty org needs none.
3. **Say what it adds and what it brings.** Show the part's own line from the menu and the dependencies in plain words, before anything is deployed: "Automations needs the data model; both will be installed." Do not describe a part from the full app. Get a yes.
4. **What it needs first.** The data model needs our values in four standard picklists (`--phase value-sets`) and Quotes switched on; the pages need Path switched on. Those change the org for everyone, so they are in the plan and get their yes (questions 6 and 7). The installer stops with the command to run when one is missing.
5. **Install it.** Check first, then install. The installer reads what the org holds, says what is already there, deploys each part in order with its own tests, holds every class and trigger in it to 75 percent, and gives the person installing each part's permission set:
   ```
   python3 scripts/setup/deploy_phase.py --target-org <alias> --only automation --dry-run
   python3 scripts/setup/deploy_phase.py --target-org <alias> --only automation
   ```
   It ends with what the org now holds and whether anything else of ours is there. To check again later: `python3 scripts/setup/verify.py --target-org <alias> --capability automation`. To give someone else access: `python3 scripts/setup/assign_access.py --target-org <alias> --capability automation --users <username>`.
6. **Ask Claude alone** is the same command with `--only ask-claude`. Check first, then install:
   ```
   python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --dry-run
   python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude
   ```
   Its permission set is `Antsurance_Ask_Claude`. Give it to anyone else with `sf org assign permset --name Antsurance_Ask_Claude --target-org <alias> --on-behalf-of <username>`. `assign_access.py` is for the whole app; do not use it here.
7. **Connect Claude** if the part calls Claude (the components, Ask Claude, and the automations' quote advisor): the person runs `set_api_key.py`, then you run `smoke_test.py`.
8. **The portal** (`--only portal`) brings the data model, the automations and the components first, says so, and asks for its own yes: it switches on Digital Experiences, which cannot be switched off again (question 5).
9. **To take a part out:** `python3 scripts/setup/uninstall.py --target-org <alias> --capability <part>`, then the same with `--yes`. It leaves what the other parts hold and refuses to remove a part another one is built on.
10. **Say what is not there.** Name what the full app has that this install does not. For Ask Claude: the chat knows the org's own objects, not the insurance model; it can prepare a follow-up task and a form, not a file note or a status move; it lives in its own small app, Ask Claude, and `FEATURES.md` has the three steps to add its utility bar item to one of their own apps. If they want the rest later, `FEATURES.md` says what going from one part to the whole app involves; run the preflight again first, which will report the part as installed. To take the part out: `python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --remove`, then the same with `--yes`.

## After any install

- Tell them who has access now and how to give more people access: `assign_access.py --propose`.
- Tell them where the model is set: Setup, Custom Metadata Types, Antsurance AI Setting, Default.
- If they did not set up the coverage agent, tell them it can be added any time: `setup_coverage_agent.py --target-org <alias>` says whether it is set up, and `--yes` sets it up.
- Tell them how to remove it: the `antsurance-uninstall` skill, or `uninstall.py`, dry run first.
- If they will build on it, point them and their Claude at `CLAUDE.md` ("What is in the app", "How to add to it") and `org-conventions.md`.

## If the person only asks "what would this change?"

Run nothing against their org without a yes, except the preflight, which changes nothing. Summarize `references/what-it-changes.md` and offer the preflight: it answers "would it clash with what I have" for their org in particular.
