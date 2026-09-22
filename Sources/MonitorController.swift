import Foundation
import CoreGraphics
import SwiftUI

/// One monitor-side feature as we currently understand it.
struct FeatureState {
    var feature: VCPFeature
    var current: UInt16 = 0
    var maximum: UInt16 = 0
    /// Values the monitor said it accepts, from the capabilities string.
    var permittedValues: [UInt16] = []
    var readable = false

    var label: String { feature.name }

    func labelFor(value: UInt16) -> String {
        if feature.code == 0x60 { return HPProfile.inputLabel(value) }
        // Where HP has extended a code past the standard enumeration, the MCCS
        // names are wrong for this panel; a raw value is more honest.
        if HPProfile.extendedByVendor.contains(feature.code) {
            return String(format: "0x%02X", value)
        }
        if let named = feature.values[value] { return named }
        return String(format: "0x%02X", value)
    }

    var choices: [(value: UInt16, label: String)] {
        var values = (permittedValues.isEmpty
                      || HPProfile.capsValuesUnreliable.contains(feature.code))
            ? Array(feature.values.keys).sorted()
            : permittedValues
        if feature.code == 0x60 {
            // The panel declares more input values than it has sockets — 0x21,
            // 0x2F and 0x3D match no connector on the back and are presumably
            // there for other models sharing this firmware. Offering them would
            // just be a way to blank the screen.
            values = values.filter { HPProfile.isIdentifiedInput($0) }
        }
        return values.map { ($0, labelFor(value: $0)) }
    }
}

/// How we are reaching the monitor's control channel, if at all.
enum Transport: Equatable {
    case none
    case local
    case proxy(host: String, monitorIndex: Int, description: String)

    var isAvailable: Bool { self != .none }

    var label: String {
        switch self {
        case .none: return "unavailable"
        case .local: return "direct DDC/CI"
        case .proxy(let host, _, _): return "via \(host)"
        }
    }
}

/// What one candidate host had to say when the link was last looked for.
///
/// "No link" is never the whole story when several machines could carry the
/// controls: one may be asleep, another signed out, a third busy showing its
/// desktop to an RDP client. Keeping a line per host is what turns a dead end
/// into something a person can act on.
struct ProxyCandidateReport: Identifiable, Equatable {
    let host: String
    let summary: String
    let usable: Bool
    var id: String { host }
}

