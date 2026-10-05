# The decisions to ask

Ask these after the analysis and before any change. Use the AskUserQuestion tool: one question per decision, the recommended option first with "(Recommended)" at the end of its label, and one line of consequence for each option. If the tool is not available, ask the same thing in plain text and wait for the answer.

- Never ask what the analysis already answered. Each question below says when to skip it.
- Never more than four questions in one go. If more than four apply, ask the first four, then the rest.
- Record every answer at the end with `write_report.py --answer key=value`, so a second run or the uninstall knows what was chosen.

Read the facts from `setup-report.json`: `facts.org`, `facts.features`, `facts.holdsRecords`, `facts.previousInstall`, `facts.valueSets`, `facts.customThemes`, `facts.comparison`, `facts.apps`, and the findings with their `key`.

The first two questions below, A and B, come before all the others: they decide which of the others apply.

If they chose parts and not everything, then ask question 1, question 2, question 8 where it applies, questions 6 and 7 only when a chosen part needs them (the installer says which, and `FEATURES.md`, "What each choice needs in the org first"), and the extras they picked. Skip the rest. For a part, question 2 has one command behind it: `assign_access.py --capability PART`, which gives the part's permission set and those of what it is built on. For Ask Claude alone the installer gives the person installing `Antsurance_Ask_Claude`, and each other person gets it with `sf org assign permset --name Antsurance_Ask_Claude --target-org ORG --on-behalf-of USERNAME`.

## A. What to install

Always ask, right after the preflight and before any plan. Skip only when the person already said exactly what they want ("install everything", "only Ask Claude").

Read the choices from the kit, not from memory: `python3 scripts/setup/deploy_phase.py --list` prints each one with what it comes with and what it needs in this build. Say the one-line shape first, in your own words: it is a chain. The data model is at the bottom, the automations sit on it, the components on the automations, and the pages on all three. Ask Claude stands apart.

The AskUserQuestion tool takes four options to a question, so this is asked in up to three questions, in one go.

**"What do you want installed?"** (one answer)

- **Everything (Recommended).** The whole app: data model, automations, components with the Claude features, pages and the app, reports and dashboards.
- **Only Ask Claude.** The chat on a tab and in the utility bar. Needs nothing else of ours and adds nothing to your objects.
- **Let me choose the parts.** You pick from the four parts below. Each comes with what it is built on, and I tell you what that is before anything is installed.

**"Which parts?"** (several answers; ask only when they said they will choose)

- **Insurance data model.** Policies, coverages, people, assets, endorsements and file notes, plus our fields and record types on Account, Contact, Case, Opportunity, Quote and Lead. Comes with nothing else of ours.
- **Automations.** The three triggers with their classes and the five flows. Comes with the data model. Also brings the quote advisor and the connection to Claude, with no key in it.
- **Screen components and the Claude features.** Every Lightning web component and the Apex it calls. Comes with the data model and the automations, because its tests count on what the triggers do.
- **Page layouts, record pages and the app.** The app, its tabs, record pages, layouts, buttons and paths. Comes with the data model, the automations and the components: all of the app but the reports and the sample data loader.

**"Any of the extras?"** (several answers; none is a fine answer)

- **Customer portal (Experience Cloud site).** A site for customers. Comes with the data model, the automations and the components. Switches on Digital Experiences, which cannot be switched off again.
- **Look and feel (theme and branding).** Our theme for everyone, and three objects renamed. Comes with the data model. Everyone in the org sees it.
- **Sample records.** About 2,100 invented records. Comes with everything. Only for an org with no real records.
- **Coverage agent (Claude Managed Agents).** A second way to check coverage on a claim. Comes with the data model, the automations and the components, needs a working key, and bills each session to it.

Picking an extra here is not yet its yes. Each still gets its own question with its consequences (questions 3, 4, 5 and 9 below), asked only for the ones picked.

Then say back what will be installed, in the installer's own words: run the chosen part with `--dry-run`, or read `brings` and `bringsWhy` for it in `kit-manifest.json`. For example: "Automations needs the Insurance data model, which is not in the org yet, so both will be installed." If the preflight found a part already there (`facts.installedParts`), say so: "The data model is already there."

