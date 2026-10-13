#!/usr/bin/env python3
"""
Testovi za sync_cameras.py — poravnavanje kamera preko zvuka.

Gradi miks od sintetičkog govora (`say`) i iz njega tri "telefona" s poznatim
pomakom i driftom: drugi frekvencijski odziv, jeka, šum, druga glasnoća. Skripta
mora vratiti pomak i drift točno — i staviti bljesak iz kamere na pravi frame
miksa, jer točan broj koji se ne primijeni ne vrijedi ništa.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from scipy import signal

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "sync_cameras.py"
SR = 48000
FAILURES = []

# Svaka rečenica drugačija: ponovljeni tekst bi dao periodičan signal u kojem je
# svaki period jednako dobar pogodak, a pravi govor se ne ponavlja.
WORDS = ("kamera mikrofon studio gost pitanje odgovor vrijeme slika zvuk epizoda "
         "razgovor domovina snimka telefon sat kristal pomak drift").split()


def text(rng, n=70):
    return " ".join(
        f"Rečenica {i}: {' '.join(rng.choice(WORDS, rng.integers(5, 12)))}. [[slnc {int(rng.integers(100, 900))}]]"
        for i in range(n))

# ime: (a = gdje je t_kamera=0 na vremenu miksa, ppm, trajanje kamere u s, bljesak u t_kamera)
CAMERAS = {
    "rano": (-7.25, +38.0, 330.0, 100.0),      # počela prije miksa
    "kasno": (12.5, -61.0, 260.0, 50.0),       # počela poslije, kraća
    "tocno": (0.0, +4.0, 320.0, 200.0),
}


def expect(cond, msg):
    print(("✅ " if cond else "❌ ") + msg)
    if not cond:
        FAILURES.append(msg)


def wav_write(path, x):
    pcm = np.clip(x * 32767, -32768, 32767).astype("<i2").tobytes()
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", str(SR), "-ac", "1", "-i", "-", str(path)],
                   input=pcm, check=True)


def make_master(tmp):
    aiff = tmp / "speech.aiff"
    subprocess.run(["say", "-o", str(aiff), text(np.random.default_rng(7))], check=True)
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(aiff), "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    speech = np.frombuffer(raw, np.float32)
    assert len(speech) >= 330 * SR, f"govor prekratak: {len(speech) / SR:.0f} s"
    x = speech[: 330 * SR].astype(np.float64)
    rng = np.random.default_rng(1)
    x += rng.normal(0, 0.002, len(x))
    return x / np.max(np.abs(x)) * 0.7


def make_camera_audio(master, a, ppm, dur, seed):
    b = 1 + ppm * 1e-6
    t = np.arange(int(dur * SR)) / SR
    pos = (a + b * t) * SR
    y = np.interp(pos, np.arange(len(master)), master, left=0.0, right=0.0)
    # Telefon: drugi odziv, jeka sobe, šum, kompresija glasnoće.
    sos = signal.butter(2, [250, 7000], btype="band", fs=SR, output="sos")
    y = signal.sosfilt(sos, y)
    # Soba: izravni zvuk, refleksija od stola (2–4 ms) skoro jednako jaka, zidovi
    # (6–15 ms), pa difuzni rep od 15 ms s energijom ~6 dB iznad izravnog —
    # telefon dva metra od govornika, bez akustične obrade.
    rng = np.random.default_rng(seed)
    ir = np.zeros(int(0.3 * SR))
    ir[0] = 1.0
    ir[int(rng.uniform(0.002, 0.004) * SR)] += 0.7
    for d in rng.uniform(0.006, 0.015, 4):
        ir[int(d * SR)] += rng.uniform(0.3, 0.5) * rng.choice([-1, 1])
    tail = np.arange(int(0.015 * SR), len(ir))
    diffuse = rng.normal(0, 1, len(tail)) * np.exp(-(tail - tail[0]) / (0.08 * SR))
    ir[tail] += diffuse * np.sqrt(2.0 / np.sum(diffuse ** 2))
    y = signal.fftconvolve(y, ir)[: len(y)]
    y = y / np.max(np.abs(y)) * 0.5 + rng.normal(0, 0.01, len(y))
    return np.tanh(2 * y) * 0.6


def make_camera_video(tmp, name, audio, dur, flash_t):
    wav = tmp / f"{name}.wav"
    wav_write(wav, audio)
    path = tmp / "cams" / name / f"take-{name}.mov"
    path.parent.mkdir(parents=True, exist_ok=True)
    # Crno, a jedan jedini frame bijel: točno na flash_t (30 fps, frame = round(t·30)).
    n = round(flash_t * 30)
    vf = f"geq=lum='if(eq(N,{n}),235,16)':cb=128:cr=128"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=black:s=320x180:r=30:d={dur}",
                    "-i", str(wav), "-vf", vf, "-c:v", "libx264", "-preset", "ultrafast", "-g", "30",
                    "-c:a", "aac", "-b:a", "128k", "-shortest", str(path)], check=True)
    (path.parent / f"{name}.json").write_text(json.dumps({"file": path.name, "camera": {"name": name}}))
    return path


def flash_time(path):
    """Vrijeme (s) najsvjetlijeg framea u videu."""
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-vf", "scale=32:18,format=gray",
                          "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
    frames = np.frombuffer(out, np.uint8).reshape(-1, 32 * 18).mean(axis=1)
    return int(np.argmax(frames)) / 30.0, float(frames.max())


def main():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        print("🔧 Gradim miks i tri kamere…")
        master = make_master(tmp)
        master_path = tmp / "miks.wav"
        wav_write(master_path, master)
        for i, (name, (a, ppm, dur, flash)) in enumerate(CAMERAS.items()):
            make_camera_video(tmp, name, make_camera_audio(master, a, ppm, dur, i + 10), dur, flash)

        out = tmp / "out"
        r = subprocess.run([sys.executable, str(SCRIPT), "--master", str(master_path),
                            "--cameras", str(tmp / "cams"), "--out", str(out), "--render", "--grid"],
                           capture_output=True, text=True)
        print(r.stdout)
        expect(r.returncode == 0, f"skripta završila bez greške (exit {r.returncode}) {r.stderr[-500:]}")
        if r.returncode != 0:
            return
        res = json.loads((out / "multicam_sync.json").read_text())["cameras"]

        for name, (a, ppm, dur, flash) in CAMERAS.items():
            got = res.get(name)
            expect(got is not None, f"{name}: izmjerena")
            if not got:
                continue
            da = (got["offsetSeconds"] - a) * 1000
            dppm = got["driftPPM"] - ppm
            # Ukupna greška na kraju kamere je ono što se vidi na ekranu.
            end_err = abs(da + dppm * 1e-6 * dur * 1000)
            expect(abs(da) < 1.0, f"{name}: pomak {got['offsetSeconds']:+.5f} s (treba {a:+.5f}, greška {da:+.3f} ms)")
            expect(abs(dppm) < 2.0, f"{name}: drift {got['driftPPM']:+.2f} ppm (treba {ppm:+.1f})")
            expect(end_err < 1.0, f"{name}: greška na kraju kamere {end_err:.3f} ms")

            want = a + (1 + ppm * 1e-6) * (round(flash * 30) / 30)
            t, lum = flash_time(out / f"{name}.mov")
            expect(lum > 100 and abs(t - want) <= 1 / 30 + 1e-6,
                   f"{name}: bljesak na {t:.3f} s miksa (treba {want:.3f} s, ±1 frame)")

        dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                    str(out / "grid.mp4")], capture_output=True, text=True).stdout)
        expect(abs(dur - len(master) / SR) < 0.2, f"grid.mp4 traje koliko miks ({dur:.1f} s)")

    print()
    if FAILURES:
        print(f"❌ {len(FAILURES)} provjera nije prošlo")
        sys.exit(1)
    print("✅ Sve provjere prošle")


if __name__ == "__main__":
    main()
