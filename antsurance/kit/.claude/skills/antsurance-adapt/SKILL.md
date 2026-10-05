---
name: antsurance-adapt
description: Fits a part of Antsurance (its automations, its screen components, the portal, or the Ask Claude chat) to a Salesforce org's own data model, when the org already has its own policy, claim or customer objects with other names and fields. Use whenever the person says "fit this to my objects", "make it work with our policy object", "we already have a claims object", "adapt this to my data model", "map your fields to ours", "I do not want your objects", "use my objects instead", or answers "fit it to my objects" when asked whose data model to use, even if they do not name Antsurance.
---

# Fit a part of Antsurance to the org's own data model

The person has objects of their own and wants our automation, our components or the chat to work on those. You make a copy of the part that names their objects and fields, follows their conventions, and is theirs to keep. A script does the renames it can be sure of and writes down every place that needs judgment. You and the person do the rest.

Read `CLAUDE.md` in the kit root first. Its rules apply to every step. The ones that matter most here:

1. **What is adapted is theirs.** It carries their names and follows `org-conventions.md`. It never carries our `Antsurance` prefix.
2. **Nothing of theirs is renamed or altered without a yes.** Not a field, not a picklist value, not a validation rule. If the fit needs a change to something of theirs, ask.
3. **Our shipped files are not edited.** The copy lives in `adapted/`. `force-app/`, `optional/` and `slices/` stay as they came.
4. **A mismatch is never papered over.** Something the adapter flags is not made to pass by deleting a test, deleting an assertion, catching an error and moving on, or `NoTestRun`. Change the test so that it builds their records and still proves the same thing.
5. **Say the target org before every deploy.** Never production unless they ask for production in that message. A sandbox or a scratch org first.

All commands run from the kit root.

## Step 1. Preflight

```
python3 scripts/setup/analyze_org.py --target-org <alias>
```

Mandatory, and it changes nothing. You need three things from it: the verdict in `setup-report.md`, the conventions in `org-conventions.md` and `org-conventions.json`, and the pulled metadata under `.install/org-metadata/<alias>/`, which is where their objects and fields are read from. A STOP in the report is settled before going on.

Read `org-conventions.md` yourself. Where a line says "a guess" or "nothing to go on", ask the person; do not invent a convention for them.

## Step 2. Which part, and how much of it

Ask with AskUserQuestion when they have not said. If that tool is not available, ask in plain text and wait.

**"Which part should work on your objects?"**

1. **The automations.** The triggers and their classes, and the flows.
2. **The screen components.** The record cards and the Claude features.
3. **The Ask Claude chat.** It already reads your objects. This teaches it more about them. Go to "The chat" at the end of this skill.
4. **The customer portal.** The site's components and classes. Read "The portal" at the end first.

Then offer to start small, and recommend it: one trigger with its class and test, one flow, or one component, before a whole part. A first small piece shows how well their model fits ours at little cost.

Say what to expect, from three pieces fitted to an invented model and deployed (`FEATURES.md` has the table): the adapter did every rename and none had to be undone. A flow that names three fields needed one decision. A screen component with its Apex needed 34, and most of the hand work was its test, which loaded our sample records and had to build theirs instead. The hand work grows with how much of our model a piece leans on, not with its size.

```
python3 scripts/setup/describe_capability.py --capability automation
python3 scripts/setup/describe_capability.py --capability automation --only ApexTrigger:AntsurancePolicyTrigger
```

The first prints everything the part names: each object, each field with its type, each record type, each picklist value named in the code, and the classes and components the part is made of, with counts. The second narrows that to one component and the code it needs. `--json` gives the same as data. This list is what has to be mapped. Show the person the counts, not the whole list.

## Step 3. Propose the mapping

Copy `scripts/setup/mapping.example.json` to `mapping.json`. Its notes say what each key means. For everything of ours on the list, the mapping says one of three things:

1. **It is this of theirs** (`"to"`). Our `Policy__c` is their `Acme_Policy__c`; our `Policy__c.Account__c` is their `Acme_Policy__c.Customer__c`.
2. **Create ours beside theirs** (`"createOurs"`). They have nothing like it and want what it does. Our field is added to their object, or our object is installed whole.
3. **Leave it out** (`"leaveOut"`). They have nothing like it and do not want it. The adapter marks every line that uses it.

A record type of ours can also map to a field value of theirs (`"toFieldValue"`), for an org that tells claims from service requests by a field. Picklist values map one by one, and `null` says they have no such value.

Propose each line from the pulled metadata: read `.install/org-metadata/<alias>/main/default/objects/` for their objects, their fields with types, their record types and their picklist values. Match on meaning, not on name. Then sort your lines into two piles and be honest about which is which:

1. **Sure.** Same meaning, same type, an obvious name. Say these in one breath.
2. **A guess.** Two candidates, a type that differs, a field whose meaning you inferred from its name alone, anything you would not bet on.

**Ask the person about every guess.** Use AskUserQuestion, one question to a guess, up to four in one go, the likeliest candidate first, and always with "we have nothing like it: create yours" and "leave it out" among the options. Never settle a guess yourself to keep things moving. A wrong mapping compiles and then reads the wrong data.

Check the mapping is complete before going on. This writes nothing:

```
python3 scripts/setup/adapt_capability.py --capability automation --mapping mapping.json --check
```

It refuses a mapping that leaves out something the part names, and names each thing. Fill those in the same way: sure, or ask.

## Step 4. Run the adapter

```
python3 scripts/setup/adapt_capability.py --capability automation --mapping mapping.json --out adapted/ --org-metadata .install/org-metadata/<alias>
```

