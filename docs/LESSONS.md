# Naučeno tijekom izrade — stvari koje se ne vide iz koda

Zapisano 2026-07-25, prije prve probe na pravom hardveru. Sve niže je ili
**izmjereno** na ovom Macu, ili **bug koji je stvarno pronađen** testom. Nije
teorija.

---

## Brojevi koje ne treba ponovno mjeriti

### Platforma

| Stvar | Vrijednost | Kako znam |
|---|---|---|
| `/bin/bash` na macOS-u | **3.2.57** | `bash --version`. Nema asocijativnih polja — `declare -A` puca. Skripte moraju biti bash 3.2 kompatibilne. |
| `duration_ts` za WAV | = broj uzoraka | `time_base=1/48000`, pa je `duration_ts` točan broj uzoraka. Koristi to, ne `duration × rate`. |
| `atrim=end_sample=N` | točan do uzorka | Izmjereno: 0,000 ms odstupanja. |
| `asetrate`+`aresample` bez splita | **0 ms** greške | 1, 2, 6 i 18 dijelova s identičnim rateom → svi 600,000000 s. |
| `asetrate`+`aresample` s promjenom ratea | **+1–2 ms po operaciji** | Resampler flush doda ~100–200 uzoraka na kraj. Akumulira se po dijelu → obavezno rezati na `end_sample`. |
| `-itsscale X` uz `-c copy` | skalira trajanje točno za X | 100 s → 100,099935 s pri X=1.001. Ni jedan frame se ne renderira. |

### Nelinearnost drifta kroz snimku

Ista termalna krivulja (kristal se smiruje s 40 na 12 ppm), različite duljine.
„Odstupanje od pravca" je rezidual koji ostaje ako se primijeni **jedan** globalni
resample odnos:

| Duljina snimke | Odstupanje od pravca | Odluka |
|---|---|---|
| 10 min | 1,9 ms | jedan odnos je dovoljan |
| 60 min | 10,5 ms | po dijelovima |
| 180 min | **31,1 ms** | po dijelovima, obavezno |

**Prijelaz je oko 50 minuta** (prag u skripti je 8 ms). Zato podcast od 20 minuta
nikad nije otkrio problem, a epizoda od 3 sata bi ga otkrila u montaži.

### Perceptivni pragovi

Zvuk koji **pretječe** sliku smeta oko dvostruko više od zvuka koji zaostaje —
grubo −45 ms naprijed vs +90 ms nazad. Latencija lanca (video označen kasnije) daje
upravo smjer „zvuk naprijed", pa je neispravljena greška od ~90 ms jasno vidljiva.

---

## Bugovi koje su testovi pronašli

Svaki od ovih je prošao pregled koda i pao na testu. Vrijedi ih pamtiti kao klase
grešaka, ne kao pojedinačne slučajeve.

### 1. `if p.get("frameCount")` — nula je falsy

Prva točka trajektorije drifta legitimno ima `frameCount: 0`. Truthiness provjera
ju je tiho odbacila, pa je baseline pomaknut na 30. sekundu — a to **skalira svaku
per-interval frekvenciju** za ~30 ppm. Rezultat: ispravak drifta radi u pogrešnom
smjeru, i nitko to ne bi primijetio bez provjere do uzorka.

> Pravilo: za numeričke vrijednosti iz JSON-a uvijek `is not None`, nikad truthiness.

### 2. Tab je IFS whitespace u bashu

`read -r a b c` s `IFS=$'\t'` **skuplja** susjedne tabove, pa prazno polje u TSV-u
pomakne sve kasnije stupce lijevo. Manifest je javljao trajanje `yes`.

> Pravilo: emitter nikad ne šalje prazno polje — umjesto praznog ide `-`.

### 3. `$VAR…` — trotočka postaje dio imena varijable

`echo "Pakiram $APP_BUNDLE…"` → bash čita ime varijable kao `APP_BUNDLE\xe2\x80\xa6`
i pod `set -u` puca s „unbound variable". Pogađa svaki ne-ASCII znak odmah nakon
imena varijable.

> Pravilo: `${VAR}` uvijek kad slijedi bilo što osim razmaka ili interpunkcije iz ASCII-ja.

### 4. Mjerenje razine samo na kanalu 0

RØDE Connect virtualni uređaj je 2-kanalni; isto i dva mikrofona panirana hard
L/R. Glas na desnom kanalu = mjerač pokazuje ništa = **alarm za mrtvi mikrofon na
zdravom ulazu.**

### 5. Auto-dodjela po imenu koje sadrži „rode"

