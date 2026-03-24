#!/usr/bin/env python3
"""Mjeri residual metriku na poznatim beep vs govor lokacijama."""
import numpy as np
import soundfile as sf
import sys

audio_path = "/tmp/test_10min.wav"
info = sf.info(audio_path)
sr = info.samplerate

n_fft = 4096
hop_length = 1024
window = np.hanning(n_fft)
freqs = np.fft.rfftfreq(n_fft, d=1.0/sr)
beep_mask = (freqs >= 800) & (freqs <= 3500)
beep_freqs = freqs[beep_mask]

def analyze_region(start_sec, end_sec, label):
    data, _ = sf.read(audio_path, start=int(start_sec*sr), stop=int(end_sec*sr),
                       dtype="float32", always_2d=True)
    data = data[:, 0] if data.shape[1] == 1 else np.mean(data, axis=1)

    num_frames = (len(data) - n_fft) // hop_length + 1
    S = np.zeros((sum(beep_mask), num_frames), dtype=np.float32)

    for i in range(num_frames):
        start = i * hop_length
        frame = data[start:start+n_fft] * window
        spectrum = np.abs(np.fft.rfft(frame)).astype(np.float32)
        S[:, i] = spectrum[beep_mask]

    # Median subtraction (na cijelom regionu)
    median_spec = np.median(S, axis=1, keepdims=True)
    residual = np.maximum(S - median_spec, 0)

    # Za svaki frame: max residual, sharpness, peak freq
    max_res = []
    sharpnesses = []
    peak_freqs_list = []

    for i in range(num_frames):
        col = residual[:, i]
        std = np.std(S[:, i]) + 1e-10
        col_norm = col / std

        mr = np.max(col_norm)
        max_res.append(mr)

        mean_val = np.mean(col_norm)
        if mean_val > 0:
            sharpnesses.append(mr / (mean_val + 1e-10))
        else:
            sharpnesses.append(0)

        peak_freqs_list.append(beep_freqs[np.argmax(col)])

    max_res = np.array(max_res)
    sharpnesses = np.array(sharpnesses)
    peak_freqs_arr = np.array(peak_freqs_list)

    print(f"=== {label} ({start_sec:.0f}s-{end_sec:.0f}s) ===")
    print(f"  Max residual: mean={np.mean(max_res):.1f} p90={np.percentile(max_res,90):.1f} "
          f"p95={np.percentile(max_res,95):.1f} max={np.max(max_res):.1f}")
    print(f"  Sharpness:    mean={np.mean(sharpnesses):.1f} p90={np.percentile(sharpnesses,90):.1f} "
          f"p95={np.percentile(sharpnesses,95):.1f} max={np.max(sharpnesses):.1f}")
    print(f"  Peak freq std: {np.std(peak_freqs_arr):.0f} Hz")

    # Koliko frameova prelazi razne pragove kombinacije
    for res_th in [3, 5, 7, 10]:
        for sharp_th in [3, 5, 7]:
            count = np.sum((max_res > res_th) & (sharpnesses > sharp_th))
            if count > 0:
                print(f"    res>{res_th} & sharp>{sharp_th}: {count}/{num_frames} ({count/num_frames*100:.1f}%)")
    print()

# Beep lokacije (relativno na 10-min test)
beeps = [
    (81, 85, "Beep 01:22"),
    (260, 263, "Beep 04:21"),
    (302, 305, "Beep 05:03"),
    (429, 432, "Beep 07:10"),
    (450, 453, "Beep 07:31"),
]

# Cist govor
speech = [
    (30, 33, "Govor 00:30"),
    (50, 53, "Govor 00:50"),
    (100, 103, "Govor 01:40"),
    (150, 153, "Govor 02:30"),
    (200, 203, "Govor 03:20"),
    (350, 353, "Govor 05:50"),
    (500, 503, "Govor 08:20"),
]

print("--- BEEPOVI ---")
for s, e, l in beeps:
    if e <= 600:
        analyze_region(s, e, l)

print("--- GOVOR ---")
for s, e, l in speech:
    analyze_region(s, e, l)
