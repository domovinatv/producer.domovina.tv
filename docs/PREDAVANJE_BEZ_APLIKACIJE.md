# Predavanje: dva Androida + iPhone kao mikrofon, bez naše aplikacije

Zapisano 2026-10-16. Recept za snimanje izvan studija (predavanje, tribina):
dva Androida na stativu snimaju u **običnoj Camera aplikaciji**, iPhone snima zvuk
u **Voice Memos**. Poslije se tri datoteke poravnaju skriptom. Ne trebaju ni naša
aplikacija, ni relay, ni mreža, ni pljesak.

**Status:** put je isti kao za naše telefone (`scripts/sync_cameras.py` u audio
načinu, bez sidecara), ali **nije isproban baš s Voice Memos `.m4a` i snimkama iz
obične Camera aplikacije**. Isproban je na sintetici i na snimkama naše Android
aplikacije. Prije prvog pravog predavanja: 5 min probe u sobi na ta tri telefona.

## Zašto radi

Svaka kamera ima sliku i zvuk u istoj datoteci, na istom satu, pa njen zvuk
pokazuje gdje je njena slika. `sync_cameras.py` korelira zvuk svake kamere s
masterom (GCC-PHAT, prozori kroz cijelu snimku) i kroz točke provuče pravac
`t_master = a + b · t_kamera`: `a` je pomak, `b` drift kristala telefona. Bez
sidecar JSON-a skripta radi samo po zvuku, a ime kamere uzima iz imena datoteke.

## Na licu mjesta

1. **Voice Memos pokreni prvi, zaustavi zadnji.** Vremenska crta je zvuk s
   iPhonea, a slika prije ili poslije njega se odbaci. Voice Memos radi i sa
   zaključanim ekranom.
2. Androidi na stativu, na punjaču, mikrofon im nije prekriven. Ne stavljati ih
   uz zvučnik ili klimu: kamera mora **čuti predavača**, makar s jekom.
3. Prostor: sat 1080p videa je otprilike 6–10 GB po telefonu.

## Poslije

```bash
python3 scripts/sync_cameras.py \
  --master predavanje.m4a \
  --cameras android1.mp4 android2.mp4 \
  --out ~/predavanje/synced --render --grid
```

Izlaz u `--out`:

| Datoteka | Što je |
|---|---|
| `android1.mov`, `android2.mov` | kamera poravnata na vremensku crtu Voice Memosa, zvuk = iPhone |
| `grid.mp4` | obje kamere u mreži, za provjeru okom |
| `multicam_sync.json` | pomak, drift, `residualRmsMs`, `medianPSR` po kameri |

Dobro poravnanje: `residualRmsMs` < 2 i `medianPSR` > 15 (skripta to označi ✅).
Kamera koja se ne da poravnati prijavi se kao neuspjela, a ostale se obrade.

Zatim: oba `.mov` u DaVinci od nule → ručna montaža → export →
`scripts/youtube_delivery.sh --input <export> --output-dir <mapa>` (glasnoća
−14 LUFS, mp4) → `scripts/prepare_youtube.sh` (naslov, opis, poglavlja iz
transkripta). **Upload na YouTube je ručni**: YouTube API upload ne postoji u kodu.

## Ograničenja

- **Udaljenost je mali pomak.** Kamera 10 m od predavača čuje ga ~29 ms kasnije,
  pa je slika toliko ispred zvuka: ispod jednog framea, u smjeru koji oko ne
  primjećuje. Ako se iPhone nosi uokolo, pomak se mijenja za desetak ms. Vidi se
  kao veći `residualRmsMs`, ali za predavanje je neprimjetno.
- **Izlaz je fiksno 1080p30** (`render(… fps=30)`), bez obzira snima li Android
  4K ili 60 fps. Promjenjiv frame rate Camera aplikacije nije problem, jer skripta
  čita vremena iz datoteke.
- **Camera aplikacije ponekad dijele dugu snimku u više datoteka.** Svaki dio se
  poravna zasebno i postane zaseban trag. Skripta ih ne spaja.
- Sat relaya treba tek kad su kamere desetke metara jedna od druge, kao na
  utakmici (zvuk prijeđe 100 m za ~290 ms). Tada vrijedi `--sync clock` i naša
  aplikacija, vidi [`2026-10-13-multicam.md`](2026-10-13-multicam.md).

## Kad bi trebala naša aplikacija (nije napravljeno)

Varijanta „Androidi preko relaya + iPhone kao mikrofon koji se nosi, sve po
Cloudflare satu“ danas **ne radi**. Fali:

1. **iOS „mikrofon“ način.** `DomovinaKamera` uvijek snima 1080p video + zvuk i u
   pozadini prekida take. Treba način samo za zvuk, sa zaključanim ekranom
   (`UIBackgroundModes: audio`), uz isti sidecar sa satom.
2. **Slika po satu, zvuk s iPhonea.** U `--sync clock` načinu skripta zanemaruje
   master i svaki render nosi vlastiti zvuk. Treba npr. `--sound-from <ime>`:
   sve po satu, zvuk jedne kamere ispod svih, a korelacija zvuka kao provjera.
3. **Obrada bez Studija.** Ručni start na telefonu daje svakom svoj
   `local-…` sessionId, pa snimke završe u različitim mapama u R2 i Post ih ne
   vidi kao jednu sesiju. `finalize_session.sh` očekuje sesiju iz Studija. Treba
   zajednički sessionId za ručni start i jednu naredbu pull → sync → render.
4. iPhone snimanje u našoj aplikaciji još nikad nije provjereno (fali dodir na
   „Dopusti“).

Za studijsku epizodu s telefonima vidi [`PROBA_STUDIO_MULTICAM.md`](PROBA_STUDIO_MULTICAM.md).
