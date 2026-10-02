import Foundation

/// Minimal but correct E-EDID 1.4 parser.
///
/// Used for two things: naming the display reliably across reconnects, and
/// reading the panel's own preferred (native) timing, which is what "Preferred
/// Resolution" means on the monitor side.
struct EDID {
    var raw: [UInt8]

    struct DetailedTiming {
        var pixelClockKHz: Int
        var hActive: Int
        var vActive: Int
        var refreshHz: Double
        var isPreferred: Bool
        var description: String {
            String(format: "%d × %d @ %.2f Hz", hActive, vActive, refreshHz)
        }
    }

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 128 else { return nil }
        let header: [UInt8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
        guard Array(bytes[0..<8]) == header else { return nil }
        raw = bytes
    }

    /// Three-letter PnP manufacturer ID, e.g. "HWP" for HP.
    var manufacturerID: String {
        let v = (UInt16(raw[8]) << 8) | UInt16(raw[9])
        let a = UInt8((v >> 10) & 0x1F), b = UInt8((v >> 5) & 0x1F), c = UInt8(v & 0x1F)
        func letter(_ x: UInt8) -> Character {
            guard x >= 1, x <= 26 else { return "?" }
            return Character(UnicodeScalar(UInt8(64) + x))
        }
        return String([letter(a), letter(b), letter(c)])
    }

    var productCode: UInt16 { UInt16(raw[10]) | (UInt16(raw[11]) << 8) }
    var serialNumber: UInt32 {
        UInt32(raw[12]) | (UInt32(raw[13]) << 8) | (UInt32(raw[14]) << 16) | (UInt32(raw[15]) << 24)
    }
    var manufactureWeek: Int { Int(raw[16]) }
    var manufactureYear: Int { Int(raw[17]) + 1990 }
    var version: String { "\(raw[18]).\(raw[19])" }

    var isDigital: Bool { raw[20] & 0x80 != 0 }
    var bitDepth: Int? {
        guard isDigital else { return nil }
        let code = (raw[20] >> 4) & 0x07
        let table = [0: nil, 1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16]
        return table[Int(code)] ?? nil
    }
    var digitalInterface: String {
        guard isDigital else { return "Analogue" }
        switch raw[20] & 0x0F {
        case 1: return "DVI"
        case 2: return "HDMI-a"
        case 3: return "HDMI-b"
        case 4: return "MDDI"
        case 5: return "DisplayPort"
        default: return "Digital"
        }
    }

    var screenSizeCM: (width: Int, height: Int) { (Int(raw[21]), Int(raw[22])) }
    var diagonalInches: Double {
        let (w, h) = screenSizeCM
        guard w > 0, h > 0 else { return 0 }
        return (Double(w * w + h * h)).squareRoot() / 2.54
    }
    var gamma: Double? { raw[23] == 0xFF ? nil : (Double(raw[23]) + 100) / 100 }

    // MARK: Color (chromaticity block, bytes 25–34)

    /// A CIE 1931 (x, y) chromaticity point at the EDID's 10-bit precision.
    struct Chromaticity: Equatable {
        var x: Double
        var y: Double
        var label: String { String(format: "%.4f, %.4f", x, y) }
    }

    /// The panel's own color primaries and white point, decoded from the EDID
    /// chromaticity block. Each coordinate is 10 bits: the high 8 in its own byte
    /// (27–34), the low 2 packed two-per-coordinate into bytes 25 and 26.
    struct ColorPrimaries: Equatable {
        var red: Chromaticity
        var green: Chromaticity
        var blue: Chromaticity
        var white: Chromaticity
    }

    var colorPrimaries: ColorPrimaries {
        func coord(_ hi: Int, _ lowByte: Int, _ shift: Int) -> Double {
            let v = (Int(raw[hi]) << 2) | ((Int(raw[lowByte]) >> shift) & 0x3)
            return Double(v) / 1024.0
        }
        return ColorPrimaries(
            red:   Chromaticity(x: coord(27, 25, 6), y: coord(28, 25, 4)),
            green: Chromaticity(x: coord(29, 25, 2), y: coord(30, 25, 0)),
            blue:  Chromaticity(x: coord(31, 26, 6), y: coord(32, 26, 4)),
            white: Chromaticity(x: coord(33, 26, 2), y: coord(34, 26, 0)))
    }

