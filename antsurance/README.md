# Antsurance CRM (Salesforce demo org)

SFDX project for Antsurance, a demo org (Developer Edition): the CRM of Antsurance, a fictional insurance
carrier, and its customer portal. It has a custom Lightning theme, an insurance data
model with demo data, record pages for customers, policies, claims, sales and quotes, guided screen
flows, printed documents, reports and dashboards, and Claude at work in claims, underwriting,
renewals, the chat and the portal through the Messages API.

Read next: `../CLAUDE.md` for the platform gotchas.

## Installing it in your own org

The easiest way to get Antsurance into a Salesforce org is the kit, a packaged copy of this project
with an install guide for Claude Code. Build it and work from the result:

```
python3 -I scripts/build_kit.py     # writes dist/antsurance-kit/ and dist/antsurance-kit.zip
```

The kit is this project packaged for your org. It carries an install skill for Claude Code, setup
scripts, an uninstall, and sample addresses that are invented. The install
starts in a throwaway scratch org, analyzes a sandbox before touching it, asks before each org-wide
change, takes the Claude API key at a hidden prompt, and gives access through our permission sets
only, starting with the person installing. The build checks its own output before it finishes. The kit's own files are in `kit/`.

Since 2026-10-05 the kit does not have to go in whole. Claude Code asks which parts you want
(the data model, automations, screen components with the Claude features, pages and the app, the
customer portal, Ask Claude alone, or everything, plus look and feel, sample data and the coverage
agent), says what each one brings with it, and then asks whether to use our data model or fit the
part to objects you already have. Fitting is done with an adapter that renames what it can be sure
of and reports every place that needs judgment. Before any install into an org that is not empty, a
read-only preflight pulls the org's metadata, reports clashes and writes down the org's naming
conventions. Every part can be taken out again. What each part holds is data in
`scripts/kit_capabilities.json`, and the build proves each set stands alone.

| | State on 2026-10-05 |
|---|---|
| Proven | An install from the built kit into a clean scratch org with state and country picklists on (`antsurance-kit-2`, 362 tests, alive until 2026-10-06) and into one with them off (`antsurance-kit-3`, 575 components, 366 tests, 0 failed, since deleted). The portal phase passed in the second: 61 components, 17 tests. A fake key is refused in plain words. |
| Proven on 2026-10-05 | In clean scratch orgs with Salesforce Notes off: each part installed alone and in order and removed alone; the portal without the whole app; the full core (516 tests, 0 failed, 94.9 percent); Ask Claude alone (88 tests); verify and access for a part; the adapter on a trigger and class, a flow, and a component with its Apex for an invented customer model; the app made visible by a permission set. Twelve faults that only an org could show were found and fixed. |
| Not proven | A customer sandbox with its own metadata (the clash and convention logic ran on fixtures and on our own two orgs). A live Claude call in a scratch org (the key may not be copied). An access proposal for more than one user. |
| To decide before you share it | Photo and font licenses, the support wording, the default model, and who signs off. |

## The insurance model

Modeled on the shapes of Financial Services Cloud's insurance objects, using custom objects
because this org has no FSC license, Person Accounts or multi-account contacts.

| Record | How it is modeled |
|---|---|
| Customer | `Account` with a record type: `Household` (its contacts are the members), `Business` or `Agency`. Roll-ups: `Active_Policies__c`, `Premium_in_Force__c`. `Customer_Brief__c` holds a written brief. |
| Policy | `Policy__c`, child of the policyholder account. `Producer__c` is the agency. `Incurred_Losses__c` is kept in step with the policy's claims by the claim trigger, and `Loss_Ratio__c` is that over a year of premium. |
| What a policy contains | Children of `Policy__c`: `Policy_Coverage__c` (limit, deductible, premium per coverage), `Policy_Participant__c` (named insured, drivers and their records), `Policy_Asset__c` (the vehicle, home or building insured, with map coordinates), `Policy_Endorsement__c` (forms, discounts, lienholders). |
| Claim | `Case` with record type `Claim`: loss details, severity, reserve, paid, coverage check, `Handled_By__c` (the adjuster) and `Days_Open__c`. Claude's work is stored on it: the brief, the photo assessment, marked areas (`Photo_Marks__c`) and the analysis (`Claude_Analysis__c`). |
| Service request | `Case` with record type `Policy_Service`: `Request_Type__c` such as Add Driver. |
| File note | `File_Note__c`: a typed, dated note on a claim, policy or customer, written in Markdown. Tasks, calls and events stay on the standard Activity objects. |
| Policy sale | `Opportunity` with record type `Policy_Sale` and stages from Submission Received to Bound. Bound is the closed-won stage; `Policy__c` links the policy the sale became. |
| Quote | The standard `Quote` object (enabled in `settings/Quote.settings-meta.xml`) with premium, limit, deductible and issue date. A sale carries one quote per option offered. `Configuration__c` holds the configurator's answers and price build-up as JSON, `Submission_Channel__c` how the request came in, and `Needs_Underwriting_Review__c` whether an answer calls for an underwriter. |

Line of business is one shared value set (`globalValueSets/Line_of_Business`).

State and country go through one class, `AntsuranceAddress`. It writes the code fields
(`BillingStateCode`) where an org has state and country picklists and the text fields where it does
not, so the project compiles in both kinds of org. No other class names a code field.

### Demo data

`AntsuranceDemoData.reset()` deletes every account, contact, case, opportunity, quote, policy, lead
and task in the org and loads a connected set. One load is about 2,140 records: 68 accounts (3 agencies, 45
households, 20 businesses), 105 contacts, 161 policies with their coverages, participants, assets
and endorsements, 87 cases (46 claims, 41 requests), about 145 file notes, 46 policy sales,
49 quotes, 77 tasks and 25 leads. Dates are relative to the day it runs. The clearing step runs only
in a scratch org or a Developer Edition org, because a sandbox may hold a copy of real records.

