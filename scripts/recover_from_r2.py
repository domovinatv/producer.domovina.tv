#!/usr/bin/env python3
"""
recover_from_r2.py — rekonstruira sesiju iz segmenata na Cloudflare R2.

Zašto postoji: aplikacija tijekom snimanja šalje male segmente na R2, ali
istovremeno piše i cijele datoteke lokalno. U normalnom slučaju segmente nikad ne
diraš — lokalni `mic-1.wav` i `camera-proxy.mov` su već cjeloviti.

Ovaj alat je za slučaj kad lokalne datoteke NE postoje: Mac se ugasio, disk je
otkazao, kartica je izgubljena. Tada su R2 segmenti jedina kopija, i bez alata
koji ih zna spojiti cijeli upload tijekom snimanja ne vrijedi ništa.

Namjerno NE ovisi o manifestu: manifest se šalje na R2 tek pri zaustavljanju, pa
ga kod pada aplikacije nema. Sadržaj se otkriva listanjem buketa.

Ovisnosti: samo Python 3 standardna biblioteka + ffmpeg za spajanje.

Upotreba:
  ./scripts/recover_from_r2.py --prefix sessions/2026-07-25-1930-epizoda-42 \\
                               --output ~/Desktop/oporavak

Kredencijali (redom kojim se traže):
  --account-id / R2_ACCOUNT_ID
  --bucket     / R2_BUCKET
  --key-id     / R2_ACCESS_KEY_ID
  secret       / R2_SECRET_ACCESS_KEY, inače iz macOS Keychaina
                 (servis tv.domovina.studio, account = key id)
"""

import argparse
import hashlib
import hmac
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ElementTree
from datetime import datetime, timezone
from pathlib import Path

REGION = "auto"
SERVICE = "s3"
UNRESERVED = frozenset(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
)


# --------------------------------------------------------------------------- #
# SigV4
# --------------------------------------------------------------------------- #

def uri_encode(value: str, encode_slash: bool = True) -> str:
    out = []
    for byte in value.encode("utf-8"):
        char = chr(byte)
        if char in UNRESERVED:
            out.append(char)
        elif char == "/" and not encode_slash:
            out.append(char)
        else:
            out.append("%%%02X" % byte)
    return "".join(out)


def _sign(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret: str, date_stamp: str, region: str = REGION, service: str = SERVICE) -> bytes:
    key = _sign(("AWS4" + secret).encode("utf-8"), date_stamp)
    key = _sign(key, region)
    key = _sign(key, service)
    return _sign(key, "aws4_request")