It never edits `force-app/` and never calls the org. It writes:

1. `adapted/main/default/`: the copy. Apex, triggers, flows, components and pages with our objects, fields, relationships, record types and picklist values renamed to theirs, and the copies themselves named by their conventions (the prefix their classes share and the way they name tests, from `org-conventions.json`, or `"prefix"` in the mapping).
2. `adapted/ADAPT-REPORT.md`: what it renamed, and every place that needs judgment, each with its file, its line and the reason.
3. `adapted/adapt-report.json`: the same as data, with every single rename.

Tell the person the two numbers it prints: how many names it changed by itself, and how many places need a decision.

## Step 5. Work through what it flagged

Open `adapted/ADAPT-REPORT.md` and take the "Needs judgment" items one kind at a time, editing the files under `adapted/` only.

1. **A type that differs.** Read every line that reads or writes the field. A master-detail that is a lookup on their side can be empty: add the check, and find another way for anything that relied on a roll-up or on the parent's sharing. A shorter text field needs the value cut or the write guarded. A picklist that is free text on their side has no fixed values to compare with.
2. **A field the org does not have.** The mapping named a field the pulled metadata lacks. Fix the mapping and run the adapter again, rather than patching the file.
3. **A picklist value with no match, a record type they do not have as one.** Decide with the person what the code should do for them. Do not pick a near value because it compiles.
4. **A name that could be one of two things, a field that could be on one of two objects.** The line was left unchanged. Read it and put the right name in.
5. **Left out by the mapping.** Take out what the line did, completely and cleanly, with the test that covered it changed to match. Say what the copy no longer does.
6. **Required in the org.** Their object requires a field ours never set. Everything that creates such a record must give it a value: ask what value makes sense.
7. **A test that builds records.** Every test in the copy builds records of their objects now. Give each record what their org asks for: required fields, values their validation rules accept, a record type. Read the preflight's list of their rules and automation first. Keep every assertion. If an assertion relied on something of ours that they do not have (a name you can set, where theirs is an auto number), assert the same fact another way.
8. **A field of ours the mapping does not mention.** The line names a field the list in step 2 did not show. Give it a line in the mapping and run the adapter again; do not patch the file.
9. **Something of ours that is not in the copy.** The line names a class or a component of ours that was not adapted. The usual one is a test that loads our sample records: write the test's records for their model in the test itself. Otherwise adapt that class too, by naming it under `"only"`.
10. **A picklist value in a component's script.** A component is handed values without the field's name, so the adapter never changes a value in a script. Read what the line compares or looks up (a color by status, an icon by product line) and put their values in.
11. **A file of ours carried as it is.** A font or a style sheet the copied code loads is in the copy under our name. Keep it, or rename the file and every line that loads it.
12. **Text that still says Antsurance.** A label an admin sees in the App Builder, a comment, a class name inside a script. Change what a person reads.
13. **Ours created beside theirs, and access.** A new field is invisible until a permission set grants it. Add it to a permission set of theirs, with a yes, or make a small one that follows their naming. Never a profile.

Things the adapter does not look for, which you must: their triggers, flows and validation rules on the same objects (the preflight lists them); sharing, where ours assumed a master-detail; and whether what the part does is right for their business at all. Say what you checked.

## Step 6. Dry run, deploy, verify

```
cd adapted
sf project deploy start --source-dir main --target-org <alias> --dry-run --test-level RunSpecifiedTests --tests <each adapted test class>
sf project deploy start --source-dir main --target-org <alias> --test-level RunSpecifiedTests --tests <each adapted test class>
```

1. Say the target org first. Show the plan and get a yes before the real deploy.
2. Name the adapted tests. A deploy that names its tests asks 75 percent of every class and trigger in it, and that is the bar: read the coverage in the result and name any class under it. Never `NoTestRun`.
3. A failure names a rule or a field of theirs. Fix the copy or the test's records. Do not switch their rule off.
4. Then show the behavior once, for real: save a record of their object and read back what the trigger or the flow did. Roll it back or delete it, and say which.
5. Tell the person what is now in their org, under which names, what it does on their objects, and what was left out.

## The chat

Ask Claude needs no mapping to work in their org. It reads their schema when it runs: their objects, fields, picklist values, record types and lookups. Say that first, and install it alone if it is not there (`deploy_phase.py --only ask-claude`).

Fitting it further means one class of theirs that extends `AntsuranceClaudeModel` and overrides what a schema cannot say. `FEATURES.md`, "Ask Claude in an org with another data model", lists the methods. `examples/acme/ask-claude-model/` is the smallest worked example.

1. Ask what the chat should know that it cannot read: what their records are called, which facts matter on a record page, which starting points to offer, which changes Claude may prepare.
2. Write the class under their name and prefix, with its test beside it. Override only what they answered. Call `super` for everything else, so their standard objects keep working.
3. Deploy the class and its test, with the test named.
4. Name the class in the setting: copy `force-app/main/default/customMetadata/Antsurance_AI_Setting.Default.md-meta.xml` (or the one under `slices/ask-claude/`), add a value for `Chat_Model_Class__c` holding the class name, and deploy that one file. The field cannot be set by a click.
5. Tell them an update of the kit puts our record back, so that one file is deployed again after an update.

## The portal

The portal's own code names 95 of our fields and 7 of our objects, and its site, its profile for portal users and its platform event are built around them. Fitting it is the largest of the four: the same steps as above with `--capability portal`, and then by hand the site's pages, the portal profile's object and field access for their objects, and sharing, so that a customer sees only their own records in objects whose sharing is theirs to decide. Say that plainly before starting, and recommend fitting the automations or one component first.
