#!/usr/bin/env python3
"""Scores a run of the box placement eval and draws a contact sheet for each way of asking.

    python3 score.py runs/<name> [sheets folder]

For every photo, each true box is paired with the box of Claude's that overlaps it most. The score is
the overlap of the pair: the area the two boxes share over the area they cover together
(intersection over union), 1 for the same box and 0 for no overlap. A true box with no partner is a
miss. A box of Claude's with no partner is a false box, unless it sits on a place cases.json lists as
optional (damage that is plausible but cannot be confirmed from the photo).

It prints the table as Markdown, writes it with the per-photo detail to <run>/scores.json, and saves
one sheet per method: every photo with the true boxes in green (optional places dashed) and Claude's
boxes in orange, each with its overlap figure.
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
METHODS = [
    ('fraction', 'Fractions of the image'),
    ('pixel', 'Pixels, with the size given'),
    ('grid', 'Numbered grid over the photo'),
    ('refine', 'Two passes: pixels, then a crop'),
    ('pixel_tight', 'Pixels, and a box for each part'),
]
PAIR_AT = 0.1
GOOD_AT = 0.5
GRID_CELLS = 10
TRUE = (46, 160, 67)
CLAUDE = (232, 120, 24)
TILE = 470
COLUMNS = 4


def font(size):
    try:
        return ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', size)
    except OSError:
        return ImageFont.load_default()


def iou(one, other):
    wide = max(0, min(one[0] + one[2], other[0] + other[2]) - max(one[0], other[0]))
    high = max(0, min(one[1] + one[3], other[1] + other[3]) - max(one[1], other[1]))
    shared = wide * high
    covered = one[2] * one[3] + other[2] * other[3] - shared
    return shared / covered if covered > 0 else 0


def inside(point, box):
    return box[0] <= point[0] <= box[0] + box[2] and box[1] <= point[1] <= box[1] + box[3]


def clamp(box):
    left, top = min(max(box[0], 0), 1), min(max(box[1], 0), 1)
    return [left, top, min(max(box[2], 0), 1 - left), min(max(box[3], 0), 1 - top)]


def boxes_for(method, kept):
    """Claude's boxes for one method as fractions of the image, each with its name. None when the answer could not be read."""
    answers = kept.get('answers', {})
    width, height = kept['width'], kept['height']
    try:
        coarse = json.loads(answers['pixel' if method == 'refine' else method]['text'])['photos'][0]['damage']
    except (KeyError, IndexError, ValueError, TypeError):
        return None
    found = []
    if method == 'refine':
        try:
            refined = {area['number']: area for area in json.loads(answers['refine']['text'])['areas']}
        except (KeyError, ValueError, TypeError):
            return None
        crops = answers['refine'].get('crops', [])
        for number, area in enumerate(coarse, start=1):
            box = area['box']
            tight = refined.get(number)
            if tight and tight.get('found') and number <= len(crops) and tight['box']['width'] > 0 and tight['box']['height'] > 0:
                crop = crops[number - 1]
                box = {'x': crop['left'] + tight['box']['x'] / crop['scale'], 'y': crop['top'] + tight['box']['y'] / crop['scale'],
                       'width': tight['box']['width'] / crop['scale'], 'height': tight['box']['height'] / crop['scale']}
            found.append((area['area'], clamp([box['x'] / width, box['y'] / height, box['width'] / width, box['height'] / height])))
        return found
    for area in coarse:
        box = area['box']
        if method.startswith('pixel'):
            sides = [box['x'] / width, box['y'] / height, box['width'] / width, box['height'] / height]
        elif method == 'grid':
            sides = [box['x'] / GRID_CELLS, box['y'] / GRID_CELLS, box['width'] / GRID_CELLS, box['height'] / GRID_CELLS]
        else:
            sides = [box['x'], box['y'], box['width'], box['height']]
        found.append((area['area'], clamp(sides)))
    return found


