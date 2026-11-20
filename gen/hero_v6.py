"""Pulse character, v5.1 overhaul: 2007-era adventurer with real proportions.

What changed from the v4/v5 character:
  - head about 1/7 of body height (was about 1/5, which looked toy-like)
  - jointed limbs: upper arm + forearm, thigh + shin, so elbows and knees bend
  - angular faceted face: jaw, cheekbones, brow, nose, ears; small dark eyes
  - hands with a thumb, boots with a toe and heel, a tunic that flares below the belt
  - a sword for duels, alongside the pickaxe

Styles (HERO_STYLE env): R = classic 2007 (faceted), S = classic smooth-shaded, H = heroic (bigger head, broader build).
Called from models.py as build_hero(Mesh, M, style) and returns (HERO_RIG, POSES, FACES).
"""
import math

STYLES = {
    # tuned after play-testing: bigger head, broad V-shaped chest, thicker limbs (the old build looked lanky)
    'R': dict(smooth=False, head=0.27, hw=1.04, shoulder=0.262, chest=0.222, waist=0.162, limb=1.2, sides=8),
    'S': dict(smooth=True, head=0.27, hw=1.04, shoulder=0.262, chest=0.222, waist=0.162, limb=1.2, sides=8),
    'H': dict(smooth=False, head=0.292, hw=1.08, shoulder=0.282, chest=0.242, waist=0.172, limb=1.3, sides=8),
}

HIP_Y = 0.90        # hip joint height above the ground
THIGH = 0.42
SHIN = 0.40
UPARM = 0.30
FOREARM = 0.27
NECK_Y = 0.60       # neck above the hip joint


