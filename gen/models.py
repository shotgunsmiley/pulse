"""Generates every 3D model and scene layout for Pulse v4 as plain data.
Output: scripts/model_data.gd (read by the Godot app) - the preview renderer reads the same data.
Coordinates: Y up, -Z forward (Godot convention). Units are roughly metres.
"""
import math, random, json, os

# --------------------------------------------------------------------------- palette
# index: (hex, glow). Indices 0-5 are character slots recoloured at runtime.
PALETTE = [
    ('#c8946a', False),  # 0 skin
    ('#4a3423', False),  # 1 hair
    ('#6e4a2c', False),  # 2 shirt
    ('#3d3a35', False),  # 3 pants
    ('#3f7a6e', False),  # 4 accent
    ('#8d8d8d', False),  # 5 pickaxe head
    ('#4a3320', False),  # 6 wood dark
    ('#6b4a2b', False),  # 7 wood
    ('#8a6438', False),  # 8 wood light
    ('#55524c', False),  # 9 stone dark
    ('#77726a', False),  # 10 stone
    ('#948e83', False),  # 11 stone light
    ('#3a2a1c', False),  # 12 boots / leather dark
    ('#2e2218', False),  # 13 belt
    ('#b8902e', False),  # 14 gold
    ('#4c4f52', False),  # 15 iron dark
    ('#85898c', False),  # 16 iron
    ('#2A9D8F', True),   # 17 pulse teal (glow)
    ('#7fe3d3', True),   # 18 pulse light (glow)
    ('#6a3fa8', True),   # 19 void (glow)
    ('#b48cf0', True),   # 20 void light (glow)
    ('#ff8a2a', True),   # 21 fire (glow)
    ('#ffd36b', True),   # 22 lantern (glow)
    ('#2c2b2a', False),  # 23 coal
    ('#8a5536', False),  # 24 rust ore
    ('#4f6e27', False),  # 25 grass
    ('#3f5c20', False),  # 26 grass dark
    ('#6e5636', False),  # 27 dirt path
    ('#7f786c', False),  # 28 cobble
    ('#6a6359', False),  # 29 cobble dark
    ('#2f5224', False),  # 30 pine
    ('#25421c', False),  # 31 pine dark
    ('#7a3a2c', False),  # 32 red roof
    ('#5c2b20', False),  # 33 red roof dark
    ('#47506a', False),  # 34 hall roof
    ('#b8a888', False),  # 35 plaster
    ('#1d1916', False),  # 36 doorway dark
    ('#d9ccaa', False),  # 37 parchment
    ('#4a4038', False),  # 38 cave floor
    ('#3a322c', False),  # 39 cave wall dark
    ('#8a2c2c', False),  # 40 banner red
    ('#1f5a52', False),  # 41 teal dark (no glow)
    ('#3d5e1f', False),  # 42 leaves
    ('#2e4a17', False),  # 43 leaves dark
    ('#a08a4a', False),  # 44 thatch
    ('#7d6a36', False),  # 45 thatch dark
    ('#1a1410', False),  # 46 eyes / brows
    ('#5a5f66', False),  # 47 slate roof
    ('#454a50', False),  # 48 slate roof dark
    ('#e0a030', True),   # 49 amber gem (glow)
    ('#c0304a', True),   # 50 garnet gem (glow)
    ('#4a78e0', True),   # 51 sapphire gem (glow)
    ('#e8eef4', False),  # 52 snow
    ('#2a5a70', False),  # 53 deep water
    ('#9ff3e6', True),   # 54 glow mushroom
    ('#c9b48a', False),  # 55 fish belly
    ('#6a7f8a', False),  # 56 fish back
]
P = {'skin': 0, 'hair': 1, 'shirt': 2, 'pants': 3, 'accent': 4, 'pick': 5, 'wood_d': 6, 'wood': 7, 'wood_l': 8,
     'stone_d': 9, 'stone': 10, 'stone_l': 11, 'boots': 12, 'belt': 13, 'gold': 14, 'iron_d': 15, 'iron': 16,
     'teal': 17, 'teal_l': 18, 'void': 19, 'void_l': 20, 'fire': 21, 'lamp': 22, 'coal': 23, 'rust': 24,
     'grass': 25, 'grass_d': 26, 'dirt': 27, 'cobble': 28, 'cobble_d': 29, 'pine': 30, 'pine_d': 31, 'roof': 32,
     'roof_d': 33, 'hall_roof': 34, 'plaster': 35, 'door': 36, 'parch': 37, 'cave_floor': 38, 'cave_wall': 39,
     'banner': 40, 'teal_d': 41, 'leaf': 42, 'leaf_d': 43, 'thatch': 44, 'thatch_d': 45, 'eye': 46,
     'slate': 47, 'slate_d': 48, 'amber': 49, 'garnet': 50, 'sapphire': 51, 'snow': 52, 'water': 53, 'mush': 54,
     'fish_l': 55, 'fish': 56}

# Material id per palette index: picks the pixel-texture tile the v5 world shader lays over the colour.
# 0 plain, 1 cloth, 2 wood, 3 stone, 4 cobble, 5 foliage, 6 dirt, 7 roof, 8 metal, 9 plaster, 10 leather, 11 hair, 12 straw, 13 ore
MAT_OF = {'skin': 0, 'hair': 11, 'shirt': 1, 'pants': 1, 'accent': 1, 'pick': 8, 'wood_d': 2, 'wood': 2, 'wood_l': 2,
          'stone_d': 3, 'stone': 3, 'stone_l': 3, 'boots': 10, 'belt': 10, 'gold': 8, 'iron_d': 8, 'iron': 8, 'coal': 13,
          'rust': 13, 'grass': 5, 'grass_d': 5, 'dirt': 6, 'cobble': 4, 'cobble_d': 4, 'pine': 5, 'pine_d': 5, 'roof': 7,
          'roof_d': 7, 'hall_roof': 7, 'plaster': 9, 'door': 2, 'parch': 9, 'cave_floor': 6, 'cave_wall': 3, 'banner': 1,
          'teal_d': 3, 'leaf': 5, 'leaf_d': 5, 'thatch': 12, 'thatch_d': 12, 'eye': 0, 'slate': 7, 'slate_d': 7,
          'snow': 9, 'water': 0, 'fish_l': 0, 'fish': 0}

# --------------------------------------------------------------------------- mesh builder
def shade_noise(p):
    # deterministic per-vertex brightness wobble (0.9 - 1.08): the hand-shaded look of 2007-era models
    x, y, z = (round(v, 3) for v in p)
    h = math.sin(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453
    return 0.90 + 0.18 * (h - math.floor(h))

def hexrgb(h):
    h = h.lstrip('#')
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]

