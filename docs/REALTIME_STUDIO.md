# Domovina Studio — realtime podcast companion

Open-source zamjena za Riverside.fm za snimanje u vlastitom studiju: 2× RØDE
PodMic USB, Lumix GH5 preko Elgato 4K X, izolirani tragovi, savršen lip sync i
kopija na Cloudflare R2 dok snimanje još traje.

---

## Ključna odluka: sync se rješava satom, ne korelacijom

Stara skripta (`podcast_sync.sh`) tražila je pomake matematičkom korelacijom
zvuka nakon snimanja. To radi, ali je pogađanje — i propada kad je u sobi tiho,
kad se mikrofoni jako razlikuju po zvuku ili kad snimka ima ponavljajuće dijelove.

Aplikacija to rješava na izvoru. Na macOS-u i CoreAudio i AVFoundation
označavaju uzorke istim satom (`mach_absolute_time()` / `CMClockGetHostTimeClock`):

* svaki audio buffer iz mikrofona nosi `AVAudioTime.hostTime`
* svaki video frame s Elgata nosi PTS na istom host clocku

Aplikacija zapiše `firstSampleHostNanos` za svaki trag i time je relativni pomak
između bilo koja dva traga **egzaktna aritmetika**, bez korelacije.

> **Važna granica ove tvrdnje.** Host clock daje egzaktno poravnanje *lanaca za
> hvatanje*, ali timestamp označava trenutak kad su podaci došli do drivera — ne
> trenutak kad se nešto dogodilo u sobi. Video s Elgata je označen 40–100 ms
> kasnije od zvuka iz mikrofona za isti stvarni trenutak, jer prolazi kroz senzor,
> obradu u kameri, HDMI i UVC buffer. Sat sam po sebi **ne rješava lip sync** —
> tu razliku mjeri korelacija HDMI zvuka, kontinuirano.
>
> **→ Cijela priča s dijagramima: [`LIP_SYNC_THEORY.md`](LIP_SYNC_THEORY.md)**

Korelacija zato pokriva dvije stvari koje sat ne može znati:

1. **razliku latencije audio lanca i video lanca** — mjeri se stalno, iz govora u
   sobi, jer HDMI zvuk putuje istim lancem kao slika;
2. **gdje počinje snimka sa SD kartice GH5**, jer kamera ima svoj neovisni sat.

```
┌──────────────┐                          zajednički host clock
│ PodMic #1    ├──► AVAudioEngine ──► mic-1.wav      ┊ firstSampleHostNanos
│ (svoj clock) │    (svoj HAL device)                ┊
└──────────────┘                                     ┊
┌──────────────┐                                     ┊
│ PodMic #2    ├──► AVAudioEngine ──► mic-2.wav      ┊ firstSampleHostNanos
│ (svoj clock) │    (svoj HAL device)                ┊
└──────────────┘                                     ┊
┌──────────────┐    ┌───────────┐                    ┊
│ GH5 ──HDMI──►│    │ AVCapture │──► camera-proxy.mov┊ firstVideoHostNanos
│ Elgato 4K X  ├───►│ Session   │──► fMP4 segmenti ──┊──► Cloudflare R2
└──────────────┘    └───────────┘                    ┊
       │
       └── SD kartica (master) ──► poravnava se u postu korelacijom prema proxyju
```

### Zašto NE Aggregate Device

Uobičajeni recept za dva USB mikrofona na Macu je Aggregate Device u Audio MIDI
Setupu. Aplikacija to namjerno ne koristi:

* Aggregate Device radi *drift correction* resamplingom u HAL-u — tiho mijenja
  tvoj zvuk i ne kaže ti koliko.
* Dobiješ jednu datoteku s više kanala, pa izolirani tragovi zahtijevaju
  dodatno razdvajanje.

Umjesto toga, svaki mikrofon se snima sa svog HAL uređaja preko vlastite
`AVAudioEngine` instance. Cijena je da drift moraš mjeriti sam — pa aplikacija to
i radi.

### Mjerenje drifta

Svaki USB mikrofon ima svoj kristal. Tipično odstupanje je 10–50 ppm, što je na
dvosatnoj snimci **72–360 ms** razlike. To se čuje.

Aplikacija tijekom snimanja stalno računa:

```
measuredSampleRate = (uzorci dostavljeni prije ovog buffera) / (proteklo host-clock vrijeme)
driftPPM           = (measuredSampleRate / nominalSampleRate − 1) × 10⁶
```

Broj se prikazuje uživo po kanalu i zapisuje u manifest. `finalize_session.sh` ga
zatim ispravlja s `asetrate` + `aresample`.

> Uzorci se broje **prije** dodavanja trenutnog buffera. Da se broje poslije,
> rezultat bi bio pomaknut za jednu dužinu buffera — oko 24 ppm na sat pri 4096
> frameova, dakle isti red veličine kao drift koji mjerimo.

---

## Što se snima

