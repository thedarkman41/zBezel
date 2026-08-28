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
