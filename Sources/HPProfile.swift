import Foundation

/// Names for values this specific monitor family uses, where the public MCCS
/// tables are wrong, silent, or have been extended by HP.
///
/// Everything marked `confirmed` was established by reading the panel, not by
/// assumption. Everything else is deliberately left as a raw value rather than
/// guessed at — a wrong label is worse than an honest hex number.
enum HPProfile {

    /// True when the attached panel looks like an HP Z-series G3.
    static func matches(_ capabilities: Capabilities?) -> Bool {
        guard let model = capabilities?.model?.uppercased() else { return false }
        return model.contains("Z27K") || model.contains("Z27U")
            || model.contains("Z24U") || model.contains("Z27Q")
    }

    /// Input Select (0x60).
    ///
    /// 0x0F and 0x11 are the standard MCCS assignments. 0x13 is confirmed as the
    /// USB-C input: it was the live value while the panel was driven over USB-C.
    /// The monitor also declares 0x21, 0x2F and 0x3D. There is no matching socket
    /// on the back of a Z27k G3 — most likely they belong to other models sharing
    /// this firmware — so they are hidden entirely rather than offered as inputs
    /// that would only blank the screen.
    static let inputNames: [UInt16: String] = [
        0x0F: "DisplayPort",
        0x11: "HDMI",
        0x13: "USB-C1 Video",
    ]

    static func inputLabel(_ value: UInt16) -> String {
        inputNames[value] ?? String(format: "Input 0x%02X", value)
    }

    static func isIdentifiedInput(_ value: UInt16) -> Bool { inputNames[value] != nil }

    /// Codes whose MCCS-standard value labels do not apply to this panel because
    /// HP extended the enumeration well past the standard's range. Showing the
    /// standard names for these would be actively misleading.
    static let extendedByVendor: Set<UInt8> = [0x14]

    /// Codes whose capabilities entry does not describe the values it accepts.
    ///
    /// 0xDC is declared as `DC(00(00 01 02 13 14 15 1D 21 2B) 02(...) 04(...))`,
    /// which reads like sub-addressing and is not: writing a plain 0x01 selects
    /// sRGB. The real value list is the contents of the FIRST group, and the
    /// parser cannot know that, so the names in VCP.swift are used instead.
    /// Trusting the caps here produced a picker with three meaningless entries.
    static let capsValuesUnreliable: Set<UInt8> = [0xDC]

    /// HP concentrates many settings behind a small number of codes rather than
    /// giving each its own, so a sweep across code numbers finds nothing —
    /// the values are what carry meaning.
    static let subAddressedCodes: Set<UInt8> = [0xE1, 0xE8]

    static func note(for code: UInt8) -> String? {
        if subAddressedCodes.contains(code) {
            return "Sub-addressed: HP packs several settings behind this one code, "
                 + "selected by the high byte of the value."
        }
        if extendedByVendor.contains(code) {
            return "HP extends this code past the values MCCS defines, so standard "
                 + "value names do not apply."
        }
        return nil
    }
}
