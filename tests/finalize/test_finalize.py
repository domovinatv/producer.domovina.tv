#!/usr/bin/env python3
"""
Testovi za finalize_session.sh — poravnavanje i ispravak drifta.

Gradi sintetičku sesiju, pokrene skriptu i provjeri da su izlazni tragovi točni
DO UZORKA. Ne treba hardver, ne treba audio-offset-finder (bez --lumix).

Pokriva tri stvari koje su se u razvoju stvarno pokvarile:
  1. prva točka trajektorije drifta ima frameCount 0 — smije li se odbaciti (ne)
  2. dodaje li aresample par ms na kraj svakog dijela (dodaje; reže se na uzorak)
  3. primjenjuje li se izmjereni pomak mikrofon→slika, a ne samo host clock
"""

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "finalize_session.sh"
NOM = 48000.0
ANCHOR = 1_000_000_000_000
SYNC_MS = 90.0
DURATION = 200          # seconds of synthetic audio

FAILURES = []


def expect(condition, message):
    print(("✅ " if condition else "❌ ") + message)
    if not condition:
        FAILURES.append(message)


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, **kwargs)


def frame_count(path):
    out = run(["ffprobe", "-v", "error", "-select_streams", "a:0",
               "-show_entries", "stream=duration_ts", "-of", "csv=p=0", str(path)]).stdout
    return int(out.strip())


def drift_points(start_ppm, end_ppm, nonlinear):
    """(hostNanos, cumulative frames) every 30 s. First point carries 0 frames."""
    points, frames = [], 0.0
    steps = DURATION // 30
    for i in range(steps + 1):
        if i > 0:
            frac = (i - 1) / float(max(1, steps - 1))
            if nonlinear:
                ppm = end_ppm + (start_ppm - end_ppm) * math.exp(-4.0 * frac)
            else:
                ppm = start_ppm + (end_ppm - start_ppm) * frac
            frames += 30.0 * NOM * (1 + ppm / 1e6)
        points.append({"hostNanos": ANCHOR + int(i * 30e9), "frameCount": int(round(frames))})
    return points


def build_session(root: Path):
    (root / "audio").mkdir(parents=True)
    (root / "video").mkdir(parents=True)

    expression = ("0.4*sin(2*PI*(200+120*sin(2*PI*t/17))*t)"
                  r"*if(lt(mod(t\,1.31)\,0.8)\,1\,0.05)")
    for name in ("mic-1", "mic-2"):
        run(["ffmpeg", "-v", "error", "-f", "lavfi",
             "-i", f"aevalsrc={expression}:d={DURATION}:s=48000",
             "-ac", "1", "-c:a", "pcm_s24le", "-y", str(root / "audio" / f"{name}.wav")])
    run(["ffmpeg", "-v", "error", "-f", "lavfi",
         "-i", f"testsrc2=size=160x90:rate=30:duration={DURATION}",
         "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
         "-y", str(root / "video" / "camera-proxy.mov")])

    # mic-1: strongly nonlinear so the piecewise branch runs.
    # mic-2: steady, so the single-ratio branch runs. Both in one session.
    nonlinear = drift_points(500, 40, True)
    linear = drift_points(10, 10, False)
    total_s = (nonlinear[-1]["hostNanos"] - nonlinear[0]["hostNanos"]) / 1e9

    manifest = {
        "version": 1, "sessionID": "test-session", "title": "Test",
        "createdAt": "2026-07-25T21:00:00Z",
        "startedAtHostNanos": ANCHOR,
        "stoppedAtHostNanos": ANCHOR + int(DURATION * 1e9),
        "machine": {"hostName": "t", "osVersion": "t", "appVersion": "t"},
        "tracks": [
            {"id": "camera-proxy", "kind": "cameraProxyVideo", "label": "proxy",
             "deviceName": "Elgato", "relativePath": "video/camera-proxy.mov",
             "width": 160, "height": 90, "nominalFrameRate": 30,
             "firstSampleHostNanos": ANCHOR, "segments": [], "driftSamples": []},
            {"id": "mic-1", "kind": "microphone", "label": "A", "deviceName": "d",
             "relativePath": "audio/mic-1.wav", "sampleRate": 48000,
             "channelCount": 1, "bitDepth": 24,
             "firstSampleHostNanos": ANCHOR + 250_000_000,
             "measuredSampleRate": nonlinear[-1]["frameCount"] / total_s,
             "driftSamples": nonlinear, "segments": []},
            {"id": "mic-2", "kind": "microphone", "label": "B", "deviceName": "d",
             "relativePath": "audio/mic-2.wav", "sampleRate": 48000,
             "channelCount": 1, "bitDepth": 24,
             "firstSampleHostNanos": ANCHOR - 120_000_000,
             "measuredSampleRate": linear[-1]["frameCount"] / total_s,
             "driftSamples": linear, "segments": []},
        ],
        "events": [],
        "syncMeasurements": [
            {"hostNanos": ANCHOR + i * 5_000_000_000,
             "offsetMilliseconds": SYNC_MS + (0.5 if i % 2 else -0.5),
             "confidence": 0.9, "clockOffsetMilliseconds": 2.0}
            for i in range(30)
        ],
    }
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    return manifest


