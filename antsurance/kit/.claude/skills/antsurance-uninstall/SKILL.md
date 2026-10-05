---
name: antsurance-uninstall
description: Removes Antsurance from a Salesforce org safely, dry run first, leaving the customer's own data and setup alone. Use whenever the person says "uninstall", "remove this", "remove Antsurance", "take it out of my org", "undo the install", "clean up the trial" or "delete the scratch org".
---

# Remove Antsurance

Read `CLAUDE.md` in the kit root first. Its rules apply: say the target org, never production unless asked in that message, show the plan and get a yes, fail loudly.

## Step 1. Which org

Ask which org if it is not clear. Run `sf org list` and show the choices.

**If it is a scratch org,** nothing needs uninstalling. Confirm, then delete the whole org:

```
sf org delete scratch --target-org <alias> --no-prompt
```

That is the end for a scratch org.

**If they want one part gone and the rest kept** (the pages, the portal, the components, the automations, the data model, Ask Claude), add `--capability <part>` to the commands below and read "Removing one part" further down first. `python3 scripts/setup/deploy_phase.py --list` names the parts.

**If they installed the whole app and now want only a part of it:** the installer does not take a part out from under the whole app, and says so. Tell them the way: remove the app (this skill, all of it), then install the part they want with `python3 scripts/setup/deploy_phase.py --target-org <alias> --only <part>`. Their own records stay unless they ask to delete them. This was done in a scratch org, with the portal and the look and feel installed: the app came out, and the parts went in on what was left. Run the preflight between the two, as before any install. It finds our six record types still there, switched off (Salesforce does not let an installer delete a record type), and says they are ours: a NOTE when it runs from the kit folder the uninstall ran from, a DECIDE when it cannot see that the uninstall ran. Neither is a clash, and the install switches them on again.

## Step 2. Dry run

```
python3 scripts/setup/uninstall.py --target-org <alias>
```

It changes nothing. Show the person:

- what would be removed, by step;
- what would stay, and the clicks to remove each by hand (Salesforce does not let an installer delete record types, picklist values or switched-on features);
- whether the org holds records that exist only because of this app (policies, claims, and so on), and how many;
- the app's own settings rows, if it lists any (for example the ids the coverage agent's setup kept). They go with the app and need no decision and no `--delete-our-records`.

The dry run also asks the org one more thing, and you must read the answer to the person: **whether a class or trigger of their own uses a class that would go.** See "A class of theirs that uses ours" below. When the dry run names any, the removal will stop there, so settle it before asking for a yes.

If the org holds the customer portal, the dry run says so: the portal is removed first, the way `--capability portal` removes it. See "The portal" below for what that does to the site.

## Step 3. Ask

Use AskUserQuestion, or plain text if the tool is not available.

**"Remove Antsurance from <org name>?"**

- **Not yet (Recommended if they want to keep the records).** Nothing changes. Export the records first.
- **Remove the app and delete its records.** Policies, their details, and the customers, claims and sales that use our record types are deleted. Records of any other record type are never touched.
- **Remove the app.** Only offered when the dry run found no such records.

If `install-report.md` exists, read "Choices made" in it: it says whether the look and feel or the portal were applied, which decides what stays to be undone by hand.

## Step 4. Remove

```
python3 scripts/setup/uninstall.py --target-org <alias> --yes
```

Add `--delete-our-records` only if they chose that.

It goes in this order, and says what it did at each step: take away access; delete our records if asked; take the portal out first if the org holds it; switch off our flows; switch off our record types; then remove components in nine steps, pages first and objects last.

If a step does not finish, it prints which component is still in use and by what. That is nearly always something of theirs that uses one of ours, such as a report or a page of their own. Help them remove that reference, then run the same command again. It picks up where it left off.

Do not delete anything by other means to force it through.

## Step 5. Finish by hand

Read back the "would stay" list and offer to walk them through each one in Setup. Order matters: delete the record types before the processes.

**If the coverage agent was set up** (the install report says so, or `setup_coverage_agent.py --target-org <alias>` did before the removal): tell the person that the agent "Antsurance claims coverage agent (Salesforce)", the environment "antsurance-crm-coverage", the skill "antsurance-coverage" and their past sessions are still in their Anthropic workspace. The uninstall removed only the ids kept in Salesforce. They can archive them in the Claude Console, under Managed Agents. Archiving there is permanent, so never do it for them and never call the Anthropic API to do it.

## Removing one part

```
python3 scripts/setup/uninstall.py --target-org <alias> --capability <part>          (dry run)
python3 scripts/setup/uninstall.py --target-org <alias> --capability <part> --yes
```