def signed_request(method, host, path, query, key_id, secret, now=None,
                   region=REGION, service=SERVICE):
    """Returns (url, headers) for a signed request with an empty payload."""
    now = now or datetime.now(timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date_stamp = amz_date[:8]
    payload_hash = hashlib.sha256(b"").hexdigest()

    canonical_uri = "/" + "/".join(
        uri_encode(part) for part in path.lstrip("/").split("/")
    ) if path.strip("/") else "/"

    # Sorting happens on the *encoded* names and values, per the specification.
    canonical_query = ""
    if query:
        pairs = sorted((uri_encode(k), uri_encode(v)) for k, v in query.items())
        canonical_query = "&".join("%s=%s" % pair for pair in pairs)

    headers = {
        "host": host,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    canonical_headers = "".join("%s:%s\n" % (k, headers[k]) for k in sorted(headers))
    signed_headers = ";".join(sorted(headers))

    canonical_request = "\n".join([
        method, canonical_uri, canonical_query,
        canonical_headers, signed_headers, payload_hash,
    ])
    scope = "%s/%s/%s/aws4_request" % (date_stamp, region, service)
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])
    signature = hmac.new(
        signing_key(secret, date_stamp, region, service),
        string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    headers["Authorization"] = (
        "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
        % (key_id, scope, signed_headers, signature)
    )
    url = "https://%s%s" % (host, canonical_uri)
    if canonical_query:
        url += "?" + canonical_query
    return url, headers


# --------------------------------------------------------------------------- #
# R2
# --------------------------------------------------------------------------- #

class R2:
    def __init__(self, account_id, bucket, key_id, secret):
        self.host = "%s.r2.cloudflarestorage.com" % account_id
        self.bucket = bucket
        self.key_id = key_id
        self.secret = secret

    def _open(self, method, path, query):
        url, headers = signed_request(method, self.host, path, query, self.key_id, self.secret)
        request = urllib.request.Request(url, method=method, headers=headers)
        return urllib.request.urlopen(request, timeout=120)

    def list_objects(self, prefix):
        """Yields (key, size) for every object under prefix, following pagination."""
        token = None
        while True:
            query = {"list-type": "2", "prefix": prefix, "max-keys": "1000"}
            if token:
                query["continuation-token"] = token
            with self._open("GET", "/" + self.bucket, query) as response:
                body = response.read()

            root = ElementTree.fromstring(body)
            namespace = {"s3": root.tag.split("}")[0].strip("{")} if "}" in root.tag else {}

            def find(node, name):
                return node.find("s3:" + name, namespace) if namespace else node.find(name)

            def findall(node, name):
                return node.findall("s3:" + name, namespace) if namespace else node.findall(name)

            for item in findall(root, "Contents"):
                key = find(item, "Key").text
                size = int(find(item, "Size").text)
                yield key, size

            truncated = find(root, "IsTruncated")
            if truncated is None or truncated.text != "true":
                return
            next_token = find(root, "NextContinuationToken")
            if next_token is None:
                return
            token = next_token.text

    def download(self, key, destination: Path):
        destination.parent.mkdir(parents=True, exist_ok=True)
        with self._open("GET", "/%s/%s" % (self.bucket, key), {}) as response:
            with open(destination, "wb") as handle:
                shutil.copyfileobj(response, handle)


# --------------------------------------------------------------------------- #
# Reassembly
# --------------------------------------------------------------------------- #

def require_ffmpeg():
    if shutil.which("ffmpeg") is None:
        sys.exit("❌ ffmpeg nije pronađen (brew install ffmpeg)")


def concat_audio(segment_paths, output: Path) -> bool:
    """Joins WAV segments with the concat demuxer — stream copy, no re-encode."""
    if not segment_paths:
        return False
    listing = output.parent / (output.stem + "_concat.txt")
    with open(listing, "w", encoding="utf-8") as handle:
        for path in segment_paths:
            handle.write("file '%s'\n" % str(path).replace("'", "'\\''"))
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-f", "concat", "-safe", "0",
         "-i", str(listing), "-c", "copy", "-y", str(output)],
        capture_output=True, text=True,
    )
    listing.unlink(missing_ok=True)
    if result.returncode != 0:
        print("   ⚠️  ffmpeg: %s" % result.stderr.strip()[:300])
        return False
    return True


def concat_fmp4(init_path, media_paths, output: Path) -> bool:
    """
    Fragmented MP4 reassembles by plain byte concatenation, initialization
    segment first — it carries the moov box the media fragments refer to.
    The result is then remuxed so the container gets a proper index.
    """
    if init_path is None or not media_paths:
        return False
    raw = output.with_suffix(".raw.mp4")
    with open(raw, "wb") as out:
        with open(init_path, "rb") as handle:
            shutil.copyfileobj(handle, out)
        for path in media_paths:
            with open(path, "rb") as handle:
                shutil.copyfileobj(handle, out)

    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(raw), "-c", "copy",
         "-movflags", "+faststart", "-y", str(output)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print("   ⚠️  ffmpeg remux nije uspio: %s" % result.stderr.strip()[:300])
        print("   ℹ️  Sirovi spojeni fMP4 ostavljen na: %s" % raw)
        return False
    raw.unlink(missing_ok=True)
    return True


def sort_key(path: Path):
    """Sorts by the trailing number in the filename, not lexically."""
    digits = "".join(ch for ch in path.stem if ch.isdigit())
    return (int(digits) if digits else -1, path.name)


# --------------------------------------------------------------------------- #

