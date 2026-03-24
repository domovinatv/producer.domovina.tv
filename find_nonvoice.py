#!/usr/bin/env python3
"""
Podcast QA - pronalazi WhatsApp beepove i pozadinske smetnje u audio datoteci.

SPEKTRALNO ODUZIMANJE S MEDIAN FILTEROM:
  1. STFT -> spektrogram
  2. Za svaki frekv. bin, median u 10s prozoru = "normalni govor"
  3. Residual = trenutni frame - median = ono sto je DODANO povrh govora
  4. U rezidualima trazi tonalne vrske (beepovi) i bas surge (kamioni)

OPTIMIZIRANO za velike datoteke (1GB+) - procesira u komadima.

Korištenje:
    python find_nonvoice.py <putanja_do_wav>
    python find_nonvoice.py <putanja_do_wav> --verbose --log analiza.log
    python find_nonvoice.py <putanja_do_wav> --residual-threshold 3.0
"""

import sys
import os
import argparse
import resource
import subprocess
import datetime
import numpy as np
import soundfile as sf
import gc


class Logger:
    def __init__(self, log_path=None):
        self.log_file = None
        if log_path:
            self.log_file = open(log_path, "w", encoding="utf-8")
            self.log_file.write(
                f"=== Podcast QA Analiza (Spectral Subtraction) "
                f"- {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} ===\n\n"
            )

    def print(self, msg="", end="\n"):
        print(msg, end=end, flush=True)
        if self.log_file:
            self.log_file.write(msg + end)
            self.log_file.flush()

    def close(self):
        if self.log_file:
            self.log_file.close()


def format_time_short(seconds):
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    if h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def get_memory_mb():
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return usage.ru_maxrss / (1024 * 1024)


