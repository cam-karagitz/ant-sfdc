"""Turns a rendered page into something that looks like a phone photo of paper on a desk.

usage: make_photo.py page.png photo.jpg
"""
import random
import sys

from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

MARGIN_X, MARGIN_Y = 260, 300
DESK = (96, 74, 56)
TILT_DEGREES = -2.2
SCALE = 0.82
JPEG_QUALITY = 78

random.seed(7)
page = Image.open(sys.argv[1]).convert('RGB')
width, height = page.size
# Paper is never pure white, and light falls off toward one edge.
page = Image.eval(page, lambda value: int(value * 0.97 + 6))
shade = Image.new('L', (width, height), 0)
draw = ImageDraw.Draw(shade)
for x in range(width):
    draw.line([(x, 0), (x, height)], fill=int(26 * (x / width)))
page = Image.composite(Image.eval(page, lambda value: int(value * 0.9)), page, shade)

desk_size = (width + MARGIN_X, height + MARGIN_Y)
desk = Image.new('RGB', desk_size, DESK)
grain = ImageDraw.Draw(desk)
for y in range(0, desk_size[1], 3):
    shift = random.randint(-7, 7)
    grain.line([(0, y), (desk_size[0], y)], fill=tuple(channel + shift for channel in DESK))
desk = desk.filter(ImageFilter.GaussianBlur(1.2))

tilted = page.convert('RGBA').rotate(TILT_DEGREES, expand=True, resample=Image.BICUBIC)
shadow = Image.new('RGBA', tilted.size, (0, 0, 0, 0))
shadow.paste((0, 0, 0, 110), mask=tilted.split()[3])
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
left = (desk_size[0] - tilted.size[0]) // 2
top = (desk_size[1] - tilted.size[1]) // 2
desk.paste(shadow, (left + 14, top + 18), shadow)
desk.paste(tilted, (left, top), tilted)

photo = desk.resize((int(desk_size[0] * SCALE), int(desk_size[1] * SCALE)), Image.LANCZOS)
ImageEnhance.Contrast(photo).enhance(0.96).save(sys.argv[2], quality=JPEG_QUALITY, optimize=True)