    /// The panel's native white point (CIE 1931 x, y). nil if the block is blank
    /// (an EDID that declined to declare one — all zeros).
    var nativeWhitePoint: Chromaticity? {
        let w = colorPrimaries.white
        return (w.x == 0 && w.y == 0) ? nil : w
    }

    /// Correlated color temperature of the native white point, via McCamy's
    /// approximation, rounded to 50 K. nil when the point is far enough off the
    /// Planckian locus that the number would be meaningless.
    var whitePointCCT: Int? {
        guard let w = nativeWhitePoint else { return nil }
        return Self.cct(x: w.x, y: w.y)
    }

    /// The standard illuminant the native white point sits closest to, if within
    /// a small tolerance — the name a person recognizes (D65, D50, DCI, …).
    var whitePointIlluminant: String? {
        guard let w = nativeWhitePoint else { return nil }
        return Self.illuminant(x: w.x, y: w.y)
    }

    /// Correlated color temperature of any CIE (x, y) via McCamy's approximation,
    /// rounded to 50 K — for the *active* white, which can be a color space's
    /// target or a dragged custom balance, not only the panel's declared white.
    static func cct(x: Double, y: Double) -> Int? {
        guard y != 0.1858 else { return nil }
        let n = (x - 0.3320) / (0.1858 - y)
        let cct = 449 * n * n * n + 3525 * n * n + 6823.3 * n + 5520.33
        guard cct > 1000, cct < 25000 else { return nil }
        return Int((cct / 50).rounded() * 50)
    }

    /// The standard illuminant a CIE (x, y) sits closest to, within tolerance.
    static func illuminant(x: Double, y: Double) -> String? {
        let standards: [(String, Double, Double)] = [
            ("D65", 0.3127, 0.3290), ("D50", 0.3457, 0.3585),
            ("D55", 0.3324, 0.3474), ("D75", 0.2990, 0.3149),
            ("DCI", 0.3140, 0.3510),
        ]
        return standards.first { abs(x - $0.1) < 0.005 && abs(y - $0.2) < 0.005 }?.0
    }

    // MARK: Color capabilities (feature-support byte 24)

    /// Whether the panel declares sRGB as its default color space (a narrow-gamut
    /// panel usually does; a wide-gamut one says no, as this one does).
    var defaultsToSRGB: Bool { isDigital && (raw[24] & 0x04 != 0) }

    /// The pixel encodings the digital interface declares. RGB 4:4:4 is always
    /// present; the two bits say whether YCbCr is offered too.
    var pixelEncodings: [String]? {
        guard isDigital else { return nil }
        var out = ["RGB 4:4:4"]
        switch (raw[24] >> 3) & 0x3 {
        case 1: out.append("YCbCr 4:4:4")
        case 2: out.append("YCbCr 4:2:2")
        case 3: out.append(contentsOf: ["YCbCr 4:4:4", "YCbCr 4:2:2"])
        default: break
        }
        return out
    }

    // MARK: Gamut coverage

    /// A named reference gamut, by its RGB primaries.
    struct ReferenceGamut { let name: String; let red, green, blue: Chromaticity }
    static let referenceGamuts: [ReferenceGamut] = [
        .init(name: "sRGB",      red: .init(x: 0.640, y: 0.330), green: .init(x: 0.300, y: 0.600), blue: .init(x: 0.150, y: 0.060)),
        .init(name: "DCI-P3",    red: .init(x: 0.680, y: 0.320), green: .init(x: 0.265, y: 0.690), blue: .init(x: 0.150, y: 0.060)),
        .init(name: "BT.709",    red: .init(x: 0.640, y: 0.330), green: .init(x: 0.300, y: 0.600), blue: .init(x: 0.150, y: 0.060)),
        .init(name: "Adobe RGB", red: .init(x: 0.640, y: 0.330), green: .init(x: 0.210, y: 0.710), blue: .init(x: 0.150, y: 0.060)),
    ]

    /// The share of a reference gamut the panel covers, as a percentage: the area
    /// the two triangles have in common over the reference triangle's area. Over
    /// 100 is not possible by this measure (it is coverage, not relative volume);
    /// a panel wider than the reference still only "covers" 100% of it.
    func coverage(of ref: ReferenceGamut) -> Int {
        let p = colorPrimaries
        let panel = [(p.red.x, p.red.y), (p.green.x, p.green.y), (p.blue.x, p.blue.y)]
        let target = [(ref.red.x, ref.red.y), (ref.green.x, ref.green.y), (ref.blue.x, ref.blue.y)]
        let targetArea = Self.triangleArea(target)
        guard targetArea > 0 else { return 0 }
        let shared = Self.triangleArea(Self.clip(panel, to: target))
        return Int((min(shared / targetArea, 1) * 100).rounded())
    }

