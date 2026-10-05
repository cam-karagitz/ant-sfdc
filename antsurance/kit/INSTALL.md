# Install Antsurance

**Open this folder in Claude Code and say "install this". Or run the three commands below. Either way, the first install goes into a throwaway org, so your real org is not touched.**

## What you need

- The Salesforce CLI: `npm install --global @salesforce/cli`
- Python 3.8 or newer
- A Salesforce org where you are an administrator. A free Developer Edition org works.
- A Claude API key from the Claude Console (optional until you want the Claude features)

## The one sentence

In Claude Code, in this folder:

> install this

Claude Code checks your tools, asks where to install, shows you a plan, and waits for your yes before it changes anything. It never asks you to paste your API key into the chat.

## The three commands

These make a scratch org (a throwaway Salesforce org that deletes itself after a few days), install everything into it with sample records and their sample files, and connect Claude.

```
sf org login web --alias my-hub
scripts/setup/test_in_scratch_org.sh --dev-hub my-hub
python3 scripts/setup/set_api_key.py --target-org antsurance-trial
```

The first signs you in to the org that will create the scratch org. That org needs Dev Hub switched on (Setup, Dev Hub, Enable). Dev Hub is the permission to create scratch orgs. Switching it on cannot be undone and changes nothing else in the org.

The second takes about 10 minutes, most of it Salesforce running the app's tests.

The third asks for your key at a hidden prompt and stores it in the scratch org. Then `python3 scripts/setup/smoke_test.py --target-org antsurance-trial` asks Claude one short question to prove it works.

One more, once the key works, makes the five showcase claims look the way the app is best shown: Claude writes its photo assessments, coverage checks, a claim analysis and briefs on them. It is about a dozen Claude calls on your key.

```
python3 scripts/setup/prepare_demo.py --target-org antsurance-trial
```

## Installing into your own org

Do this in a sandbox (a copy of your org for testing), after the scratch trial. Say "install this into my sandbox" to Claude Code, or start with the preflight yourself:

```
python3 scripts/setup/analyze_org.py --target-org my-sandbox
```

### The preflight: what it checks before anything is installed

The preflight reads your org and changes nothing. It is the first step in any org that already has things in it, and Claude Code will not skip it.

