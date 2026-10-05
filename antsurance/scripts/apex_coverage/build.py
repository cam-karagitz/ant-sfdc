"""Build a check-only validation manifest and its test list, leaving out anything
modified in the working tree right now.

usage: python3 -I scripts/apex_coverage/build.py <name> main|slow|<Class,Class,...> [tests=<T,T,...>]
Run from the antsurance project root. Writes scripts/apex_coverage/out/<name>.xml, <name>.tests and <name>.left-out.
"""
import glob
import os
import re
import subprocess
import sys

# What this writes goes beside the script, in a folder git ignores.
S = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'out')
os.makedirs(S, exist_ok=True)
CLS = 'force-app/main/default/classes'
TRG = 'force-app/main/default/triggers'

SLOW_PROD = {'AntsuranceDemoData', 'AntsuranceDemoAddresses', 'AntsuranceDemoPrep',
             'AntsuranceInsightsController'}
SLOW_TESTS = {'AntsuranceDemoDataTest', 'AntsuranceDemoAddressesTest', 'AntsuranceDemoPrepTest',
              'AntsuranceInsightsControllerTest'}
NEVER = {'AntsuranceRenewalJob'}


def is_test(name):
    src = open(f'{CLS}/{name}.cls').read()
    return bool(re.search(r'@isTest', src[:600], re.I))


def modified():
    out = subprocess.run(['git', 'status', '--short', '--', 'force-app/main/default/classes',
                          'force-app/main/default/triggers'],
                         capture_output=True, text=True, check=True).stdout
    names = set()
    for line in out.splitlines():
        path = line[3:].strip().split(' -> ')[-1]
        base = os.path.basename(path)
        base = re.sub(r'-meta\.xml$', '', base)
        base = re.sub(r'\.(cls|trigger)$', '', base)
        names.add(base)
    return names


def main():
    name, group = sys.argv[1], sys.argv[2]
    mine = set()
    tests_arg = None
    for a in sys.argv[3:]:
        if a.startswith('mine='):
            mine = set(a[5:].split(','))
        if a.startswith('tests='):
            tests_arg = a[6:].split(',')
    local = sorted(os.path.basename(p)[:-4] for p in glob.glob(f'{CLS}/*.cls'))
    tests = [n for n in local if is_test(n)]
    prod = [n for n in local if n not in tests]
    trig = sorted(os.path.basename(p)[:-8] for p in glob.glob(f'{TRG}/*.trigger'))
    changed = modified() - mine
    if group == 'main':
        classes = [n for n in prod if n not in SLOW_PROD and n not in NEVER]
        triggers = trig
        named = [n for n in tests if n not in SLOW_TESTS]
    elif group == 'slow':
        classes = sorted(SLOW_PROD)
        triggers = []
        named = sorted(SLOW_TESTS)
    else:
        wanted = group.split(',')
        classes = [n for n in wanted if n in local]
        triggers = [n for n in wanted if n in trig]
        named = tests_arg or []
    if tests_arg is not None and group in ('main', 'slow'):
        named = tests_arg
    left = sorted(n for n in classes + triggers + named if n in changed)
    classes = [n for n in classes if n not in changed and n not in NEVER]
    triggers = [n for n in triggers if n not in changed]
    named = [n for n in named if n not in changed]
    x = ['<?xml version="1.0" encoding="UTF-8"?>',
         '<Package xmlns="http://soap.sforce.com/2006/04/metadata">', '  <types>']
    x += [f'    <members>{c}</members>' for c in classes]
    x += ['    <name>ApexClass</name>', '  </types>']
    if triggers:
        x += ['  <types>'] + [f'    <members>{t}</members>' for t in triggers]
        x += ['    <name>ApexTrigger</name>', '  </types>']
    x += ['  <version>67.0</version>', '</Package>']
    open(f'{S}/{name}.xml', 'w').write('\n'.join(x) + '\n')
    open(f'{S}/{name}.tests', 'w').write(' '.join(f'--tests {t}' for t in named))
    open(f'{S}/{name}.left-out', 'w').write('\n'.join(left) + '\n')
    print(f'{name}: {len(classes)} classes, {len(triggers)} triggers, {len(named)} tests named')
    print('modified in the working tree now:', sorted(changed) or 'nothing')
    print('left out of this validation:', left or 'nothing')


main()
