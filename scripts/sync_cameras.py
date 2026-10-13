#!/usr/bin/env python3
"""
sync_cameras.py — poravnava N kamera (telefona) na glavni miks, preko zvuka.

Svaka kamera snima sliku i zvuk vlastitim satom, u istu datoteku. Zato njen zvuk
govori gdje je njena slika: koreliramo ga s glavnim miksom u mnogo prozora kroz
cijelu snimku i kroz točke provučemo pravac

    t_master = a + b · t_kamera

`a` je pomak, `b` drift kamerinog kristala (b = 1 + ppm·1e-6). Jedan prozor bi
dao samo pomak; pravac kroz desetke prozora daje i drift i pokazuje je li drift
uopće linearan (rezidual). Ne treba ni mreža ni pljesak — samo da kamera čuje
istu prostoriju kao miks.

Korelacija je GCC-PHAT (izbijeljeni spektar), jer telefon i PodMic imaju posve
različit frekvencijski odziv; obična korelacija bi se zalijepila za bas i jeku.

    sync_cameras.py --master miks.wav --cameras DIR_ILI_DATOTEKE… [--out DIR]
                    [--render] [--grid] [--av-offset ime=ms …]

Izlaz: <out>/multicam_sync.json, uz --render <out>/<kamera>.mov poravnat na
vremensku crtu miksa (crno gdje kamera nije snimala, zvuk = miks), uz --grid
<out>/grid.mp4 — sve kamere u mreži, za provjeru okom.
"""

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy import fft as sfft
from scipy import signal

FINE_SR = 8000          # Hz — fino mjerenje; s parabolom daje ispod 0,1 ms
COARSE_SR = 2000        # Hz — gruba pretraga po cijelom miksu
WINDOW_S = 20.0         # trajanje prozora kamere
SEARCH_S = 0.35         # ± oko predviđene točke u finoj fazi
MIN_PSR = 8.0           # ispod toga prozor nije pouzdan
VIDEO_EXT = {".mp4", ".mov", ".m4v"}
# Homebrew ffmpeg dolazi bez freetypea; tada grid ide bez natpisa.
HAS_DRAWTEXT = " drawtext " in subprocess.run(["ffmpeg", "-hide_banner", "-filters"],
                                              capture_output=True, text=True).stdout


def log(msg):
    print(msg, flush=True)


def load_audio(path, sr, start=None, duration=None):
    """Mono float32 na zadanoj frekvenciji, preko ffmpega."""
    cmd = ["ffmpeg", "-v", "error", "-nostdin"]
    if start is not None:
        cmd += ["-ss", f"{max(0.0, start):.6f}"]
    if duration is not None:
        cmd += ["-t", f"{duration:.6f}"]
    cmd += ["-i", str(path), "-vn", "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float32)


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(path)],
        capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def bandpass(x, sr):
    lo, hi = 100.0, min(3800.0, sr * 0.45)
    sos = signal.butter(4, [lo, hi], btype="band", fs=sr, output="sos")
    return signal.sosfiltfilt(sos, x).astype(np.float32)


def gcc_phat(window, region, sr, beta=0.8):
    """Gdje se `window` najbolje uklapa u `region`.

    Vraća (lag u uzorcima s podrezolucijom, PSR). Lag k znači da window[0]
    odgovara region[k]. PSR je visina vrha u standardnim devijacijama
    korelacije oko njega — mjera povjerenja neovisna o glasnoći.
    """
    n = len(window) + len(region)
    nfft = sfft.next_fast_len(n)
    X = sfft.rfft(window, nfft)
    Y = sfft.rfft(region, nfft)
    R = np.conj(X) * Y
    R /= np.abs(R) ** beta + 1e-12
    cc = sfft.irfft(R, nfft)
    valid = len(region) - len(window) + 1
    if valid < 3:
        return None, 0.0
    cc = cc[:valid]
    k = int(np.argmax(cc))
    peak = cc[k]
    mask = np.ones(valid, bool)
    mask[max(0, k - 20):k + 21] = False
    rest = cc[mask]
    psr = float((peak - rest.mean()) / (rest.std() + 1e-12)) if rest.size > 10 else 0.0
    frac = 0.0
    if 0 < k < valid - 1:
        y0, y1, y2 = cc[k - 1], cc[k], cc[k + 1]
        denom = y0 - 2 * y1 + y2
        if denom != 0:
            frac = 0.5 * (y0 - y2) / denom
    return k + frac, psr


