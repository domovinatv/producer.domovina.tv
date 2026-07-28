# Karta studija — kuda ide koji signal i gdje puca

Dopuna `LESSONS.md` (izmjereni brojevi i pronađeni bugovi) i `LIP_SYNC_THEORY.md`
(zašto sync radi). Ovdje je **oblik sustava**: koji signal kuda putuje, kojim
redom se ispravlja, i gdje je u praksi puknuo.

Sve niže je provjereno na hardveru 2026-07-27 i 2026-07-28, ne izvedeno iz koda.

---

## 1. Tok signala

Dvije topologije zvuka. Kamera je u obje ista.

```mermaid
flowchart LR
    subgraph mic["Mikrofoni"]
        P1["RØDE PodMic USB #1<br/>A29FA21F"]
        P2["RØDE PodMic USB #2<br/>EA6129FD"]
    end

    subgraph rc["RØDE Connect (aplikacija)"]
        GATE["gate + ducking + miks<br/>uklanja prelijevanje na izvoru"]
        VS["RØDE Connect Stream<br/>2ch — NOSI MIKS"]
        VV["RØDE Connect Virtual<br/>digitalna tišina"]
        VSYS["RØDE Connect System<br/>zvuk sustava, NE mikrofoni"]
    end

    subgraph cam["Kamera"]
        GH5["Lumix GH5"]
        SD["SD kartica<br/>= pravi master"]
        HDMI["HDMI: slika + zvuk<br/>jedan sat"]
    end

    EL["Elgato 4K X<br/>UVC, 3840x2160 @ 29.97"]

    subgraph app["Domovina Studio"]
        AR["AudioTrackRecorder<br/>24-bit WAV"]
        VC["VideoCaptureController<br/>HEVC 12 Mbit/s"]
        LS["LipSyncMonitor<br/>korelacija ovojnica"]
    end

    P1 --> GATE
    P2 --> GATE
    GATE --> VS
    GATE -.->|"ne koristiti"| VV
    GATE -.->|"ne koristiti"| VSYS

    P1 -.->|"izravno, sirovo<br/>samo ako su mikrofoni razmaknuti"| AR
    P2 -.-> AR
    VS ==>|"preporučeni put"| AR

    GH5 --> SD
    GH5 --> HDMI --> EL
    EL --> VC
    EL -->|"HDMI zvuk"| LS
    AR -->|"mikrofon"| LS

    style VS fill:#2d5a2d,color:#fff
    style VSYS fill:#5a2d2d,color:#fff
    style VV fill:#5a2d2d,color:#fff
    style SD fill:#2d3d5a,color:#fff
```

**Izmjereno, ne pretpostavljeno.** Snimao sam sva tri virtualna uređaja
istovremeno uz sirove mikrofone, s RØDE Connectom pokrenutim:

| uređaj | max | zaključak |
|---|---|---|
| RØDE Connect **Stream** | −56,9 dB | nosi miks |
| RØDE Connect Virtual | −91,0 dB | tišina |
| RØDE Connect System | −120 dB | zvuk sustava |
| PodMic sirovi (najglasniji) | −57,1 dB | referenca |

**Monitor Out u RØDE Connectu ne treba dirati.** Izgleda kao da bi to bio put
prema drugim aplikacijama, ali nije — on odlučuje samo gdje *ti* slušaš. Miks
stiže do nas i kad je na „No Output Selected".

Driver instalira sva tri virtualna uređaja **trajno**, pa njihovo postojanje ne
znači ništa. Samo pokrenuta aplikacija znači da je miks živ; bez nje je tišina.

---

## 2. Što se zapisuje tijekom snimanja

Ništa se ne spaja nakon zaustavljanja. Sve raste paralelno, od prve sekunde.

