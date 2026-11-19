"""Generates Pulse v5's music and ambience (no outside audio files).
  music_town.ogg   bright medieval-chiptune loop (D dorian)
  music_mine.ogg   slow, low and echoing (A minor drone)
  music_arena.ogg  driving drums and a fanfare (E minor)
  amb_cave.ogg     drips, distant rumbles, air
  amb_town.ogg     wind, birdsong
  amb_tavern.ogg   murmuring crowd, clinks
  amb_lake.ogg     lapping water, drips
  payday.wav       coin cascade + chime
  chime.wav        soft crystal chime
Every loop is seamless (the tail is cross-faded into the head).
Run:  python audiogen.py <out_dir>
"""
import os, sys, subprocess, wave
import numpy as np

SR = 22050
OUT = sys.argv[1] if len(sys.argv) > 1 else '.'
rng = np.random.default_rng(7)

def note_hz(n):
    return 440.0 * 2 ** ((n - 69) / 12.0)

def env(n, a=0.01, r=0.2, sus=1.0):
    t = np.arange(n) / SR
    e = np.minimum(1.0, t / max(a, 1e-4))
    tail = np.clip((n / SR - t) / max(r, 1e-4), 0, 1)
    return e * np.minimum(tail, 1.0) * sus

def osc(kind, hz, n, duty=0.5):
    t = np.arange(n) / SR
    ph = (t * hz) % 1.0
    if kind == 'square':
        return np.where(ph < duty, 1.0, -1.0)
    if kind == 'tri':
        return 4 * np.abs(ph - 0.5) - 1
    if kind == 'saw':
        return 2 * ph - 1
    return np.sin(2 * np.pi * ph)

def lowpass(x, a=0.15):
    y = np.empty_like(x)
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

def echo(x, delay=0.28, fb=0.35, mix=0.35):
    d = int(delay * SR)
    y = x.copy()
    for i in range(d, len(y)):
        y[i] += y[i - d] * fb
    return x * (1 - mix) + y * mix

def loopify(x, fade=0.6):
    f = int(fade * SR)
    head, tail = x[:f].copy(), x[-f:].copy()
    w = np.linspace(0, 1, f)
    x = x[:-f].copy()
    x[:f] = head * w + tail * (1 - w)
    return x

def kick(n=int(0.25 * SR)):
    t = np.arange(n) / SR
    return np.sin(2 * np.pi * (55 + 90 * np.exp(-t * 30)) * t) * np.exp(-t * 14)

def snare(n=int(0.18 * SR)):
    t = np.arange(n) / SR
    return (rng.uniform(-1, 1, n) * 0.7 + np.sin(2 * np.pi * 190 * t) * 0.3) * np.exp(-t * 22)

def hat(n=int(0.05 * SR)):
    t = np.arange(n) / SR
    return rng.uniform(-1, 1, n) * np.exp(-t * 80) * 0.5

