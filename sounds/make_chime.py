"""Generates done.wav: a soft two-note rising "bloop" chime for the Claude Code Stop hook.

Tweak NOTES / GAP / VOLUME and re-run:  python make_chime.py
"""
import math
import struct
import wave
from pathlib import Path

RATE = 44100
DURATION = 0.62          # seconds
VOLUME = 0.42            # peak, 0..1
GAP = 0.085              # seconds between the two notes
# (frequency Hz, decay tau s, gain) -- A5 then E6, a rising fifth
NOTES = [(880.0, 0.085, 0.85), (1318.5, 0.17, 1.0)]
# mallet-ish partials: (multiple of f0, relative gain); upper ones die faster
PARTIALS = [(1.0, 1.0), (2.0, 0.22), (3.0, 0.05)]
GLIDE = 1.05             # pitch starts 5% sharp and drops -> the "bloop"
GLIDE_TAU = 0.012


def tone(f0, tau, gain, start, buf):
    s0 = int(start * RATE)
    phases = [0.0] * len(PARTIALS)
    for i in range(s0, len(buf)):
        t = (i - s0) / RATE
        attack = min(1.0, t / 0.004)
        f = f0 * (1 + (GLIDE - 1) * math.exp(-t / GLIDE_TAU))
        v = 0.0
        for k, (mult, g) in enumerate(PARTIALS):
            phases[k] += 2 * math.pi * f * mult / RATE
            v += g * math.sin(phases[k]) * math.exp(-t * mult / tau)
        buf[i] += gain * attack * v


def main():
    n = int(DURATION * RATE)
    buf = [0.0] * n
    for idx, (f, tau, g) in enumerate(NOTES):
        tone(f, tau, g, idx * GAP, buf)

    # gentle one-pole low-pass to round off the edges
    out, prev = [], 0.0
    a = 0.55
    for x in buf:
        prev = prev + a * (x - prev)
        out.append(prev)

    # short fade-out so the tail never clicks
    fade = int(0.04 * RATE)
    for i in range(fade):
        out[n - fade + i] *= 1 - i / fade

    peak = max(abs(x) for x in out) or 1.0
    scale = VOLUME * 32767 / peak
    path = Path(__file__).with_name("done.wav")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(x * scale)) for x in out))
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