class Mesh:
    def __init__(self, smooth=False, wobble=True):
        self.tris = []   # (a, b, c, colour index); CCW seen from outside
        self.vcols = {}  # triangle index -> [(r,g,b)] * 3, overrides the palette (terrain blending)
        self.smooth = smooth
        self.wobble = wobble

    def tri(self, a, b, c, col, vc=None):
        if vc is not None:
            self.vcols[len(self.tris)] = vc
        self.tris.append((tuple(a), tuple(b), tuple(c), P[col] if isinstance(col, str) else col))

    def loft(self, rings, sides=8, cx=0.0, cz=0.0, cap_bottom=True, cap_top=True, phase=0.0):
        """Stacked elliptical rings: rings = [(y, rx, rz, col, dz)], built bottom to top or top to bottom."""
        pts = []
        for (y, rx, rz, col, *rest) in rings:
            dz = rest[0] if rest else 0.0
            pts.append([(cx + rx * math.cos(2 * math.pi * i / sides + phase), y, cz + dz + rz * math.sin(2 * math.pi * i / sides + phase)) for i in range(sides)])
        down = rings[0][0] > rings[-1][0]
        for k in range(len(rings) - 1):
            col = rings[k][3] if not down else rings[k + 1][3]
            lo, hi = (pts[k], pts[k + 1]) if not down else (pts[k + 1], pts[k])
            for i in range(sides):
                j = (i + 1) % sides
                self.quad(lo[j], lo[i], hi[i], hi[j], col)
        first, last = pts[0], pts[-1]
        bot, top = (first, last) if not down else (last, first)
        bcol = rings[0][3] if not down else rings[-1][3]
        tcol = rings[-1][3] if not down else rings[0][3]
        if cap_bottom:
            c = (sum(p[0] for p in bot) / sides, bot[0][1], sum(p[2] for p in bot) / sides)
            for i in range(sides):
                self.tri(c, bot[i], bot[(i + 1) % sides], bcol)
        if cap_top:
            c = (sum(p[0] for p in top) / sides, top[0][1], sum(p[2] for p in top) / sides)
            for i in range(sides):
                self.tri(c, top[(i + 1) % sides], top[i], tcol)

    def ellipsoid(self, cx, cy, cz, rx, ry, rz, col, seg=8, rings=6, top_frac=1.0, noise=0.0, seed=0, col2=None, back_min=None):
        """Low-poly ellipsoid. top_frac < 1 keeps only the top part (hair caps). noise roughens the surface."""
        rnd = random.Random(seed)
        rows = []
        kmax = max(1, int(round(rings * top_frac)))
        for k in range(kmax + 1):
            phi = math.pi * k / rings
            row = []
            for i in range(seg):
                th = 2 * math.pi * i / seg + (math.pi / seg if k % 2 else 0)
                f = 1.0 + (rnd.uniform(-noise, noise) if 0 < k < rings else 0)
                row.append((cx + rx * f * math.sin(phi) * math.cos(th), cy + ry * f * math.cos(phi), cz + rz * f * math.sin(phi) * math.sin(th)))
            rows.append(row)
        for k in range(kmax):
            for i in range(seg):
                j = (i + 1) % seg
                c = col if (col2 is None or (i + k) % 3) else col2
                a, b, cc, d = rows[k][i], rows[k][j], rows[k + 1][j], rows[k + 1][i]
                if back_min is not None and (a[2] + b[2] + cc[2] + d[2]) / 4 - cz < back_min * rz:
                    continue
                if k == 0:
                    self.tri(a, cc, d, c)
                elif k == rings - 1:
                    self.tri(a, b, d, c)
                else:
                    self.quad(a, b, cc, d, c)

    def tube(self, p0, p1, r0, r1, col, sides=6):
        """Tapered prism between two points (any direction)."""
        ax = [p1[i] - p0[i] for i in range(3)]
        L = math.sqrt(sum(a * a for a in ax)) or 1.0
        ax = [a / L for a in ax]
        ref = (0, 1, 0) if abs(ax[1]) < 0.9 else (1, 0, 0)
        u = [ax[1] * ref[2] - ax[2] * ref[1], ax[2] * ref[0] - ax[0] * ref[2], ax[0] * ref[1] - ax[1] * ref[0]]
        ul = math.sqrt(sum(a * a for a in u)); u = [a / ul for a in u]
        v = [ax[1] * u[2] - ax[2] * u[1], ax[2] * u[0] - ax[0] * u[2], ax[0] * u[1] - ax[1] * u[0]]
        def ring(p, r):
            return [tuple(p[k] + r * (math.cos(2 * math.pi * i / sides) * u[k] + math.sin(2 * math.pi * i / sides) * v[k]) for k in range(3)) for i in range(sides)]
        a, b = ring(p0, r0), ring(p1, r1)
        for i in range(sides):
            j = (i + 1) % sides
            self.quad(a[i], a[j], b[j], b[i], col)
            self.tri(tuple(p0), a[j], a[i], col)
            self.tri(tuple(p1), b[i], b[j], col)

    def quad(self, a, b, c, d, col):
        self.tri(a, b, c, col)
        self.tri(a, c, d, col)

    def box(self, cx, cy, cz, sx, sy, sz, col, top=None, rot=0.0):
        hx, hy, hz = sx / 2.0, sy / 2.0, sz / 2.0
        def p(x, y, z):
            c, s = math.cos(rot), math.sin(rot)
            return (cx + x * c + z * s, cy + y, cz - x * s + z * c)
        v = [p(-hx, -hy, -hz), p(hx, -hy, -hz), p(hx, hy, -hz), p(-hx, hy, -hz),
             p(-hx, -hy, hz), p(hx, -hy, hz), p(hx, hy, hz), p(-hx, hy, hz)]
        t = top or col
        self.quad(v[4], v[5], v[6], v[7], col)   # +z
        self.quad(v[1], v[0], v[3], v[2], col)   # -z
        self.quad(v[5], v[1], v[2], v[6], col)   # +x
        self.quad(v[0], v[4], v[7], v[3], col)   # -x
        self.quad(v[7], v[6], v[2], v[3], t)     # top
        self.quad(v[0], v[1], v[5], v[4], col)   # bottom

    def prism_roof(self, cx, cy, cz, sx, sy, sz, col, col2=None):
        """Gabled roof, ridge along x."""
        hx, hz = sx / 2.0, sz / 2.0
        a, b = (cx - hx, cy, cz + hz), (cx + hx, cy, cz + hz)
        c, d = (cx + hx, cy, cz - hz), (cx - hx, cy, cz - hz)
        r1, r2 = (cx - hx, cy + sy, cz), (cx + hx, cy + sy, cz)
        self.quad(a, b, r2, r1, col)
        self.quad(c, d, r1, r2, col2 or col)
        self.tri(b, c, r2, col2 or col)
        self.tri(d, a, r1, col2 or col)

    def cylinder(self, cx, cy, cz, r, h, col, sides=8, top=None, r_top=None):
        rt = r if r_top is None else r_top
        pts_b = [(cx + r * math.cos(2 * math.pi * i / sides), cy, cz + r * math.sin(2 * math.pi * i / sides)) for i in range(sides)]
        pts_t = [(cx + rt * math.cos(2 * math.pi * i / sides), cy + h, cz + rt * math.sin(2 * math.pi * i / sides)) for i in range(sides)]
        for i in range(sides):
            j = (i + 1) % sides
            self.quad(pts_b[j], pts_b[i], pts_t[i], pts_t[j], col)
            if rt > 0:
                self.tri((cx, cy + h, cz), pts_t[j], pts_t[i], top or col)
            self.tri((cx, cy, cz), pts_b[i], pts_b[j], col)

    def cone(self, cx, cy, cz, r, h, col, sides=7, col2=None):
        base = [(cx + r * math.cos(2 * math.pi * i / sides), cy, cz + r * math.sin(2 * math.pi * i / sides)) for i in range(sides)]
        apex = (cx, cy + h, cz)
        for i in range(sides):
            j = (i + 1) % sides
            self.tri(base[j], base[i], apex, col if i % 2 == 0 else (col2 or col))
            self.tri((cx, cy, cz), base[i], base[j], col)

    def crystal(self, bx, by, bz, r, h, col, col2, tilt_x=0.0, tilt_z=0.0, sides=6):
        """Hexagonal prism with a pointed tip."""
        def tf(x, y, z):
            # tilt around x then z, from the base point
            y1 = y * math.cos(tilt_x) - z * math.sin(tilt_x)
            z1 = y * math.sin(tilt_x) + z * math.cos(tilt_x)
            x2 = x * math.cos(tilt_z) - y1 * math.sin(tilt_z)
            y2 = x * math.sin(tilt_z) + y1 * math.cos(tilt_z)
            return (bx + x2, by + y2, bz + z1)
        body = h * 0.72
        ring_b = [tf(r * math.cos(2 * math.pi * i / sides), 0, r * math.sin(2 * math.pi * i / sides)) for i in range(sides)]
        ring_t = [tf(r * math.cos(2 * math.pi * i / sides), body, r * math.sin(2 * math.pi * i / sides)) for i in range(sides)]
        tip = tf(0, h, 0)
        for i in range(sides):
            j = (i + 1) % sides
            c = col if i % 2 == 0 else col2
            self.quad(ring_b[j], ring_b[i], ring_t[i], ring_t[j], c)
            self.tri(ring_t[j], ring_t[i], tip, col2 if i % 2 == 0 else col)

    def rock(self, cx, cy, cz, r, col, col2, seed, squash=0.75, sides=7, rings=4):
        rnd = random.Random(seed)
        rows = []
        for k in range(rings + 1):
            phi = math.pi * k / rings
            row = []
            for i in range(sides):
                th = 2 * math.pi * i / sides + (0.3 if k % 2 else 0)
                rr = r * (0.8 + 0.35 * rnd.random()) if 0 < k < rings else r
                x = rr * math.sin(phi) * math.cos(th)
                z = rr * math.sin(phi) * math.sin(th)
                y = r * math.cos(phi) * squash
                row.append((cx + x, cy + y + r * squash * 0.55, cz + z))
            rows.append(row)
        for k in range(rings):
            for i in range(sides):
                j = (i + 1) % sides
                c = col if (i + k) % 3 else col2
                a, b, cc, d = rows[k][i], rows[k][j], rows[k + 1][j], rows[k + 1][i]
                if k == 0:
                    self.tri(a, cc, d, c)
                elif k == rings - 1:
                    self.tri(a, b, d, c)
                else:
                    self.quad(a, b, cc, d, c)

    def flat(self, x0, z0, x1, z1, y, col):
        self.quad((x0, y, z1), (x1, y, z1), (x1, y, z0), (x0, y, z0), col)

    def add(self, other, dx=0, dy=0, dz=0, rot=0.0, s=1.0):
        c, sn = math.cos(rot), math.sin(rot)
        for t, (a, b, cc, col) in enumerate(other.tris):
            out = []
            for (x, y, z) in (a, b, cc):
                x, y, z = x * s, y * s, z * s
                out.append((dx + x * c + z * sn, dy + y, dz - x * sn + z * c))
            if t in other.vcols:
                self.vcols[len(self.tris)] = other.vcols[t]
            self.tris.append((out[0], out[1], out[2], col))

    def data(self):
        import struct, base64
        v, c, k, vc = [], [], [], []
        for t, (a, b, cc, col) in enumerate(self.tris):
            for n, p in enumerate((a, b, cc)):
                v.extend(p)
                k.append(int(round(min(255, 128 * shade_noise(p))) if self.wobble else 128))
                if self.vcols:
                    rgb = self.vcols[t][n] if t in self.vcols else hexrgb(PALETTE[col][0])
                    vc.extend(int(max(0, min(255, x))) for x in rgb)
            c.append(col)
        out = {'v': base64.b64encode(struct.pack('<%df' % len(v), *v)).decode(), 'c': base64.b64encode(bytes(c)).decode(),
               'k': base64.b64encode(bytes(k)).decode()}
        if self.smooth:
            out['s'] = 1
        if vc:
            out['vc'] = base64.b64encode(bytes(vc)).decode()
        return out

# --------------------------------------------------------------------------- models
M = {}

HERO_STYLE = os.environ.get('HERO_STYLE', 'A')
HS = {   # body proportions per style (A: classic chunky, B: same but faceted, C: chunky with beard and jaw)
    'A': dict(smooth=True, sides=8, head=(0.155, 0.175, 0.165), chest=0.29, waist=0.21, depth=0.165, arm=0.098, hand=0.078,
              leg=0.125, hip=0.8, shoulder=0.34, beard=False),
    'B': dict(smooth=False, sides=6, head=(0.155, 0.175, 0.165), chest=0.29, waist=0.21, depth=0.165, arm=0.098, hand=0.078,
              leg=0.125, hip=0.8, shoulder=0.34, beard=False),
    'C': dict(smooth=True, sides=8, head=(0.16, 0.18, 0.17), chest=0.31, waist=0.23, depth=0.18, arm=0.105, hand=0.082,
              leg=0.13, hip=0.78, shoulder=0.36, beard=True),
}[HERO_STYLE]

