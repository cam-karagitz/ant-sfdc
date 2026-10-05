#!/usr/bin/env python3
"""Measures the photo assessment on the sample damage photographs.

Each case is a claim described in words plus one or more of the antsuranceDamage static resources.
The cases run inside the org through AntsuranceClaimsAssistantPhotos.assessResources, which reads no
claim and writes nothing. Several cases share one Anonymous Apex run, because every `sf` command
spends the org's daily API allowance.

    python3 -I scripts/eval/photos/run.py <label> [--org <alias>] [--batch 5] [--only id,id]

Writes scripts/eval/photos/runs/<label>.json, the raw debug log beside it as <label>.log (not kept in
the repository), and, when Pillow is installed, a copy of each photo with Claude's boxes
drawn on it under runs/<label>-boxes/ (or --boxes), so a person can judge whether they land.
"""
import argparse
import html
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
RESOURCES = os.path.join(PROJECT, 'force-app', 'main', 'default', 'staticresources')
RANK = {'minor': 1, 'moderate': 2, 'severe': 3}


def apex_string(text):
    return "'" + text.replace('\\', '\\\\').replace("'", "\\'").replace('\n', '\\n') + "'"


def run_batch(cases, org):
    lines = []
    for case in cases:
        names = ', '.join(apex_string(name) for name in case['photos'])
        lines.append(
            'try { System.debug(\'EVALRESULT~' + case['id'] + '~\' + JSON.serialize(AntsuranceClaimsAssistantPhotos.assessResources('
            + apex_string(case['claim']) + ', new List<String>{ ' + names + ' }))); } '
            'catch (Exception e) { System.debug(\'EVALERROR~' + case['id'] + '~\' + e.getMessage()); }'
        )
    with tempfile.NamedTemporaryFile('w', suffix='.apex', delete=False) as handle:
        handle.write('\n'.join(lines))
        path = handle.name
    env = dict(os.environ, SF_DISABLE_TELEMETRY='true')
    done = subprocess.run(['sf', 'apex', 'run', '--file', path, '--target-org', org, '--json'], capture_output=True, text=True, cwd=PROJECT, env=env)
    os.unlink(path)
    try:
        logs = json.loads(done.stdout).get('result', {}).get('logs', '') or ''
    except ValueError:
        logs = ''
    found = {}
    # The debug log escapes some characters as HTML entities (a pipe arrives as &#124;), so the marker
    # uses tildes and the line is unescaped before it is read.
    for line in logs.split('\n'):
        match = re.search(r'\|DEBUG\|EVAL(RESULT|ERROR)~([^~]+)~(.*)', html.unescape(line))
        if match:
            kind, case_id, payload = match.groups()
            try:
                found[case_id] = json.loads(payload) if kind == 'RESULT' else {'error': payload}
            except ValueError:
                found[case_id] = {'error': 'The result could not be read: ' + payload[:200]}
    for case in cases:
        found.setdefault(case['id'], {'error': 'No result came back: ' + (done.stdout[:300] or done.stderr[:300])})
    return found, logs


def grade(case, result):
    """Returns the list of checks that failed. Empty means the case passed."""
    if 'error' in result:
        return ['error: ' + result['error']]
    expect = case['expect']
    failed = []
    photos = result.get('photos') or []
    if len(photos) != len(case['photos']):
        failed.append(f'{len(photos)} photos read, {len(case["photos"])} sent')
    damage = [area for photo in photos for area in (photo.get('damage') or [])]
    boxes = [area['box'] for area in damage if area.get('box')]
    for box in boxes:
        inside = 0 <= box['x'] <= 1 and 0 <= box['y'] <= 1 and box['width'] > 0 and box['height'] > 0 and box['x'] + box['width'] <= 1.001 and box['y'] + box['height'] <= 1.001
        if not inside:
            failed.append(f'a box lies outside the image: {box}')
    areas = ' | '.join(((area.get('area') or '') + ' ' + (area.get('detail') or '')).lower() for area in damage)
    worst = max([RANK.get(area.get('severity'), 0) for area in damage] or [0])
    if 'usable' in expect and any(bool(photo.get('usable')) != expect['usable'] for photo in photos):
        failed.append(f'usable should be {expect["usable"]}')
    if 'consistency' in expect and result.get('consistency') not in expect['consistency']:
        failed.append(f'consistency {result.get("consistency")}, wanted {expect["consistency"]}')
    if 'loss_any' in expect and not any(word in (result.get('lossSeen') or '').lower() for word in expect['loss_any']):
        failed.append(f'loss seen "{result.get("lossSeen")}", wanted one of {expect["loss_any"]}')
    if 'area_any' in expect and not any(word in areas for word in expect['area_any']):
        failed.append(f'no damaged area mentions any of {expect["area_any"]}: {areas}')
    if 'panel_any' in expect and not any(area.get('panel') in expect['panel_any'] for area in damage):
        failed.append(f'no panel among {expect["panel_any"]}: {[area.get("panel") for area in damage]}')
    if 'panel_all' in expect and any(area.get('panel') not in expect['panel_all'] for area in damage):
        failed.append(f'panels should all be {expect["panel_all"]}: {[area.get("panel") for area in damage]}')
    if 'severity_min' in expect and worst < RANK[expect['severity_min']]:
        failed.append(f'worst severity rank {worst}, wanted at least {expect["severity_min"]}')
    if 'severity_max' in expect and worst > RANK[expect['severity_max']]:
        failed.append(f'worst severity rank {worst}, wanted at most {expect["severity_max"]}')
    if 'next_step' in expect and result.get('nextStep') not in expect['next_step']:
        failed.append(f'next step {result.get("nextStep")}, wanted {expect["next_step"]}')
    if 'boxes_min' in expect and len(boxes) < expect['boxes_min']:
        failed.append(f'{len(boxes)} boxes, wanted at least {expect["boxes_min"]}')
    if 'boxes_max' in expect and len(boxes) > expect['boxes_max']:
        failed.append(f'{len(boxes)} boxes, wanted at most {expect["boxes_max"]}')
    if 'repair_high_min' in expect and (result.get('repairHigh') or 0) < expect['repair_high_min']:
        failed.append(f'repair range tops out at {result.get("repairHigh")}, wanted at least {expect["repair_high_min"]}')
    if expect.get('needs_photos') and not result.get('photosNeeded'):
        failed.append('no further photos asked for')
    return failed


