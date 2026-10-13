# Multicam protokol

Telefoni (Android i iOS) su dodatne kamere uz Mac studio. **Svaki telefon snima
samostalno**, lokalno, sliku i zvuk iz vlastitog mikrofona u istu datoteku. Mreža
služi samo za upravljanje (start/stop/status) i za upload snimke nakon stopa.
Sinkronizacija se ne radi preko mreže: post korelira zvuk svake kamere s glavnim
miksom (vidi `scripts/sync_cameras.py`).

```
 Mac / CLI režija ──ws──┐
                        ├── Cloudflare Worker + Durable Object "Room" ── R2
 telefon 1..N ─────ws───┘         (relay, multicam/relay)
```

## Spajanje

Jedan URL nosi sve, i to je ujedno sadržaj QR koda:

```
domovinacam://join?relay=https%3A%2F%2F<worker>&room=<soba>&key=<ključ>&name=<ime>
```

`name` je opcionalan (zadano: model uređaja). Aplikacija sprema vrijednosti i
spaja se sama pri svakom pokretanju.

## WebSocket

`GET {relay}/v1/rooms/{room}/ws?role=camera|director&id={deviceId}&key={key}`

`deviceId` je stabilan UUID koji aplikacija generira jednom i spremi. Sve poruke
su JSON s poljem `type`. Klijent se nakon prekida spaja ponovno (backoff 1→10 s).

### kamera → relay

| type | polja |
|---|---|
| `hello` | `id, name, platform ("android"\|"ios"), model, os, app` — prva poruka nakon spajanja |
| `status` | `state ("idle"\|"recording"\|"uploading"\|"error"), takeId?, recordingSeconds?, battery (0–1), charging, freeBytes, upload? {bytesDone, bytesTotal}, error?` — svakih 2 s i na svaku promjenu |
| `recordingStarted` | `sessionId, takeId, file, wallClockMs` |
| `recordingStopped` | `sessionId, takeId, file, durationSeconds, bytes` |
| `uploaded` | `sessionId, takeId, objectKeys: [..]` |
| `time` | `c` (klijentov ms) — relay odgovara `{type:"time", c, s}` |

### režija → relay → kamere

| type | polja |
|---|---|
| `start` | `sessionId, takeId` (opcionalno `target` = deviceId, inače svima) |
| `stop` | `takeId` |

Relay pamti trenutni take. Kamera koja se spoji (ili ponovno spoji) dok take traje
odmah dobije `start` — **kamera koja već snima isti `takeId` ga ignorira**; `start`
je idempotentan, kao i `stop` kad kamera ne snima.

### relay → režija

`{type:"cameras", cameras:[{id, name, platform, model, online, status, lastSeen}], take}`
nakon svake promjene, plus proslijeđeni `recordingStarted/Stopped/uploaded`
s dodanim `cameraId`.

## Upload (nakon stopa)

Svi zahtjevi nose `Authorization: Bearer {key}`. Ključ objekta je
`multicam/{sessionId}/{cameraName}/{datoteka}`; relay ga sastavlja i vraća.

1. `POST {relay}/v1/upload/create` body `{sessionId, camera, file}` → `{objectKey, uploadId, partSize}`
2. `PUT {relay}/v1/upload/part?objectKey=…&uploadId=…&part=N` (N od 1), tijelo = točno
   `partSize` bajtova (zadnji dio smije biti kraći) → `{partNumber, etag}`
3. `POST {relay}/v1/upload/complete` body `{objectKey, uploadId, parts:[{partNumber, etag}]}` → `{size}`

Mali fajlovi (sidecar JSON): `PUT {relay}/v1/object?sessionId=…&camera=…&file=…` → `{objectKey}`.

`partSize` je 32 MiB — R2 traži jednake dijelove (osim zadnjeg), Worker prima
najviše 100 MB po zahtjevu. Neuspjeli dio se ponavlja (do 5 puta, backoff).

Preuzimanje (režija): `GET /v1/list?prefix=multicam/{sessionId}/`,
`GET /v1/object?objectKey=…`.

## Snimka na telefonu

- 1920×1080, **konstantnih 30 fps**, H.264 ili HEVC ~16 Mbit/s, AAC 48 kHz.
- Slika i zvuk u istoj datoteci, isti sat uređaja — zato je zvuk iz kamere
  pouzdana referenca za sinkronizaciju.
- Ekran ne gasi dok aplikacija radi.
- Uz video ide sidecar `{takeId}.json`:

```json
{
  "version": 1,
  "sessionId": "…", "takeId": "…",
  "camera": {"id": "…", "name": "…", "platform": "ios", "model": "iPhone13,1", "os": "18.2"},
  "file": "take-….mov",
  "video": {"width": 1920, "height": 1080, "fps": 30, "codec": "hevc"},
  "audio": {"sampleRate": 48000, "channels": 1},
  "startWallClockMs": 1760000000000,
  "serverOffsetMs": -12,
  "durationSeconds": 123.4
}
```

`startWallClockMs + serverOffsetMs` je grubo (±50 ms) vrijeme početka po satu
relaya. Post ga koristi samo da suzi prozor pretrage; poravnanje radi korelacija.
