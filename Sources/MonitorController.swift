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

@MainActor
final class MonitorController: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var selectedID: CGDirectDisplayID?

    @Published private(set) var link = LinkReport()
    @Published private(set) var transport: Transport = .none
    @Published private(set) var capabilities: Capabilities?
    @Published private(set) var features: [UInt8: FeatureState] = [:]

    @Published private(set) var modeGroups: [(resolution: String, modes: [DisplayMode])] = []
    @Published private(set) var currentMode: DisplayMode?

    @Published private(set) var isProbing = false
    @Published private(set) var probeStatus = ""
    @Published var lastError: String?

    /// Proxy settings, persisted so the app comes back configured.
    @Published var proxyEnabled: Bool {
        didSet { UserDefaults.standard.set(proxyEnabled, forKey: "proxyEnabled") }
    }
    @Published var proxyHost: String {
        didSet { UserDefaults.standard.set(proxyHost, forKey: "proxyHost") }
    }
    @Published private(set) var proxyDiagnostic: String?
    @Published private(set) var remoteMonitors: [RemoteMonitor] = []

    // Vendor-code discovery
    @Published var vendorMap: VendorMap { didSet { vendorMap.save() } }
    @Published private(set) var vendorBaseline: [UInt8: UInt16]?
    @Published private(set) var vendorChanges: [VendorChange] = []
    @Published private(set) var mapperBusy = false

    private let agent = RemoteAgent()

    // MARK: KVM

    private let kvm = KVMController()
    private let pcSpace = PCSpace()
    @Published private(set) var pcSpaceOpen = false
    @Published private(set) var kvmEnabled = false
    @Published private(set) var kvmControllingRemote = false
    @Published private(set) var kvmStatus = "off"
    @Published var kvmError: String?

    init() {
        let defaults = UserDefaults.standard
        proxyEnabled = defaults.object(forKey: "proxyEnabled") as? Bool ?? true
        proxyHost = defaults.string(forKey: "proxyHost") ?? ""
        vendorMap = VendorMap.load()
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

        // The Space and the KVM are one gesture: entering it switches the panel
        // and hands over the keyboard and pointer together, because showing the
        // PC's screen while an invisible Mac pointer moved over it would be
        // worse than doing neither.
        pcSpace.onEnter = { [weak self] in self?.kvm.takeControlForSpace() }
        pcSpace.onLeave = { [weak self] in self?.kvm.releaseControlForSpace() }
        pcSpace.onWantScreenshot = { [weak self] in self?.kvm.requestScreenshot() }
        kvm.onScreenshot = { [weak self] data in
            guard let image = NSImage(data: data) else { return }
            self?.pcSpace.show(image)
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
    /// Read on/off, which is the only part of PiP the panel will tell us.
    ///
    /// 0x13 is sampled too and deliberately ignored. It does come up in the
    /// rotation, but what it reports is the last COMMAND it was given — enlarge,
    /// reduce, maximum, minimum — and not the size that resulted. Treating that
    /// echo as a size is what put a number in the UI that had nothing to do with
    /// what was on the panel.
    func syncPiPFromPanel(samples: Int = 24) async {
        guard case .proxy(_, let index, _) = transport else { return }
        let started = Date()
        guard let map = try? await agent.readSubSelectorMap(
            monitor: index, code: 0xE1, samples: samples) else { return }
        KVMLog.write(String(format: "pip: %d samples in %.2fs, saw %@",
                            samples, Date().timeIntervalSince(started),
                            map.keys.sorted().map { String(format: "%02X", $0) }
                                .joined(separator: " ")))
        if let raw = map[0x11] { pipOn = (raw & 0xFF) != 0 }
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
        if let id = selectedID, displays.contains(where: { $0.id == id }) {
            portal = id
        }
        kvm.configurePortal(display: portal)
    }

    /// Wire the panel-switching side of the KVM. Kept out of init because it
    /// needs the monitor profile, which is not known until a probe has run.
    private func wireKVMInputs() {
        kvm.macInput = HPProfile.inputNames.first { $0.value == "DisplayPort"  }?.key ?? 0x0F
        kvm.pcInput  = HPProfile.inputNames.first { $0.value == "USB-C1 Video" }?.key ?? 0x13
        kvm.setMonitorInput = { [weak self] value in
            Task { @MainActor in self?.requestMonitorInput(value) }
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
    func requestMonitorInput(_ value: UInt16) {
        desiredInput = value
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
                await set(code: VCP.inputSelect.code, value: target)

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
    func setKVM(_ on: Bool) async {
        // Remember the choice even if bringing it up fails, so a host that was
        // simply asleep does not silently switch the feature off for good.
        UserDefaults.standard.set(on, forKey: "kvmEnabled")
        guard on != kvm.isEnabled else { return }
        if on {
            guard !proxyHost.isEmpty else {
                kvmError = "Set a proxy host on the Link tab first."
                return
            }
            wireKVMInputs()
            syncKVMPortal()
            await agent.update(config: .init(host: proxyHost, enabled: true))
            var size: CGSize?
            do {
                size = try await agent.cursor().bounds.size
            } catch {
                // Not fatal: fall back to the last known size and let the user
                // see why the reading failed rather than refusing to start.
                kvmError = "Could not read \(proxyHost)'s screen size "
                         + "(\(error.localizedDescription)); using the last known size."
            }
            if let problem = kvm.enable(host: proxyHost,
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

    /// Open or close the Space that stands for the PC.
    func setPCSpace(_ on: Bool) {
        guard on != pcSpace.isOpen else { return }
        if on {
            guard let id = selectedID, displays.contains(where: { $0.id == id }) else {
                kvmError = "No external display is selected to put the Space on."
                return
            }
            guard kvm.isEnabled else {
                kvmError = "Switch on Control \(proxyHost) first — the Space hands over "
                         + "the keyboard and pointer as well as the picture."
                return
            }
            pcSpace.open(on: id, title: proxyHost.isEmpty ? "PC" : proxyHost)
        } else {
            pcSpace.close()
        }
        pcSpaceOpen = pcSpace.isOpen
        UserDefaults.standard.set(pcSpaceOpen, forKey: "pcSpaceOpen")
    }

    /// Unwind the KVM synchronously on the way out.
    ///
    /// Handing control over decouples the pointer from the mouse and hides the
    /// cursor. Quitting while that is in force would leave the Mac with a mouse
    /// that moves nothing, so this cannot be left to an async Task that may not
    /// get a chance to run before the process goes.
    func shutdownKVM() {
        pcSpace.close()
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
        defer { mapperBusy = false }
        vendorChanges = []
        vendorBaseline = await reread(codes: vendorCodes)
    }

    /// Re-read and report what moved since the snapshot.
    func compareVendorCodes() async {
        guard let baseline = vendorBaseline, !mapperBusy else { return }
        mapperBusy = true
        defer { mapperBusy = false }

        let now = await reread(codes: vendorCodes)
        vendorChanges = now.compactMap { code, value in
            guard let before = baseline[code], before != value else { return nil }
            return VendorChange(code: code, before: before, after: value)
        }
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
    @Published private(set) var vendorReadings: [String: UInt16] = [:]

    func currentValue(for control: VendorControl) -> UInt16? {
        guard let binding = vendorMap[control] else { return nil }
        if binding.isSubAddressed { return vendorReadings[control.rawValue] }
        return features[binding.code]?.current
    }

    /// Resolve every sub-addressed binding from one shared map read.
    ///
    /// The selectors are rare in the rotation — the interesting ones come back in
    /// roughly 6% of reads while 0x13 accounts for 81% — so a 30-sample read
    /// missed one about one time in six, and doing a separate read per control
    /// multiplied that risk. One large sample, shared, with retries.
    func refreshVendorReadings() async {
        guard case .proxy(_, let index, _) = transport else { return }

        let subAddressed = VendorControl.allCases.compactMap { control -> (VendorControl, VendorBinding)? in
            guard let binding = vendorMap[control], binding.isSubAddressed else { return nil }
            return (control, binding)
        }
        guard !subAddressed.isEmpty else { return }

        for code in Set(subAddressed.map { $0.1.code }) {
            var wanted = Set(subAddressed.filter { $0.1.code == code }.compactMap { $0.1.selector })
            for _ in 0..<3 {
                guard let map = try? await agent.readSubSelectorMap(monitor: index, code: code)
                else { break }
                for (control, binding) in subAddressed where binding.code == code {
                    if let selector = binding.selector, let value = map[selector] {
                        vendorReadings[control.rawValue] = value
                        wanted.remove(selector)
                    }
                }
                if wanted.isEmpty { break }
            }
        }
    }

    /// True when a sub-addressed control still has no reading.
    private var vendorReadingsIncomplete: Bool {
        VendorControl.allCases.contains { control in
            guard let binding = vendorMap[control], binding.isSubAddressed else { return false }
            return vendorReadings[control.rawValue] == nil
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
        if vendorReadingsIncomplete { await refreshVendorReadings() }
    }

    /// Both the menu bar panel and the window ask for this on appear; only the
    /// first call does the work.
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        refreshDisplays()
        await probe()
        await restoreKVMIfPreviouslyOn()
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
    func probe() async {
        guard !isProbing else { return }
        isProbing = true
        probeStatus = "Examining the video link…"
        defer { isProbing = false; probeStatus = "" }

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

    private func loadFeaturesViaProxy() async {
        probeStatus = "Contacting \(proxyHost)…"
        await agent.update(config: .init(host: proxyHost, enabled: true))

        do {
            let monitors = try await agent.list()
            remoteMonitors = monitors
            guard let target = matchRemote(monitors) else {
                transport = .none
                proxyDiagnostic = monitors.isEmpty
                    ? "\(proxyHost) is reachable but reports no monitors. The agent must run in the interactive desktop session."
                    : "\(proxyHost) sees \(monitors.count) monitor(s), none matching this display."
                return
            }

            remoteTarget = target
            probeStatus = "Reading capabilities from \(proxyHost)…"
            let capsString = try await agent.capabilities(monitor: target.index)
            let caps = capsString.isEmpty ? nil : Capabilities.parse(capsString)
            capabilities = caps

            // Drop the write-only restore commands before reading anything. The
            // capabilities string lists them next to real settings, and reading
            // 0x04 asks the monitor to restore its factory defaults.
            let codes = (caps?.supportedCodes ?? Self.fallbackCodes)
                .filter { !VCP.neverRead.contains($0) }
            probeStatus = "Reading \(codes.count) features from \(proxyHost)…"
            let readings = try await agent.read(monitor: target.index, codes: codes)

            var collected: [UInt8: FeatureState] = [:]
            for (code, reading) in readings {
                collected[code] = Self.makeState(code: code, current: reading.current,
                                                 maximum: reading.maximum, caps: caps)
            }
            features = collected
            seedVendorBindings()
            transport = .proxy(host: proxyHost, monitorIndex: target.index,
                               description: target.description)
            deriveActiveInputs()
            await refreshVendorReadings()
        } catch {
            transport = .none
            proxyDiagnostic = error.localizedDescription
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
                        vendorReadings[control.rawValue] = value
                    }
                    confirmVendorAfterSettling()
                }
                return readings[code]?.current ?? value
            } catch {
                lastError = error.localizedDescription
                return nil
            }
        }
    }

    /// Write, then confirm against the monitor. For discrete controls, where one
    /// write per interaction is the whole story.
    func set(code: UInt8, value: UInt16) async {
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
            if let reading = try? await agent.read(monitor: index, codes: [code])[code] {
                features[code]?.current = reading.current
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
                var out: [UInt8: UInt16] = [:]
                for (code, reading) in readings {
                    out[code] = reading.current
                    features[code]?.current = reading.current
                }
                return out
            } catch {
                lastError = error.localizedDescription
                return [:]
            }
        }
    }

    func reconnectProxy() async {
        await agent.disconnect()
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
