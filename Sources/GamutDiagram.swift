import SwiftUI
import CoreGraphics

/// A CIE 1931 xy chromaticity diagram in the standard form: the visible spectrum
/// filled with its own colours (the "tongue"), the active colour space drawn over
/// it as a white triangle, and its white point marked.
///
/// The tongue is a fixed image (it does not depend on the panel), built once on a
/// background task and cached. The triangle is the colour space in force — the
/// panel's native gamut, or the standard space a calibrated mode emulates — with
/// the native gamut left as a faint dashed outline behind it when they differ.
/// The white point is draggable: its CIE position maps back to RGB gains, so
/// moving it re-balances the panel live (see `onWhite`).
struct GamutDiagram: View {
    /// The triangle drawn boldly — the colour space currently in force.
    let gamut: EDID.ColourPrimaries
    /// The panel's native gamut, drawn as a faint dashed outline behind `gamut`
    /// when a calibrated mode has narrowed the active space. nil to omit it.
    var nativeOutline: EDID.ColourPrimaries? = nil
    /// The white point dot. Two-way so a drag can move it; the parent decides what
    /// it means (write gains, remember an override).
    @Binding var white: EDID.Chromaticity?
    /// Whether the dot can be grabbed and dragged.
    var draggable: Bool = false
    /// Called through a drag with the dot's CIE (x, y); the Bool is true on the
    /// final change (release), false while dragging.
    var onWhite: ((Double, Double, Bool) -> Void)? = nil

    /// Plot bounds. Axes share a scale so the tongue and triangle keep their true
    /// shape rather than stretching to the card.
    static let xMax = 0.75
    static let yMax = 0.85