```mermaid
flowchart TD
    MIC["mikrofon"] --> TAP["capture tap"]
    TAP --> CONT["audio/mic-1.wav<br/>kontinuirani master, 24-bit"]
    TAP --> SEG["segments/mic-1/*.wav<br/>60 s komadi za R2"]
    TAP --> METER["mjerač razine + drift"]

    ELG["Elgato"] --> WQ["writer queue"]
    WQ --> MASTER["video/camera-proxy.mov<br/>HEVC 12 Mbit/s, fragmenti à 2 s"]
    WQ --> FMP4["fMP4 chunkovi à 6 s<br/>samo u memoriji ako je R2 isključen"]

    METER --> MANIFEST["manifest.json"]
    LSM["LipSyncMonitor"] -->|"svakih 5 s, confidence > 0.3"| MANIFEST
    DRIFT["driftSamples"] -->|"svakih 30 s"| MANIFEST

    SEG -.->|"uploadDuringRecording"| R2["Cloudflare R2"]
    FMP4 -.-> R2

    style CONT fill:#2d5a2d,color:#fff
    style MASTER fill:#2d5a2d,color:#fff
    style MANIFEST fill:#2d3d5a,color:#fff
```

Zeleno preživljava normalno zaustavljanje bez ijedne dodatne operacije. R2
segmenti su **neovisna kopija za slučaj katastrofe**, a ne dio normalnog tijeka —
brišu se lokalno čim su poslani.

Ako je R2 isključen, fMP4 chunkovi se odbacuju u `UploadQueue.enqueue`
(`guard client != nil`). Manifest ih zato više ne bilježi s lokalnom putanjom —
inače bi tvrdio da postoji 18 datoteka kojih nema.

---

## 3. Lanac ispravaka lip synca

Redoslijed nije proizvoljan. Player u Post tabu primjenjuje **isti redoslijed**
kao `finalize_session.sh`, zato ono što čuješ jest ono što ćeš dobiti.

```mermaid
flowchart TD
    A["firstSampleHostNanos svakog traga"] --> B["1. pomak starta<br/>relativno na prvi video frame"]
    B --> C["2. drift kristala<br/>measuredSampleRate / sampleRate"]
    C --> D["3. izmjereni pomak mikrofon→HDMI zvuk<br/>medijan syncMeasurements"]
    D --> E["4. interni A/V pomak kamere<br/>cameraAVOffsetMilliseconds"]
    E --> F["poravnata snimka"]

    G["host clock"] -.->|"vidi samo kad je podatak<br/>stigao do drivera"| B
    H["korelacija HDMI zvuka"] -.->|"jedina vidi latenciju lanca"| D
    I["pljesak, jednom"] -.->|"pretvara mikrofon→zvuk<br/>u mikrofon→sliku"| E

    style D fill:#5a4d2d,color:#fff
    style E fill:#5a2d2d,color:#fff
```

**Sat i korelator se ne poklapaju i ne trebaju.** Izmjereno na pravoj snimci: sat
je javio −219 ms, korelator +223 ms. Sat vidi samo trenutak dolaska do drivera;
razlika je stvarna latencija lanca koju sat po definiciji ne može izmjeriti.

**Pomak je konstanta po sesiji, ne po sustavu.** Izmjereno kroz dan: +153, +216,
+222, +225 ms u različitim pokretanjima, a unutar pojedine snimke stabilno na
±10 ms. Da je netko izmjerio jednom i zakucao broj, polovica epizoda bila bi
kriva za ~70 ms.

Korak 4 je **jedini još neizmjeren** — kalibracija pljeskom nije napravljena, pa
postprodukcija pretpostavlja da je kamera interno poravnata.

---

## 4. Načini na koje je ovo puknulo

Svaki je pronađen na hardveru u jednom danu. Vrijedi ih pamtiti kao **klase**,
jer se svi svode na isto: tiho je izgledalo ispravno.