def coarse_offset(cam_path, cam_dur, master_coarse):
    """Pomak a (s) iz nekoliko prozora pretraženih po cijelom miksu."""
    candidates = []
    for frac in (0.1, 0.3, 0.5, 0.7, 0.9):
        start = max(0.0, min(cam_dur - WINDOW_S * 2, cam_dur * frac))
        w = load_audio(cam_path, COARSE_SR, start, WINDOW_S * 2)
        if len(w) < COARSE_SR * 5 or len(w) >= len(master_coarse):
            continue
        lag, psr = gcc_phat(bandpass(w, COARSE_SR), master_coarse, COARSE_SR)
        if lag is not None:
            candidates.append((psr, lag / COARSE_SR - start, start))
    if not candidates:
        return None, 0.0, [], 0
    # Prozori koji se slažu oko istog pomaka nadglasaju jedan jači vrh — glazbena
    # špica ili ponovljena rečenica daje visok PSR na krivom mjestu.
    def support(c):
        return sum(1 for d in candidates if abs(d[1] - c[1]) < 0.05)
    best = max(candidates, key=lambda c: (support(c), c[0]))
    shown = [(round(float(c[1]), 4), round(c[0], 1)) for c in candidates]
    return best[1], best[0], shown, support(best)


def robust_line(cs, ms):
    """Pravac m = a + b·c, uz odbacivanje outliera (3×MAD, najmanje 2 ms)."""
    keep = np.ones(len(cs), bool)
    for _ in range(5):
        b, a = np.polyfit(cs[keep], ms[keep], 1)
        res = ms - (a + b * cs)
        mad = np.median(np.abs(res[keep] - np.median(res[keep])))
        new = np.abs(res) < max(0.002, 3 * 1.4826 * mad)
        if new.sum() < 2 or (new == keep).all():
            break
        keep = new
    b, a = np.polyfit(cs[keep], ms[keep], 1)
    res = ms - (a + b * cs)
    return a, b, res, keep


def correlate_at(cam, master, s, window_s, search_s, a, b):
    """Prozor kamere od t_kamera = s, izobličen za drift b, nađen u miksu oko a + b·s.

    Uzorci se uzimaju na kamerinim vremenima s + k/(b·SR), tj. na jednolikoj
    mreži *miksa* — pa je prozor u vremenu miksa, i vrh ostaje oštar.
    Vraća (s, t_miks početka prozora, PSR) ili None.
    """
    win = int(window_s * FINE_SR)
    search = int(search_s * FINE_SR)
    pos = s * FINE_SR + np.arange(win) / b
    if pos[0] < 0 or pos[-1] >= len(cam) - 1:
        return None
    i0 = int(pos[0])
    seg = cam[i0:int(pos[-1]) + 2]
    w = np.interp(pos - i0, np.arange(len(seg)), seg).astype(np.float32)
    if np.sqrt(np.mean(w ** 2)) < 1e-5:
        return None
    j0 = int(round((a + b * s) * FINE_SR)) - search
    j1 = j0 + win + 2 * search
    if j0 < 0 or j1 > len(master):
        return None
    lag, psr = gcc_phat(w, master[j0:j1], FINE_SR)
    if lag is None:
        return None
    return s, (j0 + lag) / FINE_SR, psr


