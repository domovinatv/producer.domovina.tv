#!/usr/bin/env python3
"""
AI poboljšavanje kvalitete glasa pomoću resemble-enhance modela.
Procesira velike fajlove u segmentima na disk da izbjegne OOM.
"""
import sys
import os
import gc
import tempfile
import glob

os.environ["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"

import torch
import torchaudio
from resemble_enhance.enhancer.inference import enhance


SEGMENT_SECONDS = 60   # 60s po segmentu — dovoljno malo za memoriju
OVERLAP_SECONDS = 2    # 2s preklapanje


def main():
    if len(sys.argv) < 3:
        print("Korištenje: python enhance_audio.py <input.wav> <output.wav> [lambd]")
        print("  lambd: Balans original/AI (0.0-1.0, default 0.5)")
        sys.exit(1)

    input_path = sys.argv[1]
    output_path = sys.argv[2]
    lambd = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5

    if not os.path.exists(input_path):
        print(f"Greška: Ulazna datoteka ne postoji: {input_path}")
        sys.exit(1)

    # CPU je sigurniji za velike fajlove — MPS OOM s weight_norm fallbackom
    device = "cpu"
    print(f"Akceleracija: {device.upper()} (sigurni mod za velike fajlove)")

    info = torchaudio.info(input_path)
    sr = info.sample_rate
    total_frames = info.num_frames
    segment_frames = SEGMENT_SECONDS * sr
    overlap_frames = OVERLAP_SECONDS * sr
    hop_frames = segment_frames - overlap_frames

    total_segments = max(1, (total_frames - overlap_frames + hop_frames - 1) // hop_frames)
    print(f"Audio: {total_frames/sr:.0f}s @ {sr}Hz, {info.num_channels}ch")
    print(f"Segmenti: {total_segments} x {SEGMENT_SECONDS}s")

    # Temp direktorij za segmente
    tmpdir = tempfile.mkdtemp(prefix="enhance_")
    segment_files = []
    new_sr = None

    try:
        for i in range(total_segments):
            start = i * hop_frames
            num_frames = min(segment_frames, total_frames - start)

            print(f"\n[{i+1}/{total_segments}] {start/sr:.0f}s - {(start+num_frames)/sr:.0f}s ", end="", flush=True)

            # Učitaj samo ovaj segment s diska
            dwav, seg_sr = torchaudio.load(input_path, frame_offset=start, num_frames=num_frames)
            dwav = dwav.mean(0)  # Mono 1D

            chunk_enhanced, new_sr = enhance(
                dwav, seg_sr, device,
                nfe=64, solver="midpoint", lambd=lambd, tau=0.5,
            )

            # Spremi segment na disk odmah
            seg_path = os.path.join(tmpdir, f"seg_{i:04d}.wav")
            out = chunk_enhanced.unsqueeze(0).cpu() if chunk_enhanced.dim() == 1 else chunk_enhanced.cpu()
            torchaudio.save(seg_path, out, new_sr)
            segment_files.append(seg_path)

            # Oslobodi memoriju
            del dwav, chunk_enhanced, out
            gc.collect()

            print("OK", flush=True)

        # Spoji segmente pomoću torchaudio (trim overlap)
        print(f"\nSpajam {len(segment_files)} segmenata...")
        overlap_enhanced = int(OVERLAP_SECONDS * new_sr)
        half_overlap = overlap_enhanced // 2

        pieces = []
        for i, seg_path in enumerate(segment_files):
            seg, _ = torchaudio.load(seg_path)
            seg = seg[0]  # 1D

            if len(segment_files) == 1:
                pieces.append(seg)
            elif i == 0:
                pieces.append(seg[:-half_overlap])
            elif i == len(segment_files) - 1:
                pieces.append(seg[half_overlap:])
            else:
                pieces.append(seg[half_overlap:-half_overlap])

            del seg
            gc.collect()

        result = torch.cat(pieces).unsqueeze(0)
        torchaudio.save(output_path, result, new_sr)
        print(f"\nSpremljeno: {output_path} ({result.shape[-1]/new_sr:.0f}s @ {new_sr}Hz)")

    finally:
        # Očisti temp fajlove
        for f in glob.glob(os.path.join(tmpdir, "*.wav")):
            os.remove(f)
        os.rmdir(tmpdir)


if __name__ == "__main__":
    main()