1. **It asks your org** about its limits, your access, its features and its records.
2. **It pulls a read-only copy of your metadata** into `.install/org-metadata/` on your computer: your objects and fields, record types, validation rules, page layouts, triggers, apps, tabs, pages, credentials and picklists. Nothing is sent anywhere else. It takes under a minute and about 100 of your org's daily API requests.
3. **It reports every clash** in `setup-report.md`, with a verdict (GO, GO WITH CHANGES or STOP) and one line of what to do for each thing it found:
   - something of yours that already carries one of our names, and whether it is identical to ours or different;
   - a field of ours that you already have as another type;
   - picklist values and record types ours would add, or that share a name with yours and mean something else;
   - your required fields and validation rules on the objects the app saves records in;
   - your triggers and flows on those objects (yours will run on the app's records; ours run on your cases and opportunities and step aside unless the record is ours);
   - your apps, utility bars and Home pages, which ours sits beside without changing.
4. **It writes down how your org names and builds things** in `org-conventions.md`: your prefixes, how you name objects, fields, classes, tests, components and flows, whether you keep one trigger per object, whether your fields carry descriptions and help text, and which API versions you use, each with how many examples it rests on.

Three rules follow from that file, and Claude Code keeps to them:

1. What Antsurance ships keeps its `Antsurance` prefix. It works like a namespace: nothing of yours is overwritten, and everything of ours can be found and removed.
2. Anything new that Claude builds in your org follows your conventions, not ours.
3. Nothing of yours is ever renamed.

The installer follows the report. It refuses to touch a production org unless you ask for exactly that.

## Choosing what to install

You do not have to take the whole app. After the preflight, Claude Code asks what you want: everything, only Ask Claude, or the parts you pick. Or say it yourself, for example:

> I only want the data model and the automations

The parts, and what each comes with:

1. **Insurance data model.** Our objects, fields and record types. No code and no screens. Comes with nothing else.
2. **Automations.** The triggers, their classes and the flows. Comes with the data model.
3. **Screen components and the Claude features.** Every component and the Apex it calls. Comes with the data model and the automations: its tests count on what the triggers do.
4. **Page layouts, record pages and the app.** Comes with all three above.
5. **Ask Claude.** The chat alone. Comes with nothing else, and adds nothing to your objects.
6. **Customer portal.** An Experience Cloud site. Comes with the data model, the automations and the components, and switches on Digital Experiences, which cannot be switched off again.
7. **The extras:** the look and feel, the sample records and the coverage agent, each with its own yes.

You are told what a choice brings before anything is installed ("Automations needs the data model; both will be installed"), and what is already in your org is not installed twice. To see the menu yourself:

```
python3 scripts/setup/deploy_phase.py --list
```

By hand, a part is one command. It reads what your org holds, installs what is missing in order, runs each part's own tests, and gives you each part's permission set:

```
python3 scripts/setup/deploy_phase.py --target-org <alias> --only automation
```

`FEATURES.md` has the whole menu, how the parts stack, what each needs in the org first, and how to check, give access to and remove one part.

### If you already have your own policy or claim objects

Claude Code asks whether to use our data model or fit what you chose to the objects you already have. Fitting makes a copy of the part that names your objects and fields, follows your naming conventions, and is yours to keep. Nothing of yours is renamed. It takes longer, because every mapping that is a guess is put to you and the tests are reworked for your records. `FEATURES.md`, "Fitting a part to the objects you already have", says how it goes.

### Only Ask Claude

In a sandbox or any org with things in it, the preflight still runs first. By hand it is one command, then your key:

```
python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude
python3 scripts/setup/set_api_key.py --target-org <alias>
```

It adds a chat tab and a utility bar item in a small app of their own, called Ask Claude, and the permission set `Antsurance_Ask_Claude`. It adds no object, field, record type or picklist value, and changes no app or page of yours. To take it out again, run the first command with `--remove`, which says what would go, and then with `--remove --yes`.

## What it changes in your org

**Added, and invisible to everyone until you give them access:**

- Eight objects of our own (policies and their coverages, people, assets and endorsements, file notes, Claude's work queue and settings), and four small settings types (the model, three sample storm events, test results for Claude's jobs, and the ids of the optional coverage agent).
- Fields on Account, Contact, Case, Opportunity, Quote, Lead and User.
- Record types: Household, Business and Agency on Account; Claim and Policy Service on Case; Policy Sale on Opportunity.
- One app, its tabs and pages, five flows, reports and dashboards, Apex code and screen components. The app's navigation includes two pages of our own: Claude at Work and Event Response.
- Triggers on Case, Opportunity and our Policy object. Ours act only on our own record types. Your own cases and opportunities pass through untouched, and a test in the kit proves it.
- A credential that holds your Claude API key, and permission for Salesforce to reach api.anthropic.com, OpenStreetMap map tiles and Wikipedia images.

**Changed for the whole org, each one only after you say yes:**

- New values in five standard picklists: Case Status, Case Origin, Opportunity Stage, Opportunity Type, Quote Status. Yours are all kept, in your order. If an object has no record types today, people will see the new values on their own records.
- Quotes and Path switched on, if they are off.
- Optional look and feel: a theme, and Accounts renamed to Customers. Everyone sees this. Skip it to keep your own.
- Optional customer portal: needs Digital Experiences, which cannot be switched off again.

**Outside Salesforce, only after you say yes:** the coverage agent (next section) creates an agent, an environment and a skill in your Anthropic workspace.

**Never changed:** your profiles, your sharing settings, your record types, your page layouts, your records.

**State and country picklists:** the app works with them on or off. With them off it stores a state as text. Leave your org as it is.

## The coverage agent (optional)

The app checks coverage on a claim with one Claude call. The coverage agent is a second way: an agent that Anthropic runs for you on Claude Managed Agents. It reads the claim, the policy, the file notes, the documents and the photo assessment step by step, shows each step, and records a finding for the adjuster to confirm. Its tools run in your org as the person who pressed the button.

```
python3 scripts/setup/setup_coverage_agent.py --target-org my-sandbox          # says whether it is set up
python3 scripts/setup/setup_coverage_agent.py --target-org my-sandbox --yes    # sets it up
```

What to know before you say yes:

- **It creates three things in your Anthropic workspace,** the one your API key belongs to: an agent, an environment and a skill. Their ids are kept in the org. The skill's text is in `skills/antsurance-coverage/SKILL.md`.
- **Your key needs Claude Managed Agents.** If it does not have it, setup stops, says so and changes nothing. The app works the same without the agent.
- **Each investigation is billed to your key.** About 10 cents and under a minute in our runs, capped at one dollar a session. The cap is a number in Setup, Custom Settings, Antsurance Coverage Agent.
- **A session keeps what the agent read** (the claim, the policy, the notes, the readings of the documents) in your Anthropic workspace until you delete the session. Nothing in this kit deletes sessions.
- **You can add it later.** Skip it now and run the command when you want it.

## Who can see it

To start, only the person who installs. Access comes from three permission sets, never from a profile:

- **Antsurance CRM**: the app, its tabs, record types, fields and code.
- **Antsurance Claude**: the Home page, the Claude chat, and use of the stored key.
- **Antsurance Desk**: approving what Claude prepared. For leads and managers.

### Finding the app

Open the App Launcher (the grid of nine dots, top left) and choose Antsurance. Salesforce lists its own apps there too, in an order each person can drag to suit themselves. Anyone can make Antsurance the app they land in: App Launcher, View All, drag Antsurance to the top. The installer does not hide other apps or set a default for anyone, because that would mean editing a profile.

### Give more people access

```
python3 scripts/setup/assign_access.py --target-org my-sandbox --propose
```

That reads who uses your org and proposes who should get which permission set. Nothing changes until you run it again with `--apply-proposal --yes`. You can also name people (`--users`) or a public group (`--group`). Every run shows the plan first.

## Tests and code coverage

Salesforce refuses a production deploy when less than 75 percent of the Apex code is covered by tests. This kit holds its own code to that bar in every org, production or not.

```
python3 scripts/setup/verify.py --target-org my-sandbox
```

That runs the app's tests with code coverage, prints the overall figure, and names any class or trigger of ours under 75 percent. It fails if there is one. The install itself holds the same bar: the core phase names its tests, and Salesforce rejects it if any class in it is under 75 percent.

If you add code of your own, write its tests with it and run this again.

## Change the Claude model

Setup, Custom Metadata Types, Antsurance AI Setting, Manage Records, Default. Set the model id your Anthropic account has, and untick Fast Mode if your account does not have it. No deploy needed. A later update of the app puts the kit's value back, and the preflight tells you when yours differs.

## Remove it

```
python3 scripts/setup/uninstall.py --target-org my-sandbox
```

That is a dry run: it lists what would be removed and what would stay. Add `--yes` to remove. If the org holds policies or claims made with the app, it stops and tells you; add `--delete-our-records` to delete those too. It never deletes a record of any other record type.

If you set up the coverage agent: the uninstall removes its ids from the org. The agent, the environment, the skill and their past sessions are in your Anthropic workspace, and they are yours to archive in the Claude Console. Archiving there is permanent, so this kit never does it for you.

To remove one part and keep the rest, add `--capability <part>` (for example `--capability pages`, or `--capability portal`). It leaves what the other parts in the org need, and refuses to remove a part that another installed part is built on. If you installed the whole app and want only a part of it, remove the app and then install that part: a part is not taken out from under the whole app. The preflight you run before that install finds our record types still in the org, switched off, and says they are ours; the install switches them on again.

Before it removes anything, the uninstall asks your org whether a class or trigger of your own uses one of ours. Salesforce would delete ours without a word and yours would stop compiling, so it names them and stops. Change your class so that it no longer uses ours, or keep the part.

Salesforce does not let an installer remove a few things. The dry run lists them with the clicks to remove each by hand: our record types (they are switched off), the picklist values that were added, the Quotes and Path switches, and the portal's site, which stays emptied and switched off because Salesforce deletes no site and does not let Digital Experiences be switched off.

A scratch org needs no uninstall: `sf org delete scratch --target-org antsurance-trial --no-prompt`.

## If something fails

Every script stops at the first failure and says what failed and what to do. Nothing is skipped quietly. A failed deploy is rolled back by Salesforce, so the org is never left half done. Fix what it names and run the same command again.

## Support

This is a sample, provided as is, with no warranty and no support commitment. Test it in a scratch org or sandbox before any use with real records.
