# DOMOVINA Kamera — Android

Android telefon kao dodatna kamera za studio. Protokol: `../PROTOCOL.md`.

Kotlin + Compose, CameraX 1.6.2, OkHttp 5. AGP 9.2.1, Gradle 9.5.1 (wrapper), compileSdk 37, minSdk 26.

## Build i instalacija

```bash
cd multicam/android
./gradlew assembleDebug
adb -s <serial> install -r -g app/build/outputs/apk/debug/app-debug.apk   # -g daje dozvole kamere i mikrofona
```

## Spajanje

Skeniraj QR kod iz `node multicam/director.mjs join <ime>`, ili s Maca:

```bash
adb -s <serial> shell am start -a android.intent.action.VIEW \
  -d "'domovinacam://join?relay=https%3A%2F%2Fdomovina-multicam-relay.d-o-m.workers.dev&room=studio&key=<ključ>&name=<ime>'"
```

Navodnici unutar navodnika su nužni, inače `adb shell` odreže sve iza prvog `&`.

## Ponašanje

- Snima 1920×1080 H.264 (~16 Mbit/s) + AAC 48 kHz stereo u jedan `.mp4`, fiksni raspon 30–30 fps, bez stabilizacije.
- Snimke ostaju na telefonu: `/sdcard/Android/data/tv.domovina.multicam/files/takes/` (uz svaku i sidecar `.json`).
- Upload nakon stopa ide u dijelovima od 32 MiB. Red čekanja je u `files/pending/`, pa se upload nastavlja i nakon što se aplikacija ubije.
- Kad se aplikacija spoji dok take traje, odmah se pridruži snimanju. Snimka prekinuta ubijanjem aplikacije ostaje nečitljiva (nema `moov`) i ne uploada se.
- `startWallClockMs` se uzima u trenutku CameraX događaja `VideoRecordEvent.Start`.
