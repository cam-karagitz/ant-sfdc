#!/bin/bash
# Saves everything in the working tree, finished or not, to the `in-flight` branch on the remote,
# without touching `main`, the index or any file. Run it while workers are mid-task so their work
# is in the repo before it has been checked and committed to `main`.
#
# Each snapshot is one commit whose tree is the working tree as it stands and whose parent is the
# previous snapshot, so every push is a fast-forward. `main` stays the checked history.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

VISIBILITY="$(gh repo view --json visibility --jq .visibility)"
if [ "$VISIBILITY" != "PRIVATE" ]; then
  echo "Refusing to push: the remote is $VISIBILITY, not PRIVATE." >&2
  exit 1
fi

INDEX="$(mktemp -t in-flight-index)"
trap 'rm -f "$INDEX"' EXIT
export GIT_INDEX_FILE="$INDEX"
git read-tree HEAD
# Left out on purpose: a lock file, and screenshots kept for the owner to post himself.
git add -A -- . ':!.claude/scheduled_tasks.lock' ':!antsurance/docs/screenshots/reddit'

LEAKS="$(git diff --cached --name-only -z HEAD | xargs -0 grep -l -I -E 'sk-ant-[A-Za-z0-9_-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY|00D[A-Za-z0-9]{12,15}![A-Za-z0-9._]{20,}' 2>/dev/null || true)"
if [ -n "$LEAKS" ]; then
  echo "Refusing to push: these files look like they hold a key or token:" >&2
  echo "$LEAKS" >&2
  exit 1
fi

TREE="$(git write-tree)"
PARENT="$(git rev-parse -q --verify refs/heads/in-flight || git rev-parse HEAD)"
if [ "$(git rev-parse "$PARENT^{tree}")" = "$TREE" ]; then
  echo "Nothing new since the last snapshot ($(git rev-parse --short "$PARENT"))."
  exit 0
fi
COUNT="$(git diff --cached --name-only HEAD | wc -l | tr -d ' ')"
COMMIT="$(git commit-tree "$TREE" -p "$PARENT" -m "In-flight snapshot: $COUNT paths ahead of main at $(git rev-parse --short HEAD)

Work in progress from running workers, not yet checked. The checked history is on main.")"
git update-ref refs/heads/in-flight "$COMMIT"
unset GIT_INDEX_FILE
git push -q origin in-flight
echo "Saved $COUNT paths to in-flight as $(git rev-parse --short "$COMMIT")."
