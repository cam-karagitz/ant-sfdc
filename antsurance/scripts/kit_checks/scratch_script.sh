#!/bin/bash
# Checks kit/scripts/setup/test_in_scratch_org.sh without an org: the script runs from a throwaway folder with
# stand-ins for python3 and sf on the PATH (stubs/), each of which logs its call and fails on cue.
#
# What is checked is the script's own decisions: which steps run, where it stops, the command it prints to carry
# on with, what it keeps in .install/, and what it tells the install report. A marker value stands in for the
# Claude API key, and every output and notes file is searched for it.
#
# Usage: scripts/kit_checks/scratch_script.sh [-v]     (-v prints each run's output, not only the verdicts)
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SOURCE="$REPO/kit/scripts/setup/test_in_scratch_org.sh"
VERBOSE=0; if [ "${1:-}" = "-v" ]; then VERBOSE=1; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/kit/scripts/setup"
cp "$SOURCE" "$WORK/kit/scripts/setup/"
cd "$WORK" || exit 1

export CALLS="$WORK/calls.log"
# Not a key, and not a name either (it has dashes), so the same value serves the "key given as a name" case.
export MY_KEY='MARKER-not-a-real-key-0123456789'
T=kit/scripts/setup/test_in_scratch_org.sh
NOTES="$WORK/kit/.install/scratch-run-antsurance-trial.txt"
ALL="--key-env MY_KEY --with-portal --with-coverage-agent"
CASES=0; CHECKS=0; FAILED=0; LABEL=""; CODE=0

reset() { rm -rf "$WORK/kit/.install"; : > "$CALLS"; }

run() { # run <label> <pattern of the call to fail, or @@ for none> <arguments of the scratch script...>
    LABEL="$1"; local fail="$2"; shift 2
    CASES=$((CASES + 1))
    : > "$CALLS"
    FAIL_ON="$fail" PATH="$HERE/stubs:$PATH" /bin/bash "$T" "$@" > "$WORK/out.txt" 2>&1; CODE=$?
    if [ "$VERBOSE" = 1 ]; then
        echo "=== $LABEL: $T $*"
        grep -v '^$' "$WORK/out.txt" | grep -v ': skipped (starting' | sed 's/^/    | /'
        echo "    exit $CODE; scripts run: $(ran)"
    fi
    check "the key's value appears nowhere" not leaked
}

ran() { sed -n 's/^python3 scripts\/setup\/\([a-z_]*\)\.py.*/\1/p' "$CALLS" | tr '\n' ' ' | sed 's/ $//'; }
notes() { tr '\n' ' ' < "$NOTES" | sed 's/ $//'; }
report() { grep write_report "$CALLS" | sed 's/.*--answer where=scratch-org //'; }

check() { # check <what is expected, in words> <command that is true when it holds...>
    local what="$1"; shift
    CHECKS=$((CHECKS + 1))
    if "$@"; then return 0; fi
    FAILED=$((FAILED + 1))
    echo "FAILED  $LABEL: $what"
    sed 's/^/        | /' "$WORK/out.txt"
    echo "        exit $CODE; scripts run: $(ran)"
}

not() { if "$@"; then return 1; fi; return 0; }
says() { grep -Fq -- "$1" "$WORK/out.txt"; }
leaked() { grep -rFq -- "$MY_KEY" "$WORK/out.txt" "$WORK/kit/.install" 2>/dev/null; }
exits() { check "exit code $1 (was $CODE)" [ "$CODE" = "$1" ]; }
prints() { check "prints: $1" says "$1"; }
never_prints() { check "does not print: $1" not says "$1"; }
runs() { check "runs exactly: ${1:-(nothing)} (ran: $(ran))" [ "$(ran)" = "$1" ]; }
keeps() { check "keeps in its notes: $1 (kept: $(notes))" [ "$(notes)" = "$1" ]; }
reports() { check "tells the report: $1 (told: $(report))" [ "$(report)" = "$1" ]; }
group() { [ "$VERBOSE" = 1 ] && echo "##### $1"; reset; }

INSTALLED="Antsurance is in the scratch org antsurance-trial."
RESUME_12="  $T --org antsurance-trial --from 12 --key-env MY_KEY --with-portal --with-coverage-agent"

