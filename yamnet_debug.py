#!/usr/bin/env python3
"""Debugira YAMNet scoreove na poznatim beep lokacijama."""
import sys, types, os
if sys.version_info >= (3, 13):
    try:
        import pkg_resources
    except ImportError:
        pkg_resources = types.ModuleType('pkg_resources')
        from packaging.version import Version as _pv
        pkg_resources.parse_version = _pv
        sys.modules['pkg_resources'] = pkg_resources

import numpy as np
import soundfile as sf
import tensorflow as tf
import tensorflow_hub as hub
import csv, urllib.request, io

audio_path = sys.argv[1]
info = sf.info(audio_path)
sr = info.samplerate

model = hub.load('https://tfhub.dev/google/yamnet/1')

# Class map
url = "https://raw.githubusercontent.com/tensorflow/models/master/research/audioset/yamnet/yamnet_class_map.csv"
cache = os.path.expanduser("~/.cache/yamnet_class_map.csv")
with open(cache, "r") as f:
    reader = csv.reader(f)
    class_names = [row[2] for row in reader]

# Beep-related class indices
beep_classes = ["Beep, bleep", "Ringtone", "Telephone bell ringing", "Alarm",
                "Buzzer", "Chime", "Ding", "Sine wave", "Vehicle",
                "Truck", "Traffic noise, roadway noise"]
beep_indices = {}
for i, name in enumerate(class_names):
    if name in beep_classes:
        beep_indices[name] = i

print("Beep-related class indices:")
for name, idx in beep_indices.items():
    print(f"  {idx}: {name}")

# Lokacije za testiranje
locations = [
    (81, 87, "WhatsApp beep 01:22"),
    (178, 187, "Kamion 02:59"),
    (259, 264, "WhatsApp beep 04:21"),
    (301, 306, "WhatsApp beep 05:03"),
    (428, 433, "WhatsApp beep 07:10"),
    (449, 454, "WhatsApp beep 07:31"),
    (936, 943, "Beep 15:38"),
    # Kontrolna grupa - cist govor
    (30, 37, "KONTROLA govor 00:30"),
    (100, 107, "KONTROLA govor 01:40"),
    (500, 507, "KONTROLA govor 08:20"),
]

for start_s, end_s, label in locations:
    data, _ = sf.read(audio_path, start=int(start_s*sr), stop=int(end_s*sr),
                       dtype="float32", always_2d=True)
    if data.shape[1] > 1:
        data = np.mean(data, axis=1)
    else:
        data = data[:, 0]

    # Resample to 16kHz
    duration = len(data) / sr
    new_len = int(duration * 16000)
    indices = np.linspace(0, len(data) - 1, new_len)
    data_16k = np.interp(indices, np.arange(len(data)), data).astype(np.float32)

    scores, _, _ = model(data_16k)
    scores = scores.numpy()

    print(f"\n=== {label} ({start_s}s - {end_s}s) === [{scores.shape[0]} patches]")

    # Za svaki patch, pokazi top 5 klasa i beep-related scoreove
    for p in range(scores.shape[0]):
        patch_time = start_s + p * 0.48
        top5 = np.argsort(scores[p])[::-1][:5]

        print(f"  Patch {p} ({patch_time:.1f}s):")
        print(f"    Top 5: ", end="")
        for idx in top5:
            print(f"{class_names[idx]}={scores[p,idx]:.3f}  ", end="")
        print()

        # Beep scoreovi
        beep_scores = []
        for name, idx in beep_indices.items():
            s = scores[p, idx]
            if s > 0.005:  # samo ako barem nesto
                beep_scores.append((name, s))
        if beep_scores:
            beep_scores.sort(key=lambda x: -x[1])
            print(f"    Beep: ", end="")
            for name, s in beep_scores[:5]:
                print(f"{name}={s:.4f}  ", end="")
            print()
