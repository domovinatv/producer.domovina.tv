# Producer: DOMOVINA Studio

Open-source podcast studio za macOS. Snima 2× RØDE PodMic USB kao izolirane
tragove, Lumix GH5 preko Elgato 4K X, s egzaktnim lip syncom i kopijom na
Cloudflare R2 dok snimanje još traje — vlastita zamjena za Riverside.fm.

Built and used by [Domovina.tv](https://domovina.tv).

---

## 🎙️ DOMOVINA Studio (realtime snimanje)

**→ Puna dokumentacija: [`docs/REALTIME_STUDIO.md`](docs/REALTIME_STUDIO.md)**
**→ Kako lip sync doista radi (s dijagramima): [`docs/LIP_SYNC_THEORY.md`](docs/LIP_SYNC_THEORY.md)**
**→ Izmjereni brojevi, pronađeni bugovi, otvorene pretpostavke: [`docs/LESSONS.md`](docs/LESSONS.md)**
**→ Karta studija: tok signala, lanac ispravaka, načini pucanja: [`docs/STUDIO_MAP.md`](docs/STUDIO_MAP.md)**
**→ Kontrolna lista za snimanje (udaljenost, gain, što reći gostu): [`docs/SNIMANJE.md`](docs/SNIMANJE.md)**
**→ Čišćenje pozadinskog šuma: što je probano i zašto ništa nije ušlo: [`docs/CISCENJE_ZVUKA.md`](docs/CISCENJE_ZVUKA.md)**

Ključna razlika prema svemu ostalom: sync se ne traži korelacijom nakon snimanja.
CoreAudio i AVFoundation označavaju uzorke istim satom (`mach_absolute_time`), pa
aplikacija zapiše točno vrijeme prvog uzorka svakog traga. Relativni pomaci su
egzaktna aritmetika. Korelacija ostaje samo za snimku sa SD kartice kamere, koja
ima svoj neovisni sat.

| | |
|---|---|
| **Izolirani tragovi** | svaki mikrofon sa svog HAL uređaja, 24-bit WAV — bez Aggregate Devicea (ili jedan RØDE Connect miks, po izboru) |
| **Mjerenje drifta** | uživo po kanalu u ppm, zapisano u manifest, ispravljeno u postu |
| **Live lip sync meter** | vrijednost iz sata + neovisna korelacija kao provjera |
| **R2 tijekom snimanja** | segmenti se šalju dok snima; prekid veze samo povećava zaostatak |
| **Dvostruko snimanje** | SD kartica = master, HDMI capture = sinkroni proxy i backup |
| **Zdravlje sustava** | disk, mrtvi mikrofon, clipping, USB odspajanje, termika |
| **Kalibracija** | jednokratni pljesak-test izmjeri interni A/V pomak kamere |
| **Oporavak** | ako Mac otkaže, `scripts/recover_from_r2.py` rekonstruira sesiju iz segmenata |

```bash
./scripts/build_app.sh            # .app bundle (potrebno za dopuštenja mic/kamere)
open "build/DOMOVINA Studio.app"

./scripts/build_app.sh --install  # isto + kopija u /Applications
open -a "DOMOVINA Studio"         # pa i iz Launchpada, Spotlighta i Docka

./scripts/test.sh               # testovi, ne diraju hardver
```

### Cloudflare R2

Bucket se radi jednom, wranglerom:

```bash
CLOUDFLARE_ACCOUNT_ID=<account> wrangler r2 bucket create domovina-studio-sessions --location eeur
```

Pristupne ključeve wrangler **ne može** napraviti — rade se u dashboardu:
`https://dash.cloudflare.com/<account>/r2/api-tokens` → Create API Token, Object
Read & Write, ograničeno na taj bucket.

U aplikaciji (Postavke → Cloudflare R2) ne treba ništa prepisivati:

* **zalijepi adresu bucketa iz dashboarda** — account i bucket se očitaju iz nje;
* **ili zalijepi Cloudflare API token** — Access Key ID je ID tokena, a Secret
  njegov SHA-256, pa jedan token doista je dovoljan.

Isto radi i iz ljuske:

```bash
./scripts/setup_r2.sh --url "https://dash.cloudflare.com/<account>/r2/default/buckets/<bucket>/settings"
```

S ključevima:

```bash
./scripts/setup_r2.sh          # konfiguracija + Keychain + provjera pravim krugom
./scripts/setup_r2.sh --verify-only
```

Provjera radi PUT, GET, usporedbu bajtova i DELETE protiv stvarnog bucketa —
potpis, endpoint i dopuštenja tokena odjednom, jer upravo ta kombinacija pukne.

Tijekom snimanja idu audio segmenti i video proxy chunkovi (~5 Mbps). Puni 4K
masteri ostaju lokalno; `--upload-masters` ih šalje i na R2, ali to je ~29 GB po
satu snimke.

Nakon snimanja:

```bash
./scripts/finalize_session.sh \
  --session "$HOME/Movies/DomovinaStudio/2026-07-25-1930-epizoda-42" \
  --lumix /Volumes/LUMIX/DCIM/140_PANA/P1400661.MOV
```

---

## 🛠️ Naslijeđeni tijek: podcast_sync.sh (Riverside.fm)

Za snimke koje su išle preko Riverside.fm. Skripta ostaje u repozitoriju i
pokreće se iz komandne linije (primjer niže). Tab u aplikaciji je uklonjen — taj
je arhiv zatvoren i ništa se novo tako ne snima. Kod graditelja naredbe i dalje
stoji u `PostProcessView.swift`; vraća se dodavanjem `.riverside` u
`Mode.selectable`.

## 🛑 The Problem
Relying 100% on cloud podcast recorders (like Riverside.fm) can be risky due to connection drops or "mic bleed" causing poor track separation. Local recordings are safer and offer better quality, but:
1. Manually syncing gigabytes of video and audio is tedious.
2. Re-encoding 100GB+ video files just to replace the audio track takes hours.

## ✅ The Solution
This script uses `audio-offset-finder` to mathematically calculate exact delay times between your cloud backup and local files. It then uses `ffmpeg` stream copying (`-c copy`) to inject the perfect local audio into your massive local video files **without re-encoding**. A process that used to take hours now takes minutes.

## ⚙️ Prerequisites
You must be on macOS and have the following tools installed:
* **ffmpeg** & **ffprobe** (`brew install ffmpeg`)
* **audio-offset-finder** (`pip install audio-offset-finder`)
* **afinfo** (Native to macOS, no installation required)

## 🚀 Installation
Clone the repository and make the script executable:
```bash
git clone https://github.com/domovinatv/producer.domovina.tv.git
cd producer.domovina.tv
chmod +x podcast_sync.sh
```

## 🛠️ Usage
The script uses named arguments. Order does not matter. You can pass as many `--lumix` video files as you need (e.g., if your camera split the recording into multiple `.MOV` or `.MP4` files).

```bash
./podcast_sync.sh \
  --output-dir "/Volumes/LUMIX/podcast_output_final" \
  --riverside-speaker-1 "/Users/ms/Downloads/riverside_speaker1_raw.wav" \
  --rode-mic-speaker-1 "/Volumes/DOMOVINA1TB/rode_connect/PodMic USB Mic1.wav" \
  --rode-stereo-all-tracks "/Volumes/DOMOVINA1TB/rode_connect/StereoMix.wav" \
  --lumix "/Volumes/LUMIX/DCIM/140_PANA/P1400661.MOV" \
  --lumix "/Volumes/LUMIX/DCIM/140_PANA/P1400662.MOV"
```

### Optional flags
| Flag | Description |
|------|-------------|
| `--dry-run` | Calculates all offsets but skips the final muxing step. Useful for verifying sync values before committing to a full run. |
| `--help`, `-h` | Prints usage instructions and exits. |

## 🧠 How It Works (Under the Hood)
1. **Validates Environment:** Checks that all required tools (`ffmpeg`, `ffprobe`, `afinfo`, `audio-offset-finder`) are installed before starting.
2. **Validates Input Files:** Verifies that all provided file paths actually exist on disk.
3. **Reads Duration:** Extracts exact duration from the Riverside.fm file.
4. **First Sync:** Compares the Riverside individual mic track with the local Rode mic track to find the exact audio start delay.
5. **Cuts the Gold Audio:** Trims the local `StereoMix.wav` to perfectly match the length and start time of the cloud session.
6. **Extracts Camera Audio:** Pulls a temporary, low-quality audio track from the first LUMIX video file.
7. **Second Sync:** Compares the trimmed "Gold Audio" with the camera audio to find where the podcast started in the video file.
8. **Disk Space Check:** Warns if the output disk has less than 10 GB of free space.
9. **Zero-Render Muxing:** Uses `ffmpeg concat demuxer` to trim the start of the first video, append any subsequent video files, and replace the audio track with the Gold Audio—all via stream copy (`-c copy`). Output is timestamped (e.g., `Podcast_20260320_143000.mov`) to prevent overwrites.

All runs are logged to `sync_YYYYMMDD_HHMMSS.log` in the output directory. Temporary files are automatically cleaned up via a `trap`, even if the script fails mid-execution.

## 🖥️ Aplikacija (DOMOVINA Studio)

Native macOS SwiftUI aplikacija s dva taba:

* **Studio** — snimanje u realnom vremenu (vidi gore).
* **Post** — dovršavanje sesije: poravnanje GH5 kartice s proxyjem i pregled sinkronizacije.

### Requirements
* macOS 14 (Sonoma) or later
* Xcode or Swift toolchain installed

### Build & Run

```bash
# Preporučeno: pravi .app bundle, jer macOS dopuštenja za mikrofon i kameru
# dodjeljuje po bundle identifieru
./scripts/build_app.sh
open "build/DOMOVINA Studio.app"

# Razvoj: dopuštenja se pripisuju Terminalu
cd PodcastProducer && swift run
```

### Testovi

```bash
./scripts/test.sh          # sve
./scripts/test_core.sh     # sat, mjerači, lip sync korelator, manifest
./scripts/test_sigv4.sh    # R2 potpisivanje protiv AWS test vektora
./scripts/test_recover.sh  # oporavak sesije: spajanje fMP4 i WAV segmenata
./scripts/test_finalize.sh # poravnavanje i drift, točnost do uzorka
./scripts/test_calibration.sh # kalibracija pljeskom na sintetičkom klipu
```

Sve gore ne dira hardver. Za provjeru cijelog lanca na stvarnim uređajima:

```bash
./scripts/test_hardware.sh --seconds 75
```

Otvori oba mikrofona i Elgato, snimi pravu sesiju i provjeri je dvaput —
manifestom i neovisno `ffprobe`om. Sam proizvede zvuk kroz zvučnike (mikrofoni i
kamera čuju isti signal), pa izmjeri i lip sync. Ne pokretati tijekom snimanja:
uređaji su ekskluzivni.

## 📝 License
This project is open-sourced under the MIT License.