| Datoteka | Sadržaj | Veličina/h |
|---|---|---|
| `audio/mic-N.wav` | izolirani mikrofon, 24-bit LPCM, kontinuirano | ~0,5 GB |
| `segments/mic-N/*.wav` | isti zvuk u 60-sekundnim komadima za R2 | briše se nakon uploada |
| `video/camera-proxy.mov` | HDMI capture, HEVC ili ProRes | 9–45 GB |
| `segments/video/*.mp4` | fMP4 komadi ~3 Mbps za R2 | briše se nakon uploada |
| `manifest.json` | uređaji, pomaci, drift, oznake, dnevnik | KB |
| `upload-journal.json` | stanje reda za slanje (preživi pad aplikacije) | KB |

Master video ostaje snimka na SD kartici GH5. Proxy je referenca za sync, live
pregled i sigurnosna kopija — dvostruko snimanje znači da pad Maca ne uništava
epizodu.

### Kodeci

Mac mini s M-serija Pro/Max čipom ima hardverski ProRes encoder:

| Kodek | 1080p30 | Kada |
|---|---|---|
| HEVC | ~9 GB/h | zadano; najmanji fajl, R2 upload izvediv |
| ProRes 422 Proxy | ~20 GB/h | kad želiš montirati direktno iz proxyja |
| ProRes 422 LT | ~45 GB/h | kad proxy mora izgledati kao master |

---

## Cloudflare R2 tijekom snimanja

Ograničenja R2 multipart uploada su stroža od S3: minimalni dio je 5 MiB i **svi
dijelovi osim zadnjeg moraju biti identične veličine**. Kod snimke nepoznate
duljine to je nezgodno, pa se koristi drugačiji pristup:

* **Tijekom snimanja** — svaki segment je zaseban objekt, poslan jednim PUT-om.
  60 s mono 24-bit/48 kHz zvuka je ~8,6 MB; video komad ~2 MB. Nikakav multipart.
* **Nakon zaustavljanja** — master datoteke idu multipartom s fiksnih 16 MiB po
  dijelu.

Pravila kojih se upload drži:

1. **Nikad ne blokira snimanje.** Sve prvo ide na disk; upload je posljedica.
   Prekid interneta samo povećava zaostatak, koji vidiš kao broj na ekranu.
2. **Preživljava pad.** `upload-journal.json` se zapisuje pri svakoj promjeni.
   Stavke zatečene u letu vraćaju se u red pri sljedećem pokretanju.
3. **Ključevi nikad ne idu na disk.** Secret access key je u macOS Keychainu;
   zahtjevi se potpisuju SigV4 u procesu, bez posrednika.
4. **Odustaje kad treba.** HTTP 4xx (osim 429) se ne ponavlja — pogrešan ključ se
   neće ispraviti stotim pokušajem.

Struktura u bucketu:

```
sessions/2026-07-25-1930-epizoda-42/
├── manifest.json
├── audio/mic-1/mic-1-00000.wav …
├── video/segments/video-00000.mp4 …
└── masters/camera-proxy.mov, mic-1.wav, mic-2.wav
```

Potpisivanje je pokriveno testovima protiv AWS-ovih objavljenih SigV4 test
vektora (`scripts/test_sigv4.sh`) — pogrešan potpis se inače ne vidi dok ne padne
pravi upload, a tada snimanje već traje.

---

## Što aplikacija pazi umjesto tebe

Svaka od ovih provjera postoji jer je nekome pokvarila snimku:

| Provjera | Ponašanje |
|---|---|
| Slobodan prostor | ispod 20 GB odbija početi; prikazuje procjenu u satima |
| Mrtvi mikrofon | 15 s tišine na aktivnom kanalu = crveni alarm |
| Clipping | brojač po kanalu, peak-hold na mjeraču |
| USB odspajanje | CoreAudio listener; sesija se nastavlja, gubitak se zapisuje |
| Video bez frameova | ako 3 s nakon starta nema frameova s Elgata |
| Temperatura | `ProcessInfo.thermalState` — throttling se vidi kao ispušteni frameovi minutama kasnije |
| Zaostatak uploada | prikazan u MB i broju stavki |
| Izlaz iz aplikacije | blokiran dijalogom dok snimanje traje |
| Pad aplikacije | `movieFragmentInterval = 2 s` — video ostaje čitljiv |

---

## Rad s aplikacijom

```bash
# Build pravog .app bundlea (potrebno za dopuštenja mikrofona/kamere)
./scripts/build_app.sh
open "build/Domovina Studio.app"

# Razvoj bez bundlea (dopuštenja se pripisuju Terminalu)
cd PodcastProducer && swift run

# Testovi (ne diraju hardver)
./scripts/test.sh
```

### Tijek snimanja

1. **Postavke → Uređaji** — dodijeli PodMic USB mikrofone slotovima i odaberi
   Elgato kao video ulaz i HDMI zvuk.
2. **Pregled** — provjeri sliku i da lip sync meter pokazuje „potvrđeno".
3. **Snimaj.**
4. Tijekom snimanja dodaj **oznake** — spremaju se s točnim vremenom i izlaze u
   `markers.txt` za montažu.
