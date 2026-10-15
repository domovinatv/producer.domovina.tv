#!/usr/bin/env python3
"""
Testovi za recover_from_r2.py — potpisivanje i spajanje segmenata.

Ne dira mrežu. Potpisivanje se provjerava protiv AWS-ovih objavljenih S3 SigV4
test vektora (isti kojima je pokriven i Swift potpisnik), a spajanje na stvarnim
fMP4 i WAV segmentima koje generira ffmpeg.
"""

import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import importlib.util

spec = importlib.util.spec_from_file_location(
    "recover", Path(__file__).resolve().parents[2] / "scripts" / "recover_from_r2.py"
)
recover = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recover)

FAILURES = []


def expect(condition, message):
    print(("✅ " if condition else "❌ ") + message)
    if not condition:
        FAILURES.append(message)


# --------------------------------------------------------------------------- #
# SigV4 — the secret in AWS's S3 examples uses a slash, not a plus.
# --------------------------------------------------------------------------- #

KEY_ID = "AKIAIOSFODNN7EXAMPLE"
SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
WHEN = datetime(2013, 5, 24, 0, 0, 0, tzinfo=timezone.utc)


def signature_for(path, query):
    _, headers = recover.signed_request(
        "GET", "examplebucket.s3.amazonaws.com", path, query,
        KEY_ID, SECRET, now=WHEN, region="us-east-1", service="s3",
    )
    return headers["Authorization"].split("Signature=")[1]


# GET Bucket Lifecycle — a valueless query parameter.
expect(signature_for("/", {"lifecycle": ""})
       == "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543",
       "SigV4: GET Bucket Lifecycle (?lifecycle=)")

# List Objects — two parameters that must be sorted by encoded name.
expect(signature_for("/", {"prefix": "J", "max-keys": "2"})
       == "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
       "SigV4: List Objects (?prefix=J&max-keys=2)")

expect(recover.uri_encode("a b") == "a%20b", "uri_encode: razmak")
expect(recover.uri_encode("audio/mic-1.wav", encode_slash=False) == "audio/mic-1.wav",
       "uri_encode: kosa crta ostaje u putanji")
expect(recover.uri_encode("audio/mic-1.wav") == "audio%2Fmic-1.wav",
       "uri_encode: kosa crta se enkodira u query")
expect(recover.uri_encode("č") == "%C4%8D", "uri_encode: dijakritika")

# Segment ordering must be numeric, not lexical: 00010 sorts after 00009.
names = ["video-00010.m4s", "video-00002.m4s", "video-00001.m4s", "video-00009.m4s"]
ordered = [p.name for p in sorted((Path(n) for n in names), key=recover.sort_key)]
expect(ordered == ["video-00001.m4s", "video-00002.m4s", "video-00009.m4s", "video-00010.m4s"],
       "sortiranje segmenata je numeričko: %s" % ordered)


# --------------------------------------------------------------------------- #
# Reassembly on real media
# --------------------------------------------------------------------------- #

def run(command):
    return subprocess.run(command, capture_output=True, text=True)


def duration_of(path):
    result = run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                  "-of", "csv=p=0", str(path)])
    try:
        return float(result.stdout.strip())
    except ValueError:
        return -1.0


if run(["ffmpeg", "-version"]).returncode != 0:
    expect(False, "ffmpeg dostupan")
else:
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)

        # --- audio: six 5 s WAV segments, joined must be 30 s ---
        audio_dir = work / "audio" / "mic-1"
        audio_dir.mkdir(parents=True)
        for index in range(6):
            run(["ffmpeg", "-v", "error", "-f", "lavfi",
                 "-i", "sine=frequency=%d:duration=5:sample_rate=48000" % (220 + index * 40),
                 "-c:a", "pcm_s24le", "-y", str(audio_dir / ("mic-1-%05d.wav" % index))])
        segments = sorted(audio_dir.glob("*.wav"), key=recover.sort_key)
        joined_audio = work / "mic-1.wav"
        ok = recover.concat_audio(segments, joined_audio)
        expect(ok, "audio: 6 segmenata spojeno")
        if ok:
            duration = duration_of(joined_audio)
            expect(abs(duration - 30.0) < 0.05,
                   "audio: trajanje %.3f s (očekivano 30.000)" % duration)

        # --- video: real fMP4 init + media fragments, exactly the shape
        #     AVAssetWriter's HLS profile produces ---
        source = work / "source.mp4"
        run(["ffmpeg", "-v", "error", "-f", "lavfi",
             "-i", "testsrc=size=320x180:rate=30:duration=24",
             "-c:v", "libx264", "-preset", "ultrafast", "-g", "30",
             "-pix_fmt", "yuv420p", "-y", str(source)])
        video_dir = work / "video" / "segments"
        video_dir.mkdir(parents=True)
        run(["ffmpeg", "-v", "error", "-i", str(source), "-c", "copy",
             "-f", "hls", "-hls_time", "6", "-hls_segment_type", "fmp4",
             "-hls_fmp4_init_filename", "video-init.mp4",
             "-hls_segment_filename", str(video_dir / "video-%05d.m4s"),
             "-y", str(video_dir / "index.m3u8")])

        init = video_dir / "video-init.mp4"
        media = sorted(video_dir.glob("*.m4s"), key=recover.sort_key)
        expect(init.exists() and len(media) >= 3,
               "video: generirano %d fragmenata + init" % len(media))

        recovered = work / "camera-proxy-recovered.mp4"
        ok = recover.concat_fmp4(init, media, recovered)
        expect(ok, "video: fMP4 fragmenti spojeni i remuxani")
        if ok:
            duration = duration_of(recovered)
            expect(abs(duration - 24.0) < 0.5,
                   "video: trajanje %.3f s (očekivano ~24)" % duration)
            streams = run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                           "-show_entries", "stream=codec_name,width,height",
                           "-of", "csv=p=0", str(recovered)]).stdout.strip()
            expect(streams.startswith("h264,320,180"),
                   "video: dekodira se ispravno (%s)" % streams)

        # --- the failure that matters: media fragments without the init segment ---
        expect(not recover.concat_fmp4(None, media, work / "no_init.mp4"),
               "video: bez init segmenta spajanje ispravno odbija")

print("")
if FAILURES:
    print("🛑 %d neuspješnih." % len(FAILURES))
    sys.exit(1)
print("🏁 Svi recovery testovi prošli.")
