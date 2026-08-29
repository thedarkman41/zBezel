import AppKit
import Foundation

/// Software KVM: hand the pointer and keyboard to the Windows machine when the
/// pointer leaves the right edge of this Mac's screen, and take them back when
/// it returns to the left edge of that machine's.
///
/// The far end is BezelAgent's `kvm` subcommand, reached over one long-lived SSH
/// channel. Opening that channel costs the better part of a second — almost all
/// of it PowerShell login-shell startup — so it is opened when the feature is
/// switched on and held, not opened at the crossing. Paid per crossing it would
/// stall the pointer for a second every time, which is exactly the moment the
/// user is paying attention.
///
/// Positions are sent absolutely. Relative events on the far side are measured
/// in mickeys and pass through the pointer acceleration curve — asking for
/// +200,-300 measured +522,-785 — so this tracks where the pointer is on the
/// remote desktop itself and says exactly where to put it.

// MARK: - Log

/// A trace of what the KVM did, at ~/Library/Logs/zBezel/kvm.log.
///
/// The same reasoning as the agent's log on the Windows side, for the same
/// reason. This feature takes over the pointer, so its failures are exactly the
/// ones that cannot be investigated interactively: when a crossing does not
/// happen there is nothing on screen to look at, and when one does happen the
/// pointer is somewhere else. The alternative is asking the user to narrate
/// symptoms, which is slower and loses the timing.
enum KVMLog {
    private static let queue = DispatchQueue(label: "com.darkstar.zBezel.kvm.log")
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/zBezel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("kvm.log")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = stamp.string(from: Date()) + "  " + message + "\n"
        queue.async {
            // Bounded. This is for "what is it doing now", not history.
            if let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? UInt64, size > 256 * 1024 {
                try? FileManager.default.removeItem(at: url)
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

// MARK: - Transport

/// One SSH channel, held open, carrying one event per line.
final class KVMTransport {
    private var process: Process?
    private var input: FileHandle?
    private let queue = DispatchQueue(label: "com.darkstar.zBezel.kvm.tx")

    private(set) var lastError: String?
    var isConnected: Bool { process?.isRunning == true }

    /// True once the far side has answered.
    ///
    /// isConnected only says the local ssh process started, which it does even
    /// when the host is unreachable or the agent is not running — the failure
    /// arrives a second later. Without waiting for the agent's own reply the UI
    /// would report "armed" and then do nothing at the first crossing, which is
    /// the worst moment to discover it.
    private let readyLock = NSLock()
    private var readyFlag = false
    var isReady: Bool {
        readyLock.lock(); defer { readyLock.unlock() }
        return readyFlag
    }

    /// Writing to a pipe whose reader has gone raises SIGPIPE, and the default
    /// disposition for that is to kill the process — the whole app, not the
    /// write. The KVM is the one part of zBezel that writes continuously to a
    /// remote pipe, so it is the part that would trip it.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    func connect(host: String, exePath: String) {
        _ = KVMTransport.ignoreSIGPIPE
        disconnect()
        readyLock.lock(); readyFlag = false; readyLock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            // No ControlMaster here on purpose. The DDC calls multiplex over a
            // shared master because they are short and frequent; this channel
            // is long-lived and carries a continuous stream, and sharing it
            // would put pointer events behind a slow capabilities read.
            host, "& \"\(exePath)\" kvm",
        ]

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        do { try task.run() } catch {
            lastError = "could not start ssh: \(error.localizedDescription)"
            return
        }
        process = task
        input = stdin.fileHandleForWriting
        lastError = nil
        sentCount = 0
        KVMLog.write("transport: ssh started pid \(task.processIdentifier)")

        // Drain both so a full pipe cannot block the far side, and keep the
        // last stderr line as the reason if the channel dies.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard text.contains("\"kvm\":\"ready\"") else { return }
            guard let self else { return }
            self.readyLock.lock()
            self.readyFlag = true
            self.readyLock.unlock()
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self?.lastError = text }
        }
    }

    private var sentCount = 0

    func send(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let handle = self.input else {
                KVMLog.write("send DROPPED (no channel): \(line)")
                return
            }
            guard let data = (line + "\n").data(using: .utf8) else { return }
            do {
                try handle.write(contentsOf: data)
                self.sentCount += 1
                if self.sentCount <= 8 { KVMLog.write("sent[\(self.sentCount)] \(line)") }
            } catch {
                self.lastError = "send failed: \(error.localizedDescription)"
                KVMLog.write("send FAILED: \(line) — \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        if let handle = input {
            // Ask the far side to exit rather than relying on EOF: the remote
            // shell is PowerShell and does not reliably propagate a closed
            // stdin to the child, which leaves the agent waiting forever.
            try? handle.write(contentsOf: Data("quit\n".utf8))
        }
        queue.sync { }                       // let queued writes drain first
        input = nil
        if let task = process, task.isRunning { task.terminate() }
        process = nil
    }
}

