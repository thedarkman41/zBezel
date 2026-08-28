import Foundation
import CoreGraphics
import IOKit

// MARK: - Display identity

struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let vendorID: UInt32
    let modelID: UInt32
    let serialID: UInt32
    let isBuiltIn: Bool
    let edid: EDID?

    var name: String {
        if let n = edid?.monitorName, !n.isEmpty { return n }
        if isBuiltIn { return "Built-in Display" }
        return String(format: "Display %04X:%04X", vendorID, modelID)
    }

    /// Stable across reconnects, unlike CGDirectDisplayID.
    var stableKey: String {
        let serial = edid?.serialString ?? String(serialID)
        return "\(vendorID)-\(modelID)-\(serial)"
    }

    func hash(into h: inout Hasher) { h.combine(stableKey) }
    static func == (a: DisplayInfo, b: DisplayInfo) -> Bool { a.stableKey == b.stableKey }
}

enum DisplayInventory {
    static func all() -> [DisplayInfo] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        return ids.prefix(Int(count)).map { id in
            DisplayInfo(
                id: id,
                vendorID: CGDisplayVendorNumber(id),
                modelID: CGDisplayModelNumber(id),
                serialID: CGDisplaySerialNumber(id),
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                edid: readEDID(id))
        }
    }

    /// Prefer the EDID read live over the wire; fall back to the IORegistry copy.
    static func readEDID(_ id: CGDirectDisplayID) -> EDID? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let read = bezel_read_edid(UInt32(id), &buffer, 256)
        if read >= 128, let e = EDID(Array(buffer.prefix(Int(read)))) { return e }
        return registryEDID(id)
    }

    /// The copy macOS cached at connection time. Available even when the I2C bus is not.
    static func registryEDID(_ id: CGDirectDisplayID) -> EDID? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let wantVendor = CGDisplayVendorNumber(id)
        let wantModel = CGDisplayModelNumber(id)

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let info = IODisplayCreateInfoDictionary(
                    service, IOOptionBits(kIODisplayOnlyPreferredName))?
                    .takeRetainedValue() as? [String: Any] else { continue }

            let vendor = (info[kDisplayVendorID] as? UInt32) ?? 0
            let model = (info[kDisplayProductID] as? UInt32) ?? 0
            guard vendor == wantVendor, model == wantModel else { continue }

            if let data = info["IODisplayEDID"] as? Data, let e = EDID([UInt8](data)) { return e }
        }
        return nil
    }
}

// MARK: - Resolution and refresh rate (host side, via CoreGraphics)

struct DisplayMode: Identifiable, Hashable {
    let id: Int32
    let width: Int              // logical ("looks like") size
    let height: Int
    let pixelWidth: Int         // backing store size
    let pixelHeight: Int
    let refreshHz: Double
    let isHiDPI: Bool
    let isUsableForDesktop: Bool

    var resolutionLabel: String { "\(width) × \(height)" }
    var refreshLabel: String {
        guard refreshHz > 0 else { return "—" }
        // Show decimals only when the rate is not a whole number, so 59.875 is
        // distinguishable from 60 instead of both reading "60".
        return abs(refreshHz - refreshHz.rounded()) < 0.01
            ? String(format: "%.0f Hz", refreshHz)
            : String(format: "%.2f Hz", refreshHz)
    }

    /// Same rule, without the unit — for the Refresh Rate menu.
    var refreshShortLabel: String {
        guard refreshHz > 0 else { return "—" }
        return abs(refreshHz - refreshHz.rounded()) < 0.01
            ? String(format: "%.0f", refreshHz)
            : String(format: "%.2f", refreshHz)
    }
    var detailLabel: String {
        isHiDPI ? "\(resolutionLabel)  (HiDPI \(pixelWidth) × \(pixelHeight))" : resolutionLabel
    }
}

enum DisplayModes {
    static func available(for id: CGDirectDisplayID) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }

        var seen = Set<String>()
        var out: [DisplayMode] = []
        for m in raw {
            let w = m.width, h = m.height
            let pw = m.pixelWidth, ph = m.pixelHeight
            let hidpi = pw > w
            let mode = DisplayMode(
                id: Int32(m.ioDisplayModeID),
                width: w, height: h, pixelWidth: pw, pixelHeight: ph,
                refreshHz: m.refreshRate,
                isHiDPI: hidpi,
                isUsableForDesktop: m.isUsableForDesktopGUI())
            // Collapse exact duplicates that differ only in internal flags.
            // Rate must be part of the key at full precision: this panel offers
            // 60.0 and 59.875, and rounding merged them into one entry.
            let key = String(format: "%dx%dx%dx%dx%.3fx%@", w, h, pw, ph,
                             m.refreshRate, hidpi ? "h" : "s")
            if seen.insert(key).inserted { out.append(mode) }
        }
        return out.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.refreshHz > $1.refreshHz
        }
    }

    static func current(for id: CGDirectDisplayID) -> DisplayMode? {
        guard let m = CGDisplayCopyDisplayMode(id) else { return nil }
        return DisplayMode(
            id: Int32(m.ioDisplayModeID),
            width: m.width, height: m.height,
            pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight,
            refreshHz: m.refreshRate,
            isHiDPI: m.pixelWidth > m.width,
            isUsableForDesktop: m.isUsableForDesktopGUI())
    }

    /// Distinct logical resolutions, each with the refresh rates it supports.
    static func grouped(for id: CGDirectDisplayID) -> [(resolution: String, modes: [DisplayMode])] {
        let usable = available(for: id).filter { $0.isUsableForDesktop }
        var order: [String] = []
        var buckets: [String: [DisplayMode]] = [:]
        for m in usable {
            let key = m.resolutionLabel
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(m)
        }
        return order.map { ($0, buckets[$0]!.sorted { $0.refreshHz > $1.refreshHz }) }
    }

    @discardableResult
    static func apply(_ mode: DisplayMode, to id: CGDirectDisplayID, permanent: Bool) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let target = raw.first(where: { Int32($0.ioDisplayModeID) == mode.id })
        else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, target, nil)
        let scope: CGConfigureOption = permanent ? .permanently : .forSession
        return CGCompleteDisplayConfiguration(config, scope) == .success
    }
}