The 45 households use real street addresses, with exact coordinates, for demo purposes only, so the
insured asset page's map pin and property-site link land on the actual property. The families,
policies and claims attached to them are invented. `AntsuranceDemoAddresses` holds an invented
street for each household, and the kit ships only those.
The businesses' street addresses are made up. Every demo quote carries configurator answers worked
back from its premium.

Reload only when the person who runs the org wants it. A reload now meets a portal user: a
contact with a portal user cannot be deleted, so deactivate the portal user first, reload, then run
`scripts/portal_user.apex`. That order has not been run.

```bash
scripts/reload_demo.sh --yes     # clear, wait for storage to recount, load, refresh every dashboard
scripts/prepare_demo.sh --check  # say where the showcase claims stand; changes nothing
scripts/prepare_demo.sh          # put the showcase claims into their demo state
```

A reload leaves the showcase claims bare: the burst pipe claim is back at its first estimate of
$47,500 and nothing Claude wrote survives. `scripts/prepare_demo.sh` puts them back. It attaches the
sample files that are missing, raises that claim's estimate to the $48,921 its documents add up to
(with a file note from the adjuster), and has Claude redo its work one step per Apex run: the photo
assessment, a reading of each document, the coverage check, the analysis and the brief. It ends by
printing what each showcase claim says. There are five showcase claims: the burst pipe, the parking lot scrape, the rear-ended CR-V (whose photo is a mismatch on purpose), the roof fall and the deer strike. A sample photo has to fit its claim's vehicle and damage; sources and licenses are in `staticresources/antsuranceDamageSources/LICENSES.md`. It is safe to run twice, never clears or reloads data, and
refuses a production org (`AntsuranceDemoPrep`). After a reload it spends about fifteen `sf` commands
and a dozen Claude calls; when everything is in place it spends four and asks Claude for nothing.
On 2026-10-05 it was run against the org as it stood and changed nothing; it has not been run after
a reload. What a reload still loses: areas a person marked on a photo, a box a person moved, and the
sample video on claim 00002574.

### Automation

| What | Where |
|---|---|
| File a Claim: pick the policy, describe the loss, get the claim number and coverage check. | Screen flow `File_a_Claim`; buttons on the policy and customer pages |
| Record a Payment: pay against a claim's reserve, optionally as the final payment. | Screen flow `Record_Claim_Payment`; button on the claim page |
| Add a Driver: add a household member who is not yet a driver to a personal auto policy, pick the vehicle they drive, rate them and create a re-rating task. | Screen flow `Add_Driver`; button on personal auto policies |
| Generate Quote: start a draft quote on a sale and open its guided questions. | `lwc/antsuranceGenerateQuote`, `AntsuranceQuoteConfigurator.startQuote`; button on open policy sales |
| Bind Policy: turn the accepted quote into a policy (or ask which option the customer is taking), close the sale and mark the quote bound. | Screen flow `Bind_Policy`; button on open policy sales |
| A policy that goes past due gets a follow-up task for the account owner. | Record-triggered flow `Policy_Past_Due_Follow_Up` |
| A serious claim, a claim that becomes serious, or a referral to SIU sends a bell notification to the claim's owner. Closing a claim or request stamps `Closed_On__c`, which stops `Days_Open__c` counting; reopening clears it. | `AntsuranceCaseAutomation`, `notificationtypes/Antsurance_Claim_Alert` |
| Binding a policy sale to a new policy fills that policy in: its coverages, what it insures, and an endorsement for each extra or discount chosen on the quote. | `AntsurancePolicyContents`, `triggers/AntsuranceOpportunityTrigger` |
| A case with a policy gets its customer and contact from the policy; a claim's priority follows its severity; `Coverage_Check__c` says whether the policy covered the date of loss; new claims, requests and SIU referrals create follow-up tasks; a policy's incurred losses follow its claims. | `AntsuranceCaseAutomation`, `triggers/AntsuranceCaseTrigger` |
| A claim cannot be paid beyond its reserve. | `objects/Case/validationRules/Paid_Within_Reserve` |
| Daily at 06:00, policies expiring within 45 days move to Pending Renewal and get a renewal sale. | `AntsuranceRenewalJob`, scheduled as "Antsurance renewals" |
| What a portal customer sends is filed by an internal user. | Platform event `Antsurance_Portal_Submission__e`, `triggers/AntsurancePortalSubmissionTrigger` |

The Case and Opportunity triggers act only on our record types, so a customer's own cases and
opportunities pass through untouched. `AntsuranceCoexistenceTest` proves it with a plain case and a
plain opportunity.

### Generators

The objects, fields, layouts, record pages, app, permission set and flows are written by Python
scripts in `scripts/`, so a change is one edit and a rerun, not hand-edited XML. The XML under
`force-app` is what deploys; keep the two in step by changing the script and regenerating.

```bash
python3 scripts/gen_model.py force-app/main/default scripts/gen_model_base.py   # objects, fields, permission set
python3 scripts/gen_pages.py force-app/main/default                            # layouts, record pages, app, profile
python3 scripts/gen_flows.py force-app/main/default                            # flows and their buttons
python3 scripts/gen_reports.py force-app/main/default                          # report types, reports, dashboards
```

`gen_model.py` writes `Antsurance_CRM` and grants it every class with an `@AuraEnabled` method and
every Visualforce page controller. Run it after adding either; do not edit the permission set by hand.

## What is here

All paths are under `force-app/main/default/`. Claude's features have their own table in the next section.

