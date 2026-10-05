#!/usr/bin/env bash
# Tries Antsurance in a scratch org: a throwaway Salesforce org made from your Dev Hub.
# Nothing touches your real org. The scratch org gets everything: the app, sample records, the look and
# feel. It deletes itself when it expires.
#
# Usage:
#   scripts/setup/test_in_scratch_org.sh --dev-hub <alias of your Dev Hub org>
#
# Options:
#   --alias NAME       What to call the scratch org (default: antsurance-trial)
#   --days N           How long it lives, 1 to 30 (default: 7)
#   --key-env NAME     Read your Claude API key from this environment variable and store it in the scratch org.
#                      Without it, the script tells you the one command to run yourself to store the key.
#   --with-portal      Also set up the customer portal.
#   --with-coverage-agent
#                      Also set up the claims coverage agent on Claude Managed Agents. Needs --key-env, and a key
#                      whose Anthropic workspace has Managed Agents. It creates an agent, an environment and a
#                      skill in that workspace. Without it, the coverage card offers "Check coverage" only.
#   --definition FILE  Make the scratch org from this definition (default: config/project-scratch-def.json).
#                      config/project-scratch-def-plain.json makes one without state and country picklists.
#   --org ALIAS        Do not create an org; run the steps against this scratch org again (after fixing a failure).
#                      It runs with what the org was started with (--key-env, --with-portal, --with-coverage-agent)
#                      whether or not you repeat them: the run keeps them in .install/. Of the key it keeps only the
#                      name of the environment variable, never the key.
#   --from N           Start at step N (see the numbered steps printed as it runs).
#   --stop-after N     Stop once step N is done.
#   --leave-out-failed With --org: carry on without the step that failed last time. Only for the extras (steps 9
#                      to 12: the portal, Claude, the coverage agent). The output and the report say it was left out.
#
# It stops at the first step that fails and says which, so nothing is skipped quietly. A run carried on with --org
# cannot start past the step that failed: it runs that step again, or leaves it out because you said so.
set -euo pipefail

HUB=""; ALIAS="antsurance-trial"; DAYS=7; KEY_ENV=""; PORTAL=0; AGENT=0; EXISTING=""; FROM=1; LAST=99; DEFINITION="config/project-scratch-def.json"
LEAVE_OUT=0; FAILED=""; LEFT=""; LEFT_WHAT=""; LEFT_TITLE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dev-hub) HUB="$2"; shift 2 ;;
        --alias) ALIAS="$2"; shift 2 ;;
        --days) DAYS="$2"; shift 2 ;;
        --key-env) KEY_ENV="$2"; shift 2 ;;
        --with-portal) PORTAL=1; shift ;;
        --with-coverage-agent) AGENT=1; shift ;;
        --definition) DEFINITION="$2"; shift 2 ;;
        --org) EXISTING="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --stop-after) LAST="$2"; shift 2 ;;
        --leave-out-failed) LEAVE_OUT=1; shift ;;
        -h|--help) sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
        *) echo "STOPPED: unknown option $1" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/../.."
export SF_DISABLE_TELEMETRY=true
S=scripts/setup

command -v sf >/dev/null || { echo "STOPPED: the Salesforce CLI (sf) is not installed. Install it with: npm install --global @salesforce/cli" >&2; exit 1; }
command -v python3 >/dev/null || { echo "STOPPED: Python 3 is not installed." >&2; exit 1; }

is_name() { # true for the name of an environment variable: letters, digits and underscores, not starting with a digit
    case "$1" in ""|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;; esac
    return 0
}

# --key-env takes a name. A key given there by mistake would otherwise be printed in the command to carry on with
# and kept in the run's notes, so it is refused here, without being shown.
if [ -n "$KEY_ENV" ] && ! is_name "$KEY_ENV"; then
    echo "STOPPED: --key-env takes the NAME of an environment variable that holds your key (for example --key-env ANTHROPIC_API_KEY), never the key itself. What was given is not a name. Nothing was changed." >&2
    exit 2
fi

# What a run was asked for belongs to the org, not to one command: a run carried on with --org must do what the first
# one set out to do. So the options that decide which steps run, and the step that failed, are kept in .install/.
remember() {
    mkdir -p .install
    printf 'key_env=%s\nportal=%s\nagent=%s\nfailed=%s\n' "$KEY_ENV" "$PORTAL" "$AGENT" "$FAILED" > "$NOTES"
}

recall() { # an option given again on the command line stands; one left off comes back from the notes
    local name value
    if [ ! -f "$NOTES" ]; then return 0; fi
    while IFS='=' read -r name value; do
        case "$name" in
            key_env) if [ -z "$KEY_ENV" ] && is_name "$value"; then KEY_ENV="$value"; fi ;;
            portal) if [ "$value" = 1 ]; then PORTAL=1; fi ;;
            agent) if [ "$value" = 1 ]; then AGENT=1; fi ;;
            failed) case "$value" in ""|*[!0-9]*) ;; *) FAILED="$value" ;; esac ;;
        esac
    done < "$NOTES"
}