def m_hero():
    """2007-era adventurer: big head, broad chest, thick limbs, big hands and boots."""
    q = HS
    sm, sd = q['smooth'], q['sides']
    hx, hy, hz = q['head']
    cw, ww, dp = q['chest'], q['waist'], q['depth']
    parts = {}
    t = Mesh(smooth=sm)         # torso, origin at hips; front is -z
    t.loft([(-0.10, ww * 0.95, dp * 0.8, 'pants'), (0.0, ww, dp * 0.82, 'belt'), (0.07, ww * 1.02, dp * 0.85, 'shirt'),
            (0.28, cw * 0.88, dp * 0.95, 'shirt'), (0.46, cw, dp, 'shirt'), (0.57, cw * 0.97, dp * 0.9, 'accent'),
            (0.63, cw * 0.62, dp * 0.72, 'accent'), (0.665, 0.085, 0.075, 'skin')], sides=sd, phase=math.pi / sd)
    t.box(ww * 0.6, 0.03, -dp * 0.82, 0.08, 0.075, 0.03, 'gold')     # belt buckle
    t.box(-ww * 0.95, 0.0, 0.03, 0.09, 0.14, 0.11, 'boots')         # pouch on the hip
    parts['torso'] = t
    h = Mesh(smooth=sm)         # head, origin at neck
    h.loft([(0.0, 0.075, 0.07, 'skin'), (0.08, 0.08, 0.075, 'skin')], sides=6, cap_bottom=False, cap_top=False)
    cy = hy + 0.04
    h.ellipsoid(0, cy, 0.0, hx, hy, hz, 'skin', seg=8, rings=6)
    h.loft([(cy - hy * 0.75, hx * 0.62, hz * 0.6, 'skin', -0.025), (cy - hy * 0.25, hx * 0.92, hz * 0.85, 'skin', -0.01)],
           sides=8, cap_top=False)                               # jaw
    def fz(x, y, out=0.006):
        # front surface of the head ellipsoid at (x, y), nudged outward
        u = 1.0 - (x / hx) ** 2 - ((y - cy) / hy) ** 2
        return -hz * math.sqrt(max(0.05, u)) - out
    def fq(x0, y0, x1, y1, col, out=0.006):
        fl.quad((x0, y1, fz(x0, y1, out)), (x1, y1, fz(x1, y1, out)), (x1, y0, fz(x1, y0, out)), (x0, y0, fz(x0, y0, out)), col)
    fl = Mesh()                 # face details (flat)
    ey = cy + hy * 0.1
    for x in (-hx * 0.36, hx * 0.36):
        fq(x - 0.018, ey - 0.013, x + 0.018, ey + 0.013, 'eye')
        fq(x - 0.026, ey + 0.026, x + 0.026, ey + 0.036, 'hair')
    ny = cy - hy * 0.12
    tip = (0, ny, fz(0, ny) - 0.035)
    l, r, top = (-0.024, ny - 0.02, fz(-0.024, ny - 0.02)), (0.024, ny - 0.02, fz(0.024, ny - 0.02)), (0, ny + 0.06, fz(0, ny + 0.06))
    fl.tri(tip, l, r, 'skin'); fl.tri(tip, r, top, 'skin'); fl.tri(tip, top, l, 'skin')   # nose
    my = cy - hy * 0.42
    fq(-0.035, my - 0.006, 0.035, my + 0.006, 'eye')
    h.add(fl)
    # v5 faces (index 0 = plain): 1 freckles, 2 moustache, 3 short beard, 4 scar, 5 grand beard
    def fquad(m, x0, y0, x1, y1, col, out=0.008):
        m.quad((x0, y1, fz(x0, y1, out)), (x1, y1, fz(x1, y1, out)), (x1, y0, fz(x1, y0, out)), (x0, y0, fz(x0, y0, out)), col)
    f1 = Mesh()
    for (x, y) in ((-0.07, -0.02), (-0.05, -0.04), (-0.09, -0.045), (0.07, -0.02), (0.05, -0.04), (0.09, -0.045), (0.0, 0.02)):
        fquad(f1, x - 0.009, cy + y - 0.008, x + 0.009, cy + y + 0.008, 'boots')
    f2 = Mesh()
    fquad(f2, -0.06, my + 0.008, 0.0, my + 0.03, 'hair', 0.012)
    fquad(f2, 0.0, my + 0.008, 0.06, my + 0.03, 'hair', 0.012)
    fquad(f2, -0.075, my - 0.02, -0.05, my + 0.012, 'hair', 0.012)
    fquad(f2, 0.05, my - 0.02, 0.075, my + 0.012, 'hair', 0.012)
    f3 = Mesh()
    f3.loft([(cy - hy * 0.95, hx * 0.5, hz * 0.48, 'hair', -0.035), (cy - hy * 0.6, hx * 0.8, hz * 0.76, 'hair', -0.02),
             (cy - hy * 0.35, hx * 0.98, hz * 0.94, 'hair', -0.004)], sides=8, cap_top=False)
    f4 = Mesh()
    for i in range(4):
        x, y = hx * 0.2 + i * 0.022, ey + 0.06 - i * 0.04
        fquad(f4, x - 0.006, y - 0.022, x + 0.006, y + 0.022, 'banner', 0.01)
    f5 = Mesh()
    f5.loft([(cy - hy * 1.45, hx * 0.18, hz * 0.2, 'hair', -0.11), (cy - hy * 1.1, hx * 0.5, hz * 0.48, 'hair', -0.08),
             (cy - hy * 0.7, hx * 0.82, hz * 0.78, 'hair', -0.04), (cy - hy * 0.3, hx * 1.0, hz * 0.96, 'hair', -0.005)], sides=8, cap_top=False)
    fquad(f5, -0.065, my + 0.01, 0.065, my + 0.035, 'hair', 0.014)
    for i, fm in enumerate((f1, f2, f3, f4, f5)):
        parts['face%d' % (i + 1)] = fm
    if q['beard']:
        h.loft([(cy - hy * 1.02, hx * 0.42, hz * 0.4, 'hair', -0.07), (cy - hy * 0.7, hx * 0.75, hz * 0.72, 'hair', -0.04),
                (cy - hy * 0.3, hx * 1.0, hz * 0.95, 'hair', -0.005)], sides=8, cap_top=False)
    parts['head'] = h
    styles = []
    capy, capr = cy + 0.01, (hx * 1.08, hy * 1.04, hz * 1.07)
    def back_hair(m, scale=1.0):
        m.ellipsoid(0, capy - 0.005, 0.018, capr[0] * scale, capr[1] * scale, capr[2] * scale, 'hair', seg=8, rings=6, top_frac=0.84, back_min=-0.05)
    hs = Mesh(smooth=sm)        # 0 short crop
    hs.ellipsoid(0, capy, 0.012, *capr, 'hair', seg=8, rings=6, top_frac=0.5)
    back_hair(hs)
    styles.append(hs)
    hs = Mesh(smooth=sm)        # 1 long hair to the shoulders
    hs.ellipsoid(0, capy, 0.012, capr[0] * 1.02, capr[1], capr[2] * 1.02, 'hair', seg=8, rings=6, top_frac=0.5)
    back_hair(hs, 1.03)
    hs.loft([(cy + 0.05, hx * 1.1, 0.08, 'hair', 0.08), (cy - 0.16, hx * 1.15, 0.07, 'hair', 0.1), (cy - 0.3, hx * 1.2, 0.05, 'hair', 0.11)], sides=6, phase=math.pi / 6)
    styles.append(hs)
    hs = Mesh(smooth=sm)        # 2 braided crest: cap + braid down the back
    hs.ellipsoid(0, capy, 0.012, *capr, 'hair', seg=8, rings=6, top_frac=0.5)
    back_hair(hs)
    for i in range(4):
        hs.ellipsoid(0, cy - 0.05 - i * 0.08, hz + 0.015 + i * 0.012, 0.04, 0.05, 0.04, 'hair', seg=6, rings=4)
    hs.ellipsoid(0, cy + hy * 1.1, 0.0, 0.035, 0.045, hz * 0.7, 'accent', seg=6, rings=4)
    styles.append(hs)
    hs = Mesh(smooth=sm)        # 3 mohawk
    hs.ellipsoid(0, capy, 0.012, capr[0] * 0.99, capr[1] * 0.97, capr[2], 'hair', seg=8, rings=6, top_frac=0.42)
    hs.loft([(cy + hy * 0.6, 0.035, hz * 1.05, 'hair'), (cy + hy * 1.3, 0.025, hz * 0.85, 'hair'), (cy + hy * 1.5, 0.01, hz * 0.5, 'hair')], sides=6)
    styles.append(hs)
    for i, hs in enumerate(styles):
        parts['hair%d' % i] = hs
    ar, hr, lr = q['arm'], q['hand'], q['leg']
    hip = q['hip']
    for side in ('l', 'r'):
        a = Mesh(smooth=sm)     # arm, origin at shoulder, hangs down -y
        a.ellipsoid(0, -0.02, 0, ar * 1.15, ar * 1.05, ar * 1.12, 'shirt', seg=6, rings=4)
        a.loft([(0.0, ar, ar * 1.02, 'shirt'), (-0.23, ar * 0.84, ar * 0.86, 'shirt'), (-0.26, ar * 0.9, ar * 0.92, 'accent'),
                (-0.29, ar * 0.82, ar * 0.84, 'shirt'), (-0.42, ar * 0.72, ar * 0.74, 'shirt')], sides=6)
        a.ellipsoid(0, -0.49, -0.005, hr * 0.85, hr * 1.1, hr, 'skin', seg=6, rings=4)
        parts['arm_' + side] = a
        l = Mesh(smooth=sm)     # leg, origin at hip joint
        l.loft([(0.02, lr, lr * 1.05, 'pants'), (-hip * 0.45, lr * 0.78, lr * 0.82, 'pants'), (-hip * 0.78, lr * 0.66, lr * 0.7, 'pants'),
                (-hip * 0.82, lr * 0.78, lr * 0.8, 'boots')], sides=6, phase=math.pi / 6)
        l.ellipsoid(0, -hip + 0.085, -0.05, lr * 0.72, 0.085, lr * 1.35, 'boots', seg=6, rings=4)
        l.box(0, -hip + 0.018, -0.05, lr * 1.45, 0.036, lr * 2.6, 'boots')     # sole
        parts['leg_' + side] = l
    p = Mesh()                  # pickaxe, origin at the grip, handle along +y, head across z
    p.tube((0, -0.12, 0), (0, 0.8, 0), 0.028, 0.032, 'wood', sides=6)
    p.tube((0, 0.76, 0), (0, 0.79, -0.18), 0.05, 0.038, 'pick', sides=5)
    p.tube((0, 0.79, -0.18), (0, 0.7, -0.36), 0.038, 0.008, 'pick', sides=5)
    p.tube((0, 0.76, 0), (0, 0.79, 0.18), 0.05, 0.038, 'pick', sides=5)
    p.tube((0, 0.79, 0.18), (0, 0.7, 0.36), 0.038, 0.008, 'pick', sides=5)
    p.box(0, 0.77, 0, 0.09, 0.11, 0.1, 'iron_d')
    parts['pickaxe'] = p
    for k, v in parts.items():
        M['hero_' + k] = v

HERO_RIG = {   # part -> [model, parent, offset]
    'torso': ['hero_torso', '', [0, HS['hip'] + 0.04, 0]],
    'head': ['hero_head', 'torso', [0, 0.65, 0]],
    'hair': ['hero_hair0', 'head', [0, 0, 0]],
    'arm_l': ['hero_arm_l', 'torso', [-HS['shoulder'], 0.53, 0]],
    'arm_r': ['hero_arm_r', 'torso', [HS['shoulder'], 0.53, 0]],
    'leg_l': ['hero_leg_l', '', [-HS['waist'] * 0.55, HS['hip'], 0]],
    'leg_r': ['hero_leg_r', '', [HS['waist'] * 0.55, HS['hip'], 0]],
    'pickaxe': ['hero_pickaxe', 'arm_r', [0, -0.5, 0]],
}
FACES = 6
POSES = {   # arm swing angles (degrees, rotation about x) for the strike animation
    'idle': {'arm_r': 8, 'arm_l': 8}, 'raise': {'arm_r': 165, 'arm_l': 150}, 'strike': {'arm_r': 62, 'arm_l': 55},
}
APPEARANCE = {
    'skin': ['#e0b08a', '#c8946a', '#a87650', '#8a5c3c', '#5e3e28'],
    'hair_color': ['#4a3423', '#1e1b19', '#a8853f', '#8f3a26', '#c8c4b8', '#3f7a6e'],
    'shirt': ['#6e4a2c', '#4e5c30', '#365a38', '#2e4470', '#7a2a26', '#3e2c52'],
    'pants': ['#3d3a35', '#4e3b28', '#8a7a58', '#5c6066'],
    'accent': ['#3f7a6e', '#b8902e', '#a8552a', '#6e4e9a', '#e8b04a'],
    'pick': {'starter': '#8d8d8d', 'iron': '#9aa0a4', 'crystal': '#2A9D8F', 'void': '#6a3fa8'},
}

