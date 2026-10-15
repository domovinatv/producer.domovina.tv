import SwiftUI

/// The Domovina palette, straight from the mediakit.
///
/// Both colours come off the Croatian flag and are the only two the brand
/// system uses; everything else in the logo is white.
enum Brand {
    static let red = Color(red: 1, green: 0, blue: 0)
    static let blue = Color(red: 0, green: 47 / 255, blue: 108 / 255)
}

/// The DOMOVINA Studio logo, drawn rather than loaded.
///
/// This is a transcription of `domovina_studio_logo_square.svg` in the
/// mediakit repo — the flag-filled "D", the white counter, and the studio
/// microphone that marks this product as the one that *makes* the recording.
/// Drawing it keeps the header sharp at any size and, unlike a bundled PNG,
/// works identically under `swift run` and inside the .app bundle.
///
/// Coordinates below are the SVG's own 512×512 design space, scaled at draw
/// time, so the two files can be diffed against each other by eye.
struct BrandMark: View {
    var size: CGFloat = 32

    private static let design: CGFloat = 512

    var body: some View {
        Canvas { context, _ in
            let s = size / Self.design
            let scale = CGAffineTransform(scaleX: s, y: s)
            func scaled(_ path: Path) -> Path { path.applying(scale) }

            // Rounded white plate.
            context.fill(
                scaled(Path(roundedRect: CGRect(x: 0, y: 0, width: 512, height: 512), cornerRadius: 32)),
                with: .color(.white)
            )

            // The "D", filled with the flag. The SVG gradient is in object
            // bounding box units, so it spans the glyph's own 64…448, not the
            // full canvas — getting this wrong shifts the stripes visibly.
            var d = Path()
            d.move(to: CGPoint(x: 72, y: 64))
            d.addLine(to: CGPoint(x: 248, y: 64))
            d.addCurve(to: CGPoint(x: 440, y: 256),
                       control1: CGPoint(x: 354.071, y: 64),
                       control2: CGPoint(x: 440, y: 149.929))
            d.addCurve(to: CGPoint(x: 248, y: 448),
                       control1: CGPoint(x: 440, y: 362.071),
                       control2: CGPoint(x: 354.071, y: 448))
            d.addLine(to: CGPoint(x: 72, y: 448))
            d.closeSubpath()

            context.fill(scaled(d), with: .linearGradient(
                Gradient(stops: [
                    .init(color: Brand.red, location: 0),
                    .init(color: Brand.red, location: 1.0 / 3),
                    .init(color: .white, location: 1.0 / 3),
                    .init(color: .white, location: 2.0 / 3),
                    .init(color: Brand.blue, location: 2.0 / 3),
                    .init(color: Brand.blue, location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: 64 * s),
                endPoint: CGPoint(x: 0, y: 448 * s)
            ))

            // The counter: a smaller white "D" that isolates the symbol.
            var counter = Path()
            counter.move(to: CGPoint(x: 168, y: 160))
            counter.addLine(to: CGPoint(x: 248, y: 160))
            counter.addCurve(to: CGPoint(x: 344, y: 256),
                             control1: CGPoint(x: 301.019, y: 160),
                             control2: CGPoint(x: 344, y: 202.981))
            counter.addCurve(to: CGPoint(x: 248, y: 352),
                             control1: CGPoint(x: 344, y: 309.019),
                             control2: CGPoint(x: 301.019, y: 352))
            counter.addLine(to: CGPoint(x: 168, y: 352))
            counter.closeSubpath()
            context.fill(scaled(counter), with: .color(.white))

            // Microphone capsule.
            context.fill(
                scaled(Path(roundedRect: CGRect(x: 232, y: 182, width: 48, height: 92), cornerRadius: 24)),
                with: .color(Brand.blue)
            )

            // Grille. Deliberately fine — it dissolves into a solid capsule at
            // toolbar sizes instead of turning to mush.
            for y in [196.0, 208.0, 220.0] {
                context.fill(
                    scaled(Path(roundedRect: CGRect(x: 242, y: y, width: 28, height: 4), cornerRadius: 2)),
                    with: .color(.white)
                )
            }

            // Shock-mount cradle: a half-circle hanging below the capsule.
            var cradle = Path()
            cradle.move(to: CGPoint(x: 210, y: 242))
            cradle.addLine(to: CGPoint(x: 210, y: 256))
            cradle.addArc(center: CGPoint(x: 256, y: 256), radius: 46,
                          startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            cradle.addLine(to: CGPoint(x: 302, y: 242))
            context.stroke(scaled(cradle), with: .color(Brand.blue),
                           style: StrokeStyle(lineWidth: 13 * s, lineCap: .round))

            // Stand and base.
            context.fill(
                scaled(Path(CGRect(x: 249, y: 298, width: 14, height: 26))),
                with: .color(Brand.blue)
            )
            context.fill(
                scaled(Path(roundedRect: CGRect(x: 216, y: 320, width: 80, height: 15), cornerRadius: 7.5)),
                with: .color(Brand.blue)
            )
        }
        .frame(width: size, height: size)
        .accessibilityLabel("DOMOVINA Studio")
    }
}
