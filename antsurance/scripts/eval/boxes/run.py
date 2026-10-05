#!/usr/bin/env python3
"""Runs the box placement eval: asks Claude, through the org, to mark the damage in each photo
in cases.json, once for each way of asking for a box, and saves what it answered.

    python3 run.py first  runs/<name> [--only id,id] [--methods a,b]   one request per photo, one call per method
    python3 run.py refine runs/<name> [--only id,id]   second pass: a tighter box from a crop of each pixel box
    python3 score.py runs/<name>                       the table and the contact sheets

The photos never become static resources or files in the org: each request carries its photo to
the trial endpoint (classes/AntsuranceAiTrial), which puts the asks to Claude through
AntsuranceAiClient and answers with what came back. Nothing is saved in the org. One request per
photo, one after another with a pause; no polling. (A photo does not fit in an anonymous Apex script.)

The prompt is the assessment's own per-photo prompt (WHO, PER_PHOTO and STYLE in
AntsuranceClaimsAssistantPhotos, copied here on Oct 4), with only the sentence about the box changed.
"""
import base64
import io
import json
import os
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ORG = os.environ.get('SF_TARGET_ORG')
if not ORG:
    sys.exit('Set SF_TARGET_ORG to the alias of the org to run against.')
PAUSE_SECONDS = 4
CHUNK = 10000
GRID_CELLS = 10
CROP_PAD = 0.25
CROP_EDGE = 768

WHO = (
    'You are a claims appraiser at Antsurance, an insurance carrier, looking at the photographs attached to a claim. '
    'You are given the claim file as text and the photographs in order: the first image is Photo 1, the second is Photo 2, and so on. '
    'Look closely at every photograph, then report for the claim handler.\n\n'
    'Describe only what can be seen. Never invent damage, a part, a figure or a cause. Say so when a photograph does not show enough to judge. '
    'You assess what is visible: hidden damage and the true repair cost need an appraiser, and you never decide coverage.\n\n'
)
PER_PHOTO = (
    'photos: one entry for each photograph, in order. number is its position, starting at 1.\n'
    '- shows: one line on what the photograph shows.\n'
    '- usable: false when it is too dark, too blurred, too far away or too tightly cropped to judge damage from. unusable_reason says why in a few words, and is empty when usable.\n'
    '- damage: each damaged area you can see, at most five, most serious first, and empty when the photograph is unusable or shows no damage. '
    'area names the part in plain words, such as rear bumper, left rear quarter panel, rear window, ceiling by the outside wall or roof ridge. '
    'detail says what is wrong in a short phrase, such as creased and pushed in, glass shattered or stained and peeling. '
    'severity is minor when it is cosmetic and can be repaired in place, moderate when a part needs real repair or replacement but nothing structural or safety related is involved, '
    'and severe when it is structural, safety related, open to the weather or likely beyond economical repair. '
    "panel is, for a vehicle, the closest panel from the list, where left is the driver's side as you would sit in the car; use none for anything that is not a vehicle panel. "
)
BOX_START = 'box is the smallest rectangle that contains that damaged area in this photograph'
BOX_END = (
    ' Place it on the damage itself, not on the whole object, '
    'and check its top and bottom edges against where the damage sits in the frame before you give it.\n\n'
)
STYLE = (
    'Write in plain words. '
    'Write money with a dollar sign and thousands separators, and dates month first, like Sep 28. Do not use dashes as punctuation.'
)
# The one sentence that differs between the ways of asking, and how the box numbers are described in the answer's schema.
METHODS = {
    'fraction': {
        'box': ', as fractions of the image: x and y are the top left corner measured from the left edge and the top edge, and width and height are the size, all between 0 and 1.',
        'unit': 'A fraction of the image, from 0 to 1.',
        'image': 'plain',
    },
    'pixel': {
        'box': ': x and y are the top left corner measured from the left edge and the top edge, and width and height are the size. '
        'The photograph is listed with its size in pixels: give all four in pixels of that photograph.',
        'unit': 'Pixels of the photograph.',
        'image': 'plain',
    },
    # The pixel wording again, with one more sentence asking for a box per part: tried after the owner saw
    # one box run from a quarter panel down over the bumper to the road.
    'pixel_tight': {
        'box': ': x and y are the top left corner measured from the left edge and the top edge, and width and height are the size. '
        'The photograph is listed with its size in pixels: give all four in pixels of that photograph. '
        'Give each damaged part its own box: do not stretch one box over two parts, or over undamaged surface or the ground between them.',
        'unit': 'Pixels of the photograph.',
        'image': 'plain',
        'sized': True,
    },
    'grid': {
        'box': '. A grid of ten columns and ten rows is drawn over the photograph to help you place it, with the lines numbered 0 to 10 along the top edge and down the left edge. '
        'Give the box in grid units read off those numbers, to one decimal place: x and y are the top left corner, and width and height are the size.',
        'unit': 'Grid units, from 0 to 10, to one decimal place.',
        'image': 'grid',
    },
}
REFINE_WHO = (
    'You are a claims appraiser at Antsurance, an insurance carrier. You have already marked the damaged areas in a photograph attached to a claim. '
    'You are now given a closer crop of each area with some of its surroundings, in order, to place each box more exactly.\n\n'
    'areas: one entry for each crop, in order, with its number. box is the smallest rectangle that contains the damage named for that crop, in pixels of that crop: '
    'x and y are the top left corner measured from the left edge and the top edge of the crop, and width and height are the size. '
    'Place it on the damage itself, not on the whole object, and check each edge against where the damage stops. '
    'found is false when the crop does not show the damage named; give a box of zeros then.'
)


