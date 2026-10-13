# DOMOVINA Multicam — arhitektura

Bilo koji broj telefona (Android i iPhone) radi kao dodatne kamere uz studio. Svaki
telefon snima **samostalno i lokalno**. Internet služi samo za upravljanje i za
upload nakon snimanja. Sve kamere se nakon toga u postprodukciji poravnaju na
zajedničku vremensku crtu, **zvukom** ili **satom servera**, s točnošću unutar
jednog framea.

Primjeri upotrebe: podcast s više kutova u studiju, ili šest telefona oko
nogometnog igrališta s nestabilnim mobilnim internetom i studijem u uredu.

> Detalji protokola: [`multicam/PROTOCOL.md`](../multicam/PROTOCOL.md) ·
> mjerenja i odluke: [`2026-10-13-multicam.md`](2026-10-13-multicam.md)

---

## 1. Sustav na jednoj slici

```mermaid
flowchart TB
    subgraph STUDIO["🎙️ Studio (ured)"]
        MAC["Mac mini<br/>DOMOVINA Studio + režija"]
        MIC["RØDE PodMic ×2<br/>glavni miks"]
        GH5["Lumix GH5<br/>glavna kamera"]
        MIC --> MAC
        GH5 --> MAC
    end

    subgraph CF["☁️ Cloudflare"]
        W["Worker<br/>domovina-multicam-relay"]
        DO["Durable Object 'Room'<br/>jedna soba = jedan studio"]
        R2[("R2 bucket<br/>multicam/sesija/kamera/")]
        W <--> DO
        W --> R2
    end

    subgraph TEREN["📱 Kamere (bilo gdje)"]
        A1["Android 1"]
        A2["Android 2"]
        I1["iPhone 1"]
        IN["… telefon N"]
    end

    MAC <-- "WebSocket<br/>start / stop / status" --> W
    A1 & A2 & I1 & IN <-- "WebSocket<br/>status / sat" --> W
    A1 & A2 & I1 & IN -. "upload nakon snimanja<br/>(dijelovi od 32 MiB)" .-> W
    R2 -. "preuzimanje" .-> MAC
```

**Glavno načelo:** preko mreže nikad ne putuje video u stvarnom vremenu. Telefon
koji izgubi internet nastavlja snimati, a kad se veza vrati, nastavi tamo gdje je
stao.

---

## 2. Komponente

| Komponenta | Tehnologija | Uloga |
|---|---|---|
| **Android aplikacija** | Kotlin, Jetpack Compose, CameraX | 1080p, konstantan fps, slika i zvuk u istoj datoteci, upload koji se nastavlja nakon prekida |
| **iOS aplikacija** | SwiftUI, AVFoundation (AVAssetWriter) | Isto, plus točno vrijeme prvog framea na satu uređaja |
| **Relay** | Cloudflare Worker + Durable Object | Soba s kamerama, prosljeđivanje naredbi, referentni sat, upload u R2 |
| **Pohrana** | Cloudflare R2 | `multicam/<sesija>/<kamera>/<snimka>.mp4` + sidecar `.json` |
| **Režija** | `director.mjs` (Node), kasnije Mac aplikacija | Tko je spojen, start/stop, preuzimanje |
| **Post** | `sync_cameras.py` (Python, NumPy/SciPy, ffmpeg) | Poravnanje N kamera, render na zajedničku crtu, mreža svih kamera za provjeru |

---

## 3. Spajanje telefona

Jedan link nosi sve postavke i ujedno je sadržaj QR koda. Telefon ga skenira
jednom, zapamti postavke i od tada se spaja sam.

```
domovinacam://join?relay=…&room=studio&key=…&name=gol-sjever
```

```mermaid
sequenceDiagram
    autonumber
    participant T as 📱 Telefon
    participant R as ☁️ Relay (soba)
    participant D as 🎛️ Režija

    T->>R: WebSocket (role=camera, deviceId, key)
    R-->>T: state { take: null | aktivni take }
    T->>R: hello { ime, platforma, model }
    loop 5× odmah, zatim svakih 5 s
        T->>R: time { c }
        R-->>T: time { c, s = sat servera }
    end
    loop svake 2 s
        T->>R: status { stanje, baterija, prostor, upload % }
        R-->>D: cameras [ … ]
    end
```

---

## 4. Tijek jedne snimke

