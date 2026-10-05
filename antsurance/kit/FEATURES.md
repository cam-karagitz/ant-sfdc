# What you can install, and what each choice brings with it

You do not have to take the whole app. Pick what you want from the menu below. Each choice installs with whatever it needs, and the installer says what that is before it changes anything.

To see the same menu from the kit itself, with what this build found: `python3 scripts/setup/deploy_phase.py --list`.

## The menu

| You want | It is | Comes with | Command | Gives access |
|---|---|---|---|---|
| Everything | The whole app | Nothing to choose: all of it | Say "install this" in Claude Code, or follow `INSTALL.md` | `Antsurance_CRM`, `Antsurance_Claude`, `Antsurance_Desk` |
| Insurance data model | Our objects, fields, record types and list views. No code, no screens | Nothing else of ours | `python3 scripts/setup/deploy_phase.py --target-org <alias> --only data-model` | `Antsurance_Data_Model` |
| Automations | The three triggers with their classes, and the five flows | The data model | `python3 scripts/setup/deploy_phase.py --target-org <alias> --only automation` | `Antsurance_Automation` |
| Screen components and the Claude features | Every Lightning web component and the Apex it calls | The data model and the automations | `python3 scripts/setup/deploy_phase.py --target-org <alias> --only components` | `Antsurance_Components`, and `Antsurance_Desk` for leads |
| Page layouts, record pages and the app | The app, its tabs, record pages, layouts, buttons and paths | The data model, the automations and the components | `python3 scripts/setup/deploy_phase.py --target-org <alias> --only pages` | `Antsurance_Pages` |
| Only Ask Claude | The chat, on a tab and in the utility bar | Nothing else of ours | `python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude` | `Antsurance_Ask_Claude` |
| Customer portal (Experience Cloud site) | A site for customers | The data model, the automations and the components | `python3 scripts/setup/deploy_phase.py --target-org <alias> --only portal` | `Antsurance_Portal` for portal users, `Antsurance_Portal_Staff` for staff |
| Look and feel (theme and branding) | A theme with its logo, and three objects renamed | The data model | `python3 scripts/setup/deploy_phase.py --target-org <alias> --only look-and-feel` | Nothing: everyone sees it |
| Sample records | About 2,100 invented records | Everything | `python3 scripts/setup/load_demo_data.py --target-org <alias> --yes` | |
| Coverage agent (Claude Managed Agents) | A second way to check coverage on a claim | The data model, the automations and the components, and a working key | `python3 scripts/setup/setup_coverage_agent.py --target-org <alias> --yes` | |

### How the parts stack

This is what a scan of the app found, not a plan drawn first. The build runs the scan every time (`scripts/kit_scan.py` in the source, `kit-scan.json` here) and refuses to build a kit in which a choice does not stand alone with what it brings.

It is a chain, with Ask Claude beside it:

1. **The data model is at the bottom.** It needs nothing else of ours.
2. **The automations sit on the data model.** The triggers and flows name about half of its fields.
3. **The components sit on the automations.** By name they need only the data model: every component and every class compiles without a single trigger or flow. It is their tests that count on the triggers. A test that saves a claim asserts what the case trigger did to it. On the data model alone, all 213 components compiled in a scratch org and 8 of their 458 tests failed for exactly that reason. An install runs the tests, so the components come with the automations.
4. **The pages sit on all three.** Four of the five flows are opened by buttons on the pages, and 82 of the components are placed on them.
5. **Ask Claude stands apart.** It is cut to name nothing of the insurance model.
6. **The portal sits on the data model, the automations and the components.** It does not need the staff app's pages.

The rule the build applies, beyond what names what: a part whose tests work with records of an object that carries one of our triggers brings the part that holds the trigger.

One thing that may surprise you: **choosing the automations alone also installs the connection to Claude** (a named credential and an external credential, with no key in it). The opportunity trigger fills in a newly bound policy from its quote. That code reaches the quote configurator and the quote advisor, and the advisor can ask Claude. Nothing calls Claude until you store a key.

### What each choice needs in the org first