asked_for() { # the options this run was asked for, as they are typed. Of the key, only the name of its variable.
    local said=""
    if [ -n "$KEY_ENV" ]; then said="$said --key-env $KEY_ENV"; fi
    if [ "$PORTAL" = 1 ]; then said="$said --with-portal"; fi
    if [ "$AGENT" = 1 ]; then said="$said --with-coverage-agent"; fi
    echo "$said"
}

carry_on() { # carry_on <step>: the command that goes on from that step with everything this run was asked for
    echo "$0 --org $ALIAS --from $1$(asked_for)"
}

step() { # step <number> <title> <command...>
    local number="$1" title="$2"; shift 2
    if [ "$number" = "$LEFT" ]; then LEFT_TITLE="$title"; echo; echo "Step $number. $title: left out. It failed last time and you said to carry on without it."; return 0; fi
    if [ "$number" -lt "$FROM" ]; then echo "Step $number. $title: skipped (starting at step $FROM)."; return 0; fi
    echo; echo "Step $number. $title"
    if ! "$@"; then
        FAILED="$number"; remember
        echo >&2
        echo "STOPPED at step $number ($title). Fix what is reported above, then carry on with:" >&2
        if [ "$LAST" != 99 ]; then echo "  $(carry_on "$number") --stop-after $LAST" >&2; else echo "  $(carry_on "$number")" >&2; fi
        if [ "$number" -ge 9 ] && [ "$number" -le 12 ]; then
            echo "This step is an extra. If it cannot be fixed, add --leave-out-failed to that command to carry on without it." >&2
        fi
        exit 1
    fi
    if [ "$number" = "$FAILED" ]; then FAILED=""; remember; fi
    if [ "$number" -ge "$LAST" ]; then echo; echo "Stopped after step $number, as asked. Carry on with: $(carry_on $((number + 1)))"; exit 0; fi
}

create_org() {
    if [ -z "$HUB" ]; then
        echo "STOPPED: name your Dev Hub org with --dev-hub <alias>. A Dev Hub is the org that is allowed to create scratch orgs." >&2
        return 1
    fi
    if [ -t 1 ]; then
        sf org create scratch --definition-file "$DEFINITION" --alias "$ALIAS" --target-dev-hub "$HUB" --duration-days "$DAYS" --wait 20
        return
    fi
    # Not a terminal (a log file, or Claude Code running this for you). There sf writes its progress display again
    # several times a second, hundreds of copies ahead of everything this script says after it. Show the last one only.
    local esc seen code=0
    esc="$(printf '\033')"
    seen="$(mktemp)"
    sf org create scratch --definition-file "$DEFINITION" --alias "$ALIAS" --target-dev-hub "$HUB" --duration-days "$DAYS" --wait 20 > "$seen" 2>&1 || code=$?
    LC_ALL=C awk -v erase="$esc[2K" 'index($0, erase) { kept = ""; next } { kept = kept $0 "\n" } END { printf "%s", kept }' "$seen" | LC_ALL=C sed "s/$esc\[[0-9;]*[A-Za-z]//g"
    rm -f "$seen"
    return "$code"
}

store_key() {
    if [ -n "$KEY_ENV" ]; then
        python3 $S/set_api_key.py --target-org "$ALIAS" --from-env "$KEY_ENV" && python3 $S/smoke_test.py --target-org "$ALIAS"
    else
        echo "No key given, so Claude is not connected yet. To connect it, run this yourself in a terminal (the key is typed at a hidden prompt):"
        echo "  python3 $S/set_api_key.py --target-org $ALIAS && python3 $S/smoke_test.py --target-org $ALIAS"
    fi
}

claude_work() {
    # Claude's work on the showcase claims needs a working key: about a dozen calls on it.
    if [ -n "$KEY_ENV" ]; then
        python3 $S/prepare_demo.py --target-org "$ALIAS"
    else
        echo "Claude is not connected, so the showcase claims have their files but nothing from Claude yet. Once the key is stored, run:"
        echo "  python3 $S/prepare_demo.py --target-org $ALIAS"
    fi
}

coverage_agent() {
    if [ -z "$KEY_ENV" ]; then
        echo "STOPPED: --with-coverage-agent needs --key-env, because the agent is created in the Anthropic workspace your key belongs to." >&2
        return 1
    fi
    python3 $S/setup_coverage_agent.py --target-org "$ALIAS" --yes
}

