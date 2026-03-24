#!/usr/bin/env python3
"""Analizira razne metrike na poznatim beep lokacijama vs govor za kalibraciju."""
import sys
import numpy as np
import soundfile as sf

audio_path = sys.argv[1]
info = sf.info(audio_path)
sr = info.samplerate

known_beeps = [
    (81, 85, "Beep 01:22"),
    (260, 262, "Beep 04:21"),
    (302, 304, "Beep 05:03"),
    (429, 431, "Beep 07:10"),
    (450, 452, "Beep 07:31"),
]

speech_samples = [
    (30, 34, "Govor 00:30"),
    (50, 54, "Govor 00:50"),
    (100, 104, "Govor 01:40"),
    (150, 154, "Govor 02:30"),
    (220, 224, "Govor 03:40"),
    (350, 354, "Govor 05:50"),
    (500, 504, "Govor 08:20"),
    (600, 604, "Govor 10:00"),
]

n_fft = 4096
window = np.hanning(n_fft)
hop_length = 1024
freqs = np.fft.rfftfreq(n_fft, d=1.0/sr)
beep_mask = (freqs >= 800) & (freqs <= 4000)
beep_freqs = freqs[beep_mask]

def analyze(start_sec, end_sec, label):
    data, _ = sf.read(audio_path, start=int(start_sec*sr), stop=int(end_sec*sr),
                       dtype="float32", always_2d=True)
    if data.shape[1] > 1:
        data = np.mean(data, axis=1)
    else:
        data = data[:, 0]

    num_frames = (len(data) - n_fft) // hop_length + 1
    tonalities = []
    sharpnesses = []
    top5_ratios = []

    for i in range(num_frames):
        frame = data[i*hop_length:i*hop_length+n_fft] * window
        spectrum = np.abs(np.fft.rfft(frame))
        band = spectrum[beep_mask]

        mean_val = np.mean(band)
        if mean_val > 0:
            # Tonalnost (max/mean)
            tonalities.append(np.max(band) / mean_val)

            # Peak sharpness: peak energy vs energy in surrounding 200 Hz
            peak_idx = np.argmax(band)
            peak_freq = beep_freqs[peak_idx]
            # 200 Hz okolina
            freq_width = 200
            surrounding_mask = (beep_freqs >= peak_freq - freq_width) & (beep_freqs <= peak_freq + freq_width)
            narrow_mask = (beep_freqs >= peak_freq - 30) & (beep_freqs <= peak_freq + 30)

            narrow_energy = np.sum(band[narrow_mask])
            surrounding_energy = np.sum(band[surrounding_mask])
            if surrounding_energy > 0:
                sharpnesses.append(narrow_energy / surrounding_energy)

            # Top 5 bins ratio
            sorted_band = np.sort(band)[::-1]
            top5_energy = np.sum(sorted_band[:5])
            total_energy = np.sum(band)
            if total_energy > 0:
                top5_ratios.append(top5_energy / total_energy)

    t = np.array(tonalities)
    s = np.array(sharpnesses)
    r = np.array(top5_ratios)

    print(f"=== {label} ({start_sec:.0f}s - {end_sec:.0f}s) ===")
    print(f"   Tonalnost:  mean={np.mean(t):.1f}  p90={np.percentile(t,90):.1f}  "
          f"p95={np.percentile(t,95):.1f}  max={np.max(t):.1f}")
    print(f"   Sharpness:  mean={np.mean(s):.3f}  p90={np.percentile(s,90):.3f}  "
          f"p95={np.percentile(s,95):.3f}  max={np.max(s):.3f}")
    print(f"   Top5 ratio: mean={np.mean(r):.3f}  p90={np.percentile(r,90):.3f}  "
          f"p95={np.percentile(r,95):.3f}  max={np.max(r):.3f}")
    print()
    return t, s, r

print("--- POZNATI BEEPOVI ---")
all_beep_t, all_beep_s, all_beep_r = [], [], []
for start, end, label in known_beeps:
    t, s, r = analyze(start, end, label)
    all_beep_t.extend(t)
    all_beep_s.extend(s)
    all_beep_r.extend(r)

print("--- NORMALNI GOVOR ---")
all_speech_t, all_speech_s, all_speech_r = [], [], []
for start, end, label in speech_samples:
    t, s, r = analyze(start, end, label)
    all_speech_t.extend(t)
    all_speech_s.extend(s)
    all_speech_r.extend(r)

print("=== UKUPNA USPOREDBA ===")
bt, bs, br = np.array(all_beep_t), np.array(all_beep_s), np.array(all_beep_r)
st, ss, sr_ = np.array(all_speech_t), np.array(all_speech_s), np.array(all_speech_r)

for name, bv, sv in [("Tonalnost", bt, st), ("Sharpness", bs, ss), ("Top5 ratio", br, sr_)]:
    print(f"\n{name}:")
    print(f"   Beep:  mean={np.mean(bv):.3f}  p75={np.percentile(bv,75):.3f}  "
          f"p90={np.percentile(bv,90):.3f}  p95={np.percentile(bv,95):.3f}")
    print(f"   Govor: mean={np.mean(sv):.3f}  p75={np.percentile(sv,75):.3f}  "
          f"p90={np.percentile(sv,90):.3f}  p95={np.percentile(sv,95):.3f}")
    # Optimalni prag koji maksimizira razliku
    for thresh in [np.percentile(sv, 90), np.percentile(sv, 95), np.percentile(sv, 99)]:
        beep_above = np.sum(bv > thresh) / len(bv) * 100
        speech_above = np.sum(sv > thresh) / len(sv) * 100
        print(f"   Prag {thresh:.3f}: beep={beep_above:.1f}% govor={speech_above:.1f}% "
              f"(omjer: {beep_above/(speech_above+0.1):.1f}x)")