1. **Our values in four standard picklists** (Case Status, Case Origin, Opportunity Stage, Opportunity Type), for the data model and anything on it: `python3 scripts/setup/deploy_phase.py --target-org <alias> --phase value-sets`. Yours are all kept.
2. **Quotes switched on**, for the data model: it adds fields to Quote.
3. **Path switched on**, for the pages: they hold four paths.
4. **Digital Experiences switched on**, for the portal. Salesforce does not let that be switched off again, so the portal always asks for its own yes.

The installer checks these before it deploys and stops with the command to run when one is missing.

### Removing one part

```
python3 scripts/setup/uninstall.py --target-org <alias> --capability automation          (says what would go)
python3 scripts/setup/uninstall.py --target-org <alias> --capability automation --yes
```

It removes that part and leaves what the other parts in the org hold. The parts it takes are `pages`, `portal`, `components`, `automation`, `data-model` and `ask-claude`.

**The order.**
The top comes off first: the pages and the portal, then the components, then the automations, and the data model last. Asked for a part that another part in the org is built on, it changes nothing, names that part and gives the command to run first. Removing the data model is the whole uninstall, which stops for records you would lose and says what Salesforce lets go and what stays.

**It asks first whether anything of yours uses what would go.**
Salesforce deletes a class even when a class of your own uses it. It says nothing at the time, and your class stops compiling. So before a removal changes anything, it asks the org which classes and triggers of yours use a class that would go. If there are any it names each one with what it uses, and stops. Then you choose: change your class so that it no longer uses ours, or keep the part.

**The portal.**
`--capability portal` takes the customer portal out and leaves the rest. Salesforce does not delete a site and does not let Digital Experiences be switched off, so the site stays, emptied of our components and switched to "down for maintenance", with its profile. The removal does four things in an order Salesforce forces: it saves the site's Home and Login pages without our components (Salesforce refuses to delete a component a page shows); it publishes the site again if the published copy still uses ours, and waits for that (the published copy is a copy of its own, and Salesforce publishes only a site that is live); it removes the portal's components, classes, trigger, event and permission sets; and only then switches the site off. Archive the site afterwards in Setup, Digital Experiences, All Sites.

**If it stops part-way,** run the same command again. It takes out what is left and skips what is already gone.

**If you installed the whole app and now want only part of it:** the installer does not take a part out from under the whole app. Remove the app with `uninstall.py` (it keeps your records unless you ask otherwise, and stops to ask), then install the part you want with `--only <part>`.

This was done in a scratch org. The whole app, with the portal and the look and feel, was removed. Then the data model, the look and feel, the automations, the components and the pages were installed on what was left, and the portal after them. Every one deployed with its tests, none failed.

Run the preflight between the two, as before any install. An org the app was removed from still holds our six record types, switched off, because Salesforce does not let an installer delete a record type. The preflight says they are ours and does not stop for them: a NOTE when it runs from the kit folder the uninstall ran from, a DECIDE asking you to confirm when it cannot see that the uninstall ran. The install switches them on again. Our deleted fields sit in each object's Deleted Fields for 15 days and are not in the way: their names are free at once.

### Checking one part, and giving people access to it

```
python3 scripts/setup/verify.py --target-org <alias> --capability automation
python3 scripts/setup/assign_access.py --target-org <alias> --capability automation --users a@example.com
```

`verify.py` checks that the part and what it needs are in the org, that you hold its permission sets, that nothing else of ours is there beyond the parts installed, and that every class and trigger in it and in what it is built on is at 75 percent coverage or more. `assign_access.py` gives a person the part's permission set and those of what it is built on, and nothing else.

Each part's permission set grants only what that part holds. They are cut from the whole app's sets when the kit is built, so they cannot fall behind them.

### From parts to the whole app

Install the whole app the usual way, on top of the parts. The core phase finds the parts' permission sets, and removes them when everyone who held one now holds `Antsurance_CRM`; otherwise it leaves them and says who still holds them.

## The portal: your customers are yours to set up

The portal part installs the site, its screens and code, one profile ("Antsurance Customer", on the Customer Community license) and one permission set ("Antsurance Portal Customer"). It makes no portal users. Which of your customers get a sign-in, on which license and profile, and how they sign in depend on how your org already serves customers, so that part is configured in your org, with Claude Code: say "give a customer access to the portal" and it follows `.claude/skills/antsurance-install/references/portal-users.md`.