Answer key: `install` (for example `everything`, `ask-claude`, or `data-model,automation`).

## B. Our data model, or yours

Ask only when what they chose depends on a data model: anything in A but "Only Ask Claude" taken alone (in `kit-manifest.json` those have `needsDataModel` true). Skip it when the org has no custom objects of its own (`facts.conventions.counts.customObjects` is 0): there is nothing to fit to.

**"Use our insurance data model, or fit this to the objects you already have?"**

- **Use the Antsurance data model (Recommended to start).** Our objects and fields are added beside yours. Nothing of yours changes, and what you chose works on ours at once.
- **Fit it to my objects.** I map each object and field of ours to yours, you decide every guess, and I adapt a copy that follows your conventions. Slower, and its tests have to be reworked for your records. This is the `antsurance-adapt` skill.
- **Ours now, mine later.** Install ours to see it working, and fit a part to your objects afterwards.

When they chose "Only Ask Claude", do not ask this. Say instead that the chat already reads their own objects and fields, and that a class of their own can teach it more (`FEATURES.md`, "Ask Claude in an org with another data model").

Answer key: `dataModel` (`ours`, `theirs` or `ours-then-theirs`).

## 1. Which org, and is it a sandbox

Skip when the analysis shows a sandbox, a scratch org or a Developer Edition org and the person named it. Ask when the org is production, or when they are signed in to several orgs and did not say which.

- **Stop and use a sandbox (Recommended).** Nothing is installed here. I help you sign in to a sandbox instead.
- **Try a scratch org.** A throwaway org. Nothing touches this one.
- **Install into production anyway.** Only if you tell me so in your own words. Everyone's picklists change today.

Answer key: `where`.

## 2. Who gets access to start

Always ask.

- **Only me (Recommended).** You get the three permission sets. Nobody else sees a new app, tab, button or page. Open it up later with one command.
- **Me and people I pick.** You name users or a public group. I show the list back before assigning.
- **Propose from how the org is set up.** I read profiles, roles and permission sets and propose who gets what. You approve or edit the list.

Commands: `--only-me --yes`; `--users a,b` or `--group Name` (run once without `--yes` to show the list, then with it); `--propose`, then `--apply-proposal --yes` after they approve.

Answer key: `access`.

## 3. Load the sample records

Skip, and say why, when `facts.holdsRecords` is true (the org holds records of its own: do not offer it), when `facts.previousInstall` is true, or when the finding `noRoomForDemoData` is present.

- **No (Recommended for a sandbox).** The app installs empty. You create your own test records.
- **Yes.** About 2,100 invented records are added. They can be removed with the uninstall.

Answer key: `demoData`.

## 4. Apply the look and feel

Always ask in a sandbox. Mention their own theme by name if `facts.customThemes` lists one.

- **No, keep mine (Recommended).** The app uses your org's theme and your object names.
- **Yes.** Everyone in the org sees a new theme, and Accounts are renamed Customers. Undo by hand in Setup.

Answer key: `lookAndFeel`.

## 5. Set up the customer portal

Skip when no Customer Community license is free (the analysis says so): say it is not possible here.

- **No (Recommended).** Staff features only.
- **Yes.** A site where customers see their policies and file claims. If Digital Experiences is off, switching it on cannot be undone.

Answer key: `portal`.

## 6. Switches to turn on

Ask only when the analysis has the finding `enableQuotes` or `enablePath`. One question covering whichever are off.

- **Turn them on (Recommended).** The app needs Quotes and Path. Each is an org-wide switch. Quotes adds a Quotes list to opportunity pages. Path shows nothing on your pages until you build one.
- **Stop.** The app cannot be installed without them.

Answer key: `enable`.

## 7. Picklist values

Ask only when a finding with the key `firstRecordTypes...` is present, because then the new values will show on people's own records.