Na Macu s RØDE Connectom postoje tri virtualna uređaja. Filtar po imenu je
`RØDE Connect System` — **zvuk sustava** — dodijelio kao mikrofon. Snimalo bi ono
što Mac pušta kao gosta u podcastu.

### 6. Mjereno, a nikad primijenjeno

Korelator je mjerio pomak mikrofon→slika svake sekunde i prikazivao ga na ekranu.
Broj nije nikad išao u manifest ni u skriptu — poravnavanje je koristilo samo host
clock. Feature je izgledao gotov i bio je dekorativan.

> Pravilo: „mjerimo X" i „primjenjujemo X" su dvije različite tvrdnje. Provjeri
> putanju podataka do izlazne datoteke, ne do UI-ja.

### 7. Upload bez oporavka

Segmenti su se slali na R2 tijekom snimanja, ali nije postojao način da se sesija
iz njih rekonstruira. Uz to je `segmentType` bio odbacivan, pa se initialization
segment (nosi `moov` box) nije mogao razlikovati od media fragmenata.

> Pravilo: disaster recovery bez testiranog alata za oporavak nije disaster recovery.

### 8. Pogrešno zapamćen test vektor

Testirao sam SigV4 protiv AWS-ovog primjera i dobio neslaganje. Canonical request
hash se poklapao, potpis nije. Uzrok: tajni ključ u AWS-ovim **S3** primjerima je
`...MDENG/bPxRfi...` s **kosom crtom**, a ne `+` kao u većini drugih AWS primjera.
Implementacija je bila ispravna, test pogrešan.

> Pravilo: kad se dvije neovisne implementacije poklope a „očekivana" vrijednost ne,
> posumnjaj u očekivanu vrijednost. Provjeri izvor, ne pamćenje.

---

## Što se ne može testirati bez hardvera

Ovo su **otvorene pretpostavke**, ne provjerene činjenice. Prva proba treba
provjeriti točno njih:

| Pretpostavka | Ako je pogrešna |
|---|---|
| `AVAudioEngine` startaju paralelno, po jedan na svoj HAL uređaj, bez Aggregate Devicea | `engine.start()` padne → spojiti `inputNode` na utišan mixer |
| HDMI zvuk iz GH5 je poravnan s HDMI slikom | korelator mjeri pomak s konstantnom greškom → jednokratna kalibracija pljeskom daje konstantu |
| Elgato 4K X daje 4K/60 u `activeFormat` i HDMI zvuk je stvarno kamerin mikrofon | bez HDMI zvuka nema mjerenja lip synca — samo host clock |
| `AVAssetWriter` prihvaća `proRes422LT` na 4K na ovom čipu | pasti na HEVC |
| `.mpeg4AppleHLS` profil daje segmente uz odabrani kodek | nema live video backupa, audio ostaje |
| Termika kroz 3 sata pod trajnim encodeom | ispušteni frameovi, vidljivi u `droppedFrameCount` |
| Stvarni drift PodMic USB kristala | odlučuje je li potreban interface ili mikseta |

**Prva proba:** 20-minutna snimka, pa `manifest.json` → pogledaj `driftPPM` i
`syncMeasurements`. Ta dva broja odlučuju sve ostalo.

---

## Odluke i zašto, u jednoj rečenici svaka

* **Bez Aggregate Devicea** — HAL bi tiho resamplirao i ne bi rekao koliko; ovako
  se drift mjeri i zapisuje.
* **Medijan, ne prosjek**, za pomak mikrofon→slika — u tišini korelacija daje
  besmislice, a jedan izlet od −400 ms uništi prosjek.
* **Trajektorija, ne samo prosjek**, za drift — samo niz može razlikovati
  konstantan pomak od onog koji šeta kroz 180 minuta.
* **Segment po objektu** na R2 tijekom snimanja — R2 zahtijeva identične veličine
  multipart dijelova, što je nezgodno za stream nepoznate duljine.
* **Listanje buketa, ne manifest**, pri oporavku — manifest se šalje tek pri
  zaustavljanju, pa ga kod pada nema.
* **Dva prolaza** pri poravnavanju (drift, pa pomak) — u jednom prolazu ispravak po
  dijelovima nije izvediv.
* **`-itsscale` umjesto re-encodea** za drift kamerinog sata — skalira samo
  timestampove, ostaje zero-render.
* **Sve granice u uzorcima, ne u sekundama** — sekunde uvode zaokruživanje, a
  `atrim=start_sample`/`end_sample` je egzaktan.