1. If you already have a customer profile, it is kept and not edited: its users get our permission set, and the profile is added to the site's members.
2. A customer has no access to any object. The portal's code works out who they are from their own sign-in and shows them only their own account's records, so there is no sharing to configure.
3. Start with one test contact of your own, and look at the site as that customer with "Log in to Experience as User", before any real customer is enabled.
4. Proven: the site and its 17 tests in clean orgs, and its removal with no portal users on it. Not proven by us: a site with your real portal users on it, which is your org's own setup.

## Fitting a part to the objects you already have

You may already keep policies or claims in objects of your own, with other names and other fields. Then you have two ways to use a part of this app:

1. **Install our data model beside yours.** Nothing of yours changes. Our automation and components work on our objects. This is the quick way to see it working.
2. **Fit the part to your objects.** A copy of the part is made that names your objects and fields in place of ours. Say "fit this to my objects" in Claude Code: it follows the `antsurance-adapt` skill.

What fitting involves, in order:

1. The preflight reads your org and writes down its conventions.
2. `python3 scripts/setup/describe_capability.py --capability automation` lists every object, field, record type and picklist value the part names. That is the list to map.
3. Claude proposes a mapping from your pulled metadata and asks you about every line that is a guess. The mapping is a file: `scripts/setup/mapping.example.json` shows the format.
4. `python3 scripts/setup/adapt_capability.py --capability automation --mapping mapping.json --out adapted/` writes the copy. It does the renames it can be sure of, names the copies by your conventions, and writes `adapted/ADAPT-REPORT.md`: what it changed, and every place that needs a decision, with file, line and reason.
5. Claude works through those places with you, makes the tests build your own records, and deploys the copy with its tests at 75 percent or more.

The copy is yours. It carries your names and follows your conventions. Our files are not edited, nothing of yours is renamed, and a test or an assertion is never deleted to get something through.

**How much the adapter does, measured on three pieces of different kinds.**

| Piece | Names changed by the adapter | Places it flagged | Finished by hand |
|---|---|---|---|
| A trigger and its class (our policy trigger) | 39 in 6 files | 7 | 1 line in the class, 4 edits and 2 new tests in the test |
| A flow (past due follow up) | 6 in 1 file | 1 | 1 condition added to the flow, and a test class written for it |
| A screen component with its Apex (the customer summary) | 102 in 22 files | 34 | 10 edits in the class, 4 in the script, 2 icon lines, 4 pieces of text, access to 2 new fields, and the test's records built again for the other model: 37 lines replaced and 73 written |

Renaming is the adapter's. Everything it did was right in all three. What is left is judgment, and it grows with how much of our model a piece leans on: a flow that names three fields needs one decision, and a component whose test loads our sample records needs its test's records written again for your model. Nothing is left in silence: a field the mapping does not mention, a class of ours that is not in the copy, a picklist value inside a component's script, a file the code loads, and any line that still says Antsurance are each written in the report.

`examples/acme/` is the worked example: an invented `Acme_Policy__c` with other field names, a lookup where ours is a master-detail and a required field we do not have, three mappings (the policy trigger, the flow, the component), and a model class for the chat.

### Ask Claude in an org with another data model

**What works unchanged.** The chat reads the org's own schema when it runs (`AntsuranceClaudeModel`): your standard and custom objects, their fields, picklist values, record types and lookups. So it answers questions about your records, draws charts and lists from them, shows a compact card for any record, opens a form for any object you may create or edit, and prepares a follow-up task. None of that needs mapping, and it names nothing of ours.

**What fitting it further means.** A schema cannot say what a record is called in a sentence, which facts are worth working out for Claude (days until a policy ends, whether a claim is over its reserve), which starting points to offer, or which changes Claude may prepare beyond a task. That is written in one class of your own that extends `AntsuranceClaudeModel`, the way our own insurance model (`AntsuranceClaudeInsurance`) does. You override only what you have something to say about:

