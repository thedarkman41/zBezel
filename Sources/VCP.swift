import Foundation

/// A VESA MCCS "Virtual Control Panel" feature code.
///
/// Values here come from the public MCCS tables (as mirrored by ddcutil and the
/// ddccontrol monitor database). Anything a specific monitor actually supports is
/// determined at runtime from its capabilities string, not from this table — this
/// is a naming and presentation layer, not a claim about any particular display.
struct VCPFeature: Hashable {
    enum Kind { case continuous, nonContinuous, table }

    let code: UInt8
    let name: String
    let kind: Kind
    /// Human labels for non-continuous values, where MCCS defines them.
    var values: [UInt16: String] = [:]
    /// Short explanation surfaced in the UI.
    var blurb: String = ""

    var hex: String { String(format: "0x%02X", code) }
}

enum VCP {
    // MARK: Standard MCCS codes

    static let restoreFactoryDefaults = VCPFeature(
        code: 0x04, name: "Restore Factory Defaults", kind: .nonContinuous,
        blurb: "Resets every adjustable setting to the factory state.")
    static let restoreFactoryLuminance = VCPFeature(
        code: 0x05, name: "Restore Brightness & Contrast", kind: .nonContinuous)
    static let restoreFactoryColor = VCPFeature(
        code: 0x08, name: "Restore Factory Colour", kind: .nonContinuous)

    static let colorTemperatureIncrement = VCPFeature(
        code: 0x0B, name: "Colour Temperature Increment", kind: .continuous)
    static let colorTemperatureRequest = VCPFeature(
        code: 0x0C, name: "Colour Temperature Request", kind: .continuous)

    static let luminance = VCPFeature(
        code: 0x10, name: "Brightness", kind: .continuous,
        blurb: "Backlight luminance.")
    static let contrast = VCPFeature(
        code: 0x12, name: "Contrast", kind: .continuous)

    static let selectColorPreset = VCPFeature(
        code: 0x14, name: "Colour Preset", kind: .nonContinuous,
        values: [
            0x01: "sRGB", 0x02: "Native", 0x03: "4000 K", 0x04: "5000 K",
            0x05: "6500 K", 0x06: "7500 K", 0x07: "8200 K", 0x08: "9300 K",
            0x09: "10000 K", 0x0A: "11500 K",
            0x0B: "User 1", 0x0C: "User 2", 0x0D: "User 3",
        ],
        blurb: "Colour temperature / gamut preset.")

    static let videoGainRed = VCPFeature(code: 0x16, name: "Red Gain", kind: .continuous)
    static let videoGainGreen = VCPFeature(code: 0x18, name: "Green Gain", kind: .continuous)
    static let videoGainBlue = VCPFeature(code: 0x1A, name: "Blue Gain", kind: .continuous)

    static let autoSetup = VCPFeature(code: 0x1E, name: "Auto Setup", kind: .nonContinuous)

    static let activeControl = VCPFeature(code: 0x52, name: "Active Control", kind: .nonContinuous)

    static let inputSelect = VCPFeature(
        code: 0x60, name: "Input Source", kind: .nonContinuous,
        values: [
            0x01: "VGA 1", 0x02: "VGA 2",
            0x03: "DVI 1", 0x04: "DVI 2",
            0x05: "Composite 1", 0x06: "Composite 2",
            0x07: "S-Video 1", 0x08: "S-Video 2",
            0x09: "Tuner 1", 0x0A: "Tuner 2", 0x0B: "Tuner 3",
            0x0C: "Component 1", 0x0D: "Component 2", 0x0E: "Component 3",
            0x0F: "DisplayPort 1", 0x10: "DisplayPort 2",
            0x11: "HDMI 1", 0x12: "HDMI 2",
        ],
        blurb: "Which physical input the panel displays. USB-C inputs usually report as a DisplayPort value, because DP-alt-mode is what travels the cable.")

    static let audioVolume = VCPFeature(code: 0x62, name: "Volume", kind: .continuous)

