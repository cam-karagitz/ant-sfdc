#!/bin/bash
# Prints the sample submission (a broker's email, an application and a loss run) to PDF and puts the
# three files where the app serves them from. Every company and person in them is invented.
# Needs Google Chrome. Run from anywhere: scripts/submission_samples/build.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../force-app/main/default/staticresources"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT
print() {
    "$CHROME" --headless --disable-gpu --no-pdf-header-footer --user-data-dir="$PROFILE" --print-to-pdf="$OUT/$2.pdf" "file://$HERE/$1.html" >/dev/null 2>&1
    echo "$2.pdf $(wc -c < "$OUT/$2.pdf" | tr -d ' ') bytes"
}
print application antsuranceSubmissionApplication
print lossrun antsuranceSubmissionLossRun
print cover antsuranceSubmissionCoverNote