// MARK: - Controller

final class KVMController {

    enum Side { case here, there }

    private(set) var side: Side = .here
    private(set) var isEnabled = false
    private(set) var status: String = "off"

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let transport = KVMTransport()

    /// Where the pointer is on the remote desktop, in its pixels. Tracked here
    /// because the remote is not telling us — we are telling it.
    private var remotePoint = CGPoint.zero
    private var remoteSize = CGSize(width: 1920, height: 1080)

    /// How far past the remote's left edge the pointer must be pushed to come
    /// back. Not zero: a single stray pixel of leftward jitter used to hand
    /// control back 51ms after taking it.
    static let returnThreshold: CGFloat = -24

    /// The escape hatch: fn, Control, Option and Command, held together.
    ///
    /// All modifiers and no letter, deliberately. It has to be reachable with
    /// one hand while the other is still on the mouse, and it must not be
    /// something the far machine could reasonably want — every one of these is
    /// swallowed here rather than forwarded, so any chord chosen is a chord the
    /// PC can never receive.
    /// Where the Mac's own pointer is held while the PC has control.
    ///
    /// It has to go somewhere, and hiding it is not available: CGDisplayHideCursor
    /// and CGAssociateMouseAndMouseCursorPosition both apply only while the
    /// CALLING application is frontmost, and this is an LSUIElement menu bar app
    /// that is never frontmost. Both calls are made anyway — they cost nothing
    /// and do work if the app happens to be active — but neither can be relied
    /// on, which is why the pointer was seen wandering across the main screen.
    ///
    /// So park it on the panel instead. While the PC has control the panel is
    /// showing the PC, so the Mac's pointer sitting in the middle of it is drawn
    /// to a screen nobody is looking at: invisible without needing to be hidden,
    /// and stationary without needing the association to hold.
    private var parkingSpot: CGPoint = .zero

    private static let panicChord: CGEventFlags =
        [.maskSecondaryFn, .maskControl, .maskAlternate, .maskCommand]

    // MARK: The portal
    //
    // The monitor is an extended display for the Mac on one input and the PC's
    // only display on another, so it is the same sheet of glass either way.
    // That makes its right edge a doorway rather than the end of the desktop:
    // pushing through it switches the panel to the PC and hands over the
    // pointer together, and the pointer keeps the spot on the glass it already
    // had. Coming back is the mirror image, except the pointer lands on the
    // Mac's main display rather than on the panel — the panel has just been
    // told to show the Mac again and takes a second or two to do it, and a
    // pointer waiting on a screen that is still black reads as a lost pointer.

    /// The panel that shows the Mac on one input and the PC on another.
    /// Captured before switching, because switching may take it out of the
    /// Mac's display list and the geometry is needed to map the crossing.
    private var portalBounds: CGRect?
    private var mainBounds: CGRect = .zero

    /// Input Select values for the two sides. Supplied by the caller, which
    /// owns the monitor profile.
    var macInput: UInt16 = 0x0F          // DisplayPort
    var pcInput: UInt16 = 0x13           // USB-C

