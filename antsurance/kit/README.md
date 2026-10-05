# Antsurance

**An insurance CRM for Salesforce with Claude built in. This folder installs it into your own org.**

Antsurance is a sample insurance agency and carrier desk: customers, policies, claims, service requests, quotes and sales, on standard Salesforce objects wherever one exists. Claude works inside it: it briefs you on a customer, checks a claim against its policy, reads damage photos and claim documents, drafts claim letters for an adjuster to approve, reads a broker's submission into a quote, drafts renewal outreach, prices a quote with you, plans the response to a storm, and answers questions about your book in chat. A page called Claude at Work shows each of these jobs, how it runs and how it scored when tested. One of them, the claims coverage agent, can run as a real agent on Claude Managed Agents if you choose to set that up.

It is a working example to learn from and build on. It is not a supported product.

## Start here

Read `INSTALL.md`. It is one page.

The short version: open this folder in Claude Code and say **"install this"**. Claude Code will offer to try it in a throwaway org first, so nothing touches your real org until you choose.

Three things to know before you start:

1. **Your org is read before it is touched.** In a sandbox or any org with things in it, a preflight pulls a read-only copy of your metadata, reports anything ours would clash with, and writes down how your org names and builds things. Ours keeps its `Antsurance` prefix, anything new follows your conventions, and nothing of yours is renamed.
2. **You choose what to install.** Everything, or parts: the insurance data model, the automations, the screen components with the Claude features, the pages and the app, Ask Claude alone, the customer portal. Each part comes with what it is built on, and you are told what that is first. If you already have your own policy or claim objects, a part can be fitted to them instead. `FEATURES.md` has the menu and the commands.
3. **The code is tested to Salesforce's bar.** Every Apex class and trigger is held to the 75 percent code coverage a production deploy needs, and the installer checks it.

## What is in this folder

| Folder or file | What it is |
|---|---|
| `INSTALL.md` | How to install, what it changes in your org, how to remove it. |
| `force-app/` | The app: data model, Apex code, screen components, pages, flows, reports. Safe to add to an org that already has its own setup. |
| `optional/` | Things that change the org for everyone, each installed only when you say yes: picklist values, the Quotes and Path switches, the look and feel, the customer portal. |
| `scripts/setup/` | The installer. Small Python scripts that drive the Salesforce CLI. Each says which org it is about to act on. |
| `.claude/skills/` | Instructions that teach Claude Code how to install and remove the app. |
| `CLAUDE.md` | What Claude Code reads first: which path to take, the rules, what is in the app and how its pieces depend on each other, how to add to it. |
| `FEATURES.md` | Every feature of the kit, the ones that can be installed alone, what each needs, and the command. |
| `slices/` | A part that installs alone, complete in its own folder. Today: `slices/ask-claude/`. |
| `capabilities/` | One folder for each choice on the install menu: what it holds, what it brings with it, its tests and its own permission set. |
| `kit-scan.json` | What names what in the app: every class, trigger, flow, component and page, and the objects, fields and record types each one uses. The install menu is worked out from it. |
| `examples/acme/` | A worked example of fitting a part to another data model: an invented policy object, a mapping, and a model class for the chat. |
| `config/project-scratch-def.json` | The recipe for the throwaway trial org. |
| `skills/` | The method the optional coverage agent follows, as a skill you can read. Setting the agent up uploads the same text to your Anthropic workspace. |
| `uninstall/` | The list of what an uninstall removes, in order. |
| `licenses/` | Where the sample photos, documents and fonts came from, and their licenses. |
| `kit-manifest.json` | The names of everything the app adds, used by the installer to spot clashes. |

The preflight adds three things here when it runs: `setup-report.md` (what it found), `org-conventions.md` (how your org names and builds things) and `.install/` (its notes and the pulled copy of your metadata). All three stay on your computer and are safe to delete.

## What you need

- The Salesforce CLI (`sf`) and Python 3.8 or newer.
- A Salesforce org you administer, or a free Developer Edition org.
- A Claude API key from the Claude Console, for the Claude features. The app installs without one; Claude's buttons will say the key is missing until you add it.

## What the sample data is

About 2,100 invented records: households, businesses, agencies, policies, claims, quotes and tasks. Every person, business, policy and claim is made up. Every household sits on an invented street name. The sample photos and documents are listed in `licenses/`.

## Calling Claude costs money

Each Claude feature calls the Claude API on your key, and you pay for that use. The optional coverage agent runs sessions on Claude Managed Agents on the same key, about 10 cents each in our runs and capped at one dollar. The model is set in one place (Setup, Custom Metadata Types, Antsurance AI Setting, Default) and you can change it without touching code.
