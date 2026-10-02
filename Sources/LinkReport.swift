import Foundation

/// What the video link actually looks like, and therefore whether DDC/CI can work.
struct LinkReport {
    var framebufferFound = false
    var i2cBusCount = 0
    var busType = 0
    var edidReadOK = false
    var ddcAddressACK = false
    var ddcReplyOK = false

    var dpcdReadOK = false
    var dpcdRev: UInt8 = 0
    var maxLinkRate: UInt8 = 0
    var maxLaneCount: UInt8 = 0
    var downstreamPort: UInt8 = 0
    var mstCap: UInt8 = 0
    var mstCtrl: UInt8 = 0

    var branchPresent = false
    var branchOUI: [UInt8] = [0, 0, 0]
    var branchDeviceID = ""
    var branchFirmware = ""

    var sinkPresent = false
    var sinkOUI: [UInt8] = [0, 0, 0]
    var sinkDeviceID = ""

    init() {}

    init(_ c: BezelLinkReport) {
        framebufferFound = c.framebufferFound != 0
        i2cBusCount = Int(c.i2cBusCount)
        busType = Int(c.busType)
        edidReadOK = c.edidReadOK != 0
        ddcAddressACK = c.ddcAddressACK != 0
        ddcReplyOK = c.ddcReplyOK != 0

        dpcdReadOK = c.dpcdReadOK != 0
        dpcdRev = c.dpcdRev
        maxLinkRate = c.maxLinkRate
        maxLaneCount = c.maxLaneCount
        downstreamPort = c.downstreamPort
        mstCap = c.mstCap
        mstCtrl = c.mstCtrl

        branchPresent = c.branchPresent != 0
        branchOUI = [c.branchOUI.0, c.branchOUI.1, c.branchOUI.2]
        branchDeviceID = LinkReport.cString(c.branchDeviceID)
        branchFirmware = "\(c.branchFWMajor).\(String(format: "%02d", c.branchFWMinor))"

        sinkPresent = c.sinkPresent != 0
        sinkOUI = [c.sinkOUI.0, c.sinkOUI.1, c.sinkOUI.2]
        sinkDeviceID = LinkReport.cString(c.sinkDeviceID)
    }

    private static func cString(_ t: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
        withUnsafeBytes(of: t) { buf in
            let bytes = buf.prefix(while: { $0 != 0 }).map { UInt8($0) }
            return String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: Interpretation

    enum Verdict {
        case working
        case blockedByIntermediateDevice(String)
        case refusedByDisplay
        case noI2CBus
        case noFramebuffer
    }

    var mstEnabled: Bool { mstCtrl & 0x01 != 0 }

    /// A recognized name for the chip terminating the AUX channel, when we have one.
    var branchVendorName: String? {
        guard branchPresent else { return nil }
        // Only names we can corroborate from the device-ID string the chip reports.
        if branchOUI == [0x90, 0xCC, 0x24] || branchDeviceID.uppercased().hasPrefix("SYNA") {
            return "Synaptics"
        }
        return nil
    }

    var branchDescription: String {
        guard branchPresent else { return "none" }
        let oui = branchOUI.map { String(format: "%02X", $0) }.joined(separator: ":")
        let vendor = branchVendorName.map { "\($0) " } ?? ""
        let id = branchDeviceID.isEmpty ? "" : " “\(branchDeviceID)”"
        return "\(vendor)\(oui)\(id)"
    }

    var verdict: Verdict {
        if !framebufferFound { return .noFramebuffer }
        if i2cBusCount == 0 { return .noI2CBus }
        if ddcReplyOK { return .working }
        // EDID travels the same I2C-over-AUX path DDC/CI uses. If EDID reads but
        // DDC/CI will not even ACK its address, something is answering that proxies
        // one and refuses the other — characteristically a dock or MST hub.
        if edidReadOK, !ddcAddressACK, branchPresent, !sinkPresent {
            return .blockedByIntermediateDevice(branchDescription)
        }
        if edidReadOK, !ddcAddressACK { return .refusedByDisplay }
        return .noI2CBus
    }

    var headline: String {
        switch verdict {
        case .working: return "DDC/CI active"
        case .blockedByIntermediateDevice: return "DDC/CI blocked in the video path"
        case .refusedByDisplay: return "Display is refusing DDC/CI"
        case .noI2CBus: return "No usable control bus"
        case .noFramebuffer: return "Display not matched"
        }
    }

    var explanation: String {
        switch verdict {
        case .working:
            return "The monitor answers MCCS commands, so its own settings are adjustable from here."

        case .blockedByIntermediateDevice(let who):
            return """
            The AUX channel ends at an intermediate device (\(who)) rather than at the monitor. \
            It answers EDID reads on the monitor's behalf, but refuses the DDC/CI address, so \
            control commands never reach the panel. The monitor is not at fault and neither is macOS.

            Connecting the monitor straight to a Thunderbolt/USB-C port on the Mac removes the \
            intermediate device from the path and normally restores DDC/CI.
            """

        case .refusedByDisplay:
            return """
            The control bus reaches the monitor — its EDID reads back correctly — but the monitor \
            does not acknowledge the DDC/CI address. Check for a DDC/CI item in the monitor's \
            on-screen menu, which some models ship disabled.
            """

        case .noI2CBus:
            return "This display's framebuffer exposes no usable I2C bus, so DDC/CI is unavailable."

        case .noFramebuffer:
            return "No IOFramebuffer matched this display, so the control bus could not be opened."
        }
    }

    /// Host-side features stay available no matter what the monitor-side verdict is.
    var monitorSideAvailable: Bool {
        if case .working = verdict { return true }
        return false
    }
}