1. **The order is top down.** The pages and the portal first, then the components, then the automations, and the data model last. Asked for a part that another part in the org is built on, it changes nothing, names that part and prints the command to run first. Do that one first; do not look for a way around.
2. **It leaves what the other parts hold.** A class the automations and the components share stays while either is there.
3. **The data model is the whole uninstall.** Once nothing is built on it, `--capability data-model` runs the steps above, with the same stop for records the person would lose.
4. **If it stops part-way,** run the same command again. It takes out what is left and skips what is already gone.
5. **The pages while the look and feel is installed:** the logo file stays, because the theme shows it. It says so and carries on.

### A class of theirs that uses ours

Salesforce deletes an Apex class even when another class uses it. It gives no warning and no error, and the class that used it stops compiling the next time it is saved or run. This was seen in a scratch org: a class of the org's own that extended one of ours was left broken by a removal that reported success.

So every removal, of one part or of everything, first asks the org which classes and triggers of the person's own use a class that would go. When it finds any it prints each with what it uses, changes nothing, and stops:

```
Of the org's own, and using a class that would go: AcmeAddressHelper (uses AntsuranceAddress).
```

Tell the person exactly that, and give them the two ways on:

1. **Move their class off ours.** Change it so that it no longer names our class: copy what it needs into a class of their own, or fit that piece to their model with the `antsurance-adapt` skill. Then run the removal again.
2. **Keep the part.** If their class is meant to build on ours, the part stays.

Never delete or edit their class to get the removal through without their yes, and never remove ours "anyway". If the org would not answer the question, the removal says so and goes on: then look yourself, by searching their classes for `Antsurance`.

### The portal

`--capability portal` takes the customer portal out and leaves the rest of the app. Tell the person before the yes what stays, because none of it can be undone by an installer:

1. **The site stays.** Salesforce does not delete a site. It is left emptied of our components and switched to "down for maintenance". They archive it in Setup, Digital Experiences, All Sites.
2. **Digital Experiences stays on.** Salesforce does not let it be switched off again.
3. **The profile for portal users stays**, granting nothing of ours. They delete it in Setup, Profiles, once no user is on it. Portal users keep their logins; deactivate them in Setup, Users.
4. **Records stay.** What customers sent through the portal are ordinary claims and requests.
5. **What Salesforce made with the site stays with it.** A guest profile named after the site (Antsurance Profile), a guest group and a file named SiteSamples. They are not ours and no installer removes them.

The removal works in an order Salesforce forces, and each step has a reason:

1. **Empty the site's pages.** It saves the Home and Login pages again without our components. Salesforce refuses to delete a component while a page of a site shows it.
2. **Publish the site again, if its published copy still uses ours, and wait.** The published site is a copy of its own. Until it is published again Salesforce refuses the portal's classes with "referenced elsewhere in Salesforce ... Web App Resource Dependency", or a component with "found in ... 1 Published Instance(s)". Publishing runs in the background, so it waits a minute at a time, up to four times.
3. **Remove** the permission sets, the trigger and its subscriber, the components and classes, then the event.
4. **Only then switch the site off.** Salesforce publishes only a site that is live, so switching it off first would make step 2 impossible.

## Troubleshooting

| What it says | Why | What to do |
|---|---|---|
| "X of the org's own use a class that would go" | A class of theirs uses one of ours. Salesforce would delete ours without a word and theirs would break. | "A class of theirs that uses ours", above. |
| "... is built on ... and still in the org. Remove it first" | A part cannot go from under another. | Run the command it prints, then this one again. |
| "The whole app is in this org" | A part is not taken out from under the whole app. | Remove the app, then install the part. |
| "The published copy of the site had not let go of ours yet" | Publishing was still running after four minutes. | Wait a few minutes and run the same command again. |
| "Salesforce would not publish the site" | The site is not live, or the person may not publish it. | Set the site to Active in its Administration settings, publish it in the Builder, then run the same command again. |
| A step names something of theirs that uses one of ours (a page, a report, a flow) | Salesforce refuses those itself. | Help them take that reference out, then run the same command again. |
| "Still on" beside a record type | An object keeps its last active record type. | Listed under what stays: they delete it in Setup. |
| Our fields still listed under an object's Deleted Fields | Salesforce keeps a deleted field for 15 days, renamed with `_del`. | Nothing, or erase them there. |

## What the uninstall never does

- It never deletes a record that does not use one of our record types or sit in one of our objects.
- It never edits a profile, a sharing setting or a layout of theirs.
- It never removes a picklist value. Their records may use the ones the install added.
- It never archives or deletes anything in the person's Anthropic workspace.
- It never removes a class of ours that a class of theirs uses. It stops and names both.
