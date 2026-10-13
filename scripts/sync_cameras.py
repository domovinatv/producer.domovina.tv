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

Kad kamere ne čuju isto (stadion: zvuk prijeđe igralište za ~300 ms), radi se
po satu: --sync clock (zadano kad nema --master) koristi blok `clock` iz sidecara
(multicam/PROTOCOL.md, "Sat") — uzorke sata relaya kroz cijelu snimku i
vrijeme prvog framea na satu uređaja. Kad postoje i miks i sat, sat služi kao
neovisna provjera zvuka (clockVsAudioMs po kameri).

    sync_cameras.py [--master miks.wav] --cameras DIR_ILI_DATOTEKE… [--out DIR]
                    [--sync auto|audio|clock] [--render] [--grid] [--av-offset ime=ms …]

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
            name, sidecar = None, {}
            for side in f.parent.glob("*.json"):
                try:
                    meta = json.loads(side.read_text())
                except Exception:
                    continue
                if meta.get("file") == f.name:
                    name, sidecar = meta.get("camera", {}).get("name"), meta
            found.append((name or (f.parent.name if f.parent != p or p.is_dir() else f.stem), f, sidecar))
    names = {}
    out = []
    for name, f, meta in found:
        names[name] = names.get(name, 0) + 1
        out.append((name if names[name] == 1 else f"{name}-{names[name]}", f, meta))
    return out


def clock_fit(meta):
    """Gdje je slika kamere na satu relaya, iz sidecar v2 bloka `clock`.

    Svaki uzorak kaže: kad je uređaj bio na (t1+t4)/2, relay je bio na s, uz
    grešku do ±RTT/2. Mreža na stadionu puca i RTT skače, pa se iz svake
    minute uzima samo najbrži uzorak, a od njih samo oni blizu najbržih — sporiji
    uzorci nose asimetrično kašnjenje koje se ne poništava. Kroz preostale ide
    pravac: pomak i drift sata uređaja prema relayu.

    Vraća (A, B, info): t_relay [s] = A + B · t_datoteke [s], ili None.
    """
    clk = meta.get("clock") or {}
    samples = clk.get("samples") or []
    if clk.get("fileZeroDeviceNs") is None or not samples:
        return None
    t1 = np.array([x["t1"] for x in samples], float)
    t4 = np.array([x["t4"] for x in samples], float)
    srv = np.array([x["s"] for x in samples], float)
    ok = t4 > t1
    t1, t4, srv = t1[ok], t4[ok], srv[ok]
    if not len(t1):
        return None
    rtt = (t4 - t1) / 1e6
    mid = (t1 + t4) / 2e6                 # ms na satu uređaja
    off = srv - mid                       # sat relaya − sat uređaja, ms

    # U svakoj minuti ostaju uzorci blizu najbržeg u toj minuti (ruta se kroz
    # utakmicu mijenja, pa je prag lokalan), i to samo minute čiji je najbrži
    # uzorak blizu najbržeg uopće.
    bins = np.floor(mid / 60000.0)
    global_min = np.min(rtt)
    pick = []
    for b in np.unique(bins):
        idx = np.where(bins == b)[0]
        local = np.min(rtt[idx])
        if local <= global_min + 50:
            pick += [i for i in idx if rtt[i] <= local + 10]
    pick = np.array(sorted(pick))

    x0 = float(np.mean(mid[pick]))
    span_s = float(np.ptp(mid[pick])) / 1000 if len(pick) > 1 else 0.0
    if len(pick) >= 4 and span_s >= 120:
        keep = np.ones(len(pick), bool)
        # Težina 1/RTT²: greška asimetrije raste s RTT-om.
        w = 1.0 / rtt[pick]
        for _ in range(5):
            g, c = np.polyfit(mid[pick][keep] - x0, off[pick][keep], 1, w=w[keep])
            res = off[pick] - (c + g * (mid[pick] - x0))
            mad = np.median(np.abs(res[keep] - np.median(res[keep])))
            new = np.abs(res) < max(3.0, 3 * 1.4826 * mad)
            if new.sum() < 4 or (new == keep).all():
                break
            keep = new
        g, c = np.polyfit(mid[pick][keep] - x0, off[pick][keep], 1, w=w[keep])
        res = off[pick][keep] - (c + g * (mid[pick][keep] - x0))
    else:
        # Premalo uzoraka za drift: samo pomak iz najbržeg.
        j = pick[np.argmin(rtt[pick])]
        g, c, keep, res = 0.0, float(off[j] - 0.0), np.array([True]), np.array([0.0])
        x0 = float(mid[j])

    fz = clk["fileZeroDeviceNs"] / 1e6
    # t_relay(ms) = dev + c + g·(dev − x0), dev = fz + 1000·t
    a_ms = fz + c + g * (fz - x0)
    b = 1.0 + g
    return a_ms / 1000.0, b, {
        "clockDomain": clk.get("domain"),
        "fileZeroMethod": clk.get("fileZeroMethod"),
        "fileZeroUncertaintyMs": clk.get("fileZeroUncertaintyMs"),
        "clockSamples": int(len(t1)),
        "clockSamplesUsed": int(keep.sum()),
        "clockSpanSeconds": span_s,
        "minRttMs": float(np.min(rtt)),
        "medianRttMs": float(np.median(rtt)),
        "clockResidualRmsMs": float(np.sqrt(np.mean(res ** 2))),
        "clockDriftPPM": float(g * 1e6),
    }


