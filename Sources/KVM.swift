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

    /// How far inside the remote's left edge a crossing lands.
    static let entryInset: CGFloat = 4
    /// How far past that edge the pointer must be pushed to come back.
    static let returnThreshold: CGFloat = -24

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
                let bounds = macBounds
                let where_ = event.location
                if where_.x >= bounds.maxX - 1 {
                    handOver(atY: where_.y, in: bounds)
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

        // Deliberate panic chord: Control-Option-Command-Escape. Chosen to be
        // something no ordinary use produces by accident, and it is handled
        // here rather than forwarded so it works even if the far machine is
        // wedged.
        if type == .keyDown,
           UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == 0x35,
           event.flags.contains(.maskControl),
           event.flags.contains(.maskAlternate),
           event.flags.contains(.maskCommand) {
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

    private func handOver(atY y: CGFloat, in bounds: CGRect) {
        // Enter the far screen at the same height, proportionally, so the
        // pointer appears to continue in a straight line.
        let fraction = bounds.height > 0 ? (y - bounds.minY) / bounds.height : 0.5
        // A few pixels in, not on the edge itself. Entering at x=0 meant any
        // leftward jitter drove the accumulator straight below zero and handed
        // control back before the pointer had gone anywhere — measured at 51ms
        // between crossing out and crossing back.
        remotePoint = CGPoint(x: KVMController.entryInset,
                              y: min(max(fraction, 0), 1) * (remoteSize.height - 1))

        // Decouple the hardware from the cursor so it stops at the edge instead
        // of grinding along it, and hide it — deltas still arrive.
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())

        side = .there
        KVMLog.write("crossed OUT at y=\(Int(y)) -> remote \(Int(remotePoint.x)),\(Int(remotePoint.y)) "
                   + "of \(Int(remoteSize.width))x\(Int(remoteSize.height))")
        status = "controlling \(host) — pointer back at its left edge returns"
        transport.send("A \(Int(remotePoint.x)) \(Int(remotePoint.y))")
        onChange?()
    }

    private func handBack() {
        // Release every modifier before letting go. Crossing while holding one
        // and releasing it on this side means the far machine never hears the
        // release and behaves as though it is held forever.
        for vk in KeyMap.allModifierVKs { transport.send("K \(vk) 0") }

        let bounds = macBounds
        let fraction = remoteSize.height > 1 ? remotePoint.y / (remoteSize.height - 1) : 0.5
        let y = bounds.minY + min(max(fraction, 0), 1) * bounds.height

        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        // Two pixels in, not one: landing exactly on the edge re-triggers the
        // crossing test on the very next movement and the pointer bounces.
        CGWarpMouseCursorPosition(CGPoint(x: bounds.maxX - 2, y: y))

        side = .here
        KVMLog.write("crossed BACK to y=\(Int(y))")
        status = "armed — pointer at the right edge crosses to \(host)"
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