    @State private var tongue: CGImage?
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let canvas = Canvas { ctx, sz in draw(ctx, sz) }
                .contentShape(Rectangle())
            if draggable {
                canvas.gesture(drag(in: size))
            } else {
                canvas
            }
        }
        .aspectRatio(Self.xMax / Self.yMax, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .task { if tongue == nil { tongue = await Self.tongueImage() } }
    }

    // MARK: Drawing

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        func pt(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x / Self.xMax * size.width,
                    y: size.height - (y / Self.yMax * size.height))
        }

        if let img = tongue {
            ctx.draw(Image(decorative: img, scale: 1),
                     in: CGRect(origin: .zero, size: size))
        }

        // The panel's native gamut, faint and dashed, behind the active space —
        // so a narrowed calibrated mode shows what the panel is giving up.
        if let n = nativeOutline {
            var np = Path()
            np.move(to: pt(n.red.x, n.red.y))
            np.addLine(to: pt(n.green.x, n.green.y))
            np.addLine(to: pt(n.blue.x, n.blue.y))
            np.closeSubpath()
            ctx.stroke(np, with: .color(.white.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // The active colour space, a clean white triangle over the tongue.
        var tri = Path()
        tri.move(to: pt(gamut.red.x, gamut.red.y))
        tri.addLine(to: pt(gamut.green.x, gamut.green.y))
        tri.addLine(to: pt(gamut.blue.x, gamut.blue.y))
        tri.closeSubpath()
        ctx.stroke(tri, with: .color(.white.opacity(0.95)), lineWidth: 1.8)

        // White point.
        if let w = white {
            let c = pt(w.x, w.y)
            if dragging {
                var cross = Path()
                cross.move(to: CGPoint(x: c.x - 10, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 10, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - 10)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 10))
                ctx.stroke(cross, with: .color(.white.opacity(0.5)), lineWidth: 0.8)
            }
            let r: CGFloat = draggable ? 4.5 : 3.5
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(dot, with: .color(.white))
            ctx.stroke(dot, with: .color(.black.opacity(0.6)), lineWidth: 1.2)
            if draggable {
                let rr = r + 3
                let ring = Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                ctx.stroke(ring, with: .color(.white.opacity(dragging ? 0.6 : 0.35)), lineWidth: 1)
            }
        }
    }

    // MARK: Dragging the white point

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if !dragging {
                    // Only begin if the grab landed near the dot.
                    if let w = white {
                        let dot = CGPoint(x: w.x / Self.xMax * size.width,
                                          y: size.height - w.y / Self.yMax * size.height)
                        let d = hypot(v.startLocation.x - dot.x, v.startLocation.y - dot.y)
                        guard d <= 34 else { return }
                    }
                    dragging = true
                }
                let (x, y) = clamp(loc: v.location, in: size)
                white = EDID.Chromaticity(x: x, y: y)
                onWhite?(x, y, false)
            }
            .onEnded { v in
                guard dragging else { return }
                dragging = false
                let (x, y) = clamp(loc: v.location, in: size)
                white = EDID.Chromaticity(x: x, y: y)
                onWhite?(x, y, true)
            }
    }

    /// Screen point → CIE (x, y), clamped to a sane white-balance box around the
    /// daylight locus so a drag cannot land on an absurd, unreachable white.
    private func clamp(loc p: CGPoint, in size: CGSize) -> (Double, Double) {
        let x = Double(p.x / size.width) * Self.xMax
        let y = Double(1 - p.y / size.height) * Self.yMax
        return (min(max(x, 0.24), 0.40), min(max(y, 0.24), 0.42))
    }

    // MARK: Tongue rendering

    /// The coloured tongue, built off the main thread and memoised so the Color
    /// tab never stalls on it. Returns immediately once cached.
    static func tongueImage() async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            TongueBox(image: TongueHolder.shared.get())
        }.value.image
    }

    /// Fill every pixel whose chromaticity lies inside the spectral locus with the
    /// colour of that chromaticity: xy → XYZ (Y = 1) → linear sRGB, negatives
    /// clamped and normalised to full brightness, then sRGB gamma. The edge is
    /// anti-aliased by 2×2 coverage sampling so it reads soft, not stair-stepped;
    /// outside the locus stays transparent.
    static func renderTongue(width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        func gammaEncode(_ c: Double) -> Double {
            c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        // Sub-pixel offsets for the coverage estimate.
        let sub: [(Double, Double)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]

        for py in 0..<height {
            for px in 0..<width {
                // Edge coverage: how many of the 2×2 sub-samples fall inside.
                var cov = 0
                for (sx, sy) in sub {
                    let x = (Double(px) + sx) / Double(width) * xMax
                    let y = (Double(height) - (Double(py) + sy)) / Double(height) * yMax
                    if y > 0.0005, pointInLocus(x, y) { cov += 1 }
                }
                guard cov > 0 else { continue }
                let alpha = Double(cov) / 4.0

                // Colour at the pixel centre.
                let x = (Double(px) + 0.5) / Double(width) * xMax
                let y = (Double(height) - (Double(py) + 0.5)) / Double(height) * yMax
                guard y > 0 else { continue }
                let capX = x / y, capZ = (1 - x - y) / y
                var r =  3.2406 * capX - 1.5372 - 0.4986 * capZ
                var g = -0.9689 * capX + 1.8758 + 0.0415 * capZ
                var b =  0.0557 * capX - 0.2040 + 1.0570 * capZ
                r = max(0, r); g = max(0, g); b = max(0, b)
                let m = max(r, g, b)
                guard m > 0 else { continue }
                r /= m; g /= m; b /= m

                // premultipliedLast: store colour scaled by coverage.
                let i = py * bytesPerRow + px * 4
                data[i + 0] = UInt8(max(0, min(255, gammaEncode(r) * 255 * alpha)))
                data[i + 1] = UInt8(max(0, min(255, gammaEncode(g) * 255 * alpha)))
                data[i + 2] = UInt8(max(0, min(255, gammaEncode(b) * 255 * alpha)))
                data[i + 3] = UInt8(max(0, min(255, 255 * alpha)))
            }
        }

        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Ray-cast point-in-polygon against the (closed) spectral locus.
    static func pointInLocus(_ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = locus.count - 1
        for i in 0..<locus.count {
            let (xi, yi) = locus[i]
            let (xj, yj) = locus[j]
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// CIE 1931 spectral locus, densely enough sampled that the tongue's edge
    /// reads as a smooth curve rather than a polygon.
    static let locus: [(Double, Double)] = [
        (0.1741, 0.0050), (0.1740, 0.0050), (0.1738, 0.0049), (0.1736, 0.0049),
        (0.1733, 0.0048), (0.1730, 0.0048), (0.1726, 0.0048), (0.1721, 0.0048),
        (0.1714, 0.0051), (0.1703, 0.0058), (0.1689, 0.0069), (0.1669, 0.0086),
        (0.1644, 0.0109), (0.1611, 0.0138), (0.1566, 0.0177), (0.1510, 0.0227),
        (0.1440, 0.0297), (0.1355, 0.0399), (0.1241, 0.0578), (0.1096, 0.0868),
        (0.0913, 0.1327), (0.0687, 0.2007), (0.0454, 0.2950), (0.0235, 0.4127),
        (0.0082, 0.5384), (0.0039, 0.6548), (0.0139, 0.7502), (0.0389, 0.8120),
        (0.0743, 0.8338), (0.1142, 0.8262), (0.1547, 0.8059), (0.1929, 0.7816),
        (0.2296, 0.7543), (0.2658, 0.7243), (0.3016, 0.6923), (0.3373, 0.6589),
        (0.3731, 0.6245), (0.4087, 0.5896), (0.4441, 0.5547), (0.4788, 0.5202),
        (0.5125, 0.4866), (0.5448, 0.4544), (0.5752, 0.4242), (0.6029, 0.3965),
        (0.6270, 0.3725), (0.6482, 0.3514), (0.6658, 0.3340), (0.6801, 0.3197),
        (0.6915, 0.3083), (0.7006, 0.2993), (0.7079, 0.2920), (0.7140, 0.2859),
        (0.7190, 0.2809), (0.7230, 0.2770), (0.7260, 0.2740), (0.7300, 0.2700),
        (0.7334, 0.2666), (0.7347, 0.2653),
    ]
}

/// CGImage is not `Sendable`; box it to hand the built tongue back from a
/// detached task without tripping strict-concurrency checks.
private struct TongueBox: @unchecked Sendable { let image: CGImage? }

/// Builds the tongue once, under a lock, and holds it for the app's life.
private final class TongueHolder: @unchecked Sendable {
    static let shared = TongueHolder()
    private let lock = NSLock()
    private var image: CGImage?
    func get() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        if let image { return image }
        let img = GamutDiagram.renderTongue(width: 512, height: 580)
        image = img
        return img
    }
}
