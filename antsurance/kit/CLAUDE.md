# Antsurance kit

Antsurance is a sample insurance CRM for Salesforce with Claude built in: customers, policies, claims, service requests, quotes and sales, with Claude working inside each.
This folder is a Salesforce project (`sfdx-project.json`, metadata under `force-app/` and `optional/`) plus an installer (`scripts/setup/`) that puts the app, or one feature of it, into an org.
`README.md` says what the product is, `INSTALL.md` is the page for a person, `FEATURES.md` is the menu of what can be installed (everything, or the parts a person chooses, each with what it brings), and this file is for you.

## Start here

Pick the row that matches what the person asked for. When they say install, deploy, set up, try or remove, use the skills in `.claude/skills/` (`antsurance-install`, `antsurance-uninstall`) and follow them step by step. When they want a part to work on objects of their own, use `antsurance-adapt`.

| The situation | The path | First command |
|---|---|---|
| They want to see it, or have not said where | A new scratch org. Nothing touches a real org. | `scripts/setup/test_in_scratch_org.sh --dev-hub <hub>` |
| A new, empty Developer Edition or trial org | The preflight, then the phases. In an empty org the preflight is quick and pulls nothing. | `python3 scripts/setup/analyze_org.py --target-org <alias>` |
| A sandbox, or any org with things in it | **The preflight is mandatory before anything else.** It pulls the org's metadata, reports every clash, and writes down the org's conventions. Then the decisions, the plan, a yes, and the phases. | `python3 scripts/setup/analyze_org.py --target-org <alias>` |
| "I only want part of it" (the data model, the triggers and flows, the components, the pages, Ask Claude, the portal) | Still the preflight first, in any org that is not new and empty. Then ask which parts (the install skill's question A; `python3 scripts/setup/deploy_phase.py --list` prints the menu) and install each with `--only <part>`. The installer reads what the org holds, says what the part needs and whether that is already there ("Automations needs the data model; both will be installed"), deploys what is missing in order, runs each part's tests, and gives access with each part's own permission set. For Ask Claude that is `python3 scripts/setup/deploy_phase.py --target-org <alias> --only ask-claude` and the permission set `Antsurance_Ask_Claude`. `FEATURES.md` has the menu, what each choice brings and the exact command. Never build a partial install yourself by picking files out of `force-app/`. | `python3 scripts/setup/analyze_org.py --target-org <alias>` |
| "Make it work on my own policy and claim objects" | The `antsurance-adapt` skill: preflight, describe the part, map ours to theirs with the person deciding every guess, run the adapter into `adapted/`, finish what it flags, deploy the copy with its tests. See "Fitting a part to the org's own data model" below. | `python3 scripts/setup/describe_capability.py --capability <part>` |
| The app is already in the org and they want something added or changed | Read "What is in the app" and "How to add to it" below. Run the preflight first if `org-conventions.md` is missing or old. | `python3 scripts/setup/analyze_org.py --target-org <alias>` |
| They ask what installing would change | Run nothing but the preflight, which changes nothing. Summarize `.claude/skills/antsurance-install/references/what-it-changes.md`. | |
| Remove it, or one part of it | The `antsurance-uninstall` skill. Dry run first. One part: `--capability <part>`, top down (pages and portal, components, automations, data model). The whole app installed and only a part wanted: remove the app, then install the part. | `python3 scripts/setup/uninstall.py --target-org <alias>` |

The preflight is one command, `analyze_org.py`. It is read only. It writes `setup-report.md` (the verdict, then every STOP, DECIDE and NOTE with what to do), `setup-report.json` (the same as data), `org-conventions.md` and `org-conventions.json` (how this org names and builds things), and the pulled metadata under `.install/org-metadata/<alias>/`.

## Rules you must follow here

1. **Say the target org before every deploy or data change.** Name the alias, the org's name and what kind of org it is (scratch org, sandbox, Developer Edition, production). The setup scripts print this line themselves; repeat it to the person.
2. **Never deploy to a production org unless the person asks for production in that same message.** Recommend a scratch org first, then a sandbox. The scripts refuse production without `--allow-production`; do not add that flag on your own.
3. **Never put the Claude API key in chat, in a file or in a command line.** Do not ask the person to paste it. Do not read it from their shell history or environment and echo it. The person stores it themselves with `scripts/setup/set_api_key.py`, which reads it at a hidden prompt.
4. **Never load the sample records into an org that holds real records unless the person asks for exactly that.** `load_demo_data.py` refuses by default. Never run `AntsuranceDemoData.reset()` or `AntsuranceDemoData.clear()`: they delete every customer, case and sale in the org.
5. **Show the plan and get a yes before changing anything.** Analysis and dry runs change nothing and need no permission. Everything else does.
6. **Fail loudly, never skip quietly.** If a step fails, stop, show what failed in the script's own words, and say what to do. Do not carry on to the next phase, do not retry with weaker checks (for example without tests), and do not work around a refusal. The scratch script's `--leave-out-failed` drops an extra that failed; add it only when the person has said to go on without that extra.
7. **Access comes from permission sets only.** Never edit or deploy a customer's profile. Never make the app, a tab or a page an org-wide default.
8. **Do not edit files under `force-app/` or `optional/` to make a deploy pass** without telling the person what you are changing and why. The installer deploys a filled-in copy from `stage/`; it never edits the kit.
9. **Never set up the coverage agent unasked, and never archive or delete anything in the person's Anthropic workspace.** `setup_coverage_agent.py --yes` creates an agent, an environment and a skill there and starts billed sessions on their key. Ask first (question 9 in the install skill). Archiving in that workspace is permanent and is theirs to do.
10. **Write for the person in plain words, bottom line first.** Explain any Salesforce term the first time you use it.
11. **Preflight before anything, in any org that is not new and empty.** Run `analyze_org.py` and read `setup-report.md` before a dry run, a deploy, an access change or a single feature. A STOP means do not install there. A DECIDE is the person's to answer, not yours. A check the report says it could not run is unknown, not fine.
12. **Ours keeps its prefix; anything new follows the org; nothing of theirs is renamed.** What the kit ships keeps its `Antsurance` and `antsurance` prefix. The prefix works as a namespace: nothing of the org's is overwritten, and everything of ours can be found and removed. Anything NEW you build in that org follows the org's own conventions in `org-conventions.md`. Where that file says "a guess" or "nothing to go on", ask the person; do not invent a convention for them. Never rename, move or restyle something of theirs to fit ours, and never rename ours to step around a clash: a clash is a STOP for the person to decide.
13. **Hold the coverage bar.** Every Apex class and trigger of ours stays at 75 percent coverage or more, and so does anything you add. Salesforce refuses a production deploy under 75 percent, and a deploy that names its tests, which is how this kit deploys, asks 75 percent of every class and trigger in it. `verify.py` measures it and fails under the bar. Never get a deploy through by dropping tests, by `NoTestRun`, or by tests that assert nothing.
14. **Never take something of ours out from under something of theirs.** Salesforce deletes an Apex class even when a class of the customer's own uses it, with no warning, and theirs then stops compiling. Every removal asks the org first, names each class or trigger of theirs with what it uses, and stops. Read that list to the person and let them choose: change their class so that it no longer uses ours, or keep the part. Never delete or edit their class to get a removal through, and never remove ours by another route.

## What is in the app

Enough to change it sensibly. File paths are under `force-app/main/default/` unless they start with `optional/`.

### The data model (`objects/`)

1. **Policy (`Policy__c`)** belongs to a customer: master-detail to Account, with lookups to the producing agency (Account) and the primary insured (Contact). Four children, each master-detail to Policy: Policy Coverage, Policy Asset (shown as Insured Asset), Policy Endorsement, Policy Participant (which also looks up a Contact).
2. **File Note (`File_Note__c`)** is a dated note with lookups to Case, Policy and Account.
3. **Claude Work (`Claude_Work__c`)** is the queue and log of what Claude prepared for a person to approve. It points at its record by a text id, not a lookup.
4. **Two custom settings** hold what the app keeps for itself: Claude Autonomy (which kinds of work Claude may finish alone) and Antsurance Coverage Agent (the ids of the optional agent).
5. **Three settings types** (custom metadata): Antsurance AI Setting (the model, record `Default`), Antsurance Event (sample storm events), Antsurance Agent Eval (how each of Claude's jobs scored).
6. **Standard objects carry the rest.** Customers are Accounts with record types Household, Business and Agency. Claims and service requests are Cases with record types Claim and Policy Service. Sales are Opportunities with record type Policy Sale, and quotes are standard Quotes. Our fields sit on Account, Contact, Case, Opportunity, Quote, Lead and User.
7. **Everything keys off record types by developer name.** Triggers, pages, paths and Claude's prompts all ask "is this a Claim" by name. A record of any other record type is left alone.
8. **Only `AntsuranceAddress` touches state and country fields,** so the app works with state and country picklists on or off.

### Automation

1. `AntsuranceCaseTrigger` hands to `AntsuranceCaseAutomation` and acts only on Claim and Policy Service cases.
2. `AntsuranceOpportunityTrigger` hands to `AntsurancePolicyContents` and acts only on Policy Sales.
3. `AntsurancePolicyTrigger` hands to `AntsurancePolicyAutomation`, on our own object.
4. One trigger per object, with the logic in a class. `AntsuranceCoexistenceTest` proves a plain case and a plain opportunity pass through untouched.
5. Five flows (`flows/`): File a Claim, Record Claim Payment, Add Driver and Bind Policy are screen flows opened by buttons; Policy Past Due Follow Up runs when a policy's payment status changes.

### Pages, the app and what was generated

1. One Lightning app, `Antsurance`, with its own utility bar (`flexipages/Antsurance_UtilityBar`, one item: Ask Claude) and its own Home page. Record pages are assigned inside the app, per record type and profile, never org-wide.
2. One record page per kind of record (`flexipages/*_Record_Page`). Each is a stack of our components. The Claim page holds the case summary, the status path, Claude's brief, the coverage check, documents and photos, the claim analysis and file notes. The Policy page holds the policy summary, coverages, renewal outreach, documents and file notes. The Policy Sale page holds the quote board and submission intake. The Quote page holds the quote configurator and the underwriting review.
3. **The record pages, layouts, the app, the five flows and their buttons, the reports and dashboards, and the objects and fields were written by generator scripts that are not in this kit.** Here they are plain metadata files. Edit them directly, and keep related files in step by hand: a new field needs its line in the `Antsurance_CRM` permission set, and so does every new class with an `@AuraEnabled` method and every new Visualforce page controller.
4. Five document pages (`pages/`, Visualforce rendered as PDF): declarations, ID cards, certificate, proposal and claim letter. Each has a controller of the same name and shares `AntsuranceDocumentFormat` and `AntsuranceDocumentLayout`. PDF rendering supports old CSS only: lay out with tables.

### The Claude features, and the code they share

Three classes call the Claude API, all through the named credential `Anthropic_API` (which reads the key from the external credential `Anthropic`), and all read the model from `AntsuranceAiSettings`:

1. **`AntsuranceAiClient`** asks Claude one question and gets one structured answer back (`ask()`, with the answer's shape built as text by `AntsuranceAiClient.Shape`). About twenty classes use it: every feature in the table below except the chat and the agent. It keeps count of the 120 seconds of outside calls a request is allowed and reports a timeout as an `AiException` with a message for the person.
2. **`AntsuranceClaudeController`** runs the chat. It has its own loop, because the chat lets Claude use tools: a read-only query tool that runs as the person, display tools (`AntsuranceClaudeDisplay`), and proposed actions the person confirms (`AntsuranceClaudeActions`). It does not use `AntsuranceAiClient`.
3. **`AntsuranceCoverageAgentApi`** talks to Claude Managed Agents for the optional coverage agent.

| Feature | Screen components (`lwc/`) | Apex behind it | Needs |
|---|---|---|---|
| Ask Claude chat, in the utility bar and on its own tab | `antsuranceClaudeUtility` and `antsuranceClaudePage`, both wrapping `antsuranceClaude` and its `antsuranceClaude*` display blocks | `AntsuranceClaudeController`, `AntsuranceClaudeActions`, `AntsuranceClaudeDisplay`, `AntsuranceClaudeRecordFacts`, `AntsuranceClaudeAttachments`, and `AntsuranceClaudeModel`, which tells the chat about the org it is in by reading that org's schema. The whole app adds `AntsuranceClaudeInsurance`, the insurance model, which the chat finds by name and uses in its place | The credential and the AI setting. Nothing else when installed alone |
| Home | `antsuranceHome` and the `antsuranceCockpit*` family | `AntsuranceCockpitController`, `AntsuranceWorkController` | `AntsuranceAiClient`, the desk, tasks |
| Customer brief and record summaries | `antsuranceCustomerSummary`, the other `antsurance*Summary` cards | `AntsuranceInsightsController` | The data model |
| Claims: intake, brief, photos, documents, coverage check, analysis, letters | `antsuranceClaimIntake`, `antsuranceClaimBrief`, `antsuranceClaimPhotos`, `antsuranceClaimDocuments`, `antsuranceCoverageCheck`, `antsuranceClaimAnalysis`, `antsuranceClaimLetters` | The `AntsuranceClaimsAssistant*` classes (one per job), `AntsuranceClaimLetters`, `AntsuranceClaimRules`, `AntsuranceSalesforceNotes` | `AntsuranceAiClient`, fields on Case, File Note |
| Coverage agent (optional) | `antsuranceCoverageAgent`, inside the coverage check card | `AntsuranceCoverageAgent`, `AntsuranceCoverageAgentApi`, `AntsuranceCoverageAgentTools`, `AntsuranceCoverageAgentSetup` | Set up by `setup_coverage_agent.py`; hidden until then |
| The desk: what Claude prepared, for approval | `antsuranceDesk`, `antsuranceDeskAutonomy` | `AntsuranceDeskController`, `AntsuranceDeskShift` (a queueable job that reuses the claim brief, renewal and underwriting classes) | Claude Work, Claude Autonomy, the `Antsurance_Desk` permission set |
| Submission intake and underwriting review | `antsuranceSubmissionIntake`, `antsuranceUnderwritingReview` | `AntsuranceSubmissionIntake`, `AntsuranceUnderwritingController` | `AntsuranceAiClient`, the quote configurator |
| Quote configurator and advisor | `antsuranceQuoteConfigurator`, `antsuranceGenerateQuote` | `AntsuranceQuoteConfigurator`, `AntsuranceQuoteAdvisor` (they call each other) | Standard Quotes switched on |
| Renewal outreach | `antsuranceRenewalOutreach` | `AntsuranceRenewalOutreachController`, `AntsuranceRenewalJob` (schedulable, not scheduled by the install) | `AntsuranceAiClient` |
| Event Response | `antsuranceEvents`, `antsuranceEventMap` | `AntsuranceEventController`, `AntsuranceEventGeometry` | Antsurance Event records, the OpenStreetMap trusted site |
| Claude at Work | `antsuranceAgents` | `AntsuranceAgentsController` | Antsurance Agent Eval records, Claude Work |
| Documents and file notes | `antsuranceDocuments`, `antsuranceFileNotes` | `AntsuranceDocumentController`, `AntsuranceFilesController`, `AntsuranceNotesController` | The document pages |

Shared screen pieces that most components import: `antsuranceFonts` (the fonts), `antsuranceUiStyles` and `antsuranceClaudeBlockStyles` (style sheets), `antsuranceText` and `antsuranceIcons` (helpers), `antsuranceUiMemory` (remembers a tab or page per person), `antsuranceMarkdown`, `antsuranceStepPager`, `antsuranceTabs`, `antsuranceAccordion`. `antsuranceClaudeClient` is the chat's client-side helper.

**How the pieces depend on each other.** In the full app everything rests on the data model: the Apex names our objects, fields and record types in its queries, so a class lifted out of `force-app/` does not compile without them. The Claude features rest on the credential and the AI setting. The chat stands apart from the other Claude features. The desk reuses the claim, renewal and underwriting classes. The portal and the coverage agent are extras on top.

**The dependencies are measured, not remembered.** When the kit is built, a scan reads every file and records what names what: each class, trigger, flow, component, page, layout, button and tab, and every object, field, record type and picklist value it uses. The result is `kit-scan.json` in the kit root (`nodes`, `edges`, `objects`, `valuesNamed`), and what it means for installing is in `kit-manifest.json` under `capabilities` and in `capabilities/<part>/capability.json`. Read those before reasoning about what can be installed without what. What the scan found:

1. **The data model** (`data-model`) is at the bottom and needs nothing else of ours. It does need our values in four standard picklists and Quotes switched on.
2. **The automations** (`automation`) sit on the data model. They carry more than triggers and flows: the opportunity trigger's handler reaches `AntsuranceQuoteConfigurator` and `AntsuranceQuoteAdvisor`, and through them `AntsuranceAiClient` and the Anthropic credential. So the automations alone bring the connection to Claude, with no key in it.
3. **The components** (`components`) sit on the automations. By name they need only the data model: every component and class compiles without a trigger. Their tests are what count on the triggers: a test that saves a claim asserts what the case trigger did. On the data model alone, 8 of their 458 tests failed in a scratch org for that reason. The build applies that as a rule: a part whose tests work with records of an object that carries one of our triggers brings the part that holds the trigger (`testsCountOn` in the manifest says which objects and which tests).
4. **The pages** (`pages`) sit on all three: four flows through their buttons, 82 components on the record pages.
5. **Ask Claude** (`ask-claude`) stands apart, in `slices/ask-claude/`.
6. **The portal** (`portal`) sits on the data model, the automations and the components. It does not need the pages. It can be taken out again by itself; its site stays, emptied and switched off.
7. **The look and feel** (`look-and-feel`) sits on the data model and carries its own logo file.
8. **Only the whole app** holds the reports, dashboards, report types, the sample data loader and the scheduled jobs.

When you add a test of your own that saves a claim, a policy sale or a policy, remember the same thing: it runs our triggers when they are there, and what it asserts depends on whether they are.

Asking for a part installs it and what it needs, and says so before anything is deployed. A part is never installed without what it is built on, and never removed from under a part that is built on it, or from under the whole app: with the whole app installed, the way to keep only a part is to remove the app and install that part.

**Parts that install alone are built for it.** The four parts above are sets of files in `force-app/`, listed in `capabilities/<part>/capability.json`, each with a permission set of its own that grants only what the part holds (`Antsurance_Data_Model`, `Antsurance_Automation`, `Antsurance_Components`, `Antsurance_Pages`); those sets are cut from `Antsurance_CRM` and its two companions when the kit is built. The build refuses to produce a kit in which a part names something outside itself and what it brings. Ask Claude is different: it has its own copy under `slices/`, cut so that it names nothing of the insurance model, with its own small app and its own permission set: `slices/ask-claude/`, the app `Ask_Claude` and the permission set `Antsurance_Ask_Claude`. `deploy_phase.py --only ask-claude` installs it and the same command with `--remove` takes it out again. Its chat names no insurance object: `AntsuranceClaudeModel` builds what Claude is told from the org's own schema, and offers a follow-up task as the one change it can prepare. That is why picking files out of `force-app/` by hand is the wrong way to install one feature, and why the preflight, when it finds only such a part in an org, says "that part is installed here" and compares the org with the part's own files.

### Fitting a part to the org's own data model

Many orgs already keep policies or claims in objects of their own. Then the person chooses: install our data model beside theirs, or fit a part to theirs. Fitting is the `antsurance-adapt` skill. In short:

1. `describe_capability.py --capability <part>` prints what the part names: every object, field with its type, record type and picklist value, and the classes and components it is made of. `--only Type:Name` narrows it to one trigger or component and the code it needs. That list is what has to be mapped.
2. The mapping is a file (`scripts/setup/mapping.example.json` shows the format): for each of ours, the thing of theirs it is, or "create ours beside theirs", or "leave out". Propose it from the pulled metadata in `.install/org-metadata/<alias>/` and ask the person about every line that is a guess.
3. `adapt_capability.py --capability <part> --mapping mapping.json --out adapted/ --org-metadata .install/org-metadata/<alias>` writes a copy with the sure renames done and the copies named by `org-conventions.json`, and `adapted/ADAPT-REPORT.md`: what it changed, and every place that needs judgment with its file, line and reason. It refuses a mapping that leaves out something the part names. It never edits `force-app/` and never calls the org.
4. You finish the flagged places in `adapted/`, make the tests build the org's own records, dry run, deploy with the tests named and every class and trigger at 75 percent, and check the behavior.

**What to expect of it.** Measured on a trigger with its class, a flow, and a screen component with its Apex, each fitted to an invented model and deployed (`FEATURES.md` has the table): the adapter did every rename, 39, 6 and 102 of them, and none had to be undone. It flagged 7, 1 and 34 places. The flow needed one condition and a test. The component needed 10 edits in its class, 4 in its script and its test's records written again, because the test loaded our sample records. What the adapter cannot do, it writes down: besides types, record types and values with no match, the report names a field of ours the mapping does not mention, a class or component of ours that is not in the copy, a picklist value inside a component's script (a script is handed values without the field's name, so they are never changed for you), a file the copied code loads, and every line that still says Antsurance. A copy with none of those flags can still be wrong for the business: read it.

The rules: what is adapted is theirs and follows their conventions; nothing of theirs is renamed or altered without a yes; our shipped files are not edited; a mismatch the adapter flags is never papered over by deleting a test or an assertion.

**Ask Claude needs no mapping to work.** `AntsuranceClaudeModel` reads the org's schema at run time. To teach it more about their objects, write one class of theirs that extends it (as `AntsuranceClaudeInsurance` does) and name that class in `Chat_Model_Class__c` on the `Default` record of Antsurance AI Setting, with a one-file `customMetadata` deploy. `examples/acme/ask-claude-model/` is the smallest worked example, and `FEATURES.md` says what works unchanged and what such a class adds.

### Access (`permissionsets/`)

1. **Antsurance CRM**: the app, its tabs, record types, objects, fields, pages and nearly every class.
2. **Antsurance Claude**: the Home page, the chat, and use of the stored key (the external credential's principal). Without it Claude's buttons fail with an access error even when the key is right. An org that has only the Ask Claude part has **Ask Claude** (`Antsurance_Ask_Claude`) instead: the chat's tab, its app and the stored key, and nothing of the whole app.
3. **Antsurance Desk**: approving what Claude prepared, for leads and managers.
4. **Antsurance Portal** (`optional/portal/`): for portal users only.
5. **One set for each part that installs alone**: Antsurance Data Model, Antsurance Automation, Antsurance Components, Antsurance Pages, and Antsurance Portal Staff for staff where the portal is installed without the whole app. They are in `capabilities/<part>/main/default/permissionsets/`, cut from the sets above by the build. An org with the whole app does not need them: once everyone who held one holds Antsurance CRM, the core phase removes them.

### The portal (`optional/portal/`, optional)

A customer site where a customer sees their policies and documents, files a claim with photos, asks for a quote and chats with Claude. Its own components (`antsurancePortal*`), classes (`AntsurancePortal*`), a platform event with a trigger that saves what a customer submits, a site and a portal profile for portal users only. It needs Digital Experiences, which cannot be switched off again, so it is its own phase with its own yes. The install creates no portal users: which of the person's customers get a sign-in, on which license and profile, and how they sign in is theirs to decide and yours to set up with them, following `.claude/skills/antsurance-install/references/portal-users.md`. A customer has no object access; the portal's Apex scopes every read and write to the signed-in customer's own account, and that check is never traded for object access on a customer profile.

### The coverage agent (optional)

A second way to check coverage on a claim: an agent on Claude Managed Agents that reads the claim step by step and calls back into the org for the policy, the notes and the documents. Its code installs with the app and stays hidden until `setup_coverage_agent.py --yes` has kept an agent id and an environment id in the Antsurance Coverage Agent setting.

### Sample data

`AntsuranceDemoData.load()` adds about 2,100 invented records. `AntsuranceDemoPrep` attaches sample files to five showcase claims and has Claude do its work on them. Only `load_demo_data.py` and `prepare_demo.py` should call them.

## How to add to it

1. **Read `org-conventions.md` first.** If it is missing, run the preflight. It says how this org names objects, fields, classes, tests, components, flows and permission sets, whether it keeps one trigger per object and a trigger framework, whether fields carry descriptions and help text, and which API versions it uses, with how many examples each observation rests on.
2. **Decide whose it is.** A change to something the kit ships (a fix to `AntsuranceClaimRules`, a new card on our Claim page) is ours: keep the `Antsurance` prefix and the kit's style, and put it under `force-app/`. Something new for the org (their own object, their own automation, a component for their own page) is theirs: follow `org-conventions.md`, keep it out of `force-app/`, and never give it our prefix.
3. **Where things go.** Apex in `classes/`, with its test beside it as `<Name>Test`. Components in `lwc/`, each custom CSS class prefixed `c-`. A new Claude job asks through `AntsuranceAiClient.ask()` with a `Shape`, one Claude call per request, and reads the model from `AntsuranceAiSettings`; never hard-code a model. Anything that reads or writes an address goes through `AntsuranceAddress`. A trigger gets no logic of its own and checks the record type first.
4. **Give access the same way.** Add the new class, field, tab or page to the matching permission set. Never a profile.
5. **Test it.** Write the test with the class. Stand in for Claude with `Test.setMock(HttpCalloutMock.class, ...)` as the existing tests do; no test calls the real API. Tests run as the person deploying, with that person's field access, so they need our permission sets assigned first; the core phase does that. Deploy through `deploy_phase.py`, which runs the tests, then run `verify.py`.
6. **In their org, their automation runs on our records and ours on theirs.** The preflight lists their triggers, flows, validation rules and required fields on the objects we save to. Read that list before adding anything that saves a record.

### The coverage bar

Salesforce refuses a production deploy under 75 percent code coverage and refuses any trigger with none. A deploy that names its tests asks 75 percent of every class and trigger in the deploy. The kit holds the stricter bar for its own code everywhere, sandbox and scratch org included.

1. `python3 scripts/setup/verify.py --target-org <alias>` runs our tests with code coverage in one call, prints our overall figure, and names every class or trigger of ours under 75 percent with its figure and line counts. It exits 1 if there is one, if a trigger has no coverage, or if the overall figure is under 75.
2. The core deploy holds the same bar by itself: it names our tests, so Salesforce rejects it when a class or trigger in it is under 75 percent, and `deploy_phase.py` prints the class and Salesforce's message.
3. When a class falls short: open the class and its test, find the branches no test reaches (the error paths, the "feature is off" paths, the bulk path), and add tests that run them with real assertions. Then deploy the class with its test and run `verify.py` again.
4. **A test that returns early covers nothing.** A test that checks "is this feature on in this org" and returns when it is not will pass and leave its class uncovered in an org where the feature is off. Salesforce Notes is the example: with Notes off, a test that needs the note object has nothing to run. Write such tests so the path for "off" is itself tested.
5. Optional help: Salesforce's `salesforce-development` plugin for Claude Code has two skills for this, `platform-apex-test-run` (run tests, read coverage, fix loop) and `platform-apex-test-generate` (write test classes). Use them if they are installed. Nothing here depends on them.

## The installer's scripts

| Script | What it does | Changes the org? |
|---|---|---|
| `analyze_org.py` | The preflight. Reads the org, pulls the metadata ours could meet, compares it with the kit, and writes `setup-report.md`, `setup-report.json`, `org-conventions.md` and `org-conventions.json`. `--offline` judges the last read again without a call. `--pull-again` repeats only the pull. | No |
| `preflight.py` | The pull, the comparison and the conventions, used by `analyze_org.py`. Not run by itself. | No |
| `deploy_phase.py` | Deploys one phase, or with `--only <part>` one part and what it needs (`--list` prints the parts and calls no org). `--dry-run` only checks. `--only <part> --remove` says what removing that part would take away, and with `--yes` removes it; the portal is a part for this, and its site stays, emptied and switched off. | Yes, unless `--dry-run` or `--list` |
| `capabilities.py` | What can be chosen, what each choice brings, and what an org holds of it. Used by the scripts around it. Not run by itself. | No |
| `describe_capability.py` | Lists what one part names: objects, fields with types, record types, picklist values, classes and components. `--json` for the same as data. Calls no org. | No |
| `adapt_capability.py` | Writes a copy of a part that names an org's own objects and fields, from a mapping file, with a report of what needs judgment and of everything of ours the copy still names. `--check` only checks the mapping. Calls no org. | No |
| `assign_access.py` | Gives people the permission sets. Shows a plan unless `--yes`. `--capability <part>` gives one part's sets. | Only with `--yes` |
| `set_api_key.py` | Stores the Claude API key. Run by the person. | Yes |
| `smoke_test.py` | One short question to Claude from the org. | No |
| `setup_coverage_agent.py` | Says whether the optional coverage agent is set up. With `--yes`, sets it up on Claude Managed Agents. | Only with `--yes` (and the person's Anthropic workspace) |
| `load_demo_data.py` | Adds the sample records. Shows a plan unless `--yes`. | Only with `--yes` |
| `prepare_demo.py` | After the sample records: attaches sample files to five showcase claims and has Claude do its work on them. `--check` changes nothing. | Yes, unless `--check` |
| `verify.py` | Runs the tests with code coverage, holds the 75 percent bar, checks access, gives the app's address. `--capability <part>` checks one part and what it needs. | No |
| `write_report.py` | Writes `install-report.md`. | No |
| `uninstall.py` | Removes the app. Dry run unless `--yes`. `--capability <part>` removes one part and leaves what the others need. Either way it first asks the org whether a class of its own uses one that would go, and stops if so; and it takes the portal out first when the org holds it. | Only with `--yes` |
| `test_in_scratch_org.sh` | The whole install into a new scratch org. | A new scratch org only |
| `prepare_scratch_org.py` | Sets a new scratch org's user's country, so the user record can be saved. | A scratch org only |
| `selftest.py` | Checks the installer's own logic against a stand-in org and a fake key: the preflight, the coverage gate, the menu of parts and the adapter included. | No org at all |

Every script needs `--target-org`. None of them uses a default org. They keep notes in `.install/` and working copies in `stage/`; both are safe to delete.

**What the preflight costs.** With a pull: 6 `sf` commands and about 50 requests against the org's daily allowance, plus one for each second the retrieve takes (18 seconds for the app alone, a minute for a fuller org). Without a pull, in a new empty org: 8 commands and about 55 requests. `--offline` costs nothing.

**What the preflight pulls.** The standard objects ours extends or saves to (Account, Contact, Lead, Case, Opportunity, Quote, Task, User, Activity) and every custom object, each with its fields, record types, validation rules and processes; every page layout, trigger, custom app, tab, Lightning page, action, named and external credential, global value set and theme; the five standard picklists ours adds to; and, by name, whichever of our own classes, components, flows, pages, permission sets and settings records the org already has, so they can be compared with the kit's. The org's own Apex classes, components, flows, permission sets and static resources are listed by name with queries, not pulled, so a large org stays a small pull.

## Things about Salesforce that matter to an installer

- **Standard picklists are replaced, not merged, by a plain deploy.** Deploying a Case Status file with only our values would delete the org's own. Always go through `deploy_phase.py --phase value-sets`, which reads the org's values first and adds ours after them.
- **Our tests run as the person installing, and Salesforce checks that person's access to every field.** So the core phase deploys the data model and permission sets first, assigns them to the installer, and only then deploys the code with its tests. Do not try to deploy everything in one go into an org that is new to the app: every test fails with "fields being inaccessible".
- **State and country picklists.** The app works with them on or off. Only `AntsuranceAddress` touches a state or country field, and it uses the code fields (`BillingStateCode`) when the org has them and the text fields when it does not. Never switch the picklists on in a customer's org for this. New code must go through that class: naming a code field anywhere else stops the app compiling in an org without the picklists, and the kit build reports it.
- **Salesforce Notes can be off.** Then the note object does not exist. The app looks it up by name and works either way: with Notes off it reads no Salesforce notes and does not offer to save one. The preflight says which it is. Do not switch Notes on for this.
- **A Developer Edition org has 5 MB of data storage.** The sample records nearly fill it. Past the limit every insert fails with `STORAGE_LIMIT_EXCEEDED`. Scratch orgs and sandboxes have more.
- **A Developer Edition org allows 15,000 API requests in any 24 hours.** Every `sf` command spends a few. Do not poll in a loop. If you hit `REQUEST_LIMIT_EXCEEDED`, wait; the browser still works.
- **A class with a scheduled job cannot be redeployed.** If `AntsuranceRenewalJob` has been scheduled, a later core deploy fails with "This schedulable class has jobs pending". Delete the scheduled job in Setup, Scheduled Jobs, deploy, then schedule it again.
- **Salesforce allows 120 seconds of calls to outside services per request.** The app makes one Claude call per request and reports a timeout in plain words. A slow model can hit this; pick a faster one in the AI setting.
- **Which record page shows is set per app, record type and profile.** That is why `assign_access.py` redeploys our app after it gives access to people on a new profile. It edits our app, not their profile.
- **A dashboard shows stored results.** After loading records, refresh it. `load_demo_data.py` does.
- **After a deploy, a browser can show the old page.** Reload. If it persists, clear the site's stored data for the org's address and reload.
- **Using the stored key needs the Antsurance Claude permission set.** Without it, Claude's buttons fail with an access error even when the key is right.
- **Ask what the org holds, never what this person may open.** Two "is it there" checks in this installer once read the list of apps (`AppDefinition`) and the list of tabs (`TabDefinition`). Both lists hold only what the person asking may open, so an app or a tab that was in the org read as absent to anyone without access to it, and a part looked half installed. To ask whether an app or a tab exists, count it through the Tooling API, one name at a time: `SELECT COUNT() FROM CustomApplication WHERE DeveloperName = '...'` and `SELECT COUNT() FROM CustomTab WHERE DeveloperName = '...'` (`capabilities.by_name` does this; a Tooling count works inside a batch of questions, a Tooling query for fields does not). The tab of a custom object has no name of its own there: it is there when its object is. The same trap waits in every list Salesforce filters by access: tabs, apps, record types offered, list views. Before writing a check, ask yourself whose view the query returns.
- **Salesforce deletes a class that another class uses, and says nothing.** A destructive deploy of an Apex class succeeds even when a class of the customer's own extends or calls it; theirs fails to compile afterwards ("Variable does not exist"). Salesforce does refuse when a page, a flow or a site uses it. So the removal scripts ask first (`deploy_phase.used_by_theirs`): the Tooling object `MetadataComponentDependency`, filtered by `RefMetadataComponentId IN (...)` with the ids of our classes. It cannot be filtered by name: `RefMetadataComponentName LIKE` is refused. Rule 14 says what to do with the answer.
- **A site cannot be deleted, and it holds on to what it shows.** Salesforce refuses to delete a component while a page of a site shows it ("found in 1 Development Instance(s)"), and refuses the classes those components call while the published copy of the site still uses them ("Web App Resource Dependency"). The published copy changes only when the site is published again, and Salesforce publishes only a live site. That fixes the order of the portal's removal: save the pages without our components, publish, wait, remove, and switch the site off last. Digital Experiences itself cannot be switched off.
- **A site brings things of its own.** With the portal's site Salesforce makes a guest profile named after it (Antsurance Profile), a guest group of the same name and a static resource named SiteSamples. None is ours, none is in the kit, and all three are still there after the portal or the whole app is removed. Do not count them as something the uninstall missed.
- **An uninstall leaves our record types, and the preflight knows them.** Salesforce does not let an installer delete a record type, so the uninstall switches ours off (one stays on where it is the last active one of its object). An org the app was removed from therefore still holds six record types with our names. The preflight does not stop for them when nothing else of ours is there and they are in that state: it says NOTE when this kit's own notes in `.install/` show its uninstall ran on that org, and DECIDE when they do not (a new copy of the kit, or another machine), so the person confirms they are ours. Installing the app or a part again switches them on again. A record type with one of our names that is in use beside others is still a STOP.
- **A folder of reports or dashboards is deleted as a `Report` or a `Dashboard` member that names only the folder.** A destructive deploy that asks for `ReportFolder` or `DashboardFolder` succeeds and deletes nothing. `uninstall.py` translates the two (`AS_DEPLOYED`).
- **A record type is switched off without naming its picklist values.** Deploy it with `active` false and no `picklistValues`: Salesforce leaves its values as they are. Name one value the org's field does not have, as happens when the org and the kit are a version apart, and the whole change is refused.
- **A deleted custom field is kept for 15 days**, renamed with `_del`, under the object's Deleted Fields, in a scratch org too and whatever the deploy asked. Its name is free again at once.
- **A theme names its logo by address** (`/file-asset/<name>` in the branding set), not by a reference Salesforce checks at deploy. The look and feel carries its logo file for that reason, and Salesforce keeps the file while a theme shows it: removing the pages then leaves it in place.
- **Deleting a field or object fails while any flow version, even an inactive one, still uses it.** The uninstall turns our flows off and deletes them before the fields.
- **Record types, picklist values and switched-on features cannot be removed by an installer.** The uninstall says which stay and how to remove them by hand.
- **The Claude model is a setting, not code.** Setup, Custom Metadata Types, Antsurance AI Setting, Default. An update of the app puts the kit's value back, so note a changed model before updating; the preflight lists that record when it differs.
- **The coverage agent is optional and lives partly outside Salesforce.** Its code installs with the app and stays hidden until `setup_coverage_agent.py --yes` has kept an agent id and an environment id in the Antsurance Coverage Agent custom setting. A key whose workspace has no Claude Managed Agents gets a plain refusal and nothing changes. The skill it uploads is the static resource `antsuranceCoverageSkill`; `skills/antsurance-coverage/SKILL.md` is the same text to read.
- **A callout cannot follow a save in one request, and one request gets 120 seconds of outside calls.** That is why `prepare_demo.py` asks Claude for one piece of work per request and can be run again after a failure.
- **The Salesforce CLI ignores every file under a folder whose name starts with a dot.** A retrieve into `.install/` or any other dot folder finishes, reports no error and writes nothing. The preflight retrieves under `stage/` and then moves the result to `.install/org-metadata/`. If you ever retrieve by hand, do it in a folder with no dot in its path below the project.
- **The org rewrites some of what it is given.** It lays out a flow's boxes itself, renames the icon text on a tab, stores an always-required field as required on a page, and leaves out settings that hold their default. The preflight's comparison knows these and does not call them differences. A plain file diff does not.
- **A retrieve names what it could not find instead of failing.** Asking for a settings record whose type the org lacks, or a class it does not have, gives a warning per name. The preflight asks only for the names its questions found, so a clean org gives no warnings; a warning that is left is shown as a NOTE.
- **Their automation runs on our records.** Triggers, record-triggered flows, validation rules and required fields on Account, Contact, Case, Opportunity, Quote, Task and Lead apply to the records the app and its tests create. Salesforce does not promise which trigger runs first. The preflight lists them; the tests in the deploy show whether they get in the way, and a failure names the rule.
- **Our triggers run on their records and step aside.** On Case and Opportunity ours fire for every record and return at once unless the record type is ours.
- **New and Edit dialogs use the org's default page layout.** Layout assignment lives in a profile, which the kit never touches. So a field their layout marks required is asked of someone creating one of our records through the standard dialog. The preflight lists those fields.
- **Coverage is per class in a deploy that names its tests.** One class under 75 percent fails the whole deploy even when the overall figure is high. See "The coverage bar".
