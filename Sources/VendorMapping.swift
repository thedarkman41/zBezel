import Foundation

/// The controls HP exposes that the MCCS standard does not define.
///
/// MCCS reserves 0xE0–0xFF for the manufacturer and explicitly places those codes
/// outside the standard, so no document — free or paid — says which code drives
/// which control. They can only be found by changing one setting and seeing what
/// moved. HP also multiplexes several settings behind a single code, so sweeping
/// code numbers finds nothing; the values carry the meaning.
enum VendorControl: String, CaseIterable, Codable, Identifiable {
    case autoSwitch          = "Auto Switch"
    case dpHotPlugDetection  = "DisplayPort Hot Plug Detection"
    case displayPortVersion  = "DisplayPort Version"
    case usbCConfiguration   = "USB-C Configuration"
    case pictureInPicture    = "Picture in Picture"

    var id: String { rawValue }

    /// The option labels HP's own panel shows, in order.
    var options: [String] {
        switch self {
        case .autoSwitch, .dpHotPlugDetection:
            return ["Off", "On"]
        case .displayPortVersion:
            return ["DisplayPort 1.1", "DisplayPort 1.2"]
        case .usbCConfiguration:
            return ["3840 × 2160 30Hz + USB 3.0", "3840 × 2160 60Hz + USB 2.0"]
        case .pictureInPicture:
            // Two states, not three. The Z27k G3's own OSD offers only
            // picture-in-picture and single-screen — there is no side-by-side
            // mode on this panel, and offering a third option that the hardware
            // cannot enter is how a control ends up silently doing nothing.
            return ["Off", "On"]
        }
    }

    var isToggle: Bool {
        self == .autoSwitch || self == .dpHotPlugDetection || self == .pictureInPicture
    }
}

/// A discovered binding from a control to the VCP code that drives it.
struct VendorBinding: Codable, Equatable {
    var code: UInt8
    /// Value to write for each option, in the same order as `VendorControl.options`.
    var optionValues: [UInt16]
    /// How the binding was established, shown so a guess is never mistaken for a fact.
    var evidence: String

    /// HP fits more settings than MCCS's 32 vendor codes allow by sub-addressing
    /// inside one code: value = (selector << 8) | setting. Such a binding cannot
    /// be read back with a plain read.
    var isSubAddressed: Bool { optionValues.contains { $0 > 0xFF } }
    var selector: UInt8? {
        guard isSubAddressed, let first = optionValues.first else { return nil }
        return UInt8(first >> 8)
    }

    func value(forOptionAt index: Int) -> UInt16? {
        index < optionValues.count ? optionValues[index] : nil
    }
    func optionIndex(forValue value: UInt16) -> Int? {
        optionValues.firstIndex(of: value)
    }
}

/// What the panel last said about a sub-addressed control, and how much that is
/// worth.
///
/// These settings live behind 0xE1, which cannot be read directly: a read of it
/// returns whichever sub-selector the monitor's rotation lands on, and the one
/// you want may take hundreds of reads to appear — or not appear at all. So a
/// reading is either something the panel actually offered up (`confirmed`) or
/// the value this app last wrote or last saw, carried forward. Both are worth
/// showing; only one is worth showing without a caveat.
struct VendorReading: Codable, Equatable {
    var value: UInt16
    var takenAt: Date
    var confirmed: Bool
}

struct VendorMap: Codable, Equatable {
    var bindings: [String: VendorBinding] = [:]

    subscript(control: VendorControl) -> VendorBinding? {
        get { bindings[control.rawValue] }
        set { bindings[control.rawValue] = newValue }
    }

    static let storageKey = "vendorMap"

    /// Bindings already established on the HP Z-series G3 panels.
    ///
    /// These were found the only way they can be — change one setting, see what
    /// moved, then write the value back and confirm the panel obeys. Shipping
    /// them means a fresh install is not asked to repeat an hour of differential
    /// probing to reach a result that is already known.
    ///
    /// Applied only when the attached panel matches the family, and never over
    /// a binding the user has discovered themselves.
    static let knownZSeries: [VendorControl: VendorBinding] = [
        .autoSwitch: VendorBinding(
            code: 0xE6, optionValues: [0x0000, 0x0001],
            evidence: "toggled 1->0 and 0->1 in HP Display Center"),
        .dpHotPlugDetection: VendorBinding(
            code: 0xE7, optionValues: [0x0000, 0x0001],
            evidence: "toggled 1->0 then 0->1 in one pass"),
        .displayPortVersion: VendorBinding(
            code: 0xE1, optionValues: [0x3500, 0x3501],
            evidence: "0xE1 sub 0x35: 0x00 on 1.1, 0x01 on 1.2; writing 0x3501 switched the panel"),
        .usbCConfiguration: VendorBinding(
            code: 0xE1, optionValues: [0x3901, 0x3900],
            evidence: "0xE1 sub 0x39: 0x01 on 30Hz+USB3.0, 0x00 on 60Hz+USB2.0"),
        .pictureInPicture: VendorBinding(
            code: 0xE1, optionValues: [0x1100, 0x1101],
            evidence: "0xE1 sub 0x11: 0 off, 1 on. Found by sampling the selector map in "
                    + "both states — every other selector held its value. Nothing changed in "
                    + "any plain vendor code. Writing 0x1101 then 0x1100 switched the panel "
                    + "and back, confirmed on screen."),
    ]

    /// Fill in anything not already known, without disturbing what is.
    mutating func seedKnownIfMissing() {
        for (control, binding) in VendorMap.knownZSeries where bindings[control.rawValue] == nil {
            bindings[control.rawValue] = binding
        }
    }

    static func load() -> VendorMap {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(VendorMap.self, from: data)
        else { return VendorMap() }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

/// One code that moved between two readings.
struct VendorChange: Identifiable, Equatable {
    let code: UInt8
    let before: UInt16
    let after: UInt16
    /// Set for a sub-addressed code: WHICH setting behind that code moved.
    ///
    /// Previously the selector was taken from the high byte of the later reading
    /// and applied to both. That is wrong whenever the two readings are different
    /// sub-selectors, which for 0xE1 is most of the time — a plain read of it
    /// returns whichever one the monitor's rotation happens to land on. Every
    /// comparison therefore reported a change, and the change it printed was two
    /// unrelated settings subtracted from each other.
    let selector: UInt8?

    var id: String {
        selector.map { String(format: "%02X.%02X", code, $0) }
            ?? String(format: "%02X", code)
    }

    var description: String {
        guard let selector else {
            return String(format: "0x%02X: %d → %d", code, before, after)
        }
        return String(format: "0x%02X sub 0x%02X: %d → %d", code, selector, before, after)
    }

    var decomposed: String? {
        guard selector != nil else { return nil }
        return String(format: "0x%02X → 0x%02X", before & 0xFF, after & 0xFF)
    }
}