def draw_boxes(case, result, folder):
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return
    colours = {'minor': (226, 211, 168), 'moderate': (217, 162, 51), 'severe': (174, 95, 70)}
    os.makedirs(folder, exist_ok=True)
    for photo, name in zip(result.get('photos') or [], case['photos']):
        path = os.path.join(RESOURCES, name + '.jpg')
        if not os.path.exists(path):
            continue
        image = Image.open(path).convert('RGB')
        draw = ImageDraw.Draw(image)
        width, height = image.size
        for order, area in enumerate(photo.get('damage') or [], start=1):
            box = area.get('box')
            if not box:
                continue
            left, top = box['x'] * width, box['y'] * height
            right, bottom = left + box['width'] * width, top + box['height'] * height
            colour = colours.get(area.get('severity'), (255, 255, 255))
            draw.rectangle([left - 1, top - 1, right + 1, bottom + 1], outline=(255, 255, 255), width=6)
            draw.rectangle([left, top, right, bottom], outline=colour, width=4)
            draw.text((left + 8, top + 6), f'{order} {area.get("area")}', fill=(255, 255, 255), stroke_width=3, stroke_fill=(20, 20, 19))
        image.thumbnail((1000, 1000))
        image.save(os.path.join(folder, f'{case["id"]}-{name}.jpg'), quality=80)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('label')
    parser.add_argument('--org', default=os.environ.get('SF_TARGET_ORG'), required=not os.environ.get('SF_TARGET_ORG'))
    parser.add_argument('--batch', type=int, default=5)
    parser.add_argument('--only', default='')
    parser.add_argument('--boxes', default='', help='Folder for the photos with boxes drawn on; defaults to runs/<label>-boxes')
    args = parser.parse_args()

    cases = json.load(open(os.path.join(HERE, 'cases.json')))
    if args.only:
        wanted = set(args.only.split(','))
        cases = [case for case in cases if case['id'] in wanted]
    results = {}
    os.makedirs(os.path.join(HERE, 'runs'), exist_ok=True)
    with open(os.path.join(HERE, 'runs', args.label + '.log'), 'w') as raw:
        for start in range(0, len(cases), args.batch):
            found, logs = run_batch(cases[start:start + args.batch], args.org)
            results.update(found)
            # Kept so that a run that cannot be read does not have to be paid for twice.
            raw.write(logs + '\n')

    report = []
    for case in cases:
        result = results[case['id']]
        failed = grade(case, result)
        report.append({'id': case['id'], 'passed': not failed, 'failed': failed, 'result': result})
        print(('PASS ' if not failed else 'FAIL ') + case['id'] + ('' if not failed else ': ' + '; '.join(failed)))
        draw_boxes(case, result, args.boxes or os.path.join(HERE, 'runs', args.label + '-boxes'))
    passed = sum(1 for row in report if row['passed'])
    print(f'{passed} of {len(report)} cases passed')
    os.makedirs(os.path.join(HERE, 'runs'), exist_ok=True)
    json.dump({'label': args.label, 'passed': passed, 'total': len(report), 'cases': report}, open(os.path.join(HERE, 'runs', args.label + '.json'), 'w'), indent=1)
    return 0 if passed == len(report) else 1


if __name__ == '__main__':
    sys.exit(main())