def detect_in_chunk(data, sr, chunk_start_sec, residual_threshold, verbose, log):
    """
    Spektralno oduzimanje + detekcija anomalija.
    """
    anomalies = []

    n_fft = 4096
    hop_length = 1024
    window = np.hanning(n_fft)

    num_frames = (len(data) - n_fft) // hop_length + 1
    if num_frames < 20:
        return anomalies

    freqs = np.fft.rfftfreq(n_fft, d=1.0 / sr)
    frame_times = chunk_start_sec + np.arange(num_frames) * hop_length / sr

    # Puni STFT (treba nam za median po frekvencijama)
    S = np.zeros((n_fft // 2 + 1, num_frames), dtype=np.float32)
    for i in range(num_frames):
        start = i * hop_length
        frame = data[start : start + n_fft] * window
        S[:, i] = np.abs(np.fft.rfft(frame)).astype(np.float32)

    # ============================================================
    # SPEKTRALNO ODUZIMANJE - median filter po vremenu za svaki bin
    # ============================================================

    # Median prozor: 10 sekundi = N frameova
    median_window = int(10.0 * sr / hop_length)
    if median_window % 2 == 0:
        median_window += 1
    median_window = min(median_window, num_frames)

    # Izračunaj pokretni median za svaki frekv. bin
    # Ovo je "očekivani" spektar (govor + stalna pozadina)
    # Koristimo efikasnu implementaciju s kliznim prozorom
    half_w = median_window // 2

    # Residual = S - median(S) -> ono što je DODANO povrh normalnog
    residual = np.zeros_like(S)
    for i in range(num_frames):
        w_start = max(0, i - half_w)
        w_end = min(num_frames, i + half_w + 1)
        median_spectrum = np.median(S[:, w_start:w_end], axis=1)
        residual[:, i] = np.maximum(S[:, i] - median_spectrum, 0)

    # Normaliziraj residual po binu (z-score naspram mediana)
    # Ovo daje "koliko standardnih devijacija je ovaj frame iznad normalnog"
    residual_norm = np.zeros_like(residual)
    for i in range(num_frames):
        w_start = max(0, i - half_w)
        w_end = min(num_frames, i + half_w + 1)
        local_std = np.std(S[:, w_start:w_end], axis=1) + 1e-10
        residual_norm[:, i] = residual[:, i] / local_std

    # ============================================================
    # 1. BEEP DETEKCIJA - tonalni vrh u residualu (800-3500 Hz)
    # ============================================================

    beep_mask = (freqs >= 800) & (freqs <= 3500)
    beep_residual = residual_norm[beep_mask, :]
    beep_freqs = freqs[beep_mask]

    # Za svaki frame, nađi max residual i provjeri je li "šiljat" (tonalni)
    beep_detected = np.zeros(num_frames, dtype=bool)
    beep_peak_freq = np.zeros(num_frames)
    beep_score = np.zeros(num_frames)

    for i in range(num_frames):
        col = beep_residual[:, i]
        max_val = np.max(col)

        if max_val < residual_threshold:
            continue

        peak_idx = np.argmax(col)

        # Provjera "šiljatosti": je li energija koncentrirana?
        # Gledamo omjer max vs mean u bandu
        mean_val = np.mean(col)
        if mean_val > 0:
            sharpness = max_val / (mean_val + 1e-10)
        else:
            sharpness = 0

        # Beep: šiljat residual (sharpness > 4) = energija dodana u uskom pojasu
        # Govor: širok residual (sharpness < 3) = energija mijenja se široko
        if sharpness > 3.5:
            beep_detected[i] = True
            beep_peak_freq[i] = beep_freqs[peak_idx]
            beep_score[i] = min(1.0, max_val / (residual_threshold * 3))

    # Grupiraj bliske beep frameove
    min_frames = max(3, int(0.12 * sr / hop_length))
    segments = _group_frames(beep_detected, frame_times, beep_peak_freq, beep_score,
                              min_frames, max_gap=3)

    for seg_start, seg_end, dom_freq, freq_std, avg_score, count in segments:
        anomalies.append((
            seg_start, seg_end, "BEEP",
            avg_score,
            f"~{dom_freq:.0f} Hz (std={freq_std:.0f}, res_score={avg_score:.2f}, {count}fr)"
        ))

    # ============================================================
    # 2. RUMBLE DETEKCIJA - bas surge u residualu (<300 Hz)
    # ============================================================

    low_mask = (freqs >= 30) & (freqs <= 300)
    low_residual = residual_norm[low_mask, :]

    # Prosječni residual u bas pojasu
    low_avg_residual = np.mean(low_residual, axis=0)

    rumble_active = low_avg_residual > (residual_threshold * 0.7)

    # Grupiraj
    in_seg = False
    seg_start_t = 0
    for i in range(num_frames):
        if rumble_active[i] and not in_seg:
            seg_start_t = frame_times[i]
            in_seg = True
        elif not rumble_active[i] and in_seg:
            seg_end_t = frame_times[i]
            if seg_end_t - seg_start_t >= 0.5:
                sf_idx = max(0, int((seg_start_t - chunk_start_sec) * sr / hop_length))
                ef_idx = min(num_frames, int((seg_end_t - chunk_start_sec) * sr / hop_length))
                avg_r = np.mean(low_avg_residual[sf_idx:ef_idx])
                anomalies.append((
                    seg_start_t, seg_end_t, "RUMBLE",
                    min(1.0, avg_r / (residual_threshold * 2)),
                    f"bas residual={avg_r:.1f}x"
                ))
            in_seg = False

    if in_seg:
        seg_end_t = frame_times[-1]
        if seg_end_t - seg_start_t >= 0.5:
            avg_r = np.mean(low_avg_residual[-10:])
            anomalies.append((
                seg_start_t, seg_end_t, "RUMBLE",
                min(1.0, avg_r / (residual_threshold * 2)),
                f"bas residual={avg_r:.1f}x"
            ))

    return anomalies


def _group_frames(detected, frame_times, peak_freqs, scores, min_frames, max_gap=3):
    """Grupira detektirane frameove u segmente, dopuštajući kratke gapove."""
    segments = []
    in_seg = False
    seg_start_idx = 0
    seg_count = 0
    gap = 0

    for i in range(len(detected)):
        if detected[i]:
            if not in_seg:
                seg_start_idx = i
                seg_count = 1
                in_seg = True
                gap = 0
            else:
                seg_count += 1
                gap = 0
        else:
            if in_seg:
                gap += 1
                if gap > max_gap:
                    end_idx = i - gap
                    if seg_count >= min_frames:
                        seg = _make_segment(seg_start_idx, end_idx, frame_times, peak_freqs, scores, detected, seg_count)
                        segments.append(seg)
                    in_seg = False
                    seg_count = 0
                    gap = 0

    if in_seg and seg_count >= min_frames:
        end_idx = len(detected) - 1
        seg = _make_segment(seg_start_idx, end_idx, frame_times, peak_freqs, scores, detected, seg_count)
        segments.append(seg)

    return segments


def _make_segment(start_idx, end_idx, frame_times, peak_freqs, scores, detected, count):
    seg_start = frame_times[start_idx]
    seg_end = frame_times[min(end_idx, len(frame_times) - 1)]

    mask = detected[start_idx:end_idx + 1]
    seg_freqs = peak_freqs[start_idx:end_idx + 1][mask]
    seg_scores = scores[start_idx:end_idx + 1][mask]

    dom_freq = np.median(seg_freqs) if len(seg_freqs) > 0 else 0
    freq_std = np.std(seg_freqs) if len(seg_freqs) > 0 else 999
    avg_score = np.mean(seg_scores) if len(seg_scores) > 0 else 0

    return (seg_start, seg_end, dom_freq, freq_std, avg_score, count)


def find_nonvoice_sounds(audio_path, residual_threshold=3.0, chunk_duration=60,
                          verbose=False, log_path=None):
    log = Logger(log_path)

    log.print(f"Datoteka: {audio_path}")
    if not os.path.exists(audio_path):
        log.print(f"GRESKA: Datoteka ne postoji: {audio_path}")
        log.close()
        return

    file_size_mb = os.path.getsize(audio_path) / (1024 * 1024)
    log.print(f"Velicina: {file_size_mb:.0f} MB")
    log.print(f"Residual threshold: {residual_threshold} (std devijacija iznad mediana)")

    if verbose:
        log.print(f"RAM: {get_memory_mb():.0f} MB")

    log.print(f"\nCitam metapodatke...")
    try:
        info = sf.info(audio_path)
        sample_rate = info.samplerate
        total_frames = info.frames
        total_duration = info.duration
    except Exception as e:
        log.print(f"GRESKA: {e}")
        log.close()
        return

    log.print(f"Trajanje: {format_time_short(total_duration)} ({total_duration:.1f}s)")
    log.print(f"Sample rate: {sample_rate} Hz, Kanali: {info.channels}")

    chunk_frames = int(chunk_duration * sample_rate)
    # Veci overlap jer median filter treba kontekst
    overlap_frames = int(5.0 * sample_rate)
    total_chunks = int(np.ceil(total_frames / chunk_frames))

    log.print(f"\nSpektralno oduzimanje u {total_chunks} komada po {chunk_duration}s...")
    log.print(f"Princip: median(10s) = govor, residual = dodani zvukovi (beepovi)\n")

    all_anomalies = []

    for chunk_idx in range(total_chunks):
        frame_offset = chunk_idx * chunk_frames
        if chunk_idx > 0:
            frame_offset = max(0, frame_offset - overlap_frames)

        num_frames_to_read = min(chunk_frames + overlap_frames, total_frames - frame_offset)
        if num_frames_to_read <= 0:
            break

        chunk_start_sec = frame_offset / sample_rate
        chunk_end_sec = chunk_start_sec + num_frames_to_read / sample_rate
        progress = (chunk_idx + 1) / total_chunks * 100

        log.print(
            f"   [{chunk_idx+1}/{total_chunks}] "
            f"{format_time_short(chunk_start_sec)} - {format_time_short(chunk_end_sec)} "
            f"({progress:.0f}%)",
            end="",
        )

        try:
            data, _ = sf.read(
                audio_path, start=frame_offset,
                stop=frame_offset + num_frames_to_read,
                dtype="float32", always_2d=True,
            )
            if data.shape[1] > 1:
                data = np.mean(data, axis=1)
            else:
                data = data[:, 0]
        except Exception as e:
            log.print(f" GRESKA: {e}")
            continue

        chunk_anomalies = detect_in_chunk(
            data, sample_rate, chunk_start_sec, residual_threshold, verbose, log
        )
        del data
        gc.collect()

        n_beep = sum(1 for a in chunk_anomalies if "BEEP" in a[2])
        n_rumble = sum(1 for a in chunk_anomalies if "RUMBLE" in a[2])

        if n_beep or n_rumble:
            parts = []
            if n_beep: parts.append(f"{n_beep} beep")
            if n_rumble: parts.append(f"{n_rumble} rumble")
            log.print(f" -> {', '.join(parts)}")
        else:
            log.print(f" ok")

        all_anomalies.extend(chunk_anomalies)

        if verbose and (chunk_idx % 20 == 0):
            log.print(f"      RAM: {get_memory_mb():.0f} MB")

    # Deduplikacija
    if all_anomalies:
        all_anomalies.sort(key=lambda x: x[0])
        deduped = [all_anomalies[0]]
        for a in all_anomalies[1:]:
            prev = deduped[-1]
            if a[2] == prev[2] and a[0] - prev[1] < 2.0:
                deduped[-1] = (prev[0], max(prev[1], a[1]), prev[2],
                               max(prev[3], a[3]), prev[4])
            elif abs(a[0] - prev[0]) < 1.0 and a[2] == prev[2]:
                if a[3] > prev[3]:
                    deduped[-1] = a
            else:
                deduped.append(a)
        all_anomalies = deduped

    # Rezultati
    log.print()
    if not all_anomalies:
        log.print("REZULTAT: Nisu pronadjene anomalije!")
        log.print("   Pokusaj smanjiti --residual-threshold (default: 3.0)")
        log.close()
        return

    log.print(f"REZULTAT: Pronadjeno {len(all_anomalies)} anomalija!")
    by_type = {}
    for a in all_anomalies:
        by_type.setdefault(a[2], []).append(a)
    for atype, items in sorted(by_type.items()):
        log.print(f"   {atype}: {len(items)}")

    log.print()
    log.print("=" * 100)
    log.print(f"{'#':<5} {'Vrijeme':<18} {'Traj.':<8} {'Tip':<10} {'Sig.':<8} {'Detalj'}")
    log.print("-" * 100)

    for i, (start, end, atype, confidence, detail) in enumerate(all_anomalies, 1):
        dur = end - start
        time_str = f"{format_time_short(start)} - {format_time_short(end)}"
        log.print(f"{i:<5} {time_str:<18} {dur:.1f}s{'':<4} {atype:<10} {confidence*100:.0f}%{'':<4} {detail}")

    log.print("-" * 100)

    # Validacija
    known_issues = [
        (82, 86, "WhatsApp beep 01:22-01:26"),
        (179, 186, "Kamion 02:59-03:06"),
        (261, 263, "WhatsApp beep 04:21"),
        (303, 305, "WhatsApp beep 05:03"),
        (430, 432, "WhatsApp beep 07:10"),
        (451, 453, "WhatsApp beep 07:31"),
        (938, 941, "Beep 15:38-15:41"),
    ]
    log.print()
    log.print("VALIDACIJA poznatih problema:")
    hits = 0
    for ks, ke, desc in known_issues:
        found = False
        for start, end, atype, conf, detail in all_anomalies:
            if start <= ke + 1 and end >= ks - 1:
                log.print(f"   POGODJENO: {desc}")
                log.print(f"      -> {atype} na {format_time_short(start)} ({detail})")
                found = True
                hits += 1
                break
        if not found:
            log.print(f"   PROMASENO: {desc}")
    log.print(f"\n   Rezultat: {hits}/{len(known_issues)}")

    # FFmpeg komanda za beepove
    beep_anomalies = [a for a in all_anomalies if a[2] == "BEEP"]
    if beep_anomalies:
        log.print()
        log.print("FFmpeg komanda za uklanjanje (bandreject 800-3000 Hz na detektiranim lokacijama):")
        filters = []
        for start, end, atype, conf, detail in beep_anomalies:
            filters.append(
                f"bandreject=f=1500:w=2200:enable='between(t,{start-0.1:.2f},{end+0.2:.2f})'"
            )
        filter_str = ",".join(filters)
        out_path = audio_path.replace(".wav", "_nobeep.wav")
        log.print(f'\nffmpeg -i "{audio_path}" -af "{filter_str}" "{out_path}"')

    log.print()
    log.print("Timestampovi za brzi copy-paste:")
    for start, end, atype, conf, detail in all_anomalies:
        log.print(f"   {format_time_short(start)}  {atype}: {detail}")

    if verbose:
        log.print(f"\nRAM na kraju: {get_memory_mb():.0f} MB")

    if log_path:
        log.print(f"\nLog spremljen u: {log_path}")

    log.close()


def main():
    parser = argparse.ArgumentParser(
        description="Podcast QA - pronalazi smetnje spektralnim oduzimanjem"
    )
    parser.add_argument("audio_path", help="Putanja do WAV datoteke")
    parser.add_argument(
        "--residual-threshold", type=float, default=3.0,
        help="Prag residuala u std devijacijama (default: 3.0, nize = osjetljivije)"
    )
    parser.add_argument("--chunk-duration", type=int, default=60)
    parser.add_argument("--log", type=str, default=None)
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()
    find_nonvoice_sounds(
        args.audio_path, args.residual_threshold, args.chunk_duration,
        args.verbose, args.log,
    )


if __name__ == "__main__":
    main()