group "A. step 12 fails (no Managed Agents); then the command without its options, typed by hand"
run A1 "setup_coverage_agent.py" --dev-hub hub $ALL
exits 1; prints "STOPPED at step 12"; prints "$RESUME_12"; prints "add --leave-out-failed"; never_prints "$INSTALLED"
runs "prepare_scratch_org deploy_phase deploy_phase assign_access load_demo_data prepare_demo deploy_phase deploy_phase set_api_key smoke_test prepare_demo setup_coverage_agent"
keeps "key_env=MY_KEY portal=1 agent=1 failed=12"
run A2-bare-resume "setup_coverage_agent.py" --org antsurance-trial --from 12
exits 1; prints "Running with what this org was started with and what you added: --key-env MY_KEY --with-portal --with-coverage-agent"
prints "$RESUME_12"; runs "setup_coverage_agent"; never_prints "$INSTALLED"
run A3-skip-past-it "@@" --org antsurance-trial --from 13
exits 2; prints "starting at step 13 would skip it. Nothing was changed."; prints "$RESUME_12"; runs ""; keeps "key_env=MY_KEY portal=1 agent=1 failed=12"
run A4-fixed "@@" --org antsurance-trial --from 12
exits 0; prints "$INSTALLED"; runs "setup_coverage_agent verify write_report"; keeps "key_env=MY_KEY portal=1 agent=1 failed="
reports "--answer access=only-me --answer demoData=yes --answer lookAndFeel=yes --answer portal=yes --answer coverageAgent=yes"

group "B. step 12 fails and cannot be fixed: leave it out, by name"
run B1 "setup_coverage_agent.py" --dev-hub hub $ALL
exits 1
run B2-leave-out "@@" --org antsurance-trial --from 12 $ALL --leave-out-failed
exits 0; prints "Step 12. Set up the coverage agent on Claude Managed Agents: left out."
prints "Left out, because it failed and you said to carry on without it: step 12 (Set up the coverage agent on Claude Managed Agents). The install report says so too."
prints "$INSTALLED"; runs "verify write_report"; keeps "key_env=MY_KEY portal=1 agent=0 failed="
reports "--answer access=only-me --answer demoData=yes --answer lookAndFeel=yes --answer portal=yes --answer coverageAgent=no --answer leftOut=coverage-agent"
run B3-nothing-failed "@@" --org antsurance-trial --from 13 --leave-out-failed
exits 2; prints "no step is on record as failed"; runs ""

group "C. step 11 fails; the bare resume must run Claude's work, not print 'not connected'"
run C1 'prepare_demo.py --target-org antsurance-trial$' --dev-hub hub --key-env MY_KEY
exits 1; prints "STOPPED at step 11"; prints "  $T --org antsurance-trial --from 11 --key-env MY_KEY"; keeps "key_env=MY_KEY portal=0 agent=0 failed=11"
run C2-bare-resume "@@" --org antsurance-trial --from 11
exits 0; never_prints "Claude is not connected"; runs "prepare_demo verify write_report"; prints "$INSTALLED"; keeps "key_env=MY_KEY portal=0 agent=0 failed="

group "D. step 4 (the app itself) fails: it cannot be skipped or left out"
run D1 'phase core' --dev-hub hub
exits 1; prints "STOPPED at step 4"; prints "  $T --org antsurance-trial --from 4"; never_prints "add --leave-out-failed"
runs "prepare_scratch_org deploy_phase deploy_phase"
run D2-skip "@@" --org antsurance-trial --from 5
exits 2; prints "starting at step 5 would skip it"; runs ""
run D3-leave-out "@@" --org antsurance-trial --from 5 --leave-out-failed
exits 2; prints "is part of the app itself, so it cannot be left out"; runs ""
run D4-fixed "@@" --org antsurance-trial --from 4 --stop-after 5
exits 0; prints "Stopped after step 5, as asked. Carry on with: $T --org antsurance-trial --from 6"; runs "deploy_phase assign_access"
keeps "key_env= portal=0 agent=0 failed="

group "E. a key given where a name belongs"
run E1 "@@" --dev-hub hub --key-env "$MY_KEY"
exits 2; prints "never the key itself. What was given is not a name. Nothing was changed."; runs ""
check "keeps no notes" not test -e "$WORK/kit/.install"