def judge(case, found):
    """Pairs true boxes with Claude's, best overlap first."""
    pairs = sorted(((iou(truth['box'], box), at, to) for at, truth in enumerate(case['truth']) for to, (unused, box) in enumerate(found)), reverse=True)
    partner, taken = {}, set()
    for overlap, at, to in pairs:
        if overlap >= PAIR_AT and at not in partner and to not in taken:
            partner[at] = (to, overlap)
            taken.add(to)
    rows = []
    for at, truth in enumerate(case['truth']):
        if at in partner:
            to, overlap = partner[at]
            box = found[to][1]
            rows.append({'truth': truth['label'], 'claude': found[to][0], 'iou': round(overlap, 3),
                         'center_inside': inside((box[0] + box[2] / 2, box[1] + box[3] / 2), truth['box'])})
        else:
            rows.append({'truth': truth['label'], 'claude': None, 'iou': 0.0, 'center_inside': False})
    false = []
    for to, (name, box) in enumerate(found):
        if to in taken:
            continue
        center = (box[0] + box[2] / 2, box[1] + box[3] / 2)
        allowed = any(iou(box, place['box']) >= PAIR_AT or inside(center, place['box']) for place in case.get('optional', []))
        # A second box on damage that is already paired is a repeat, not an invention.
        repeat = any(iou(box, truth['box']) >= PAIR_AT or inside(center, truth['box']) for truth in case['truth'])
        if not allowed and not repeat:
            false.append(name)
    return rows, false, taken


