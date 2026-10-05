# The phases, for a sandbox or a new org

Run from the kit root. Replace `ORG` with the alias. Each phase: what to run, what to show the person, when to stop.

## Preflight

```
python3 scripts/setup/analyze_org.py --target-org ORG
```

Mandatory before anything else in an org that is not new and empty. Changes nothing. It does three things:

1. **Asks the org** about its limits, your access, its features, its records and what it holds by name.
2. **Pulls the metadata ours could meet,** read only, into `.install/org-metadata/ORG/`: the standard objects we add to with their fields, record types, validation rules and processes, every custom object, layout, trigger, app, tab, Lightning page, action, credential, value set and theme, and whichever of our own components the org already has. It pulls whenever the org holds anything of its own or of ours. A new, empty org is not pulled.
3. **Compares and reports.** `setup-report.md` and `setup-report.json` hold the verdict and each finding as STOP, DECIDE or NOTE. `org-conventions.md` and `org-conventions.json` hold how the org names and builds things.

It costs 6 `sf` commands and about 50 requests plus one for each second of the pull, usually under a minute.

Show: the verdict, then every STOP and DECIDE line with its action, then the NOTE lines briefly. Do not paste the whole report.

What the lines mean:

- **STOP, Names or Clashes.** Something in the org already carries one of our names, or a field of ours exists as another type. The report says whether the org's copy is identical to ours or different. The person decides (question 8). Never rename ours and never touch theirs.
- **"Antsurance is already installed here."** Not a clash. The report counts what matches this kit, what differs and what is missing; an update replaces what differs. If they changed something on purpose, such as the model in Antsurance AI Setting, note it before updating.
- **DECIDE, Automation.** Their triggers, flows, validation rules or required fields on the objects we save to. Theirs run on our records. Ours run on their cases and opportunities and step aside unless the record type is ours.
- **DECIDE, Clashes, picklist values.** A value of theirs has our name and another meaning (closed where ours is open, say). The installer keeps theirs.
- **NOTE, Beside yours.** Their apps, utility bars and Home pages. Ours is one more app with its own; theirs do not change.
- **NOTE, Features, Salesforce Notes.** On or off. The app works either way.
- **DECIDE, Metadata, could not be pulled.** The checks rest on the questions alone. Fix what the message names, then `analyze_org.py --target-org ORG --pull-again`, which repeats only the pull.

Then read `org-conventions.md`. It is the rule book for anything new built in this org.

To judge the same read again without calling the org (after a kit update, say): `analyze_org.py --target-org ORG --offline`.

Stop when: the verdict is STOP. Explain each stop and offer a scratch org.

## What to install

```
python3 scripts/setup/deploy_phase.py --list
```

Calls no org. Prints every choice with what it comes with, what it needs first and its command. Ask question A in `questions.md`, then question B when it applies.

## Parts of it

After the preflight, the questions and the plan, install each chosen part with its command. The installer reads what the org holds, says what the part needs and whether that is already there, deploys what is missing in order, runs each part's own tests, and gives access with each part's permission set. The phases further down are for the whole app.

```
python3 scripts/setup/deploy_phase.py --target-org ORG --only automation --dry-run
python3 scripts/setup/deploy_phase.py --target-org ORG --only automation
python3 scripts/setup/verify.py --target-org ORG --capability automation
python3 scripts/setup/assign_access.py --target-org ORG --capability automation --users a@example.com
python3 scripts/setup/uninstall.py --target-org ORG --capability automation          (says what would go; add --yes to remove)
```

Show: the lines that say what is in the org and what will be installed ("Automations needs Insurance data model ... it is already there"), each step's status line and its Coverage line, the permission sets given, and the closing "In the org now" lines.

Stop when: it says something is needed first (picklist values, Quotes, Path) and gives the command; or a step fails. A failed step is rolled back by Salesforce, and the parts installed before it stay.

A dry run checks the first part that is missing. What sits on it cannot be checked ahead of time, and the installer says so.

Ask Claude:

```
python3 scripts/setup/deploy_phase.py --target-org ORG --only ask-claude --dry-run
python3 scripts/setup/deploy_phase.py --target-org ORG --only ask-claude
python3 scripts/setup/set_api_key.py --target-org ORG          (the person runs this one)
python3 scripts/setup/smoke_test.py --target-org ORG
```

It gives the person installing the permission set `Antsurance_Ask_Claude` and prints the address of its app. Stop when: the deploy or a test fails. A failed deploy is rolled back whole. To remove the part: the same command with `--only ask-claude --remove`, then again with `--yes`.

## Plan

No command. After the questions in `questions.md`, show a plan like this and wait for a yes:

- Target: ORG (name, kind of org).
- Adds: the app, its objects, fields, record types, code, pages, flows and reports. Invisible to everyone until they are given access.
- Changes for the whole org: only what they agreed to (picklist values added; Quotes and Path switched on; look and feel; portal).
- Access: who, in their words.
- Not touched: profiles, sharing settings, their record types, page layouts and records.
- Time: 10 to 30 minutes, most of it Salesforce running the app's tests.

## Dry run

```
python3 scripts/setup/deploy_phase.py --target-org ORG --phase core --dry-run
```

Changes nothing. Core deploys in two steps, and the dry run checks what can be checked ahead of time:

- **Step 1, the data model and permission sets.** Always checked.
- **Step 2, the code and its tests.** Checked only when the org already has our data model (an update). In an org new to the app it cannot be checked ahead: the tests save records as the person installing, and that person has no access to our fields until step 1 is really in the org. Say this plainly. The tests then run when the phase deploys. If they fail there, Salesforce rolls the code back; only the data model stays, and nobody can see it.

If picklist values or switches are still missing in the org, the dry run fails on those. In that case deploy `prerequisites` and `value-sets` first (they agreed to them in the plan), then dry run core.