1. `wordFor` and `words`: what records are called, and the starting points and questions the chat offers.
2. `factsQuery` and `addFacts`: what Claude is told about the record on screen.
3. `recordCard`: the card a record is shown as.
4. `actionTools`, `propose` and `confirm`: changes Claude may prepare for a person to confirm.
5. `dataModel` and `rules`: a note about your model in your own words, and your house rules.

The class keeps your name and your prefix. The chat finds it through one setting: put its name in **Chat Model Class** (`Chat_Model_Class__c`) on the `Default` record of Antsurance AI Setting. The field is set by a deploy, not by a click: copy the kit's `customMetadata/Antsurance_AI_Setting.Default.md-meta.xml`, add the value, and deploy that one file. With the field empty the chat uses the insurance model when the whole app is installed, and the schema alone otherwise. A name that is not a class in the org, or not a model, is passed over. An update of the app puts the kit's record back, so deploy your one file again after an update; the preflight lists that record when it differs.

`examples/acme/ask-claude-model/` is the smallest such class, `AcmeClaudeModel`, for the invented `Acme_Policy__c`, with its test and the one-file setting.

## I only want Ask Claude

Ask Claude is a chat on a tab of its own and in the utility bar of every page. It answers questions by reading Salesforce as the person asking, and draws the answer as a chart, figures, a list, a draft, a record card or a form.

Installed alone, it works in any org. It learns the org it is in from that org's own schema: your standard objects, your custom objects, their picklist values, record types and lookups. It needs none of the insurance objects and adds nothing to yours.

### Steps

Run these from the kit's folder. `<alias>` is the name you gave the org when you signed in with `sf org login web --alias <alias>`.

1. **Read the org first, if it has things in it.** A new, empty org needs no preflight.
   ```
   python3 scripts/setup/analyze_org.py --target-org <alias>
   ```
2. **Check it would install.** This changes nothing.
   ```
   python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --dry-run
   ```
3. **Install it.** It deploys the part, runs its tests, and gives you its permission set. Nobody else is given anything.
   ```
   python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude
   ```
4. **Store your Claude API key.** You type it at a hidden prompt. It is never shown, logged or put in a file.
   ```
   python3 scripts/setup/set_api_key.py --target-org <alias>
   ```
5. **Check Claude answers from the org.**
   ```
   python3 scripts/setup/smoke_test.py --target-org <alias>
   ```
6. **Open it.** In the App Launcher, choose Ask Claude. Or:
   ```
   sf org open --target-org <alias> --path /lightning/app/c__Ask_Claude
   ```
7. **Give other people access**, one at a time:
   ```
   sf org assign permset --name Antsurance_Ask_Claude --target-org <alias> --on-behalf-of <their username>
   ```

### What it adds

| Kind | What |
|---|---|
| App | `Ask_Claude`: the Ask Claude tab, Accounts and Contacts, and the utility bar item |
| Tab | `Antsurance_Claude`, labeled Ask Claude |
| Utility bar | `Antsurance_UtilityBar`, with one item |
| Permission set | `Antsurance_Ask_Claude` |
| Apex | 8 classes and 6 test classes, named `AntsuranceClaude*` and `AntsuranceAi*` |
| Screen components | 21: sixteen named `antsuranceClaude*` and five shared pieces |
| Connection to Claude | Named credential `Anthropic_API`, external credential `Anthropic` |
| Setting | Custom metadata type `Antsurance_AI_Setting__mdt` with one record, the model to use |
| Files | Static resources `claudeSpark` (the logo) and `antsuranceFonts` |

### What it leaves alone

1. Your objects. It adds no field, record type, picklist value, trigger, flow, validation rule or page layout.
2. Your apps, pages, profiles and settings. The tab and the utility bar item sit in an app of their own.
3. Your records. Claude reads what the person asking can already read, and nothing is written without a press. The permission set gives access to no records.

Its tests create a few accounts, contacts, leads, opportunities, cases, tasks and one product. Salesforce rolls them back when each test ends. An org with its own required fields or validation rules on those objects can fail them; in a sandbox, add `--test-level NoTestRun` to install without running them.

### What it needs

1. A Claude API key from your own Anthropic account.
2. Lightning Experience.
3. The Salesforce CLI and Python 3.8 or newer, on the machine you install from.

