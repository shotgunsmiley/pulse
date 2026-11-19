"""Generates Pulse v5's chunky 2007-era pixel textures (no artist files needed).
Outputs into godot/pulse_v4/textures/:
  atlas.png   4x4 tiles of 32x32 grey "detail" patterns. The world shader multiplies each
              model's colour by its tile (128 = no change), picked by material id.
  clouds.png  128x128 tileable cloud noise for the sky shader.
  ui_stone.png, ui_parch.png, ui_gold.png  old-school menu panels (9-slice friendly).
Run:  python texgen.py <out_dir>
"""
import math, os, random, sys
from PIL import Image

T = 32
OUT = sys.argv[1] if len(sys.argv) > 1 else '.'
os.makedirs(OUT, exist_ok=True)

def vnoise(seed, period, x, y):
    """Tileable value noise: lattice of `period` cells over the 32px tile."""
    rng = random.Random(seed)
    g = [[rng.random() for _ in range(period)] for _ in range(period)]
    fx, fy = x * period / T, y * period / T
    x0, y0 = int(fx) % period, int(fy) % period
    x1, y1 = (x0 + 1) % period, (y0 + 1) % period
    tx, ty = fx - int(fx), fy - int(fy)
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    a = g[y0][x0] + (g[y0][x1] - g[y0][x0]) * tx
    b = g[y1][x0] + (g[y1][x1] - g[y1][x0]) * tx
    return a + (b - a) * ty

def fbm(seed, x, y, octaves=((4, 0.6), (8, 0.3), (16, 0.1))):
    return sum(vnoise(seed + i * 17, p, x, y) * w for i, (p, w) in enumerate(octaves))

def tile(fn, seed):
    rng = random.Random(seed)
    return [[max(0.55, min(1.3, fn(x, y, rng))) for x in range(T)] for y in range(T)]

def t_plain(x, y, r):
    return 1.0

