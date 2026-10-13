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
- Gubitak veze nikad ne zaustavlja snimanje. Pri ponovnom spajanju relay pošalje `state`; ako snimam take koji više nije aktivan (stop je stigao dok sam bio offline), zaustavim ga i uploadam.
- `start` nosi `startAtServerMs`: snimanje kreće kad sat relaya (procjena iz uzorka s najkraćim RTT-om u zadnjih 5 min) dođe do tog trenutka, ranije za naučeno kašnjenje CameraX-a od `start` do prvog framea (~120–200 ms, pomični prosjek u prefs `startLatencyMs`). Ako je trenutak prošao, odmah.

## Sat (sidecar v2)

- Dok je spojen, telefon šalje `time` svakih 5 s (plus pet zaredom pri spajanju). Svaki odgovor `{t1, t4, s}` (t1/t4 = `elapsedRealtimeNanos`, t4 uzet na niti čitača socketa) dopisuje se u `files/clock/samples-boot<N>.txt` — jedna datoteka po paljenju telefona, jer se elapsedRealtime resetira pri bootu.
- Sidecar dobije sve uzorke od 15 min prije snimke; neposredno prije uploada sidecara (nakon videa) lista se osvježi do tog trenutka, i nakon restarta aplikacije.
- `fileZeroDeviceNs`: CameraX `Recorder` pamti PTS prvog videoframea u privatnom polju `mFirstRecordingVideoDataTimeUs` (System.nanoTime µs; enkoder ga dobije iz senzorskog REALTIME vremena fiksnim pomakom) i oduzima ga od svih PTS-ova — to je točno nula mp4-a (zvuk prije prvog framea Recorder baca). Čita se refleksijom i pretvara natrag u elapsedRealtime, pa se provjeri prema Camera2 `SENSOR_TIMESTAMP` iz CaptureCallbacka: na oba testna telefona razlika je ≤1 µs, pa se uzima senzorsko vrijeme (nesigurnost 0,1 ms). Ako refleksija ne uspije (nova verzija CameraX-a), rezerva je `status-min` (min vremena Status događaja − trajanje), ~30 ms lošije.