def expected_frames(track, source_frames):
    """Reimplements the script's arithmetic independently."""
    points = sorted((p["hostNanos"], p["frameCount"]) for p in track["driftSamples"])
    t0, n0 = points[0]
    total_s = (points[-1][0] - t0) / 1e9
    rate_global = (points[-1][1] - n0) / total_s
    worst_ms = max(
        abs(f - (n0 + rate_global * ((h - t0) / 1e9))) / NOM * 1000 for h, f in points
    )
    measured = track["measuredSampleRate"]

    if worst_ms > 8.0:
        count = max(2, min(len(points) - 1, int(round(total_s / 600.0))))
        step = (len(points) - 1) / float(count)
        edges = [points[int(round(i * step))] for i in range(count)] + [points[-1]]
        total, cursor = 0, 0
        for i in range(len(edges) - 1):
            (ta, na), (tb, nb) = edges[i], edges[i + 1]
            rate = float("%.4f" % ((nb - na) / ((tb - ta) / 1e9)))
            start = min(round(float("%.6f" % ((na - n0) / NOM)) * NOM), source_frames)
            end = min(round(float("%.6f" % ((nb - n0) / NOM)) * NOM), source_frames)
            span = max(0, end - start)
            if span:
                total += round(span * NOM / rate)
                cursor = end
        if cursor < source_frames:
            total += round((source_frames - cursor) * NOM / measured)
        return total, "piecewise", worst_ms
    return round(source_frames * NOM / measured), "single", worst_ms


with tempfile.TemporaryDirectory() as temporary:
    session = Path(temporary) / "session"
    manifest = build_session(session)

    result = run(["bash", str(SCRIPT), "--session", str(session)])
    expect(result.returncode == 0, "finalize_session.sh se izvršio")
    if result.returncode != 0:
        print(result.stdout[-2500:])
        print(result.stderr[-1500:])
        sys.exit(1)

    output = result.stdout
    expect("+90.0 ms" in output or "+90." in output,
           "izmjereni pomak mikrofon→slika je primijenjen (medijan ~90 ms)")
    expect("drift po dijelovima" in output, "piecewise putanja se aktivirala za mic-1")

    anchor = manifest["tracks"][0]["firstSampleHostNanos"]
    for track in manifest["tracks"]:
        if track.get("kind") != "microphone":
            continue
        tid = track["id"]
        source_frames = frame_count(session / track["relativePath"])
        drift_frames, mode, worst_ms = expected_frames(track, source_frames)

        offset = (track["firstSampleHostNanos"] - anchor) / 1e9 + SYNC_MS / 1000.0
        if offset >= 0.0005:
            total = drift_frames + round(round(offset * 1000) / 1000.0 * NOM)
        elif offset <= -0.0005:
            total = drift_frames - round(abs(offset) * NOM)
        else:
            total = drift_frames

        actual = frame_count(session / "final" / "aligned" / f"{tid}_aligned.wav")
        delta_ms = abs(actual - total) / NOM * 1000
        expect(delta_ms < 1.0,
               f"{tid} [{mode}, nelinearnost {worst_ms:.1f} ms]: "
               f"{actual} uzoraka, očekivano {total} (razlika {delta_ms:.2f} ms)")

    # The very first trajectory point carries frameCount 0. Treating that as
    # falsy drops it, which shifts the baseline and silently rescales every rate.
    points = manifest["tracks"][1]["driftSamples"]
    expect(points[0]["frameCount"] == 0, "test podaci sadrže frameCount 0 na prvoj točki")
    reader = run(["bash", "-c",
                  f"sed -n '/^read_manifest() {{/,/^}}/p' {SCRIPT} > /tmp/_r.sh && "
                  f"printf 'MANIFEST=\"$1\"\\nread_manifest\\n' >> /tmp/_r.sh && "
                  f"bash /tmp/_r.sh {session / 'manifest.json'}"])
    drift_line = [l for l in reader.stdout.splitlines() if l.startswith("MICDRIFT\tmic-1")]
    expect(bool(drift_line) and drift_line[0].split("\t")[-1] == str(len(points)),
           f"nijedna točka trajektorije nije odbačena ({len(points)} točaka)")

    # Format must survive the split-and-concat.
    info = run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
                "stream=codec_name,sample_rate,channels", "-of", "csv=p=0",
                str(session / "final" / "aligned" / "mic-1_aligned.wav")]).stdout.strip()
    expect(info == "pcm_s24le,48000,1", f"format očuvan nakon spajanja dijelova ({info})")

    expect((session / "final" / "mix.wav").exists(), "miks je napravljen")

print("")
if FAILURES:
    print("🛑 %d neuspješnih." % len(FAILURES))
    sys.exit(1)
print("🏁 Svi finalize testovi prošli.")