    static let videoBlackLevelRed = VCPFeature(code: 0x6C, name: "Red Black Level", kind: .continuous)
    static let videoBlackLevelGreen = VCPFeature(code: 0x6E, name: "Green Black Level", kind: .continuous)
    static let videoBlackLevelBlue = VCPFeature(code: 0x70, name: "Blue Black Level", kind: .continuous)

    /// Seven named steps, exactly as HP's OSD lists them — the two ends are
    /// words and the middle five are numbers. Declared as 87(01..07) and read
    /// back as a continuous 1-7, but it is an enumeration on the panel, so a
    /// slider showing "4" was inventing a scale the monitor does not use.
    static let sharpness = VCPFeature(
        code: 0x87, name: "Sharpness", kind: .nonContinuous,
        values: [0x01: "Soft", 0x02: "Level 2", 0x03: "Level 3", 0x04: "Level 4",
                 0x05: "Level 5", 0x06: "Level 6", 0x07: "Sharp"])
    static let audioMute = VCPFeature(
        code: 0x8D, name: "Audio Mute / Screen Blank", kind: .nonContinuous,
        values: [0x01: "Muted", 0x02: "Unmuted"])

    static let horizontalFrequency = VCPFeature(code: 0xAC, name: "Horizontal Frequency", kind: .continuous)
    static let verticalFrequency = VCPFeature(code: 0xAE, name: "Vertical Frequency", kind: .continuous)

    static let subPixelLayout = VCPFeature(
        code: 0xB2, name: "Sub-pixel Layout", kind: .nonContinuous,
        values: [0x00: "Undefined", 0x01: "RGB vertical stripe", 0x02: "RGB horizontal stripe",
                 0x03: "BGR vertical stripe", 0x04: "BGR horizontal stripe"])
    static let displayTechnology = VCPFeature(
        code: 0xB6, name: "Display Technology", kind: .nonContinuous,
        values: [0x01: "CRT", 0x02: "CRT", 0x03: "Passive LCD", 0x04: "Active LCD",
                 0x05: "LCoS", 0x06: "Plasma", 0x07: "OLED", 0x08: "EL", 0x09: "MEM"])

    static let displayScaling = VCPFeature(
        code: 0x86, name: "Display Scaling", kind: .nonContinuous,
        // Names taken from HP's own OSD, not from the MCCS table — the table's
        // name for 02 was wrong for this panel. 02 and 05 BOTH show as "Fill to
        // Screen" there; they are distinct values that read back distinctly, and
        // at native resolution nothing distinguishes them on screen.
        values: [0x01: "Pixel-for-Pixel", 0x02: "Fill to Screen",
                 0x05: "Fill to Screen (stretched)"],
        blurb: "Image Scaling. The monitor greys this out while the source is at "
             + "the panel's native resolution — there is nothing to scale — so a "
             + "change here stores and reads back but may do nothing visible.")

    static let greyScaleExpansion = VCPFeature(
        code: 0x2E, name: "Grey Scale Expansion", kind: .nonContinuous,
        values: [0x00: "0", 0x01: "1", 0x02: "2", 0x03: "3"],
        blurb: "Declared, writable, reads back — and controls nothing observable. "
             + "All four values were set while watching Brightness+ and Image: no "
             + "OSD field moved and the picture did not change. Kept here for the "
             + "Advanced listing only; deliberately not given a control.")

    static let displayUsageTime = VCPFeature(
        code: 0xC0, name: "Panel Hours", kind: .continuous,
        blurb: "Cumulative backlight hours reported by the monitor.")
    static let applicationEnableKey = VCPFeature(code: 0xC6, name: "Application Enable Key", kind: .table)
    static let controllerType = VCPFeature(code: 0xC8, name: "Controller Type", kind: .nonContinuous)
    static let firmwareLevel = VCPFeature(code: 0xC9, name: "Firmware Level", kind: .continuous)

