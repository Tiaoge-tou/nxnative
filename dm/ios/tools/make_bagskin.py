#!/usr/bin/env python3
"""Make the Silksong pad's bag-mode key art (dm/ios/padskin + padskin-badge).

The bag layout (DmGamepad pad mode 4) has nine keys of its own: a D-pad of
four round-frame keys with a solid block arrow each (generously rounded
corners), the X / A / B face keys as
round-frame keys with a big serif letter, and L / R in the double-horn frame
with a letter. Every key is composed from the shipping skin's own frames --
bind.png for the round thorn frame, needolin.png for the double-horn frame --
over a clean radial dark disc generated here: the frames' own discs carry
their icons, and a cleaned copy of one still showed the icon's ghost in the
approved layout preview, so the disc is procedural (a radial gradient, a
soft inner shadow at its rim, faint brush dabs and grain, in the badge
medallion face's family) and no pixel of an icon survives into it.

Glyphs follow the badge bake's letter craft (tools in the skin workspace,
bake_badges.py): Noto Serif, an ivory vertical gradient, a dark carved
offset below, optically centred. Sizes are the approved bag-layout
preview's: a face letter's ink stands 0.474 of the frame's diameter, an
L / R letter's 0.314 of its frame's, a block arrow spans 0.41 across and
0.434 down its frame before rounding. The pressed state follows the shipping
set's rule, measured off bind / bind_p: the frame is untouched and the
disc's interior takes a warm rose glow, strongest at the centre. The badge
set is the plain set padded onto its 1020 canvas (the same +70 offset
bake_badges pads by), with no medallion: the bag keys carry their letter
in the disc already.

Deterministic (seeded). Run from anywhere; paths resolve off this file.
    python3 dm/ios/tools/make_bagskin.py
"""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import glob, math, os, random, sys

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.normpath(os.path.join(HERE, '..'))
PLAIN, BADGE = f'{IOS}/padskin', f'{IOS}/padskin-badge'
SERIF = sorted(glob.glob('/usr/share/fonts/truetype/noto/NotoSerif-Regular.ttf'))
SERIF = SERIF[0] if SERIF else '/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf'

CANVAS = 880                 # the plain set's canvas; the badge set's is 1020
BADGE_PAD = 70               # int(880 * 0.08), bake_badges' pad
CENTRE = {'bind': (439.5, 440.0), 'needolin': (440.5, 440.5)}
DISC_R = 300                 # the frames' disc interior ends here; the frame ring is kept past it
BLEND_R = 314                # the generated disc has blended into the frame by here
IVORY_TOP, IVORY_BOT = (246, 243, 233), (208, 201, 184)


