#!/usr/bin/env bash
# Puts the claims into their demo state. Run it after scripts/reload_demo.sh, or any time to see
# where Claude's work on the open claims stands.
#
# Usage: scripts/prepare_demo.sh [--check [--tomorrow]] [--refresh] [org alias]   (default org: $SF_TARGET_ORG)
#
#   --check    changes nothing: says what a run would do on the showcase claims, then lists every
#              stored piece of Claude's work, on any open claim, that is missing or out of date.
#              Exits 3 when it lists any, so it can gate a demo.
#   --tomorrow with --check: reads as tomorrow, so it also lists what was written today and will
#              be stale by then ("due today", "open for 13 days"). Run it the evening before.
#   --refresh  asks Claude again for work the showcase claims already carry (about twenty Claude calls)
#
# What a run does, in order:
#   1. attaches the sample documents and photos that are not on their claims yet
#   2. raises the burst pipe claim's estimate from its first figure to what its documents add up to,
#      with a file note from the adjuster
#   3. has Claude do its work on each showcase claim, one step per Apex run: the photo assessment,
#      a reading of each document, the coverage check, the claim analysis and the brief
#   4. gives every other open claim a coverage check, so a claim off the demo's path is not three
#      empty cards. That is one Claude call for each open claim that has none: 21 calls took 92
#      seconds on Oct 5, and a later run makes none. It runs in the org as a background job, a claim
#      at a time.
#   5. prints what each showcase claim now says
#   6. lists what is still missing or out of date on any open claim, as --check does
#
# It is safe to run twice: a file, an estimate or a piece of Claude's work that is already there is
# left alone. It never clears or reloads data, and it refuses to run in a production org.
#
# It fails loudly: a step that still fails after two more tries stops the run with a non-zero exit,
# and so does anything left out of date at the end (exit 3).
# Each step is one sf command, so a full run after a reload spends about thirty; a run that finds
# everything in place spends about ten. The background job is waited for on a timer: one look when
# it should be done, then one a minute.
set -euo pipefail

CHECK=""
AHEAD="0"
REFRESH="false"
ORG="${SF_TARGET_ORG:-}"
for arg in "$@"; do
    case "${arg}" in
        --check) CHECK="yes" ;;
        --tomorrow) AHEAD="1" ;;
        --refresh) REFRESH="true" ;;
        --*) echo "Unknown option ${arg}. Usage: scripts/prepare_demo.sh [--check [--tomorrow]] [--refresh] [org alias]" >&2; exit 2 ;;
        *) ORG="${arg}" ;;
    esac
done
if [ -z "${ORG}" ]; then
    echo "Set SF_TARGET_ORG, or pass the org alias as an argument." >&2
    exit 2
fi
cd "$(dirname "$0")/.."
export SF_DISABLE_TELEMETRY=true
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ask() {
    # Runs one Apex expression that returns something JSON can hold, and prints it as JSON.
    # On failure prints the error to stderr and returns 1.
    printf "System.debug(LoggingLevel.ERROR, 'PREP ' + JSON.serialize(%s));\n" "$1" > "${WORK}/run.apex"
    sf apex run --file "${WORK}/run.apex" --target-org "${ORG}" --json 2>/dev/null | python3 -I -c '
import html, json, sys
try:
    reply = json.load(sys.stdin)
except ValueError:
    print("The Salesforce CLI gave no answer. Is the org signed in?", file=sys.stderr)
    sys.exit(1)
result = reply.get("result") or {}
if not result.get("success"):
    print(result.get("exceptionMessage") or result.get("compileProblem") or reply.get("message") or "unknown error", file=sys.stderr)
    sys.exit(1)
# The log echoes the source and writes | as &#124;, so only the debug line itself is read.
for line in (result.get("logs") or "").splitlines():
    if "USER_DEBUG" in line and "PREP " in line:
        print(html.unescape(line[line.index("PREP ") + 5:]))
        sys.exit(0)
print("The run finished but its answer was not in the log.", file=sys.stderr)
sys.exit(1)
'
}

lines() {
    # Prints a JSON list of strings, one per line, indented.
    python3 -I -c 'import json, sys; [print("  " + line) for line in json.load(sys.stdin)]'
}