def sync_camera(cam_path, master_fine, master_coarse, master_dur):
    info = probe(cam_path)
    cam_dur = float(info["format"]["duration"])
    if not any(s["codec_type"] == "audio" for s in info["streams"]):
        raise RuntimeError("kamera nema zvučni trag — ne može se sinkronizirati")

    coarse = coarse_offset(cam_path, cam_dur, master_coarse)
    a0, psr0, cands, agree = coarse
    if a0 is None:
        raise RuntimeError("gruba korelacija nije uspjela")
    log(f"   grubo: a = {a0:+.3f} s (PSR {psr0:.1f}, slaže se {agree}/{len(cands)}: {cands})")
    if agree < 2:
        log("   ⚠️  grubi prozori se ne slažu — pomak je nesiguran, provjeri grid.mp4")

    cam = load_audio(cam_path, FINE_SR)
    cam = bandpass(cam, FINE_SR)

    # Dva prolaza. PHAT daje vrh širok jedan uzorak, a drift od 60 ppm rastegne
    # prozor od 20 s za ~10 uzoraka i razmaže ga. Zato prvo kratki prozori (malo
    # rastezanja) daju drift, a onda se dugi prozori prije korelacije izobliče za
    # taj drift — tada su opet oštri i daju podmilisekundnu točnost.
    a, b = a0, 1.0
    points = []
    for window_s, search_s, n_windows in ((4.0, SEARCH_S, 120), (WINDOW_S, 0.25, 60)):
        lo = max(0.0, -a) + 0.5
        hi = min(cam_dur, (master_dur - a) / b) - window_s - 0.5
        if hi <= lo:
            raise RuntimeError("kamera i miks se ne preklapaju")
        starts = np.arange(lo, hi + 1e-9, max(window_s, (hi - lo) / n_windows))
        points = []
        for s in starts:
            m = correlate_at(cam, master_fine, s, window_s, search_s, a, b)
            if m is None:
                continue
            points.append(m)
            good = [(c, mm) for c, mm, p in points if p >= MIN_PSR]
            if window_s < WINDOW_S and len(good) >= 4:
                c_, m_ = np.array(good).T
                a, b, _, _ = robust_line(c_, m_)
        good = [(c, m, p) for c, m, p in points if p >= MIN_PSR]
        if len(good) < 3:
            raise RuntimeError(f"premalo pouzdanih prozora ({len(good)}/{len(points)})")
        cs, ms, ps = (np.array(v) for v in zip(*good))
        a, b, res, keep = robust_line(cs, ms)

    ppm = (b - 1.0) * 1e6
    if abs(ppm) > 500:
        raise RuntimeError(f"drift {ppm:.0f} ppm je nerealan — korelacija je promašila")

    # Je li drift linearan: rezidual između prve i druge polovice.
    half = len(cs) // 2
    walk_ms = float((np.median(res[keep][half:]) - np.median(res[keep][:half])) * 1000) if half >= 2 else 0.0
    return {
        "file": str(cam_path),
        "durationSeconds": cam_dur,
        "offsetSeconds": float(a),
        "scale": float(b),
        "driftPPM": float(ppm),
        "driftOverTakeMs": float((b - 1.0) * cam_dur * 1000),
        "windows": len(points),
        "windowsUsed": int(keep.sum()),
        "medianPSR": float(np.median(ps)),
        "residualRmsMs": float(np.sqrt(np.mean(res[keep] ** 2)) * 1000),
        "residualMaxMs": float(np.max(np.abs(res[keep])) * 1000),
        "halfWalkMs": walk_ms,
        "points": [[round(float(c), 3), round(float(m - (a + b * c)) * 1000, 3), round(float(p), 1)]
                   for c, m, p in zip(cs, ms, ps)],
    }


def find_cameras(paths):
    """Video datoteke + ime kamere (iz sidecar JSON-a, inače iz imena mape)."""
    found = []
    for p in map(Path, paths):
        files = [p] if p.is_file() else sorted(f for f in p.rglob("*") if f.suffix.lower() in VIDEO_EXT)
        for f in files:
            name = None
            for side in f.parent.glob("*.json"):
                try:
                    meta = json.loads(side.read_text())
                except Exception:
                    continue
                if meta.get("file") == f.name:
                    name = meta.get("camera", {}).get("name")
            found.append((name or (f.parent.name if f.parent != p or p.is_dir() else f.stem), f))
    names = {}
    out = []
    for name, f in found:
        names[name] = names.get(name, 0) + 1
        out.append((name if names[name] == 1 else f"{name}-{names[name]}", f))
    return out


def render(cam, master, master_dur, out_path, size="1920:1080", fps=30, crf_args=None):
    """Kamera na vremensku crtu miksa: frame u t_k ide na a + b·t_k − av."""
    a, b = cam["offsetSeconds"] - cam.get("avOffsetMs", 0.0) / 1000.0, cam["scale"]
    w, h = size.split(":")
    vf = (f"[1:v]setpts=(PTS-STARTPTS)*{b!r}+({a!r})/TB,trim=start=0,setpts=PTS,"
          f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2[cam];"
          f"[0:v][cam]overlay=eof_action=pass:repeatlast=0,fps={fps}[v]")
    cmd = ["ffmpeg", "-v", "error", "-stats", "-y",
           "-f", "lavfi", "-i", f"color=black:s={w}x{h}:r={fps}:d={master_dur:.3f}",
           "-i", cam["file"], "-i", str(master),
           "-filter_complex", vf, "-map", "[v]", "-map", "2:a",
           *(crf_args or ["-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1"]),
           "-c:a", "aac", "-b:a", "256k", "-t", f"{master_dur:.3f}", str(out_path)]
    subprocess.run(cmd, check=True)