def cases(only=None):
    listed = json.load(open(os.path.join(HERE, 'cases.json')))['photos']
    return [case for case in listed if not only or case['id'] in only]


def load(case):
    return Image.open(os.path.join(HERE, case['file'])).convert('RGB')


def jpeg(image, quality=85):
    out = io.BytesIO()
    image.save(out, 'JPEG', quality=quality)
    return out.getvalue()


def with_grid(image):
    """The photo with a numbered ten by ten grid over it: thin light lines with a dark edge, so they show on any photo."""
    image = image.copy()
    draw = ImageDraw.Draw(image, 'RGBA')
    width, height = image.size
    try:
        font = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', max(14, width // 60))
    except OSError:
        font = ImageFont.load_default()
    for step in range(GRID_CELLS + 1):
        x = min(width - 1, round(width * step / GRID_CELLS))
        y = min(height - 1, round(height * step / GRID_CELLS))
        for offset, color in ((1, (0, 0, 0, 150)), (0, (255, 255, 255, 220))):
            draw.line([(x + offset, 0), (x + offset, height)], fill=color, width=1)
            draw.line([(0, y + offset), (width, y + offset)], fill=color, width=1)
        for at in ((min(x + 3, width - 22), 2), (2, min(y + 2, height - 20))):
            if step == 0 and at[0] != 2:
                continue
            box = draw.textbbox(at, str(step), font=font)
            draw.rectangle([box[0] - 2, box[1] - 1, box[2] + 2, box[3] + 1], fill=(0, 0, 0, 170))
            draw.text(at, str(step), fill=(255, 255, 255, 255), font=font)
    return image


SEVERITIES = ['minor', 'moderate', 'severe']
PANELS = ['front_bumper', 'hood', 'windshield', 'roof', 'rear_window', 'trunk', 'rear_bumper', 'front_left_fender', 'front_right_fender',
          'front_left_door', 'front_right_door', 'rear_left_door', 'rear_right_door', 'rear_left_quarter', 'rear_right_quarter', 'none']


def shape(fields):
    """An answer schema in the form AntsuranceAiClient.Shape writes: every field required, in order, and no others."""
    return {'type': 'object', 'properties': fields, 'required': list(fields), 'additionalProperties': False}


def text(description):
    return {'type': 'string', 'description': description}


def box_shape(unit):
    return shape({side: {'type': 'number', 'description': unit} for side in ('x', 'y', 'width', 'height')})


def photos_schema(unit):
    damage = shape({
        'area': text('The damaged part, in plain words.'),
        'detail': text('What is wrong with it, in a short phrase.'),
        'severity': {'type': 'string', 'enum': SEVERITIES, 'description': 'How bad it is.'},
        'panel': {'type': 'string', 'enum': PANELS, 'description': "For a vehicle, the closest panel, left being the driver's side; none otherwise."},
        'box': box_shape(unit),
    })
    photo = shape({
        'number': {'type': 'integer', 'description': "The photograph's position, starting at 1."},
        'shows': text('One line on what the photograph shows.'),
        'usable': {'type': 'boolean', 'description': 'True when damage can be judged from it.'},
        'unusable_reason': text('Why it cannot be used, or empty.'),
        'damage': {'type': 'array', 'items': damage, 'description': 'The damaged areas visible, most serious first, at most five.'},
    })
    return shape({'photos': {'type': 'array', 'items': photo, 'description': 'One entry for each photograph, in order.'}})


def send(request, folder, name):
    """One request to the trial endpoint: a few asks, each one call to Claude. Returns the answers by name, or an error."""
    path = os.path.join(folder, name + '.request.json')
    json.dump(request, open(path, 'w'))
    done = subprocess.run(
        ['sf', 'api', 'request', 'rest', '/services/apexrest/antsurance/ai-trial', '--method', 'POST', '--body', '@' + path,
         '--header', 'Content-Type: application/json', '--target-org', ORG],
        capture_output=True, text=True, env={**os.environ, 'SF_DISABLE_TELEMETRY': 'true'})
    os.remove(path)  # The request holds a whole photo; the answers are what is kept.
    try:
        answers = json.loads(done.stdout)
    except json.JSONDecodeError:
        return {}, (done.stdout or done.stderr)[:400]
    if not isinstance(answers, list):
        return {}, json.dumps(answers)[:400]
    return {answer['name']: {'ms': answer.get('ms', 0), 'text': answer.get('text') or 'FAILED ' + str(answer.get('error'))} for answer in answers}, None