- **Add them (Recommended).** Your values are all kept, in your order. Ours are added after them. People will see the extra values in the list.
- **Stop.** The app cannot be installed without its statuses and stages.

Otherwise do not ask: say in the plan that values are added and nothing of theirs is removed.

Answer key: `clashes` (with question 8).

## 8. A clash was found

Ask once for each kind of clash the analysis reported. Use the finding's own words.

**Something in the org already has one of our names** (`nameClash`):

- **Stop and use a scratch org (Recommended).** Nothing is overwritten.
- **It is ours from an earlier try: overwrite it.** The install replaces it.

The finding says whether the org's copy is identical to ours or different. Identical usually means an earlier try. Never offer to rename ours: the prefix is what keeps ours findable and removable.

**Record types with our names are there and nothing else of ours is** (`leftByUninstall`, a DECIDE, or a NOTE that needs no question):

- **Antsurance was removed from this org before: they are ours. Go ahead.** The uninstall leaves them switched off because Salesforce does not let an installer delete a record type. The install switches them on again.
- **One of them is a record type of our own: stop and use a scratch org.** The install would overwrite it.

When the finding is a NOTE, the kit's own notes show its uninstall ran on this org: say so and ask nothing.

**A field of ours is already there as another type** (`fieldTypeClash`):

- **Stop and use a scratch org (Recommended).** Salesforce will not turn one type into the other while the field holds values.
- **It is left from an earlier try: I will delete it first.** Then run the preflight again.

**A picklist value of yours has our name and another meaning** (`valueSetCollision`):

- **Stop and use a scratch org (Recommended).** The app would read your value with your meaning.
- **Go ahead: ours can live with yours.** The installer keeps yours as it is. Say which behavior differs, in the finding's words.

**A record type of yours has the same label as one of ours** (`recordTypeLabels`):

- **Go ahead (Recommended when few people hold both).** Only people with our permission set and yours see both.
- **Stop and use a scratch org.**

**The metadata could not be pulled** (`pullFailed`): do not ask. Say the clash checks are thinner, fix what the message names, and run `analyze_org.py --pull-again`.

**A required field of yours would break our saves** (`requiredFields`):

- **Stop. I will give that field a default value first (Recommended).** Then run the analysis again.
- **Install in a scratch org instead.**

**Validation rules, triggers or flows of yours run on the same objects** (`validationRules`, `theirTriggers`, `theirFlows`): do not ask. The NOTE lines (`validationRulesNarrow`, `besideYours`, `layoutRequired`, `notesOn`, `notesOff`, `alreadyInstalled`) need no question either: say them in the plan. Say in the plan that the dry run and the tests will show whether they get in the way, and that a failure will name the rule.

## 9. Set up the coverage agent on Claude Managed Agents

Ask after the Claude API key is stored and `smoke_test.py` has passed. Skip, and say it can be added later, when there is no working key yet.

Say this first, in your own words: the app already checks coverage on a claim with one Claude call. The coverage agent is a second way to do it. It is an agent that Anthropic runs for you on Claude Managed Agents: it reads the claim, the policy, the file notes, the documents and the photo assessment step by step, and shows each step. Its tools run in your Salesforce org as the person who pressed the button.

- **Not now (Recommended).** Nothing is created outside Salesforce. Claims keep the one-call "Check coverage". You can add the agent later with one command.
- **Yes, set it up.** Creates one agent, one environment and one skill in your Anthropic workspace, the one your API key belongs to, and keeps their ids in the org. Each investigation is billed to your key: about 10 cents and under a minute in our runs, capped at one dollar a session. Your key's workspace needs Claude Managed Agents; if it does not have it, setup stops, says so and changes nothing.

Also say, on a yes: a session on Managed Agents keeps what the agent read (the claim, the policy, the notes and the readings of the documents) on Anthropic's side until the session is deleted. Nothing here deletes sessions. A workspace of its own for this is the tidy choice.

Command, only on a yes: `python3 scripts/setup/setup_coverage_agent.py --target-org ORG --yes`. Without `--yes` it only says whether the agent is set up.

Answer key: `coverageAgent`.