```mermaid
sequenceDiagram
    autonumber
    participant D as 🎛️ Režija
    participant R as ☁️ Relay
    participant T1 as 📱 Telefon A
    participant T2 as 📱 Telefon B (loš signal)
    participant B as 🗄️ R2

    D->>R: start { sessionId, takeId }
    R->>T1: start { startAtServerMs = sada + 2 s }
    R->>T2: start { startAtServerMs }
    Note over T1,T2: Oba čekaju isti trenutak po satu servera,<br/>pa kreću zajedno bez obzira na latenciju mreže
    T1->>T1: ● snima lokalno
    T2->>T2: ● snima lokalno

    rect rgb(255, 235, 235)
        Note over T2: ✂️ internet nestane na 3 min
        T2->>T2: ● snima dalje, bez prekida
    end

    D->>R: stop
    R->>T1: stop
    T1->>T1: ■ zatvori datoteku, zapiši sidecar
    Note over R,T2: T2 nije dobio stop (offline)

    T2->>R: ponovno spajanje
    R-->>T2: state { take: null }
    T2->>T2: ■ zaustavi, jer take više nije aktivan

    par Upload nakon snimanja
        T1->>R: create → part 1..N → complete
        R->>B: multipart upload
    and
        T2->>R: create → part 1..N → complete
        R->>B: multipart upload
    end
    T1->>R: uploaded
    T2->>R: uploaded
    R-->>D: uploaded (A, B)
```

---

## 5. Stanja aplikacije na telefonu

```mermaid
stateDiagram-v2
    [*] --> Nespojen
    Nespojen --> Spreman: WebSocket + hello
    Spreman --> Čeka: start (startAtServerMs u budućnosti)
    Spreman --> Snima: start (trenutak već prošao — kasni ulazak)
    Čeka --> Snima: sat servera ≥ startAtServerMs
    Snima --> Snima: gubitak mreže (ne utječe na snimanje)
    Snima --> Zatvara: stop  ILI  state{take≠ovaj}
    Zatvara --> Uploada: sidecar zapisan
    Uploada --> Uploada: dio nije prošao → ponovi (do 5×)
    Uploada --> Spreman: svi dijelovi + sidecar u R2
    Uploada --> Uploada: aplikacija ugašena → nastavi nakon pokretanja
```

---

## 6. Što telefon zapisuje

Svaka snimka daje dvije datoteke.

```mermaid
flowchart LR
    subgraph TEL["📱 Telefon"]
        CAM["Kamera + mikrofon<br/>isti sat uređaja"]
        CLK["Monotoni sat uređaja<br/>(Android elapsedRealtime,<br/>iOS host clock)"]
        WS["Uzorci sata servera<br/>svakih 5 s, cijelo vrijeme"]
    end
    CAM --> MP4["take.mp4 / .mov<br/>1080p, 30 fps, AAC 48 kHz"]
    CLK --> SC
    WS --> SC["take.json (sidecar)<br/>• model, fps, kodek<br/>• fileZeroDeviceNs = 1. frame na satu uređaja<br/>• samples [t1, t4, s] …"]
```

- **Slika i zvuk u istoj datoteci, na istom satu.** Zato je zvuk iz kamere
  pouzdan pokazatelj gdje joj je slika.
- **`fileZeroDeviceNs`** veže prvi frame za sat uređaja s točnošću ispod
  milisekunde. Na Androidu se čita iz CameraX-a i provjerava prema senzorskom
  vremenu kamere, a na iOS-u je to vrijeme prvog framea koji je primio AVAssetWriter.
- **Uzorci sata** kažu koliko je sat uređaja bio ispred ili iza sata servera, u
  mnogo trenutaka kroz cijelu snimku.

---

## 7. Poravnanje u postprodukciji: dva načina

```mermaid
flowchart TB
    IN["N snimki + sidecari<br/>(+ glavni miks iz studija)"] --> Q{"Čuju li sve kamere<br/>isti zvuk?"}

    Q -- "Da — studio,<br/>kamere unutar par metara" --> AUD["🔊 ZVUK<br/>GCC-PHAT korelacija<br/>s glavnim miksom"]
    Q -- "Ne — stadion,<br/>kamere 100 m jedna od druge" --> CLKM["⏱️ SAT<br/>uzorci sata servera<br/>+ fileZero"]

    AUD --> FIT["Za svaku kameru:<br/>t_zajedničko = pomak + skala · t_kamere"]
    CLKM --> FIT
    FIT --> OUT["• multicam_sync.json<br/>• svaka kamera renderirana na zajedničku crtu<br/>• grid.mp4 — sve kamere odjednom"]
    AUD -. "ako postoje oba,<br/>sat provjerava zvuk" .-> CLKM
```

### Zašto dva načina

