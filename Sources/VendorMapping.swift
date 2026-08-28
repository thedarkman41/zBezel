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
            return ["Off", "Picture in Picture", "Picture beside Picture"]
        }
    }

    var isToggle: Bool { self == .autoSwitch || self == .dpHotPlugDetection }
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

struct VendorMap: Codable, Equatable {
    var bindings: [String: VendorBinding] = [:]

    subscript(control: VendorControl) -> VendorBinding? {
        get { bindings[control.rawValue] }
        set { bindings[control.rawValue] = newValue }
    }

    static let storageKey = "vendorMap"

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
    var id: UInt8 { code }

    var description: String {
        String(format: "0x%02X: %d → %d", code, before, after)
    }
    /// HP's sub-addressed codes carry a selector in the high byte.
    var decomposed: String? {
        guard HPProfile.subAddressedCodes.contains(code) else { return nil }
        return String(format: "sub 0x%02X: 0x%02X → 0x%02X",
                      after >> 8, before & 0xFF, after & 0xFF)
    }
}