def song(bpm, bars, chords, scale, lead_kind, bass_kind, drums, seed, lead_vol=0.22, drone=None, swing=0.0):
    r = np.random.default_rng(seed)
    beat = 60.0 / bpm
    total = bars * 4 * beat
    buf = np.zeros(int((total + 1.0) * SR))
    melody_prev = 7
    for b in range(bars):
        root = chords[b % len(chords)]
        t0 = b * 4 * beat
        # bass: root on 1 and 3, fifth on 2 and 4
        for k, iv in enumerate((0, 7, 0, 7)):
            n = int(beat * 0.9 * SR)
            add(buf, t0 + k * beat, osc(bass_kind, note_hz(root - 12 + iv), n) * env(n, 0.005, 0.15) * 0.18)
        # arpeggio pad
        for k in range(8):
            iv = (0, 3 if (root % 12) in (2, 9, 4) else 4, 7, 12)[k % 4]
            n = int(beat * 0.45 * SR)
            add(buf, t0 + k * beat / 2, osc('tri', note_hz(root + iv), n) * env(n, 0.01, 0.2) * 0.07)
        # lead: a stepwise walk on the scale, phrase-shaped
        steps = [0.5] * 8 if b % 2 == 0 else [1, 0.5, 0.5, 1, 1]
        t = t0
        for k, d in enumerate(steps):
            melody_prev = int(np.clip(melody_prev + r.choice([-2, -1, -1, 0, 1, 1, 2]), 0, len(scale) - 1))
            if k == len(steps) - 1 and b % 4 == 3:
                melody_prev = 0
            n = int(d * beat * 0.92 * SR)
            hz = note_hz(scale[melody_prev] + 12)
            vib = 1 + 0.004 * np.sin(2 * np.pi * 5.5 * np.arange(n) / SR)
            sig = osc(lead_kind, 1, n)  # placeholder shape
            tt = np.arange(n) / SR
            ph = np.cumsum(hz * vib / SR) % 1.0
            sig = np.where(ph < 0.5, 1.0, -1.0) if lead_kind == 'square' else (4 * np.abs(ph - 0.5) - 1)
            if r.random() > 0.12:
                add(buf, t + (swing * beat if k % 2 else 0), sig * env(n, 0.01, 0.12) * lead_vol)
            t += d * beat
        if drums:
            for k in range(4):
                add(buf, t0 + k * beat, kick() * (0.35 if k % 2 == 0 else 0.0))
                add(buf, t0 + k * beat, snare() * (0.18 if k % 2 == 1 else 0.0))
                for h in range(2):
                    add(buf, t0 + k * beat + h * beat / 2, hat() * 0.25)
    if drone is not None:
        n = len(buf)
        tt = np.arange(n) / SR
        buf += (np.sin(2 * np.pi * note_hz(drone) * tt) + 0.5 * np.sin(2 * np.pi * note_hz(drone + 7) * tt)) * 0.05 * (0.8 + 0.2 * np.sin(2 * np.pi * 0.07 * tt))
    buf = buf[:int(total * SR) + int(0.6 * SR)]
    return buf

def noise_bed(seconds, cutoff=0.05, vol=0.1):
    return lowpass(rng.uniform(-1, 1, int(seconds * SR)), cutoff) * vol

def drip(at_buf, t, hz):
    n = int(0.25 * SR)
    tt = np.arange(n) / SR
    s = np.sin(2 * np.pi * (hz + 900 * np.exp(-tt * 40)) * tt) * np.exp(-tt * 18) * 0.35
    add(at_buf, t, s)

def amb_cave(sec=24.0):
    b = noise_bed(sec + 0.6, 0.02, 0.18)
    for i in range(14):
        drip(b, rng.uniform(0, sec), rng.uniform(800, 1600))
    for i in range(2):
        n = int(2.5 * SR)
        tt = np.arange(n) / SR
        add(b, rng.uniform(0, sec - 3), lowpass(rng.uniform(-1, 1, n), 0.01) * np.sin(np.pi * tt / 2.5) * 2.0)
    return echo(b, 0.31, 0.4, 0.4)

def chirp(buf, t):
    for k in range(rng.integers(2, 5)):
        n = int(0.09 * SR)
        tt = np.arange(n) / SR
        f0 = rng.uniform(2500, 4200)
        s = np.sin(2 * np.pi * (f0 + 1500 * np.sin(np.pi * tt / 0.09)) * tt) * np.sin(np.pi * tt / 0.09) * 0.12
        add(buf, t + k * 0.12, s)

def amb_town(sec=24.0):
    b = noise_bed(sec + 0.6, 0.008, 0.25)
    for i in range(9):
        chirp(b, rng.uniform(0, sec - 1))
    return b