PATH_ANGLES = (0, 52, 105, 160, 255, 308)

def town_height(x, z):
    """Flat where people walk, rolling hills beyond the buildings."""
    r = math.hypot(x, z)
    if r < 16.5:
        return 0.0
    t = min(1.0, (r - 16.5) / 9.0)
    n = 0.6 + 0.4 * math.sin(x * 0.31 + 1.7) * math.cos(z * 0.27 - 0.4) + 0.25 * math.sin(x * 0.9 + z * 0.7)
    return t * t * (3.0 * n + 0.6)

def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)

def mix(c1, c2, t):
    return [c1[i] + (c2[i] - c1[i]) * t for i in range(3)]

def town_colour(x, z):
    r = math.hypot(x, z)
    n1 = 0.5 + 0.5 * math.sin(x * 0.53 + 0.3) * math.sin(z * 0.47 + 1.1)
    n2 = shade_noise((x, 0.0, z))
    grass = mix(hexrgb('#55752b'), hexrgb('#3e5c1f'), n1)
    grass = mix(grass, hexrgb('#6f7a35'), 0.35 * max(0.0, math.sin(x * 0.21 - z * 0.17)))   # dry patches
    col = grass
    # dirt paths out to each building
    pd = 99.0
    for ang in PATH_ANGLES:
        th = math.radians(ang)
        dx, dz = math.sin(th), -math.cos(th)
        along = x * dx + z * dz
        if 0 < along < 12.5:
            pd = min(pd, abs(x * dz - z * dx))
    col = mix(col, mix(hexrgb('#6e5636'), hexrgb('#5c4830'), n1), 1 - smoothstep(0.9, 1.9, pd + 0.6 * (n2 - 1)))
    # cobbled plaza
    stone = mix(hexrgb('#7f786c'), hexrgb('#625b51'), 0.5 + 0.5 * math.sin(x * 2.3) * math.sin(z * 2.1))
    col = mix(col, stone, 1 - smoothstep(7.2, 8.2, r + 0.5 * (n2 - 1)))
    # darker, mossier grass on the hills
    col = mix(col, hexrgb('#34501c'), 0.6 * smoothstep(17, 25, r))
    return [c * n2 for c in col]

def heightfield(x0, x1, z0, z1, cell, hfun, cfun, col='grass'):
    m = Mesh(smooth=True, wobble=False)
    nx, nz = int(round((x1 - x0) / cell)), int(round((z1 - z0) / cell))
    for i in range(nx):
        for k in range(nz):
            xa, xb, za, zb = x0 + i * cell, x0 + (i + 1) * cell, z0 + k * cell, z0 + (k + 1) * cell
            p = [(xa, hfun(xa, za), za), (xb, hfun(xb, za), za), (xb, hfun(xb, zb), zb), (xa, hfun(xa, zb), zb)]
            c = [cfun(q[0], q[2]) for q in p]
            # winding so the top faces up (+y)
            m.tri(p[0], p[3], p[2], col, vc=[c[0], c[3], c[2]])
            m.tri(p[0], p[2], p[1], col, vc=[c[0], c[2], c[1]])
    return m

def m_town_props():
    M['town_ground'] = heightfield(-30, 30, -30, 30, 1.25, town_height, town_colour)
    mon = Mesh()        # Pulse monument
    mon.cylinder(0, 0, 0, 1.6, 0.3, 'stone', 8, 'stone_l')
    mon.cylinder(0, 0.3, 0, 1.1, 0.5, 'stone_d', 8, 'stone')
    mon.crystal(0, 0.8, 0, 0.45, 3.2, 'teal', 'teal_l')
    mon.crystal(0.55, 0.8, 0.15, 0.25, 1.5, 'teal', 'teal_l', 0.1, -0.4)
    mon.crystal(-0.5, 0.8, -0.1, 0.22, 1.3, 'teal', 'teal_l', -0.15, 0.45)
    mon.crystal(0.05, 0.8, 0.55, 0.2, 1.1, 'teal', 'teal_l', 0.45, 0.1)
    M['monument'] = mon
    t = Mesh()          # evergreen: stacked faceted cones
    t.tube((0, 0, 0), (0, 1.0, 0), 0.2, 0.14, 'wood_d', sides=6)
    t.cone(0, 0.7, 0, 1.25, 1.5, 'pine', 8, 'pine_d')
    t.cone(0, 1.6, 0, 0.98, 1.3, 'pine_d', 8, 'pine')
    t.cone(0, 2.45, 0, 0.68, 1.15, 'pine', 8, 'pine_d')
    M['pine'] = t
    t = Mesh(smooth=True)   # common leafy tree: thick trunk, lumpy round crown
    t.loft([(0, 0.32, 0.32, 'wood_d'), (0.25, 0.22, 0.22, 'wood'), (1.5, 0.17, 0.17, 'wood'), (1.9, 0.2, 0.2, 'wood')], sides=7, cap_top=False)
    t.tube((0, 1.5, 0), (0.55, 2.2, 0.1), 0.1, 0.06, 'wood', sides=5)
    t.tube((0, 1.6, 0), (-0.5, 2.3, -0.2), 0.1, 0.06, 'wood', sides=5)
    for (x, y, z, r, sd) in ((0, 2.75, 0, 1.25, 1), (0.75, 2.45, 0.35, 0.85, 2), (-0.7, 2.5, -0.3, 0.9, 3), (0.1, 3.35, -0.2, 0.85, 4), (-0.3, 2.4, 0.65, 0.75, 5)):
        t.ellipsoid(x, y, z, r, r * 0.85, r, 'leaf', seg=7, rings=5, noise=0.16, seed=sd, col2='leaf_d')
    M['tree'] = t
    t = Mesh(smooth=True)   # oak: wider, flatter crown
    t.loft([(0, 0.42, 0.42, 'wood_d'), (0.3, 0.3, 0.3, 'wood_d'), (1.3, 0.24, 0.24, 'wood'), (1.7, 0.3, 0.3, 'wood')], sides=7, cap_top=False)
    for (x, y, z, r, sd) in ((0, 2.5, 0, 1.6, 11), (1.1, 2.2, 0.2, 1.0, 12), (-1.1, 2.25, -0.1, 1.05, 13), (0.2, 2.3, 1.0, 0.95, 14), (-0.1, 2.3, -1.05, 0.95, 15), (0.1, 3.1, 0, 1.0, 16)):
        t.ellipsoid(x, y, z, r, r * 0.7, r, 'leaf_d', seg=7, rings=5, noise=0.15, seed=sd, col2='leaf')
    M['oak'] = t
    lp = Mesh()         # lamp post
    lp.tube((0, 0, 0), (0, 2.35, 0), 0.09, 0.05, 'iron_d', sides=6)
    lp.box(0, 2.5, 0, 0.26, 0.3, 0.26, 'lamp')
    lp.cone(0, 2.64, 0, 0.26, 0.24, 'iron_d', 4)
    lp.box(0, 0.08, 0, 0.3, 0.16, 0.3, 'stone_d')
    M['lamp_post'] = lp
    for i in range(3):
        r = Mesh()
        r.rock(0, 0, 0, 0.5 + 0.25 * i, 'stone', 'stone_d', 10 + i)
        M['rock%d' % i] = r

def window(m, x, y, z, face, w=0.7, h=0.8):
    """Dark window with a timber frame on a wall facing +z (face=1) or +x (face=2)."""
    if face == 1:
        m.box(x, y, z + 0.02, w, h, 0.06, 'door')
        m.box(x, y - h / 2 - 0.05, z + 0.06, w + 0.2, 0.1, 0.12, 'wood_d')
        m.box(x, y + h / 2 + 0.04, z + 0.05, w + 0.14, 0.08, 0.1, 'wood_d')
        m.box(x, y, z + 0.06, 0.06, h, 0.06, 'wood_d')
    else:
        m.box(z + 0.02, y, x, 0.06, h, w, 'door')
        m.box(z + 0.06, y - h / 2 - 0.05, x, 0.12, 0.1, w + 0.2, 'wood_d')
        m.box(z + 0.05, y + h / 2 + 0.04, x, 0.1, 0.08, w + 0.14, 'wood_d')
        m.box(z + 0.06, y, x, 0.06, h, 0.06, 'wood_d')

def house_base(m, w, d, h, wall, roof, roof2, door=True, door_col='door'):
    m.box(0, h / 2, 0, w, h, d, wall)
    m.box(0, 0.15, 0, w + 0.24, 0.3, d + 0.24, 'stone_d')
    for x in (-w / 2, w / 2):                     # corner quoins
        for z in (-d / 2, d / 2):
            m.box(x, h / 2, z, 0.3, h, 0.3, 'stone_d' if wall != 'stone_d' else 'stone')
    m.prism_roof(0, h, 0, w + 0.6, 1.7, d + 0.6, roof, roof2)
    m.box(0, h + 0.02, 0, w + 0.62, 0.14, d + 0.62, roof2)   # eaves
    m.box(0, h + 1.72, 0, w + 0.7, 0.14, 0.24, roof2)       # ridge cap
    if door:
        m.box(0, 0.9, d / 2 + 0.03, 1.1, 1.8, 0.08, door_col)
        m.box(0, 1.85, d / 2 + 0.05, 1.3, 0.14, 0.1, 'wood_d')

