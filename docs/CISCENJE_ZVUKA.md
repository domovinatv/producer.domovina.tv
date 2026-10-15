# Čišćenje pozadinskog šuma — što je probano i zašto ništa nije ušlo u lanac

Zapis istraživanja od **2026-07-28**, na epizodi snimljenoj s dva PodMica USB u uredu
uz prometnu cestu (kamioni kroz prozor, ventilator Mac Minija).

Zaključak unaprijed: **ništa od probanog nije ušlo u produkcijski lanac.** Ovaj
dokument postoji da se istih pet eksperimenata ne ponovi — i da se zna koji je broj
odlučio.

Dopunjuje [`SNIMANJE.md`](SNIMANJE.md) (kako snimiti da problem ne nastane) i
[`LESSONS.md`](LESSONS.md) (bugovi i izmjereni brojevi).

---

## 1. Broj koji odlučuje sve: odnos glasa i šuma po tragu

Mjereno u sekundama u kojima **nitko** ne govori (oba traga ispod 25. percentila),
pa uspoređeno s medijanom govora tog traga:

| trag | govor | šum u tišini | **odnos** | udaljenost od usta |
|---|---|---|---|---|
| voditelj | −42,0 dBFS | −61,0 dBFS | **19,1 dB** | ~6 cm |
| gošća | −45,4 dBFS | −51,1 dBFS | **5,7 dB** | ~30 cm |

**Ispod ~10 dB odnosa nijedan alat ne pomaže.** Na 5,7 dB svaki testirani algoritam
odnese više glasa nego šuma — to nije mana algoritma nego posljedica toga da glas i
šum dijele isti spektar, a šum je gotovo jednako glasan.

Kamioni koje se čuje u epizodi ulaze **skoro isključivo kroz udaljeniji mikrofon.**
Zato je pravilo od 15 cm iz `SNIMANJE.md` jedini stvarni lijek: gošća na 15 cm
umjesto 30 cm dobiva ~6 dB, dakle s 5,7 na ~11,7 dB — preko praga na kojem obrada
uopće ima smisla.

---

## 2. Što je probano

Sve na istom isječku, sve normalizirano na istu glasnoću prije slušanja (inače
glasnija varijanta uvijek „zvuči bolje").

| alat | vrsta | šum | glas | presuda |
|---|---|---|---|---|
| `afftdn` (ffmpeg) | spektralni, bez profila | −0,5 dB | −1,3 dB visina | prebalago da se primijeti |
| `arnndn` / RNNoise | mala mreža, 48 kHz | −1,9 dB | −1,9 dB visina | „gotovo isto kao original" |
| DeepFilterNet 3 | mreža, maskiranje | −0,7 dB | **−2,6 dB govora** | „katastrofa" — stišava govor više od šuma |
| `noisereduce` nestacionarni | spektralna subtrakcija | −19,7 dB | **−8,8 dB govora** | robotizira glas |
| **Demucs** `htdemucs` | separacija izvora | **−8,5 dB** | **nepromijenjen** | najbolji od svih, ali pišti (vidi 4.) |

Demucs je jedini koji je skinuo znatan šum **bez stišavanja glasa** (−28,4 → −28,7 dB)
i uz to dodao 3,4 dB visina. Nije „speech enhancement" model nego separator za
glazbu: glas ide u `vocals`, ventilator i vozila u ostalo. Radi maskiranjem, ne
sintezom — zato boja glasa ostaje.

Brzina, mjereno: Demucs 25 s zvuka za 11 s na CPU-u (M-series), DeepFilterNet
RTF 0,027. **Compute nikad nije bio ograničenje** — nema razloga graditi Modal
pipeline dok se ne nađe model koji na ovom materijalu doista pomaže.

---

## 3. Zamka koja je pokvarila prva mjerenja

Prvi krug testova hranio je modele signalom na **−47 LUFS**, jer je miks te epizode
snimljen ~26 dB pretiho. DeepFilterNet i RNNoise trenirani su na govoru normalne
razine i signal 30 dB pretih čitaju kao šum.

**Redoslijed je obavezno: pojačaj na normalnu razinu (~−20 LUFS) → očisti →
normaliziraj na cilj.** Nakon ispravka redoslijeda rezultati su se promijenili, ali
presuda nije — vidi tablicu gore, ona je već iz ispravnog kruga.

---

## 4. Kako se artefakti detektiraju iz signala

Uho je presudilo, ali oba prigovora imaju mjerljiv potpis. Korisno jer omogućuje
provjeru bez slijepog slušanja svake varijante.

### Pištanje (tonalni artefakti) — **detektirano**

Broj **izoliranih tonalnih vrhova** u pauzama: bin STFT-a koji je >10 dB iznad
medijana svoje okoline (5 binova × 5 okvira), po okviru pauze.

| | izoliranih vrhova |
|---|---|
| original | 0,27 |
| **Demucs** | **1,99** (7× više) |
| spektralni | 0,26 |

Poklapa se točno s dojmom „kod ventilatora se uvede nekakvo pištanje". Demucs stvara
tonove kojih u izvorniku nema.

### Robotizacija — **nije detektirana ovim mjerama**

Probano i **nije razlučilo**, pa se na to ne treba oslanjati:

- **cepstralna prominencija (CPP)** — obje varijante −1 % prema originalu
- **log-spektralna udaljenost na jakim binovima glasa** — daje veći broj Demucsu
  (27,8 dB) nego spektralnom (9,2 dB), dakle suprotno od onoga što uho čuje; broj je
  napuhan jer računa i praznine između harmonika gdje je šum uklonjen
- **titranje pojačanja između okvira** — isto, ne razdvaja

Jedini objektivan trag robotizacije spektralne subtrakcije bio je **stišavanje samog
govora za 8,8 dB**. Ako neki alat stišava govor više od ~3 dB, to je znak da suzbija
govor a ne šum — i to je pouzdaniji pokazatelj od svih spektralnih mjera gore.

---

## 5. Odluka

* **Na epizodi od 2026-07-28 ne radi se čišćenje.** Svaka varijanta gubi više nego
  dobiva; odnos glasa i šuma na udaljenijem tragu (5,7 dB) je ispod granice.
* **Lijek je na snimanju, ne u postu** — 15 cm i zatvoren prozor, vidi `SNIMANJE.md`.
* **Ako se ipak jednom bude čistilo**, prvi izbor je Demucs `--two-stems=vocals`, uz
  svijest da pišti na stalnom šumu poput ventilatora.
* **Ostaje neprobano:** MossFormer2_SE_48K (ClearerVoice-Studio, radi na 48 kHz,
  također maskiranje) i Resemble Enhance — potonji **resintetizira glas**, pa za
  prepoznatljive glasove nije kandidat.
* **Sigurna alternativa koja nije algoritamska:** expander na udaljenijem kanalu koji
  ga spusti dok ta osoba ne govori. Ne dira glas jer se tada ni ne aktivira. Nije
  primijenjeno — čeka odluku.
