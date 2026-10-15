#!/usr/bin/env python3
"""
sync_cameras.py --sync clock — poravnavanje po satu relaya (stadion).

Tri "telefona" s različitim satom (pomak, drift do ±80 ppm), uzorci sata s
lošom mrežom: RTT od 25 ms do 2 s, asimetrična ruta, rupa od nekoliko minuta
bez mreže usred snimke. Isti događaj (bljesak u istom trenutku po satu relaya)
mora pasti na isti frame u svim renderima, a početak svake kamere biti točan na
nekoliko ms — bez ijednog zajedničkog zvuka.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_sync_cameras as tc     # noqa: E402

SCRIPT = tc.SCRIPT
S0 = 1_760_000_000_000.0           # ms na satu relaya
FLASH_S = 140.0                    # bljesak: S0 + 140 s, isti za sve kamere
# ime: (početak snimke po relayu [s od S0], drift ppm, sat uređaja u S0 [ms], trajanje [s])
CAMS = {"gol-sjever": (10.0, +35.0, 5_000_123.4, 240.0),
        "tribina": (12.37, -80.0, 91_777_000.0, 230.0),
        "gol-jug": (9.12, +4.0, 3_210.9, 250.0)}
FAILURES = []


def expect(cond, msg):
    print(("✅ " if cond else "❌ ") + msg)
    if not cond:
        FAILURES.append(msg)


def dev_ms(name, srv_ms):
    start, ppm, d0, _ = CAMS[name]
    return d0 + (srv_ms - S0) * (1 + ppm * 1e-6)


def samples(name, rng):
    start, _, _, dur = CAMS[name]
    out = []
    for t in np.arange(start - 600, start + dur + 300, 5.0):
        if start + 60 < t < start + 230:        # rupa bez mreže
            continue
        rtt = 25 + rng.exponential(40)
        if rng.random() < 0.1:
            rtt += rng.uniform(300, 2000)       # zagušenje
        up = rtt * rng.uniform(0.2, 0.8)        # asimetrična ruta
        send = S0 + t * 1000
        out.append({"t1": int(dev_ms(name, send) * 1e6),
                    "t4": int(dev_ms(name, send + rtt) * 1e6),
                    "s": int(round(send + up))})
    return out


def make_camera(tmp, name, rng):
    start, ppm, d0, dur = CAMS[name]
    fz_ms = dev_ms(name, S0 + start * 1000)
    # Datoteka teče po satu uređaja: t_dat = (dev − fz)/1000.
    c_flash = (dev_ms(name, S0 + FLASH_S * 1000) - fz_ms) / 1000
    n = round(c_flash * 30)
    d = tmp / "cams" / name
    d.mkdir(parents=True)
    f = d / f"{name}.mp4"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"color=black:s=320x180:r=30:d={dur}",
                    "-f", "lavfi", "-i", f"sine=frequency={300 + len(name) * 20}:duration={dur}",
                    "-vf", f"geq=lum='if(eq(N,{n}),235,16)':cb=128:cr=128",
                    "-c:v", "libx264", "-preset", "ultrafast", "-g", "30", "-c:a", "aac", "-shortest", str(f)],
                   check=True)
    (d / f"{name}.json").write_text(json.dumps({
        "version": 2, "file": f.name, "camera": {"name": name},
        "clock": {"domain": "test", "fileZeroDeviceNs": int(fz_ms * 1e6), "fileZeroMethod": "test",
                  "fileZeroUncertaintyMs": 0.0, "samples": samples(name, rng)}}))


def main():
    rng = np.random.default_rng(3)
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name in CAMS:
            make_camera(tmp, name, rng)
        bez = tmp / "cams" / "bez-sata"
        bez.mkdir()
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "color=black:s=320x180:r=30:d=5",
                        "-f", "lavfi", "-i", "sine=duration=5", "-c:v", "libx264", "-c:a", "aac",
                        str(bez / "bez-sata.mp4")], check=True)

        out = tmp / "out"
        r = subprocess.run([sys.executable, str(SCRIPT), "--cameras", str(tmp / "cams"),
                            "--out", str(out), "--render", "--grid"], capture_output=True, text=True)
        print(r.stdout[-2500:])
        res = json.loads((out / "multicam_sync.json").read_text())
        expect(res["method"] == "clock", "bez --master bira se sat")
        expect(res["failed"] == ["bez-sata"], f"kamera bez sata prijavljena kao neuspjela ({res['failed']})")

        t0 = min(c[0] for c in CAMS.values())
        for name, (start, ppm, _, dur) in CAMS.items():
            got = res["cameras"].get(name)
            if not got:
                expect(False, f"{name}: poravnata")
                continue
            err = (got["offsetSeconds"] - (start - t0)) * 1000
            expect(abs(err) < 5, f"{name}: početak {got['offsetSeconds']:+.4f} s (treba {start - t0:+.4f}, "
                                 f"greška {err:+.2f} ms)")
            # scale je t_relay po t_datoteke = 1/(1+ppm)
            want_ppm = (1 / (1 + ppm * 1e-6) - 1) * 1e6
            expect(abs(got["driftPPM"] - want_ppm) < 5, f"{name}: drift {got['driftPPM']:+.1f} ppm (treba {want_ppm:+.1f})")
            t, lum = tc.flash_time(out / f"{name}.mov")
            want = FLASH_S - t0
            expect(lum > 100 and abs(t - want) <= 1 / 30 + 1e-6,
                   f"{name}: bljesak na {t:.3f} s zajedničke crte (treba {want:.3f})")
            a_dur = float(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
                                          "stream=duration", "-of", "csv=p=0", str(out / f"{name}.mov")],
                                         capture_output=True, text=True).stdout.strip() or 0)
            expect(abs(a_dur - res["masterDurationSeconds"]) < 0.1, f"{name}: zvuk pokriva cijelu crtu ({a_dur:.2f} s)")
        expect((out / "grid.mp4").exists(), "grid.mp4 bez miksa napravljen")

    print()
    if FAILURES:
        print(f"❌ {len(FAILURES)} provjera nije prošlo")
        sys.exit(1)
    print("✅ Sve provjere prošle")


if __name__ == "__main__":
    main()