def build_hero(Mesh, M, style='R'):
    q = STYLES.get(style, STYLES['R'])
    sm, sd = q['smooth'], q['sides']
    ph = math.pi / sd
    H = q['head']
    s = H / 0.245                    # head scale
    L = q['limb']
    parts = {}

    # ---------------------------------------------------------------- torso (origin = hips, front = -z)
    cw, ww, sh = q['chest'], q['waist'], q['shoulder']
    t = Mesh(smooth=sm)
    t.loft([(-0.08, ww * 1.02, 0.115, 'pants'), (0.07, ww * 0.98, 0.11, 'pants'), (0.10, ww * 0.96, 0.108, 'belt'),
            (0.14, ww * 0.97, 0.11, 'shirt'), (0.24, ww * 1.04, 0.122, 'shirt'), (0.36, cw * 0.97, 0.142, 'shirt'),
            (0.46, cw * 1.03, 0.14, 'shirt'), (0.52, cw * 0.97, 0.124, 'accent'), (0.56, cw * 0.62, 0.096, 'accent'),
            (0.585, 0.055, 0.05, 'skin'), (0.63, 0.05, 0.048, 'skin')], sides=sd, phase=ph)
    # tunic flares below the belt (the classic adventurer look)
    t.loft([(0.10, ww * 1.0, 0.118, 'shirt'), (0.0, ww * 1.14, 0.142, 'shirt'), (-0.12, ww * 1.26, 0.158, 'shirt'),
            (-0.15, ww * 1.28, 0.16, 'accent')], sides=sd, phase=ph, cap_top=False, cap_bottom=False)
    # shoulder caps so the arms join the body
    for x in (-sh + 0.025, sh - 0.025):
        t.ellipsoid(x, 0.475, 0, 0.068 * L, 0.06 * L, 0.07 * L, 'shirt', seg=8, rings=5)
    t.box(0, 0.10, -0.112, 0.06, 0.05, 0.02, 'gold')             # buckle
    t.box(-ww * 0.95, 0.06, 0.02, 0.07, 0.11, 0.09, 'boots')    # pouch
    t.box(0.0, 0.47, -0.128, 0.03, 0.10, 0.012, 'accent')       # tunic lacing
    parts['torso'] = t

    # ---------------------------------------------------------------- head (origin = base of the neck)
    h = Mesh(smooth=sm)
    k = q['hw']
    # (height above neck, half width, half depth, z offset forward)
    rings = [(0.02 * s, 0.040 * s * k, 0.045 * s, -0.035 * s), (0.055 * s, 0.075 * s * k, 0.085 * s, -0.02 * s),
             (0.10 * s, 0.092 * s * k, 0.105 * s, -0.008 * s), (0.15 * s, 0.098 * s * k, 0.112 * s, 0.0),
             (0.195 * s, 0.096 * s * k, 0.112 * s, 0.004 * s), (0.235 * s, 0.078 * s * k, 0.098 * s, 0.006 * s),
             (0.262 * s, 0.040 * s * k, 0.06 * s, 0.006 * s)]
    h.loft([(y, rx, rz, 'skin', dz) for (y, rx, rz, dz) in rings], sides=sd, phase=ph)
    h.loft([(-0.02, 0.048, 0.044, 'skin'), (0.04 * s, 0.05, 0.046, 'skin')], sides=6, cap_top=False, cap_bottom=False)

    def front(y, out=0.004):
        """z of the head's front facet at height y (flat facet faces -z)."""
        for (y0, _, rz0, dz0), (y1, _, rz1, dz1) in zip(rings, rings[1:]):
            if y0 <= y <= y1:
                f = (y - y0) / (y1 - y0)
                rz, dz = rz0 + (rz1 - rz0) * f, dz0 + (dz1 - dz0) * f
                return -(rz * math.cos(math.pi / sd)) + dz - out
        return -0.1 * s

    def fq(m, x0, y0, x1, y1, col, out=0.004):
        m.quad((x0, y1, front(y1, out)), (x1, y1, front(y1, out)), (x1, y0, front(y0, out)), (x0, y0, front(y0, out)), col)

    fl = Mesh()
    ey = 0.155 * s
    for x in (-0.038 * s, 0.038 * s):
        fq(fl, x - 0.017 * s, ey - 0.009 * s, x + 0.017 * s, ey + 0.009 * s, 'parch')        # eye white
        fq(fl, x - 0.008 * s, ey - 0.009 * s, x + 0.008 * s, ey + 0.009 * s, 'eye', 0.006)  # pupil
        fq(fl, x - 0.024 * s, ey + 0.018 * s, x + 0.022 * s, ey + 0.028 * s, 'hair', 0.007)  # brow
    ny = 0.12 * s
    zf = front(ny)
    tip = (0, ny - 0.006 * s, zf - 0.032 * s)
    fl.tri(tip, (-0.018 * s, ny - 0.02 * s, front(ny - 0.02 * s)), (0.018 * s, ny - 0.02 * s, front(ny - 0.02 * s)), 'skin')
    fl.tri(tip, (0.018 * s, ny - 0.02 * s, front(ny - 0.02 * s)), (0, ny + 0.05 * s, front(ny + 0.05 * s)), 'skin')
    fl.tri(tip, (0, ny + 0.05 * s, front(ny + 0.05 * s)), (-0.018 * s, ny - 0.02 * s, front(ny - 0.02 * s)), 'skin')
    my = 0.075 * s
    fq(fl, -0.026 * s, my - 0.004 * s, 0.026 * s, my + 0.004 * s, 'door', 0.006)              # mouth
    for x in (-1, 1):                                                                             # ears
        fl.box(x * (0.096 * s * k + 0.008), 0.15 * s, 0.01 * s, 0.018, 0.05 * s, 0.035 * s, 'skin')
    h.add(fl)
    parts['head'] = h

    # face extras: 1 freckles, 2 moustache, 3 short beard, 4 scar, 5 grand beard
    f1 = Mesh()
    for (x, y) in ((-0.05, 0.125), (-0.035, 0.115), (-0.06, 0.11), (0.05, 0.125), (0.035, 0.115), (0.06, 0.11), (0.0, 0.135)):
        fq(f1, (x - 0.006) * s, (y - 0.005) * s, (x + 0.006) * s, (y + 0.005) * s, 'boots', 0.006)
    f2 = Mesh()
    fq(f2, -0.045 * s, my + 0.008 * s, 0.045 * s, my + 0.024 * s, 'hair', 0.009)
    fq(f2, -0.05 * s, my - 0.02 * s, -0.036 * s, my + 0.012 * s, 'hair', 0.009)
    fq(f2, 0.036 * s, my - 0.02 * s, 0.05 * s, my + 0.012 * s, 'hair', 0.009)
    f3 = Mesh(smooth=sm)
    f3.loft([(0.012 * s, 0.045 * s * k, 0.05 * s, 'hair', -0.045 * s), (0.05 * s, 0.08 * s * k, 0.09 * s, 'hair', -0.024 * s),
             (0.088 * s, 0.094 * s * k, 0.106 * s, 'hair', -0.008 * s)], sides=sd, phase=ph, cap_top=False)
    f4 = Mesh()
    for i in range(4):
        x, y = 0.03 * s + i * 0.008 * s, ey + 0.035 * s - i * 0.022 * s
        fq(f4, x - 0.004 * s, y - 0.012 * s, x + 0.004 * s, y + 0.012 * s, 'banner', 0.008)
    f5 = Mesh(smooth=sm)
    f5.loft([(-0.13 * s, 0.02 * s, 0.02 * s, 'hair', -0.09 * s), (-0.06 * s, 0.05 * s * k, 0.045 * s, 'hair', -0.075 * s),
             (0.02 * s, 0.075 * s * k, 0.07 * s, 'hair', -0.05 * s), (0.07 * s, 0.09 * s * k, 0.096 * s, 'hair', -0.022 * s),
             (0.098 * s, 0.096 * s * k, 0.106 * s, 'hair', -0.008 * s)], sides=sd, phase=ph, cap_top=False)
    fq(f5, -0.05 * s, my + 0.008 * s, 0.05 * s, my + 0.026 * s, 'hair', 0.01)
    for i, fm in enumerate((f1, f2, f3, f4, f5)):
        parts['face%d' % (i + 1)] = fm

    # hair styles: 0 short crop, 1 long, 2 braid + headband, 3 mohawk
    def cap(m, grow=1.0, low=0.17):
        m.loft([(low * s, 0.102 * s * k * grow, 0.118 * s * grow, 'hair', 0.008 * s), (0.215 * s, 0.103 * s * k * grow, 0.12 * s * grow, 'hair', 0.008 * s),
                (0.255 * s, 0.085 * s * k * grow, 0.106 * s * grow, 'hair', 0.008 * s), (0.282 * s, 0.045 * s * k * grow, 0.066 * s * grow, 'hair', 0.008 * s)],
               sides=sd, phase=ph, cap_bottom=False)
        # back of the head
        m.loft([(0.06 * s, 0.085 * s * k * grow, 0.07 * s, 'hair', 0.05 * s), (0.17 * s, 0.1 * s * k * grow, 0.075 * s, 'hair', 0.055 * s)],
               sides=sd, phase=ph, cap_top=False)
    styles = []
    m0 = Mesh(smooth=sm)
    cap(m0)
    styles.append(m0)
    m1 = Mesh(smooth=sm)
    cap(m1, 1.04, 0.15)
    m1.loft([(0.2 * s, 0.1 * s * k, 0.06 * s, 'hair', 0.07 * s), (0.02 * s, 0.108 * s * k, 0.055 * s, 'hair', 0.08 * s),
             (-0.12 * s, 0.11 * s * k, 0.045 * s, 'hair', 0.085 * s)], sides=6, phase=math.pi / 6)
    for x in (-1, 1):
        m1.tube((x * 0.098 * s * k, 0.19 * s, 0.01 * s), (x * 0.104 * s * k, -0.05 * s, 0.03 * s), 0.042 * s, 0.026 * s, 'hair', sides=5)
    styles.append(m1)
    m2 = Mesh(smooth=sm)
    cap(m2)
    m2.loft([(0.19 * s, 0.108 * s * k, 0.124 * s, 'accent', 0.008 * s), (0.215 * s, 0.108 * s * k, 0.124 * s, 'accent', 0.008 * s)],
            sides=sd, phase=ph, cap_top=False, cap_bottom=False)
    for i in range(5):
        m2.ellipsoid(0, 0.12 * s - i * 0.065 * s, 0.11 * s + i * 0.012 * s, 0.028 * s, 0.038 * s, 0.028 * s, 'hair', seg=6, rings=4)
    styles.append(m2)
    m3 = Mesh(smooth=sm)
    cap(m3, 0.99, 0.19)
    m3.loft([(0.26 * s, 0.022 * s, 0.11 * s, 'hair', 0.0), (0.33 * s, 0.016 * s, 0.09 * s, 'hair', 0.01 * s), (0.36 * s, 0.006 * s, 0.05 * s, 'hair', 0.02 * s)], sides=6)
    styles.append(m3)
    for i, m in enumerate(styles):
        parts['hair%d' % i] = m

    # ---------------------------------------------------------------- limbs
    for side, sx in (('l', -1), ('r', 1)):
        ua = Mesh(smooth=sm)          # upper arm, origin at the shoulder, hangs down -y
        ua.loft([(0.03, 0.06 * L, 0.065 * L, 'shirt'), (-0.12, 0.058 * L, 0.06 * L, 'shirt'), (-UPARM + 0.02, 0.048 * L, 0.05 * L, 'shirt'),
                 (-UPARM - 0.01, 0.044 * L, 0.046 * L, 'shirt')], sides=6, phase=math.pi / 6)
        parts['uparm_' + side] = ua
        fa = Mesh(smooth=sm)          # forearm + hand, origin at the elbow
        fa.loft([(0.02, 0.046 * L, 0.048 * L, 'shirt'), (-0.1, 0.045 * L, 0.047 * L, 'shirt'), (-0.17, 0.041 * L, 0.042 * L, 'accent'),
                 (-0.2, 0.043 * L, 0.044 * L, 'accent'), (-0.22, 0.034 * L, 0.036 * L, 'skin'), (-FOREARM + 0.01, 0.032 * L, 0.033 * L, 'skin')],
                sides=6, phase=math.pi / 6)
        fa.box(0, -FOREARM - 0.04, -0.005, 0.038 * L, 0.085, 0.07 * L, 'skin')               # hand
        fa.box(-sx * 0.025 * L, -FOREARM - 0.02, -0.035 * L, 0.018, 0.05, 0.022, 'skin')      # thumb
        parts['forearm_' + side] = fa
        th = Mesh(smooth=sm)          # thigh, origin at the hip joint
        th.loft([(0.0, 0.066 * L, 0.07 * L, 'pants'), (-0.1, 0.072 * L, 0.076 * L, 'pants'), (-THIGH + 0.03, 0.06 * L, 0.065 * L, 'pants'),
                 (-THIGH - 0.01, 0.058 * L, 0.062 * L, 'pants')], sides=sd, phase=ph)
        parts['thigh_' + side] = th
        sn = Mesh(smooth=sm)          # shin + boot, origin at the knee
        sn.loft([(0.03, 0.058 * L, 0.062 * L, 'pants'), (-0.1, 0.055 * L, 0.06 * L, 'pants'), (-0.2, 0.06 * L, 0.064 * L, 'boots'),
                 (-0.24, 0.064 * L, 0.068 * L, 'boots'), (-SHIN + 0.08, 0.05 * L, 0.054 * L, 'boots')], sides=sd, phase=ph)
        sn.box(0, -SHIN + 0.045, -0.035, 0.1 * L, 0.09, 0.2 * L, 'boots')                      # foot
        sn.box(0, -SHIN + 0.06, -0.14 * L, 0.085 * L, 0.06, 0.05, 'boots')                    # toe
        sn.box(0, -SHIN + 0.008, -0.04, 0.108 * L, 0.016, 0.24 * L, 'door')                    # sole
        parts['shin_' + side] = sn

    # ---------------------------------------------------------------- tools (origin at the grip, along +y)
    p = Mesh()
    p.tube((0, -0.1, 0), (0, 0.72, 0), 0.022, 0.026, 'wood', sides=6)
    p.box(0, 0.7, 0, 0.07, 0.09, 0.08, 'iron_d')
    p.tube((0, 0.7, 0), (0, 0.73, -0.15), 0.042, 0.032, 'pick', sides=5)
    p.tube((0, 0.73, -0.15), (0, 0.64, -0.32), 0.032, 0.006, 'pick', sides=5)
    p.tube((0, 0.7, 0), (0, 0.73, 0.15), 0.042, 0.032, 'pick', sides=5)
    p.tube((0, 0.73, 0.15), (0, 0.64, 0.32), 0.032, 0.006, 'pick', sides=5)
    parts['pickaxe'] = p
    sw = Mesh()
    sw.tube((0, -0.09, 0), (0, 0.08, 0), 0.02, 0.022, 'belt', sides=6)        # grip
    sw.ellipsoid(0, -0.11, 0, 0.03, 0.03, 0.03, 'gold', seg=6, rings=4)        # pommel
    sw.box(0, 0.09, 0, 0.2, 0.035, 0.05, 'gold')                                # crossguard
    sw.box(0, 0.09, 0, 0.05, 0.035, 0.2, 'gold')
    # blade: a diamond cross-section wide enough to read from the side and the front
    sw.loft([(0.1, 0.046, 0.04, 'steel'), (0.6, 0.04, 0.034, 'steel'), (0.76, 0.004, 0.004, 'steel')], sides=4, phase=math.pi / 4)
    sw.box(0, 0.36, 0, 0.012, 0.46, 0.05, 'iron')                            # fuller
    parts['sword'] = sw
    for name, mesh in parts.items():
        M['hero_' + name] = mesh

    sh_y = 0.49
    rig = {   # part -> [model, parent, offset]
        'torso': ['hero_torso', '', [0, HIP_Y, 0]],
        'head': ['hero_head', 'torso', [0, NECK_Y, 0]],
        'hair': ['hero_hair0', 'head', [0, 0, 0]],
        'uparm_l': ['hero_uparm_l', 'torso', [-sh, sh_y, 0]],
        'forearm_l': ['hero_forearm_l', 'uparm_l', [0, -UPARM, 0]],
        'uparm_r': ['hero_uparm_r', 'torso', [sh, sh_y, 0]],
        'forearm_r': ['hero_forearm_r', 'uparm_r', [0, -UPARM, 0]],
        'thigh_l': ['hero_thigh_l', '', [-0.095, HIP_Y, 0]],
        'shin_l': ['hero_shin_l', 'thigh_l', [0, -THIGH, 0]],
        'thigh_r': ['hero_thigh_r', '', [0.095, HIP_Y, 0]],
        'shin_r': ['hero_shin_r', 'thigh_r', [0, -THIGH, 0]],
        'pickaxe': ['hero_pickaxe', 'forearm_r', [0, -FOREARM - 0.05, -0.01]],
        'sword': ['hero_sword', 'forearm_r', [0, -FOREARM - 0.05, -0.01]],
    }
    poses = {   # shoulder / elbow angles in degrees (rotation about x; positive = forward and up)
        'idle': {'arm_r': 6, 'arm_l': 6, 'elbow_r': 12, 'elbow_l': 12},
        'raise': {'arm_r': 170, 'arm_l': 150, 'elbow_r': 40, 'elbow_l': 30},
        'strike': {'arm_r': 58, 'arm_l': 50, 'elbow_r': 8, 'elbow_l': 10},
    }
    return rig, poses, 6