def sheet(method, title, cases, results, folder, run_name):
    rows = (len(cases) + COLUMNS - 1) // COLUMNS
    tile_height = TILE * 3 // 4 + 96
    page = Image.new('RGB', (COLUMNS * (TILE + 16) + 16, rows * (tile_height + 16) + 76), (250, 249, 245))
    draw = ImageDraw.Draw(page)
    draw.text((16, 12), f'{title}', fill=(20, 20, 19), font=font(24))
    draw.text((16, 44), 'Green: the true damage, drawn by eye (dashed: plausible, not counted). Orange: Claude. The figure is the overlap of the pair, 0 to 1.',
              fill=(102, 100, 94), font=font(14))
    for index, case in enumerate(cases):
        left = 16 + (index % COLUMNS) * (TILE + 16)
        top = 76 + (index // COLUMNS) * (tile_height + 16)
        photo = Image.open(os.path.join(HERE, case['file'])).convert('RGB')
        photo.thumbnail((TILE, TILE * 3 // 4), Image.LANCZOS)
        width, height = photo.size
        pen = ImageDraw.Draw(photo)
        for place in case.get('optional', []):
            dashed(pen, place['box'], width, height, TRUE)
        for truth in case['truth']:
            rect(pen, truth['box'], width, height, TRUE, 3)
        result = results[case['id']].get(method)
        lines = []
        if result is None:
            lines.append('No answer could be read.')
        else:
            for name, box in result['found']:
                rect(pen, box, width, height, CLAUDE, 2)
            for row in result['rows']:
                lines.append(f"{row['truth']}: {'missed' if row['claude'] is None else format(row['iou'], '.2f')}")
            if result['false']:
                lines.append('False: ' + ', '.join(result['false']))
            if not case['truth']:
                lines.append('No damage in this photo. ' + ('Claude drew none.' if not result['found'] else f"Claude drew {len(result['found'])}."))
        page.paste(photo, (left + (TILE - width) // 2, top))
        draw.text((left, top + TILE * 3 // 4 + 6), f"{case['id']}  ({case['kind']})", fill=(20, 20, 19), font=font(15))
        for at, line in enumerate(lines[:4]):
            draw.text((left, top + TILE * 3 // 4 + 26 + at * 17), line[:70], fill=(102, 100, 94), font=font(13))
    path = os.path.join(folder, f'boxes-{method}.jpg')
    page.save(path, quality=88)
    return path


def rect(pen, box, width, height, color, line):
    pen.rectangle([box[0] * width, box[1] * height, (box[0] + box[2]) * width - 1, (box[1] + box[3]) * height - 1], outline=color, width=line)


def dashed(pen, box, width, height, color, dash=7):
    left, top, right, bottom = box[0] * width, box[1] * height, (box[0] + box[2]) * width - 1, (box[1] + box[3]) * height - 1
    at = left
    while at < right:
        pen.line([(at, top), (min(at + dash, right), top)], fill=color, width=1)
        pen.line([(at, bottom), (min(at + dash, right), bottom)], fill=color, width=1)
        at += dash * 2
    at = top
    while at < bottom:
        pen.line([(left, at), (left, min(at + dash, bottom))], fill=color, width=1)
        pen.line([(right, at), (right, min(at + dash, bottom))], fill=color, width=1)
        at += dash * 2


def main():
    run = os.path.join(HERE, sys.argv[1])
    sheets = sys.argv[2] if len(sys.argv) > 2 else run
    os.makedirs(sheets, exist_ok=True)
    cases = json.load(open(os.path.join(HERE, 'cases.json')))['photos']
    results, table = {}, []
    for case in cases:
        path = os.path.join(run, case['id'] + '.json')
        kept = json.load(open(path)) if os.path.exists(path) else {'width': 1, 'height': 1}
        results[case['id']] = {}
        for method, unused in METHODS:
            found = boxes_for(method, kept)
            if found is None:
                results[case['id']][method] = None
                continue
            rows, false, unused_taken = judge(case, found)
            results[case['id']][method] = {'found': found, 'rows': rows, 'false': false}
    for method, title in METHODS:
        rows = [row for case in cases if results[case['id']][method] for row in results[case['id']][method]['rows']]
        unread = sum(1 for case in cases if results[case['id']][method] is None)
        false = sum(len(results[case['id']][method]['false']) for case in cases if results[case['id']][method])
        on_clean = sum(len(results[case['id']][method]['found']) for case in cases if results[case['id']][method] and not case['truth'])
        paired = [row for row in rows if row['claude'] is not None]
        if rows:
            table.append({
                'method': method, 'title': title, 'true_boxes': len(rows),
                'mean_overlap': round(sum(row['iou'] for row in rows) / len(rows), 2),
                'mean_overlap_of_pairs': round(sum(row['iou'] for row in paired) / len(paired), 2) if paired else 0,
                'share_at_half': round(sum(row['iou'] >= GOOD_AT for row in rows) / len(rows), 2),
                'share_center_inside': round(sum(row['center_inside'] for row in rows) / len(rows), 2),
                'missed': len(rows) - len(paired), 'false_boxes': false, 'boxes_on_clean_photos': on_clean, 'photos_unread': unread,
            })
        sheet(method, title, cases, results, sheets, os.path.basename(run))
    json.dump({'table': table, 'photos': results}, open(os.path.join(run, 'scores.json'), 'w'), indent=1)
    print('| How the box is asked for | True boxes | Mean overlap | Overlap of at least 0.5 | Center inside the truth | Missed | False boxes | Boxes on the two clean photos |')
    print('|---|---|---|---|---|---|---|---|')
    for row in table:
        print(f"| {row['title']} | {row['true_boxes']} | {row['mean_overlap']:.2f} | {row['share_at_half']:.0%} | {row['share_center_inside']:.0%} | {row['missed']} | {row['false_boxes']} | {row['boxes_on_clean_photos']} |")
    for case in cases:
        line = [case['id'].ljust(18)]
        for method, unused in METHODS:
            result = results[case['id']][method]
            line.append('unread' if result is None else ' '.join(format(row['iou'], '.2f') for row in result['rows']) + (f" +{len(result['false'])}f" if result['false'] else ''))
        print('  '.join(part.ljust(22) for part in line))


if __name__ == '__main__':
    main()