5. **Zaustavi.** Master datoteke odlaze na R2 u pozadini.

### Lip sync meter

Prikazuje dva broja namjerno:

* **Po satu** — iz host clock oznaka. Ovome vjerujemo, ovo ide u manifest.
* **Korelacija** — neovisna provjera korelacijom anvelope mikrofona i HDMI zvuka.

Ako se razilaze više od 40 ms, meter kaže „provjeri!". Ispod 30 % pouzdanosti
korelacija nije upotrebljiva — obično znači da je u sobi bilo tiho.

---

## Post-produkcija

```bash
./scripts/finalize_session.sh \
  --session "$HOME/Movies/DomovinaStudio/2026-07-25-1930-epizoda-42" \
  --lumix /Volumes/LUMIX/DCIM/140_PANA/P1400661.MOV \
  --lumix /Volumes/LUMIX/DCIM/140_PANA/P1400662.MOV
```

Skripta:

1. pročita manifest,
2. ispravi drift svakog mikrofona,
3. poravna mikrofone na vremensku os proxyja — **host-clock pomak plus izmjerena
   latencija lanca** iz korelacije HDMI zvuka (`adelay` ili `atrim`),
4. napravi miks (`normalize=0` da razine kanala ostanu netaknute, pa `alimiter`),
5. korelacijom nađe gdje proxy počinje unutar SD snimke,
6. muxa SD snimku s miksom uz `-c:v copy` — bez renderiranja videa.

Rezultat je u `<sesija>/final/`: `*_final.mov`, `mix.wav`, `aligned/`,
`markers.txt` i log.

`--dry-run` ispiše sve pomake bez zapisivanja — korisno za provjeru prije nego
pokreneš obradu na 100 GB materijala.

---

## Provjereno bez hardvera

Napisano i testirano bez priključenih mikrofona i kamere. Provjereno je:

* korelator za lip sync na umjetnim pomacima 0 / +100 / −60 ms — izmjereno s
  greškom < 0,1 ms i pouzdanošću 1,00;
* mjerači razine protiv poznatih signala (−20 dBFS sinus → peak −20,00, rms
  −23,01 dB), detekcija clippinga i mrtvog mikrofona;
* host clock aritmetika, uključujući negativne razlike bez UInt64 wrapa;
* manifest round-trip i imenovanje mapa (`Đakovo: čćžšđ #42!` → `dakovo-cczsd-epizoda-42`);
* SigV4 protiv tri AWS test vektora, uključujući sortiranje query parametara;
* cijeli `finalize_session.sh` na sintetičkoj sesiji — poravnanje točno do
  milisekunde, SD offset od 10,000 s pronađen egzaktno.

### Poznate rupe (prije epizode od 180 minuta)

Detaljno objašnjeno u [`LIP_SYNC_THEORY.md`](LIP_SYNC_THEORY.md):

1. **Drift mikrofona se zapisuje kao jedan globalni odnos**, a termalna komponenta
   je nelinearna → rezidual 10–30 ms na krajevima duge snimke. Treba zapisivati
   trajektoriju drifta svakih 30 s i ispravljati po dijelovima. (Pomak
   mikrofon→slika se **već** bilježi kroz vrijeme i skripta javlja ako šeta.)
2. **`finalize_session.sh` korelira SD master samo na početku.** Kamerin sat drifta
   kroz snimku, pa na 180 min kraj epizode može biti do ~324 ms van syncа. Treba
   korelirati na dva mjesta i primijeniti `ffmpeg -itsscale` (skalira timestampove
   bez renderiranja).
3. **Jednokratna kalibracija pljeskom** još nije podržana kao konstanta u
   postavkama.

Za snimke do ~30 minuta ništa od ovoga se ne vidi. Za 180 minuta se vidi.

### Što se MORA provjeriti na pravom hardveru

Ovo se ne može simulirati:

1. **Dva PodMic USB istovremeno** — hoće li `AVAudioEngine` startati po HAL
   uređaju bez Aggregate Devicea. Ako `engine.start()` padne, treba spojiti
   `inputNode` na utišan mixer.
2. **Stvarni drift** — koliko ppm ti mikrofoni doista imaju.
3. **Elgato 4K X format** — koja rezolucija/fps se pojavi u `activeFormat` i
   nosi li HDMI zvuk stvarno GH5-ov mikrofon.
4. **ProRes hardverski encoder** — prihvaća li `AVAssetWriter` `proRes422LT` na
   tvom čipu pri 4K.
5. **Segmentirani writer** — daje li `.mpeg4AppleHLS` profil komade uz odabrani
   kodek, i kolika je stvarna brzina uploada.
6. **Termika kroz dva sata** — Mac mini pod trajnim encodeom.

Za prvu probu: pusti 10-minutnu testnu snimku, pa provjeri `manifest.json` i
pokreni `finalize_session.sh --dry-run`.
