"""Generates the v5.5 world-boss sounds (no outside audio files).
  horn.wav        a low war horn: the 3-minute warning that a monster is coming
  roar.wav        the monster arrives (growl + rumble)
  mhit.wav        a heavy hit on a monster's hide
  victory.wav     a short brass fanfare when the town wins
  escape.wav      a falling, mournful phrase when the monster gets away
  music_boss.ogg  a driving battle loop for the town square during a fight
Run:  python bossaudio.py <out_dir>
"""
import os, sys, subprocess, wave
import numpy as np

SR = 22050
OUT = sys.argv[1] if len(sys.argv) > 1 else '.'
rng = np.random.default_rng(55)


def note_hz(n):
    return 440.0 * 2 ** ((n - 69) / 12.0)


def env(n, a=0.01, r=0.2):
    t = np.arange(n) / SR
    e = np.minimum(1.0, t / max(a, 1e-4))
    tail = np.clip((n / SR - t) / max(r, 1e-4), 0, 1)
    return e * tail


def osc(kind, hz, n, phase=0.0):
    t = np.arange(n) / SR
    if np.ndim(hz):
        ph = (np.cumsum(hz) / SR + phase) % 1.0
    else:
        ph = (t * hz + phase) % 1.0
    if kind == 'square':
        return np.where(ph < 0.5, 1.0, -1.0)
    if kind == 'tri':
        return 4 * np.abs(ph - 0.5) - 1
    if kind == 'saw':
        return 2 * ph - 1
    return np.sin(2 * np.pi * ph)


def lowpass(x, a=0.15):
    y = np.zeros_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc += a * (x[i] - acc)
        y[i] = acc
    return y


def add(buf, at, sig):
    i = int(at * SR)
    j = min(len(buf), i + len(sig))
    if i < len(buf):
        buf[i:j] += sig[:j - i]


def echo(x, delay=0.25, fb=0.3, mix=0.3):
    d = int(delay * SR)
    y = x.copy()
    for i in range(d, len(y)):
        y[i] += y[i - d] * fb
    return x * (1 - mix) + y * mix


def brass(hz, sec, vol=0.3, vib=4.5):
    n = int(sec * SR)
    t = np.arange(n) / SR
    f = hz * (1 + 0.006 * np.sin(2 * np.pi * vib * t) * np.minimum(1, t * 3))
    s = osc('saw', f, n) * 0.6 + osc('square', f * 0.5, n) * 0.25 + osc('sine', f * 2, n) * 0.15
    s = lowpass(s, 0.09 + 0.08 * min(1.0, sec))
    return s * env(n, 0.06, min(0.35, sec * 0.4)) * vol


def horn():
    # two long low calls, the second a fifth higher, like a watchman on the wall
    buf = np.zeros(int(3.2 * SR))
    add(buf, 0.0, brass(note_hz(43), 1.25, 0.55, 3.0))
    add(buf, 0.0, brass(note_hz(31), 1.25, 0.3, 3.0))
    add(buf, 1.35, brass(note_hz(50), 1.6, 0.55, 3.0))
    add(buf, 1.35, brass(note_hz(38), 1.6, 0.3, 3.0))
    return echo(buf, 0.33, 0.35, 0.4)


def roar():
    n = int(1.9 * SR)
    t = np.arange(n) / SR
    f = 70 + 55 * np.exp(-((t - 0.45) ** 2) / 0.08) - 25 * t
    growl = osc('saw', f, n) * (0.6 + 0.4 * osc('sine', 23, n))
    noise = lowpass(rng.uniform(-1, 1, n), 0.08) * 1.6
    s = lowpass(growl * 0.7 + noise * 0.5, 0.18) * env(n, 0.12, 0.8)
    rumble = lowpass(rng.uniform(-1, 1, n), 0.01) * 6.0 * env(n, 0.05, 1.2)
    return np.clip((s + rumble) * 0.9, -1, 1)


def mhit():
    n = int(0.32 * SR)
    t = np.arange(n) / SR
    thump = osc('sine', 95 * np.exp(-t * 9) + 40, n) * np.exp(-t * 14)
    crack = lowpass(rng.uniform(-1, 1, n), 0.35) * np.exp(-t * 40)
    return np.clip(thump * 0.9 + crack * 0.45, -1, 1)