    /// Put the monitor on an input. Fired, never awaited: the pointer has to
    /// move now, and the panel catches up in its own time — a DDC write through
    /// the proxy costs the better part of a second, and blocking the event tap
    /// on it would stall every input event on the Mac behind it.
    var setMonitorInput: ((UInt16) -> Void)?

    /// Whether crossing should switch the monitor's input as well as the
    /// pointer. Off means the KVM behaves as it did before: control moves, the
    /// panel does not.
    var switchesInput = true

    func configurePortal(bounds: CGRect?, main: CGRect) {
        portalBounds = bounds ?? portalBounds     // keep the last known geometry
        mainBounds = main
    }

    private var host = ""
    private var exePath = #"$HOME\bezel\BezelAgent.exe"#

    /// Called when control changes hands, so the UI can follow.
    var onChange: (() -> Void)?

    // MARK: Geometry

    /// Every active display, unioned, in CoreGraphics' top-left origin space.
    private var macBounds: CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return CGDisplayBounds(CGMainDisplayID())
        }
        var rect = CGRect.null
        for id in ids { rect = rect.union(CGDisplayBounds(id)) }
        return rect.isNull ? CGDisplayBounds(CGMainDisplayID()) : rect
    }

    // MARK: Enable / disable

    /// True once the user has granted Accessibility. Without it CGEvent.tapCreate
    /// returns nil and there is no way to either observe or suppress input.
    static func hasInputPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func enable(host: String, exePath: String, remoteSize: CGSize?) -> String? {
        guard !isEnabled else { return nil }
        guard !host.isEmpty else { return "No proxy host is configured." }
        self.host = host
        self.exePath = exePath
        if let size = remoteSize, size.width > 1, size.height > 1 {
            self.remoteSize = size
        }

        let trusted = KVMController.hasInputPermission(prompt: true)
        KVMLog.write("enable: host=\(host) accessibility=\(trusted)")
        guard trusted else {
            return "zBezel needs Accessibility permission to capture input. "
                 + "Grant it in System Settings > Privacy & Security > Accessibility, "
                 + "then switch this on again."
        }
        let tapped = installTap()
        KVMLog.write("enable: eventTap=\(tapped)")
        guard tapped else {
            return "Could not create the event tap even though Accessibility is granted. "
                 + "Removing zBezel from the Accessibility list and re-adding it usually clears this."
        }

        transport.connect(host: host, exePath: exePath)
        isEnabled = true
        side = .here
        status = "armed — pointer at the right edge crosses to \(host)"
        onChange?()
        return nil
    }

    func disable() {
        guard isEnabled else { return }
        KVMLog.write("disable")
        if side == .there { handBack() }
        removeTap()
        transport.disconnect()
        isEnabled = false
        status = "off"
        onChange?()
    }

    // MARK: Tap

    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<KVMController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,               // must be able to suppress, not just observe
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    private func removeTap() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
    }

    // MARK: Event handling

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long in its callback, and
        // says so by sending this instead of an event. Re-enabling is the only
        // recovery; without it the KVM dies silently on the first hiccup.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return nil
        }
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        if side == .here {
            // Only looking for the crossing; everything passes through.
            if type == .mouseMoved || type == .leftMouseDragged
                || type == .rightMouseDragged || type == .otherMouseDragged {
                // The doorway is the PANEL's right edge, not the desktop's.
                // They coincide in the usual layout, but only by accident of
                // the panel being the rightmost display — put it on the left
                // and the desktop edge would be the wrong wall entirely.
                let doorway = portalBounds ?? macBounds
                let where_ = event.location
                if where_.x >= doorway.maxX - 1 {
                    handOver(at: where_, doorway: doorway)
                    return nil
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // ---- Escape hatches ----
        //
        // While control is handed over, this tap swallows every pointer and key
        // event on the Mac. If it kept doing that when it could no longer
        // deliver them, the user would be left with no keyboard and no pointer
        // and no way to fix it — the input needed to recover is the input being
        // eaten. Both of these have to be checked before anything is swallowed.

        // The far end has gone: stop swallowing at once and pass this event on.
        if !transport.isConnected {
            handBack()
            status = "\(host) stopped answering — control returned"
            onChange?()
            return Unmanaged.passUnretained(event)
        }

        // The panic chord: fn, Control, Option and Command held together.
        //
        // Handled here rather than forwarded, so it works even if the far
        // machine is wedged or the channel is dead.
        //
        // Tested against the flags of EVERY event, not just flagsChanged. A
        // chord made only of modifiers has no keystroke to hang the test on,
        // and the natural thing to do while holding it is to move the mouse —
        // requiring a modifier transition would mean the chord did nothing
        // until the user let go and pressed again, which is the opposite of
        // what an escape hatch should ask of someone.
        if event.flags.isSuperset(of: KVMController.panicChord) {
            KVMLog.write("panic chord — returning control")
            handBack()
            return nil
        }

        // Fallback, kept on purpose: Control-Option-Command-Escape.
        //
        // fn is confirmed working on the keyboard this was built against, so
        // this is not covering a known failure. It covers an unknown one: not
        // every keyboard reports fn at all, and the way that failure presents
        // is the user holding the chord with no pointer, no keyboard and
        // nothing happening — the one situation this mechanism exists to
        // prevent, on the one day nobody is watching the log. A second hatch
        // costs a comparison.
        if type == .keyDown,
           UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == 0x35,
           event.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand]) {
            KVMLog.write("panic chord (Escape fallback) — returning control")
            handBack()
            return nil
        }


        forward(type: type, event: event)
        return nil                              // swallowed: this Mac must not act on it
    }

    private func forward(type: CGEventType, event: CGEvent) {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            remotePoint.x += dx
            remotePoint.y += dy

            // Coming home takes a deliberate push past the left edge, not a
            // single stray pixel. The accumulator is allowed to go negative so
            // that push has to be sustained; what gets SENT is always clamped
            // to the remote desktop.
            if remotePoint.x < KVMController.returnThreshold { handBack(); return }

            remotePoint.x = min(remotePoint.x, remoteSize.width - 1)
            remotePoint.y = min(max(remotePoint.y, 0), remoteSize.height - 1)
            let sendX = min(max(remotePoint.x, 0), remoteSize.width - 1)
            transport.send("A \(Int(sendX)) \(Int(remotePoint.y))")

            // Put the Mac's pointer back where it cannot be seen. Cheap, and it
            // generates no event of its own, so it cannot feed back into this
            // tap; the deltas above come from the hardware fields rather than
            // from comparing positions, so warping does not disturb tracking.
            CGWarpMouseCursorPosition(parkingSpot)

        case .leftMouseDown:   transport.send("B 1 1")
        case .leftMouseUp:     transport.send("B 1 0")
        case .rightMouseDown:  transport.send("B 2 1")
        case .rightMouseUp:    transport.send("B 2 0")
        case .otherMouseDown:  transport.send("B 3 1")
        case .otherMouseUp:    transport.send("B 3 0")

        case .scrollWheel:
            // Windows counts wheel notches in units of 120.
            let vertical = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let horizontal = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            if vertical != 0 { transport.send("W \(Int(vertical * 120))") }
            if horizontal != 0 { transport.send("H \(Int(horizontal * 120))") }

        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if let vk = KeyMap.windowsKey(for: code) {
                transport.send("K \(vk) \(type == .keyDown ? 1 : 0)")
            }

        case .flagsChanged:
            // These do not say up or down, only the resulting flag state, so
            // read the state of the flag this key owns.
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let flag = KeyMap.modifierFlags[code],
                  let vk = KeyMap.windowsKey(for: code) else { return }
            let down = event.flags.contains(flag)
            transport.send("K \(vk) \(down ? 1 : 0)")

        default:
            break
        }
    }

    // MARK: Crossings

    private func handOver(at point: CGPoint, doorway: CGRect) {
        // Keep the spot on the glass.
        //
        // The panel is about to stop showing the Mac and start showing the PC,
        // and it is the same physical screen either way, so the pointer belongs
        // where the user last saw it. Proportionally, not by pixel: the Mac
        // drives this panel at 2560x1440 logical and the PC drives it at
        // 3840x2160, so equal fractions land on the same glass, equal
        // coordinates would not.
        let relX = doorway.width  > 0 ? (point.x - doorway.minX) / doorway.width  : 1
        let relY = doorway.height > 0 ? (point.y - doorway.minY) / doorway.height : 0.5
        remotePoint = CGPoint(x: min(max(relX, 0), 1) * (remoteSize.width  - 1),
                              y: min(max(relY, 0), 1) * (remoteSize.height - 1))

        // Decouple the hardware from the cursor so it stops at the edge instead
        // of grinding along it, and hide it — deltas still arrive.
        // Best-effort: these only bite while this app is frontmost, which it
        // generally is not. The parking below is what actually holds.
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())

        // Middle of the panel, which is about to be showing the PC. If there is
        // no panel to hide behind, fall back to the far corner of the desktop,
        // where a stationary pointer is at least out of the way.
        parkingSpot = portalBounds.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: macBounds.maxX - 2, y: macBounds.maxY - 2)
        CGWarpMouseCursorPosition(parkingSpot)

        side = .there
        KVMLog.write("crossed OUT at \(Int(point.x)),\(Int(point.y)) -> remote "
                   + "\(Int(remotePoint.x)),\(Int(remotePoint.y)) "
                   + "of \(Int(remoteSize.width))x\(Int(remoteSize.height))")
        transport.send("A \(Int(remotePoint.x)) \(Int(remotePoint.y))")

        // Send the pointer first, then the panel. The pointer is already on the
        // far machine as far as the user is concerned, and the input switch
        // costs the better part of a second through the proxy.
        if switchesInput {
            KVMLog.write("switching panel to the PC input (0x\(String(pcInput, radix: 16)))")
            setMonitorInput?(pcInput)
        }
        status = "controlling \(host) — its left edge brings you back"
        onChange?()
    }

    private func handBack() {
        // Release every modifier before letting go. Crossing while holding one
        // and releasing it on this side means the far machine never hears the
        // release and behaves as though it is held forever.
        for vk in KeyMap.allModifierVKs { transport.send("K \(vk) 0") }

        // Land on the Mac's MAIN display, not back on the panel.
        //
        // The panel has just been told to show the Mac again and takes a second
        // or two to renegotiate the link. A pointer parked on a screen that is
        // still black is indistinguishable from a pointer that has been lost,
        // and the reflex is to move the mouse harder, which would only push it
        // back through the doorway.
        let landing = mainBounds.isEmpty ? macBounds : mainBounds
        let fraction = remoteSize.height > 1 ? remotePoint.y / (remoteSize.height - 1) : 0.5
        let y = landing.minY + min(max(fraction, 0), 1) * landing.height

        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        // Two pixels in, not one: landing exactly on the edge re-triggers the
        // crossing test on the very next movement and the pointer bounces.
        CGWarpMouseCursorPosition(CGPoint(x: landing.maxX - 2, y: y))

        side = .here
        KVMLog.write("crossed BACK to \(Int(landing.maxX - 2)),\(Int(y))")
        if switchesInput {
            KVMLog.write("switching panel to the Mac input (0x\(String(macInput, radix: 16)))")
            setMonitorInput?(macInput)
        }
        status = "armed — the panel's right edge crosses to \(host)"
        onChange?()
    }

    /// The remote desktop's size, so absolute positions mean the same thing at
    /// both ends. Supplied by the caller from the agent's `cursor` reply.
    func updateRemoteSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        remoteSize = size
    }

    var transportError: String? { transport.lastError }
    var transportConnected: Bool { transport.isConnected }
    var transportReady: Bool { transport.isReady }

    /// Note that the channel came up, or say why it did not.
    func noteReadiness() {
        KVMLog.write("transport ready=\(transport.isReady) connected=\(transport.isConnected) "
                   + "error=\(transport.lastError ?? "none")")
        if transport.isReady {
            status = "armed — pointer at the right edge crosses to \(host)"
        } else {
            status = "no answer from \(host)"
        }
        onChange?()
    }
}
