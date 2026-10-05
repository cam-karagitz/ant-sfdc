# Antsurance

Antsurance is a fictional insurance carrier, built as a Salesforce CRM you can install in your own org.
It has an insurance data model with sample records, record pages for customers, policies, claims, sales
and quotes, guided screen flows, reports and dashboards, a customer portal, and Claude at work in
claims, underwriting, renewals, the chat and the portal through the Messages API.

Use it to try Claude inside Salesforce, as a starting point for your own build, or as a worked example
of a larger Salesforce project.

## Install it with Claude Code

1. Install [Claude Code](https://claude.com/claude-code), Python 3 and the
   [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`).
2. Clone this repository and open Claude Code in it.
3. Say "install this". Claude Code reads `CLAUDE.md`, asks which org to use and what you want, builds
   the installer and walks you through it.

You can install everything, or only the parts you choose: the data model, automations, screen
components, pages and the app, the customer portal, or Ask Claude on its own. It can start in a
throwaway scratch org so nothing touches a real org, and it asks before every change to an org.
Every part can be removed again.

The Claude features need an Anthropic API key. You store it yourself at a hidden prompt, and it is
never put in chat or in a file.

## Install it by hand

```bash
python3 -I antsurance/scripts/build_kit.py     # writes antsurance/dist/antsurance-kit/
cd antsurance/dist/antsurance-kit
```

Then follow `INSTALL.md` in that folder. Install from the built kit rather than from
`antsurance/force-app`: the kit installs parts that stand alone, uses sample addresses and checks its
own output.

## What is here

| Path | What it holds |
|---|---|
| `antsurance/` | The Salesforce project: the data model, Apex, Lightning components, flows, pages, reports and the portal. Start with `antsurance/README.md`. |
| `antsurance/kit/` | The source of the installer: setup scripts, the install, adapt and uninstall skills, and the install guide. |
| `antsurance/scripts/` | Generators for the objects, pages, flows and reports, the kit build, and the eval harnesses for Claude's features. |
| `CLAUDE.md` | Instructions Claude Code follows in this repository. |
| `.claude/skills/` | Salesforce skills for Claude Code, vendored from [forcedotcom/sf-skills](https://github.com/forcedotcom/sf-skills). |

## About the data

The sample records are invented, with one exception: the 45 households use real street addresses, for
demo purposes only, so maps and property links land on real places. The families, policies and claims
attached to them are made up. The built kit ships invented streets instead.

## License

MIT, see `LICENSE`. The vendored Salesforce skills (Apache-2.0), the fonts and the sample photos keep
their own licenses, listed in `THIRD_PARTY_NOTICES.md`.