out_of_date() {
    # Lists every stored piece of Claude's work on an open claim that is missing or out of date, a
    # page of claims at a time because one Apex run can only read so many. Returns 3 when it lists
    # any, 1 when the org could not be asked.
    local at=0 found=0 page
    while [ -n "${at}" ]; do
        ask "AntsuranceDemoPrep.outOfDate(${at}, ${AHEAD})" > "${WORK}/sweep.json" || return 1
        page=$(python3 -I -c '
import json, sys
sweep = json.load(open(sys.argv[1]))
for line in sweep["lines"]:
    print("  " + line)
print("NEXT %s %d %d" % ("" if sweep.get("next") is None else sweep["next"], len(sweep["lines"]), sweep["openClaims"]))
' "${WORK}/sweep.json")
        printf '%s\n' "${page}" | grep -v '^NEXT ' || true
        set -- $(printf '%s\n' "${page}" | grep '^NEXT ' | sed 's/^NEXT /x/')
        at="${1#x}"
        found=$((found + $2))
        open="$3"
    done
    if [ "${found}" -eq 0 ]; then
        echo "  Nothing: Claude's work on all ${open} open claims is current."
        return 0
    fi
    echo "  ${found} to put right across ${open} open claims."
    return 3
}

if [ -n "${CHECK}" ]; then
    echo "Checking the showcase claims in ${ORG}. Nothing is changed."
    ask "AntsuranceDemoPrep.check()" | lines
    echo "Claude's work that is missing or out of date, on any open claim:"
    status=0
    out_of_date || status=$?
    exit "${status}"
fi

echo "Preparing the showcase claims in ${ORG} ..."
echo "Sample files and the burst pipe estimate:"
ask "new List<String>{ AntsuranceDemoPrep.attach(), AntsuranceDemoPrep.settle() }" | lines

echo "Claude's work:"
ask "AntsuranceDemoPrep.steps()" > "${WORK}/steps.json"
python3 -I -c '
import json, sys
for step in json.load(open(sys.argv[1])):
    print("|".join([step["key"], "done" if step["done"] else "todo", step["caseNumber"], step["label"]]))
' "${WORK}/steps.json" > "${WORK}/steps.txt"

asked=0
while IFS='|' read -r key state number label; do
    [ -z "${key}" ] && continue
    if [ "${state}" = "done" ] && [ "${REFRESH}" != "true" ]; then
        echo "  ${number}: has ${label}."
        continue
    fi
    tries=0
    while :; do
        tries=$((tries + 1))
        ask "AntsuranceDemoPrep.run('${key}', ${REFRESH})" > "${WORK}/outcome.json" || { echo "  ${number}: ${label} could not be run." >&2; exit 1; }
        verdict=$(python3 -I -c '
import json, sys
outcome = json.load(open(sys.argv[1]))
if outcome.get("ok"):
    print("ok|" + ("Already on the claim." if outcome.get("skipped") else (outcome.get("line") or "Done.")))
else:
    print(("retry|" if outcome.get("retryable") else "stop|") + (outcome.get("error") or "It did not work."))
' "${WORK}/outcome.json")
        case "${verdict}" in
            ok\|*)
                echo "  ${number}: ${label}. ${verdict#ok|}"
                asked=$((asked + 1))
                break
                ;;
            retry\|*)
                if [ "${tries}" -lt 3 ]; then
                    echo "  ${number}: ${label} did not finish (${verdict#retry|}). Trying again in 15 seconds ..."
                    sleep 15
                    continue
                fi
                echo "  ${number}: ${label} failed three times: ${verdict#retry|}" >&2
                exit 1
                ;;
            *)
                echo "  ${number}: ${label} failed: ${verdict#stop|}" >&2
                exit 1
                ;;
        esac
    done
done < "${WORK}/steps.txt"
[ "${asked}" -eq 0 ] && echo "  Claude was not asked for anything: it was all there."

echo "A coverage check on every other open claim:"
ask "AntsuranceDemoPrep.checkCoverageEverywhere()" > "${WORK}/job.json"
job=$(python3 -I -c '
import json, sys
job = json.load(open(sys.argv[1]))
print("%s|%d|%s" % (job["jobId"], job["calls"], job["line"]))
' "${WORK}/job.json")
job_id="${job%%|*}"
rest="${job#*|}"
echo "  ${rest#*|}"
# One look when the job should be done, then one a minute. Nothing is asked faster than that.
sleep $(( ${rest%%|*} * 6 + 20 ))
looks=0
while :; do
    looks=$((looks + 1))
    ask "AntsuranceDemoPrep.coverageProgress('${job_id}')" > "${WORK}/progress.json"
    progress=$(python3 -I -c '
import json, sys
job = json.load(open(sys.argv[1]))
print(("done|" if job["finished"] else "running|") + job["line"])
' "${WORK}/progress.json")
    if [ "${progress%%|*}" = "done" ]; then
        echo "  ${progress#*|}"
        break
    fi
    if [ "${looks}" -ge 15 ]; then
        echo "  The coverage job is still running after fifteen looks: ${progress#*|}" >&2
        exit 1
    fi
    echo "  ${progress#*|} Looking again in a minute ..."
    sleep 60
done

echo "What the showcase claims now say:"
ask "AntsuranceDemoPrep.summary()" | lines
echo "Claude's work that is still missing or out of date, on any open claim:"
status=0
out_of_date || status=$?
[ "${status}" -eq 0 ] && echo "Done."
exit "${status}"
