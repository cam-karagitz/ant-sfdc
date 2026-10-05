#!/usr/bin/env python3
"""Vendor forcedotcom/sf-skills into this project's .claude/skills.

Copies every upstream skill into .claude/skills/<name>/ so the skills load only
for Claude Code sessions started in (or below) this directory. Nothing is
installed at user scope. Skills that a plugin enabled for this project already
provides (see enabledPlugins in .claude/settings.json) are skipped, so each
skill is listed once; re-run after installing, updating or removing a plugin.

    scripts/sync_sf_skills.py                 # latest main
    scripts/sync_sf_skills.py --ref 1.58.0    # a tag, branch or commit
    scripts/sync_sf_skills.py --dry-run       # show what would change
    scripts/sync_sf_skills.py --reset-tiers   # re-apply the default tiers

State lives in two files:
  .claude/sf-skills.lock.json   what was vendored and from which commit
  .claude/settings.local.json   skillOverrides: skills outside
                                scripts/sf-skills-core.txt are pinned to
                                name-only, so 240 descriptions do not swamp the
                                skill listing budget. Change a tier with /skills.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = "https://github.com/forcedotcom/sf-skills.git"
ROOT = Path(__file__).resolve().parent.parent
SKILLS_DIR = ROOT / ".claude" / "skills"
LOCK = ROOT / ".claude" / "sf-skills.lock.json"
SETTINGS = ROOT / ".claude" / "settings.local.json"
CORE = Path(__file__).with_name("sf-skills-core.txt")
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def git(*args, cwd):
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def fetch(ref, dest):
    """Shallow-fetch one ref (branch, tag or commit), checking out only skills/."""
    git("init", "-q", cwd=dest)
    git("remote", "add", "origin", REPO, cwd=dest)
    git("sparse-checkout", "set", "skills", cwd=dest)
    git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", ref, cwd=dest)
    git("checkout", "-q", "FETCH_HEAD", cwd=dest)


def read_json(path, default):
    return json.loads(path.read_text()) if path.exists() else default


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")


def read_core():
    lines = CORE.read_text().splitlines() if CORE.exists() else []
    return {ln.strip() for ln in lines if ln.strip() and not ln.startswith("#")}


def plugin_provided():
    """Skills supplied by plugins enabled for this project, as {skill: plugin}.

    A skill a plugin already provides is not vendored, so it is listed once.
    """
    enabled = {}
    for path in (ROOT / ".claude" / "settings.json", SETTINGS):  # local wins
        enabled.update(read_json(path, {}).get("enabledPlugins", {}))
    registry = read_json(Path.home() / ".claude" / "plugins" / "installed_plugins.json", {})
    provided = {}
    for key in sorted(k for k, on in enabled.items() if on):
        for inst in registry.get("plugins", {}).get(key, []):
            if inst.get("scope") != "user" and inst.get("projectPath") != str(ROOT):
                continue
            skills = Path(inst.get("installPath", "")) / "skills"
            if skills.is_dir():
                for d in skills.iterdir():
                    if (d / "SKILL.md").is_file():
                        provided[d.name] = key
    return provided


def upstream_skills(src):
    """Skill directories that are safe to copy: plain names, no symlinks."""
    found, skipped = {}, []
    for d in sorted((src / "skills").iterdir()):
        if not (d / "SKILL.md").is_file():
            continue
        if not NAME_RE.match(d.name):
            skipped.append((d.name, "unexpected directory name"))
        elif d.is_symlink() or any(p.is_symlink() for p in d.rglob("*")):
            skipped.append((d.name, "contains a symlink"))
        else:
            found[d.name] = d
    return found, skipped


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ref", default="main", help="branch, tag or commit (default: main)")
    ap.add_argument("--source", type=Path, help="use an existing local clone instead of fetching")
    ap.add_argument("--dry-run", action="store_true", help="report changes without writing")
    ap.add_argument("--reset-tiers", action="store_true", help="re-apply default tiers to every vendored skill")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory(prefix="sf-skills-") as tmp:
        src = args.source.resolve() if args.source else Path(tmp)
        if not args.source:
            print(f"Fetching {REPO} @ {args.ref} ...")
            fetch(args.ref, src)
        try:
            commit = git("rev-parse", "HEAD", cwd=src)
        except (subprocess.CalledProcessError, FileNotFoundError):
            commit = "unknown"

        upstream, skipped = upstream_skills(src)
        if not upstream:
            sys.exit(f"No skills found under {src / 'skills'}; nothing changed.")

        lock = read_json(LOCK, {})
        prev = set(lock.get("skills", []))
        core = read_core()

        # A directory we did not vendor is someone's own skill: leave it alone.
        local = {n for n in upstream if (SKILLS_DIR / n).exists() and n not in prev}
        for name in sorted(local):
            skipped.append((name, "a local skill of the same name already exists"))
        provided = plugin_provided()
        wanted = {n: p for n, p in upstream.items() if n not in local and n not in provided}
        added = sorted(set(wanted) - prev)
        removed = sorted(prev - set(wanted))

        if not args.dry_run:
            SKILLS_DIR.mkdir(parents=True, exist_ok=True)
            for name, path in wanted.items():
                dst = SKILLS_DIR / name
                if dst.exists():
                    shutil.rmtree(dst)
                shutil.copytree(path, dst)
            for name in removed:
                shutil.rmtree(SKILLS_DIR / name, ignore_errors=True)

            settings = read_json(SETTINGS, {})
            overrides = settings.get("skillOverrides", {})
            for name in removed:
                overrides.pop(name, None)
            for name in sorted(wanted) if args.reset_tiers else added:
                if name in core:
                    overrides.pop(name, None)  # absent means "on"
                elif args.reset_tiers or name not in overrides:
                    overrides[name] = "name-only"
            settings["skillOverrides"] = dict(sorted(overrides.items()))
            write_json(SETTINGS, settings)

            write_json(LOCK, {
                "source": REPO,
                "ref": args.ref,
                "commit": commit,
                "synced_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "skills": sorted(wanted),
            })

    verb = "Would vendor" if args.dry_run else "Vendored"
    print(f"{verb} {len(wanted)} skills at {commit[:12]} (was {lock.get('commit', 'none')[:12]})")
    print(f"  added:   {len(added)}" + (f"  {', '.join(added)}" if 0 < len(added) <= 15 else ""))
    print(f"  removed: {len(removed)}" + (f"  {', '.join(removed)}" if removed else ""))
    print(f"  core (description eligible): {len(core & set(wanted))}   pinned name-only: {len(set(wanted) - core)}")
    for plugin in sorted(set(provided.values())):
        names = [n for n, p in provided.items() if p == plugin]
        print(f"  not vendored, provided by {plugin}: {len(names)}")
    for name, why in skipped:
        print(f"  SKIPPED {name}: {why}")
    for name in sorted(core - set(upstream)):
        print(f"  NOTE {name} is in sf-skills-core.txt but no longer upstream (renamed?)")
    if skipped:
        sys.exit(1)


if __name__ == "__main__":
    main()
