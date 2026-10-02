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

    /// The EDID product code this panel presents on each of its inputs.
    ///
    /// The Z27k G3 hands out a DIFFERENT product code per physical input, so the
    /// code a remote agent reports for the monitor it sees says exactly which
    /// input that machine is plugged into — no one has to configure it. Confirmed
    /// by reading the panel over each connection: DisplayPort 36D4, USB-C1 36D3,
    /// HDMI 36D5 (manufacturer HPN either way).
    static let inputForProduct: [String: UInt16] = [
        "36D4": 0x0F,   // DisplayPort
        "36D3": 0x13,   // USB-C1 Video
        "36D5": 0x11,   // HDMI
    ]

    /// Map a reported product identity to the input it means, or nil if it is not
    /// a face of this monitor. Accepts "HPN36D5" or a bare "36D5".
    static func input(forProduct code: String) -> UInt16? {
        let hex = String(code.uppercased().suffix(4))
        return inputForProduct[hex]
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

    /// One entry on the monitor's Color Mode menu.
    struct ColorMode: Identifiable {
        let value: UInt16
        let name: String
        /// What the mode is.
        let what: String
        /// What it is for.
        let bestFor: String

        var id: UInt16 { value }
        var help: String { "\(what)\n\nBest for: \(bestFor)" }
    }

    /// The nine modes, grouped by what they actually are.
    ///
    /// A flat list is misleading here, because 0xDC mixes three different kinds of
    /// setting: calibrated color-space targets, white-point preferences, and HP's
    /// image processing. Listed together they imply that Warm and P3 are the same
    /// sort of choice, and they are not — one is a look, the other is a gamut.
    static let colorModeGroups: [(title: String, modes: [ColorMode])] = [
        ("Calibrated color spaces", [
            ColorMode(value: 0x00, name: "Native",
                what: "Uses the panel's full native color response without emulating a color space.",
                bestFor: "A measured or calibrated workflow, or color-managed apps with a matching ICC profile."),
            ColorMode(value: 0x01, name: "sRGB (D65)",
                what: "Standard SDR color for the web, general desktop use, and most non-color-managed content.",
                bestFor: "The default choice for ordinary Mac use."),
            ColorMode(value: 0x02, name: "BT.709 (D65)",
                what: "HD SDR video color standard with a D65 white point.",
                bestFor: "Rec.709 and HD video editing or review."),
            // 0x05, not the 0x21 the capabilities string lists: writing 0x21
            // works but the panel reports 0x05 back, so a row keyed to 0x21 would
            // never show as selected. Every other mode round-trips exactly.
            ColorMode(value: 0x05, name: "P3 (D65)",
                what: "Wide-gamut Display P3-style mode with a D65 white point.",
                bestFor: "Wide-gamut photography, Apple-oriented content, and P3-targeted video and design."),
            ColorMode(value: 0x2B, name: "Color Match",
                what: "The monitor's color-matching mode. Pair it with the corresponding ICC profile.",
                bestFor: "Color-critical or factory-calibrated work."),
        ]),
        ("White balance", [
            ColorMode(value: 0x13, name: "Warm",
                what: "Warmer white point, with a reduced blue appearance.",
                bestFor: "Comfort and preference. Not color-critical work."),
            ColorMode(value: 0x15, name: "Neutral",
                what: "Balanced, default white appearance.",
                bestFor: "General viewing when no standard-space target is needed."),
            ColorMode(value: 0x14, name: "Cool",
                what: "Cooler white point, with a bluer appearance.",
                bestFor: "Bright rooms and preference. Not color-critical work."),
        ]),
        ("Enhancement", [
            ColorMode(value: 0x1D, name: "HP Enhance+",
                what: "HP's image-enhancement processing. May favour perceived sharpness, contrast or saturation over reference accuracy.",
                bestFor: "Casual desktop and media use, when you prefer the look."),
        ]),
    ]

    static func colorMode(for value: UInt16) -> ColorMode? {
        colorModeGroups.lazy.flatMap(\.modes).first { $0.value == value }
    }

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