### How it differs from the chat in the whole app

| | Ask Claude alone | In the whole app |
|---|---|---|
| What Claude knows | Your org's own objects and fields, read at run time | The insurance model, written out for it |
| Changes it can prepare | A follow-up task, and a form for a record you may create or edit | Also a file note and a status move on a claim or request |
| A record's card | A compact card: name, status, key fields, a link | The record's own page card where it has one |
| Starting points | Pipeline, tasks, cases, leads, chosen from what you can read | Claims, policies, quotes |

### Put the utility bar item in an app of your own

The Ask Claude app is there so that nothing of yours changes. To have the chat in an app your people already use:

1. Setup, App Manager, find your Lightning app, Edit.
2. Utility Items, Add Utility Item, choose **Antsurance Claude (Utility Bar)**. Label it Ask Claude, set the panel width to 520 and the height to 640, and tick Start automatically.
3. Save.

To add the tab as well: in the same editor, Navigation Items, move Ask Claude to the selected list. People using that app still need the permission set.

### Remove it

The first command says what would go and changes nothing. The second removes it, with the stored key.

```
python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --remove
python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude --remove --yes
```

If you added the utility bar item or the tab to an app of your own, take them out of that app first.

### From Ask Claude to the whole app

Remove the part first, with the command above, then install the whole app the usual way. The whole app carries the same chat, with the insurance model added. This order has not been run end to end; the preflight reports the part as installed if you run it in between.

### What is proven

| | State on 2026-10-05 |
|---|---|
| Proven | Installed alone from the built kit into a new scratch org with nothing of ours in it: 48 components, 88 tests, none failed, every class between 88 and 100 percent covered. In that org the data model note named its standard objects and nothing of ours, a record's facts and card were read, and a task was proposed and confirmed. Removed again with `--remove --yes`, in three steps, none failed. |
| Not proven | A real answer from Claude in that org: no API key was stored there. The screens were not opened in a browser there. An org with a customer's own metadata, required fields or validation rules. The steps for putting the utility bar item in another app. Going from Ask Claude to the whole app. |


## What is proven

State on 2026-10-05, from two scratch orgs with Salesforce Notes off, in three passes. No Claude API key was stored there, so nothing below includes an answer from Claude.

