# Proba prije prve epizode s telefonima

Plan od 2026-10-15. Cijeli lanac postoji u `main`, Studio build 39, a testovi
(`test_sync_cameras.sh`, `test_finalize.sh`) prolaze. **Ovo još nikad nije
pokrenuto zajedno**: pravi telefon kojim upravlja Studio i pravi RØDE miks kao
master. Zato prvo jedna proba od 10–15 min, točno u postavu za epizodu.

## Postav

- 2× PodMic → RØDE Connect → Studio snima `RØDE Connect Stream`
- GH5 → HDMI → Elgato 4K X (proxy), a glavna snimka je SD kartica
- 2× Android na stativu (Moto Edge 30 Ultra `ZY22G9DDR3`, Moto G86 `ZY32M4Q2GJ`),
  aplikacija `tv.domovina.multicam`, spojeni na relay (QR iz Postavke → Telefoni)

## Prije Snimaj

1. RØDE Connect otvoren **i na Rec**. Bez toga je `Stream` digitalna tišina.
2. Elgato Camera Hub zatvoren, ulaz zvuka na Elgatu na **HDMI** (ne Analog).
3. Telefoni na punjaču, mikrofon nije prekriven, oba vidljiva u panelu Telefoni.
4. Slobodan prostor: `/Volumes/DOMOVINA2TB` i na telefonima (~7 GB/h po telefonu).

## Tijek

1. Snimaj u Studiju. Telefoni prelaze u „snima“ unutar ~2 s.
2. Pljesak jednom, blizu GH5 i u kadru oba telefona (kontrola, ne treba za sync).
3. 10–15 min normalnog razgovora.
4. Zaustavi. Pričekaj „u R2“ za oba telefona.
5. Post → Telefoni → preuzmi, pa finalize (sam nađe `<sesija>/cameras/`).

## Što provjeriti

- `cameras/multicam_sync.json`: po telefonu `residualRmsMs` < 2, `medianPSR` > 15,
  `clockVsAudioMs` unutar ~±20 ms.
- `cameras/grid.mp4`: pljesak na istom frameu u svim kamerama.
- `<session>_final.mov` (GH5) i `cameras/<telefon>.mov` počinju na 0 miksa i
  slažu se u DaVinciju bez pomicanja.

## Poznato prije probe

- Render telefona je fiksno **1080p30** (`scripts/sync_cameras.py`, `render(… fps=30)`).
  Ako GH5 snima 25p, timeline miješa 25 i 30 fps. Sinkronizacija ostaje točna, ali je
  pretvorba vidljiva u pokretu. Treba uskladiti s fps-om GH5.
- G86 snima 29,97 fps, Edge 30 fps. Post čita vrijeme iz datoteke, ne pretpostavlja 30.
- Duge snimke (60+ min) na telefonima nisu isprobane (baterija, toplina).
- FCPXML i automatski rez na govornika ne postoje. Montaža je ručna.

Vidi [`2026-10-13-multicam.md`](2026-10-13-multicam.md) (Otvoreno, stavke 2, 4, 5, 7).