    private static func triangleArea(_ poly: [(Double, Double)]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var a = 0.0
        for i in 0..<poly.count {
            let j = (i + 1) % poly.count
            a += poly[i].0 * poly[j].1 - poly[j].0 * poly[i].1
        }
        return abs(a) / 2
    }

    /// Sutherland–Hodgman: clip convex `subject` against convex `clipPoly`.
    private static func clip(_ subject: [(Double, Double)], to clipPoly: [(Double, Double)]) -> [(Double, Double)] {
        // Normalize the clip polygon to counter-clockwise so "inside" is a
        // consistent sign whichever way the primaries were listed.
        var signed = 0.0
        for i in 0..<clipPoly.count {
            let j = (i + 1) % clipPoly.count
            signed += clipPoly[i].0 * clipPoly[j].1 - clipPoly[j].0 * clipPoly[i].1
        }
        let cp = signed < 0 ? clipPoly.reversed().map { $0 } : clipPoly
        var out = subject
        for i in 0..<cp.count {
            let a = cp[i], b = cp[(i + 1) % cp.count]
            let input = out
            out = []
            if input.isEmpty { break }
            func side(_ p: (Double, Double)) -> Double {
                (b.0 - a.0) * (p.1 - a.1) - (b.1 - a.1) * (p.0 - a.0)
            }
            func crossing(_ p: (Double, Double), _ q: (Double, Double)) -> (Double, Double) {
                let sp = side(p), sq = side(q)
                let t = sp / (sp - sq)
                return (p.0 + t * (q.0 - p.0), p.1 + t * (q.1 - p.1))
            }
            var prev = input.last!
            for cur in input {
                let curIn = side(cur) >= 0, prevIn = side(prev) >= 0
                if curIn {
                    if !prevIn { out.append(crossing(prev, cur)) }
                    out.append(cur)
                } else if prevIn {
                    out.append(crossing(prev, cur))
                }
                prev = cur
            }
        }
        return out
    }

    var extensionBlockCount: Int { Int(raw[126]) }

    // MARK: Descriptors

    private func descriptorBlocks() -> [ArraySlice<UInt8>] {
        stride(from: 54, to: 126, by: 18).map { raw[$0..<($0 + 18)] }
    }

    private func stringDescriptor(tag: UInt8) -> String? {
        for d in descriptorBlocks() {
            let b = Array(d)
            guard b[0] == 0, b[1] == 0, b[2] == 0, b[3] == tag else { continue }
            let text = b[5..<18]
                .prefix { $0 != 0x0A }
                .map { Character(UnicodeScalar($0)) }
            return String(text).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    var monitorName: String? { stringDescriptor(tag: 0xFC) }
    var serialString: String? { stringDescriptor(tag: 0xFF) }

    /// Detailed timing descriptors. The first one is the panel's preferred timing.
    var detailedTimings: [DetailedTiming] {
        var out: [DetailedTiming] = []
        for (index, block) in descriptorBlocks().enumerated() {
            let b = Array(block)
            let clock = Int(b[0]) | (Int(b[1]) << 8)
            guard clock != 0 else { continue }        // 0 means it's a text descriptor

            let hActive = Int(b[2]) | ((Int(b[4]) & 0xF0) << 4)
            let hBlank  = Int(b[3]) | ((Int(b[4]) & 0x0F) << 8)
            let vActive = Int(b[5]) | ((Int(b[7]) & 0xF0) << 4)
            let vBlank  = Int(b[6]) | ((Int(b[7]) & 0x0F) << 8)

            let hTotal = hActive + hBlank
            let vTotal = vActive + vBlank
            guard hTotal > 0, vTotal > 0 else { continue }

            let pixelClockHz = Double(clock) * 10_000.0
            let refresh = pixelClockHz / Double(hTotal * vTotal)

            out.append(DetailedTiming(pixelClockKHz: clock * 10,
                                      hActive: hActive, vActive: vActive,
                                      refreshHz: refresh,
                                      isPreferred: index == 0))
        }
        return out
    }

    var preferredTiming: DetailedTiming? { detailedTimings.first { $0.isPreferred } }

    var displayName: String {
        monitorName ?? "\(manufacturerID) \(String(format: "%04X", productCode))"
    }
}