| What | Seen |
|---|---|
| The data model alone | Installed: 251 components. Before our picklist values were in, the installer stopped and gave the command to add them. |
| The automations on the data model | Installed: 29 components, 61 tests, none failed, every class and trigger at 81 percent or more. It said the data model was already there. |
| The components without the automations | Not installable, and now not offered: all 213 components compiled, 8 of 458 tests failed because each asserts what a trigger did, and Salesforce rolled it back. That is why the components come with the automations. |
| The components on the automations | Installed: 199 components, 421 tests, none failed, every class at 81 percent or more. |
| The portal on the data model, automations and components | Installed without the whole app: 61 components, 17 tests, none failed, with the staff permission set `Antsurance_Portal_Staff`. |
| The pages on all three | Installed: 61 components, and the closing line named all five parts in the org and nothing else of ours. Its dry run passed first. |
| Everything, on top of the parts | Installed through the core phase: 653 components, 516 tests, none failed, 94.9 percent overall, lowest class 81.7 percent. The parts' four permission sets were removed once the whole app's covered them. |
| A part asked out from under the whole app | Refused, nothing changed, with the command for the whole uninstall. |
| `assign_access.py --capability` | For the automations it gave two sets (data model, automations) and nothing else. For the components it then gave one more. |
| `verify.py --capability` | Components: failed before their access was given, naming the set and the command. Then 49 test classes, 515 tests, none failed, 94 percent over the 60 classes and triggers of the components and the automations, lowest 81. Automations, after the components were removed: 62 tests, 96 percent over 11. |
| Removing a part from under another | Refused, naming the pages and the portal, nothing changed. |
| Removing the pages | 55 components in 3 steps. A direct count in the org afterwards: none of our Lightning pages, tabs, buttons, paths, layouts on standard objects or the app left; the layouts of our own objects stay with the data model, as it says. |
| Removing the portal | Emptied the site's Home and Login pages, published the site again, waited 60 seconds, removed 27 components in 4 steps, switched the site off. The first try showed the order Salesforce needs, which is now the order it uses. A run that had stopped part-way was run again and finished. |
| Removing the components | 199 components in 3 steps. |
| A class of the org's own that uses ours | The automations' removal named two such classes and stopped with nothing changed. With them gone it ran: flows switched off, 34 components in 4 steps. |
| Removing the data model (the whole uninstall) | Stopped for 1 household and 1 policy until asked to delete them. Then 9 steps, none failed; a record of the org's own stayed. Afterwards the org held none of our objects, classes, flows, permission sets, files or report folders. Left, as it says: the logo while the theme shows it, one list view, the record types, and our deleted fields in each object's Deleted Fields. |
| The look and feel through `--only` | Installed on the data model alone: 18 components, with its logo. |
| Ask Claude alone, and a class of the org's own that extends its model | Installed alone: 49 components, 89 tests, none failed. With a class of the org's own that extends `AntsuranceClaudeModel` in the org, the removal named that class and ours and stopped with nothing changed. With the class gone it ran: 45 components in 3 steps. |
| The portal alone, and a class of the org's own that calls one of its classes | The removal named that class and `AntsurancePortalDocuments` and stopped with nothing changed, and the dry run of the whole uninstall named them too. With the class gone the dry run passed. Removed alone for real later, on the parts: 28 components in 4 steps, the site emptied first and switched off last. |
| Everything, into a new org, with the look and feel and the portal | Core phase: 243 components, then 657 with 526 tests, none failed. Look and feel: 18. Portal: 62 components, 18 tests, none failed. The site was then published, as a customer who uses it has. |
| The whole uninstall with the portal and the look and feel installed | One run, nothing refused that it does not say stays. The portal first: Home and Login saved without our components, the permission set, the trigger, then the components and classes were refused by the published copy, so the site was published again, and after one wait of 60 seconds they went; the event; the site switched off. Then flows off, five of six record types off, and nine steps. A direct count afterwards: none of our classes, triggers, screen components, document pages, permission sets, objects, flows, report or dashboard folders, apps, tabs or credentials, and no custom field left live on a standard object. Left, as it says: one record type still on (the last on Opportunity), one list view, the three processes, the 56 deleted fields in Deleted Fields, the look and feel's theme with its logo, the site switched off with its profile, Digital Experiences on. Also left, and Salesforce's own: the site's guest profile, its guest group and a file named SiteSamples. |
| The preflight on an org the app was removed from | It stopped on our six record types as a name clash. Fixed: it now says they are what the uninstall left, and the verdict on that same read is no longer a stop. |
| Installing parts after removing the app | Data model 253 components; look and feel 18; automations 29 with 61 tests; components 199 with 430 tests, 94 percent, lowest class 81; pages 61. None failed. The closing line named the four parts and nothing else of ours. |
| Removing the pages with the look and feel installed | 54 components in 2 steps, and the third step said the logo file is left because the theme shows it. Afterwards the logo file, the theme and the theme's line naming the logo were all in the org, and no app, tab or Lightning page of ours. |
| The portal put back after it was removed | Installed again on the emptied, switched-off site: 62 components, 18 tests, none failed. Then removed alone again. |
| The preflight on an org that holds a part | Read the org in 6 commands and said the data model is installed by itself and is not a clash. |
| Fitting our policy trigger to an invented `Acme_Policy__c` | The adapter changed 39 names in 6 files by itself and flagged 7 places. Deployed with 4 tests, none failed, 100 percent, and the trigger stamped the customer's name on a saved Acme policy. |
| Fitting a flow | 6 names changed, 1 place flagged. Deployed on the first try with a test class of 2 tests, none failed. An Acme policy that went overdue got its owner a task naming the policy and its contact. |
| Fitting a screen component with its Apex | 102 names changed in 22 files, 34 places flagged. Deployed on the first try: 7 tests, none failed, the class 95 percent covered. Its Apex returned the right counts, premium and loss ratio for an Acme customer and for a broker. |
| A model class of an org's own for the chat | `AcmeClaudeModel` deployed with the setting that names it: 6 tests, none failed, 97 percent. |