@MainActor
final class MonitorController: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var selectedID: CGDirectDisplayID?

    @Published private(set) var link = LinkReport()
    @Published private(set) var transport: Transport = .none {
        didSet {
            // Start watching the input only once there is a channel to read it
            // over. Starting at launch meant every run began by announcing that
            // it could not reach the monitor, which is noise that hides the real
            // thing that line is for: a channel that has genuinely gone away.
            guard transport.isAvailable != oldValue.isAvailable else { return }
            if transport.isAvailable { startWatchingInput() } else { stopWatchingInput() }
            // The KVM refuses crossings that would need an input switch while
            // there is no channel; keep its status line truthful either way.
            kvm.linkAvailabilityChanged()
            syncKVMState()
        }
    }
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var features: [UInt8: FeatureState] = [:]
    /// True while a colour mode change is applying and its per-mode gains and
    /// black levels are being re-read — the sliders dim so the outgoing numbers
    /// do not read as current before the new ones land.
    @Published private(set) var refreshingColor = false

    /// The white-balance reference for the draggable white point: the RGB gains
    /// and the white they are taken to produce (the panel's native white). Set
    /// lazily from the current gains the first time the white point is dragged,
    /// and cleared when a colour mode change moves the gains out from under it.
    private var whiteBalanceReference: (gains: (Double, Double, Double), white: (Double, Double))?

    @Published private(set) var modeGroups: [(resolution: String, modes: [DisplayMode])] = []
    @Published private(set) var currentMode: DisplayMode?

    @Published private(set) var isProbing = false
    @Published private(set) var probeStatus = ""
    @Published var lastError: String?

    /// Proxy settings, persisted so the app comes back configured.
    @Published var proxyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(proxyEnabled, forKey: "proxyEnabled")
            // Switching the proxy on with no link should start the unattended
            // retries then and there, not wait for the next thing that probes.
            updateLinkRetry()
        }
    }
    @Published var proxyHost: String {
        didSet { UserDefaults.standard.set(proxyHost, forKey: "proxyHost") }
    }
    @Published private(set) var proxyDiagnostic: String?
    /// One line per candidate host from the last proxy probe, in the order they
    /// were tried.
    @Published private(set) var proxyCandidateReports: [ProxyCandidateReport] = []
    /// When the next unattended probe is due, while there is no link.
    @Published private(set) var nextLinkRetry: Date?
    @Published private(set) var remoteMonitors: [RemoteMonitor] = []

    // Vendor-code discovery
    @Published var vendorMap: VendorMap { didSet { vendorMap.save() } }
    @Published private(set) var vendorBaseline: [UInt8: UInt16]?
    /// Sub-addressed codes, sampled: code -> selector -> value.
    ///
    /// These cannot be compared by a single read. 0xE1 answers with whichever
    /// sub-selector its rotation lands on, so two plain reads taken a minute apart
    /// are usually different SETTINGS rather than a changed one.
    private var vendorSubBaseline: [UInt8: [UInt8: UInt16]] = [:]
    @Published private(set) var vendorChanges: [VendorChange] = []
    @Published private(set) var mapperBusy = false
    /// Set by the Cancel affordance; the sampling loop checks it between chunks.
    ///
    /// Sampling a sub-addressed code properly takes hundreds of reads, which is
    /// most of a minute on this link. A job that long with no way out is a job
    /// that traps the user.
    private var vendorCancelled = false

    func cancelVendorMapping() { vendorCancelled = true }

    private let agent = RemoteAgent()

    // MARK: KVM

    private let kvm = KVMController()
    let discovery = KVMDiscovery()

    /// Hosts pinned by hand — the fallback for a machine discovery cannot see
    /// (a different subnet, no broadcast). Kept apart from the discovered set so
    /// a rebuild never loses them, and persisted on their own.
    @Published var manualPins: [KVMController.Machine] {
        didSet {
            if let data = try? JSONEncoder().encode(manualPins) {
                UserDefaults.standard.set(data, forKey: "kvmManualPins")
            }
        }
    }
    @Published private(set) var kvmEnabled = false
    @Published private(set) var kvmControllingRemote = false
    @Published private(set) var kvmStatus = "off"
    @Published var kvmError: String?

    init() {
        let defaults = UserDefaults.standard
        proxyEnabled = defaults.object(forKey: "proxyEnabled") as? Bool ?? true
        proxyHost = defaults.string(forKey: "proxyHost") ?? ""
        kvmMachines = MonitorController.loadKVMMachines(
            proxyHost: defaults.string(forKey: "proxyHost") ?? "")
        if let data = defaults.data(forKey: "kvmManualPins"),
           let list = try? JSONDecoder().decode([KVMController.Machine].self, from: data) {
            manualPins = list
        } else {
            manualPins = []
        }
        lastCommandedInput = UInt16(defaults.object(forKey: "lastCommandedInput") as? Int
                                    ?? 0x0F)
        vendorMap = VendorMap.load()
        vendorReadings = MonitorController.loadVendorReadings()
        pipPlacement  = defaults.object(forKey: "pipPlacement") as? Int ?? 0
        // -1 means this app has never set a size, which is not the same as
        // "small" — the panel is not asked and so is not claimed.
        pipSize       = PiPSize(rawValue: defaults.object(forKey: "pipSize") as? Int ?? -1)
        // HP's factory values, used only until this app sets one — the panel will
        // not report where these actually stand.
        osdMenuH       = defaults.object(forKey: "osdMenuH") as? Int ?? 97
        osdMenuV       = defaults.object(forKey: "osdMenuV") as? Int ?? 14
        osdMenuTimeout = defaults.object(forKey: "osdMenuTimeout") as? Int ?? 60
        osdTransparency = Transparency(
            rawValue: defaults.object(forKey: "osdTransparency") as? Int ?? -1)
        pipSideBySide = defaults.bool(forKey: "pipSideBySide")


        // The tap runs on the main run loop, but the callback reaches us from a
        // C function pointer with no isolation the compiler can see, so hop
        // explicitly rather than asserting it is already safe.
        kvm.onChange = { [weak self] in
            Task { @MainActor in self?.syncKVMState() }
        }
        kvm.onNotice = { [weak self] note in
            Task { @MainActor in self?.kvmError = note }
        }

        kvm.onScreenshot = { [weak self] data in
            guard let image = NSImage(data: data) else { return }
            self?.pcSnapshot = image
        }
    }

    private func syncKVMState() {
        kvmEnabled = kvm.isEnabled
        kvmControllingRemote = kvm.side == .there
        kvmStatus = kvm.status
    }

    /// Adopt the bindings already known for this panel family.
    ///
    /// Only once the capabilities string confirms which panel is attached: these
    /// codes are manufacturer-specific and writing another vendor's 0xE1 with
    /// HP's sub-selectors would be poking at something entirely unrelated.
    private func seedVendorBindings() {
        guard HPProfile.matches(capabilities) else { return }
        var updated = vendorMap
        updated.seedKnownIfMissing()
        if updated != vendorMap { vendorMap = updated }
    }

    // MARK: Picture in Picture
    //
    // All four settings live behind 0xE1's sub-addressing: 0x11 on/off, 0x12
    // mode, 0x13 size, 0x14 placement.
    //
    // Held locally rather than read back, and that is not laziness. 0x12 and
    // 0x14 essentially never surface in the monitor's selector rotation — 300
    // samples returned neither — so a read cannot tell us where they stand. The
    // panel obeys the writes; it simply will not report them. Optimistic state
    // plus persistence is the honest answer, and it is why the UI never claims
    // to have re-read these.

    /// Read back from the panel: this one DOES surface in the selector rotation.
    @Published var pipOn = false

    /// The size this app last set, remembered across launches.
    ///
    /// Optimistic, like mode and placement, and for the same reason: the panel
    /// will not report it. 0x13 answers reads with a latched constant that does
    /// not follow a change — 2 across one session's four size changes, 3 across
    /// another's — so it is asserted rather than read, and nil until this app has
    /// actually set one.
    @Published var pipSize: PiPSize? {
        didSet { UserDefaults.standard.set(pipSize?.rawValue ?? -1, forKey: "pipSize") }
    }

    /// Not readable — 0x12 and 0x14 never appear in the monitor's rotation; a
    /// thousand consecutive reads returned neither.
    ///
    /// So they are not read. They are ASSERTED: switching PiP on pushes all four
    /// settings, and the panel is then in the state the diagram shows because
    /// the app just put it there.
    ///
    /// The previous attempt drew them as "unknown", which was honest and
    /// useless — a diagram declining to say where the inset is, beside a monitor
    /// visibly showing where the inset is. Asserting only became the better
    /// answer once a write cost 0.09s instead of 3s; at the old price, four
    /// writes on every enable would have been unbearable.
    @Published var pipPlacement: Int {
        didSet { UserDefaults.standard.set(pipPlacement, forKey: "pipPlacement") }
    }
    @Published var pipSideBySide: Bool {
        didSet { UserDefaults.standard.set(pipSideBySide, forKey: "pipSideBySide") }
    }

    /// A bare write, with no read-back of anything else.
    ///
    /// The generic set() re-reads every volatile code after each write, which
    /// costs about two extra seconds. That is a fair trade for brightness, where
    /// the values on screen should follow the panel. It is pure waste here:
    /// 0xE1's read returns whichever sub-setting the panel feels like naming, so
    /// the read-back cannot confirm what was just written and cannot refresh
    /// anything that changed.
    ///
    /// Measured: 3.22s with the read-back, 1.29s without.
    private func writeSub(_ selector: UInt8, _ value: Int) async {
        guard case .proxy(_, let index, _) = transport else {
            await set(code: 0xE1, value: UInt16(Int(selector) << 8 | (value & 0xFF)))
            return
        }
        let started = Date()
        let raw = UInt16(Int(selector) << 8 | (value & 0xFF))
        try? await agent.writeOnly(monitor: index, code: 0xE1, value: raw)
        KVMLog.write(String(format: "pip: write 0x%02X=%d took %.2fs",
                            selector, value, Date().timeIntervalSince(started)))
    }

    func applyPiPOn(_ on: Bool) async {
        pipBusyControl = "mode"
        defer { pipBusyControl = nil }
        pipOn = on
        await writeSub(0x11, on ? 1 : 0)
        guard on else { return }

        // Push the rest so the panel is in the state the diagram claims.
        //
        // Two of these cannot be read back, so the only way for picture and
        // monitor to agree is to make them agree. Four writes at ~0.09s is a
        // third of a second, and the two ends are then in step by construction
        // rather than by hope.
        await writeSub(0x12, pipSideBySide ? 1 : 0)
        await writeSub(0x14, pipPlacement)
        // Size too, once this app has ever set one. It is a setting like the
        // other two, so asserting it is what keeps diagram and panel in step.
        if let size = pipSize { await writeSub(0x13, size.rawValue) }
    }

    func applyPiPSideBySide(_ side: Bool) async {
        pipBusyControl = "mode"
        defer { pipBusyControl = nil }
        pipSideBySide = side
        await writeSub(0x12, side ? 1 : 0)
    }

    /// Take on/off and size from the panel itself.
    ///
    /// Only these two: mode and placement cannot be read at all, so they stay
    /// unknown until set. Sampled rather than read once, because a single read
    /// of 0xE1 returns whichever selector the rotation lands on.
    /// Read whether PiP is on — the only part of it the panel will tell us.
    ///
    /// Sampled in chunks and stopped the moment 0x11 turns up, because the
    /// rotation is savagely lopsided: in one 300-read pass while side-by-side was
    /// active, 0x13 took 263 of them and 0x11 appeared three times. The old
    /// 24-sample read therefore missed it almost every launch and left the toggle
    /// showing off while the panel was plainly split in two.
    ///
    /// The MODE — picture-in-picture versus side-by-side — cannot be read at all.
    /// 0x12 did not appear once in that same 300-sample pass. It stays asserted
    /// from what this app last set.
    func syncPiPFromPanel(chunks: Int = 8, samples: Int = 60) async {
        guard case .proxy(_, let index, _) = transport else { return }
        let started = Date()
        var reads = 0
        for _ in 0..<chunks {
            guard let map = try? await agent.readSubSelectorMap(
                monitor: index, code: 0xE1, samples: samples) else { return }
            reads += samples
            if let raw = map[0x11] {
                pipOn = (raw & 0xFF) != 0
                KVMLog.write(String(format: "pip: 0x11 found after %d reads in %.2fs — %@",
                                    reads, Date().timeIntervalSince(started),
                                    pipOn ? "on" : "off"))
                return
            }
        }
        KVMLog.write("pip: 0x11 never surfaced in \(reads) reads; leaving the toggle as it was")
    }

    /// 0 bottom-right, 1 top-left, 2 top-right, 3 bottom-left.
    /// Placement cannot be read back, so this cannot be verified the way size
    /// is — but it still takes the same lock, because queued writes to a panel
    /// that needs seconds per change is what made the size control misbehave.
    func applyPiPPlacement(_ corner: Int) async {
        guard !pipBusy else { return }
        pipBusyControl = "placement"
        defer { pipBusyControl = nil }

        // No on/off or mode write first.
        //
        // Those preambles tripled the cost of every corner: three writes at ~3s
        // each is the ten seconds. They fired because pipOn defaults to false
        // and the sync rarely corrects it — 0x11 surfaces in about one read in a
        // hundred, so twenty-four samples almost never see it, and the app kept
        // "helpfully" switching on something already on.
        //
        // Setting placement while PiP is off is harmless: it takes effect when
        // PiP is switched on, which is the toggle right above.
        let started = Date()
        await writeSub(0x14, corner)
        pipPlacement = corner
        KVMLog.write(String(format: "pip placement %d: total %.2fs",
                            corner, Date().timeIntervalSince(started)))
    }

    // Live stills for the side-by-side diagram: what each machine is showing.
    @Published private(set) var macSnapshot: NSImage?
    @Published private(set) var pcSnapshot: NSImage?
    @Published private(set) var needsScreenRecording = !ScreenSnapshot.isPermitted

    /// Refresh both halves.
    ///
    /// The Mac half is the display the PANEL is showing, not the built-in one —
    /// side by side composites what this Mac sends to that panel next to what
    /// the PC sends, so the built-in screen would be the wrong picture.
    ///
    /// The PC half is asked for over the clipboard channel and arrives
    /// asynchronously, so this only sends the request.
    func refreshSnapshots() async {
        needsScreenRecording = !ScreenSnapshot.isPermitted
        if let id = selectedID, displays.contains(where: { $0.id == id }) {
            macSnapshot = await ScreenSnapshot.capture(display: id)
        }
        kvm.requestScreenshot(width: 640)
    }

    func askForScreenRecording() {
        ScreenSnapshot.requestPermission()
        needsScreenRecording = !ScreenSnapshot.isPermitted
    }

    /// True while a PiP write is in flight, so the UI can say so and further
    /// clicks are dropped rather than queued.
    /// Which diagram is mid-write: "placement", "size" or "mode".
    @Published private(set) var pipBusyControl: String?
    var pipBusy: Bool { pipBusyControl != nil }

    /// Set the inset size.
    ///
    /// One write. There is nothing to read back — 0x13's read is latched and does
    /// not follow the write — so the UI shows what it set, which is honest as
    /// long as it never claims to have checked.
    ///
    /// Clicks during a write are dropped rather than queued. Queueing them is
    /// what produced the burst where several clicks did nothing and then all
    /// arrived at once.
    func applyPiPSize(_ size: PiPSize) async {
        guard !pipBusy else { return }
        pipBusyControl = "size"
        let started = Date()
        pipSize = size
        await writeSub(0x13, size.rawValue)
        KVMLog.write(String(format: "pip size %@: total %.2fs",
                            size.label, Date().timeIntervalSince(started)))
        pipBusyControl = nil
    }

    /// Hold the size stepping in one direction until told to stop.
    ///
    /// Driven by the jog knob, which reports a DIRECTION and an INTENSITY rather
    /// than a value — the right model for a panel that will not say what size it
    /// is and only accepts "one step bigger".
    ///
    /// Intensity sets the pause between writes: `jogMaxDelay` just outside the
    /// dead zone, tapering to none at full deflection. Wide open, the wire is the
    /// only limit.
    ///
    /// No busy flag. The busy guard exists to stop clicks queueing into a burst,
    /// and here the burst IS the feature; cancellation is what ends it.
    func startPiPJog(up: Bool, intensity: Double) {
        jogDelay = UInt64(MonitorController.jogMaxDelay * (1 - min(1, max(0, intensity))))
        // Already running the right way: just re-rate it. Restarting the task on
        // every drag event would throw away the write in flight each time.
        guard up != jogDirection || jogTask == nil else { return }
        jogTask?.cancel()
        jogDirection = up
        // Off the presets the moment it moves: the inset no longer matches one,
        // and the picker should stop claiming it does.
        pipSize = nil
        jogTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.writeSub(0x13, up ? PiPSize.growCommand
                                             : PiPSize.shrinkCommand)
                let pause = self.jogDelay
                if pause > 0 { try? await Task.sleep(nanoseconds: pause) }
            }
        }
    }

    func stopPiPJog() {
        jogTask?.cancel()
        jogTask = nil
        jogDirection = nil
    }

    /// The pause just outside the dead zone, in nanoseconds.
    ///
    /// 300ms, which gives roughly three steps a second at the slow end against
    /// about eleven wide open. The first attempt used 0.5ms, and the curve was
    /// implemented correctly and did nothing you could feel: a write is its own
    /// round trip at ~90ms, so a pause has to be an appreciable fraction of THAT
    /// to change the rate. The delay is not the interval, it is the extra on top
    /// of it.
    private static let jogMaxDelay: Double = 300_000_000

    // MARK: - The monitor's own menu
    //
    // Position and how long the menu stays up. Found by writing a different
    // number to each unmapped continuous sub-selector in one pass and then
    // reading HP's menu: whichever setting showed 55 named 0x3B, 56 named 0x3C,
    // 57 named 0x3E. One pass identified three controls that sampling could never
    // have found — none of them has ever appeared in the read rotation, across
    // roughly three thousand samples.
    //
    // Not readable, so asserted and persisted like the PiP group. The numbers are
    // the ones HP's menu shows: 0-100 for position, seconds for the timeout.

    @Published var osdMenuH: Int {
        didSet { UserDefaults.standard.set(osdMenuH, forKey: "osdMenuH") }
    }
    @Published var osdMenuV: Int {
        didSet { UserDefaults.standard.set(osdMenuV, forKey: "osdMenuV") }
    }
    @Published var osdMenuTimeout: Int {
        didSet { UserDefaults.standard.set(osdMenuTimeout, forKey: "osdMenuTimeout") }
    }

    /// Menu transparency, in the steps HP's own menu shows.
    ///
    /// The panel has eight steps and only SIX can be reached over DDC. Everything
    /// from raw 0 to 43 lands on 89, and everything from 95 to 200 lands on 35,
    /// so the two extremes — 100 and 25 — are settable from the monitor's buttons
    /// and not from here.
    ///
    /// The raw values were found one probe at a time, because the spacing is
    /// irregular (10, 10, 6, 6, 15) and three different curves fitted through the
    /// early points each predicted a step that turned out to be wrong. Walking it
    /// took nine round trips; guessing took three wrong answers first.
    enum Transparency: Int, CaseIterable, Identifiable {
        case p89 = 30
        case p78 = 58
        case p67 = 68
        case p57 = 74
        case p46 = 80
        case p35 = 95

        var id: Int { rawValue }

        /// What HP's menu calls this step.
        var shown: Int {
            switch self {
            case .p89: return 89
            case .p78: return 78
            case .p67: return 67
            case .p57: return 57
            case .p46: return 46
            case .p35: return 35
            }
        }
    }

    @Published var osdTransparency: Transparency? {
        didSet { UserDefaults.standard.set(osdTransparency?.rawValue ?? -1,
                                           forKey: "osdTransparency") }
    }

    func applyOSDMenu(transparency: Transparency) async {
        osdTransparency = transparency
        await writeSub(0x56, transparency.rawValue)
    }

    func applyOSDMenu(horizontal: Int) async {
        osdMenuH = max(0, min(100, horizontal))
        await writeSub(0x3B, osdMenuH)
    }

    func applyOSDMenu(vertical: Int) async {
        osdMenuV = max(0, min(100, vertical))
        await writeSub(0x3C, osdMenuV)
    }

    /// 5 to 60 seconds, the range HP's own slider offers.
    func applyOSDMenu(timeout seconds: Int) async {
        osdMenuTimeout = max(5, min(60, seconds))
        await writeSub(0x3E, osdMenuTimeout)
    }

    // MARK: Pivot (rotate whichever machine's desktop is on the panel)

    /// Where a Pivot rotation should land, decided by which machine the panel is
    /// currently showing. Rotating the machine that ISN'T on screen would be
    /// invisible — the Mac enumerates the panel even while a PC drives it — so the
    /// live input, not the display list, chooses the target.
    enum PivotTarget: Equatable {
        case mac(CGDirectDisplayID)   // the Mac is on screen: turn its framebuffer
        case agent(host: String)      // a PC is on screen: ask its agent to turn its desktop
        case none                     // nothing rotatable right now
    }

    var pivotTarget: PivotTarget {
        if kvm.panelShowsMac {
            if let id = pivotDisplayID { return .mac(id) }
            return .none
        }
        // A PC is on screen. Turn the machine on the live input — but only when it
        // is the host whose agent relay we already hold (the proxy host); a
        // different machine would need its own relay, which we do not keep open.
        if !proxyHost.isEmpty,
           let m = kvm.machines.first(where: { $0.input == kvm.currentInput }),
           m.host.lowercased() == proxyHost.lowercased() {
            return .agent(host: m.host)
        }
        return .none
    }

    /// True when there is something on the panel we can rotate right now.
    var pivotAvailable: Bool { pivotTarget != .none }

    /// Who the rotation will land on, for the card's status ("Mac" or a hostname).
    var pivotTargetLabel: String {
        switch pivotTarget {
        case .mac:              return "Mac"
        case .agent(let host):  return host
        case .none:             return ""
        }
    }

    /// The panel's local display id, but only when the Mac is the LIVE input —
    /// not merely enumerated. Through this dock the Mac lists the panel whether or
    /// not it is on screen, so `panelShowsMac` is the honest gate.
    var pivotDisplayID: CGDirectDisplayID? {
        guard kvm.panelShowsMac, let id = selectedID,
              displays.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// Rotation shown on the Pivot control. For the Mac it is the live framebuffer
    /// angle; for a PC it is the last angle we asked for (its desktop can't be read
    /// back cheaply).
    @Published var pivotDegrees: Int = 0
    @Published var pivotBusy = false

    /// Re-read the Mac's live rotation. Cheap, side-effect free; no-op for a PC.
    func refreshPivot() {
        if case .mac(let id) = pivotTarget { pivotDegrees = DisplayRotation.current(id) }
    }

    /// Rotate whatever machine is currently on the panel to `degrees`.
    func applyPivot(_ degrees: Int) async {
        guard !pivotBusy else {
            LinkWatchLog.write("PIVOT applyPivot(\(degrees)°) SKIPPED — already busy")
            return
        }
        LinkWatchLog.write("PIVOT applyPivot -> \(degrees)° target=\(pivotTargetLabel) autoFollow=\(pivotAutoFollow)")
        switch pivotTarget {
        case .mac(let id):
            pivotBusy = true
            _ = await DisplayRotation.rotate(id, to: degrees, fade: true)
            pivotDegrees = DisplayRotation.current(id)
            pivotBusy = false
            // Rotation changes the panel's bounds, and the KVM edge-map is built
            // from them — re-hand it the geometry so a crossing still lands.
            syncKVMPortal()
        case .agent(let host):
            pivotBusy = true
            if await rotateRemote(host: host, degrees: degrees) { pivotDegrees = degrees }
            pivotBusy = false
        case .none:
            break
        }
    }

    /// Ask the PC on the live input to rotate its own desktop. Goes through the
    /// shared agent relay, which lands in that machine's interactive session — the
    /// only place ChangeDisplaySettingsEx turns the visible desktop. The agent is
    /// already pointed at the proxy host, which is the live PC here.
    private func rotateRemote(host: String, degrees: Int) async -> Bool {
        do { try await agent.rotate(degrees: degrees); return true }
        catch { lastError = "Rotate on \(host) failed: \(error.localizedDescription)"; return false }
    }

    // MARK: Pivot auto-follow (physical orientation from the phone on rigel)

    /// Whether the app is tracking the panel's physical orientation and rotating
    /// to match. Off by default and not persisted: it only makes sense once the
    /// phone is mounted and calibrated, so arming it is a deliberate act.
    @Published var pivotAutoFollow = false
    /// A short line for the Pivot card: what the follow loop is currently doing.
    @Published var pivotFollowStatus = ""
    private var pivotFollowTask: Task<Void, Never>?

    func setPivotAutoFollow(_ on: Bool) {
        guard on != pivotAutoFollow else { return }
        pivotAutoFollow = on
        LinkWatchLog.write("PIVOT auto-follow \(on ? "ARMED" : "DISARMED")")
        pivotFollowTask?.cancel()
        pivotFollowStatus = ""
        if on { pivotFollowTask = Task { [weak self] in await self?.pivotFollowLoop() } }
        else  { pivotFollowTask = nil }
    }

    /// Poll the panel's physical orientation and rotate the Mac's picture to
    /// match. The reading arrives already snapped to 0/90/180/270 with the phone's
    /// own 45°-boundary hysteresis, so this only adds two guards: ignore readings
    /// while the panel lies flat (`inplane` low, orientation undefined), and
    /// require a changed orientation to persist across a couple of polls before
    /// committing a fade+rotate — so a hand brushing the panel mid-pivot, or a
    /// single stray sample, never kicks one off.
    private func pivotFollowLoop() async {
        var candidate: Int?
        var candidateSince = Date.distantPast
        var lastTried: Int?          // the orientation we last asked for…
        var lastTriedStuck = false   // …and whether it failed to take effect
        while !Task.isCancelled {
            // The phone is cabled to the proxy host (rigel) — not the Mac, and not
            // through the monitor's hub — so the feed is always read there, no
            // matter which machine currently drives the panel.
            let host = proxyHost
            guard !host.isEmpty else {
                pivotFollowStatus = "No PC set for the phone feed."
                try? await Task.sleep(nanoseconds: 2_000_000_000); continue
            }
            guard pivotAvailable else {
                pivotFollowStatus = "Waiting — nothing on the panel to rotate."
                candidate = nil
                try? await Task.sleep(nanoseconds: 1_500_000_000); continue
            }

            if let r = await PanelOrientation.read(host: host) {
                // Where the target actually sits now. The Mac we can read live, so
                // a sleep or signal-drop reset self-heals; a PC we cannot read
                // back, so we trust the last angle we set.
                let actual: Int
                if case .mac(let id) = pivotTarget { actual = DisplayRotation.current(id) }
                else { actual = pivotDegrees }

                if r.inplane < 1.5 {
                    pivotFollowStatus = "Panel near flat — holding \(actual)°."
                    candidate = nil
                } else if r.orient == actual {
                    pivotFollowStatus = "Following · \(r.orient)° (\(pivotTargetLabel))"
                    candidate = nil; lastTried = nil; lastTriedStuck = false
                } else if lastTriedStuck && lastTried == r.orient {
                    // Already tried this and it did not take — do not fade-loop;
                    // wait for the orientation to change again.
                    pivotFollowStatus = "Couldn't rotate to \(r.orient)°."
                    candidate = nil
                } else if candidate != r.orient {
                    candidate = r.orient
                    candidateSince = Date()
                    pivotFollowStatus = "Panel at \(r.orient)°…"
                } else if Date().timeIntervalSince(candidateSince) >= 0.3 {
                    candidate = nil
                    pivotFollowStatus = "Rotating to \(r.orient)°…"
                    await applyPivot(r.orient)   // fades / round-trips; suspends the loop
                    let now: Int
                    if case .mac(let id) = pivotTarget { now = DisplayRotation.current(id) }
                    else { now = pivotDegrees }
                    lastTried = r.orient
                    lastTriedStuck = (now != r.orient)
                }
            } else {
                pivotFollowStatus = "Phone feed unreachable via \(host)."
                candidate = nil
            }
            try? await Task.sleep(nanoseconds: 700_000_000)   // ~0.7 s between polls
        }
    }

    private var jogTask: Task<Void, Never>?
    private var jogDirection: Bool?
    private var jogDelay: UInt64 = 0

    /// Tell the KVM which panel is the doorway and where to land coming back.
    ///
    /// The doorway is the display this app is controlling — the one that shows
    /// the Mac on DisplayPort and the PC on USB-C. Its right edge is the
    /// crossing point, which is NOT the same thing as the right edge of the
    /// desktop: they coincide only because the panel happens to sit rightmost.
    ///
    /// Re-read whenever the layout changes, and note that switching the panel
    /// to the PC may take it out of the Mac's display list entirely — the KVM
    /// keeps the last known geometry for exactly that reason, since it still
    /// needs it to map the way back.
    func syncKVMPortal() {
        var portal: CGDirectDisplayID?
        let present = selectedID.map { id in displays.contains { $0.id == id } } ?? false
        if let id = selectedID, present {
            portal = id
        }
        kvm.configurePortal(display: portal)

        // The display list was once treated as authoritative here, on the
        // reasoning that it "cannot lie". Through this dock it does: the Mac
        // enumerates the panel whether or not it is the live input. Measured —
        // 0x60 read 17 (HDMI) while the Z27k was still listed among this Mac's
        // displays. Believing it made the app announce "panel is back on this
        // Mac" while the panel was plainly showing another machine, and then
        // overwrite the tracked input with DisplayPort, corrupting the one piece
        // of state the input watcher relies on.
        //
        // 0x60 is the honest signal, and it does track changes nobody commanded,
        // including switches made on the monitor's own buttons. So when there is
        // a control channel the watcher owns which input is live, and the
        // display list is used only to choose the portal display.
        //
        // Without a control channel there is no reading to prefer, and the
        // display list is all there is — so the old behaviour stands in.
        if !haveSettledInput {
            kvm.panelShowsMac = present
            kvm.currentInput = present ? kvm.macInput : lastCommandedInput
            if present && lastCommandedInput != kvm.macInput {
                lastCommandedInput = kvm.macInput
                KVMLog.write("panel is back on this Mac (display list); corrected the tracked input")
            }
        }
    }

    /// The input the panel was last told to show.
    ///
    /// Tracked here because it cannot be read back. Persisted so a relaunch does
    /// not start out believing the panel is on DisplayPort when it is not.
    @Published var lastCommandedInput: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(lastCommandedInput), forKey: "lastCommandedInput")
            kvm.currentInput = lastCommandedInput
        }
    }

    private let machineChooser = MachineChooser()
    private let screenTransition = ScreenTransition()
    /// True while a chooser pick is mid-dissolve, so a second pick cannot start a
    /// competing transition (and cannot happen anyway — the chooser is closed).
    private var switchTransitioning = false

    /// Wire the panel-switching side of the KVM. Kept out of init because it
    /// needs the monitor profile, which is not known until a probe has run.
    private func wireKVMInputs() {
        kvm.macInput = HPProfile.inputNames.first { $0.value == "DisplayPort"  }?.key ?? 0x0F
        kvm.pcInput  = HPProfile.inputNames.first { $0.value == "USB-C1 Video" }?.key ?? 0x13
        kvm.setMonitorInput = { [weak self] value in
            Task { @MainActor in self?.requestMonitorInput(value, byHand: false) }
        }
        // Put the question on the panel the pointer just reached, which is the
        // screen the user is looking at when they ask it.
        kvm.presentChooser = { [weak self] exit in
            guard let self else { return }
            // The pick comes back as an INDEX and is applied to kvm.machines, so
            // the tiles must be built from that same array. kvmMachines is the
            // editable copy, made equal to it only when the KVM is armed; feed
            // the chooser from that and a tile labelled Rigel can pick Bellatrix.
            self.machineChooser.show(on: self.selectedID,
                                     machines: self.kvm.machines,
                                     near: exit,
                                     pick: { [weak self] index in
                                         self?.switchInputWithDissolve(pickIndex: index)
                                     },
                                     cancel: { [weak self] in
                                         self?.kvm.cancelChoice()
                                         self?.syncKVMState()
                                     })
        }
        // Pointer moved back off the edge with the chooser still open: slide it
        // shut and stand the crossing down, the same teardown a cancel does.
        kvm.dismissChooser = { [weak self] in
            guard let self else { return }
            self.machineChooser.close(animated: true)
            self.kvm.cancelChoice()
            self.syncKVMState()
        }
        // No DDC channel means the panel's input cannot be switched, so a
        // crossing that would need one is refused before the pointer is
        // captured: no tiles, no frozen cursor. See KVMController.canSwitchPanel.
        kvm.canSwitchPanel = { [weak self] in self?.transport.isAvailable ?? false }
        // What the KVM falls back to when a machine's primary (Tailscale) name is
        // unreachable — the whole reason "KVM before login" failed after a reboot:
        // the box was on the LAN but not yet on Tailscale. Prefer the IP the
        // machine announced itself from (looked up live, so a box that moved keeps
        // working); when it is not discovered — a hand-pinned host, or one just
        // rebooted and not yet on the tailnet — fall back to its LAN mDNS name,
        // which is up as soon as the box is. Only a bare short name has a `.local`.
        kvm.addressForHost = { [weak self] host in
            let target = self?.discovery.agents[host.lowercased()]?.fallbackTarget ?? ""
            if !target.isEmpty { return target }
            return (host.contains(".") || host.isEmpty) ? nil : "\(host).local"
        }
        // Coming home gets the mirror of a pick's dissolve: fade the machine out
        // on its own side, switch, then reveal the Mac with its curtain.
        kvm.beginReturnDissolve = { [weak self] leavingHost in
            self?.runReturnDissolve(leavingHost: leavingHost)
        }
    }

    private static let dissolveFade: Double = 0.7   // fade the leaving side to black
    private static let revealFade: Double = 2.1     // fade the arriving side up from black

    /// How long the panel takes to renegotiate a DDC input switch and LIGHT the
    /// new source, before the reveal clears the arriving curtain onto it.
    ///
    /// Keyed on the INPUT, not the machine — so it needs no per-PC tuning: zBezel
    /// detects the input from the panel, and a freshly installed PC gets the value
    /// for its cable automatically, whatever box it is. It has to vary by input
    /// because they do not light alike: HDMI (HDCP/link training) lights at ~5s,
    /// DisplayPort and USB-C at ~4s. The reveal must land WHEN the panel lights —
    /// too late and a fast input wakes showing its desktop for the gap before the
    /// reveal (a visible flash-then-black); too early and a slow one pops in at
    /// full. There is no readable "pixels are up" signal on this panel to make it
    /// adaptive (0xD6 reads "on" straight through the dark switch), so it is a
    /// per-input timed wait. Raise a value if that input flashes, lower it if it
    /// sits on black too long.
    private static func revealWait(forInput input: UInt16) -> UInt64 {
        switch input {
        case 0x11: return 5_500_000_000   // HDMI — lights latest
        default:   return 3_900_000_000   // DisplayPort (0x0F) / USB-C1 (0x13)
        }
    }

    /// A chooser tile was clicked (Mac -> machine). A dissolve, both sides in
    /// software: the Mac fades out under its own curtain, then — once the panel
    /// has switched — the machine fades itself in under a black curtain its agent
    /// draws over its own screen. No backlight: a DDC brightness ramp is smooth on
    /// a direct link but can only step coarsely over the proxy, which is the
    /// abruptness to avoid. See ScreenTransition and BezelAgent's FadeOverlay.
    private func switchInputWithDissolve(pickIndex index: Int) {
        guard !switchTransitioning else { return }
        // Settle the pick at once: this clears the choosing state and stands the
        // edge down for the length of the dissolve, so a pointer drift cannot
        // cancel the crossing or start another. A pick this chain cannot honour
        // stands itself down and gets no animation.
        guard kvm.takeChoice(at: index) else { syncKVMState(); return }
        syncKVMState()
        guard kvm.machines.indices.contains(index) else {
            switchTransitioning = false; return
        }
        let arrivingHost = kvm.machines[index].host
        let arrivingInput = kvm.machines[index].input

        switchTransitioning = true
        let display = selectedID
        Task { @MainActor in
            defer { switchTransitioning = false; kvm.deferCenterPark = false }

            // 1. Dissolve the Mac (being left) to a blurred black (700 ms).
            await screenTransition.fadeToBlack(on: display, duration: Self.dissolveFade)
            // 2. Carry the pointer across and command the input switch. handOver
            //    reopens the machine's channel if need be, so the arm below lands.
            //    deferCenterPark leaves the cursor where it is rather than jumping
            //    it to the panel centre — the panel is still the Mac's black
            //    curtain, where a centred cursor would show on the black.
            kvm.deferCenterPark = true
            kvm.commitChoice()
            syncKVMState()
            // 3. Arm the arriving machine's own curtain black NOW, while the panel
            //    is still renegotiating and the machine is not yet on screen — so
            //    it shows black, not a flash of desktop, when the panel reaches it.
            //    Instant (ms 0): there is nothing to animate behind a dead input.
            // 3. Arm the machine's curtain black. Its agent then holds it on top on
            //    its own fast timer (see FadeOverlay) — an input that sleeps its
            //    output off-panel (HDMI on bellatrix) wakes showing the last desktop
            //    frame for an instant, and only a local re-assert is quick enough to
            //    cover that; a Mac round-trip is not. Instant (ms 0): nothing to
            //    animate behind a dead input.
            kvm.fadeMachine(host: arrivingHost, toOpaque: 100, overMs: 0)
            // 4. Give the panel time to light the machine's input (per input —
            //    HDMI lights later), so the reveal lands on a lit panel.
            try? await Task.sleep(nanoseconds: Self.revealWait(forInput: arrivingInput))
            // 5. The panel is on the machine now, so the centre is behind it and
            //    safe to hide the cursor in. Then fade the machine in on its own
            //    side, and take the Mac's curtain down — invisible behind the
            //    machine's input.
            kvm.reparkAtPanelCentre()
            kvm.deferCenterPark = false
            kvm.fadeMachine(host: arrivingHost, toOpaque: 0, overMs: Int(Self.revealFade * 1000))
            screenTransition.end()
            // Hold the transition open until the machine has finished fading in, so
            // a quick re-cross cannot interrupt it half-lit.
            try? await Task.sleep(nanoseconds: UInt64(Self.revealFade * 1_000_000_000))
        }
    }

    /// The pointer crossed home (machine -> Mac): the mirror of a pick. The
    /// machine fades itself out under its agent's curtain (it is the one on
    /// screen), then — once the panel has switched home — the Mac reveals under
    /// its own curtain clearing. Both sides in software, no backlight. Called by
    /// KVM.handBack via beginReturnDissolve, which has suspended the edge and
    /// passes the host being left.
    private func runReturnDissolve(leavingHost: String) {
        let macInput = kvm.macInput
        // Busy with another dissolve: just switch home plainly and re-arm the edge.
        guard !switchTransitioning else {
            Task { @MainActor in
                await set(code: VCP.inputSelect.code, value: macInput, byHand: false)
                kvm.resumeEdge()
            }
            return
        }

        switchTransitioning = true
        let display = selectedID
        Task { @MainActor in
            defer { switchTransitioning = false; inputSwitchRunning = false; kvm.resumeEdge() }

            // 1. Fade the machine (still on the panel) out on its own side (700 ms).
            kvm.fadeMachine(host: leavingHost, toOpaque: 100, overMs: 700)
            try? await Task.sleep(nanoseconds: 700_000_000)
            // 2. Arm the Mac's curtain black behind the machine's input, so the Mac
            //    is covered the instant the panel switches to it.
            screenTransition.coverInstantly(on: display)
            // 3. Switch the panel home. Hold the input watcher off across the
            //    renegotiation — this write bypasses requestMonitorInput's coalescer,
            //    so nothing else sets inputSwitchRunning, and a poll mid-switch reads
            //    the transit and fires a spurious lock/release.
            inputSwitchRunning = true
            await set(code: VCP.inputSelect.code, value: macInput, byHand: false)
            // 4. Give the panel time to light the Mac's input before revealing.
            try? await Task.sleep(nanoseconds: Self.revealWait(forInput: macInput))
            inputSwitchRunning = false
            // 5. Reveal the Mac — clear its curtain (blurred black to sharp).
            await screenTransition.clear(duration: Self.revealFade)
            // 6. Clear the machine's own curtain now that it is off the panel, so
            //    its desktop is normal again for a View or RDP window. Invisible:
            //    the panel is showing the Mac.
            kvm.fadeMachine(host: leavingHost, toOpaque: 0, overMs: 0)
        }
    }

    private var desiredInput: UInt16?
    private var lastRequestedInput: UInt16?
    private var inputSwitchRunning = false

    /// Ask the panel for an input, coalescing bursts and never overlapping.
    ///
    /// A DDC input switch is not instant — the panel renegotiates the link and
    /// takes several seconds — and crossing the edge issues one of these each
    /// way. Crossings 1.6 seconds apart therefore put two switches in flight at
    /// once and the panel ended up wherever the collision left it, which looked
    /// exactly like the return crossing failing to switch back at all.
    ///
    /// Swift actors make that worse: calls awaiting an actor are not guaranteed
    /// to resume in the order they were made, so two writes issued a second
    /// apart could be applied backwards.
    ///
    /// So: one writer at a time, the most recent request wins, and a reversal
    /// inside the coalescing window asks for nothing at all — which is what
    /// changing your mind that quickly should mean.
    /// Put the panel on an input.
    ///
    /// `byHand` is the difference between the KVM moving the panel as the pointer
    /// travels and the user choosing an input themselves. Choosing one by hand
    /// overrules any lock: the lock exists to stop the panel following the
    /// pointer home, and someone reaching for the input list has plainly decided
    /// where they want the panel to be.
    // MARK: - Following the panel

    /// Notices the input changing and takes the pointer with it, however the
    /// change was made — including on the monitor's own buttons. See
    /// InputWatcher for why this polls rather than waiting on an interrupt.
    private var inputWatcher = InputWatcher()
    private var inputWatchTask: Task<Void, Never>?
    /// Set once 0x60 has given a settled reading. Until then the display list is
    /// the only signal available, however unreliable.
    private var haveSettledInput = false

    func startWatchingInput() {
        guard inputWatchTask == nil else { return }   // already watching
        KVMLog.write("input watch: started (throttled 20s / 180s idle)")
        // RESTORED after the amber-blink DDC experiment concluded: the drop
        // recurred with zBezel doing zero DDC (poll off), so its DDC is EXONERATED
        // and there is no reason to keep the poll off — and the KVM depends on it.
        // Tracking 0x60 is what tells the app which input the panel shows, which
        // drives panelShowsMac/lockedIndex; with it off, a panel returned to the
        // Mac out-of-band (e.g. an amber-blink recovery) is never noticed, so the
        // doorway logic thinks a PC is up and puts the crossing on the built-in's
        // edge instead of the panel's. Adaptive cadence keeps DDC light: 20s while
        // the user is active, 180s once idle 5 min, snapping back on activity.
        inputWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollInput()
                if self.secondsSinceUserInput() < 300 {
                    try? await Task.sleep(nanoseconds: 20 * 1_000_000_000)
                } else {
                    var waited = 0
                    while waited < 180, !Task.isCancelled,
                          self.secondsSinceUserInput() >= 300 {
                        try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                        waited += 5
                    }
                }
            }
        }
    }

    /// Seconds since the user last physically used the mouse or keyboard, for the
    /// adaptive poll cadence above. Real HID activity registers here even while
    /// the KVM event tap consumes it, so driving a remote PC keeps the fast rate.
    private func secondsSinceUserInput() -> CFTimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .leftMouseDragged, .keyDown, .flagsChanged, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
    }

    func stopWatchingInput() {
        guard inputWatchTask != nil else { return }
        KVMLog.write("input watch: stopped — no control channel to the monitor")
        inputWatchTask?.cancel()
        inputWatchTask = nil
    }

    private func pollInput() async {
        guard transport.isAvailable else { return }
        // Never read over the top of a switch we are performing: that reading is
        // taken mid-renegotiation, which is the least trustworthy moment there is.
        guard !inputSwitchRunning else { return }

        let readings = await reread(codes: [VCP.inputSelect.code])
        guard let value = readings[VCP.inputSelect.code] else {
            KVMLog.write("input watch: no reading from 0x60")
            return
        }

        guard let reading = inputWatcher.observe(value,
                                                 machines: kvm.machines,
                                                 macInput: kvm.macInput) else { return }

        // Publish the state on EVERY settled reading, not only when something
        // needs doing. This is what the pointer crossing consults to decide
        // where to hand control: with the panel showing a machine, a crossing at
        // the edge goes to that machine. Reporting only on change meant a launch
        // with the panel already elsewhere left the crossing believing the panel
        // was on this Mac, so pushing at the edge did nothing.
        //
        // The controller cannot read any of this back on its own and otherwise
        // only learns what it commanded.
        let settled = reading.value
        lastCommandedInput = settled
        lastRequestedInput = settled   // observed, not commanded — see set() for why it matters
        kvm.currentInput = settled
        // And this, not the display list, is what "the panel is showing the Mac"
        // means from here on: see the note in syncKVMPortal.
        let showsMac = (settled == kvm.macInput)
        if kvm.panelShowsMac != showsMac {
            kvm.panelShowsMac = showsMac
            KVMLog.write("input watch: panel is showing "
                       + (showsMac ? "this Mac" : HPProfile.inputLabel(settled)))
        }
        haveSettledInput = true

        guard let action = reading.action else { return }

        switch action {
        case .release:
            KVMLog.write("input watch: returned to this Mac; releasing the lock")
            kvm.clearLock()
        case .lock(let index, let why):
            guard kvm.machines.indices.contains(index) else { break }
            let host = kvm.machines[index].host
            // The panel being on the machine the KVM is actively controlling is
            // the KVM's own crossing, not a switch someone made by hand — locking
            // to it would pin the panel and stop the pointer returning to the Mac,
            // which is exactly the bounce-and-no-badge bug. Adopt it as the
            // baseline instead. A by-hand switch to a DIFFERENT machine still locks.
            guard !kvm.isControlling(host: host) else {
                inputWatcher.resync(to: kvm.machines[index].input)
                KVMLog.write("input watch: panel on \(host) is the KVM's own crossing; not locking")
                break
            }
            if !kvm.lockTo(machineIndex: index, why: why) {
                KVMLog.write("input watch: wanted to lock to \(host) but could not")
            }
        case .unknownInput(let value):
            KVMLog.write("input watch: panel moved to \(HPProfile.inputLabel(value)) "
                       + "(0x\(String(value, radix: 16))) — no machine configured for it")
        }
    }

    func requestMonitorInput(_ value: UInt16, byHand: Bool = true) {
        if byHand { kvm.followManualInput(value) }
        // We are about to move the panel ourselves, so the watcher should adopt
        // the new value as its baseline rather than treat our own switch as
        // something to follow.
        inputWatcher.resync(to: value)
        desiredInput = value
        lastCommandedInput = value
        guard !inputSwitchRunning else { return }
        inputSwitchRunning = true

        Task { @MainActor in
            defer { inputSwitchRunning = false }
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let target = desiredInput else { return }
                desiredInput = nil

                if target == lastRequestedInput { continue }   // already going there
                lastRequestedInput = target
                await set(code: VCP.inputSelect.code, value: target, byHand: false)

                // Let the panel finish. A write landing mid-renegotiation is
                // simply lost, and the reads during it report the transition
                // rather than the destination.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if desiredInput == nil { return }
            }
        }
    }

    /// Turn the software KVM on or off.
    ///
    /// Switching on asks the far machine how big its desktop is first. The Mac
    /// sends absolute positions, so without that number they would mean
    /// different things at each end and the pointer would land in the wrong
    /// place — badly on a 4K display driven from a smaller Mac screen.
    /// The machines the pointer can reach, left to right.
    ///
    /// Persisted as JSON because it is a list the user arranges, not a single
    /// setting. Seeded on first run from the proxy host, since a machine that can
    /// drive the monitor's controls is by definition one plugged into it.
    @Published var kvmMachines: [KVMController.Machine] {
        didSet {
            if let data = try? JSONEncoder().encode(kvmMachines) {
                UserDefaults.standard.set(data, forKey: "kvmMachines")
            }
            // A machine added or removed is worth an immediate parity read, so
            // its dot is not blank until the next scheduled sweep.
            checkParity()
        }
    }

    // MARK: - Agent source-code parity

    /// Per host: does the deployed agent match the source this app ships, is it
    /// merely running, or is the box even reachable. Drives the KVM row's dot.
    @Published private(set) var machineHealth: [String: MachineHealth] = [:]

    private var parityTimer: Timer?
    private var parityRef: String?
    private var parityInFlight: Set<String> = []
    private var lastParityCheck = Date.distantPast

    /// Start the occasional parity sweep. The interval is generous on purpose:
    /// this is a background reassurance, not a live meter, and every tick is an
    /// SSH round trip per machine.
    func startParityMonitor() {
        parityRef = AgentParity.bundledSourceHash()
        parityTimer?.invalidate()
        parityTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkParity() }
        }
        checkParity()
    }

    /// A check on demand (the card appeared), throttled so re-showing the tab
    /// does not fire a burst of SSH probes.
    func checkParityNow(throttle: TimeInterval = 25) {
        guard Date().timeIntervalSince(lastParityCheck) >= throttle else { return }
        checkParity()
    }

    private func checkParity() {
        guard let ref = parityRef ?? AgentParity.bundledSourceHash() else { return }
        parityRef = ref
        lastParityCheck = Date()

        // Forget machines no longer in the chain.
        let hosts = Set(kvmMachines.map(\.host))
        for key in machineHealth.keys where !hosts.contains(key) { machineHealth[key] = nil }

        for machine in kvmMachines {
            let host = machine.host
            guard !host.isEmpty, !parityInFlight.contains(host) else { continue }
            parityInFlight.insert(host)
            if machineHealth[host] == nil { machineHealth[host] = .unknown }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let health = AgentParity.probe(host: host, reference: ref)
                DispatchQueue.main.async {
                    guard let self else { return }
                    let before = self.machineHealth[host]
                    self.machineHealth[host] = health
                    self.parityInFlight.remove(host)

                    // A machine that has just come back — booted, signed in,
                    // agent started — is the usual reason there was no link a
                    // moment ago. This sweep already paid for the SSH round
                    // trip, so let the transport find out now rather than at
                    // the end of its backoff.
                    let wasDown: Bool
                    switch before {
                    case .unreachable, .notRunning: wasDown = true
                    default: wasDown = false
                    }
                    // And re-probe too when the machine that came back is the one
                    // the link is riding: its agent has just restarted, so what
                    // the transport still names is a channel to a process that no
                    // longer exists. A DIFFERENT host coming back while the link
                    // is healthy is not a reason to tear a working link down.
                    let carriesTheLink: Bool
                    if case .proxy(let current, _, _) = self.transport {
                        carriesTheLink = current.caseInsensitiveCompare(host) == .orderedSame
                    } else {
                        carriesTheLink = false
                    }
                    if wasDown, health == .ok || health == .mismatch,
                       self.transport == .none || carriesTheLink {
                        self.reprobeSoon()
                    }
                }
            }
        }
    }

    // MARK: - Discovery

    /// Bring up LAN discovery and keep the machine set in step with it. Called
    /// once from bootstrap. Every announce that changes the set of live machines
    /// runs applyDiscovery, which is what makes machines appear and drop on their
    /// own — including while the KVM is armed.
    func startDiscovery() {
        discovery.onChange = { [weak self] in self?.applyDiscovery() }
        discovery.start()
        applyDiscovery()      // in case packets already landed before we wired up
    }

    /// Rebuild the machine set from what the network shows right now, plus any
    /// hand-pinned hosts, and push it into the live chain. Discovered machines
    /// arrive already knowing their input (from the product code the agent
    /// reported); a size we learned earlier is carried over, otherwise the panel's
    /// native 4K stands in until the next arm sizes it for real.
    func applyDiscovery() {
        var next: [KVMController.Machine] = []
        for agent in discovery.agents.values
            .sorted(by: { $0.host.lowercased() < $1.host.lowercased() }) {
            var machine = KVMController.Machine(name: agent.host, host: agent.host,
                                                input: agent.input, width: 3840, height: 2160)
            // A hand-pinned size is AUTHORITATIVE — the user set it precisely
            // because discovery/learning gets it wrong. rigel is the case in
            // point: it reports its RDP virtual display (1920x1080) rather than
            // its real console (3840x2160), and that stale learned value, once
            // carried over, halves the KVM pointer range at the sign-in screen.
            // So prefer the pin; fall back to a carried-over learned size only
            // when there is no pin.
            if let pin = manualPins.first(where: {
                $0.host.lowercased() == agent.host.lowercased() }), pin.width > 1 {
                machine.width = pin.width
                machine.height = pin.height
            } else if let known = kvmMachines.first(where: {
                $0.host.lowercased() == agent.host.lowercased() }), known.width > 1 {
                machine.width = known.width
                machine.height = known.height
            }
            next.append(machine)
        }
        for pin in manualPins where !next.contains(where: {
            $0.host.lowercased() == pin.host.lowercased() }) {
            next.append(pin)
        }

        // Only churn when the shape actually changed — the onChange that called us
        // already filters heartbeats, but a size carry-over can leave it identical.
        let unchanged = next.count == kvmMachines.count && zip(next, kvmMachines).allSatisfy {
            $0.host == $1.host && $0.input == $1.input
        }
        guard !unchanged else { return }

        kvmMachines = next
        kvm.updateChain(next)
    }

    /// Pin a host by hand, for a machine discovery will not see on its own.
    func addManualPin(host: String, input: UInt16) {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !manualPins.contains(where: { $0.host.lowercased() == trimmed.lowercased() })
        else { return }
        manualPins.append(KVMController.Machine(name: trimmed, host: trimmed, input: input))
        applyDiscovery()
    }

    /// Forget a hand-pinned host. A discovered machine cannot be forgotten this
    /// way — it drops on its own when it stops announcing — so this only touches
    /// the pins.
    func forgetMachine(host: String) {
        manualPins.removeAll { $0.host.lowercased() == host.lowercased() }
        applyDiscovery()
    }

    /// True for a host the user pinned, as opposed to one discovery surfaced.
    /// The remove control is only meaningful for these.
    func isManualPin(host: String) -> Bool {
        let key = host.lowercased()
        if manualPins.contains(where: { $0.host.lowercased() == key }) { return true }
        return discovery.agents[key] == nil     // not discovered ⇒ it is a leftover pin
    }

    /// Whether the network has surfaced this host in the last sweep.
    func isDiscovered(host: String) -> Bool { discovery.agents[host.lowercased()] != nil }

    static func loadKVMMachines(proxyHost: String) -> [KVMController.Machine] {
        if let data = UserDefaults.standard.data(forKey: "kvmMachines"),
           let list = try? JSONDecoder().decode([KVMController.Machine].self, from: data),
           !list.isEmpty {
            return list
        }
        guard !proxyHost.isEmpty else { return [] }
        return [KVMController.Machine(name: proxyHost, host: proxyHost,
                                      input: HPProfile.inputNames
                                        .first { $0.value == "USB-C1 Video" }?.key ?? 0x13)]
    }

    func setKVM(_ on: Bool) async {
        // Remember the choice even if bringing it up fails, so a host that was
        // simply asleep does not silently switch the feature off for good.
        UserDefaults.standard.set(on, forKey: "kvmEnabled")
        guard on != kvm.isEnabled else { return }
        if on {
            guard !kvmMachines.isEmpty || !proxyHost.isEmpty else {
                kvmError = "No machines yet. One running the agent will appear on its own, "
                         + "or pin a host on the Link tab."
                return
            }
            wireKVMInputs()
            syncKVMPortal()
            // Deliberately does NOT re-point the DDC agent. Its host belongs to
            // the transport, which may well have settled on a different machine
            // than proxyHost; pointing it here re-aimed the monitor controls at
            // whichever host the KVM happened to lead with, while the transport
            // still described the one that answered. Nothing below needs it —
            // the desktop sizes come from RemoteAgent.desktopSize, which opens
            // its own short-lived ssh per machine.

            // Size every machine in the chain, not just the proxy. A machine
            // whose size cannot be read keeps whatever it had: a wrong size makes
            // the pointer reach an edge early or late, which is annoying, while
            // refusing to start makes the whole feature unavailable.
            let exe = #"$HOME\bezel\BezelAgent.exe"#
            var chain = kvmMachines
            var unreachable: [String] = []
            for i in chain.indices {
                // A hand-pinned size is authoritative — never overwrite it with a
                // learned one. rigel reports its RDP virtual display (1920x1080)
                // from desktopSize rather than its real console (3840x2160), and
                // learning that halves the KVM pointer range at the sign-in screen.
                if let pin = manualPins.first(where: {
                    $0.host.lowercased() == chain[i].host.lowercased() }), pin.width > 1 {
                    chain[i].width = pin.width
                    chain[i].height = pin.height
                } else if let size = RemoteAgent.desktopSize(host: chain[i].host, exePath: exe) {
                    chain[i].width = size.width
                    chain[i].height = size.height
                } else if chain[i].width <= 1 {
                    unreachable.append(chain[i].name)
                }
            }
            kvmMachines = chain
            kvm.machines = chain
            if !unreachable.isEmpty {
                kvmError = "Could not read the screen size of "
                         + unreachable.joined(separator: ", ")
                         + "; using the last known size."
            }
            let size = chain.first?.size
            if let problem = kvm.enable(host: chain.first?.host ?? proxyHost,
                                        exePath: #"$HOME\bezel\BezelAgent.exe"#,
                                        remoteSize: size) {
                kvmError = problem
                syncKVMState()
                return
            }

            // Wait for the agent's own reply rather than trusting that ssh
            // started. Roughly a second of that budget is PowerShell login-shell
            // startup on the far side, which is unavoidable and paid once here
            // instead of at every crossing.
            let deadline = Date().addingTimeInterval(8)
            while !kvm.transportReady, Date() < deadline, kvm.transportConnected {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            kvm.noteReadiness()
            if !kvm.transportReady {
                kvmError = kvm.transportError
                    ?? "\(proxyHost) did not answer. Check that the agent is installed and running."
            }
        } else {
            kvm.disable()
            kvmError = nil
        }
        syncKVMState()
    }

    /// Unwind the KVM synchronously on the way out.
    ///
    /// Handing control over decouples the pointer from the mouse and hides the
    /// cursor. Quitting while that is in force would leave the Mac with a mouse
    /// that moves nothing, so this cannot be left to an async Task that may not
    /// get a chance to run before the process goes.
    func shutdownKVM() {
        kvm.disable()
    }

    /// Every code this monitor declares that the standard does not define.
    var vendorCodes: [UInt8] {
        capabilities?.manufacturerCodes ?? []
    }

    /// Record where the vendor codes sit right now, so a later reading can be diffed.
    func snapshotVendorCodes() async {
        guard !vendorCodes.isEmpty, !mapperBusy else { return }
        mapperBusy = true
        vendorCancelled = false
        defer { mapperBusy = false; vendorCancelled = false }
        vendorChanges = []
        vendorBaseline = await reread(codes: vendorCodes.filter {
            !HPProfile.subAddressedCodes.contains($0)
        })
        vendorSubBaseline = await sampleSubAddressed()
    }

    /// Sample every sub-addressed code's selector map.
    ///
    /// 250 reads per code, because the rotation is lopsided and its bias shifts
    /// with the panel's state — a selector can be 80% of one pass and absent from
    /// the next. A small sample makes absence look like a change.
    private func sampleSubAddressed() async -> [UInt8: [UInt8: UInt16]] {
        guard case .proxy(_, let index, _) = transport else { return [:] }
        var out: [UInt8: [UInt8: UInt16]] = [:]
        for code in vendorCodes where HPProfile.subAddressedCodes.contains(code) {
            var merged: [UInt8: UInt16] = [:]
            // In chunks, so Cancel is answered within a second or two rather than
            // at the end of a quarter-thousand reads.
            for _ in 0..<5 {
                if vendorCancelled { return out }
                if let map = try? await agent.readSubSelectorMap(
                    monitor: index, code: code, samples: 50) {
                    merged.merge(map) { _, new in new }
                }
            }
            out[code] = merged
        }
        return out
    }

    /// Re-read and report what moved since the snapshot.
    func compareVendorCodes() async {
        guard let baseline = vendorBaseline, !mapperBusy else { return }
        mapperBusy = true
        vendorCancelled = false
        defer { mapperBusy = false; vendorCancelled = false }

        let now = await reread(codes: vendorCodes.filter {
            !HPProfile.subAddressedCodes.contains($0)
        })
        var changes: [VendorChange] = now.compactMap { code, value in
            guard let before = baseline[code], before != value else { return nil }
            return VendorChange(code: code, before: before, after: value, selector: nil)
        }

        // Sub-addressed codes are diffed per selector, and only where the selector
        // turned up in BOTH samples. A selector missing from one pass says nothing
        // about whether it changed — it says the rotation did not offer it.
        let after = await sampleSubAddressed()
        for (code, nowMap) in after {
            guard let beforeMap = vendorSubBaseline[code] else { continue }
            for (selector, value) in nowMap {
                guard let was = beforeMap[selector], was != value else { continue }
                changes.append(VendorChange(code: code, before: was,
                                            after: value, selector: selector))
            }
        }
        vendorChanges = changes
        .sorted { $0.code < $1.code }
    }

    /// Bind a control to a code that was observed to move with it.
    func bind(_ control: VendorControl, to change: VendorChange) {
        // The reading before the change corresponds to the option that was
        // selected before, and the reading after to the one selected now. Which
        // is which is the operator's call, so record both and let them re-run
        // the pass to confirm rather than inferring an ordering we cannot know.
        var values = control.isToggle
            ? [min(change.before, change.after), max(change.before, change.after)]
            : [change.before, change.after]
        while values.count < control.options.count { values.append(values.last ?? 0) }

        vendorMap[control] = VendorBinding(
            code: change.code,
            optionValues: values,
            evidence: "observed changing \(change.description) during a mapping pass")
    }

    func unbind(_ control: VendorControl) { vendorMap[control] = nil }

    /// Readings for sub-addressed vendor controls, which a plain read cannot give.
    ///
    /// Kept on disk. These settings are only visible when the monitor's selector
    /// rotation happens to offer them, so a launch that does not catch one used
    /// to leave its radio group with nothing selected — a control that reads as
    /// "off, and also not on". A remembered value is a truthful answer to "what
    /// did this last read as", and is labelled as remembered until the panel
    /// confirms it.
    @Published private(set) var vendorReadings: [String: VendorReading] = [:] {
        didSet { saveVendorReadings() }
    }

    /// A sample is in flight, so an unconfirmed value is about to be checked
    /// rather than merely stale.
    @Published private(set) var vendorSampling = false

    private var lastVendorSample: Date?

    private static let vendorReadingsKey = "vendorReadings"

    private func saveVendorReadings() {
        guard let data = try? JSONEncoder().encode(vendorReadings) else { return }
        UserDefaults.standard.set(data, forKey: Self.vendorReadingsKey)
    }

    /// Restore last launch's readings, none of them confirmed: this session has
    /// not seen the panel say anything yet.
    private static func loadVendorReadings() -> [String: VendorReading] {
        guard let data = UserDefaults.standard.data(forKey: vendorReadingsKey),
              let decoded = try? JSONDecoder().decode([String: VendorReading].self, from: data)
        else { return [:] }
        return decoded.mapValues { VendorReading(value: $0.value, takenAt: $0.takenAt,
                                                 confirmed: false) }
    }

    func currentValue(for control: VendorControl) -> UInt16? {
        guard let binding = vendorMap[control] else { return nil }
        if binding.isSubAddressed { return vendorReadings[control.rawValue]?.value }
        return features[binding.code]?.current
    }

    func reading(for control: VendorControl) -> VendorReading? {
        guard let binding = vendorMap[control], binding.isSubAddressed else { return nil }
        return vendorReadings[control.rawValue]
    }

    /// Record a value we asked for but have not yet seen the panel report back.
    func noteVendorWrite(_ control: VendorControl, value: UInt16) {
        vendorReadings[control.rawValue] = VendorReading(value: value, takenAt: Date(),
                                                         confirmed: false)
    }

    /// Resolve every sub-addressed binding from a shared sample of the code.
    ///
    /// Sampled in chunks with a per-selector early exit, and it still often comes
    /// back with nothing. 0xE1 is not a rotation that will eventually offer every
    /// selector: it is pinned, and what pins it is not under this app's control.
    /// A 200-read pass on 2026-09-01 returned selector 0x11 two hundred times out
    /// of two hundred, and neither reading it nor writing a different selector
    /// (0x1300 and 0x1301, both accepted) moved it off 0x11. Earlier passes were
    /// pinned just as hard on 0x13. So sampling is worth one attempt and is not
    /// worth waiting on — which is why the readings are kept on disk and this
    /// runs detached.
    ///
    /// `cooldown` refuses a sample taken too soon after the last one. A selector
    /// that never surfaces leaves the readings permanently "incomplete", and
    /// without this the automatic refresh on every panel appearance would spend
    /// half a minute on the wire each time re-asking a question the monitor has
    /// already declined to answer.
    func refreshVendorReadings(chunks: Int = 8, samples: Int = 60,
                               cooldown: TimeInterval = 0) async {
        guard case .proxy(_, let index, _) = transport, !vendorSampling else { return }
        if cooldown > 0, let last = lastVendorSample,
           Date().timeIntervalSince(last) < cooldown { return }
        lastVendorSample = Date()

        let subAddressed = VendorControl.allCases.compactMap { control -> (VendorControl, VendorBinding)? in
            guard let binding = vendorMap[control], binding.isSubAddressed else { return nil }
            return (control, binding)
        }
        guard !subAddressed.isEmpty else { return }

        vendorSampling = true
        defer { vendorSampling = false }

        for code in Set(subAddressed.map { $0.1.code }) {
            var wanted = Set(subAddressed.filter { $0.1.code == code }.compactMap { $0.1.selector })
            let started = Date()
            var reads = 0
            var seen: Set<UInt8> = []
            var barren = 0
            for _ in 0..<chunks {
                guard let map = try? await agent.readSubSelectorMap(
                    monitor: index, code: code, samples: samples) else { break }
                reads += samples
                KVMLog.write(String(format: "vendor: 0x%02X chunk saw %@", code,
                                    map.keys.sorted().map { String(format: "0x%02X", $0) }
                                        .joined(separator: " ")))
                for (control, binding) in subAddressed where binding.code == code {
                    if let selector = binding.selector, let value = map[selector] {
                        vendorReadings[control.rawValue] = VendorReading(
                            value: value, takenAt: Date(), confirmed: true)
                        // The PiP toggle reads its state from pipOn rather than
                        // from here, and 0x11 is the rarest selector of the lot —
                        // so when a sample does catch it, use it, instead of
                        // making syncPiPFromPanel go and win the same lottery.
                        if control == .pictureInPicture { pipOn = (value & 0xFF) != 0 }
                        wanted.remove(selector)
                    }
                }
                if wanted.isEmpty { break }

                // Give up once three chunks running have turned up nothing the
                // earlier ones had not. The register is pinned, and reading it
                // another 180 times says the same thing more slowly — the whole
                // 480-read budget went to 0x11 on 2026-09-01 and took 27 seconds
                // to conclude what the first 180 already had.
                let before = seen.count
                seen.formUnion(map.keys)
                barren = seen.count > before ? 0 : barren + 1
                if barren >= 3 { break }
            }
            if wanted.isEmpty {
                KVMLog.write(String(format: "vendor: 0x%02X resolved in %d reads in %.2fs",
                                    code, reads, Date().timeIntervalSince(started)))
            } else {
                let missing = wanted.sorted().map { String(format: "0x%02X", $0) }
                    .joined(separator: ", ")
                KVMLog.write(String(format: "vendor: 0x%02X sub %@ never surfaced in %d reads",
                                    code, missing, reads))
            }
        }
    }

    /// Confirm the sub-addressed readings without making anything wait for it.
    func sampleVendorInBackground(cooldown: TimeInterval = 0) {
        Task<Void, Never> { [weak self] in
            await self?.refreshVendorReadings(cooldown: cooldown)
        }
    }

    /// True when a sub-addressed control has nothing the panel has confirmed
    /// this session — either no reading at all, or one only remembered.
    private var vendorReadingsIncomplete: Bool {
        VendorControl.allCases.contains { control in
            guard let binding = vendorMap[control], binding.isSubAddressed else { return false }
            return vendorReadings[control.rawValue]?.confirmed != true
        }
    }

    func setVendor(_ control: VendorControl, optionIndex: Int) async {
        guard let binding = vendorMap[control],
              let value = binding.value(forOptionAt: optionIndex) else { return }
        await set(code: binding.code, value: value)
    }

    var selected: DisplayInfo? { displays.first { $0.id == selectedID } }
    var monitorControlAvailable: Bool { transport.isAvailable }

    /// Whether monitor-side controls should accept input.
    ///
    /// Reachability alone is not enough: during the initial probe nothing has
    /// been read yet, so a control rendered from empty state shows a value the
    /// monitor never reported. Clicking it would write a setting the user never
    /// chose. A later refresh is fine — the values on screen are real, just
    /// being updated — so only the first probe locks things out.
    var controlsLive: Bool {
        transport.isAvailable && !isProbing && !features.isEmpty
    }

    // MARK: Lifecycle

    private var didBootstrap = false

    /// Codes worth re-reading every time a panel is shown. The monitor's state
    /// can change without us: its own buttons, the other machine's software, or
    /// the panel auto-switching inputs. A cached reading goes stale silently,
    /// which is worse than a brief spinner.
    private static let volatileCodes: [UInt8] = [0x10, 0x12, 0x60, 0x87, 0xD6]

    @Published private(set) var isRefreshing = false

    // MARK: Input cycling

    /// Every input this panel has that we can name — the candidate set, before
    /// asking which of them actually has something plugged in.
    var knownInputs: [UInt16] {
        guard let state = features[VCP.inputSelect.code], state.readable else { return [] }
        let declared = state.permittedValues.isEmpty
            ? Array(HPProfile.inputNames.keys)
            : state.permittedValues
        return declared.filter { HPProfile.isIdentifiedInput($0) }.sorted()
    }

    /// Inputs that click-to-cycle will visit.
    ///
    /// DDC/CI has no standard way to ask whether an input has a signal, so this
    /// is derived from evidence rather than queried, and the derivation is
    /// visible and editable on the Input tab. Cycling onto a dead input is not a
    /// harmless mistake: it blanks the screen you would need in order to click
    /// your way back off it.
    var cyclableInputs: [UInt16] {
        let known = knownInputs
        let active = known.filter { activeInputs.contains($0) }
        // Never cycle into nothing: if the set has been emptied, fall back to
        // everything rather than silently doing nothing.
        return active.isEmpty ? known : active
    }

    /// Which inputs click-to-cycle will visit.
    ///
    /// Deliberately dull. An earlier version tried to learn liveness by switching
    /// to an input and seeing whether the monitor stayed — on the theory that it
    /// refuses to sit on a dead port. That theory is false on this panel: select
    /// HDMI with nothing attached and it stays there showing black. The same
    /// mechanism also mistook a live DisplayPort for dead, because a port that
    /// has not been displaying takes several seconds to train.
    ///
    /// So nothing is inferred from switching any more. Liveness comes from two
    /// places only: a port this Mac can prove is live, and the user's ticks.
    var activeInputs: Set<UInt16> {
        var set = Set(inputOverrides.filter { $0.value }.keys)
        // A port this Mac is driving is live whether or not it is being shown.
        set.formUnion(derivedActiveInputs)
        // An explicit untick beats everything, including the derivation.
        for (input, wanted) in inputOverrides where !wanted { set.remove(input) }
        return set
    }

    @Published private(set) var derivedActiveInputs: Set<UInt16> = []
    @Published private(set) var inputOverrides: [UInt16: Bool] = [:] { didSet { persistInputState() } }

    /// One store per physical monitor.
    ///
    /// This used to be keyed on the local display when macOS could see the
    /// monitor and on the proxy's device id when it could not — so the key
    /// flipped as the monitor changed input, and the app silently swapped
    /// between two different sets of settings for the same panel. That is what
    /// made ticks appear to change on their own.
    private var targetKey = "inputState.unknown"

    private func updateTargetKey() {
        let defaults = UserDefaults.standard
        if let local = selected {
            targetKey = "inputState." + local.stableKey
            defaults.set(targetKey, forKey: "lastTargetKey")
        } else if let remembered = defaults.string(forKey: "lastTargetKey") {
            targetKey = remembered
        } else if let remote = remoteTarget {
            targetKey = "inputState.remote-" + remote.deviceID
        }
    }

    private func persistInputState() {
        UserDefaults.standard.set([
            "overrides": Dictionary(uniqueKeysWithValues:
                inputOverrides.map { (String($0.key), $0.value) }),
            "seeded": true,
        ] as [String: Any], forKey: targetKey)
    }

    private func loadInputState() -> Bool {
        guard let payload = UserDefaults.standard.dictionary(forKey: targetKey) else {
            inputOverrides = [:]
            return false
        }
        var overrides: [UInt16: Bool] = [:]
        for (key, value) in (payload["overrides"] as? [String: Bool] ?? [:]) {
            if let code = UInt16(key) { overrides[code] = value }
        }
        inputOverrides = overrides
        return (payload["seeded"] as? Bool) ?? false
    }

    /// Whether the locally-selected display really is the monitor being
    /// controlled. With more than one external display attached, the local
    /// selection can easily be a *different* panel — and reading its EDID and
    /// attributing the result to the controlled monitor produced exactly that
    /// bug: a second display connected by HDMI made HDMI look like a live input
    /// on this one.
    var localDisplayIsTarget: Bool {
        guard let local = selected else { return false }
        guard let remote = remoteTarget else { return true }   // no proxy: local is the target
        guard let name = local.edid?.monitorName?
            .trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return false }
        return remote.description.lowercased().contains(name)
    }

    /// The input this Mac is plugged into, when macOS can currently see the
    /// monitor. macOS listing the display at all is proof that cable carries a
    /// signal, and it stops listing it the moment the cable is pulled — so this
    /// half needs no guessing and corrects itself.
    private var localPortInput: UInt16? {
        guard localDisplayIsTarget else { return nil }
        guard let interface = selected?.edid?.digitalInterface else { return nil }
        switch interface {
        case "DisplayPort": return 0x0F
        case "HDMI-a", "HDMI-b": return 0x11
        default: return nil
        }
    }

    func deriveActiveInputs() {
        updateTargetKey()
        let seeded = loadInputState()

        derivedActiveInputs = localPortInput.map { [$0] } ?? []

        // First run for this monitor: assume whatever it is showing has a source,
        // since something is evidently driving it. Done exactly once — after that
        // the set only changes when the user says so, which is what makes it
        // stable.
        if !seeded {
            var seed: [UInt16: Bool] = [:]
            if let current = currentInput, HPProfile.isIdentifiedInput(current) { seed[current] = true }
            if let local = localPortInput { seed[local] = true }
            // Seed only what we can justify; never write an entry for an input we
            // have no evidence for, because a stored entry outlives the evidence.
            inputOverrides = seed.filter { $0.value }
        }
    }

    /// Only ever called from the checkbox, and only on a real change.
    func setInputActive(_ input: UInt16, _ active: Bool) {
        guard inputOverrides[input] != active else { return }
        inputOverrides[input] = active
    }

    /// Forget everything learned and start the derivation over.
    func resetInputDetection() {
        UserDefaults.standard.removeObject(forKey: targetKey)
        inputOverrides = [:]
        deriveActiveInputs()
    }

    var currentInput: UInt16? {
        guard let state = features[VCP.inputSelect.code], state.readable else { return nil }
        return state.current
    }

    var currentInputName: String? {
        currentInput.map { HPProfile.inputLabel($0) }
    }

    /// Advance to the next input. Re-reads first, so cycling starts from what the
    /// monitor is really on rather than from a cached value — the panel can change
    /// input on its own, and acting on a stale reading would skip or repeat one.
    @discardableResult
    func cycleInput() async -> String? {
        guard transport.isAvailable else {
            lastError = "No control channel to the monitor."
            return nil
        }
        _ = await reread(codes: [VCP.inputSelect.code])

        let inputs = cyclableInputs
        guard inputs.count > 1, let current = currentInput else {
            if inputs.count <= 1 {
                lastError = "Only one input is marked active, so there is nothing to cycle to."
            }
            return nil
        }

        let next: UInt16
        if let index = inputs.firstIndex(of: current) {
            next = inputs[(index + 1) % inputs.count]
        } else {
            // Sitting on an input we do not cycle through; step onto the first.
            next = inputs[0]
        }
        await set(code: VCP.inputSelect.code, value: next)
        // Confirm what the monitor settled on, but draw no conclusions from it:
        // this panel will happily sit on an input with no source.
        // set() already read the whole visible set back in the same exchange.
        return HPProfile.inputLabel(currentInput ?? next)
    }

    /// One batched round trip, rather than the full capability sweep.
    var isBusyWriting: Bool { !inFlight.isEmpty || !pendingWrites.isEmpty }

    func refreshVisible() async {
        guard transport.isAvailable, !isProbing, !isRefreshing, !isBusyWriting else { return }
        let codes = Self.volatileCodes.filter { features[$0] != nil }
        guard !codes.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Resolution and refresh rate can be changed from System Settings or by
        // the display itself; re-reading them is a local call and costs nothing.
        refreshModes()
        _ = await reread(codes: codes)
        // Detached on purpose. A sample that has to wait for a rare selector can
        // run for a couple of minutes, and awaiting it here would hold
        // isRefreshing — and every other refresh behind it — for that whole time
        // while the values on screen were already correct.
        if vendorReadingsIncomplete { sampleVendorInBackground(cooldown: 600) }
    }

    /// Both the menu bar panel and the window ask for this on appear; only the
    /// first call does the work.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        watchForLinkChanges()
        refreshDisplays()
        await probe()
        await restoreKVMIfPreviouslyOn()
        startParityMonitor()
        startDiscovery()
    }

    /// Subscribe to the things that change what the far side can see.
    ///
    /// A remote-desktop session takes a machine's desktop away from its console
    /// for as long as it is up, and hands it back — via the reclaim — when it
    /// closes. Sleep does much the same to every SSH connection at once. All
    /// three used to leave the app sitting on a dead link until somebody
    /// clicked, which read as "zBezel is broken" long after the cause was gone.
    private func watchForLinkChanges() {
        RDPControl.shared.onSessionStarted = { [weak self] host in
            guard let self, case .proxy(let current, _, _) = self.transport,
                  current.caseInsensitiveCompare(host) == .orderedSame else { return }
            // The controls are riding the very machine that just gave its
            // desktop away; look for another candidate before a write lands on
            // the virtual RDP display and quietly does nothing.
            self.reprobeSoon()
        }
        RDPControl.shared.onSessionEnded = { [weak self] _, _ in
            // The reclaim has already run by the time this fires, so the far
            // agent is back on its console — but give it a moment to notice.
            self?.reprobeSoon(after: 3)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                // Networking, DNS and the SSH master sockets all need a moment
                // after a wake; probing into that reports a failure that says
                // nothing about the far machine.
                self?.reprobeSoon(after: 5)
            }
        }
    }

    /// Put the KVM back the way it was left.
    ///
    /// Armed is not the same as capturing: it only means that crossing the
    /// panel's right edge hands control over. Restoring it takes nothing away
    /// from the user — the pointer stays here until they deliberately drive it
    /// off the edge — and having to switch it on again after every launch was
    /// the thing that made it feel like a toy rather than a setting.
    ///
    /// Detached from bootstrap's own timing: bringing the channel up waits for
    /// the far side to answer, and a host that is off would otherwise hold the
    /// first probe open for the whole of that timeout.
    private func restoreKVMIfPreviouslyOn() async {
        guard UserDefaults.standard.bool(forKey: "kvmEnabled"), !proxyHost.isEmpty else { return }
        Task { @MainActor in
            await setKVM(true)
            if let problem = kvmError {
                // Worth recording, not worth a dialog: the usual cause is the
                // other machine not being on yet, and the switch stays on so
                // it can simply be flicked again.
                KVMLog.write("restore: could not arm on launch — \(problem)")
            }
        }
    }

    func refreshDisplays() {
        displays = DisplayInventory.all()
        // Only external displays are candidates: the built-in panel has no DDC/CI,
        // and leaving it selected made the app think it had a target when it did not.
        let externals = displays.filter { !$0.isBuiltIn }
        if selectedID == nil || !externals.contains(where: { $0.id == selectedID }) {
            // Prefer the one matching the monitor the proxy is controlling, so a
            // second external display cannot be mistaken for the target.
            if let remote = remoteTarget,
               let match = externals.first(where: { display in
                   guard let name = display.edid?.monitorName?
                       .trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty
                   else { return false }
                   return remote.description.lowercased().contains(name)
               }) {
                selectedID = match.id
            } else {
                selectedID = externals.first?.id
            }
        }
        refreshModes()
    }

    /// The monitor being controlled may have no local connection at all — it can
    /// be attached solely to the proxy host. Everything monitor-side must work in
    /// that case; only the host-side settings (resolution, refresh rate) need a
    /// display this Mac can actually see.
    var hasLocalDisplay: Bool { selected != nil }

    var targetName: String {
        selected?.name ?? remoteTarget?.description ?? "No display"
    }

    @Published private(set) var remoteTarget: RemoteMonitor?

    func refreshModes() {
        guard let id = selectedID else { modeGroups = []; currentMode = nil; return }
        modeGroups = DisplayModes.grouped(for: id)
        currentMode = DisplayModes.current(for: id)
    }

    // MARK: Probing

    /// Use the local link when this Mac has one that works; otherwise the proxy.
    /// A monitor reachable only through the proxy is a perfectly normal case.
    /// - Parameter resetBackoff: a probe somebody asked for starts the retry
    ///   ladder again from its shortest rung; one the ladder itself scheduled
    ///   must not, or it would never climb.
    func probe(resetBackoff: Bool = true) async {
        guard !isProbing else { return }
        if resetBackoff { linkRetryDelay = 0 }
        isProbing = true
        probeStatus = "Examining the video link…"
        defer { isProbing = false; probeStatus = ""; updateLinkRetry() }

        capabilities = nil
        features = [:]
        proxyDiagnostic = nil
        remoteTarget = nil

        refreshModes()

        if let id = selectedID {
            link = await Self.diagnoseLocal(id)
            if link.monitorSideAvailable {
                transport = .local
                await loadFeaturesLocally(id)
                deriveActiveInputs()
                return
            }
        } else {
            // Nothing attached here to describe; the link report has no bearing.
            link = LinkReport()
        }

        guard proxyEnabled else {
            transport = .none
            return
        }
        await loadFeaturesViaProxy()
    }

    private func loadFeaturesLocally(_ id: CGDirectDisplayID) async {
        probeStatus = "Reading capabilities…"
        let caps = await Self.readCapabilities(id).map { Capabilities.parse($0) }
        capabilities = caps

        let codes = caps?.supportedCodes ?? Self.fallbackCodes
        var collected: [UInt8: FeatureState] = [:]
        for (index, code) in codes.enumerated() {
            probeStatus = "Reading feature \(index + 1) of \(codes.count)…"
            guard let value = await Self.readFeature(id, code) else { continue }
            collected[code] = Self.makeState(code: code, current: value.current,
                                             maximum: value.maximum, caps: caps)
        }
        features = collected
        seedVendorBindings()
        deriveActiveInputs()
    }

    /// Every machine that could carry the controls, the preferred one first.
    ///
    /// Which host can reach the panel is not a fixed fact: a machine can be
    /// asleep, signed out, or parked off its own console, and the monitor is on
    /// more than one of them. Asking only the configured host reported "no link"
    /// with a perfectly good proxy sitting in the KVM list beside it.
    var proxyCandidates: [String] {
        var out: [String] = []
        for host in ([proxyHost] + kvmMachines.map(\.host))
            .map({ $0.trimmingCharacters(in: .whitespaces) })
        where !host.isEmpty
            && !out.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
            out.append(host)
        }
        return out
    }

    /// Try each candidate in turn and adopt the first that can actually see the
    /// monitor. Every host that could not gets a line saying why.
    private func loadFeaturesViaProxy() async {
        var reports: [ProxyCandidateReport] = []
        var sawBlindAgent = false
        remoteMonitors = []

        // Let go of the old link BEFORE the first `agent.update`.
        //
        // There is one shared RemoteAgent, and the sweep re-points it at each
        // candidate in turn while everything else — writeRaw, confirm, reread,
        // and the input poll behind them — takes its monitor index from
        // `transport`. Leaving a live `.proxy` in place meant that for as long
        // as the sweep ran (ten seconds per dead candidate, up to forty more
        // inside a reclaim) the agent pointed at candidate N while `transport`
        // still named the host adopted last time. A poll or an input write
        // landing in that window was delivered to the wrong machine, carrying
        // the old machine's monitor index: at best it threw, at worst it changed
        // the input of a different physical panel. `.none` makes all of those
        // paths short-circuit until a candidate is actually adopted.
        transport = .none
        remoteTarget = nil

        for host in proxyCandidates {
            probeStatus = "Contacting \(host)…"
            await agent.update(config: .init(host: host, enabled: true))

            var listing: AgentListing
            do {
                listing = try await agent.list()
            } catch {
                reports.append(ProxyCandidateReport(host: host,
                                                    summary: error.localizedDescription,
                                                    usable: false))
                continue
            }

            // Somebody is using this machine through RDP. Its agent enumerates
            // that connection's virtual display, so DDC writes would report
            // success while the panel never moved — the one failure worth
            // refusing outright rather than working around.
            if listing.session?.insideRemoteSession == true {
                reports.append(ProxyCandidateReport(
                    host: host,
                    summary: "its agent is inside a remote (RDP) session and only sees the "
                           + "virtual display",
                    usable: false))
                continue
            }

            if listing.session?.detachedFromConsole == true {
                switch await putSessionBackOnConsole(host: host, session: listing.session) {
                case .listing(let fresh):
                    listing = fresh
                case .report(let why):
                    reports.append(ProxyCandidateReport(host: host, summary: why, usable: false))
                    continue
                }
            }

            if !listing.monitors.isEmpty { remoteMonitors = listing.monitors }

            guard !listing.monitors.isEmpty else {
                sawBlindAgent = true
                let place = listing.session.map { session -> String in
                    let station = session.station.isEmpty ? "no window station" : session.station
                    return "session \(session.state) on \(station)"
                } ?? "its session did not say where it is"
                reports.append(ProxyCandidateReport(
                    host: host,
                    summary: "reachable but its agent sees no monitor (\(place))",
                    usable: false))
                continue
            }

            guard let target = matchRemote(listing.monitors) else {
                reports.append(ProxyCandidateReport(
                    host: host,
                    summary: "sees \(listing.monitors.count) monitor(s), none matching this display",
                    usable: false))
                continue
            }

            if let problem = await adoptProxy(host: host, target: target) {
                reports.append(ProxyCandidateReport(host: host, summary: problem, usable: false))
                continue
            }

            reports.append(ProxyCandidateReport(host: host,
                                                summary: "carrying the controls for "
                                                       + target.description,
                                                usable: true))
            proxyCandidateReports = reports
            proxyDiagnostic = nil
            return
        }

        transport = .none
        remoteTarget = nil
        proxyCandidateReports = reports

        var lines = reports.map { "\($0.host): \($0.summary)" }
        if reports.isEmpty {
            lines = ["No proxy host is configured. Set one on this tab, or add a KVM machine."]
        } else if sawBlindAgent {
            lines.append("The agent is running but reports no monitors. Its session is not on the "
                       + "physical console — the screen is locked, the session was left "
                       + "disconnected after an RDP connection, or the agent started outside the "
                       + "interactive session.")
        }
        proxyDiagnostic = lines.joined(separator: "\n")
    }

    /// The result of trying to hand a machine's console back to its own session.
    private enum SessionReclaim {
        /// It is back, and this is what it sees now.
        case listing(AgentListing)
        /// It is not, and this is the line to show for the host.
        case report(String)
    }

    /// Per host: when this app last asked for the console back, and what came of
    /// it. A machine that declines to move must not be asked again on every
    /// probe — and the probes that do not ask must say why, which means
    /// remembering the answer rather than assuming one.
    private var lastConsoleReclaim: [String: Date] = [:]
    private var lastReclaimOutcome: [String: ConsoleReclaim.Outcome] = [:]
    private static let reclaimCooldown: TimeInterval = 300

    /// One clause naming what the last reclaim on a host actually did.
    private static func reclaimReason(_ outcome: ConsoleReclaim.Outcome) -> String {
        switch outcome {
        case .moved:
            return "it was put back recently and did not stay"
        case .alreadyActive:
            return "the console was already showing a desktop, so its session stayed put"
        case .notMoved(let why):
            return "it would not move — \(why)"
        case .noTask:
            return "BezelReclaimConsole is not installed there"
        case .noVerdict:
            return "the reclaim task reported nothing"
        case .unreachable(let output):
            return "could not run the reclaim task — \(output)"
        }
    }

    /// A session left `Disconnected` after an RDP connection closed is still
    /// signed in — it simply no longer owns the console, so it can enumerate
    /// nothing. `tscon` puts it back, and then the agent can see the panel again.
    private func putSessionBackOnConsole(host: String,
                                         session: AgentSession?) async -> SessionReclaim {
        let sessionID = session.map { String($0.id) } ?? "?"
        let consoleID = session.map { $0.console < 0 ? "none" : String($0.console) } ?? "?"
        let situation = "agent in session \(sessionID) is disconnected from the console "
                      + "(session \(consoleID))"

        // A Control window means a person is in that session right now, and
        // moving it out from under them would end their connection.
        if RDPControl.shared.isOpen(host: host) {
            return .report(situation + "; a Control window is using it")
        }
        if let last = lastConsoleReclaim[host],
           Date().timeIntervalSince(last) < Self.reclaimCooldown {
            // Say what happened last time, not what a fixed sentence guesses.
            // One wording covered every outcome here — "it was put back recently
            // and did not stay" — so a host whose reclaim task is missing spent
            // the next five minutes reporting a move that was never attempted,
            // sending the reader to look at a session instead of at the task.
            let why = lastReclaimOutcome[host].map(Self.reclaimReason)
                ?? "it was put back recently and did not stay"
            return .report(situation + "; " + why)
        }

        probeStatus = "\(host): putting its session back on the console…"
        // Name the session meant: the task picks its own target and, on a machine
        // with a second user signed in and disconnected, that need not be the
        // agent's. A move of anything else comes back as .notMoved.
        let outcome = await ConsoleReclaim.reclaim(host: host, expecting: session?.id)
        lastReclaimOutcome[host] = outcome

        // Back off only from outcomes where something was actually decided on the
        // far machine. Stamped before the call, as it was, the cooldown also
        // silenced the cases most worth retrying — ssh momentarily down, the task
        // not installed yet, a run that said nothing — for five minutes each.
        switch outcome {
        case .moved, .alreadyActive, .notMoved: lastConsoleReclaim[host] = Date()
        case .noTask, .noVerdict, .unreachable: break
        }

        switch outcome {
        case .moved, .alreadyActive:
            // The agent caches its monitor handles for 20s, and the reclaim
            // takes longer than that on its own, so this list re-enumerates
            // rather than answering from the cache taken while it was blind.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let listing = try? await agent.list() else {
                return .report(situation + "; put it back, but it did not answer afterwards")
            }
            return .listing(listing)
        default:
            return .report(situation + "; " + Self.reclaimReason(outcome))
        }
    }

    /// The capability sweep for one chosen host and monitor.
    /// Returns nil once the transport is live, or the reason it is not.
    private func adoptProxy(host: String, target: RemoteMonitor) async -> String? {
        do {
            remoteTarget = target
            probeStatus = "Reading capabilities from \(host)…"
            let capsString = try await agent.capabilities(monitor: target.index)
            let caps = capsString.isEmpty ? nil : Capabilities.parse(capsString)
            capabilities = caps

            // Drop the write-only restore commands before reading anything. The
            // capabilities string lists them next to real settings, and reading
            // 0x04 asks the monitor to restore its factory defaults.
            let codes = (caps?.supportedCodes ?? Self.fallbackCodes)
                .filter { !VCP.neverRead.contains($0) }
            probeStatus = "Reading \(codes.count) features from \(host)…"
            let readings = try await agent.read(monitor: target.index, codes: codes)

            var collected: [UInt8: FeatureState] = [:]
            for (code, reading) in readings {
                collected[code] = Self.makeState(code: code, current: reading.current,
                                                 maximum: reading.maximum, caps: caps)
            }
            features = collected
            seedVendorBindings()
            // A fresh host starts with a clean slate; failures counted against
            // the machine this one replaced say nothing about it.
            proxyFailureStreak = 0
            transport = .proxy(host: host, monitorIndex: target.index,
                               description: target.description)
            deriveActiveInputs()
            // The remembered readings are already on screen; confirming them is
            // slow and nothing waits on the answer.
            sampleVendorInBackground()
            return nil
        } catch {
            remoteTarget = nil
            return error.localizedDescription
        }
    }

    // MARK: Coming back on its own

    // A link that has gone lives on the far machine, and the far machine mends
    // itself: it finishes booting, somebody signs in, an RDP session closes.
    // Until this, .none was terminal — the only ways out were a click or a Mac
    // display-layout change, so an app left open overnight was still saying "no
    // link" hours after the cause had cleared.

    private var linkRetryTimer: Timer?
    private var linkRetryDelay: TimeInterval = 0
    private var lastReprobe = Date.distantPast
    /// Rungs in seconds. Long enough that a machine that is simply off costs
    /// almost nothing, short enough that a machine coming back is noticed while
    /// the person who turned it on is still watching.
    private static let linkRetryDelays: [TimeInterval] = [20, 40, 80, 120]

    /// Schedule the next unattended probe, or stand down because there is a link.
    private func updateLinkRetry() {
        linkRetryTimer?.invalidate()
        linkRetryTimer = nil
        guard transport == .none, proxyEnabled, !proxyCandidates.isEmpty else {
            nextLinkRetry = nil
            linkRetryDelay = 0
            return
        }
        let delay = Self.linkRetryDelays.first { $0 > linkRetryDelay }
            ?? Self.linkRetryDelays.last ?? 120
        linkRetryDelay = delay
        nextLinkRetry = Date().addingTimeInterval(delay)
        linkRetryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isProbing else { return }
                await self.probe(resetBackoff: false)
            }
        }
    }

    /// Consecutive failures on the adopted proxy since it last answered.
    private var proxyFailureStreak = 0
    /// Three in a row before giving up on a host. One timeout is ordinary — the
    /// far agent re-enumerating after a hotplug, an ssh that took its time — and
    /// demoting on a single one would thrash a link that is merely busy.
    private static let proxyFailureLimit = 3

    /// Record how a call over the proxy went, and let go of the host once it has
    /// stopped answering altogether.
    ///
    /// Nothing else demoted a live `.proxy`: every failure was swallowed into
    /// `lastError` and the transport went on naming a machine that had gone to
    /// sleep hours before. Both self-healing paths — the retry ladder and the
    /// parity sweep — arm only while the transport is `.none`, so that machine
    /// was never retried and a second candidate that could have carried the
    /// controls the whole time was never tried at all. The link stayed dead, and
    /// the card still said "Proxy Info ✓", until somebody pressed Reconnect.
    private func noteProxyOutcome(succeeded: Bool) {
        guard case .proxy(let host, _, _) = transport else { return }
        if succeeded {
            proxyFailureStreak = 0
            return
        }
        proxyFailureStreak += 1
        guard proxyFailureStreak >= Self.proxyFailureLimit else { return }
        proxyFailureStreak = 0
        transport = .none
        remoteTarget = nil
        proxyDiagnostic = "\(host) stopped answering — \(lastError ?? "no reply"). "
                        + "Looking for another machine that can reach this display."
        updateLinkRetry()
    }

    /// Probe again shortly — for the moments when something else has just
    /// changed the far side and waiting out the backoff would leave the app
    /// looking broken for a minute after the cause was fixed. Throttled, because
    /// several of those moments arrive together.
    func reprobeSoon(after seconds: TimeInterval = 2) {
        guard Date().timeIntervalSince(lastReprobe) >= 10 else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            guard let self else { return }
            // The throttle is re-checked, and spent, HERE rather than at
            // scheduling time. Stamped up front it was spent by probes that then
            // never ran, and a probe already in flight would swallow the next ten
            // seconds' worth of reasons to look again — the reclaim finishing,
            // the parity sweep seeing a host come back — leaving the app to wait
            // out a two-minute backoff rung for a link that was ready at once.
            guard Date().timeIntervalSince(self.lastReprobe) >= 10 else { return }
            guard !self.isProbing else {
                // A probe is already running, and it started before whatever we
                // are reacting to — so it cannot have seen it. Do not spend the
                // throttle on a probe that would be dropped: reset the ladder
                // instead, and that probe's own `defer` schedules the next one at
                // the shortest rung rather than the longest.
                self.linkRetryDelay = 0
                return
            }
            self.lastReprobe = Date()
            await self.probe(resetBackoff: false)
        }
    }

    /// Pair the local display with the one the proxy host can see.
    private func matchRemote(_ monitors: [RemoteMonitor]) -> RemoteMonitor? {
        guard !monitors.isEmpty else { return nil }
        if monitors.count == 1 { return monitors[0] }
        guard selected != nil else { return monitors[0] }

        // The monitor advertises a different EDID per input, so the product code
        // will not match across connections. Compare the human-readable name.
        if let name = selected?.edid?.monitorName?
            .trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty {
            if let hit = monitors.first(where: { $0.description.lowercased().contains(name) }) {
                return hit
            }
        }
        return monitors[0]
    }

    private static func makeState(code: UInt8, current: UInt16, maximum: UInt16,
                                  caps: Capabilities?) -> FeatureState {
        var state = FeatureState(feature: VCP.describe(code))
        state.current = current
        state.maximum = maximum
        state.permittedValues = caps?.values(for: code) ?? []
        state.readable = true
        return state
    }

    private static let fallbackCodes: [UInt8] =
        [0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x60, 0x62, 0x6C, 0x6E, 0x70,
         0x87, 0xAC, 0xAE, 0xB6, 0xC0, 0xC9, 0xCA, 0xCC, 0xD6, 0xDC, 0xDF]

    // MARK: Writing

    /// Write a value and report what the monitor says it ended up at, if it says.
    /// No retry and no separate read-back: callers decide whether to confirm.
    private func writeRaw(code: UInt8, value: UInt16) async -> UInt16? {
        switch transport {
        case .none:
            lastError = "No control channel to the monitor."
            return nil

        case .local:
            guard let id = selectedID else { return nil }
            guard await Self.writeFeature(id, code, value) else {
                lastError = "The monitor did not accept \(VCP.describe(code).name)."
                return nil
            }
            return value

        case .proxy(_, let index, _):
            do {
                var toRead = Set(Self.volatileCodes)
                toRead.insert(code)
                let readings = try await agent.writeAndRead(
                    monitor: index, code: code, value: value, readCodes: Array(toRead).sorted())
                noteProxyOutcome(succeeded: true)
                for (readCode, reading) in readings { features[readCode]?.current = reading.current }

                // An input switch takes seconds, and the panel visibly passes
                // through other inputs on the way — we watched it walk
                // 0x0F -> 0x11 -> 0x0F -> 0x13 when a source disappeared. A read
                // taken moments after the write catches that transit and shows
                // the wrong input for a few seconds. Trust what was asked for and
                // check once it has settled.
                if code == VCP.inputSelect.code {
                    features[code]?.current = value
                    confirmInputAfterSettling(expected: value)
                    return value
                }
                // Same story for a sub-addressed write, only worse: confirming it
                // means sampling 0xE1 until a rare selector appears, which takes
                // tens of seconds. Show the chosen option immediately and verify
                // out of band rather than making the user watch a stale radio.
                if value > 0xFF {
                    let selector = UInt8(value >> 8)
                    for control in VendorControl.allCases
                    where vendorMap[control]?.code == code && vendorMap[control]?.selector == selector {
                        noteVendorWrite(control, value: value)
                    }
                    confirmVendorAfterSettling()
                }
                return readings[code]?.current ?? value
            } catch {
                lastError = error.localizedDescription
                noteProxyOutcome(succeeded: false)
                return nil
            }
        }
    }

    /// Write, then confirm against the monitor. For discrete controls, where one
    /// write per interaction is the whole story.
    func set(code: UInt8, value: UInt16, byHand: Bool = true) async {
        // Every path that changes the input from the interface arrives here — the
        // menu bar list and the Input tab both call set() rather than
        // requestMonitorInput. Choosing an input by hand overrules a lock, and
        // catching it at this one point means a new control cannot forget to.
        if code == VCP.inputSelect.code {
            // A person picked this — menu-bar icon, its pulldown, or the Input
            // tab all arrive here with byHand's default of true. That pins the
            // panel and holds the pointer to the machine on that input (the
            // Mac's own input lets go). The KVM's own pointer-driven write also
            // lands here, via requestMonitorInput's deferred task, and says
            // byHand: false — without that, every ordinary crossing engaged a
            // lock nobody clicked half a second later, and the way home was then
            // refused as "locked". The default stays true on purpose: a control
            // added later that forgets the parameter locks, rather than silently
            // breaking Rule 2.
            if byHand { kvm.followManualInput(value) }
            lastCommandedInput = value
            // The coalescer in requestMonitorInput skips a write when the target
            // equals lastRequestedInput, and that was only ever set inside its
            // own task — so after a by-hand switch it went stale and a later
            // return to DisplayPort could be swallowed outright. Keep it in step
            // with reality: "the input the panel is heading to or resting on".
            lastRequestedInput = value
            inputWatcher.resync(to: value)
        }
        if case .proxy = transport {
            // The proxy path writes and reads everything back in one exchange,
            // so a separate confirm would just be another second on the wire.
            _ = await writeRaw(code: code, value: value)
            return
        }
        guard await writeRaw(code: code, value: value) != nil else { return }
        features[code]?.current = value
        await confirm(code: code)
    }

    // MARK: Continuous controls
    //
    // A slider emits changes far faster than the link can carry them — about
    // 0.8 s per write through the proxy. Queueing every intermediate value would
    // run seconds behind the user's finger and keep going after they let go.
    // So: at most one write in flight per code, and a single pending slot that
    // newer values overwrite. Intermediate positions are dropped on purpose;
    // the value the user actually settles on is always the one that lands.

    private var inFlight: Set<UInt8> = []
    private var pendingWrites: [UInt8: UInt16] = [:]

    /// Called continuously while a slider moves.
    func setLive(code: UInt8, value: UInt16) {
        guard transport.isAvailable else { return }
        features[code]?.current = value     // keep the UI ahead of the wire
        pendingWrites[code] = value
        guard !inFlight.contains(code) else { return }

        inFlight.insert(code)
        Task<Void, Never> { [weak self] in
            guard let self else { return }
            while let next = self.takePending(code) {
                _ = await self.writeRaw(code: code, value: next)
            }
            self.finishInFlight(code)
        }
    }

    private func takePending(_ code: UInt8) -> UInt16? {
        pendingWrites.removeValue(forKey: code)
    }

    private func finishInFlight(_ code: UInt8) {
        inFlight.remove(code)
    }

    /// Called when the user lets go: land on the final value, then settle the UI
    /// on the monitor's own reading of it.
    func setFinal(code: UInt8, value: UInt16) async {
        guard transport.isAvailable else { return }
        setLive(code: code, value: value)
        await commit(code: code)
    }

    /// Called when the user lets go: settle the UI on the monitor's own reading.
    func commit(code: UInt8) async {
        // Let any in-flight coalesced write finish, so the read is not stale.
        while inFlight.contains(code) || pendingWrites[code] != nil {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        await confirm(code: code)
    }

    /// Re-sample the sub-addressed controls once the monitor has settled.
    /// Deliberately not awaited: it is slow, and the UI already shows the value
    /// that was asked for.
    private func confirmVendorAfterSettling() {
        Task<Void, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.refreshVendorReadings()
        }
    }

    /// Re-read the input once the switch has finished, in case the monitor
    /// ended up somewhere other than where it was sent — an input with no source
    /// is one way that happens.
    private func confirmInputAfterSettling(expected: UInt16) {
        Task<Void, Never> { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self else { return }
            _ = await self.reread(codes: [VCP.inputSelect.code])
        }
    }

    /// Replace our optimistic value with what the monitor actually reports.
    private func confirm(code: UInt8) async {
        switch transport {
        case .none:
            return
        case .local:
            guard let id = selectedID else { return }
            if let readback = await Self.readFeature(id, code) {
                features[code]?.current = readback.current
            }
        case .proxy(_, let index, _):
            // do/catch rather than try?: a host that has stopped answering has to
            // be counted, and a swallowed error is indistinguishable from a code
            // the monitor declined to report.
            do {
                let readings = try await agent.read(monitor: index, codes: [code])
                noteProxyOutcome(succeeded: true)
                if let reading = readings[code] { features[code]?.current = reading.current }
            } catch {
                noteProxyOutcome(succeeded: false)
            }
        }
    }

    /// Re-read a set of codes in one round trip. Used by the vendor-code mapper.
    ///
    /// Filters the write-only restores again rather than trusting every caller to
    /// have done it. This is the path the vendor mapper uses, and it builds its
    /// code lists by sweeping ranges — exactly the way a restore command gets read
    /// by accident.
    func reread(codes rawCodes: [UInt8]) async -> [UInt8: UInt16] {
        let codes = rawCodes.filter { !VCP.neverRead.contains($0) }
        switch transport {
        case .none:
            return [:]
        case .local:
            guard let id = selectedID else { return [:] }
            var out: [UInt8: UInt16] = [:]
            for code in codes {
                if let value = await Self.readFeature(id, code) { out[code] = value.current }
            }
            for (code, value) in out { features[code]?.current = value }
            return out
        case .proxy(_, let index, _):
            do {
                let readings = try await agent.read(monitor: index, codes: codes)
                noteProxyOutcome(succeeded: true)
                var out: [UInt8: UInt16] = [:]
                for (code, reading) in readings {
                    out[code] = reading.current
                    features[code]?.current = reading.current
                }
                return out
            } catch {
                lastError = error.localizedDescription
                noteProxyOutcome(succeeded: false)
                return [:]
            }
        }
    }

    /// Change the colour mode (0xDC) and pull the settings that follow from it.
    ///
    /// The panel recomputes its per-mode RGB gains (0x16/0x18/0x1A) and black
    /// levels (0x6C/0x6E/0x70) — and its colour preset mirror (0x14) — but the
    /// mode write does not read them back, so the sliders kept showing the
    /// previous mode's numbers. This writes the mode, gives the panel a beat to
    /// apply it, then re-reads those so the sliders follow. `refreshingColor` is
    /// held across the whole thing so the sliders dim until the new values land.
    func setColorMode(_ value: UInt16) async {
        refreshingColor = true
        defer { refreshingColor = false }
        await set(code: 0xDC, value: value)
        // The write returns before the panel has finished switching; give it a
        // beat so the read lands on the settled values, not the outgoing ones.
        try? await Task.sleep(nanoseconds: 500_000_000)
        _ = await reread(codes: [0x14, 0x16, 0x18, 0x1A, 0x6C, 0x6E, 0x70])
        // Landing on Native with fresh factory gains is the one moment we know the
        // gains produce the native white — pin the white-balance reference here.
        if value == 0x00, let w = selected?.edid?.nativeWhitePoint {
            captureWhiteReference(nativeWhite: w)
        }
    }

    // MARK: White-point solver (the draggable dot in the gamut diagram)

    /// Capture the white-balance reference: the current RGB gains and the white
    /// they are taken to produce. Trusted only in Native mode, where the gains act
    /// on the panel's own primaries rather than through a colour-space LUT. Once
    /// taken it is a fixed physical fact, so it is captured once and kept.
    func captureWhiteReference(nativeWhite: EDID.Chromaticity) {
        guard whiteBalanceReference == nil else { return }
        guard (features[0xDC]?.current ?? 0xFF) == 0x00 else { return }
        let g = currentGains()
        guard g.0 > 0, g.1 > 0, g.2 > 0 else { return }
        whiteBalanceReference = (g, (nativeWhite.x, nativeWhite.y))
    }

    private func currentGains() -> (Double, Double, Double) {
        (Double(features[0x16]?.current ?? 0),
         Double(features[0x18]?.current ?? 0),
         Double(features[0x1A]?.current ?? 0))
    }

    /// Drive the panel's white toward CIE (x, y) by rescaling the RGB gains. The
    /// gains act on the panel's native primaries, so `primaries` is always the
    /// EDID's own: solve the primary scalings for the reference and target whites
    /// and rescale each gain by the ratio, holding the peak channel to preserve
    /// level. `commit` writes on release; otherwise the gains stream live.
    func setWhitePoint(x: Double, y: Double, primaries: EDID.ColourPrimaries,
                       nativeWhite: EDID.Chromaticity, commit: Bool) {
        captureWhiteReference(nativeWhite: nativeWhite)
        guard let inv = Self.invert3x3(Self.primaryMatrix(primaries)) else { return }
        let sTgt = Self.mul(inv, Self.whiteXYZ(x, y))
        var r: Double, g: Double, b: Double
        let maxGain = Double(features[0x16]?.maximum ?? 255)
        let targetPeak: Double
        if let ref = whiteBalanceReference {
            // Preferred model: rescale the factory gains by the ratio of primary
            // scalings for the target vs the reference (native) white. Pins the
            // native white to the factory gains exactly.
            let sRef = Self.mul(inv, Self.whiteXYZ(ref.white.0, ref.white.1))
            guard sRef.0 != 0, sRef.1 != 0, sRef.2 != 0 else { return }
            r = ref.gains.0 * (sTgt.0 / sRef.0)
            g = ref.gains.1 * (sTgt.1 / sRef.1)
            b = ref.gains.2 * (sTgt.2 / sRef.2)
            targetPeak = max(ref.gains.0, ref.gains.1, ref.gains.2)
        } else {
            // Fallback with no native reference captured yet: gains proportional to
            // the primary scalings for the target white, filled to full drive. Less
            // pinned to factory, but the white still moves the right way — so the
            // dot always does something rather than silently no-op.
            r = max(0, sTgt.0); g = max(0, sTgt.1); b = max(0, sTgt.2)
            targetPeak = maxGain
        }
        let peak = max(r, g, b)
        guard peak > 0 else { return }
        let k = targetPeak / peak
        r *= k; g *= k; b *= k
        func q(_ v: Double) -> UInt16 { UInt16(max(0, min(maxGain, v.rounded()))) }
        let rr = q(r), gg = q(g), bb = q(b)
        if commit {
            Task { await setFinal(code: 0x16, value: rr)
                   await setFinal(code: 0x18, value: gg)
                   await setFinal(code: 0x1A, value: bb) }
        } else {
            setLive(code: 0x16, value: rr)
            setLive(code: 0x18, value: gg)
            setLive(code: 0x1A, value: bb)
        }
    }

    /// The white the current RGB gains produce on the panel's native primaries —
    /// for placing the dot after a mode change. nil until a native reference has
    /// been captured (the caller then falls back to the declared white).
    func whitePointForCurrentGains(primaries: EDID.ColourPrimaries) -> EDID.Chromaticity? {
        guard let ref = whiteBalanceReference,
              ref.gains.0 > 0, ref.gains.1 > 0, ref.gains.2 > 0,
              let inv = Self.invert3x3(Self.primaryMatrix(primaries)) else { return nil }
        let sRef = Self.mul(inv, Self.whiteXYZ(ref.white.0, ref.white.1))
        let L = (sRef.0 / ref.gains.0, sRef.1 / ref.gains.1, sRef.2 / ref.gains.2)
        let g = currentGains()
        let contrib = (g.0 * L.0, g.1 * L.1, g.2 * L.2)
        let m = Self.primaryMatrix(primaries)
        let xyz = Self.mul(m, contrib)
        let sum = xyz.0 + xyz.1 + xyz.2
        guard sum > 0 else { return nil }
        return EDID.Chromaticity(x: xyz.0 / sum, y: xyz.1 / sum)
    }

    private static func primaryMatrix(_ p: EDID.ColourPrimaries) -> [[Double]] {
        func col(_ c: EDID.Chromaticity) -> (Double, Double, Double) {
            c.y > 0 ? (c.x / c.y, 1, (1 - c.x - c.y) / c.y) : (0, 0, 0)
        }
        let r = col(p.red), g = col(p.green), b = col(p.blue)
        return [[r.0, g.0, b.0], [r.1, g.1, b.1], [r.2, g.2, b.2]]
    }
    private static func whiteXYZ(_ x: Double, _ y: Double) -> (Double, Double, Double) {
        y > 0 ? (x / y, 1, (1 - x - y) / y) : (0, 0, 0)
    }
    private static func mul(_ m: [[Double]], _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0][0]*v.0 + m[0][1]*v.1 + m[0][2]*v.2,
         m[1][0]*v.0 + m[1][1]*v.1 + m[1][2]*v.2,
         m[2][0]*v.0 + m[2][1]*v.1 + m[2][2]*v.2)
    }
    static func invert3x3(_ m: [[Double]]) -> [[Double]]? {
        let a = m[0][0], b = m[0][1], c = m[0][2]
        let d = m[1][0], e = m[1][1], f = m[1][2]
        let g = m[2][0], h = m[2][1], i = m[2][2]
        let A = e*i - f*h, B = -(d*i - f*g), C = d*h - e*g
        let det = a*A + b*B + c*C
        guard abs(det) > 1e-9 else { return nil }
        let id = 1 / det
        return [[A*id, (c*h - b*i)*id, (b*f - c*e)*id],
                [B*id, (a*i - c*g)*id, (c*d - a*f)*id],
                [C*id, (b*g - a*h)*id, (a*e - b*d)*id]]
    }

    func reconnectProxy() async {
        await agent.disconnect()
        // Asked for by hand: start the retry ladder at its shortest rung again,
        // rather than making a person who has just fixed the far machine wait
        // out a two-minute delay the unattended retries had climbed to.
        linkRetryDelay = 0
        await probe()
    }

    // MARK: Host-side changes

    func apply(mode: DisplayMode, permanent: Bool = true) {
        guard let id = selectedID else { return }
        if DisplayModes.apply(mode, to: id, permanent: permanent) {
            refreshModes()
        } else {
            lastError = "macOS refused the mode change to \(mode.detailLabel)."
        }
    }

    var preferredTimingLabel: String? { selected?.edid?.preferredTiming?.description }

    func applyPreferredTiming() {
        guard let preferred = selected?.edid?.preferredTiming else { return }
        let candidates = modeGroups.flatMap(\.modes)
        let match = candidates.first {
            $0.pixelWidth == preferred.hActive && $0.pixelHeight == preferred.vActive
                && abs($0.refreshHz - preferred.refreshHz) < 1.5
        } ?? candidates.first {
            $0.pixelWidth == preferred.hActive && $0.pixelHeight == preferred.vActive
        }
        if let match { apply(mode: match) }
        else { lastError = "No macOS mode matches the panel's preferred timing (\(preferred.description))." }
    }

    // MARK: Off-main-actor bridges to the local C transport

    private nonisolated static func diagnoseLocal(_ id: CGDirectDisplayID) async -> LinkReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var raw = BezelLinkReport()
                let rc = bezel_diagnose(UInt32(id), &raw)
                continuation.resume(returning: rc == BEZEL_OK ? LinkReport(raw) : LinkReport())
            }
        }
    }

    private nonisolated static func readCapabilities(_ id: CGDirectDisplayID) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var buffer = [CChar](repeating: 0, count: 4096)
                let n = bezel_ddc_capabilities(UInt32(id), &buffer, 4096)
                continuation.resume(returning: n > 0 ? String(cString: buffer) : nil)
            }
        }
    }

    private nonisolated static func readFeature(_ id: CGDirectDisplayID, _ code: UInt8)
        async -> (current: UInt16, maximum: UInt16)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var current: UInt16 = 0, maximum: UInt16 = 0, type: UInt8 = 0
                let rc = bezel_ddc_get_vcp(UInt32(id), code, &current, &maximum, &type)
                continuation.resume(returning: rc == BEZEL_OK ? (current, maximum) : nil)
            }
        }
    }

    private nonisolated static func writeFeature(_ id: CGDirectDisplayID, _ code: UInt8,
                                                 _ value: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: bezel_ddc_set_vcp(UInt32(id), code, value) == BEZEL_OK)
            }
        }
    }
}