| Piece | Where | Notes |
|---|---|---|
| Org theme "Anthropic" | `brandingSets/`, `lightningExperienceThemes/`, `contentassets/Claude_Spark.asset` | SLDS 2 theme: clay accents, Claude spark logo, which is also the app's logo. Active through `settings/LightningExperience.settings-meta.xml`. |
| Home | `flexipages/Antsurance_Home_Page`, `aura/antsuranceHomeTemplate`, `lwc/antsuranceHomePage`, `lwc/antsuranceHome`, `lwc/antsuranceCockpit*`, `AntsuranceCockpitController` | A cockpit, and since 2026-10-04 the app's Home page, so every route to Home lands on it. A slim bar with the greeting and an Ask Claude box; six figures, three to a row, beside a line of how the loss ratio built that you read with the pointer (`lwc/antsuranceCockpitTrend`, see Reports and dashboards); Claude's briefing; a rail of things to keep an eye on; and a workspace of tabs (Claude's desk, My day, Claims, Renewals, Pipeline, Underwriting) whose rows open in place. It draws without waiting on Claude. |
| Record pages | `flexipages/*_Record_Page`, `layouts/` | Customer, contact, lead, policy, claim, service request, policy sale, quote, participant, coverage, endorsement and insured asset pages, assigned inside the Antsurance app, never as an org default, plus a File Note page. Each page lists its own header actions, which replaces the layout's: a standard button nobody lists is gone, and one Salesforce hides on some records (the portal login on a contact with no login) lets the next action slide out, so Delete is kept behind the arrow by the count of buttons showing. Edit and Clone open only the fields a page carries in its sections, so each page ends on a complete Details tab; the designed tabs come first. The header strips hold short values only; a long customer name is carried by the page's card, which names the policyholder (on a policy) or the customer (on a claim) in full, linked. The insured asset page shows a picture of the vehicle's own model generation (a table of freely licensed files in `AntsuranceAssetController`) and lists the policy's claims and people under it. |
| Shared controls | `lwc/antsuranceTabs`, `lwc/antsuranceAccordion`, `lwc/antsuranceCarousel`, `lwc/antsuranceStepPager`, `lwc/antsuranceUiMemory` | The one set of tabs, folding section, carousel and pager for the org. The rule they serve: at rest no component is taller than about one screen. Each works by keyboard, shows a count of what is behind it, and hides nothing from print. The portal has its own, in the same look. |
| Shared look | `lwc/antsuranceIcons`, `lwc/antsuranceUiStyles` | One icon and tint mapping, the hover, focus and pressed states, loading skeletons, and the one severity chip and "read by Claude" chip. |
| `antsuranceStatusPath` | `lwc/` | The status bar on claims, service requests, policy sales and leads. The button moves the record to its next step; clicking another step shows its guidance and turns the button into "Mark as" that step. On a lead's last open step it reads "Convert this lead". When the steps do not all fit it goes compact and never cuts a name. |
| `antsuranceRelatedList` | `lwc/` | Every related list on the record pages. It reads through the UI API as the user and draws with the page. Rows carry an icon and open on a click; long lists page; `mergeBy` joins rows that share a parent (a contact's policies show one row each with both roles). Configured per page in `scripts/gen_pages.py`. |
| Tasks tab | `tabs/Antsurance_Tasks`, `lwc/antsuranceTasks`, `AntsuranceTasksController` | My open tasks under Overdue, Today, This week and Later, one group open at a time with its count, six rows a page, tick to complete and New Task. |
| Summary cards | `lwc/antsuranceCustomerSummary`, `antsurancePolicySummary`, `antsurancePolicyCoverages`, `antsuranceCaseSummary`, `antsuranceContactSummary`, `antsuranceLeadSummary`, `antsuranceQuoteSummary`, `antsuranceQuoteBoard`, `antsuranceCoverageSummary`, `antsuranceParticipantSummary`, `antsuranceEndorsementSummary` | One designed card per record, none a restyle of another. The claim card states its severity tier and why, and says in a line where the reserve stands. A policy's coverages are grouped rows with a plain line, the limit and its basis, the deductible and its share of premium. |
| `antsurancePersonFile` | `lwc/`, `AntsurancePersonFileController` | Participant page: the person's policies and roles, the cases that name them, and who else is on the policy, behind three tabs. |
| `antsuranceAssetViewer` | `lwc/`, `AntsuranceAssetController` | Insured asset page: a photo of the vehicle model from Wikipedia, or a street map of the property from OpenStreetMap tiles, and an "Insured to value" bar where a limit and a value both exist. Every seeded home reads 100 percent. Needs the trusted sites in `cspTrustedSites/` and `remoteSiteSettings/Wikipedia`. |
| `antsuranceFileNotes` | `lwc/`, `AntsuranceNotesController`, `AntsuranceSalesforceNotes` | File notes timeline with a Markdown composer and "Draft with Claude". A long note folds and opens in place; four a page. A note saved from Claude's own analysis is marked as Claude's. Salesforce's own Notes on the record show in the same timeline, turned from their HTML into Markdown, with a link to open each in Notes; choosing the type "Salesforce note" in the composer saves a note there instead of as a file note. |
| `antsuranceDocuments` | `lwc/`, `AntsuranceFilesController` | Documents tab on a policy, sale and customer: the document picker and its three actions on one row, the top of the document as a preview, and the files saved on the record. See Documents below. |
| Quote configurator | `lwc/antsuranceQuoteConfigurator`, `antsuranceQuotePrice`, `antsuranceQuoteAnswers`, `AntsuranceQuoteConfigurator` | The Configuration tab on the quote page: guided questions with the price alongside, then the answers by section and how the premium was built. See below. |
| `antsuranceMarkdownField`, `antsuranceBrief`, `antsuranceMarkdown` | `lwc/` | A long-text field shown as a card of labeled points; the Markdown renderer has unit tests: `node --test force-app/main/default/lwc/antsuranceMarkdown/__tests__/markdown.test.mjs`. |
| `antsuranceFonts` | `lwc/`, `staticresources/antsuranceFonts/` | Loads Poppins (SIL Open Font License) for headings and figures. Everything else uses the Salesforce system font. |
| API credential | `namedCredentials/Anthropic_API`, `externalCredentials/Anthropic` | Sends the key as `x-api-key`. The key itself is not in source. |
| Model settings | `objects/Antsurance_AI_Setting__mdt`, `customMetadata/Antsurance_AI_Setting.Default`, `AntsuranceAiSettings` | The model, whether to ask for fast output, and the beta header are one record in Setup, not code. |
| Access | `permissionsets/Antsurance_CRM`, `Antsurance_Claude`, `Antsurance_Desk`, `Antsurance_Portal`; `profiles/` | Everything a person needs comes from the permission sets. `profiles/Admin` sets the default app, record types and layouts in this org only and never ships in the kit. `Antsurance Customer` is the portal's profile. |
| Customer portal | `networks/`, `sites/`, `digitalExperiences/`, `lwc/antsurancePortal*`, `classes/AntsurancePortal*` | See "The customer portal" below. |

## Claude at work

Claude is built into the work, not only the chat. Every call goes through the `Anthropic_API` Named
Credential; the key lives in the org's External Credential and nowhere in source. Nothing is written
without a click.

| Where | What Claude does | Code |
|---|---|---|
| Ask Claude tab and the utility bar on every record | Answers questions about the book or the open record by reading Salesforce as the user, and draws the answer in the shape that fits: a record card, figures, a chart, a work list, a draft, options side by side, a timeline, or a real record form filled in. It can propose a task, a file note or a status change. It reads attached photos and PDFs (below). | `AntsuranceClaudeController`, `AntsuranceClaudeDisplay`, `AntsuranceClaudeRecordFacts`, `AntsuranceClaudeActions`, `AntsuranceClaudeAttachments`, `lwc/antsuranceClaude*`. What the chat knows about this org's records sits behind one class: `AntsuranceClaudeModel` works in any org from its schema, and `AntsuranceClaudeInsurance` extends it for policies, claims and quotes. An org can name its own class in the AI setting's Chat Model Class. That seam is what lets the chat install alone. |
| File a Claim with Claude, on a customer or a policy | Turns a pasted email or call notes into a claim ready to review: which policy and why, date and type of loss, severity, an estimate, and what is still missing. | `AntsuranceClaimsAssistantIntake`, `lwc/antsuranceClaimIntake` |
| Coverage check, on a claim | Reads the loss against the policy as it stood on the date of loss and gives a verdict, the coverage that responds, the limit and deductible and what is payable, each finding linked to its record. It reasons from the policy record, not the form wording, and says so. The adjuster confirms it. | `AntsuranceClaimsAssistantCoverage`, `lwc/antsuranceCoverageCheck` |
| Claim brief, on a claim | Writes where the file stands, coverage, the money, what to watch and the next steps, behind five small tabs. Each step can become a task. It says when the claim has changed since it was written. | `AntsuranceClaimsAssistantBrief`, `lwc/antsuranceClaimBrief` |
| Photos, on a claim | Assesses the damage photos: what they show, whether it fits the reported loss, a repair range, and a numbered box over each piece of damage. A person can mark their own areas and ask about them. See "Photos and boxes" below. | `AntsuranceClaimsAssistantPhotos`, `AntsuranceClaimsAssistantFocus`, `lwc/antsuranceClaimPhotos`, `antsuranceClaimPhotoViewer`, `antsuranceImageMarker` |
| Documents, on a claim | Reads an attached PDF or photo (an invoice, an estimate, a police report), compares it with the reserve and estimate, and suggests changes that apply only after you confirm. | `AntsuranceClaimsAssistantDocuments`, `lwc/antsuranceClaimDocuments` |
| Analysis tab, on a claim | One button works through every piece of evidence step by step (photos, a video read from six frames, PDFs, the coverage check) and writes one adjuster's report: a headline and three figures always in view, with Summary, Evidence, Damage, Coverage, Flags, Reserve and Next steps behind tabs. Print shows every section. Three actions wait for Confirm: add next steps as tasks, set the reserve, add the report to file notes. "Add evidence" takes photos, videos and documents into the claim's Salesforce Files and a file note into its notes, from the tab itself; a Salesforce note on the claim is read as a note, not listed as a document. | `AntsuranceClaimsAssistantAnalysis`, `lwc/antsuranceClaimAnalysis`, `antsuranceClaimAnalysisReport` |
| Underwriting review, on a referred quote | Shows why the quote was referred, drafts a memo for the underwriter, and records the decision. | `AntsuranceUnderwritingController`, `lwc/antsuranceUnderwritingReview` |
| Renewal outreach, on a policy pending renewal | Says what the renewal costs and drafts what to say. Nothing is sent or stored. | `AntsuranceRenewalOutreachController`, `lwc/antsuranceRenewalOutreach` |
| Claude suggests, in the quote questions | Up to three changes the seller could make after each step, repriced exactly by the configurator. | `AntsuranceQuoteAdvisor`, `lwc/antsuranceQuotePrice` |
| Home briefing | One headline, the things to do first with the record each is about, and a few to keep an eye on. Stored on the user so Home opens with it. | `AntsuranceCockpitController`, `lwc/antsuranceCockpitBriefing` |
| Claude's desk, on Home | "Run Claude's shift" prepares routine work one piece at a time (briefs, renewal notes, memos, reserve reviews, quote follow-ups), each with Approve, Edit or Dismiss. "What Claude may do" sets each kind of work to done and reported, prepared for approval, or off; money and anything sent to a customer always waits for a person. The nightly job exists and is not scheduled, on purpose. | `AntsuranceDeskController`, `AntsuranceDeskShift`, `lwc/antsuranceDesk`, `antsuranceDeskAutonomy`, `objects/Claude_Work__c`, `Claude_Autonomy__c` |
| File notes | Drafts a note from a few words. | `AntsuranceNotesController` |
| Coverage agent, on a claim's coverage check | The one job that runs as an agent on a harness, Claude Managed Agents: Anthropic runs the loop, and the agent's tools run in Salesforce as the signed-in user. It works the coverage question step by step over the notes, documents, photos and earlier claims, shows each step, and leaves a finding for the adjuster to confirm. Each run is capped at one dollar. | `AntsuranceCoverageAgent`, `AntsuranceCoverageAgentApi`, `AntsuranceCoverageAgentTools`, `AntsuranceCoverageAgentSetup`, `lwc/antsuranceCoverageAgent`, `objects/Antsurance_Coverage_Agent__c`, `staticresources/antsuranceCoverageSkill` |
| Letters, under a claim's documents | Drafts the acknowledgment, the coverage position or reservation of rights, and the notice to the other carrier. The adjuster edits and approves; approval saves a branded PDF and a file note. Nothing is sent, and there is no denial letter by design. | `AntsuranceClaimLetters`, `AntsuranceClaimLetterController`, `lwc/antsuranceClaimLetters`, `pages/AntsuranceClaimLetter` |
| Read a submission, on a policy sale or a lead | Reads a broker's email, application and loss runs (up to four PDFs or photos), fills the quote's answers with the page each came from, checks them against the referral rules, lists what is missing or disagrees, and drafts the reply to the broker. Nothing is stored until the person saves the quote. | `AntsuranceSubmissionIntake`, `lwc/antsuranceSubmissionIntake`, `lwc/antsuranceSubmissionHandover` |
| Event response, the Events tab | A storm's footprint over a map of insured locations: what is inside it, the insured value under a coverage that responds, claims already in, and on request Claude's plan of who to call first with the outreach drafted. The events are sample records in Setup. | `AntsuranceEventController`, `AntsuranceEventGeometry`, `lwc/antsuranceEvents`, `lwc/antsuranceEventMap`, `objects/Antsurance_Event__mdt` |
| Claude at Work, a tab | Not a feature of its own: one page listing the nine jobs Claude does here, how each runs (a single call, a pipeline, a tool loop, or the one agent on a harness), what it may do alone, what it did today and how it scored when tested. Each job opens with how it is started and a button that goes to a record to try it on (an open claim, a customer with a policy in force, the policy nearest renewal, a referred quote), picked as the person looking. | `AntsuranceAgentsController`, `lwc/antsuranceAgents`, `objects/Antsurance_Agent_Eval__mdt` |
| The customer portal | Answers a signed-in customer from their own records, takes them to a page, fills a form for them to send, explains a quote question, and checks each claim photo. | `AntsurancePortalClaude`, `AntsurancePortalQuote`, `AntsurancePortalPhotos` |

`AntsuranceAiClient` is the shared helper for the single-answer calls. It builds answer schemas as
text (Apex reorders map keys, and a reordered schema makes Claude return empty fields), accounts for
Salesforce's 120 seconds of callout time, reads the model from `Antsurance_AI_Setting__mdt`, and adds
"Write in American English." to every caller's instructions.

### One rule for a reserve

A reserve is what the insurer expects to pay. It is compared with the payable amount (the estimate
less the deductible, capped at the limit), never with the gross estimate, and a recommendation to
change it shows its sum. The rule and its arithmetic are in `AntsuranceClaimRules`; the brief, the
coverage check, the analysis, the document reader and the Home briefing all include it and are
handed a worked `PAYABLE:` line. The desk's reserve review follows the same rule from its own copy
of the text in `AntsuranceDeskShift`. A brief or analysis stored before 2026-10-04 may still
disagree until it is run again. The rule also covers a cost that comes in above the estimate: it is
measured against the estimate, with the deductible taken off once. On claim 00002566 every card now
agrees (documents total $48,921, $46,421 payable, the $45,000 reserve $1,421 short); that claim's
estimate was changed from $47,500 to match its documents on 2026-10-04. It was decided on 2026-10-05
to keep it. The seed keeps $47,500 as the first estimate and `scripts/prepare_demo.sh` raises it.

### Photos and boxes

Claude returns a box for each piece of damage and the viewer draws it. Boxes are stored as fractions
of the image; Claude is asked for them in pixels with the photo's size given, because that measured
better. A finding with no single place has no box. A person can draw, move and resize their own
areas by mouse or keyboard, add a note, and ask Claude about just those areas; Claude's boxes can be
nudged or dismissed and the change is kept as the person's.

| Eval on 12 photos, 16 true boxes | Fractions (before) | Pixels (shipped) |
|---|---|---|
| Mean overlap with the true damage | 0.59 | 0.69 |
| Boxes overlapping at least half | 62% | 81% |
| Damage missed | 3 | 0 |
| Boxes on the two photos with no damage | 0 | 0 |

Two caveats: the true boxes were drawn by eye by the worker who ran the eval, and each method ran
once on twelve photos, so a few hundredths is noise. Boxes are tight where damage has an edge and
loose where it is spread out (shingles, a ceiling stain), and they vary from run to run. The eval is
in `scripts/eval/boxes/`. The claim analysis reads a marked area only when Claude found damage in it.

### Attachments in the chat

The chat takes photos and PDFs by the paperclip, paste, drop, or "Use this claim's files".

| Limit | Value |
|---|---|
| Files on one message | 4 |
| A photo, after the browser redraws it at 1,568 pixels | 600 KB |
| A PDF | 900 KB |
| All files on one message | 1.2 MB |

The latest message's files travel with each later turn; earlier ones are named and Claude asks for
them again. Nothing is stored in the org. The caps are what they are because the 6 MB heap holds each
file twice. The real file picker, a drag from the desktop and the
over-1.2 MB refusal were not seen in the browser.

### How well it works

| Feature | Measured | Where |
|---|---|---|
| Chat | 84 of 84 questions with answers computed from the org at run time. Not rerun since the prompt changed on 2026-10-04. | `scripts/eval/README.md` |
| Claim intake | 36 of 36 over two runs of 18 hand-written messages. | `scripts/eval/claims/` |
| Photo assessment | 8 of 9 cases, with the miss fixed and confirmed in the browser. Not rerun since the box prompt changed. | `scripts/eval/photos/` |
| Boxes | The table above. | `scripts/eval/boxes/` |
| Quote suggestions | 9 of 9 cases. | `scripts/eval/advisor/` |
| Read a submission | 13 of 13 quote answers on three runs of one sample submission, with the planted disagreement caught each time. | `scripts/eval/submission/` |

The sets are small and each was written by one person, so they show the features are reliable on
demo-style input, not on a carrier's real inbox.

## The customer portal

A signed-in customer sees only their own household at
`https://<your-site-domain>/portal`. It is an LWR Experience Cloud site
whose one page holds one component, `antsurancePortalApp`, which routes by name.

| A customer can | How |
|---|---|
| See their policies, claims and requests | Home, lists that page five at a time, and a page for each. A policy opens on what it is and what it costs, with Covered, People and property, Changes, Documents, Your bill and Good to know behind tabs. |
| Ask Claude | Claude answers from their records in one or two sentences plus a block drawn for the answer: choices to press when it needs one fact ("which bill?"), a list of policies, a price receipt, a renewal, a claim's status, a coverage, a note. Claude names only the kind of block and the records; the server builds each block from that customer's own records and drops anything that is not theirs, so no figure comes from Claude. It also goes to a page, fills a form and points at fields; each filled field is marked and editable. Claude never sends anything. "New chat" starts the conversation over and leaves a form as it is. |
| Send a request or a claim | Add a driver, ask for a change, file a claim. A claim takes up to five photos, redrawn in the browser; Claude says in a line whether each is usable and what is still missing. |
| Get a quote | Renters, auto, home or umbrella. Answers the org holds are filled in, the price follows every answer through `AntsuranceQuoteConfigurator.price`, and "What does this mean?" has Claude explain a question. The sent quote arrives internally as a draft on a policy sale. |
| Get their documents and see their bill | The declarations page (and ID cards on auto) as a copy shared with that customer only. The bill is worked out from the policy's fields and says what the org does not hold. |

| How it is built | |
|---|---|
| Access | Profile `Antsurance Customer` (Customer Community license) and permission set `Antsurance_Portal`. No object or field access: every read and write goes through the portal's Apex, which works out the customer from the running user and checks that any record it is handed belongs to them. |
| What is public | The sign-in page only. No self-registration and nothing for the guest user. |
| Submissions | The portal checks the form and publishes `Antsurance_Portal_Submission__e`; the trigger files it as an internal user, because the case automation cannot run as a portal user. That user must be a member of the site and hold `Antsurance_CRM`. |
| Tests | 17, run as two portal users: another household's policy, claim, request, quote, photo and document are refused. `AntsurancePortalControllerTest` and `AntsurancePortalNextTest`. |
| After a deploy | Publish, or the live site keeps the old code: `sf api request rest "/services/data/v64.0/connect/communities/<site-id>/publish" --method POST --body '{}' --target-org "$SF_TARGET_ORG"` |
| Sign in as the sample customer | Never with a password. On Maria Reyes's contact (Reyes Household), in the Lightning app, press "Log in to Experience as User", the button on her contact page. `scripts/portal_user.apex` recreates the portal user and prints a direct link. |

Not checked: ID cards printed live, the bill for a policy that is behind, the forgot-password page
(still stock), and a real phone. 

## Documents

Four branded PDFs print from live records. The Documents tab on a policy or a policy sale shows a
picker, the three actions (Save to Files, Download, Open in New Tab) on the same row, the top of the
chosen document, and the files saved on the record. A table that fits on a page is never cut across two.

| Document | Applies to |
|---|---|
| Declarations | Every policy |
| Auto ID cards | Auto policies, two wallet-size cards per vehicle |
| Certificate of insurance | A commercial customer's liability policies in force, made out to a named holder. An original layout, not the ACORD form. |
| Quote proposal | A policy sale with at least one quote: the options side by side and what the customer told us |

```bash
python3 scripts/render_documents.py /tmp/out "dec|AntsuranceDecPage|SELECT Id FROM Policy__c WHERE Name = 'ANT-PA-204517'"
```

That renders a document to PNG pages for checking. The PDF renderer forces its own layout rules (see the Visualforce notes in `../CLAUDE.md`).

## Org state that is not in source

These live only in the org. Redo them by hand in a new org, or expect them when working in this one.

| What | Detail |
|---|---|
| The API key | In the External Credential. See below. |
| Standard field labels | Setup, Rename Tabs and Labels: Account Name is Customer Name, Account Owner is Customer Owner, Billing Address is Address, Billing City is City; on Case, Case Number is Number, Case Origin is Channel, Case Owner is Owner, and (under Other Labels) Case Record Type is Record Type; Opportunity Name is Policy Sale Name, Opportunity Owner is Sale Owner; on Lead, Company is Household or Business. The object and tab names are in `objectTranslations/`. |
| Pinned default lists, per user | All Customers, All Contacts, All Policies, Open Claims, Open Policy Sales, Open Quotes, Open Leads. On Contacts and Leads, press List View once to leave the intelligence view. The pin only registers once the list has finished loading. |
| The demo user's time zone | Central, so chat and dashboard times agree. |
| Stock list views removed | On 2026-10-05, 22 of Salesforce's sample list views were deleted from this org (New Last Week, New This Week, Platinum and Gold SLA Customers, Birthdays This Month, Bulk SMS Contacts, the My views on customers, contacts and policy sales, All Closed Cases, four on leads, Closing This and Next Month, Opportunity Pipeline, Private, Won). A new org has them again; the kit never deletes anything of a customer's. All Quotes and My Quotes stay: the first is the only list of every quote, and the second could not be addressed for deletion. |
| Salesforce Notes | Turned on in Setup (Notes Settings) on 2026-10-05, so a claim's own Salesforce notes can be written and show in the File Notes timeline. The project compiles with Notes off; it then reads no Salesforce notes and does not offer to save one. |
| Digital Experiences | On, which cannot be turned off. The site is published. |
| The account owner's user | Has the role CEO, which the owner of a portal account must have. |
| The portal user | `maria.reyes@portal.antsurance.demo` on Maria Reyes's contact. It uses 1 of 5 Customer Community licenses. |
| Dev Hub | On since 2026-10-04, which cannot be turned off. Pass `--target-dev-hub "$SF_TARGET_ORG"` on the command. Scratch org `antsurance-kit-2` is alive until 2026-10-06. |
| The renewal job | Scheduled as "Antsurance renewals". It blocks a deploy of the whole project. |
| Records today's work left | Stored analyses, a sample video and marked areas. The sedan photo on claim 00002562, a Honda CR-V claim, is there on purpose: it was kept on 2026-10-05 as the moment where Claude catches a photo that does not fit, and it is now one of the sample photos. |

## Limits to plan around

| Limit | What it means here |
|---|---|
| Data storage, 5 MB | About 2,500 records, and the kit's analyzer read about 1 MB free on 2026-10-04. A demo that files claims and quotes uses it up. See the next section. |
| File storage, 20 MB | Separate from data. Sample photos, a video, printed copies and saved PDFs were added on 2026-10-04 and the figure was not measured afterwards: check with `sf org list limits --target-org "$SF_TARGET_ORG"`. |
| API calls, 15,000 in any rolling 24 hours | Every `sf` command spends several. Past the limit the CLI fails with `REQUEST_LIMIT_EXCEEDED` for hours while the browser keeps working. Deploy with `--async` and check once. |
| Callout time, 120 seconds a request | One Claude call per Apex request; long jobs run step by step from the page. |
| A full deploy | Fails while the renewal job is scheduled. Deploy changed folders and classes by name. |
| A data reload | Must deactivate the portal user first (see Demo data). |
| Scratch orgs | 3 active and 6 a day from this Dev Hub. |
| Dashboards that run as the viewer | Three in a Developer Edition org. Ours use exactly three. |

## Storage budget

The demo data loads about 2,120 records and a test (`theLoadLeavesTheOrgRoomToWork`) fails above
2,150, which leaves a few hundred records of room for what a demo creates. If inserts start failing
with `STORAGE_LIMIT_EXCEEDED`, the data needs a reload, which is for the org's administrator to decide.

## Reports and dashboards

67 reports in six folders and six dashboards in three folders, on ten custom report types, all written
by `scripts/gen_reports.py`. 

| Dashboard folder | Dashboard | What it answers |
|---|---|---|
| Leadership | Executive Overview | Premium in force, loss ratio by line, the shape of the book, claims exposure, the pipeline and what renews next. |
| Underwriting and Sales | Book of Business | Premium by line, agency and status, coverage mix, insured values and driver risk. |
| Underwriting and Sales | Sales Pipeline and Quotes | The open pipeline, quotes waiting on an answer, win rate and where leads come from. |
| Underwriting and Sales | Renewals and Retention | What is up for renewal, how renewals are progressing, and premium at risk or lost. |
| Claims and Service | Claims Operations | Open claims by status, severity, age band and adjuster, what is reserved and paid, and the large open claims. |
| Claims and Service | Service and Operations | Open requests by type and age, how work arrives, and tasks due or overdue. |

```bash
python3 scripts/gen_reports.py force-app/main/default
sf project deploy start --source-dir force-app/main/default/reportTypes --target-org "$SF_TARGET_ORG"
sf project deploy start --source-dir force-app/main/default/reports --target-org "$SF_TARGET_ORG"
sf project deploy start --source-dir force-app/main/default/dashboards --target-org "$SF_TARGET_ORG"
```

Deploy in that order. A dashboard shows stored results, so after deploying one or reloading the data,
open it and press Refresh (the first click only focuses the button; press it twice). Three dashboards
run as the person viewing, because they are working queues: Claims Operations, Service and Operations,
Sales Pipeline and Quotes. The three views of the whole book run as one named user: Executive
Overview, Book of Business, Renewals and Retention. Pass a different username as the script's second
argument in another org.

On 2026-10-04 Home and the Executive Overview both showed a 63 percent loss ratio. The personal lines
run higher, because the hand-written claim stories sit on a small book.

Home's loss ratio line is a running total, not a stored history: the org keeps no daily snapshots.
For each of the last 366 days `AntsuranceCockpitController.loadLossTrend` adds up what had been
incurred by that day, by date of loss and at today's reserves, on the policies in force today. The
page divides each day by today's premium in force, so the last day is the loss ratio figure beside
it and the line only ever climbs. Policies that have since expired, and their claims, are not in it.
Because the demo claims are dated in the months before the load, with the large open reserves in
the last few weeks, the line sits near zero and climbs steeply at the end. A line that looks like a
carrier's year needs older closed claims in the seed, which means a data reload.

## The quote configurator

`AntsuranceQuoteConfigurator` holds the questions and the rating for eight lines of business:
Personal Auto, Homeowners, Renters, Umbrella, General Liability, Commercial Property, Workers
Compensation and Commercial Auto. The questions are rows in `QUESTION_ROWS`, one list per line:

| Row | Meaning |
|---|---|
| `S\|key\|title\|intro` | A section, which is one step of the guided flow. |
| `Q\|key\|label\|type\|default\|how to ask it\|role\|showWhen` | A question. Type is `choice`, `toggle`, `number`, `currency` or `text`. Role `limit` or `deductible` feeds that field on the quote; `exposure` is the amount or count the base rate is built on. `showWhen` is `otherKey=value,value`. |
| `O\|value\|label\|effect\|referral reason` | A choice. Effect `x1.15` multiplies the premium, `+45` adds dollars. A referral reason flags the quote for underwriting review. |

A premium is the line's base rate (per vehicle, per $1,000 insured, per $100 of payroll and so on,
in `baseRate`), times each chosen multiplier, plus each add-on, times a territory and tier factor.
The price is always worked out on the server: as answers change for the live figure, and again on
save. Pricing a saved quote again gives the same premium to the dollar; two tests price every stored
configuration again to hold that. A quote that is Accepted, Bound, Declined or Expired is locked.

To add a question or change a rate, edit the rows; no component changes are needed. The portal's
guided quote uses the same pricing code.

## How the chat reads Salesforce data

Claude is given one tool, `query_salesforce`, which takes a SOQL `SELECT`. Apex runs it with
`AccessLevel.USER_MODE`, so object access, field-level security and sharing apply exactly as they do
for the person asking, then returns the rows to Claude. Nothing other than a single `SELECT` is
accepted, and results are capped at 50 rows and 20,000 characters.

Each call to `sendMessage` is one step: either Claude's answer or one round of lookups. The chat
calls again after a lookup (up to four rounds), which lets it show what was read while the answer
is written and gives each step its own Apex limits. `DATA_MODEL` in `AntsuranceClaudeController` is
the note that teaches Claude the objects and fields; update it when the model changes.

When a record is open, the chat prefixes the question with a short page-context note naming that
record, so "summarize this claim" works from the utility bar on any object.

### Models and speed

The default model, whether to ask for fast output, and the beta header come from the `Default`
record of `Antsurance_AI_Setting__mdt`, so another org changes one record in Setup, not code. This
org ships `claude-opus-5-5` with fast mode on. The chat's model menu is the `MODELS` list in
`AntsuranceClaudeController`; a configured model that is not in the list is offered first, and the
choice is remembered per browser. A rate-limited fast request is retried once at standard speed.

Measured on 2026-10-02 for a question that needs one lookup: Opus 5.5 with fast mode 3.9s,
Sonnet 5.5 5.9s, Opus 5.5 without fast mode 9.0s.

## Deploy

```bash
# Deploy what changed, by path, and check once. Never poll: polling spends the org's API allowance.
sf project deploy start --source-dir force-app/main/default/lwc/<bundle> --source-dir force-app/main/default/classes/<Class>.cls \
  --target-org "$SF_TARGET_ORG" --test-level RunSpecifiedTests --tests <ClassTest> --async
sf project deploy report --job-id <id> --target-org "$SF_TARGET_ORG"   # once, a few minutes later
sf org assign permset --name Antsurance_Claude --name Antsurance_CRM --name Antsurance_Desk --target-org "$SF_TARGET_ORG"
```

Deploying the whole project fails while the renewal job is scheduled ("This schedulable class has
jobs pending"). Publish the portal after deploying one of its components. The Salesforce plugin's
hook refuses a raw `sf` command until the matching skill has been invoked in the session; `../CLAUDE.md`
lists which.

There are 47 test classes. A full local run passed 331 of 331 on 2026-10-04 before that day's later
work landed; the count has grown since. The data tests load the whole book several times, so allow
about ten minutes.

In a new org, also load the demo data and schedule the renewal job from Anonymous Apex:
`System.schedule('Antsurance renewals', '0 0 6 * * ?', new AntsuranceRenewalJob());`

## Set or rotate the API key

The key lives in the External Credential's `ApiUser` principal, parameter `ApiKey`. Set it in Setup
(Named Credentials, External Credentials, Anthropic, ApiUser, Edit) or with the Connect REST API
(`POST` to create, `PUT` to replace). Never put the key in a file or in chat.

```bash
sf api request rest /services/data/v67.0/named-credentials/credential --method PUT --target-org "$SF_TARGET_ORG" --body '{
  "externalCredential": "Anthropic", "principalName": "ApiUser", "principalType": "NamedPrincipal",
  "authenticationProtocol": "Custom", "credentials": {"ApiKey": {"value": "<key>", "encrypted": true}}}'
```

`kit/scripts/setup/set_api_key.py` does the same from a hidden prompt.

## Design rules for anything added here

| Rule | Detail |
|---|---|
| Type | Headings and figures in Poppins, everything else in the Salesforce system font, on one size scale. No serif and no monospace. |
| Emphasis | Cards are white or cream with a clay edge, never a dark fill or a glow. A chip always carries its word. |
| Height | At rest no component is taller than about one screen. Use the shared tabs, accordion, pager and carousel. |
| Text | Bold lead-ins sit on their own line. Buttons never wrap; the text beside them gives way. No name, date or amount splits across lines. `text-wrap: balance` on headings only. |
| Spelling | American, in everything a person reads and in what Claude writes. "Cancelled" stays where it is a stored status value. |
| Each card | Its own design, with icons and states from `antsuranceIcons` and `antsuranceUiStyles`. |


## Checking changes in the browser

Lightning caches component code and page layouts in the browser. After a deploy, a normal reload can
show the old version. Clear the site's IndexedDB (DevTools, Application, Storage, Clear site data)
and reload before judging a change.

| Check | How |
|---|---|
| A page when narrow, internal org | In your own tab set `document.body.style.width = '1024px'`, wait a second, run `scripts/ui_checks/narrow_check.js`, set the width back to `''`. Page zoom does not narrow a Lightning page. |
| A page when narrow, portal | The other way round: `document.documentElement.style.zoom = '1.5'` narrows it and the body's width does not. Phone layouts need a 360 pixel same-origin frame, because zoom does not trip media queries. |
| What the check finds | Button labels that wrapped, text cut off by its box, text spilling into a neighbor, and text running off its card, by component. |
| Spelling | `python3 scripts/ui_checks/us_spelling.py` must pass. The kit build runs it too. |
| Never | Resize the browser window. It is the user's window and every agent shares it. |

Two agents reported the narrow check clean while their screenshots still showed the page at full
width, so treat a clean narrow result as the check's word until a person has dragged the window.