def amb_tavern(sec=20.0):
    b = noise_bed(sec + 0.6, 0.06, 0.06)
    tt = np.arange(len(b)) / SR
    for v in range(7):
        f = rng.uniform(110, 240)
        b += np.sin(2 * np.pi * f * tt + 3 * np.sin(2 * np.pi * rng.uniform(2, 5) * tt)) * 0.02 * (0.5 + 0.5 * np.sin(2 * np.pi * rng.uniform(0.1, 0.4) * tt + v))
    for i in range(6):
        n = int(0.3 * SR)
        x = np.arange(n) / SR
        add(b, rng.uniform(0, sec), np.sin(2 * np.pi * rng.uniform(2200, 3400) * x) * np.exp(-x * 25) * 0.18)
    return b

def amb_lake(sec=24.0):
    b = noise_bed(sec + 0.6, 0.03, 0.12)
    tt = np.arange(len(b)) / SR
    b *= 0.6 + 0.4 * np.sin(2 * np.pi * 0.25 * tt) ** 2
    for i in range(8):
        drip(b, rng.uniform(0, sec), rng.uniform(600, 1100))
    return echo(b, 0.4, 0.45, 0.45)

def payday():
    b = np.zeros(int(1.6 * SR))
    for i in range(14):
        n = int(0.18 * SR)
        x = np.arange(n) / SR
        f = rng.uniform(2600, 4200)
        add(b, i * 0.06 + rng.uniform(0, 0.03), (np.sin(2 * np.pi * f * x) + 0.4 * np.sin(2 * np.pi * f * 2.7 * x)) * np.exp(-x * 30) * 0.22)
    for k, n_ in enumerate((79, 83, 86, 91)):
        n = int(0.8 * SR)
        x = np.arange(n) / SR
        add(b, 0.55 + k * 0.08, np.sin(2 * np.pi * note_hz(n_) * x) * np.exp(-x * 4) * 0.2)
    return b

def chime():
    b = np.zeros(int(1.2 * SR))
    for k, n_ in enumerate((88, 95)):
        n = int(1.0 * SR)
        x = np.arange(n) / SR
        add(b, k * 0.07, (np.sin(2 * np.pi * note_hz(n_) * x) + 0.3 * np.sin(2 * np.pi * note_hz(n_) * 2.01 * x)) * np.exp(-x * 5) * 0.2)
    return b

def write_wav(path, x):
    x = np.clip(x / max(1e-6, np.max(np.abs(x))) * 0.85, -1, 1)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((x * 32767).astype(np.int16).tobytes())

def write_ogg(name, x, q=3):
    tmp = os.path.join(OUT, name + '.tmp.wav')
    write_wav(tmp, x)
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', tmp, '-c:a', 'libvorbis', '-q:a', str(q), os.path.join(OUT, name + '.ogg')], check=True)
    os.remove(tmp)

os.makedirs(OUT, exist_ok=True)
D_DORIAN = [62, 64, 65, 67, 69, 71, 72, 74, 76]
A_MINOR = [57, 59, 60, 62, 64, 65, 67, 69, 71]
E_MINOR = [64, 66, 67, 69, 71, 72, 74, 76, 78]
write_ogg('music_town', loopify(echo(song(104, 16, [62, 60, 58, 60], D_DORIAN, 'square', 'tri', False, 1, 0.18, swing=0.08), 0.24, 0.25, 0.2)))
write_ogg('music_mine', loopify(echo(song(72, 12, [57, 55, 53, 52], A_MINOR, 'tri', 'tri', False, 2, 0.2, drone=45), 0.42, 0.45, 0.4)))
write_ogg('music_arena', loopify(song(132, 16, [64, 62, 60, 59], E_MINOR, 'square', 'square', True, 3, 0.16)))
write_ogg('amb_cave', loopify(amb_cave()))
write_ogg('amb_town', loopify(amb_town()))
write_ogg('amb_tavern', loopify(amb_tavern()))
write_ogg('amb_lake', loopify(amb_lake()))
write_wav(os.path.join(OUT, 'payday.wav'), payday())
write_wav(os.path.join(OUT, 'chime.wav'), chime())
print('audio written to', OUT)