def m_buildings():
    f = Mesh()          # FORGE: stone smithy with chimney and glowing hearth
    house_base(f, 5.0, 4.0, 2.8, 'stone', 'slate', 'slate_d')
    window(f, 0, 1.6, 2.5, 2); window(f, 0, 1.6, -2.62, 2)
    f.box(1.6, 3.6, -0.6, 0.9, 2.6, 0.9, 'stone_d')
    f.box(1.6, 4.95, -0.6, 1.0, 0.15, 1.0, 'stone')
    f.box(-1.6, 1.0, 2.06, 1.2, 0.9, 0.06, 'fire')
    f.box(2.9, 0.45, 1.2, 1.1, 0.5, 0.6, 'iron_d')        # anvil outside
    f.box(2.9, 0.75, 1.2, 1.3, 0.14, 0.45, 'iron')
    f.box(2.9, 0.2, 1.2, 0.6, 0.4, 0.5, 'wood_d')
    M['forge'] = f
    t = Mesh()          # TAVERN: timber house with hanging sign
    house_base(t, 5.5, 4.2, 3.0, 'plaster', 'thatch', 'thatch_d')
    window(t, 0, 1.7, 2.75, 2); window(t, 0, 1.7, -2.87, 2)
    for z in (-1.0, 1.0):
        t.box(2.78, 1.5, z, 0.1, 3.0, 0.16, 'wood_d'); t.box(-2.78, 1.5, z, 0.1, 3.0, 0.16, 'wood_d')
    for x in (-2.7, 2.7):
        t.box(x, 1.5, 2.12, 0.18, 3.0, 0.1, 'wood_d')
    t.box(0, 2.95, 2.12, 5.5, 0.16, 0.1, 'wood_d')
    t.box(-1.8, 1.6, 2.12, 0.9, 0.7, 0.06, 'lamp')
    t.box(1.8, 1.6, 2.12, 0.9, 0.7, 0.06, 'lamp')
    t.box(2.2, 2.4, 2.6, 0.08, 0.08, 1.0, 'iron_d')
    t.box(2.2, 2.0, 3.0, 0.9, 0.6, 0.06, 'wood')
    t.box(2.2, 2.0, 3.04, 0.5, 0.3, 0.02, 'gold')
    M['tavern'] = t
    gh = Mesh()         # GAMBIT HALL: tall hall, purple roof, crystal sign
    house_base(gh, 6.0, 5.0, 4.2, 'stone_l', 'hall_roof', 'slate_d')
    window(gh, -1.2, 2.4, 3.0, 2); window(gh, 1.2, 2.4, 3.0, 2); window(gh, -1.2, 2.4, -3.12, 2); window(gh, 1.2, 2.4, -3.12, 2)
    for x in (-2.2, -0.9, 0.9, 2.2):
        gh.box(x, 2.1, 2.62, 0.4, 4.2, 0.3, 'plaster')
    gh.box(0, 4.35, 2.62, 6.2, 0.3, 0.4, 'gold')
    gh.crystal(-0.5, 4.5, 2.6, 0.22, 1.0, 'void', 'void_l')
    gh.crystal(0.5, 4.5, 2.6, 0.22, 1.0, 'teal', 'teal_l')
    gh.crystal(0, 4.5, 2.6, 0.28, 1.4, 'lamp', 'gold')
    M['gambit_hall'] = gh
    a = Mesh()          # ARENA: round stone ring with banners
    sides = 14
    for i in range(sides):
        if i in (13, 0):
            continue                          # opening facing +z (toward the plaza)
        th = 2 * math.pi * (i + 0.5) / sides + math.pi / 2
        x, z = 3.6 * math.cos(th), 3.6 * math.sin(th)
        a.box(x, 0.9, z, 1.7, 1.8, 0.6, 'stone' if i % 2 else 'stone_l', rot=-th + math.pi / 2)
    a.cylinder(0, 0, 0, 3.2, 0.05, 'dirt', 14)
    for x, col in ((-2.2, 'teal_d'), (2.2, 'banner')):
        a.box(x, 2.2, -3.4, 0.12, 4.4, 0.12, 'wood_d')
        a.box(x, 3.2, -3.3, 1.1, 1.6, 0.06, col)
        a.box(x, 3.95, -3.27, 1.15, 0.12, 0.06, 'gold')
    M['arena'] = a
    b = Mesh()          # NOTICE BOARD
    b.box(-1.0, 1.1, 0, 0.16, 2.2, 0.16, 'wood_d')
    b.box(1.0, 1.1, 0, 0.16, 2.2, 0.16, 'wood_d')
    b.box(0, 1.5, 0, 2.4, 1.3, 0.12, 'wood')
    for i, (x, y) in enumerate(((-0.6, 1.7), (0.1, 1.55), (0.7, 1.75), (-0.3, 1.25), (0.55, 1.2))):
        b.box(x, y, 0.08, 0.45, 0.35, 0.02, 'parch')
    b.prism_roof(0, 2.2, 0, 2.7, 0.5, 0.7, 'thatch', 'thatch_d')
    M['notice_board'] = b
    me = Mesh()         # MINE ENTRANCE: rocky mound with timber frame
    rnd = random.Random(8)
    for i in range(9):
        th = math.pi * (i / 8.0)
        me.rock(3.2 * math.cos(th), -0.3, -0.8 - 1.4 * math.sin(th) + rnd.uniform(-0.3, 0.3), 1.3 + rnd.random() * 0.5, 'stone', 'stone_d', 40 + i, squash=1.0)
    me.rock(0, 1.6, -1.6, 2.2, 'stone', 'stone_d', 77, squash=0.8)
    me.box(0, 1.2, -0.3, 2.2, 2.4, 0.4, 'door')
    me.box(-1.25, 1.3, 0.05, 0.3, 2.6, 0.3, 'wood')
    me.box(1.25, 1.3, 0.05, 0.3, 2.6, 0.3, 'wood')
    me.box(0, 2.7, 0.05, 3.0, 0.32, 0.36, 'wood_d')
    me.box(0, 2.95, 0.25, 1.4, 0.4, 0.06, 'parch')
    me.box(1.0, 1.5, 0.3, 0.3, 0.3, 0.3, 'lamp')
    for i in range(5):                          # rails coming out
        me.box(0, 0.04, 0.6 + i * 0.7, 1.5, 0.08, 0.18, 'wood_d')
    me.box(-0.5, 0.1, 2.0, 0.08, 0.08, 3.4, 'iron')
    me.box(0.5, 0.1, 2.0, 0.08, 0.08, 3.4, 'iron')
    M['mine_entrance'] = me

def m_mine():
    def cave_h(x, z):
        r = math.hypot(x, z + 1)
        bump = 0.18 * math.sin(x * 1.3 + 0.5) * math.cos(z * 1.1 - 0.3)
        return smoothstep(9.0, 12.5, r) * 2.6 + (bump if r > 8.5 else 0.0)
    def cave_c(x, z):
        n1 = 0.5 + 0.5 * math.sin(x * 0.7 + 1.0) * math.sin(z * 0.6 - 0.4)
        col = mix(hexrgb('#5a4c3e'), hexrgb('#433a32'), n1)
        col = mix(col, hexrgb('#6a6058'), 0.4 * max(0.0, math.sin(x * 0.35 + z * 0.4)))
        return [c * shade_noise((x, 1.0, z)) for c in col]
    fl = heightfield(-14, 14, -15, 13, 1.0, cave_h, cave_c, 'cave_floor')
    rnd = random.Random(5)
    M['cave_floor'] = fl
    w = Mesh()          # ring of cave wall rocks (open toward +z, where the player enters)
    for i in range(26):
        th = math.pi * (0.05 + 1.9 * i / 25.0) + math.pi / 2 * 0
        ang = math.radians(200 + 140 * i / 25.0) if False else 2 * math.pi * i / 26
        if math.sin(ang) > 0.82:
            continue
        r = 11 + rnd.uniform(-0.6, 0.6)
        w.rock(r * math.cos(ang), -0.6, r * math.sin(ang) - 1, 2.2 + rnd.random() * 1.2, 'cave_wall', 'stone_d', 100 + i, squash=1.3)
    M['cave_walls'] = w
    s = Mesh()          # timber support frame
    s.box(-1.4, 1.6, 0, 0.3, 3.2, 0.3, 'wood')
    s.box(1.4, 1.6, 0, 0.3, 3.2, 0.3, 'wood')
    s.box(0, 3.3, 0, 3.4, 0.3, 0.36, 'wood_d')
    s.box(-1.4, 2.6, 0, 0.34, 0.12, 0.34, 'iron_d')
    s.box(1.4, 2.6, 0, 0.34, 0.12, 0.34, 'iron_d')
    s.box(0, 2.9, 0.22, 0.26, 0.3, 0.26, 'lamp')
    M['support'] = s
    c = Mesh()          # mine cart with ore
    c.box(0, 0.65, 0, 1.4, 0.7, 0.9, 'iron_d')
    c.box(0, 1.0, 0, 1.5, 0.08, 1.0, 'iron')
    for x in (-0.45, 0.45):
        for z in (-0.5, 0.5):
            c.box(x, 0.25, z, 0.32, 0.32, 0.08, 'coal')
    c.rock(-0.3, 0.8, 0, 0.3, 'coal', 'stone_d', 3)
    c.rock(0.25, 0.8, 0.1, 0.28, 'rust', 'stone_d', 4)
    c.crystal(0.1, 0.95, -0.2, 0.1, 0.45, 'teal', 'teal_l')
    M['cart'] = c
    for name, rock, rock2, cry, cry2, n in (('vein_coal', 'stone', 'stone_l', 'coal', 'iron_d', 4),
                                            ('vein_iron', 'stone', 'rust', 'rust', 'iron', 4),
                                            ('vein_crystal', 'stone_d', 'cave_wall', 'teal', 'teal_l', 6),
                                            ('vein_void', 'cave_wall', 'stone_d', 'void', 'void_l', 7)):
        v = Mesh()
        v.rock(0, 0, 0, 1.2, rock, rock2, sum(map(ord, name)) % 1000, squash=0.9)
        rr = random.Random(len(name) * 7)
        for i in range(n):
            ang = 2 * math.pi * i / n + rr.uniform(-0.3, 0.3)
            if name in ('vein_coal', 'vein_iron'):
                v.rock(0.75 * math.cos(ang), 0.9 + rr.uniform(0, 0.4), 0.75 * math.sin(ang), 0.32, cry, cry2, i + 9)
            else:
                v.crystal(0.6 * math.cos(ang), 0.8, 0.6 * math.sin(ang), 0.14 + rr.random() * 0.08, 0.9 + rr.random() * 0.9, cry, cry2,
                          0.5 * math.sin(ang), -0.5 * math.cos(ang))
        if name in ('vein_crystal', 'vein_void'):
            v.crystal(0, 1.2, 0, 0.26, 1.9, cry, cry2)
        M[name] = v
    ex = Mesh()         # exit ladder / daylight shaft
    ex.box(-0.4, 2, 0, 0.12, 4, 0.12, 'wood')
    ex.box(0.4, 2, 0, 0.12, 4, 0.12, 'wood')
    for i in range(7):
        ex.box(0, 0.4 + i * 0.55, 0, 0.8, 0.08, 0.1, 'wood_d')
    ex.box(0, 4.1, 0, 1.4, 0.16, 0.3, 'wood_d')
    ex.box(0.6, 3.2, 0.2, 0.22, 0.26, 0.22, 'lamp')
    ex.box(0, 4.6, -0.2, 0.9, 0.06, 0.06, 'parch')
    M['exit_ladder'] = ex

