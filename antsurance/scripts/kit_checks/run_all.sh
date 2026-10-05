#!/bin/bash
# Runs every offline check of the customer kit's installer against the kit in the working tree (kit/).
# No org, no sf command, no key. See README.md here for what this proves and what only a scratch org can.
#
# Usage: scripts/kit_checks/run_all.sh [-v]     (-v prints each case, not only the verdicts)
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO" || exit 1
export PYTHONDONTWRITEBYTECODE=1
VERBOSE="${1:-}"
bad=0

part() { # part <title> <command...>
    local title="$1"; shift
    echo "--- $title"
    if ! "$@"; then bad=$((bad + 1)); echo "    ^ FAILED: $title"; fi
}

parses() { python3 -c 'import ast, sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        ast.parse(handle.read(), path)
print("installer scripts: %d files parse" % len(sys.argv[1:]))' kit/scripts/setup/*.py; }

selftest() { # The self-test reads the kit's manifest, which only a built kit has: run the working tree's scripts
    # from a throwaway kit whose every other file is the last build's (dist/antsurance-kit), linked, not copied.
    local built="$REPO/dist/antsurance-kit" work entry code
    if [ ! -f "$built/kit-manifest.json" ]; then
        echo "self-test NOT run: there is no built kit in dist/. Build one first: python3 -I scripts/build_kit.py"
        return 1
    fi
    work="$(mktemp -d)"
    mkdir -p "$work/kit/scripts"
    for entry in "$built"/* "$built"/.[!.]*; do
        case "$(basename "$entry")" in scripts|.install|stage) ;; *) ln -s "$entry" "$work/kit/" ;; esac
    done
    cp -R kit/scripts/setup "$work/kit/scripts/setup"
    python3 "$work/kit/scripts/setup/selftest.py" > "$work/out.txt" 2>&1; code=$?
    if [ "$code" = 0 ]; then echo "self-test: $(grep '^Ran ' "$work/out.txt"), $(tail -n 1 "$work/out.txt")"; else cat "$work/out.txt"; fi
    rm -rf "$work"
    return "$code"
}

part "The scratch script's decisions (test_in_scratch_org.sh, with stand-ins for python3 and sf)" "$HERE/scratch_script.sh" $VERBOSE
part "The uninstall's decisions (uninstall.py, with a stand-in org)" python3 "$HERE/uninstall_offline.py" $VERBOSE
part "The build's handling of skills (build_kit.py copy_skills, in throwaway folders)" python3 "$HERE/build_skills_offline.py" $VERBOSE
part "The kit's own self-test (kit/scripts/setup/selftest.py, run beside the last build's manifest)" selftest
part "Every installer script parses" parses

echo
if [ "$bad" = 0 ]; then echo "Kit checks: all five parts passed. Nothing here touched an org."; else echo "Kit checks: $bad of five parts FAILED."; fi
[ "$bad" = 0 ]