Stop when: it fails. Show each failed line. Common causes are in `troubleshooting.md`.

## Prerequisites (only if agreed)

```
python3 scripts/setup/deploy_phase.py --target-org ORG --phase prerequisites --enable quotes --enable path
```

Name only the switches that are off and that they agreed to.

## Picklist values

```
python3 scripts/setup/deploy_phase.py --target-org ORG --phase value-sets
```

Show: its lines, which say for each picklist how many of theirs are kept and which of ours are added.

## Core

```
python3 scripts/setup/deploy_phase.py --target-org ORG --phase core
```

Takes 5 to 30 minutes, longer in an org with code of its own. Step 1 puts in the data model and our permission sets and gives the person installing those permission sets, because the tests run as them. Nobody else is given anything. Step 2 deploys the code, pages, app, flows and reports, and runs the tests.

Show: both status lines, and the line saying which permission sets the installer was given.

Stop when: either step fails. A failed step is rolled back by Salesforce. If step 2 fails, step 1 stays in the org: a data model nobody can see. Fix what is named and run the same command again.

## Access

Only me:

```
python3 scripts/setup/assign_access.py --target-org ORG --only-me --yes
```

People they pick: run first without `--yes`, show the list, then with it.

```
python3 scripts/setup/assign_access.py --target-org ORG --users a@example.com,b@example.com --desk a@example.com
```

Proposal: `--propose` writes `.install/access-proposal.json` and prints a summary by profile. Show it. They can edit the file. Then `--apply-proposal --yes`.

"Only me" is real: after it, no other user and no profile has changed. `verify.py` checks that no profile grants our app, tabs or objects.

## Connect Claude

The person runs this themselves and types the key at the hidden prompt. Do not run it for them and do not ask for the key.

```
python3 scripts/setup/set_api_key.py --target-org ORG
```

Then you run:

```
python3 scripts/setup/smoke_test.py --target-org ORG
```

Show its answer. If it says the key was refused, they run `set_api_key.py` again. If it says the model is not available, see `troubleshooting.md`.

To store the key by hand in Setup instead: `api-key-by-hand.md`.

## Coverage agent (only if agreed)

Ask question 9 in `questions.md` first. It needs the key stored and the smoke test passing.

```
python3 scripts/setup/setup_coverage_agent.py --target-org ORG          # says whether it is set up; changes nothing
python3 scripts/setup/setup_coverage_agent.py --target-org ORG --yes    # sets it up; safe to run again
```

It creates an agent, an environment and a skill in the person's Anthropic workspace and keeps their ids in the org's Antsurance Coverage Agent custom setting. The skill's text is in `skills/antsurance-coverage/SKILL.md`. After it, a claim's coverage card offers "Investigate with the coverage agent" beside "Check coverage".

Show: each line it prints (what it found and what it made).

Stop when: it says the agent was not set up. The usual cause is a key whose workspace does not have Claude Managed Agents, or no key stored yet. Nothing was changed in the org and the rest of the app works without the agent. Do not retry with another key and do not try to build the agent another way.

Never archive or delete anything in the person's Anthropic workspace. Archiving there is permanent.

## Look and feel (only if agreed)

```
python3 scripts/setup/deploy_phase.py --target-org ORG --phase look-and-feel
```

## Sample records (only if agreed)

```
python3 scripts/setup/load_demo_data.py --target-org ORG --yes
```

It refuses in production, in an org that holds records, and when there is no room. Do not add `--into-org-with-records` unless the person asks for exactly that.

Then prepare the showcase claims, five sample claims the app is best shown on:

```
python3 scripts/setup/prepare_demo.py --target-org ORG --check             # changes nothing, says what a run would do
python3 scripts/setup/prepare_demo.py --target-org ORG --without-claude    # sample files and one estimate; needs no key
python3 scripts/setup/prepare_demo.py --target-org ORG                     # also Claude's work: about a dozen calls on their key
```

Run the full one only once the key is stored and the smoke test passes, and say first that it calls Claude about a dozen times. It only adds to the sample claims and is safe to run twice. If a Claude step fails it stops and names the step; running it again carries on from there.

## Portal (only if agreed)

```
python3 scripts/setup/deploy_phase.py --target-org ORG --phase portal
```

Then publish the site in Setup, Digital Experiences, All Sites, Builder, Publish.

The install creates no portal users. Giving the person's own customers access (which license and profile, which customers, how they sign in) is their configuration, and you do it with them: follow `references/portal-users.md` step by step. In short, a portal user needs a customer license, a profile that is a member of the site (ours is "Antsurance Customer", or one they already have), the "Antsurance Portal Customer" permission set, and a contact under an account whose owner has a role.

## Verify

```
python3 scripts/setup/verify.py --target-org ORG
```

Add `--skip-tests` if the core deploy just ran them. Show each PASS and FAIL line.

The Coverage line is the 75 percent gate. Salesforce refuses a production deploy under 75 percent, and a deploy that names its tests asks 75 percent of every class and trigger in it. `verify.py` gets coverage from the same test run, prints our overall figure, and on a FAIL names each class or trigger under the bar with its figure and line counts. With `--skip-tests` nothing is measured: the core deploy already held the same bar, because Salesforce rejects it otherwise.

Stop when: Coverage fails. Do not go on to a production install. See `troubleshooting.md`, "Coverage is under 75 percent".

## Report

```
python3 scripts/setup/write_report.py --target-org ORG --answer where=sandbox --answer access=only-me --answer demoData=no --answer lookAndFeel=no --answer portal=no --answer coverageAgent=no
```

Add `--answer coverageAgent=yes` or `no` for question 9. Use the answers they gave. Show them where `install-report.md` is and its "Who has access" and "To remove everything" sections.