m_hero(); m_town_props(); m_buildings(); m_mine()

# --------------------------------------------------------------------------- scene layouts
def ring(r, deg):
    a = math.radians(deg)
    return [round(r * math.sin(a), 2), 0, round(-r * math.cos(a), 2)]

TOWN_BUILDINGS = {   # name -> angle around the plaza (0 = north, away from the camera)
    'mine': 0, 'gambit_hall': 52, 'tavern': 105, 'board': 160, 'arena': 255, 'forge': 308,
}
TOWN = [{'m': 'town_ground', 'p': [0, 0, 0], 'r': 0}, {'m': 'monument', 'p': [0, 0, 0], 'r': 0}]
SPOTS = {}
for name, deg in TOWN_BUILDINGS.items():
    model = {'mine': 'mine_entrance', 'gambit_hall': 'gambit_hall', 'tavern': 'tavern', 'board': 'notice_board',
             'arena': 'arena', 'forge': 'forge'}[name]
    dist = 13 if name != 'board' else 8.5
    pos = ring(dist, deg)
    TOWN.append({'m': model, 'p': pos, 'r': -deg})   # door (+z in the model) faces the plaza
    SPOTS['town_' + name] = {'p': ring(dist - (4.6 if name not in ('board', 'arena') else 3.0), deg), 'look': pos}
rnd = random.Random(21)
for i in range(30):
    deg = i * 12 + rnd.uniform(-4, 4)
    if any(abs((deg - d + 180) % 360 - 180) < 16 for d in TOWN_BUILDINGS.values()):
        continue
    p = ring(17 + rnd.uniform(0, 5), deg)
    p[1] = round(town_height(p[0], p[2]) - 0.15, 2)
    TOWN.append({'m': ('tree', 'pine', 'oak', 'tree')[i % 4], 'p': p, 'r': rnd.uniform(0, 360), 's': round(0.85 + rnd.random() * 0.5, 2)})
for i in range(26):     # a second, looser ring of trees up on the hills
    deg = i * 13.8 + rnd.uniform(-5, 5)
    p = ring(23 + rnd.uniform(0, 5), deg)
    p[1] = round(town_height(p[0], p[2]) - 0.2, 2)
    TOWN.append({'m': ('oak', 'tree', 'pine')[i % 3], 'p': p, 'r': rnd.uniform(0, 360), 's': round(0.9 + rnd.random() * 0.5, 2)})
for i, deg in enumerate((25, 80, 135, 205, 230, 285, 335)):
    TOWN.append({'m': 'lamp_post', 'p': ring(8.2, deg), 'r': 0})
for i in range(8):
    deg = rnd.uniform(0, 360)
    p = ring(15 + rnd.uniform(0, 3), deg)
    p[1] = round(town_height(p[0], p[2]) - 0.1, 2)
    TOWN.append({'m': 'rock%d' % (i % 3), 'p': p, 'r': rnd.uniform(0, 360)})
SPOTS['town_spawn'] = {'p': [0, 0, 6.5], 'look': [0, 0, 0]}
TOWN_LIGHTS = [{'p': ring(8.2, d)[:1] + [2.6] + ring(8.2, d)[2:], 'c': '#ffb35c', 'r': 7, 'e': 1.2} for d in (25, 80, 135, 205, 230, 285, 335)]
TOWN_LIGHTS.append({'p': [0, 3, 0], 'c': '#5fe0cf', 'r': 9, 'e': 1.6})

VEIN_SPOTS = {1: (-6.0, -1.5), 2: (-2.6, -6.4), 3: (2.6, -6.4), 4: (6.0, -1.5)}
MINE = [{'m': 'cave_floor', 'p': [0, 0, 0], 'r': 0}, {'m': 'cave_walls', 'p': [0, 0, 0], 'r': 0},
        {'m': 'cart', 'p': [4.2, 0, 4.0], 'r': 25}, {'m': 'exit_ladder', 'p': [0, 0, 8.6], 'r': 0}]
for x, z, r in ((-4.5, 3.0, 20), (4.6, -4.2, -30), (-4.6, -4.2, 30), (0, -9.0, 0)):
    MINE.append({'m': 'support', 'p': [x, 0, z], 'r': r})
MINE_LIGHTS = [{'p': [-6.0, 2.4, 0.6], 'c': '#ffb35c', 'r': 6, 'e': 1.3}, {'p': [-2.6, 2.6, -4.6], 'c': '#ffb35c', 'r': 6, 'e': 1.2},
               {'p': [-4.5, 2.9, 3.2], 'c': '#ffb35c', 'r': 7, 'e': 1.4}, {'p': [4.6, 2.9, -4.0], 'c': '#ffb35c', 'r': 7, 'e': 1.4},
               {'p': [-4.6, 2.9, -4.0], 'c': '#ffb35c', 'r': 7, 'e': 1.4}, {'p': [0, 2.9, -8.8], 'c': '#ffb35c', 'r': 7, 'e': 1.2}]
for tier, (x, z) in VEIN_SPOTS.items():
    model = {1: 'vein_coal', 2: 'vein_iron', 3: 'vein_crystal', 4: 'vein_void'}[tier]
    MINE.append({'m': model, 'p': [x, 0, z], 'r': tier * 40, 'vein': tier})
    d = math.hypot(x, z - 2)
    px, pz = x - (x - 0) / d * 2.0, z - (z - 2) / d * 2.0
    SPOTS['vein%d' % tier] = {'p': [round(px, 2), 0, round(pz, 2)], 'look': [x, 0, z]}
    if tier in (1, 2):   # warm work lamp over the coal and iron seams so they stand out from the walls
        MINE_LIGHTS.append({'p': [x * 0.8, 2.2, z * 0.8 + 0.6], 'c': '#ffd9a0', 'r': 5, 'e': 1.5})
    if tier == 3:
        MINE_LIGHTS.append({'p': [x, 2.0, z], 'c': '#5fe0cf', 'r': 6, 'e': 1.8})
    if tier == 4:
        MINE_LIGHTS.append({'p': [x, 2.0, z], 'c': '#a979f0', 'r': 6, 'e': 1.8})
SPOTS['mine_spawn'] = {'p': [0, 0, 6.5], 'look': [0, 0, 0]}

# --------------------------------------------------------------------------- solid footprints
# Local footprints per model (top-down, x/z): ('c', x, z, r) circles or ('b', cx, cz, half_w, half_d) boxes.
# Transformed by each layout item's position/rotation/scale and exported so the hero walks around them.
def arena_shapes():
    out = []
    for i in range(1, 13):
        th = 2 * math.pi * (i + 0.5) / 14 + math.pi / 2
        out.append(('c', 3.6 * math.cos(th), 3.6 * math.sin(th), 0.85))
    out += [('c', -2.2, -3.4, 0.2), ('c', 2.2, -3.4, 0.2)]
    return out

FOOTPRINTS = {
    'monument': [('c', 0, 0, 1.7)],
    'forge': [('b', 0, 0, 2.65, 2.15), ('c', 2.9, 1.2, 0.75)],
    'tavern': [('b', 0, 0, 2.9, 2.25)],
    'gambit_hall': [('b', 0, 0, 3.15, 2.65)],
    'notice_board': [('b', 0, 0, 1.3, 0.25)],
    'mine_entrance': [('b', 0, -1.6, 4.2, 1.9), ('c', -1.25, 0.05, 0.25), ('c', 1.25, 0.05, 0.25)],
    'arena': arena_shapes(),
    'lamp_post': [('c', 0, 0, 0.22)],
    'pine': [('c', 0, 0, 0.35)], 'tree': [('c', 0, 0, 0.45)], 'oak': [('c', 0, 0, 0.55)],
    'rock0': [('c', 0, 0, 0.55)], 'rock1': [('c', 0, 0, 0.75)], 'rock2': [('c', 0, 0, 0.95)],
    'cart': [('b', 0, 0, 0.8, 0.55)],
    'support': [('c', -1.4, 0, 0.25), ('c', 1.4, 0, 0.25)],
    'vein_coal': [('c', 0, 0, 1.25)], 'vein_iron': [('c', 0, 0, 1.25)], 'vein_crystal': [('c', 0, 0, 1.25)], 'vein_void': [('c', 0, 0, 1.25)],
    'exit_ladder': [('b', 0, 0, 0.6, 0.3)],
}

def solids(layout):
    out = []
    for it in layout:
        rot = math.radians(it.get('r', 0))
        sc = it.get('s', 1.0)
        c, sn = math.cos(rot), math.sin(rot)
        px, pz = it['p'][0], it['p'][2]
        for sh in FOOTPRINTS.get(it['m'], []):
            x, z = sh[1] * sc, sh[2] * sc
            wx, wz = px + x * c + z * sn, pz - x * sn + z * c
            if sh[0] == 'c':
                out.append([round(wx, 2), round(wz, 2), round(sh[3] * sc, 2)])
            else:
                out.append([round(wx, 2), round(wz, 2), round(sh[3] * sc, 2), round(sh[4] * sc, 2), round(rot, 3)])
    return out


