# What installing changes in an org

Sorted by how far each thing reaches. Use this to answer "what would this change?" and to write the plan.

## Before anything: the preflight. Reads only, changes nothing

- It asks the org questions and pulls a read-only copy of the metadata ours could meet (objects and fields, record types, validation rules, layouts, triggers, apps, tabs, pages, credentials, picklists).
- It writes to the person's computer only: `setup-report.md`, `setup-report.json`, `org-conventions.md`, `org-conventions.json` and `.install/org-metadata/<alias>/`. Nothing is sent anywhere else, and all of it is safe to delete.
- It costs about 100 of the org's daily API requests.

## When only parts are installed

Each part adds only what it holds, and what it is built on. `python3 scripts/setup/deploy_phase.py --list` says which that is, and `capabilities/<part>/capability.json` lists every file.

- **Insurance data model**: the objects, fields, record types, processes, compact layouts, list views and settings types below, the group Antsurance Users and the permission set Antsurance Data Model. No code. It needs our picklist values and Quotes first.
- **Automations**: three triggers, five flows, eight classes with their tests, one notification type, the Anthropic credential (empty) and the permission set Antsurance Automation. Plus the data model.
- **Screen components and the Claude features**: the components, the Apex they call, five document pages, static resources, three trusted sites, and the permission sets Antsurance Components and Antsurance Desk. Plus the data model and the automations.
- **Page layouts, record pages and the app**: the app, its tabs, record pages, page layouts, buttons, paths and the permission set Antsurance Pages. Plus the three above.
- **Ask Claude**: `FEATURES.md` lists it. Nothing is added to any object.
- **A part fitted to their own objects** (the `antsurance-adapt` skill): a copy of the part's code under their names, and whatever of ours the mapping says to create beside theirs. Nothing of theirs is renamed.

## Ours alone. Added, and invisible until someone is given access

- Objects: Policy, Policy Coverage, Policy Participant, Insured Asset (Policy Asset), Policy Endorsement, File Note, Claude Work, Claude Autonomy (a settings object).
- Settings of our own: the Antsurance AI Setting type (the model), the Antsurance Event type (three sample storm events for the Event Response page), the Antsurance Agent Eval type (how each of Claude's jobs scored when tested, shown on the Claude at Work page), and the Antsurance Coverage Agent custom setting (empty until the optional coverage agent is set up).
- Apex classes and triggers whose names start with `Antsurance`.
- Screen components whose names start with `antsurance`.
- Five flows, the Antsurance app, its tabs and record pages, five document pages (declarations, certificate, ID cards, proposal, claim letter), buttons on our pages.
- Two pages of our own in the app's navigation: Claude at Work (what each of Claude's jobs is, how it runs and what it did) and Event Response (insured locations inside a storm's footprint). Both only read; Event Response creates call tasks when a person asks, five at most.
- Sample documents for the underwriting "Read a submission" card: three made-up PDFs about one sample customer.
- Report and dashboard folders whose names start with `Ants`, shared only with the group "Antsurance Users".
- Permission sets Antsurance CRM, Antsurance Claude, Antsurance Desk, and the public group Antsurance Users.
- The Anthropic credential (holds the key) and permission to reach api.anthropic.com, OpenStreetMap tiles and Wikipedia images.

## Added to things the org shares. Merged, never replaced

- **Fields** on Account, Contact, Case, Opportunity, Quote, Lead and User. Nobody sees them without our permission set.
- **Record types**: Household, Business, Agency (Account); Claim, Policy Service (Case); Policy Sale (Opportunity). Nobody is offered them without our permission set. If the object had no record types, these are its first.
- **Processes** behind those record types (which statuses and stages each offers).
- **Page layouts and compact layouts** of our own, for our record types. The org's layouts are not edited and no layout assignment is changed.
- **List views** of our own on Case, Account, Opportunity and Quote, shared only with the group Antsurance Users.
- **One validation rule** on Case. It only applies to the Claim record type.
- **Triggers** on Case and Opportunity. They act only on our record types. A test in the kit saves a plain case and a plain opportunity and checks nothing of ours touched them.
- **Picklist values** in Case Status, Case Origin, Opportunity Stage, Opportunity Type and Quote Status. The org's own values are read first and all kept in their order; ours are added after them. This is the one addition people can see without access: if an object has no record types, the new values appear in everyone's list for that field.

## Org-wide. Optional, each needs a yes

- **Quotes** switched on (adds a Quotes list to opportunity pages).
- **Path** switched on (shows nothing until a path is built for a record type).
- **Look and feel**: a theme made active for everyone; Accounts renamed Customers, Cases renamed Claims and Service, Opportunities renamed Policy Sales; search results columns for standard objects; restyled stock list views.
- **Customer portal**: Digital Experiences switched on (cannot be undone), one site, a portal profile for portal users only. The portal can be taken out again by itself (`uninstall.py --capability portal`): its components, classes and access go; the site stays, emptied and switched off, because Salesforce deletes no site.

## Outside Salesforce. Optional, needs a yes

- **The coverage agent on Claude Managed Agents.** Its code ships with the app and does nothing until it is set up. Setting it up creates one agent, one environment and one skill in the person's Anthropic workspace (the one their API key belongs to) and keeps their ids in the org. Each investigation is a billed session on their key, capped at one dollar. A session keeps what the agent read on Anthropic's side until it is deleted. The uninstall removes the ids from the org; the agent, environment, skill and sessions stay in the workspace for the person to archive in the Claude Console.

## Never

- No profile is edited or deployed. The System Administrator profile is not touched.
- No sharing setting is changed.
- No record of theirs is read into the app's data, changed or deleted.
- No default app, default record type or org-wide page assignment is set.