```mermaid
flowchart TD
    START{"snimka nije<br/>ispala kako treba"}

    START --> A{"ima li videa?"}
    A -->|"ne"| A1["dopuštenje za kameru odbijeno<br/>→ sesija se nije pokrenula<br/>→ snimalo se samo zvuk<br/><br/>POPRAVLJENO: glasna poruka<br/>umjesto retka u logu"]

    A -->|"da"| B{"lip sync mjeren?"}
    B -->|"0 mjerenja"| B1{"ima li HDMI zvuka?"}
    B1 -->|"tišina"| B2["Elgato ulaz na Analog<br/>umjesto HDMI"]
    B1 -->|"ima ga"| B3["monitor put odbacivao svaki buffer<br/>ArrayTooSmall na PREVELIKOM polju<br/><br/>POPRAVLJENO"]

    B -->|"ima"| C{"tragovi poravnati?"}
    C -->|"ne"| C1["manifest bez firstSampleHostNanos<br/>→ finalize tiho uzima offset 0<br/><br/>POPRAVLJENO: statistike se čitaju<br/>prije otpuštanja recordera"]

    C -->|"da"| D{"disk / performanse?"}
    D -->|"odbija snimati"| D1["exFAT vraća 0 za slobodan prostor<br/>→ preflight odbija vanjski disk<br/><br/>POPRAVLJENO: fallback"]
    D -->|"zastajkuje"| D2["druga aplikacija drži camera feed<br/>Elgato Studio, ANE na 92%"]

    style A1 fill:#5a2d2d,color:#fff
    style B3 fill:#5a2d2d,color:#fff
    style C1 fill:#5a2d2d,color:#fff
```

Zajednička nit: **ništa od ovoga nije javilo grešku.** Manifest je nastao,
datoteke su nastale, aplikacija je izgledala zdravo. Uhvatilo ih je jedino
provjeravanje *sadržaja* — broja uzoraka, razine u dB, postojanja polja — a ne
„je li se izvršilo bez greške".

Dvije poruke su aktivno **krivile pogrešnog krivca**:

- „provjeri je li HDMI zvuk iz kamere bio odabran" — a bug je bio u našem
  monitor putu;
- `kCMSampleBufferError_ArrayTooSmall` na polju šest puta **prevelikom** od
  potrebnog.

> Pravilo: kad dijagnostika optuži hardver, provjeri prvo da put kojim podatak
> dolazi uopće radi. Snimka je cijelo vrijeme imala uredan zvuk u
> `camera-proxy.mov` — writer put je radio, monitor nije, i nitko ih nije
> usporedio.

---

## 5. Cloudflare R2 — odakle dolaze ključevi

Wrangler može napraviti bucket, ali **ne može** napraviti S3 kredencijale.
Provjereno: OAuth token koji wrangler drži odbijen je na token-management API-ju
(HTTP 403, kod 9109).

```mermaid
flowchart LR
    W["wrangler r2 bucket create"] --> B["bucket postoji"]
    W -.->|"403, kod 9109<br/>nema ovlasti"| X["izrada tokena"]

    DASH["dash.cloudflare.com<br/>/account/r2/api-tokens"] --> TOK["Cloudflare API token<br/>Object Read & Write"]

    TOK --> ID["GET /user/tokens/verify<br/>→ result.id"]
    TOK --> SHA["SHA-256 vrijednosti tokena"]

    ID --> AK["Access Key ID"]
    SHA --> SK["Secret Access Key"]

    AK --> SIG["SigV4 potpis"]
    SK --> SIG
    SIG --> R2["S3 endpoint<br/>account.r2.cloudflarestorage.com"]

    style X fill:#5a2d2d,color:#fff
    style TOK fill:#2d5a2d,color:#fff
```

Zato **jedan token doista je dovoljan** — nije zaobilaženje SigV4, nego su ta
dva podatka izvedena iz njega. Aplikacija to radi sama (Postavke → Cloudflare R2
→ „Izvedi ključeve"), a token se nigdje ne sprema; samo ono što je iz njega
izvedeno.

Adresa bucketa iz dashboarda se može zalijepiti cijela — account je prvi segment
putanje, a bucket **iza oznake `buckets`**, ne na fiksnoj dubini: segment između
njih je „default" na većini računa, ali „eu" drugdje.

---

## 6. Što ostaje otvoreno

| stavka | stanje |
|---|---|
| Kalibracija pljeskom | **nije napravljena** — bez nje je izmjereni pomak mikrofon→*zvuk*, ne mikrofon→*sliku* |
| R2 kredencijali | bucket postoji, ključevi se još nisu unijeli |
| Termika kroz 3 sata | neprovjereno pod trajnim 4K encodeom |
| `proRes422LT` na 4K | neprovjereno |
| 2-kanalni WAV s mono mikrofona | viđeno jednom (1,7 GB umjesto 0,9 GB); uzrok nije utvrđen |