# --------------------------------------------------------------------------- v5 models
def m_v5():
    w = Mesh()          # town well
    w.cylinder(0, 0, 0, 0.85, 0.75, 'stone', 10, 'stone_l')
    w.cylinder(0, 0.72, 0, 0.62, 0.04, 'water', 10)
    for x in (-0.7, 0.7):
        w.box(x, 1.25, 0, 0.12, 1.1, 0.12, 'wood_d')
    w.box(0, 1.75, 0, 1.6, 0.1, 0.12, 'wood_d')
    w.prism_roof(0, 1.85, 0, 1.9, 0.55, 1.2, 'roof', 'roof_d')
    w.box(0.15, 1.2, 0, 0.18, 0.24, 0.18, 'wood')
    M['well'] = w
    for n, (canopy, canopy2, goods) in enumerate((('banner', 'gold', ('leaf', 'rust', 'gold')), ('hall_roof', 'parch', ('teal', 'coal', 'iron')))):
        st = Mesh()     # market stall: counter, posts, striped canopy, goods
        st.box(0, 0.45, 0, 2.2, 0.9, 0.9, 'wood')
        st.box(0, 0.92, 0, 2.3, 0.06, 1.0, 'wood_l')
        for x in (-1.05, 1.05):
            st.box(x, 1.2, -0.4, 0.1, 2.4, 0.1, 'wood_d')
            st.box(x, 0.9, 0.42, 0.1, 1.8, 0.1, 'wood_d')
        for i in range(6):
            x0 = -1.2 + i * 0.4
            st.quad((x0, 2.4, -0.55), (x0 + 0.4, 2.4, -0.55), (x0 + 0.4, 1.85, 0.75), (x0, 1.85, 0.75), canopy if i % 2 == 0 else canopy2)
        rr = random.Random(40 + n)
        for i in range(6):
            st.rock(-0.85 + i * 0.34, 1.02, rr.uniform(-0.25, 0.2), 0.13, goods[i % 3], 'stone_d', 50 + i + n * 7, squash=0.8)
        st.box(1.6, 0.3, 0.3, 0.55, 0.6, 0.55, 'wood_d', top='wood')
        st.box(1.55, 0.85, 0.25, 0.4, 0.5, 0.4, 'wood', top='wood_l')
        M['stall%d' % n] = st
    b = Mesh()          # barrel
    b.loft([(0, 0.3, 0.3, 'wood'), (0.15, 0.3, 0.3, 'iron_d'), (0.2, 0.34, 0.34, 'wood'), (0.55, 0.36, 0.36, 'wood'),
            (0.6, 0.34, 0.34, 'iron_d'), (0.8, 0.3, 0.3, 'wood_d')], sides=8)
    M['barrel'] = b
    c = Mesh()
    c.box(0, 0.3, 0, 0.6, 0.6, 0.6, 'wood', top='wood_l')
    c.box(0.15, 0.75, 0.05, 0.42, 0.3, 0.42, 'wood_d', top='wood')
    M['crates'] = c
    bn = Mesh()
    bn.box(0, 0.45, 0, 1.6, 0.08, 0.45, 'wood_l')
    for x in (-0.65, 0.65):
        bn.box(x, 0.22, 0, 0.1, 0.44, 0.38, 'wood_d')
    M['bench'] = bn
    bd = Mesh()         # bird: body + two wings (wings flap by scaling in the app)
    bd.ellipsoid(0, 0, 0, 0.06, 0.05, 0.12, 'eye', seg=6, rings=4)
    bd.tri((0, 0.01, -0.03), (-0.3, 0.04, 0.02), (0, 0.01, 0.07), 'eye')
    bd.tri((0, 0.01, -0.03), (0, 0.01, 0.07), (0.3, 0.04, 0.02), 'eye')
    M['bird'] = bd
    # pets
    g = Mesh(smooth=False)
    g.box(0, 0.32, 0, 0.42, 0.38, 0.32, 'stone', top='stone_l')
    g.box(0, 0.64, -0.02, 0.3, 0.26, 0.26, 'stone_l')
    g.box(-0.08, 0.68, -0.15, 0.06, 0.05, 0.02, 'teal_l')
    g.box(0.08, 0.68, -0.15, 0.06, 0.05, 0.02, 'teal_l')
    for x in (-0.28, 0.28):
        g.box(x, 0.28, 0, 0.12, 0.34, 0.14, 'stone_d')
    for x in (-0.11, 0.11):
        g.box(x, 0.07, 0, 0.14, 0.14, 0.18, 'stone_d')
    g.crystal(0, 0.77, 0.05, 0.05, 0.22, 'teal', 'teal_l')
    M['pet_golem'] = g
    bt = Mesh()
    bt.ellipsoid(0, 0, 0, 0.1, 0.11, 0.1, 'cave_wall', seg=6, rings=4)
    bt.tri((-0.05, 0.08, 0), (-0.09, 0.2, 0), (-0.01, 0.1, 0), 'cave_wall')
    bt.tri((0.05, 0.08, 0), (0.01, 0.1, 0), (0.09, 0.2, 0), 'cave_wall')
    bt.box(-0.04, 0.03, -0.09, 0.03, 0.03, 0.01, 'void_l')
    bt.box(0.04, 0.03, -0.09, 0.03, 0.03, 0.01, 'void_l')
    M['pet_bat'] = bt
    bw = Mesh()         # bat wing (mirrored in the app)
    bw.tri((0, 0, 0), (0.34, 0.12, 0.02), (0.3, -0.06, 0.04), 'cave_wall')
    bw.tri((0, 0, 0), (0.3, -0.06, 0.04), (0.14, -0.1, 0.02), 'cave_wall')
    M['pet_bat_wing'] = bw
    sp = Mesh()
    sp.crystal(0, -0.15, 0, 0.09, 0.32, 'teal', 'teal_l')
    sp.crystal(0, 0.15, 0, 0.07, -0.0001 + 0.0, 'teal', 'teal_l') if False else None
    sp.cone(0, -0.15, 0, 0.09, -0.18, 'teal_l', 6)
    M['pet_sprite'] = sp
    # trophies for the cabin shelves
    f = Mesh(smooth=True)
    f.ellipsoid(0, 0.12, 0, 0.06, 0.07, 0.2, 'fish', seg=7, rings=5)
    f.ellipsoid(0, 0.1, 0.01, 0.05, 0.04, 0.16, 'fish_l', seg=7, rings=4)
    f.tri((0, 0.12, 0.17), (0, 0.24, 0.3), (0, 0.0, 0.3), 'fish')
    f.box(0, 0.02, 0, 0.18, 0.04, 0.3, 'wood_d')
    M['trophy_fish'] = f
    for gname in ('amber', 'garnet', 'sapphire', 'void'):
        gm = Mesh()
        gm.box(0, 0.03, 0, 0.22, 0.06, 0.22, 'wood_d')
        gm.crystal(0, 0.06, 0, 0.07, 0.2, gname, gname if gname != 'void' else 'void_l')
        M['trophy_gem_' + gname] = gm
    pl = Mesh()
    pl.box(0, 0.16, 0, 0.26, 0.32, 0.04, 'wood_d')
    pl.cylinder(0, 0.2, -0.03, 0.08, 0.02, 'gold', 8)
    M['trophy_badge'] = pl
    # the cabin (an interior room, 9 x 9 m)
    cb = Mesh()
    cb.flat(-4.6, -4.6, 4.6, 4.6, 0, 'wood_l')
    for x in range(-4, 5, 2):
        cb.box(x, 0.01, 0, 0.04, 0.02, 9.2, 'wood_d')
    cb.box(0, 1.8, -4.7, 9.4, 3.6, 0.2, 'wood')
    cb.box(-4.7, 1.8, 0, 0.2, 3.6, 9.4, 'wood')
    cb.box(4.7, 1.8, 0, 0.2, 3.6, 9.4, 'wood')
    cb.box(0, 1.8, 4.7, 9.4, 3.6, 0.2, 'wood')
    for z in (-3, 0, 3):
        cb.box(0, 3.5, z, 9.4, 0.25, 0.3, 'wood_d')
    cb.box(-4.55, 1.6, -1.5, 0.08, 1.0, 1.2, 'lamp')      # window glow
    cb.box(0, 1.1, 4.58, 1.2, 2.2, 0.08, 'door')
    M['cabin_room'] = cb
    fp = Mesh()         # fireplace
    fp.box(0, 1.0, 0, 2.0, 2.0, 0.8, 'stone', top='stone_l')
    fp.box(0, 0.55, 0.22, 1.1, 0.9, 0.5, 'door')
    fp.box(0, 2.6, -0.1, 1.2, 1.4, 0.6, 'stone_d')
    for i, x in enumerate((-0.25, 0.0, 0.22)):
        fp.cone(x, 0.15, 0.3, 0.16, 0.45 + 0.1 * i, 'fire', 5)
    fp.box(0, 0.12, 0.3, 0.8, 0.12, 0.2, 'wood_d')
    M['fireplace'] = fp
    sh = Mesh()         # trophy shelves (two boards, 3 slots each)
    for y in (1.0, 1.9):
        sh.box(0, y, 0, 3.4, 0.08, 0.5, 'wood_d')
    for x in (-1.65, 1.65):
        sh.box(x, 1.2, 0, 0.1, 2.4, 0.5, 'wood_d')
    M['shelves'] = sh
    rg = Mesh()
    rg.flat(-1.6, -1.1, 1.6, 1.1, 0.02, 'banner')
    rg.flat(-1.3, -0.8, 1.3, 0.8, 0.025, 'gold')
    rg.flat(-1.1, -0.6, 1.1, 0.6, 0.03, 'banner')
    M['rug'] = rg
    bdm = Mesh()
    bdm.box(0, 0.3, 0, 1.3, 0.6, 2.2, 'wood_d')
    bdm.box(0, 0.65, 0.1, 1.2, 0.15, 1.9, 'plaster')
    bdm.box(0, 0.75, 0.3, 1.22, 0.1, 1.4, 'banner')
    bdm.box(0, 0.78, -0.75, 0.8, 0.14, 0.4, 'parch')
    M['bed'] = bdm
    tb = Mesh()
    tb.box(0, 0.75, 0, 1.4, 0.08, 0.9, 'wood')
    for x in (-0.6, 0.6):
        for z in (-0.35, 0.35):
            tb.box(x, 0.37, z, 0.08, 0.74, 0.08, 'wood_d')
    tb.box(0.3, 0.86, 0.1, 0.14, 0.14, 0.14, 'lamp')
    M['table'] = tb
    # underground lake bits
    dk = Mesh()         # dock
    dk.box(0, 0.12, 0, 1.4, 0.08, 3.6, 'wood')
    for z in (-1.6, 0, 1.6):
        dk.box(0, 0.1, z, 1.5, 0.06, 0.16, 'wood_d')
        for x in (-0.65, 0.65):
            dk.box(x, -0.2, z, 0.14, 0.7, 0.14, 'wood_d')
    M['dock'] = dk
    ms = Mesh()         # glowing mushrooms
    rr = random.Random(77)
    for i in range(5):
        x, z = rr.uniform(-0.5, 0.5), rr.uniform(-0.5, 0.5)
        h = rr.uniform(0.15, 0.4)
        ms.tube((x, 0, z), (x, h, z), 0.03, 0.025, 'parch', sides=5)
        ms.cone(x, h, z, 0.12 + h * 0.2, 0.1, 'mush', 6)
    M['mushrooms'] = ms
    rb = Mesh()         # rubble pile for expedition floors
    for i in range(5):
        a = i * 1.3
        rb.rock(0.5 * math.cos(a), 0, 0.5 * math.sin(a), 0.3 + 0.08 * i, 'cave_wall', 'stone_d', 300 + i)
    M['rubble'] = rb