Zvuk putuje 343 m/s. Telefon 100 m od suca zviždaljku čuje **~290 ms kasnije**
(~9 frameova) od telefona pokraj njega. Na igralištu bi zato korelacija zvuka
mjerila udaljenost od izvora zvuka, a ne razliku između kamera. U studiju su
kamere blizu i zvuk je najtočnija metoda.

| | Zvuk | Sat servera |
|---|---|---|
| Kada | Studio, kamere čuju istu prostoriju | Stadion, teren, bilo koja udaljenost |
| Treba | Glavni miks ili jednu kameru kao referencu | Da je telefon bio spojen barem povremeno |
| Izmjerena točnost | **0,01 ms** (stvarni telefoni) | **~7 ms** prema zvuku (stvarni telefoni) · 0,7 ms (simulacija s RTT do 2 s) |
| Jedan frame (30 fps) | 33 ms | 33 ms |

### Zvuk, u dva prolaza

```mermaid
flowchart LR
    G["Gruba pretraga<br/>5 prozora × 40 s<br/>po cijelom miksu, 2 kHz"] --> V{"Slažu li se<br/>prozori?"}
    V -- "glasanje" --> P1["1. prolaz<br/>prozori od 4 s<br/>→ pomak + drift"]
    P1 --> P2["2. prolaz<br/>prozori od 20 s, izobličeni<br/>za izmjereni drift<br/>→ oštar vrh, < 0,1 ms"]
    P2 --> L["Robustan pravac<br/>kroz sve prozore"]
```

Drift je razlika u brzini kristala dvaju uređaja, obično 2 do 80 ppm. Na 80 ppm
to je 0,4 s kroz 90 minuta, pa se ispravlja, a ne zanemaruje.

### Sat, s lošom mrežom

```mermaid
flowchart LR
    S["Svi uzorci<br/>RTT 25 ms … 2 s"] --> B["Po minuti zadrži samo<br/>one blizu najbržeg"]
    B --> W["Pravac, težina 1/RTT²"]
    W --> M["sat_servera = α + β · sat_uređaja"]
    M --> F["+ fileZero → gdje je<br/>svaki frame na satu servera"]
```

Kod sporih uzoraka nije jasno koliki je dio vremena otišao u kojem smjeru, pa se
odbacuju. Rupe u mreži samo smanje broj uzoraka. Pravac kroz cijelu snimku i
dalje izmjeri i pomak i drift.

---

## 8. Protok podataka od kamere do montaže

```mermaid
flowchart LR
    A["📱 snimanje<br/>lokalno"] --> B["📱 sidecar<br/>+ uzorci sata"]
    B --> C["☁️ upload<br/>32 MiB dijelovi,<br/>nastavlja se"]
    C --> D[("R2")]
    D --> E["💻 director.mjs pull<br/>→ sesija/cameras/"]
    E --> F["💻 finalize_session.sh<br/>miks + GH5 + N kamera"]
    F --> G["🎬 poravnati videi<br/>+ grid.mp4<br/>→ montaža"]
```

| Što | Veličina |
|---|---|
| Video po telefonu (1080p, ~16 Mbit/s) | ~7 GB po satu |
| Nogometna utakmica, 6 telefona, ~100 min | ~70 GB ukupno, upload nakon utakmice (Wi-Fi) |
| Upravljački promet tijekom snimanja | nekoliko kB/s po telefonu |

---

## 9. Pouzdanost

| Situacija | Ponašanje |
|---|---|
| Internet nestane tijekom snimanja | Snimanje se nastavlja; uzorci sata se nastave nakon povratka |
| Stop stigne dok je telefon offline | Pri ponovnom spajanju relay javi `state: nema takea` → telefon zaustavi i uploada |
| Telefon se spoji usred snimke | Odmah dobije `start` i priključi se (kasni ulazak) |
| Upload pukne ili se aplikacija ugasi | Popis dijelova je spremljen na disk; nastavlja se nakon pokretanja |
| Kamera bez zvuka ili bez podataka o satu | Prijavi se kao neuspjela; ostale kamere i audio se normalno obrade |

---

## 10. Status (2026-10-13)

| | Stanje |
|---|---|
| Relay + R2 | ✅ u produkciji, provjeren |
| Android (Moto Edge 30 Ultra, Moto G86) | ✅ provjereno na uređajima: snimanje, upload, rupe u mreži, sat |
| iOS (iPhone SE 2nd, 12 mini) | 🟡 builda se, instalira i spaja na relay; snimanje čeka dozvolu za kameru na uređaju |
| Post (zvuk + sat) | ✅ sintetički i stvarni testovi prolaze |
| Upravljanje iz Mac Studio aplikacije | ⏳ sljedeći korak |
| Automatski rez na govornika | ⏳ planirano |