group "F. --stop-after carries the options; a bare carry-on still reports the portal"
run F1 "@@" --dev-hub hub --with-portal --stop-after 9
exits 0; prints "Stopped after step 9, as asked. Carry on with: $T --org antsurance-trial --from 10 --with-portal"; keeps "key_env= portal=1 agent=0 failed="
run F2-bare "@@" --org antsurance-trial --from 10
exits 0; prints "$INSTALLED"; runs "verify write_report"
reports "--answer access=only-me --answer demoData=yes --answer lookAndFeel=yes --answer portal=yes --answer coverageAgent=no"
run F3-fail-with-stop-after 'verify.py' --org antsurance-trial --from 13 --stop-after 13
exits 1; prints "  $T --org antsurance-trial --from 13 --with-portal --stop-after 13"; never_prints "add --leave-out-failed"

group "G. notes that do not add up (failed step 9, portal not asked for, a key_env that is not a name)"
mkdir -p "$WORK/kit/.install"; printf 'key_env=bad name; rm -rf x\nportal=0\nagent=0\nfailed=9\n' > "$NOTES"
run G1 "@@" --org antsurance-trial --from 9
exits 1; prints "STOPPED: step 9 failed in an earlier run"; never_prints "$INSTALLED"; never_prints "bad name"

group "H. step 10 fails (the key is refused) with the agent asked for: leave Claude out"
run H1 'smoke_test.py' --dev-hub hub $ALL
exits 1; prints "STOPPED at step 10 (Connect Claude)"; prints "  $T --org antsurance-trial --from 10 --key-env MY_KEY --with-portal --with-coverage-agent"
run H2-leave-out "@@" --org antsurance-trial --from 10 --leave-out-failed
exits 0; prints "Leaving out step 10 (Connect Claude) leaves out the coverage agent too"; prints "Step 10. Connect Claude: left out."
prints "Claude is not connected"; prints "step 10 (Connect Claude). The install report says so too."; prints "$INSTALLED"; runs "verify write_report"; keeps "key_env= portal=1 agent=0 failed="
reports "--answer access=only-me --answer demoData=yes --answer lookAndFeel=yes --answer portal=yes --answer coverageAgent=no --answer leftOut=claude"

group "I. a plain run with no options; --leave-out-failed on a new run; --help"
run I1 "@@" --dev-hub hub
exits 0; prints "$INSTALLED"; prints "No key given, so Claude is not connected yet."
runs "prepare_scratch_org deploy_phase deploy_phase assign_access load_demo_data prepare_demo deploy_phase verify write_report"
keeps "key_env= portal=0 agent=0 failed="
reports "--answer access=only-me --answer demoData=yes --answer lookAndFeel=yes --answer portal=no --answer coverageAgent=no"
run I2 "@@" --dev-hub hub --leave-out-failed
exits 2; prints "--leave-out-failed goes with --org"; runs ""
run I3-help "@@" --help
exits 0; prints "# Tries Antsurance in a scratch org"; prints "--leave-out-failed"
check "--help prints comment lines only" [ "$(grep -vc '^#' "$WORK/out.txt")" = 0 ]

group "J. sf redraws its progress display while it creates the org: off a terminal, only the last one is shown"
ESC="$(printf '\033')"
frame() { printf ' -- Creating Scratch Org --\n\n %s\n Alias: antsurance-trial\n\n' "$1"; }
redraw() { printf '\033[2K\033[1A\033[2K\033[1A\033[2K\033[G\n'; }
{ frame "Send Request 0ms"; redraw; frame "Send Request 30ms"; redraw; frame "Done 12ms"; printf '\033[1m\033[32mYour scratch org is ready.\033[39m\033[22m\n'; } > "$WORK/sf-says.txt"
export SF_SAYS="$WORK/sf-says.txt"
run J1-created "@@" --dev-hub hub --stop-after 1
exits 0; prints " Done 12ms"; prints "Your scratch org is ready."; never_prints "Send Request"; never_prints "$ESC"
check "shows the display once" [ "$(grep -c 'Creating Scratch Org' "$WORK/out.txt")" = 1 ]
reset
run J2-not-created 'org create scratch' --dev-hub hub
exits 1; prints " Done 12ms"; never_prints "Send Request"; prints "stand-in: sf org create scratch failed"; prints "STOPPED at step 1"; runs ""
unset SF_SAYS

check_syntax() { /bin/bash -n "$SOURCE" 2> "$WORK/out.txt"; }
LABEL="syntax"; CODE=0; check "bash -n passes with /bin/bash ($(/bin/bash --version | sed -n '1s/.*version \([0-9.]*\).*/\1/p'))" check_syntax

echo "scratch script: $CASES runs, $CHECKS checks, $FAILED failed"
[ "$FAILED" = 0 ]