m_v5()
FOOTPRINTS.update({'well': [('c', 0, 0, 0.95)], 'stall0': [('b', 0, 0, 1.2, 0.55), ('c', 1.6, 0.3, 0.4)],
                   'stall1': [('b', 0, 0, 1.2, 0.55), ('c', 1.6, 0.3, 0.4)], 'barrel': [('c', 0, 0, 0.38)], 'crates': [('c', 0, 0, 0.45)],
                   'bench': [('b', 0, 0, 0.8, 0.25)], 'fireplace': [('b', 0, 0, 1.05, 0.5)], 'shelves': [('b', 0, 0, 1.75, 0.3)],
                   'bed': [('b', 0, 0, 0.7, 1.15)], 'table': [('b', 0, 0, 0.75, 0.5)], 'rubble': [('c', 0, 0, 0.8)],
                   'mushrooms': [('c', 0, 0, 0.4)]})

# town additions: a well, two market stalls, barrels, crates and benches between the buildings
TOWN.extend([{'m': 'well', 'p': ring(5.6, 192), 'r': 0},
             {'m': 'stall0', 'p': ring(10.0, 28), 'r': -28 + 180}, {'m': 'stall1', 'p': ring(10.2, 132), 'r': -132 + 180},
             {'m': 'barrel', 'p': ring(10.8, 282), 'r': 0}, {'m': 'barrel', 'p': ring(11.5, 286), 'r': 40},
             {'m': 'crates', 'p': ring(11.0, 78), 'r': 20}, {'m': 'bench', 'p': ring(6.2, 230), 'r': -230},
             {'m': 'bench', 'p': ring(6.2, 335), 'r': -335}])
TOWN_LIGHTS.append({'p': [ring(5.6, 192)[0], 1.4, ring(5.6, 192)[2]], 'c': '#7fb8d0', 'r': 3, 'e': 0.4})
SPOTS['town_market'] = {'p': ring(7.4, 28), 'look': ring(10.0, 28)}
SPOTS['town_network'] = {'p': [0, 0, 3.0], 'look': [0, 0, 0]}
# NPC wander points (open plaza ground) and bird circle centres
WANDER = [ring(r, d) for r, d in ((6.5, 10), (7.5, 60), (6.8, 118), (7.2, 170), (6.9, 215), (7.4, 262), (6.6, 300), (7.0, 345),
                                  (10.5, 230), (10.5, 340), (4.5, 90), (4.5, 270))]

CABIN = [{'m': 'cabin_room', 'p': [0, 0, 0], 'r': 0}, {'m': 'fireplace', 'p': [-2.4, 0, -4.15], 'r': 0},
         {'m': 'shelves', 'p': [1.9, 0, -4.3], 'r': 0}, {'m': 'rug', 'p': [0, 0, 0.2], 'r': 0},
         {'m': 'bed', 'p': [3.4, 0, 2.6], 'r': 0}, {'m': 'table', 'p': [-3.0, 0, 2.2], 'r': 90},
         {'m': 'barrel', 'p': [-3.9, 0, -2.2], 'r': 0}]
CABIN_LIGHTS = [{'p': [-2.4, 0.9, -3.3], 'c': '#ff9a40', 'r': 7, 'e': 1.8}, {'p': [-3.0, 1.3, 2.2], 'c': '#ffd9a0', 'r': 5, 'e': 1.0},
                {'p': [1.9, 2.8, -3.2], 'c': '#ffe8c0', 'r': 4, 'e': 0.7}]
SHELF_SLOTS = [[1.9 + dx, y + 0.04, -4.3] for y in (1.0, 1.9) for dx in (-1.05, 0.0, 1.05)]
SPOTS.update({'cabin_spawn': {'p': [0, 0, 0.9], 'look': [0, 0, -2]}, 'cabin_shelves': {'p': [1.9, 0, -2.6], 'look': [1.9, 0, -4.3]},
              'cabin_fire': {'p': [-2.4, 0, -2.4], 'look': [-2.4, 0, -4.2]}})

LAKE = [{'m': 'cave_floor', 'p': [0, 0, 0], 'r': 0}, {'m': 'cave_walls', 'p': [0, 0, 0], 'r': 0},
        {'m': 'dock', 'p': [0, 0, -1.6], 'r': 0}, {'m': 'exit_ladder', 'p': [6.4, 0, 5.2], 'r': -55}]
for x, z in ((-4.8, -1.5), (4.6, -2.0), (-3.2, -7.4), (3.6, -7.0), (-5.6, 2.8), (5.2, 3.4)):
    LAKE.append({'m': 'mushrooms', 'p': [x, 0, z], 'r': (x * 37) % 360})
LAKE.append({'m': 'support', 'p': [-4.5, 0, 3.0], 'r': 20})
LAKE_LIGHTS = [{'p': [0, 2.5, -4.5], 'c': '#5fe0cf', 'r': 9, 'e': 1.2}, {'p': [-4.5, 2.9, 3.2], 'c': '#ffb35c', 'r': 7, 'e': 1.4},
               {'p': [-4.8, 0.8, -1.5], 'c': '#9ff3e6', 'r': 3, 'e': 0.9}, {'p': [4.6, 0.8, -2.0], 'c': '#9ff3e6', 'r': 3, 'e': 0.9}]
LAKE_WATER = {'center': [0, -4.6], 'radius': 4.6}
SPOTS.update({'lake_spawn': {'p': [0, 0, 6.5], 'look': [0, 0, -3]}, 'lake_fish': {'p': [0, 0, 0.6], 'look': [0, 0, -5]}})

EXPED = [{'m': 'cave_floor', 'p': [0, 0, 0], 'r': 0}, {'m': 'cave_walls', 'p': [0, 0, 0], 'r': 0},
         {'m': 'rubble', 'p': [-4.0, 0, 1.5], 'r': 0}, {'m': 'rubble', 'p': [4.4, 0, 0.5], 'r': 80},
         {'m': 'support', 'p': [0, 0, -3.6], 'r': 0}, {'m': 'exit_ladder', 'p': [6.4, 0, 5.2], 'r': -55}]
EXPED_LIGHTS = [{'p': [0, 2.9, -3.4], 'c': '#ffb35c', 'r': 7, 'e': 1.2}]
SPOTS.update({'exped_spawn': {'p': [0, 0, 3.0], 'look': [0, 0, -1]}, 'exped_vein': {'p': [0, 0, 0.6], 'look': [0, 0, -1.4]}})
EXPED_VEIN = [0, 0, -1.4]

TOWN_SOLIDS = solids(TOWN)
MINE_SOLIDS = solids(MINE)
CABIN_SOLIDS = solids(CABIN)
LAKE_SOLIDS = solids(LAKE) + [[LAKE_WATER['center'][0], LAKE_WATER['center'][1], LAKE_WATER['radius']]]
EXPED_SOLIDS = solids(EXPED) + [[EXPED_VEIN[0], EXPED_VEIN[2], 1.25]]

# --------------------------------------------------------------------------- export
def gd_value(v, ind=0):
    if isinstance(v, dict):
        items = ['"%s": %s' % (k, gd_value(x, ind + 1)) for k, x in v.items()]
        return '{' + ', '.join(items) + '}'
    if isinstance(v, (list, tuple)):
        return '[' + ', '.join(gd_value(x, ind + 1) for x in v) + ']'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, float):
        s = ('%.3f' % v).rstrip('0').rstrip('.')
        return s if s not in ('-0', '') else '0'
    if isinstance(v, int):
        return str(v)
    return '"%s"' % v

def export(path):
    lines = ['# GENERATED by gen/models.py - do not edit by hand.',
             '# Low-poly models for Pulse v4: each model is a flat list of triangle',
             '# vertices (x, y, z per corner, float32, base64) plus one palette index',
             '# per triangle (bytes, base64). Decoded by mesh_builder.gd.',
             'extends RefCounted', '',
             'const PALETTE = %s' % gd_value([[h, g] for h, g in PALETTE]),
             'const SLOTS = %s' % gd_value({k: P[k] for k in ('skin', 'hair', 'shirt', 'pants', 'accent', 'pick')}),
             'const HERO_RIG = %s' % gd_value(HERO_RIG),
             'const POSES = %s' % gd_value(POSES),
             'const APPEARANCE = %s' % gd_value(APPEARANCE),
             'const TOWN = %s' % gd_value(TOWN),
             'const TOWN_LIGHTS = %s' % gd_value(TOWN_LIGHTS),
             'const MINE = %s' % gd_value(MINE),
             'const MINE_LIGHTS = %s' % gd_value(MINE_LIGHTS),
             'const SPOTS = %s' % gd_value(SPOTS),
             'const TOWN_SOLIDS = %s' % gd_value(TOWN_SOLIDS),
             'const MINE_SOLIDS = %s' % gd_value(MINE_SOLIDS),
             'const MATS = %s' % gd_value([MAT_OF.get(next(k for k, v in P.items() if v == i), 0) for i in range(len(PALETTE))]),
             'const FACES = %d' % FACES,
             'const WANDER = %s' % gd_value(WANDER),
             'const CABIN = %s' % gd_value(CABIN),
             'const CABIN_LIGHTS = %s' % gd_value(CABIN_LIGHTS),
             'const CABIN_SOLIDS = %s' % gd_value(CABIN_SOLIDS),
             'const SHELF_SLOTS = %s' % gd_value(SHELF_SLOTS),
             'const LAKE = %s' % gd_value(LAKE),
             'const LAKE_LIGHTS = %s' % gd_value(LAKE_LIGHTS),
             'const LAKE_SOLIDS = %s' % gd_value(LAKE_SOLIDS),
             'const LAKE_WATER = %s' % gd_value(LAKE_WATER),
             'const EXPED = %s' % gd_value(EXPED),
             'const EXPED_LIGHTS = %s' % gd_value(EXPED_LIGHTS),
             'const EXPED_SOLIDS = %s' % gd_value(EXPED_SOLIDS),
             'const EXPED_VEIN = %s' % gd_value(EXPED_VEIN), '',
             'const MODELS = {']
    for name, mesh in M.items():
        d = mesh.data()
        lines.append('\t"%s": %s,' % (name, gd_value(d)))
    lines.append('}')
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    tri = sum(len(m.tris) for m in M.values())
    return tri, os.path.getsize(path)

def scene_tris(layout):
    out = []
    for it in layout:
        mesh = M[it['m']]
        rot = math.radians(it.get('r', 0))
        s = it.get('s', 1.0)
        c, sn = math.cos(rot), math.sin(rot)
        for a, b, cc, col in mesh.tris:
            pts = []
            for (x, y, z) in (a, b, cc):
                x, y, z = x * s, y * s, z * s
                pts.append((it['p'][0] + x * c + z * sn, it['p'][1] + y, it['p'][2] - x * sn + z * c))
            out.append((pts, col))
    return out

if __name__ == '__main__':
    import sys
    tri, size = export(sys.argv[1])
    print('models:', len(M), 'triangles:', tri, 'bytes:', size)