def t_cloth(x, y, r):
    weave = 0.94 + 0.08 * (((x // 2) + (y // 2)) % 2)
    return weave + (fbm(3, x, y) - 0.5) * 0.08

def t_wood(x, y, r):
    plank = x % 11 == 0
    grain = 0.92 + 0.12 * math.sin(x * 1.7 + 3.0 * fbm(5, x * 0.3, y * 2.0))
    knot = 0.85 if (x - 6) ** 2 + ((y - 20) % T) ** 2 < 5 else 1.0
    return (0.7 if plank else grain) * knot

def t_stone(x, y, r):
    v = 0.84 + fbm(7, x, y) * 0.32
    crack = abs(math.sin(x * 0.4 + y * 0.9 + fbm(9, x, y) * 4)) < 0.05
    return v * (0.78 if crack else 1.0)

CELLS = [(random.Random(11 + i).randint(0, 31), random.Random(91 + i).randint(0, 31)) for i in range(9)]
def t_cobble(x, y, r):
    ds = []
    for cx, cy in CELLS:
        dx = min(abs(x - cx), T - abs(x - cx))
        dy = min(abs(y - cy), T - abs(y - cy))
        ds.append(math.hypot(dx, dy))
    ds.sort()
    edge = ds[1] - ds[0]
    if edge < 1.6:
        return 0.68
    return 0.95 + min(0.12, edge * 0.02) + (fbm(13, x, y) - 0.5) * 0.12

def t_foliage(x, y, r):
    blade = 1.0 + (0.16 if vnoise(15, 16, x, y) > 0.7 else 0.0) - (0.18 if vnoise(19, 32, x, y) < 0.2 else 0.0)
    return blade + (fbm(17, x, y) - 0.5) * 0.18

def t_dirt(x, y, r):
    v = 0.9 + (fbm(21, x, y) - 0.5) * 0.25
    if vnoise(23, 32, x, y) > 0.82:
        v *= 1.15
    if vnoise(29, 32, x, y) < 0.12:
        v *= 0.8
    return v

def t_roof(x, y, r):
    row = y // 6
    off = (row % 2) * 4
    edge = (y % 6) == 5 or ((x + off) % 8) == 0
    return (0.72 if edge else 1.0 + (vnoise(31 + row, 8, x, y) - 0.5) * 0.14) * (0.96 + 0.06 * ((y % 6) / 5.0))

def t_metal(x, y, r):
    return 0.95 + (vnoise(37, 32, x * 0.1, y) - 0.5) * 0.18 + (0.08 if (x * 7 + y * 3) % 29 == 0 else 0)

def t_plaster(x, y, r):
    v = 0.93 + (fbm(41, x, y) - 0.5) * 0.16
    crack = abs(math.sin(x * 0.25 - y * 0.6 + fbm(43, x, y) * 3)) < 0.03 and fbm(47, x, y) > 0.55
    return v * (0.82 if crack else 1.0)

def t_leather(x, y, r):
    stitch = (y % 16 == 3) and (x % 4 < 2)
    return (1.12 if stitch else 0.94 + (vnoise(53, 16, x, y) - 0.5) * 0.14)

def t_hair(x, y, r):
    return 0.9 + 0.16 * vnoise(59, 32, x, y * 0.15) + (fbm(61, x, y) - 0.5) * 0.06

def t_straw(x, y, r):
    return 0.86 + 0.24 * vnoise(67, 32, (x + y) % T, (x - y) % T * 0.12)

def t_ore(x, y, r):
    v = t_stone(x, y, r)
    if vnoise(71, 16, x, y) > 0.72:
        v *= 1.25
    return v

TILES = [t_plain, t_cloth, t_wood, t_stone, t_cobble, t_foliage, t_dirt, t_roof, t_metal, t_plaster, t_leather, t_hair,
         t_straw, t_ore, t_plain, t_plain]

atlas = Image.new('RGB', (T * 4, T * 4))
for i, fn in enumerate(TILES):
    data = tile(fn, 100 + i)
    ox, oy = (i % 4) * T, (i // 4) * T
    for y in range(T):
        for x in range(T):
            v = int(max(0, min(255, round(data[y][x] * 128))))
            atlas.putpixel((ox + x, oy + y), (v, v, v))
atlas.save(os.path.join(OUT, 'atlas.png'))

# clouds: tileable fbm, soft threshold
C = 128
cl = Image.new('L', (C, C))
def cnoise(seed, period, x, y):
    rng = random.Random(seed)
    g = [[rng.random() for _ in range(period)] for _ in range(period)]
    fx, fy = x * period / C, y * period / C
    x0, y0 = int(fx) % period, int(fy) % period
    x1, y1 = (x0 + 1) % period, (y0 + 1) % period
    tx, ty = fx - int(fx), fy - int(fy)
    tx, ty = tx * tx * (3 - 2 * tx), ty * ty * (3 - 2 * ty)
    a = g[y0][x0] + (g[y0][x1] - g[y0][x0]) * tx
    b = g[y1][x0] + (g[y1][x1] - g[y1][x0]) * tx
    return a + (b - a) * ty
grids = [(4, 0.55), (8, 0.28), (16, 0.12), (32, 0.05)]
for y in range(C):
    for x in range(C):
        v = sum(cnoise(200 + i, p, x, y) * w for i, (p, w) in enumerate(grids))
        v = max(0.0, min(1.0, (v - 0.48) * 3.2))
        cl.putpixel((x, y), int(v * 255))
cl.save(os.path.join(OUT, 'clouds.png'))

# old-school UI panels (64x64, 9-slice with 12px margins)
def panel(name, base, dark, light, rough, border=None):
    S = 64
    im = Image.new('RGBA', (S, S))
    for y in range(S):
        for x in range(S):
            n = (fbm(300 + len(name), x % T, y % T) - 0.5) * rough
            c = [max(0, min(255, int(ch * (1 + n)))) for ch in base]
            e = min(x, y, S - 1 - x, S - 1 - y)
            if border and e < 4:
                c = list(border[0] if e in (0, 3) else border[1])
            elif e < 2:
                c = list(dark)
            elif e < 3:
                c = list(light)
            im.putpixel((x, y), tuple(c) + (255,))
    im.save(os.path.join(OUT, name))

panel('ui_stone.png', (74, 70, 64), (28, 26, 23), (110, 104, 95), 0.35)
panel('ui_parch.png', (217, 204, 170), (110, 86, 52), (240, 230, 200), 0.18, border=((64, 46, 24), (184, 144, 46)))
panel('ui_gold.png', (184, 144, 46), (90, 64, 18), (240, 210, 120), 0.25)
print('textures written to', OUT)

# v5 neutral beveled frames, tinted in the app by each panel's colour (9-slice, 8px margins)
def frame(name, ring=None):
    S = 48
    im = Image.new('RGBA', (S, S))
    for y in range(S):
        for x in range(S):
            n = (fbm(500, x % T, y % T) - 0.5) * 0.10
            v = 0.86 + n
            e = min(x, y, S - 1 - x, S - 1 - y)
            if e == 0:
                c = (12, 10, 8)
            elif ring and e in (1, 2):
                c = ring
            elif e <= 3:
                top_left = (x <= y and x + y < S) if False else (y <= 3 or x <= 3) and not (y >= S - 4 or x >= S - 4)
                v2 = 1.0 if top_left else 0.5
                c = tuple(int(255 * v2) for _ in range(3))
            else:
                c = tuple(int(255 * v) for _ in range(3))
            im.putpixel((x, y), c + (255,))
    im.save(os.path.join(OUT, name))

frame('ui_frame.png')
frame('ui_frame_gold.png', ring=(232, 176, 74))
print('frames written')