    static let osdControl = VCPFeature(
        code: 0xCA, name: "OSD / Button Lock", kind: .nonContinuous,
        values: [0x01: "OSD disabled", 0x02: "OSD enabled",
                 0xFF: "Buttons locked"])
    static let osdLanguage = VCPFeature(
        code: 0xCC, name: "OSD Language", kind: .nonContinuous,
        values: [0x01: "Chinese (traditional)", 0x02: "English", 0x03: "French",
                 0x04: "German", 0x05: "Italian", 0x06: "Japanese", 0x07: "Korean",
                 0x08: "Portuguese", 0x09: "Russian", 0x0A: "Spanish",
                 0x0B: "Swedish", 0x0C: "Turkish", 0x0D: "Chinese (simplified)",
                 0x0E: "Portuguese (Brazil)", 0x0F: "Arabic", 0x10: "Bulgarian",
                 0x11: "Croatian", 0x12: "Czech", 0x13: "Danish", 0x14: "Dutch",
                 0x15: "Estonian", 0x16: "Finnish", 0x17: "Greek", 0x18: "Hebrew",
                 0x19: "Hindi", 0x1A: "Hungarian", 0x1B: "Latvian", 0x1C: "Lithuanian",
                 0x1D: "Norwegian", 0x1E: "Polish", 0x1F: "Romanian", 0x20: "Serbian",
                 0x21: "Slovak", 0x22: "Slovenian", 0x23: "Thai", 0x24: "Ukrainian",
                 0x25: "Vietnamese"])

    static let displayApplication = VCPFeature(
        code: 0xDC, name: "Preset Mode", kind: .nonContinuous,
        values: [0x00: "Standard", 0x01: "Productivity", 0x02: "Mixed",
                 0x03: "Movie", 0x04: "User", 0x05: "Games", 0x06: "Sports",
                 0x07: "Professional", 0x08: "Standard (default)", 0x09: "Reading",
                 0x0A: "Text", 0x0B: "Video"],
        blurb: "Vendor picture modes. HP exposes its viewing modes here on models that support it.")

    static let vcpVersion = VCPFeature(code: 0xDF, name: "MCCS Version", kind: .continuous)

    static let powerMode = VCPFeature(
        code: 0xD6, name: "Power Mode", kind: .nonContinuous,
        values: [0x01: "On", 0x02: "Standby", 0x03: "Suspend",
                 0x04: "Off (soft)", 0x05: "Off (hard)"],
        blurb: "DPMS power state.")

    /// Everything above, indexed by code.
    static let all: [UInt8: VCPFeature] = {
        let list = [
            restoreFactoryDefaults, restoreFactoryLuminance, restoreFactoryColor,
            colorTemperatureIncrement, colorTemperatureRequest,
            luminance, contrast, selectColorPreset,
            videoGainRed, videoGainGreen, videoGainBlue, autoSetup, activeControl,
            inputSelect, audioVolume,
            videoBlackLevelRed, videoBlackLevelGreen, videoBlackLevelBlue,
            sharpness, audioMute, horizontalFrequency, verticalFrequency,
            subPixelLayout, displayTechnology, displayUsageTime,
            displayScaling, greyScaleExpansion,
            applicationEnableKey, controllerType, firmwareLevel,
            osdControl, osdLanguage, displayApplication, vcpVersion, powerMode,
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.code, $0) })
    }()

    /// Descriptive fallback for a code we have no table entry for.
    static func describe(_ code: UInt8) -> VCPFeature {
        if let known = all[code] { return known }
        let manufacturerSpecific = code >= 0xE0
        return VCPFeature(
            code: code,
            name: manufacturerSpecific ? "Manufacturer code \(String(format: "0x%02X", code))"
                                       : "Reserved code \(String(format: "0x%02X", code))",
            kind: .nonContinuous,
            blurb: manufacturerSpecific
                ? "Inside the MCCS manufacturer-specific range. Meaning is defined by HP, not by the standard."
                : "Not named in the public MCCS tables.")
    }

    static func isManufacturerSpecific(_ code: UInt8) -> Bool { code >= 0xE0 }
}
