---
name: verify
description: How to verify a change to a Salesforce org project in this folder (Apex, LWC, pages, flows, reports) before calling it done. Use after any change that is deployed to the Antsurance demo org.
---

# Verifying work in this folder

A change is done when it has been deployed, tested, and seen working in the browser on a real record. Tests alone do not count: they miss layout, wording and integration faults.

## Steps

1. **Deploy by path, asynchronously.** `sf project deploy start --source-dir <paths> --test-level RunSpecifiedTests --tests <the tests for what changed> --async`, then one `sf project deploy report --job-id <id>` after a wait. Do not poll and do not use a long `--wait`: every status check spends the org's daily API allowance (15,000 calls), and running out stops all work for hours.
2. **Look in the browser.** Clear the site's IndexedDB, hard-reload, and wait for related lists to settle before judging. Check each page at the width its components are used at. Then check it narrow without resizing the window, which is shared: run `antsurance/scripts/ui_checks/narrow_check.js` in your own tab at 1,024 pixels (it narrows the page container itself and will not report clean unless it measured the change; on the portal use page zoom instead): no button label may wrap, no text may be squeezed or clipped, and a row's action drops under its text instead of shrinking. The first click on a button right after load may only focus it.
3. **Check the screen rules:** no awkward wraps or one-word last lines, no truncation, no large empty areas, no component taller than about one screen at rest (tabs, accordions, paging and carousels instead of a long scroll), no solid black fills or glows, no card that copies another card's design, bold lead-ins on their own line, no em dashes, American spelling (`python3 antsurance/scripts/ui_checks/us_spelling.py` must pass).
4. **For page or component work, get an independent UI audit.** A fresh agent that did not build the screens walks every page in the browser against a UI and UX rubric and writes its findings to a file. Give it record Ids and tell it to use no CLI. Fix what it finds, then run it again; the first pass here found 121 issues and the second still found 53.
5. **Judge the screen as a person using it would, not only as a layout.** Measurements pass screens a person faults in seconds. On every screen you changed, and on the records people open first, ask: does the content fit this record (a photo shows the loss the claim describes and the vehicle the policy insures; documents belong to this claim; names, dates and amounts agree between the cards and with what Claude wrote); is it obvious how to start each feature and what to do next; does anything read as a test, as stock, or as stale (words like "today" on something written on an earlier day; `antsurance/scripts/prepare_demo.sh --check` lists stale stored work); do the header actions include what that kind of record needs (a page that lists its own actions loses every standard button nobody listed); is anything cut off by its container or does a border stop short. An audit agent gets this list, not only a rubric of wraps and heights. Anything you upload or type into a sample record while testing must be believable for that record, because it is hard to tell afterwards what to delete.
6. **Close what you flagged before you report.** Go back over what you noticed on the way and what you have not seen work, and fix it or drive it until it is seen: the browser's file upload tool for a file picker, a scratch org for an install path, a tester agent for a long walk. A report does not end with a list of things "not exercised". Leave an item open only when it cannot be done from here, and say why in one line.
7. **Every Apex class and trigger at 75 percent coverage or more.** A deploy with `RunSpecifiedTests` enforces it for the classes in it; do not get around it.
8. **Before a final sign-off,** run all local tests once (`sf apex run test --test-level RunLocalTests`, then one `sf apex get test`).
9. **Never reload or clear the demo data to verify something.** `antsurance/scripts/reload_demo.sh` deletes every record, leaves the org empty for a minute or two and changes every record Id, and someone may be using the org. Reload only when the person running the org asks for it in that message; if a check seems to need fresh data, say so and ask.

## When several agents work at once

Give each a territory of files and a budget of `sf` commands, and tell each that it may not reload or delete data. They share one browser tab group, so each works only in a tab it just created.
