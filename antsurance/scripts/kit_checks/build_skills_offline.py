#!/usr/bin/env python3
"""Checks how scripts/build_kit.py carries the skills into the kit, against throwaway folders.

copy_skills() must build the kit's readable skill as the same bytes as the kit's static resource, and must stop
the build when the source skill and the static resource differ, when a skill folder holds a second file, or when
either file is missing. The real skills/, force-app/ and dist/ are only read: the build's paths are pointed at a
temporary folder for each case.

Usage: python3 scripts/kit_checks/build_skills_offline.py [-v]
"""
import contextlib
import io
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..'))
import build_kit as build  # noqa: E402

VERBOSE = '-v' in sys.argv[1:]
FOLDER, RESOURCE = build.UPLOADED_SKILLS[0]
REAL_SKILL = os.path.join(build.SKILLS_SRC, FOLDER, 'SKILL.md')
failed = []


def case(label, change, builds):
    tmp = tempfile.mkdtemp()
    build.SKILLS_SRC = os.path.join(tmp, 'skills')
    build.SRC = os.path.join(tmp, 'src')
    build.OUT = os.path.join(tmp, 'out')
    build.CORE = os.path.join(build.OUT, 'force-app', 'main', 'default')
    # The built static resource stands for what copy_metadata() made: here, the source text with one word changed.
    built = os.path.join(build.CORE, 'staticresources', RESOURCE)
    for target in (os.path.join(build.SKILLS_SRC, FOLDER, 'SKILL.md'), os.path.join(build.SRC, 'staticresources', RESOURCE), built):
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(REAL_SKILL, target)
    with open(built, 'a') as handle:
        handle.write('\nA line only the built resource has.\n')
    change(tmp)
    said = io.StringIO()
    try:
        with contextlib.redirect_stdout(said), contextlib.redirect_stderr(said):
            build.copy_skills()
        out = os.path.join(build.OUT, 'skills', FOLDER)
        with open(os.path.join(out, 'SKILL.md'), 'rb') as one, open(built, 'rb') as other:
            same = one.read() == other.read()
        got = 'builds' if same and os.listdir(out) == ['SKILL.md'] else 'builds something else: %s, same bytes as the kit resource: %s' % (sorted(os.listdir(out)), same)
    except SystemExit as stop:
        got = 'stops' if stop.code else 'exits 0 without building'
    shutil.rmtree(tmp)
    want = 'builds' if builds else 'stops'
    if VERBOSE or got != want:
        print('=== %s -> %s%s' % (label, got, ('  (' + ' '.join(said.getvalue().split())[:160] + ')') if said.getvalue().strip() else ''))
    if got != want:
        print('FAILED  %s: expected "%s"' % (label, want))
        failed.append(label)


def write(path, text, mode='w'):
    with open(path, mode) as handle:
        handle.write(text)


case('1 as it is: one file, the same bytes as the kit static resource', lambda tmp: None, True)
case('2 the source skill edited, the static resource not', lambda tmp: write(os.path.join(tmp, 'skills', FOLDER, 'SKILL.md'), '\nOne more rule.\n', 'a'), False)
case('3 a second file beside SKILL.md', lambda tmp: write(os.path.join(tmp, 'skills', FOLDER, 'reference.md'), 'More.\n'), False)
case('4 the source static resource missing', lambda tmp: os.remove(os.path.join(tmp, 'src', 'staticresources', RESOURCE)), False)
case('5 the source skill missing', lambda tmp: os.remove(os.path.join(tmp, 'skills', FOLDER, 'SKILL.md')), False)

print('build, skills: 5 cases, %d failed' % len(failed))
sys.exit(1 if failed else 0)