def render(cam, master, master_dur, out_path, size="1920:1080", fps=30, crf_args=None):
    """Kamera na vremensku crtu miksa: frame u t_k ide na a + b·t_k − av."""
    a = float(cam["offsetSeconds"] - cam.get("avOffsetMs", 0.0) / 1000.0)
    b = float(cam["scale"])
    w, h = size.split(":")
    vf = (f"[1:v]setpts=(PTS-STARTPTS)*{b!r}+({a!r})/TB,trim=start=0,setpts=PTS,"
          f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2[cam];"
          f"[0:v][cam]overlay=eof_action=pass:repeatlast=0,fps={fps}[v]")
    if master is not None:
        audio_in, audio_map = ["-i", str(master)], "2:a"
    else:
        # Bez miksa (stadion): kamera nosi svoj zvuk, rastegnut i pomaknut isto
        # kao slika. asetrate prima samo cijele Hz (preslab za ppm), pa se
        # timestampovi skaliraju za b, a aresample meko rasteže zvuk prema njima
        # (izmjereno: stalni zaostatak ~1 ms, ne raste s duljinom).
        sr = 48000
        shift = (f"adelay={a * 1000:.3f}:all=1" if a >= 0
                 else f"atrim=start={-a:.6f},asetpts=PTS-STARTPTS")
        vf += (f";[1:a]aresample={sr},asetpts=(PTS-STARTPTS)*{b!r},"
               f"aresample={sr}:min_comp=0.001:min_hard_comp=1:max_soft_comp=0.01:first_pts=0,"
               f"{shift},apad=whole_dur={master_dur:.3f}[a]")
        audio_in, audio_map = [], "[a]"
    cmd = ["ffmpeg", "-v", "error", "-stats", "-y",
           "-f", "lavfi", "-i", f"color=black:s={w}x{h}:r={fps}:d={master_dur:.3f}",
           "-i", cam["file"], *audio_in,
           "-filter_complex", vf, "-map", "[v]", "-map", audio_map,
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
    # Bez miksa: svi renderi već nose zvuk poravnat na istu crtu, uzmi prvi.
    audio = ["-i", str(master)] if master is not None else []
    cmd = ["ffmpeg", "-v", "error", "-stats", "-y", *inputs, *audio,
           "-filter_complex", ";".join(chains) + ";" + layout,
           "-map", "[v]", "-map", f"{n}:a" if master is not None else "0:a", "-c:v", "h264_videotoolbox", "-b:v", "6M",
           "-c:a", "aac", "-shortest", str(out_path)]
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--master", help="glavni miks (wav ili bilo što što ffmpeg čita); bez njega --sync clock")
    ap.add_argument("--cameras", nargs="+", required=True, help="video datoteke ili mape (npr. izlaz director.mjs pull)")
    ap.add_argument("--sync", choices=("auto", "audio", "clock"), default="auto",
                    help="audio: korelacija s miksom (studio); clock: sat relaya iz sidecara (stadion, "
                         "kamere daleko jedna od druge); auto: audio ako je dan --master, inače clock")
    ap.add_argument("--out", default=None, help="izlazna mapa (zadano: uz miks / uz prvu kameru, multicam_synced/)")
    ap.add_argument("--render", action="store_true", help="izvezi svaku kameru poravnatu na zajedničku crtu")
    ap.add_argument("--grid", action="store_true", help="mreža svih kamera za provjeru (traži --render)")
    ap.add_argument("--av-offset", action="append", default=[], metavar="IME=MS",
                    help="kamerin vlastiti A/V pomak iz pljeska: + znači slika kasni za svojim zvukom")
    args = ap.parse_args()

    mode = args.sync if args.sync != "auto" else ("audio" if args.master else "clock")
    if mode == "audio" and not args.master:
        sys.exit("❌ --sync audio traži --master.")
    master = Path(args.master) if args.master and mode == "audio" else None
    if args.master and mode == "clock":
        log("ℹ️  --sync clock: miks nema sat relaya pa se ne koristi; zvuk renderâ je zvuk svake kamere.")

    cameras = find_cameras(args.cameras)
    if not cameras:
        sys.exit("❌ Nema video datoteka.")
    out = Path(args.out) if args.out else (master.parent if master else cameras[0][1].parent.parent) / "multicam_synced"
    out.mkdir(parents=True, exist_ok=True)
    av = {k: float(v) for k, v in (x.split("=", 1) for x in args.av_offset)}

    # Sat se računa uvijek kad ga sidecar ima: u clock načinu je to poravnanje,
    # u audio načinu neovisna provjera — dvije metode koje se moraju složiti.
    clocks = {}
    for name, path, meta in cameras:
        fit = clock_fit(meta)
        if fit:
            clocks[name] = fit

    results, failed = {}, []
    if mode == "audio":
        master_dur = float(probe(master)["format"]["duration"])
        log(f"🎚  Miks: {master} ({master_dur:.1f} s)")
        master_fine = bandpass(load_audio(master, FINE_SR), FINE_SR)
        master_coarse = bandpass(load_audio(master, COARSE_SR), COARSE_SR)
        for name, path, meta in cameras:
            log(f"📱 {name}: {path.name}")
            try:
                r = sync_camera(path, master_fine, master_coarse, master_dur)
            except Exception as e:
                log(f"   ❌ {e}")
                failed.append(name)
                continue
            r["method"] = "audio"
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
        # Provjera satom: razlika (audio pomak − sat pomak) mora biti ista za sve kamere.
        both = [n for n in results if n in clocks]
        if len(both) >= 2:
            d = {n: results[n]["offsetSeconds"] - clocks[n][0] for n in both}
            ref = float(np.median(list(d.values())))
            log("⏱  Sat relaya prema zvuku (iste kamere, neovisna metoda):")
            for n in both:
                results[n]["clockVsAudioMs"] = (d[n] - ref) * 1000
                results[n].update(clocks[n][2])
                log(f"   {n}: {results[n]['clockVsAudioMs']:+.1f} ms "
                    f"(RTT min {clocks[n][2]['minRttMs']:.0f} ms, {clocks[n][2]['clockSamplesUsed']} uzoraka)")
    else:
        missing = [n for n, _, _ in cameras if n not in clocks]
        for n in missing:
            log(f"📱 {n}: ❌ sidecar nema blok clock (v2) — ne može se poravnati po satu")
            failed.append(n)
        if not clocks:
            sys.exit("❌ Nijedna kamera nema podatke o satu.")
        t0 = min(a for a, _, _ in clocks.values())
        for name, path, meta in cameras:
            if name not in clocks:
                continue
            a, b, info = clocks[name]
            dur = float(probe(path)["format"]["duration"])
            r = {"file": str(path), "method": "clock", "durationSeconds": dur,
                 "offsetSeconds": float(a - t0), "scale": float(b), "driftPPM": float((b - 1) * 1e6),
                 "serverStartMs": float(a * 1000), "avOffsetMs": av.get(name, 0.0), **info}
            results[name] = r
            unc = math.hypot(info["clockResidualRmsMs"], info["fileZeroUncertaintyMs"] or 0.0)
            flag = "✅" if info["clockSamplesUsed"] >= 4 and unc < 15 else "⚠️ "
            log(f"📱 {name}: {flag} počinje {r['offsetSeconds']:+.3f} s · sat {info['clockDriftPPM']:+.1f} ppm · "
                f"{info['clockSamplesUsed']}/{info['clockSamples']} uzoraka, RTT min {info['minRttMs']:.0f} ms · "
                f"rasipanje uzoraka {unc:.1f} ms")
            if info["clockSamplesUsed"] < 4:
                log("   ⚠️  premalo uzoraka sata kroz snimku — drift nije izmjeren, samo pomak")
        master_dur = max(r["offsetSeconds"] + r["scale"] * r["durationSeconds"] for r in results.values())

    (out / "multicam_sync.json").write_text(json.dumps(
        {"version": 2, "method": mode, "master": str(master) if master else None,
         "masterDurationSeconds": master_dur,
         "model": "t_timeline = offsetSeconds + scale * t_camera - avOffsetMs/1000",
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