if [ -n "$EXISTING" ]; then ALIAS="$EXISTING"; fi
NOTES=".install/scratch-run-$(printf '%s' "$ALIAS" | tr -c 'A-Za-z0-9_.-' '_').txt"
if [ -n "$EXISTING" ]; then
    recall
    # Step 1 only creates the org. A run that names the org with --org is past it.
    if [ "$FAILED" = 1 ]; then FAILED=""; fi
    if [ "$LEAVE_OUT" = 1 ]; then
        case "$FAILED" in
            9) PORTAL=0; LEFT_WHAT=portal ;;
            # Without Claude connected there is nothing for the coverage agent to run on, so it goes too.
            10) if [ "$AGENT" = 1 ]; then echo "Leaving out step 10 (Connect Claude) leaves out the coverage agent too: it needs Claude connected."; fi
                KEY_ENV=""; AGENT=0; LEFT_WHAT=claude ;;
            11) LEFT_WHAT=claude-work-on-showcase-claims ;;
            12) AGENT=0; LEFT_WHAT=coverage-agent ;;
            "") echo "STOPPED: --leave-out-failed was given, but no step is on record as failed for $ALIAS. Nothing was changed." >&2; exit 2 ;;
            *) echo "STOPPED: step $FAILED failed last time and is part of the app itself, so it cannot be left out. Fix what it reported, then carry on with:" >&2
               echo "  $(carry_on "$FAILED")" >&2; exit 2 ;;
        esac
        LEFT="$FAILED"; FAILED=""
    elif [ -n "$FAILED" ] && [ "$FROM" -gt "$FAILED" ]; then
        echo "STOPPED: step $FAILED failed in the last run on $ALIAS and has not passed since, and starting at step $FROM would skip it. Nothing was changed. Carry on with:" >&2
        echo "  $(carry_on "$FAILED")" >&2
        if [ "$FAILED" -ge 9 ] && [ "$FAILED" -le 12 ]; then
            echo "That step is an extra. If it cannot be fixed, add --leave-out-failed to that command to carry on without it." >&2
        fi
        exit 2
    fi
    remember
    echo "Using the scratch org $ALIAS."
    if [ -n "$(asked_for)" ]; then echo "Running with what this org was started with and what you added:$(asked_for)"; fi
else
    if [ "$LEAVE_OUT" = 1 ]; then echo "STOPPED: --leave-out-failed goes with --org, on a run that is carried on after a step failed." >&2; exit 2; fi
    remember
    step 1 "Create the scratch org $ALIAS from $HUB (lives $DAYS days)" create_org
fi
step 2 "Get the scratch org ready" python3 $S/prepare_scratch_org.py --target-org "$ALIAS"
step 3 "Add our values to the standard picklists" python3 $S/deploy_phase.py --target-org "$ALIAS" --phase value-sets
step 4 "Install the app and run its tests (the long step, 5 to 15 minutes)" python3 $S/deploy_phase.py --target-org "$ALIAS" --phase core --wait 90
step 5 "Give yourself access" python3 $S/assign_access.py --target-org "$ALIAS" --only-me --yes
step 6 "Load the sample records" python3 $S/load_demo_data.py --target-org "$ALIAS" --yes
step 7 "Prepare the showcase claims: sample files and one estimate" python3 $S/prepare_demo.py --target-org "$ALIAS" --without-claude
step 8 "Apply the look and feel" python3 $S/deploy_phase.py --target-org "$ALIAS" --phase look-and-feel
if [ "$PORTAL" = 1 ] || [ "$LEFT" = 9 ]; then
    step 9 "Set up the customer portal" python3 $S/deploy_phase.py --target-org "$ALIAS" --phase portal
else
    echo; echo "Step 9. Customer portal: not asked for (add --with-portal)."
fi
step 10 "Connect Claude" store_key
step 11 "Have Claude do its work on the showcase claims" claude_work
if [ "$AGENT" = 1 ] || [ "$LEFT" = 12 ]; then
    step 12 "Set up the coverage agent on Claude Managed Agents" coverage_agent
else
    echo; echo "Step 12. Coverage agent on Claude Managed Agents: not asked for (add --with-coverage-agent, or run setup_coverage_agent.py later)."
fi
step 13 "Check the install" python3 $S/verify.py --target-org "$ALIAS" --skip-tests
step 14 "Write the install report" python3 $S/write_report.py --target-org "$ALIAS" --answer where=scratch-org --answer access=only-me --answer demoData=yes --answer lookAndFeel=yes --answer portal=$([ "$PORTAL" = 1 ] && echo yes || echo no) --answer coverageAgent=$([ "$AGENT" = 1 ] && echo yes || echo no) ${LEFT_WHAT:+--answer leftOut=$LEFT_WHAT}

# Every step that failed has either passed since or was left out by name. Anything else is not a finished install.
if [ -n "$FAILED" ]; then
    echo >&2; echo "STOPPED: step $FAILED failed in an earlier run on $ALIAS and did not run in this one. Carry on with:" >&2
    echo "  $(carry_on "$FAILED")" >&2
    exit 1
fi

echo
if [ -n "$LEFT" ]; then echo "Left out, because it failed and you said to carry on without it: step $LEFT ($LEFT_TITLE). The install report says so too."; fi
echo "Antsurance is in the scratch org $ALIAS. Open it with: sf org open --target-org $ALIAS --path /lightning/app/c__Antsurance"
echo "Delete it when you are done with: sf org delete scratch --target-org $ALIAS --no-prompt"