def first(folder, only, methods=None):
    for case in cases(only):
        image = load(case)
        width, height = image.size
        request = {'images': {'plain': base64.b64encode(jpeg(image)).decode()}, 'asks': []}
        if not methods or 'grid' in methods:
            request['images']['grid'] = base64.b64encode(jpeg(with_grid(image))).decode()
        for method, how in METHODS.items():
            if methods and method not in methods:
                continue
            listing = f'Photo 1: "{case["title"]}"' + (f' ({width} pixels wide, {height} pixels high)' if method.startswith('pixel') else '')
            request['asks'].append({
                'name': method,
                'instructions': WHO + PER_PHOTO + BOX_START + how['box'] + BOX_END + STYLE,
                'prompt': case['claim'] + '\n\nThe photograph attached to this claim is:\n' + listing +
                "\n\nThese are some of the claim's photographs; the others are looked at separately. Report on each of these photographs only.",
                'schema': json.dumps(photos_schema(how['unit'])),
                'maxTokens': 1600,
                'images': [how['image']],
            })
        found, error = send(request, folder, case['id'])
        save(folder, case['id'], found, {'width': width, 'height': height})
        print(case['id'], error or {method: answer['ms'] for method, answer in found.items()}, flush=True)
        time.sleep(PAUSE_SECONDS)


def save(folder, case_id, found, extra=None):
    path = os.path.join(folder, case_id + '.json')
    kept = json.load(open(path)) if os.path.exists(path) else {}
    kept.update(extra or {})
    kept.setdefault('answers', {}).update(found)
    json.dump(kept, open(path, 'w'), indent=1)


def damage_of(answer):
    """The damage list in an answer, or None when the answer could not be read."""
    try:
        return json.loads(answer['text'])['photos'][0]['damage']
    except (KeyError, IndexError, ValueError, TypeError):
        return None


def refine(folder, only):
    for case in cases(only):
        kept = json.load(open(os.path.join(folder, case['id'] + '.json')))
        coarse = damage_of(kept['answers'].get('pixel', {}))
        if coarse is None:
            print(case['id'], 'no pixel answer to refine')
            continue
        if not coarse:
            save(folder, case['id'], {'refine': {'ms': 0, 'text': json.dumps({'areas': []}), 'crops': []}})
            print(case['id'], 'no boxes to refine')
            continue
        image = load(case)
        width, height = image.size
        request, listing, crops = {'images': {}, 'asks': []}, [], []
        for number, area in enumerate(coarse, start=1):
            box = area['box']
            pad_x, pad_y = box['width'] * CROP_PAD, box['height'] * CROP_PAD
            left, top = max(0, box['x'] - pad_x), max(0, box['y'] - pad_y)
            right, bottom = min(width, box['x'] + box['width'] + pad_x), min(height, box['y'] + box['height'] + pad_y)
            if right - left < 8 or bottom - top < 8:
                left, top, right, bottom = 0, 0, width, height
            crop = image.crop((round(left), round(top), round(right), round(bottom)))
            scale = min(2.0, CROP_EDGE / max(crop.size))
            crop = crop.resize((max(1, round(crop.size[0] * scale)), max(1, round(crop.size[1] * scale))), Image.LANCZOS)
            crops.append({'left': left, 'top': top, 'scale': scale, 'width': crop.size[0], 'height': crop.size[1]})
            request['images'][f'crop{number}'] = base64.b64encode(jpeg(crop, 80)).decode()
            listing.append(f'Crop {number} ({crop.size[0]} pixels wide, {crop.size[1]} pixels high): {area["area"]}, {area["detail"]}')
        area_shape = shape({
            'number': {'type': 'integer', 'description': "The crop's position, starting at 1."},
            'found': {'type': 'boolean', 'description': 'True when the crop shows the damage named.'},
            'box': box_shape('Pixels of the crop.'),
        })
        request['asks'].append({
            'name': 'refine',
            'instructions': REFINE_WHO,
            'prompt': case['claim'] + '\n\nThe photograph is "' + case['title'] + '". The crops, in order:\n' + '\n'.join(listing) + '\n\nGive the box for the damage in each crop.',
            'schema': json.dumps(shape({'areas': {'type': 'array', 'items': area_shape, 'description': 'One entry for each crop, in order.'}})),
            'maxTokens': 700,
            'images': list(request['images']),
        })
        found, error = send(request, folder, case['id'] + '-refine')
        if 'refine' in found:
            found['refine']['crops'] = crops
        save(folder, case['id'], found)
        print(case['id'], error or {method: answer['ms'] for method, answer in found.items()}, flush=True)
        time.sleep(PAUSE_SECONDS)


if __name__ == '__main__':
    step, folder = sys.argv[1], os.path.join(HERE, sys.argv[2])
    only = set(sys.argv[sys.argv.index('--only') + 1].split(',')) if '--only' in sys.argv else None
    methods = set(sys.argv[sys.argv.index('--methods') + 1].split(',')) if '--methods' in sys.argv else None
    os.makedirs(folder, exist_ok=True)
    if step == 'first':
        first(folder, only, methods)
    else:
        refine(folder, only)