def radial_disc(centre, seed):
    """A clean dark disc, CANVAS square, transparent outside DISC_R + margin."""
    rng = random.Random(seed)
    cx, cy = centre
    R = BLEND_R + 6
    stops = [(0.0, (57, 59, 63)), (0.55, (39, 41, 45)), (0.88, (28, 29, 33)), (1.0, (20, 21, 25))]
    disc = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    px = disc.load()
    for y in range(int(cy - R) - 1, int(cy + R) + 2):
        for x in range(int(cx - R) - 1, int(cx + R) + 2):
            r = math.hypot(x - cx, y - cy)
            if r > R:
                continue
            t = r / R
            for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
                if t <= t1:
                    f = (t - t0) / (t1 - t0)
                    col = tuple(int(a + (b - a) * f) for a, b in zip(c0, c1))
                    break
            else:
                col = stops[-1][1]
            if r > DISC_R * 0.86:   # the rim's inner shadow, as the shipping discs dip before the frame
                f = (r - DISC_R * 0.86) / (DISC_R * 0.14)
                col = tuple(int(v * (1 - 0.35 * f)) for v in col)
            px[x, y] = col + (255,)
    # faint brush dabs, well under the badge face's, blurred soft
    dab = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dab)
    for _ in range(40):
        a, rr = rng.uniform(0, 6.28), rng.uniform(0, DISC_R * 0.92)
        x, y = cx + rr * math.cos(a), cy + rr * math.sin(a)
        w = rng.uniform(10, 44)
        tone = rng.choice([(255, 255, 255), (0, 0, 0)])
        dd.ellipse([x - w, y - w * 0.4, x + w, y + w * 0.4], fill=tone + (rng.randint(4, 9),))
    dab = dab.filter(ImageFilter.GaussianBlur(6))
    mask = Image.new('L', (CANVAS, CANVAS), 0)
    ImageDraw.Draw(mask).ellipse([cx - DISC_R, cy - DISC_R, cx + DISC_R, cy + DISC_R], fill=255)
    disc = Image.composite(Image.alpha_composite(disc, dab), disc, mask)
    # fine grain
    noise = Image.effect_noise((CANVAS, CANVAS), 7).convert('L')
    dark = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
    dpx, npx = disc.load(), noise.load()
    for y in range(int(cy - DISC_R), int(cy + DISC_R) + 1):
        for x in range(int(cx - DISC_R), int(cx + DISC_R) + 1):
            if math.hypot(x - cx, y - cy) <= DISC_R and dpx[x, y][3]:
                r0, g0, b0, a0 = dpx[x, y]
                dn = (npx[x, y] - 128) / 28.0
                dpx[x, y] = (max(0, min(255, int(r0 + dn))), max(0, min(255, int(g0 + dn))),
                             max(0, min(255, int(b0 + dn))), a0)
    return disc


def clean_base(frame_name, seed):
    """The shipping frame with its disc interior replaced by the clean disc."""
    base = Image.open(f'{PLAIN}/{frame_name}.png').convert('RGBA')
    cx, cy = CENTRE[frame_name]
    disc = radial_disc((cx, cy), seed)
    out = base.copy()
    bpx, dpx, opx = base.load(), disc.load(), out.load()
    for y in range(CANVAS):
        for x in range(CANVAS):
            r = math.hypot(x - cx, y - cy)
            if r <= DISC_R:
                opx[x, y] = dpx[x, y][:3] + (max(bpx[x, y][3], dpx[x, y][3]),)
            elif r < BLEND_R:
                f = (r - DISC_R) / (BLEND_R - DISC_R)
                opx[x, y] = tuple(int(dpx[x, y][i] * (1 - f) + bpx[x, y][i] * f) for i in range(3)) + (bpx[x, y][3],)
    return out


