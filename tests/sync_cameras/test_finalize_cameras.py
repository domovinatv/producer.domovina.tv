#!/usr/bin/env python3
"""
finalize_session.sh s N dodatnih kamera.

Sintetička sesija (ista kao u tests/finalize) s govorom umjesto tonova, prvi
prolaz napravi miks, iz tog miksa se izvedu dvije kamere s poznatim pomakom i
driftom i stave u <sesija>/cameras, a drugi prolaz ih mora sam pronaći, izmjeriti
i renderirati na vremensku crtu miksa. Treći prolaz s --cameras-sync-only ne
smije renderirati ništa, a kamera bez zvuka ne smije srušiti ostatak.
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "finalize"))
import test_finalize as tf          # noqa: E402
import test_sync_cameras as tc      # noqa: E402

SCRIPT = tf.SCRIPT
CAMS = {"telefon-a": (-3.4, +27.0, 150.0, 40.0), "telefon-b": (21.75, -44.0, 120.0, 70.0)}
FAILURES = []


def expect(cond, msg):
    print(("✅ " if cond else "❌ ") + msg)
    if not cond:
        FAILURES.append(msg)


def read_wav(path):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", "48000", "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.float32).astype(np.float64)


def finalize(session, *extra):
    r = subprocess.run(["bash", str(SCRIPT), "--session", str(session), *extra], capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def main():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        session = tmp / "session"
        tf.build_session(session)

        # Govor umjesto tonova: tonovi s periodom od 1,31 s nemaju jedinstveno
        # poravnanje, a govor ima.
        speech = tc.make_master(tmp)
        for i, name in enumerate(("mic-1", "mic-2")):
            part = speech[i * 100 * tc.SR:][: tf.DURATION * tc.SR] * (1.0 if i == 0 else 0.3)
            tc.wav_write(session / "audio" / f"{name}.wav", part)

        code, out = finalize(session)
        expect(code == 0, "prvi prolaz (bez kamera) prošao")
        expect("Dodatne kamere" not in out, "bez kamera nema koraka kamera")
        mix_path = session / "final" / "mix.wav"
        mix = read_wav(mix_path)

        for i, (name, (a, ppm, dur, flash)) in enumerate(CAMS.items()):
            audio = tc.make_camera_audio(mix, a, ppm, dur, 30 + i)
            src = tc.make_camera_video(tmp, name, audio, dur, flash)
            dest = session / "cameras" / name
            dest.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), dest / src.name)
            shutil.move(str(src.parent / f"{name}.json"), dest / f"{name}.json")

        code, out = finalize(session)
        expect(code == 0, "drugi prolaz (s kamerama) prošao")
        expect("📱 Dodatne kamere" in out, "kamere pronađene same, iz <sesija>/cameras")
        out_dir = session / "final" / "cameras"
        res = json.loads((out_dir / "multicam_sync.json").read_text())
        expect(not res["failed"], f"nijedna kamera nije pala ({res['failed']})")
        for name, (a, ppm, dur, flash) in CAMS.items():
            got = res["cameras"].get(name)
            if not got:
                expect(False, f"{name}: izmjerena")
                continue
            end_err = abs((got["offsetSeconds"] - a) * 1000 + (got["driftPPM"] - ppm) * 1e-6 * dur * 1000)
            expect(end_err < 1.0, f"{name}: pomak {got['offsetSeconds']:+.4f} s, drift {got['driftPPM']:+.1f} ppm, "
                                  f"greška na kraju {end_err:.3f} ms")
            want = a + (1 + ppm * 1e-6) * (round(flash * 30) / 30)
            t, lum = tc.flash_time(out_dir / f"{name}.mov")
            expect(lum > 100 and abs(t - want) <= 1 / 30 + 1e-6, f"{name}: bljesak na {t:.3f} s miksa (treba {want:.3f})")
        expect((out_dir / "grid.mp4").exists(), "grid.mp4 napravljen")

        # Samo mjerenje, i jedna kamera bez zvuka.
        shutil.rmtree(out_dir)
        mute = session / "cameras" / "nijemi"
        mute.mkdir()
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=5",
                        "-c:v", "libx264", "-preset", "ultrafast", str(mute / "nijemi.mov")], check=True)
        code, out = finalize(session, "--cameras-sync-only")
        res = json.loads((out_dir / "multicam_sync.json").read_text())
        expect(code == 0, "kamera bez zvuka ne ruši finalize")
        expect(res["failed"] == ["nijemi"] and len(res["cameras"]) == 2,
               f"nijema kamera prijavljena kao neuspjela, ostale izmjerene ({res['failed']})")
        expect("NISU poravnate" in out, "neuspjeh je ponovljen na kraju ispisa")
        expect(not list(out_dir.glob("*.mov")), "--cameras-sync-only ne renderira")

    print()
    if FAILURES:
        print(f"❌ {len(FAILURES)} provjera nije prošlo")
        sys.exit(1)
    print("✅ Sve provjere prošle")


if __name__ == "__main__":
    main()
