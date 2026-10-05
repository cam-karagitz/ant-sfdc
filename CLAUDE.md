# Salesforce development workshop

The type-first workshop for Salesforce platform work (Apex, LWC, Flow, metadata, Agentforce). Root placement rules in `../CLAUDE.md` still apply: a customer-specific Salesforce project goes in a subfolder here named for the customer; anything reusable is branded Antsurance.

## Skills

Everything here is scoped to this folder. There are 250 Salesforce skills from two sources, both built from [forcedotcom/sf-skills](https://github.com/forcedotcom/sf-skills).

- **The `salesforce-development` plugin** (37 skills, invoked as `salesforce-development:<name>`). Enabled in `.claude/settings.json`. It also brings a session-start hook that detects the SFDX project and default org, a gate on `sf project deploy` and `sf project delete` that checks the target org and blocks unconfirmed production deploys, an Apex and SOQL language server exposed as MCP tools, and `/salesforce-development:*` commands (`setup`, `status`, `org`, `login`, `discover`).
- **Vendored skills** (213, invoked by bare name) in `.claude/skills/`, at the commit recorded in `.claude/sf-skills.lock.json`. This is every upstream skill the plugin does not already provide.

Rules:

- **Never hand-edit a vendored skill.** `scripts/sync_sf_skills.py` replaces each one wholesale on the next sync. To change behavior, add your own skill under a new directory name; the sync leaves directories it did not create alone.
- **Update:** `scripts/sync_sf_skills.py` (latest `main`), `--ref 1.58.0` to pin a release, `--dry-run` to preview. Upstream renames and removes skills between releases, so review `git diff --stat` after a sync. Re-run it after installing, updating or removing a plugin: it skips whatever an enabled plugin provides, so no skill is listed twice.
- **Tiers:** the skill listing has a small character budget, and 250 descriptions are many times over it. The vendored skills in `scripts/sf-skills-core.txt` stay eligible for a description; the rest are pinned to `name-only` in `.claude/settings.local.json` (`skillOverrides`) so they never crowd the core set out. A name-only skill still works: invoke it by name. Promote or demote one with `/skills`, or edit the core file and run the sync with `--reset-tiers`. Plugin skills cannot be pinned this way; they compete for the budget like any other skill.
- **Disclosure is progressive either way.** The listing (name, plus description when shown) is level one. A skill's `SKILL.md` body loads only when the skill is invoked, and its `references/`, `assets/` and `scripts/` only when that body points to them.

### Which skill for which job

Always load the matching skill before writing Salesforce code or metadata, including when its description is not shown. Names starting `sd:` below are plugin skills; write the prefix out as `salesforce-development:`.

| Job | Skills |
|---|---|
| New SFDX project, environment check | `sd:dx-project-create`, `sd:platform-environment-validate`, `sd:platform-capability-search` |
| Apex classes, triggers, tests, logs | `sd:platform-apex-generate`, `sd:platform-apex-test-generate`, `sd:platform-apex-test-run`, `sd:platform-apex-logs-debug`, `sd:platform-apex-anonymous-run` |
| SOQL and record data | `sd:platform-soql-query`, `platform-data-manage` |
| Objects, fields, schema | `sd:platform-custom-object-generate`, `sd:platform-custom-field-generate`, `sd:platform-validation-rule-generate`, `sd:platform-value-set-generate`, `platform-custom-metadata-type-generate`, `platform-custom-setting-generate` |
| Apps, tabs, pages, list views, reports | `sd:platform-custom-application-generate`, `sd:platform-custom-tab-generate`, `sd:platform-flexipage-generate`, `sd:platform-list-view-generate`, `sd:platform-lightning-app-coordinate`, `sd:platform-report-generate`, `sd:platform-custom-report-type-generate` |
| Permissions and sharing | `sd:platform-permission-set-generate`, `sd:platform-sharing-rules-generate`, `sd:platform-sharing-owd-configure`, `dx-org-permission-set-assign` |
| Flow | `sd:automation-flow-generate` |
| LWC | `experience-lwc-generate`, `experience-lwc-design-generate`, `experience-lwc-base-components-integrate`, `experience-lwc-security-validate`, `experience-lwc-accessibility-jest-run`, `experience-lwc-runtime-observe` |
| Lightning Data Service, GraphQL, SLDS | `experience-lds-best-practices-apply`, `experience-lds-graphql-generate`, `experience-lds-data-requirements-generate`, `design-systems-slds-apply`, `design-systems-slds-validate` |
| Deploy and retrieve | `sd:platform-metadata-deploy`, `sd:platform-metadata-retrieve`, `sd:platform-deploy-validate`, `sd:platform-quick-deploy`, `sd:platform-destructive-deploy`, `sd:platform-manifest-generate` |
| Orgs: scratch, sandbox, Dev Hub, trial | `sd:dx-org-manage`, `dx-org-switch`, `dx-org-analyze`, `dx-org-devhub-configure`, `platform-sandbox-configure`, `platform-trial-org-create` |
| API and docs lookup | `sd:platform-metadata-api-context-get`, `sd:platform-lsp-integrate`, `platform-data-and-tooling-api-context-get`, `platform-docs-get` |
| Static analysis, architecture review | `sd:dx-code-analyzer-configure`, `sd:dx-code-analyzer-run`, `sd:dx-code-analyzer-custom-rule-create`, `sd:platform-architecture-analyze`, `dx-apexguru-scan` |
| Agentforce agents | `agentforce-generate`, `agentforce-test`, `agentforce-observe`, `agentforce-architecture-analyze` |
| Integration | `integration-connectivity-generate`, `integration-connectivity-connected-app-configure`, `integration-eventing-cdc-configure` |
| Diagrams | `external-diagram-mermaid-generate` |

Name-only families, by prefix: `service-` (Omni-Channel, ITSM, digital engagement, voice), `field-service-`, `omnistudio-`, `experience-ui-bundle-` and `experience-cms-` (React UI bundles, CMS), `dx-devops-` (DevOps Center), `consumer-goods-`, `education-cloud-`, `life-sciences-`, `commerce-b2b-`, `mobile-`, `sales-`, `data360-`. Run `ls .claude/skills | grep '^<prefix>'` to find the one you need.

## Working against orgs

- The skills drive the Salesforce CLI (`sf`, installed globally with npm). If `sf --version` fails, stop and say so rather than working around it. Code Analyzer's PMD and SFGE engines also need a Java runtime, which this machine does not have.
- **First run: make sure `SF_TARGET_ORG` is set before any org work.** No org alias is committed. At the start of a session here, check `echo "${SF_TARGET_ORG:-unset}"`. If it is unset, do not guess and do not fall back to the CLI's global default: ask the user which org alias to use (offer the authorized ones, listed with the `salesforce-development:dx-org-switch` skill, and say if none is authorized yet so they can log in first). Then save the answer by merging `"SF_TARGET_ORG": "<alias>"` into the `env` block of `.claude/settings.local.json` (create the file if missing, keep every other key such as `skillOverrides`; it is gitignored), and tell the user to restart the session so it takes effect. For the current session, pass `--target-org <alias>` explicitly. Scripts exit with a message when it is unset. The org is the Antsurance demo org, a Developer Edition org.
- The Bash sandbox blocks the org's `*.my.salesforce.com` host. An `sf` command that talks to the org fails inside the sandbox with "Host is not in the sandbox host allowlist"; rerun it outside the sandbox rather than treating it as an auth problem.
- The demo org is also a Dev Hub (turned on 2026-10-04, which cannot be undone): 3 active scratch orgs, 6 a day. Pass `--target-dev-hub "$SF_TARGET_ORG"` on the command; do not set a global default. The vendored `dx-org-devhub-configure` helper reads status and allocation fine but its `--enable` deploys at API 47.0, where the setting is not valid; a one-file `DevHubSettings` deploy at the project's API version is what worked.
- The `salesforce-development` plugin's hook refuses a raw `sf` command until the matching skill has been invoked in the session ("Skills-first enforcement"): `platform-metadata-deploy` before deploys, `platform-soql-query` before queries, `platform-apex-test-run` before tests, `platform-apex-anonymous-run` before anonymous Apex, `dx-org-manage` before scratch org commands. It also interrupts now and then to propose plugins; install none (the vendored skills here already cover them) and run the command again. Tell every subagent both things.
- Work here targets demo, scratch, Developer Edition or sandbox orgs. Say which org alias you are targeting before any deploy or data change, and deploy to a production org only when asked to in that message. The plugin's deploy gate enforces the same thing; do not bypass it.
- About 36 vendored skills (mostly `service-omni-*`) declare `allowed-tools: Bash`, which pre-approves shell commands while that skill is active. Keep reading the commands they run against an org.

## Building or changing the Antsurance org: start here

`antsurance/` is the whole org as source. A session that has to build it, change it or hand it on reads these, in this order:

1. `antsurance/README.md`: what the org is, the data model, every feature and where its code is, and the limits to plan around.
2. The gotchas below: platform traps already paid for.

How the org is made:

| Layer | Made by | Change it by |
|---|---|---|
| Objects, fields, permission sets | `antsurance/scripts/gen_model.py` | Editing the script and rerunning it, never the XML |
| Layouts, record pages, the app, tabs | `antsurance/scripts/gen_pages.py` | The same |
| Screen flows and their buttons | `antsurance/scripts/gen_flows.py` | The same |
| Reports and dashboards | `antsurance/scripts/gen_reports.py` | The same |
| Apex and Lightning components | Written by hand under `antsurance/force-app/main/default/` | Editing them, with a test for every class (75 percent coverage or more, each) |
| Claude's features | One shared helper, `AntsuranceAiClient`, and one class per feature | See "Claude at work" in the README |
| Demo records | `AntsuranceDemoData` | Only when the person running the org asks for a reload |

Deploy by path with the tests named, check once, then follow `.claude/skills/verify/SKILL.md`. To put the app into anyone else's org, build the kit (`python3 -I antsurance/scripts/build_kit.py`) and work from `antsurance/dist/antsurance-kit`, whose own `CLAUDE.md` covers the menu of what can be installed (the data model, automations, components, pages, the portal, Ask Claude alone, or everything, each bringing what it needs), the preflight for an org that already holds things, that org's naming conventions, taking a part out again, and fitting a part to an org's own objects with the adapter. What each part contains is data (`antsurance/scripts/kit_capabilities.json`) and the build proves each set stands alone, so a new class, component or field lands in a part without anyone listing it; when a build fails that check, the message says which file reaches outside its part.

## Projects and gotchas

- `antsurance/` is the SFDX project for the the demo org demo org (theme, Home page, Claude chat). Read its `README.md` first.
- Prefix every custom CSS class in an LWC with `c-`. Unprefixed names such as `.stage` collide with Salesforce's own global styles, which still reach into components.
- A `List<SObject>` also passes `instanceof SObject` in Apex. Test for the list first.
- After deploying LWC or FlexiPage changes, clear the site's IndexedDB in the browser before checking them. A reload alone can show the previous version, including a stale page layout and nav bar.
- In an SLDS 2 theme, `BRAND_COLOR` alone leaves links, the active tab and buttons blue. Set `ACCENT_COLOR_*`, `CONTAINER_ACCENT_COLOR_*` and `ACCENT_CONTAINER_CONTENT_COLOR_*` on the BrandingSet.
- `@salesforce-ux/slds-linter` and one dependency of `@salesforce/sfdx-lwc-jest` could not be installed in the environment this was built in, so neither the SLDS linter nor LWC Jest was run. Verify components in the browser and cover logic with Apex tests.
- A Lightning App Page always shows a header with the tab's icon and label. To drop it, point the tab at an LWC (`lwcComponent`, target `lightning__Tab`) instead of a FlexiPage.
- SLDS gutter classes on a parent grid also pad every nested `.slds-col`, including ones inside child components. Leave `slds-col` off elements that should not get that padding.
- State and country picklists are on in the demo org: set `BillingStateCode = 'IL'` and `BillingCountryCode = 'US'`, not the text fields.
- Layout deploys fail unless always-required fields are present: `ParentId` on Account layouts, `SuppliedEmail` on Case layouts. Activity related lists on Contact have no `TASK.WHO_NAME`, and on Lead neither that nor `TASK.WHAT_NAME`.
- A record page for one record type is assigned in the app (`profileActionOverrides` in `applications/*.app-meta.xml`), not on the object.
- `slds-wrap` turns off equal-height columns; add `slds-grid_vertical-stretch` to get them back.
- Updating records that were queried with read-only fields (a master-detail parent, formulas) can fail with "fields being inaccessible". Update a new `SObject(Id = ..., Field = ...)` instead.
- The plugin's Flow and Lightning-page skills expect a `metadata-experts` tool server. When it is not connected, write the flow or page XML directly (in `antsurance/`, through the generators in `antsurance/scripts/`) and let the deploy validate it.
- In flow XML, a Boolean screen input must not carry `isRequired`, and a text default cannot reach through a lookup (`{!Get_Claim.Contact.Name}`); put the cross-object value in a formula resource and reference that.
- A long text area field cannot be used in a SOQL `WHERE` clause. Filter on another field and compare in Apex.
- Standard Quotes are off until `settings/Quote.settings-meta.xml` sets `enableQuote`. Prefer the standard object over a custom quote object.
- Deleting an object or field fails while an old, inactive flow version still references it. Delete that `Flow` version through the Tooling API first.
- `getRecord` in an LWC does not return the latitude and longitude halves of a compound Geolocation field, even though the REST API does. Use two Number fields.
- `lightning-map` did not geocode addresses or draw reliably in the demo org. `antsuranceAssetViewer` draws OpenStreetMap tiles itself from stored coordinates.
- An image from another site needs a CSP Trusted Site for its exact host (Wikipedia serves thumbnails from `thumb.wikimedia.org`), and the page needs one reload after the rule deploys.
- The first click on a record page's action button right after navigation only focuses it. Wait for the related lists to load, or click again.
- A deploy that includes a schedulable class with a scheduled job fails with "This schedulable class has jobs pending". In `antsurance/` that is `AntsuranceRenewalJob`, so deploy changed classes by name instead of the whole `classes` folder.
- `hint` is a reserved identifier in Apex; a field or variable with that name does not compile.
- A button that should do something and then navigate, with no screen, is an LWC quick action with `actionType` `Action` and an `@api invoke()` method. To show a record-page action only in some states, give its `valueListItems` entry a `visibilityRule` (see `antsurance/scripts/gen_pages.py`).
- Report and dashboard metadata has its own rules (column naming on custom report types, what a metric or table tile will accept, the `branding` palette, the limit on dashboards that run as the viewer). Read `antsurance/scripts/gen_reports.py` before changing them.
- A dashboard shows stored results. After deploying one or reloading data, refresh it: `antsurance/scripts/reload_demo.sh` does both, or send a `PUT` with body `{}` to `/analytics/dashboards/<id>`.
- **A Developer Edition org has 5 MB of data storage, about 2,500 records at 2 KB each.** Past it, every insert fails with `STORAGE_LIMIT_EXCEEDED` while updates still work. Keep seed data near 2,100 records. Salesforce recounts storage about a minute behind, so deleting and reloading in one transaction fails when the org is nearly full: delete, wait for `sf org list limits` to show `DataStorageMB` free, then load. Files count against a separate 20 MB.
- **A Developer Edition org allows 15,000 API calls in any rolling 24 hours, shared by everything that touches it.** Every `sf` command spends several (a deploy, a query, an Apex run, a limits check), and an eval that runs one Apex call per case, a polling loop, or several agents working at once can spend the lot in an evening. Past it, every CLI call fails with `REQUEST_LIMIT_EXCEEDED: TotalRequests Limit exceeded` for hours; the browser still works. Setup, Company Information shows the count. Budget it: batch deploys, print many values from one Apex run instead of many queries, wait on a timer instead of polling, and give each parallel worker a call budget.
- Salesforce's path component does not draw on Lead record pages in the demo org, even with an active path. The Lead page uses its own `antsuranceLeadPath` component.
- A long text area field cannot appear in a SOQL `WHERE` clause, including `!= NULL`. Filter in Apex.
- Deleting a stock sample field can fail because Salesforce's sample case assignment and escalation rules, or a custom link, still use it (`Account.SLA__c`, `Opportunity.TrackingNumber__c`).
- `CustomObjectTranslation` renames a standard object and its tab (Accounts to Customers) but refuses standard field labels ("Cannot translate standard field"). Those need Setup, Rename Tabs and Labels, by hand; `antsurance/README.md` lists the ones this org uses.
- Relabelling a stock list view needs a plain label. Deploying `ENCODED:{!FilterNames...}` shows that text literally.
- A record-page header action hidden by a visibility rule does not count toward `numVisibleActions`, so the next action slides into view. Give Delete the same rule as the actions before it.
- Apex does not keep the order of map keys when it serializes. A JSON schema built from nested maps reaches the Claude API reordered, and Claude then returns empty fields with HTTP 200. Build schemas as text (`AntsuranceAiClient.Shape`).
- **Salesforce allows 120 seconds of callout time per Apex transaction, across every callout in it,** and enforces it with a limit error no code can catch. So: one Claude call per Apex request; multi-step jobs (a shift, several batches of photos, a report) are driven step by step from the component, with progress and a retry for the step that failed; a retry inside the same transaction gets only the time the first attempt left. `AntsuranceAiClient` does the accounting and reports a timeout as `AiException` with `kind = 'timeout'` and a message for the person.
- A callout cannot follow a save in the same transaction ("uncommitted work pending"). In Anonymous Apex, save in one run and call out in the next.
- In flow XML a record choice set accepts a `NotIn` filter against a text collection, and a screen can lay fields out in two columns with a `RegionContainer` holding two `Region` fields of width 6 (see `antsurance/scripts/gen_flows.py`).
- A quick action can be opened by URL: `/lightning/action/quick/<Object>.<Action>?objectApiName=<Object>&context=RECORD_DETAIL&recordId=<Id>&backgroundContext=<encoded record path>`.
- Pinning a list view in the browser only registers once the list has finished loading; a click before that only shows the tooltip.
- Agents driving the same Chrome share one tab group. When one closes the group's last tab the group goes with it, and the next `tabs_context_mcp` makes a new one, so always work in a tab you just created and expect its id to change.
- A record page can name its own related lists with `lst:dynamicRelatedList`: columns go in `relatedListFieldAliases`, spelled exactly as in a page layout's related list (`CASES.CASE_NUMBER`, not `CASE_NUMBER`), and `relatedListLabel` is the only way to retitle a standard relationship. Three lists on the first tab load in about six seconds; a page of five took ten.
- A visibility rule with more than one criterion needs a `booleanFilter` ("1 AND 2").
- Dashboard chart colours come from a fixed list of palettes. Only the one that follows the org's theme leads with the brand colour, and it draws every series in shades of it, so keep charts to a single series when using it.
- The Claude API rejects a request whose strict tools add up to too large a grammar ("The compiled grammar is too large"). Four strict tools were fine in `antsurance/`; thirteen were not. Keep display-only tools non-strict and check their input in Apex.
- The `Global.SendEmail` quick action hangs when opened on a Case. Open it on the contact or the policy instead.
- With state and country picklists on, a record form (`lightning-record-edit-form`) needs `CountryCode` set ahead of `StateCode`.
- **Do not reload or clear the demo data unless the person running the org asks for it in that message.** `antsurance/scripts/reload_demo.sh` empties the org for a minute or two and changes every record Id; on Oct 4 a routine reload ran while someone was using the org and found it empty. The script now refuses to run without `--yes`.
- The Chrome window the browser tools drive is the user's own window and is shared by every agent. Never resize it. To see a page narrow, run `antsurance/scripts/ui_checks/narrow_check.js` in your own tab: it narrows the active page container (`.oneContent.active`) itself, measures that the layout really moved, lists wrapped button labels, cut-off or spilling text and components taller than the window, by component, and puts the page back. It refuses to say "clean" when nothing reflowed. Neither page zoom nor the body's width narrows an internal Lightning page (both were tried and both gave a false "clean"); on the LWR portal, page zoom does. A tab that is not in front draws no frames, so a component that re-measures itself must use a timer or a `resize` listener, not `requestAnimationFrame` or `ResizeObserver` alone.
- Write American spelling in everything a person reads, including prompts that shape what Claude writes ("Analyze", not "Analyse"). "Cancelled" stays: it is a stored status value.
- The customer portal (`/portal`, an LWR Experience Cloud site) keeps serving the old code after a component deploy until the site is published. A contact with a portal user cannot be deleted, so a demo data reload must deactivate the portal user first and run `antsurance/scripts/portal_user.apex` after.
- `main` holds checked work only: a worker's files are committed there after the orchestrator has seen them working. While workers are mid-task, `scripts/snapshot_in_flight.sh` saves the whole working tree to the `in-flight` branch on the remote without touching `main`, the index or any file, so nothing lives only on this machine. Run it after each integration and before stepping away.
- `override` and `then` are reserved words in Apex, like `hint`.
- A record page's header strip gives each field a share of the page (about 240 pixels at 1,745 wide, about 135 at 1,024), and a value that does not fit breaks. A formula there breaks a single word by the letter, and a no-break space does not hold a name on one line. Keep the strip to short values and let the page's card carry a long name (`antsurancePolicySummary`, `antsuranceCaseSummary`).
- The portal's phone layout shows in a 390 pixel same-origin frame; page zoom does not trigger it.
- The sandbox blocks `thumb.wikimedia.org`. `upload.wikimedia.org` serves the same thumbnails and throttles hard, so fetch slowly. Vehicle pictures on the insured asset page come from a table in `AntsuranceAssetController`, one freely licensed file per model generation.
- A check for "is our app, tab or class installed here" must ask what the org holds (the Tooling API, or a retrieve), never what the running person may open (`AppMenuItem`, the tab list): an administrator whose profile does not show the app reads as "not installed". The kit made this mistake twice.
- Removing metadata that a customer's own class depends on does not fail: Salesforce deletes ours and theirs stops compiling. Ask first (`MetadataComponentDependency`, or the kit's own check) and stop.
- An Experience Cloud component or class cannot be deleted while a page of the site shows it or the published copy uses it. Empty the pages, publish while the site is live, delete, then switch the site off.
- A custom app is visible only to a profile or permission set that says so. Ours comes from `Antsurance_CRM` (`applicationVisibilities`, written by `gen_model.py`); the demo org hid its absence because the administrator's profile shows the app.
- A SOQL `LIKE` pattern with an escaped underscore (`'Antsurance\_%'`) matched nothing in a bracketed query on `PermissionSet`. Query `LIKE 'Antsurance%'` and check `startsWith('Antsurance_')` in Apex.
- After a successful LWC deploy the org can go on serving the old component for two or three minutes, even with IndexedDB cleared and two reloads. Before concluding a change did not deploy, check the bundle's `LastModifiedDate` (Tooling, `LightningComponentResource`), wait, and reload again.
- A demo photo has to fit the record it is on: the vehicle type and the side of the damage the claim describes, not only the kind of loss. Claude's photo assessment names a sedan on an SUV claim even from a tight crop, and a person sees a wrong photo at once. Sample photos and their licenses are in `antsurance/force-app/main/default/staticresources/antsuranceDamageSources/LICENSES.md`.
- `on` is reserved too: a method named `on` does not compile.
- Salesforce throws stored Apex coverage away whenever a class is saved, so the Tooling API's coverage tables read zero after a day of deploys. Measure with a check-only deploy (`antsurance/scripts/apex_coverage/`): it changes nothing and its result carries every class's figure.
- A test that returns early when a feature is off ("Notes is not on here") passes and covers nothing, and the class then fails the 75 percent bar in an org without that feature. Give the class a stand-in the test can set, so its logic is covered in any org.
- LWC compiles `value` on a `<textarea>` as an attribute, which a textarea ignores, so the box draws empty. Set `.value` through `lwc:ref` in `renderedCallback`, and only when it differs, so the caret does not jump while a person types (see `antsuranceClaimLetters`).
- A total row inside a list of amounts Claude returns gets added to the lines it totals. Tell Claude to leave it out and drop it in Apex as well (`restatesTotal` in `AntsuranceClaimsAssistantAnalysis`).
- At API 67 a test's plain DML runs with the running user's field access. In a clean org the permission sets must be assigned before the tests run, and a test that has to write a field its user cannot see says `insert as system`. the demo org hides this because its admin sees everything; a scratch org does not.
- A Tooling query inside a composite batch comes back without its fields: ask those one at a time. `sf api request rest --method DELETE` fails with "No 'mode' found in 'body' entry": send a composite batch with DELETE sub-requests instead.
- The Apex debug log writes `|` inside a message as `&#124;` and echoes the anonymous source, so match only its `USER_DEBUG` lines.
- A scratch org with state and country picklists needs its user's `CountryCode` set before the user record can be saved, and starts with one sample account and two sample cases.
- `antsurance/scripts/gen_model.py` takes two arguments (`force-app/main/default scripts/gen_model_base.py`) and writes the `Antsurance_CRM` permission set: it grants every class with an `@AuraEnabled` method and every Visualforce page controller, so run it after adding either instead of editing the permission set by hand.
- To share the project with someone else, build the kit: `python3 -I antsurance/scripts/build_kit.py` writes `antsurance/dist/antsurance-kit.zip`, with sample addresses and a check of its own output, and stops if that check finds a problem.
- To check a change, follow `.claude/skills/verify/SKILL.md`.
- Visualforce `renderAs="pdf"` supports CSS 2.1 only: no flexbox or grid, lay out with tables, and embed images as static resources.