def victory():
    buf = np.zeros(int(2.6 * SR))
    seq = [(0.0, 60, 0.16), (0.18, 64, 0.16), (0.36, 67, 0.16), (0.54, 72, 0.5), (1.1, 67, 0.16), (1.28, 72, 1.1)]
    for at, nn, d in seq:
        add(buf, at, brass(note_hz(nn), d + 0.05, 0.32, 5.5))
        add(buf, at, brass(note_hz(nn - 12), d + 0.05, 0.16, 5.5))
    k = int(0.25 * SR)
    for at in (0.54, 1.28):
        tt = np.arange(k) / SR
        add(buf, at, osc('sine', 60 * np.exp(-tt * 6) + 35, k) * np.exp(-tt * 9) * 0.5)
    return echo(buf, 0.21, 0.25, 0.3)


def escape():
    buf = np.zeros(int(2.4 * SR))
    for i, nn in enumerate([62, 60, 57, 53]):
        add(buf, i * 0.42, brass(note_hz(nn), 0.6 if i < 3 else 1.2, 0.3, 3.5))
    return echo(buf, 0.3, 0.35, 0.4)


def music_boss(sec=None):
    bpm = 132
    beat = 60.0 / bpm
    bars = 8
    n = int(bars * 4 * beat * SR)
    buf = np.zeros(n)
    roots = [40, 40, 43, 38, 40, 40, 45, 47]          # E minor, a little darker on the turn
    for b, r in enumerate(roots):
        t0 = b * 4 * beat
        for e in range(8):                             # galloping bass eighths
            k = int(beat * 0.5 * SR * 0.9)
            nn = r if e % 4 != 3 else r + 7
            add(buf, t0 + e * beat * 0.5, lowpass(osc('square', note_hz(nn - 12), k), 0.12) * env(k, 0.005, 0.08) * 0.22)
        for q in range(4):                             # drums
            k = int(0.22 * SR)
            tt = np.arange(k) / SR
            if q in (0, 2):
                add(buf, t0 + q * beat, osc('sine', 120 * np.exp(-tt * 18) + 45, k) * np.exp(-tt * 10) * 0.55)
            else:
                add(buf, t0 + q * beat, lowpass(rng.uniform(-1, 1, k), 0.5) * np.exp(-tt * 22) * 0.3)
            hk = int(0.04 * SR)
            add(buf, t0 + q * beat + beat * 0.5, rng.uniform(-1, 1, hk) * np.exp(-np.arange(hk) / SR * 90) * 0.08)
        add(buf, t0, brass(note_hz(r + 12), 4 * beat * 0.95, 0.07, 4.0))       # a held brass pad
        add(buf, t0, brass(note_hz(r + 19), 4 * beat * 0.95, 0.05, 4.0))
    lead = [(0, 64), (1.5, 67), (2, 71), (3, 69), (4, 67), (6, 64), (7, 66),
            (8, 67), (9.5, 71), (10, 74), (11, 72), (12, 71), (14, 69), (15, 71)]
    for half in (0, 16):
        for at, nn in lead:
            add(buf, (half + at) * beat, brass(note_hz(nn), beat * 0.9, 0.12, 6.0))
    fade = int(0.4 * SR)
    head = buf[:fade].copy()
    buf[:fade] = head * np.linspace(0, 1, fade) + buf[-fade:] * np.linspace(1, 0, fade)
    return buf[:-fade]


def write_wav(path, x):
    x = np.clip(x / max(1e-6, np.max(np.abs(x))) * 0.85, -1, 1)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype('<i2').tobytes())


def write_ogg(name, x, q=3):
    tmp = os.path.join(OUT, name + '.tmp.wav')
    write_wav(tmp, x)
    dst = os.path.join(OUT, name + '.ogg')
    try:
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', tmp, '-c:a', 'libvorbis', '-q:a', str(q), dst], check=True)
    finally:
        os.remove(tmp)


if __name__ == '__main__':
    write_wav(os.path.join(OUT, 'horn.wav'), horn())
    write_wav(os.path.join(OUT, 'roar.wav'), roar())
    write_wav(os.path.join(OUT, 'mhit.wav'), mhit())
    write_wav(os.path.join(OUT, 'victory.wav'), victory())
    write_wav(os.path.join(OUT, 'escape.wav'), escape())
    write_ogg('music_boss', music_boss())
    print('ok')