def main():
    parser = argparse.ArgumentParser(description="Rekonstruira sesiju iz R2 segmenata.")
    parser.add_argument("--prefix", required=True,
                        help="npr. sessions/2026-07-25-1930-epizoda-42")
    parser.add_argument("--output", required=True, help="izlazna mapa")
    parser.add_argument("--account-id", default=os.environ.get("R2_ACCOUNT_ID"))
    parser.add_argument("--bucket", default=os.environ.get("R2_BUCKET"))
    parser.add_argument("--key-id", default=os.environ.get("R2_ACCESS_KEY_ID"))
    parser.add_argument("--list-only", action="store_true",
                        help="samo ispiši što je na R2, ne preuzimaj")
    args = parser.parse_args()

    for name, value in [("--account-id", args.account_id),
                        ("--bucket", args.bucket),
                        ("--key-id", args.key_id)]:
        if not value:
            sys.exit("❌ %s je obavezan (ili odgovarajuća env varijabla)" % name)

    secret = os.environ.get("R2_SECRET_ACCESS_KEY")
    if not secret:
        # Same Keychain item the app writes.
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "tv.domovina.studio",
             "-a", args.key_id, "-w"],
            capture_output=True, text=True,
        )
        if result.returncode == 0:
            secret = result.stdout.strip()
    if not secret:
        sys.exit("❌ Nema secret keya: postavi R2_SECRET_ACCESS_KEY ili ga spremi u Keychain preko aplikacije.")

    client = R2(args.account_id, args.bucket, args.key_id, secret)
    output = Path(args.output).expanduser()

    print("🔎 Listam %s/%s …" % (args.bucket, args.prefix))
    try:
        objects = list(client.list_objects(args.prefix.strip("/")))
    except urllib.error.HTTPError as error:
        sys.exit("❌ R2 je vratio HTTP %s: %s" % (error.code, error.read()[:300].decode("utf-8", "replace")))
    except urllib.error.URLError as error:
        sys.exit("❌ Ne mogu se povezati na R2: %s" % error.reason)

    if not objects:
        sys.exit("❌ Ništa nije nađeno pod tim prefiksom.")

    total = sum(size for _, size in objects)
    print("✅ %d objekata, %.1f MB" % (len(objects), total / 1_048_576))

    if args.list_only:
        for key, size in objects:
            print("   %10d  %s" % (size, key))
        return

    require_ffmpeg()
    raw_dir = output / "r2"
    print("⬇️  Preuzimam u %s …" % raw_dir)
    local_paths = []
    for index, (key, size) in enumerate(objects, 1):
        relative = key[len(args.prefix.strip("/")):].lstrip("/")
        destination = raw_dir / relative
        client.download(key, destination)
        local_paths.append((relative, destination))
        print("   [%d/%d] %s" % (index, len(objects), relative))

    print("\n🧩 Spajam …")
    output.mkdir(parents=True, exist_ok=True)

    # Audio: one directory of numbered WAV segments per microphone.
    audio_root = raw_dir / "audio"
    if audio_root.is_dir():
        for track_dir in sorted(p for p in audio_root.iterdir() if p.is_dir()):
            segments = sorted((p for p in track_dir.glob("*.wav")), key=sort_key)
            if not segments:
                continue
            target = output / ("%s.wav" % track_dir.name)
            if concat_audio(segments, target):
                print("   ✅ %s  (%d segmenata)" % (target.name, len(segments)))
            else:
                print("   ❌ %s nije spojen" % target.name)

    # Video: initialization segment first, then media fragments in order.
    video_root = raw_dir / "video" / "segments"
    if video_root.is_dir():
        init_candidates = list(video_root.glob("video-init.mp4"))
        media = sorted((p for p in video_root.glob("*.m4s")), key=sort_key)
        if not media:
            # Older sessions numbered every chunk .mp4, init being index 0.
            everything = sorted(video_root.glob("*.mp4"), key=sort_key)
            if everything and not init_candidates:
                init_candidates, media = [everything[0]], everything[1:]
        init = init_candidates[0] if init_candidates else None
        target = output / "camera-proxy-recovered.mp4"
        if concat_fmp4(init, media, target):
            print("   ✅ %s  (%d fragmenata)" % (target.name, len(media)))
        elif init is None:
            print("   ❌ Nema initialization segmenta — video fragmenti se ne mogu dekodirati.")

    # Masters uploaded after a normal stop need no work.
    masters = raw_dir / "masters"
    if masters.is_dir():
        for path in sorted(masters.iterdir()):
            shutil.copy2(path, output / path.name)
            print("   ✅ %s (master, kopiran)" % path.name)

    manifest = raw_dir / "manifest.json"
    if manifest.exists():
        shutil.copy2(manifest, output / "manifest.json")
        print("   ✅ manifest.json — finalize_session.sh se može pokrenuti nad ovom mapom")
    else:
        print("   ⚠️  Nema manifest.json (sesija nije normalno zaustavljena).")
        print("      Pomaci za lip sync nisu poznati — poravnaj ručno ili korelacijom.")

    print("\n🏁 Oporavljeno u: %s" % output)


if __name__ == "__main__":
    main()
