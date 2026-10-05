#!/usr/bin/env bash
# Reloads the Antsurance demo data and refreshes every Antsurance dashboard, so the org is
# ready to show. Usage: scripts/reload_demo.sh --yes [org alias]   (default: $SF_TARGET_ORG)
#
# This DELETES every CRM record in the org and loads a new set. For a minute or two in between the
# org is empty, and every record gets a new Id, so anyone using the org sees blank pages and dead
# links. Run it only when the person who owns the org has asked for a reload, never as a routine
# step. It refuses to run without --yes.
#
# It fails loudly: a clear or load that did not succeed, storage that never frees up, or no dashboards
# refreshed, each exits non-zero.
set -euo pipefail

if [ "${1:-}" != "--yes" ]; then
    echo "This deletes every CRM record in the org and reloads the demo set; the org is empty for a minute or two." >&2
    echo "Run it only when the org's owner has asked for a reload: scripts/reload_demo.sh --yes [org alias]" >&2
    exit 2
fi
shift
ORG="${1:-${SF_TARGET_ORG:-}}"
if [ -z "${ORG}" ]; then
    echo "Set SF_TARGET_ORG, or pass the org alias as an argument." >&2
    exit 2
fi
FOLDERS="'Leadership','Underwriting and Sales','Claims and Service'"
cd "$(dirname "$0")/.."
export SF_DISABLE_TELEMETRY=true

run_apex() {
    # Runs an Anonymous Apex file and prints nothing on success; on failure prints the error and returns 1.
    sf apex run --file "$1" --target-org "${ORG}" --json 2>/dev/null | python3 -I -c '
import json, sys
reply = json.load(sys.stdin)
result = reply.get("result") or {}
if not result.get("success"):
    print(result.get("exceptionMessage") or result.get("compileProblem") or reply.get("message") or "unknown error")
    sys.exit(1)
# The load prints its own checks; pass them on so one run answers what would otherwise take a dozen queries.
for line in (result.get("logs") or "").splitlines():
    for tag in ("RESET ", "COUNTS ", "LOSS ", "CHECKS "):
        if "|" + tag in line or line.startswith(tag):
            print("  " + line[line.index(tag):])
'
}

# A Developer Edition org has 5 MB of data storage, about 2,500 records, and the demo data fills most
# of it. Salesforce counts storage a minute or so behind, so deleting and loading in one step fails
# with STORAGE_LIMIT_EXCEEDED when the org is nearly full. Clear first, wait, then load.
#
# The org also allows only 15,000 API calls in any 24 hours, and every sf command spends several, so
# this script waits on a timer and retries the load instead of polling the storage limit.
echo "Clearing the demo data in ${ORG} (this deletes every CRM record) ..."
run_apex scripts/clear_demo_data.apex || { echo "The clear failed." >&2; exit 1; }

loaded=""
for wait in 75 60 90; do
    echo "Waiting ${wait} seconds for Salesforce to recount storage ..."
    sleep "${wait}"
    echo "Loading the demo data ..."
    if error=$(run_apex scripts/reset_demo_data.apex); then
        loaded="yes"
        echo "${error}"
        break
    fi
    case "${error}" in
        *STORAGE_LIMIT_EXCEEDED*) echo "  Storage has not been recounted yet." ;;
        *) echo "The load failed: ${error}" >&2; exit 1 ;;
    esac
done
if [ -z "${loaded}" ]; then
    echo "The load still fails on storage after about four minutes. Something else is using it; check Setup, Storage Usage." >&2
    exit 1
fi
echo "Demo data loaded."

echo "Refreshing dashboards ..."
ids=$(sf data query -q "SELECT Id, Title FROM Dashboard WHERE FolderName IN (${FOLDERS})" --target-org "${ORG}" --json 2>/dev/null |
    python3 -I -c 'import json, sys; print("\n".join(r["Id"] + "|" + r["Title"] for r in json.load(sys.stdin)["result"]["records"]))')

refreshed=0
while IFS='|' read -r id title; do
    [ -z "${id}" ] && continue
    # A PUT on the dashboard asks Salesforce to re-run its reports. It is queued, so tiles catch up within a minute.
    if sf api request rest "/services/data/v64.0/analytics/dashboards/${id}" --method PUT --body "{}" --target-org "${ORG}" 2>/dev/null | grep -q statusUrl; then
        echo "  refreshed: ${title}"
        refreshed=$((refreshed + 1))
    else
        echo "  COULD NOT refresh: ${title}" >&2
    fi
done <<< "${ids}"

if [ "${refreshed}" -eq 0 ]; then
    echo "No dashboards were refreshed. Check that the dashboards are deployed and the folder names above still match." >&2
    exit 1
fi
echo "Done: ${refreshed} dashboards refreshing."
echo "Next: scripts/prepare_demo.sh ${ORG} puts the showcase claims into their demo state (sample files, the burst pipe estimate, and Claude's work on each)."