def grid(rendered, master, out_path):
    n = len(rendered)
    cols = math.ceil(math.sqrt(n))
    rows = math.ceil(n / cols)
    inputs, chains = [], []
    for i, (name, path) in enumerate(rendered):
        inputs += ["-i", str(path)]
        label = name.replace("'", "").replace(":", " ")
        text = (f",drawtext=text='{label}':x=10:y=10:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5"
                if HAS_DRAWTEXT else "")
        chains.append(f"[{i}:v]scale=640:360{text}[g{i}]")
    if n == 1:
        layout = "[g0]copy[v]"
    else:
        cells = "|".join(f"{(i % cols) * 640}_{(i // cols) * 360}" for i in range(n))
        layout = "".join(f"[g{i}]" for i in range(n)) + f"xstack=inputs={n}:layout={cells}:fill=black[v]"
    cmd = ["ffmpeg", "-v", "error", "-stats", "-y", *inputs, "-i", str(master),
           "-filter_complex", ";".join(chains) + ";" + layout,
           "-map", "[v]", "-map", f"{n}:a", "-c:v", "h264_videotoolbox", "-b:v", "6M",
           "-c:a", "aac", "-shortest", str(out_path)]
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--master", required=True, help="glavni miks (wav ili bilo što što ffmpeg čita)")
    ap.add_argument("--cameras", nargs="+", required=True, help="video datoteke ili mape (npr. izlaz director.mjs pull)")
    ap.add_argument("--out", default=None, help="izlazna mapa (zadano: uz miks, multicam_synced/)")
    ap.add_argument("--render", action="store_true", help="izvezi svaku kameru poravnatu na miks")
    ap.add_argument("--grid", action="store_true", help="mreža svih kamera za provjeru (traži --render)")
    ap.add_argument("--av-offset", action="append", default=[], metavar="IME=MS",
                    help="kamerin vlastiti A/V pomak iz pljeska: + znači slika kasni za svojim zvukom")
    args = ap.parse_args()

    master = Path(args.master)
    out = Path(args.out) if args.out else master.parent / "multicam_synced"
    out.mkdir(parents=True, exist_ok=True)
    av = {k: float(v) for k, v in (x.split("=", 1) for x in args.av_offset)}

    master_dur = float(probe(master)["format"]["duration"])
    log(f"🎚  Miks: {master} ({master_dur:.1f} s)")
    master_fine = bandpass(load_audio(master, FINE_SR), FINE_SR)
    master_coarse = bandpass(load_audio(master, COARSE_SR), COARSE_SR)

    cameras = find_cameras(args.cameras)
    if not cameras:
        sys.exit("❌ Nema video datoteka.")

    results, failed = {}, []
    for name, path in cameras:
        log(f"📱 {name}: {path.name}")
        try:
            r = sync_camera(path, master_fine, master_coarse, master_dur)
        except Exception as e:
            log(f"   ❌ {e}")
            failed.append(name)
            continue
        r["avOffsetMs"] = av.get(name, 0.0)
        results[name] = r
        flag = "✅" if r["residualRmsMs"] < 2 and r["medianPSR"] > 15 else "⚠️ "
        log(f"   {flag} pomak {r['offsetSeconds']:+.4f} s · drift {r['driftPPM']:+.1f} ppm "
            f"({r['driftOverTakeMs']:+.1f} ms kroz snimku) · rezidual {r['residualRmsMs']:.2f} ms RMS, "
            f"max {r['residualMaxMs']:.2f} · {r['windowsUsed']}/{r['windows']} prozora · PSR {r['medianPSR']:.0f}")
        if abs(r["halfWalkMs"]) > 3:
            log(f"   ⚠️  drift nije linearan: druga polovica odstupa {r['halfWalkMs']:+.1f} ms")
        if name not in av:
            log("   ℹ️  bez --av-offset: pretpostavljam da je slika telefona poravnata s njegovim zvukom")

    (out / "multicam_sync.json").write_text(json.dumps(
        {"version": 1, "master": str(master), "masterDurationSeconds": master_dur,
         "model": "t_master = offsetSeconds + scale * t_camera - avOffsetMs/1000",
         "cameras": results, "failed": failed}, indent=2, ensure_ascii=False))
    log(f"📝 {out / 'multicam_sync.json'}")

    if args.render:
        rendered = []
        for name, r in results.items():
            dest = out / f"{name}.mov"
            log(f"🎬 {dest.name}")
            render(r, master, master_dur, dest)
            rendered.append((name, dest))
        if args.grid and rendered:
            log("🧩 grid.mp4")
            grid(rendered, master, out / "grid.mp4")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