def glyph_layer(draw_fn, post=None):
    """Render a glyph at 2x with the carved shadow and ivory gradient, centred.

    post, when given, post-processes the drawn mask before centring (the
    D-pad's block arrows blur and re-threshold theirs to round the corners)."""
    SS = 2
    S = CANVAS * SS
    mask = Image.new('L', (S, S), 0)
    draw_fn(ImageDraw.Draw(mask), SS)
    if post: mask = post(mask)
    bbox = mask.getbbox()
    if bbox:   # optical centring on the ink, as bake_badges' glyph_mask
        dx = round(S / 2 - (bbox[0] + bbox[2]) / 2)
        dy = round(S / 2 - (bbox[1] + bbox[3]) / 2)
        out = Image.new('L', (S, S), 0)
        out.paste(mask, (dx, dy))
        mask = out
    lay = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sh = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    sh.paste(Image.new('RGBA', (S, S), (10, 10, 12, 150)), (0, 5 * SS // 2), mask)
    lay = Image.alpha_composite(lay, sh)
    grad = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    bb = mask.getbbox() or (0, 0, S, S)
    for yy in range(bb[1], bb[3]):
        t = (yy - bb[1]) / max(1, bb[3] - bb[1])
        gd.line([0, yy, S, yy], fill=tuple(int(a + (b - a) * t) for a, b in zip(IVORY_TOP, IVORY_BOT)) + (255,))
    lay.paste(grad, (0, 0), mask)
    return lay.resize((CANVAS, CANVAS), Image.LANCZOS)


def block_arrow_glyph(direction):
    """A solid block arrow with generously rounded corners, drawn natively
    per direction (the polygon's coordinates rotate, never a bitmap): an
    arrowhead 330 wide over a shaft 96 wide, the whole 350 tall in canvas
    px, its corners rounded by blurring the 2x mask and re-thresholding it
    (the approved design sheet's heavier rounding)."""
    UP = [(0, -175), (165, 30), (48, 30), (48, 175), (-48, 175), (-48, 30), (-165, 30)]
    ROT = {'up': lambda x, y: (x, y), 'right': lambda x, y: (-y, x),
           'down': lambda x, y: (-x, -y), 'left': lambda x, y: (y, -x)}
    def draw(md, SS):
        c = CANVAS * SS // 2
        rot = ROT[direction]
        md.polygon([(c + rot(x, y)[0] * SS, c + rot(x, y)[1] * SS) for x, y in UP], fill=255)
    def soften(mask):
        return mask.filter(ImageFilter.GaussianBlur(38)).point(lambda v: 255 if v >= 128 else 0)
    return glyph_layer(draw, soften)


def letter_glyph(letter, ink_h):
    probe = ImageDraw.Draw(Image.new('RGBA', (4, 4)))
    def draw(md, SS):
        size = int(ink_h * SS * 1.9)
        while size > 8:
            f = ImageFont.truetype(SERIF, size)
            b = probe.textbbox((0, 0), letter, font=f)
            if b[3] - b[1] <= ink_h * SS:
                break
            size -= 2
        c = CANVAS * SS // 2
        md.text((c - (b[2] - b[0]) / 2 - b[0], c - (b[3] - b[1]) / 2 - b[1]), letter, font=f, fill=255)
    return glyph_layer(draw)


def pressed(art, centre):
    """The shipping set's pressed rule: the frame untouched, the disc's
    interior warmed (rose in the red, a touch off the green and blue),
    strongest at the centre and gone at the disc's rim."""
    out = art.copy()
    cx, cy = centre
    px = out.load()
    for y in range(int(cy - DISC_R), int(cy + DISC_R) + 1):
        for x in range(int(cx - DISC_R), int(cx + DISC_R) + 1):
            r = math.hypot(x - cx, y - cy)
            if r >= DISC_R or not px[x, y][3]:
                continue
            g = ((math.cos(math.pi * r / DISC_R) + 1) / 2) ** 1.3
            r0, g0, b0, a0 = px[x, y]
            px[x, y] = (max(0, min(255, int(r0 + 36 * g))), max(0, min(255, int(g0 - 8 * g))),
                        max(0, min(255, int(b0 - 5 * g))), a0)
    return out


def badge(art):
    out = Image.new('RGBA', (1020, 1020), (0, 0, 0, 0))
    out.alpha_composite(art, (BADGE_PAD, BADGE_PAD))
    return out


def main():
    keys = []   # (name, frame, glyph layer)
    for name, direction in (('bagdup', 'up'), ('bagddown', 'down'), ('bagdleft', 'left'), ('bagdright', 'right')):
        keys.append((name, 'bind', block_arrow_glyph(direction)))
    for name, letter in (('bagx', 'X'), ('baga', 'A'), ('bagb', 'B')):
        keys.append((name, 'bind', letter_glyph(letter, 383)))   # ink height 0.474 of the frame's 807
    for name, letter in (('bagl', 'L'), ('bagr', 'R')):
        keys.append((name, 'needolin', letter_glyph(letter, 230)))   # 0.314 of the horn frame's 733
    bases = {}
    done = []
    for name, frame, glyph in keys:
        if frame not in bases:
            bases[frame] = clean_base(frame, 11 if frame == 'bind' else 23)
        art = bases[frame].copy()
        art.alpha_composite(glyph)
        for suffix, im in (('', art), ('_p', pressed(art, CENTRE[frame]))):
            im.save(f'{PLAIN}/{name}{suffix}.png')
            badge(im).save(f'{BADGE}/{name}{suffix}.png')
            done.append(f'{name}{suffix}')
    print('bag skin baked:', ', '.join(done))


if __name__ == '__main__':
    sys.exit(main())