Not proven in an org, and why: an answer from Claude in any of these (no API key may be stored there); the screens in a browser, the fitted component on a page among them (it compiled and its Apex answered, and nobody looked at it); an org with a customer's own metadata beyond the invented Acme model and two small classes; a portal with portal users in it (the removal counts them and says to deactivate them, and no portal user was made in the scratch orgs); the theme looked at in a browser after the pages were removed (the theme, its logo file and the line that names it were read from the org).

## Every feature of the kit

Which choice on the menu holds each feature. "Whole app only" means no part holds it: it comes with Everything.

| Feature | What it is | Made of | Needs | Comes with the choice |
|---|---|---|---|---|
| Ask Claude | Chat on a tab and in the utility bar | `classes/AntsuranceClaude*`, `lwc/antsuranceClaude*` | A Claude API key | `--only ask-claude`, alone. Also in the components, with the insurance model |
| Insurance data model | Policies, coverages, people, assets, endorsements, file notes; fields and record types on Account, Case, Opportunity, Quote, Lead | `objects/`, `globalValueSets/` | Picklist values added to four standard picklists, Quotes on | `--only data-model` |
| Triggers | What runs when a claim, a policy sale or a policy is saved | `triggers/`, `AntsuranceCaseAutomation`, `AntsurancePolicyContents`, `AntsurancePolicyAutomation` | The data model | `--only automation` |
| Guided flows | File a claim, record a payment, add a driver, bind a policy, past due follow up | `flows/` | The data model | `--only automation`. Their buttons are in the pages |
| Record cards | A summary card for each kind of record | `lwc/antsurance*Summary`, `antsuranceRelatedList` | The data model | `--only components` |
| Home | Figures, Claude's briefing and a workspace of tabs | `lwc/antsuranceHome*`, `antsuranceCockpit*`, `AntsuranceCockpitController` | The data model, a key | `--only components`. Its tab is in the pages |
| Claims work | Intake, coverage check, brief, photos, documents, analysis, letters | `AntsuranceClaimsAssistant*`, `AntsuranceClaimLetters`, `lwc/antsuranceClaim*` | Claims on Case, a key | `--only components` |
| Coverage agent | An agent that works a coverage question step by step | `AntsuranceCoverageAgent*`, `skills/` | Claude Managed Agents; set up by its own step | `--only components` holds its code; `setup_coverage_agent.py` sets it up |
| Quotes and underwriting | Guided quote, price, Claude's suggestions, submission intake, underwriting review | `AntsuranceQuote*`, `AntsuranceSubmissionIntake`, `AntsuranceUnderwritingController` | Quotes switched on | `--only components`. The quote configurator and advisor also come with the automations |
| Renewals | Renewal outreach and a daily renewal job | `AntsuranceRenewal*` | Policies | `--only components` for the outreach. The daily job is whole app only |
| Claude's desk | Routine work prepared for approval | `AntsuranceDesk*`, `objects/Claude_Work__c` | The claims, renewal and underwriting features | `--only components`, with the permission set `Antsurance_Desk` |
| Event response | Insured locations inside a storm's footprint | `AntsuranceEvent*`, `lwc/antsuranceEvent*` | Insured assets with coordinates | `--only components` |
| Documents | Four branded PDFs and a claim letter | `pages/`, `AntsuranceDocument*` | Policies and quotes | `--only components` |
| Record pages, layouts and the app | A page for each kind of record, the app, its tabs, buttons and paths | `flexipages/`, `layouts/`, `applications/`, `tabs/`, `quickActions/`, `pathAssistants/` | Path on | `--only pages` |
| Reports and dashboards | 68 reports, 6 dashboards | `reports/`, `dashboards/`, `reportTypes/` | The data model | Whole app only |
| Look and feel | Theme, and Accounts renamed to Customers | `optional/look-and-feel/` | Your yes: it changes what everyone sees | `--only look-and-feel` |
| Customer portal | A site where a customer sees their own household | `optional/portal/` | Digital Experiences, which cannot be turned off | `--only portal` |
| Sample records | About 2,100 invented records | `AntsuranceDemoData` | An org with no real records | Whole app only |
