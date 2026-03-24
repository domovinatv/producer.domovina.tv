#!/usr/bin/env python3
import sys
import librosa
import numpy as np
from scipy.signal import find_peaks

def find_beeps(audio_path, target_freq=1200, freq_margin=150, threshold=0.15):
    print(f"🔍 Analiziram datoteku: {audio_path}")
    print(f"🎯 Tražim WhatsApp beepove oko: {target_freq} Hz...")

    try:
        # Učitavanje zvuka
        y, sr = librosa.load(audio_path, sr=None, mono=True)
    except Exception as e:
        print(f"❌ Greška pri učitavanju datoteke: {e}")
        return

    # STFT za pretvaranje u frekvencijsku domenu
    S = np.abs(librosa.stft(y))
    freqs = librosa.fft_frequencies(sr=sr)

    # Pronalazak raspona frekvencija gdje se nalazi beep
    freq_mask = (freqs >= (target_freq - freq_margin)) & (freqs <= (target_freq + freq_margin))

    # Izdvajanje energije samo u tom frekvencijskom pojasu
    band_energy = np.sum(S[freq_mask, :], axis=0)

    # Normalizacija energije za lakše traženje šiljaka (0 do 1)
    if np.max(band_energy) > 0:
        band_energy = band_energy / np.max(band_energy)

    # Pronalazak šiljaka (vrhova). distance sprječava da isti beep detektira dvaput
    peaks, _ = find_peaks(band_energy, height=threshold, distance=sr//512 * 2)

    if len(peaks) == 0:
        print("✅ Nisu pronađeni beepovi na ovoj frekvenciji!")
        return

    # Pretvaranje frameova u sekunde
    times = librosa.frames_to_time(peaks, sr=sr)

    print(f"\n🚨 Pronađeno {len(times)} potencijalnih beepova!")
    print("-" * 60)

    ffmpeg_filters = []
    for i, t in enumerate(times):
        print(f"Beep #{i+1}: detektiran na {t:.2f} sekundi")
        # Generiramo notch filter koji ubija 1200Hz, širine 150Hz, samo u trajanju beepa
        ffmpeg_filters.append(f"notch=f={target_freq}:bw=150:enable='between(t,{t-0.1:.2f},{t+0.6:.2f})'")

    print("-" * 60)
    print("🛠️ Tvoja gotova FFmpeg komanda za brisanje (Copy-Paste):")
    filter_string = ",".join(ffmpeg_filters)

    # Ispis finalne komande s originalnom putanjom
    print(f"\nffmpeg -i '{audio_path}' -af \"{filter_string}\" '{audio_path.replace('.wav', '_nobeep.wav')}'\n")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Korištenje: python find_beeps.py <putanja_do_wav>")
        sys.exit(1)
    find_beeps(sys.argv[1])
