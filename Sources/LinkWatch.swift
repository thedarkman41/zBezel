import Foundation
import CoreGraphics
import AppKit

/// Debug instrumentation for the intermittent "blinking amber" link drop: the
/// HP Z27k falls into DPMS standby (no-signal, blinking amber LED) MID-WORK
/// while the source stays awake. The working theory is contended DDC/CI on the
/// panel — zBezel drives DDC through the rigel proxy while BetterDisplay drives
/// its OWN DDC (hardware brightness + input) over the Mac's connection, and two
/// masters on one monitor's MCU can wedge it into dropping the live link.
///
/// The drop is rare and unpredictable, so this records a timestamped trail we
/// can read AFTER it happens:
///  - every macOS display-reconfiguration event (zero DDC cost),
///  - system/screen sleep + wake, so a mid-work drop is provably NOT a sleep,
///  - transitions in the panel link telemetry zBezel already reads on its
///    normal polls, and every DDC WRITE zBezel itself issues — so a change we
///    caused is distinguishable from one BetterDisplay caused.
///
/// Deliberately PASSIVE about DDC: it adds no polling of its own, because more
/// DDC traffic is the very thing suspected of triggering the drop. See memory
/// bezel-amber-blink-betterdisplay-ddc-contention.
enum LinkWatchLog {
    private static let queue = DispatchQueue(label: "com.darkstar.zBezel.linkwatch.log")
    private static let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/zBezel", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private static let url = dir.appendingPathComponent("linkwatch.log")
    private static let rolled = dir.appendingPathComponent("linkwatch.1.log")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Append one line. Unlike KVMLog (a small "what is it doing now" buffer that
    /// is discarded on overflow), this KEEPS HISTORY: at 5 MB the current file is
    /// rotated to `linkwatch.1.log` rather than deleted, so the window leading up
    /// to a drop survives until we get to read it.
    static func write(_ message: String) {
        let line = stamp.string(from: Date()) + "  " + message + "\n"
        queue.async {
            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? UInt64, size > 5 * 1024 * 1024 {
                try? FileManager.default.removeItem(at: rolled)
                try? FileManager.default.moveItem(at: url, to: rolled)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Registers the zero-DDC-cost Mac-side observers: display reconfiguration and
/// sleep/wake. Started once from AppDelegate.
enum DisplayEventMonitor {
    private static var started = false
    private static var tokens: [NSObjectProtocol] = []

    @MainActor
    static func start() {
        guard !started else { return }
        started = true

        // Per-display config changes (mode set, enable/disable, add/remove,
        // becoming main, desktop reshape). This is macOS's own view of the panel
        // flapping — the closest thing to a "the display just changed" event.
        // The callback is a C function pointer, so it captures nothing and reads
        // only statics.
        let rc = CGDisplayRegisterReconfigurationCallback(reconfigCallback, nil)
        LinkWatchLog.write("display-event monitor armed (reconfig cb rc=\(rc.rawValue)); \(snapshotAll())")

        let wsnc = NSWorkspace.shared.notificationCenter
        func observe(_ name: Notification.Name, _ label: String) {
            let t = wsnc.addObserver(forName: name, object: nil, queue: .main) { _ in
                LinkWatchLog.write("SLEEP/WAKE: \(label); \(snapshotAll())")
            }
            tokens.append(t)
        }
        // These separate a genuine sleep from a mid-work drop: if a drop is logged
        // with no screensDidSleep/willSleep just before it, it happened awake.
        observe(NSWorkspace.willSleepNotification, "system willSleep")
        observe(NSWorkspace.didWakeNotification, "system didWake")
        observe(NSWorkspace.screensDidSleepNotification, "screens didSleep")
        observe(NSWorkspace.screensDidWakeNotification, "screens didWake")
        observe(NSWorkspace.sessionDidResignActiveNotification, "session resignActive")
        observe(NSWorkspace.sessionDidBecomeActiveNotification, "session becomeActive")
    }

    private static let reconfigCallback: CGDisplayReconfigurationCallBack = { display, flags, _ in
        // Ignore the pre-change pass; log the settled one so state reads are true.
        if flags.contains(.beginConfigurationFlag) { return }
        LinkWatchLog.write("RECONFIG: \(DisplayEventMonitor.describe(display)) [\(DisplayEventMonitor.decode(flags))]")
    }

    // MARK: display state helpers

    static func decode(_ f: CGDisplayChangeSummaryFlags) -> String {
        var parts: [String] = []
        if f.contains(.movedFlag) { parts.append("moved") }
        if f.contains(.setMainFlag) { parts.append("setMain") }
        if f.contains(.addFlag) { parts.append("added") }
        if f.contains(.removeFlag) { parts.append("removed") }
        if f.contains(.enabledFlag) { parts.append("enabled") }
        if f.contains(.disabledFlag) { parts.append("disabled") }
        if f.contains(.mirrorFlag) { parts.append("mirror") }
        if f.contains(.unMirrorFlag) { parts.append("unmirror") }
        if f.contains(.desktopShapeChangedFlag) { parts.append("desktopReshape") }
        return parts.isEmpty ? "no-flags" : parts.joined(separator: ",")
    }

    static func describe(_ id: CGDirectDisplayID) -> String {
        let kind = CGDisplayIsBuiltin(id) != 0 ? "builtin" : "external"
        let online = CGDisplayIsOnline(id) != 0 ? "online" : "OFFLINE"
        let active = CGDisplayIsActive(id) != 0 ? "active" : "INACTIVE"
        let asleep = CGDisplayIsAsleep(id) != 0 ? "ASLEEP" : "awake"
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
        let w = CGDisplayPixelsWide(id), h = CGDisplayPixelsHigh(id)
        return "id=\(id) \(kind) v=\(vendor)/m=\(model) \(w)x\(h) \(online) \(active) \(asleep)"
    }

    static func snapshotAll() -> String {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return "displays: <query failed>" }
        let list = (0..<Int(count)).map { describe(ids[$0]) }
        return "displays{ " + list.joined(separator: " | ") + " }"
    }
}
