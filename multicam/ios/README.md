# DOMOVINA Kamera (iOS)

iPhone kao dodatna kamera za multicam snimanje. Protokol: `../PROTOCOL.md`.

Telefon snima samostalno (1080p, konstantnih 30 fps, HEVC, zvuk iz mikrofona u
istoj `.mov` datoteci), a nakon stopa uploada snimku i sidecar JSON preko relaya
u R2. Lokalne datoteke ostaju u Documents, vidljive u aplikaciji Datoteke.

## Build i instalacija

```bash
cd multicam/ios
xcodegen generate                       # .xcodeproj se ne commita
xcodebuild -project DomovinaKamera.xcodeproj -scheme DomovinaKamera \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  -allowProvisioningUpdates build
xcrun devicectl list devices
xcrun devicectl device install app --device <ID> build/Build/Products/Debug-iphoneos/DomovinaKamera.app
```

Novi telefon prvo treba registrirati u profilu tima (jednom):
`xcodebuild … -destination "id=<UDID>" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`
(UDID: `xcrun xctrace list devices`). Bez toga instalacija javlja
„This provisioning profile cannot be installed on this device“.

## Spajanje

`node multicam/director.mjs join <ime>` ispiše join URL i QR. Skeniraj QR kamerom
iPhonea (otvara aplikaciju) ili u aplikaciji: ⚙︎ → „Skeniraj QR za spajanje“.
S Maca, bez diranja telefona:

```bash
xcrun devicectl device process launch --terminate-existing --device <ID> \
  --payload-url "$(node multicam/director.mjs join iphone-se2 | head -1)" tv.domovina.multicam
```

Postavke se pamte (ključ u Keychainu), pa se aplikacija nakon toga spaja sama.

**Pri prvom pokretanju na telefonu treba jednom dodirnuti „Dopusti“ za kameru i
mikrofon** — dok se to ne napravi, režija vidi grešku „Čeka dozvolu…“.

## Dijagnostika

Log aplikacije je `Documents/app.log`:

```bash
xcrun devicectl device copy from --device <ID> --domain-type appDataContainer \
  --domain-identifier tv.domovina.multicam --source Documents/app.log --destination app.log
```
