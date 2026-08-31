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

/// One SSH channel, held open, carrying one line at a time.
///
/// Two of these run: pointer and keyboard on one, clipboard on the other.
/// Separate connections rather than one, because they have opposite shapes —
/// the input channel carries tiny messages that must never wait, the clipboard
/// carries occasional large ones. Sharing a stream meant a paste sat in front of
/// every pointer event behind it and the pointer visibly froze mid-motion, which
/// is what the old 1MB payload cap existed to keep brief.
///
/// Not multiplexed onto the DDC connection either, though SSH would allow it:
/// RemoteAgent tears that master down with `ssh -O exit` whenever the host
/// setting changes, which would take the clipboard with it as a side effect of
/// an unrelated action.
final class KVMTransport {
    /// How to get back if the channel dies. Set on every connect.
    private var lastHost: String?
    private var lastExePath = ""
    private var reconnecting = false

    /// The agent subcommand this channel runs.
    private let command: String

    init(command: String) { self.command = command }

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
        lastHost = host
        lastExePath = exePath
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
            host, "& \"\(exePath)\" \(command)",
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
        KVMLog.write("transport[\(command)]: ssh started pid \(task.processIdentifier)")

        // Drain both so a full pipe cannot block the far side, and keep the
        // last stderr line as the reason if the channel dies.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }

            // Split on BYTES, not Characters.
            //
            // The far side is Console.WriteLine on Windows, so lines end "\r\n"
            // — and in Swift "\r\n" is a single Character, so searching a String
            // for "\n" never matches it. Every line silently failed to parse:
            // the ready handshake stopped being seen and clipboard payloads were
            // dropped, while the channel itself was working perfectly.
            //
            // Only this handler touches the buffer.
            self.stdoutBuffer.append(chunk)
            if self.stdoutBuffer.count > 8 * 1_048_576 {
                KVMLog.write("transport: discarding an oversized unterminated reply")
                self.stdoutBuffer.removeAll(keepingCapacity: false)
                return
            }
            while let newline = self.stdoutBuffer.firstIndex(of: 0x0A) {
                let raw = self.stdoutBuffer[self.stdoutBuffer.startIndex..<newline]
                self.stdoutBuffer.removeSubrange(self.stdoutBuffer.startIndex...newline)
                let line = String(decoding: raw, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.contains("\"ready\"") {
                    self.readyLock.lock()
                    self.readyFlag = true
                    self.readyLock.unlock()
                } else if !line.isEmpty {
                    self.onLine?(line)
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self?.lastError = text }
        }
    }

    private var sentCount = 0
    private var stdoutBuffer = Data()

    /// A complete line received from the far side, other than the handshake.
    var onLine: ((String) -> Void)?

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
                // A dead pipe means the far agent went away — it was restarted,
                // the machine slept, or the network dropped. Nothing else in this
                // class notices, so the UI went on claiming control of a machine
                // that had not heard from us in minutes. Say so, and reconnect.
                self.lastError = "send failed: \(error.localizedDescription)"
                KVMLog.write("send FAILED: \(line) — \(error.localizedDescription)")
                self.input = nil
                self.scheduleReconnect()
            }
        }
    }

    /// Bring the channel back after the far side has vanished.
    ///
    /// Throttled, because a burst of pointer events against a dead pipe would
    /// otherwise queue a reconnect per event. The first failure is the one that
    /// matters; the rest are the same failure arriving repeatedly.
    private func scheduleReconnect() {
        guard !reconnecting, let host = lastHost else { return }
        reconnecting = true
        let exe = lastExePath
        KVMLog.write("channel to \(host) died; reconnecting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.reconnecting = false
            self.connect(host: host, exePath: exe)
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
    /// One machine the pointer can reach, in the order it is reached.
    ///
    /// The Mac is not in this list; it is where the chain starts. Crossing the
    /// panel's right edge enters the first entry, and pushing past THAT machine's
    /// right edge enters the next — the arrangement of the desks, described once.
    struct Machine: Codable, Equatable, Identifiable {
        var name: String
        var host: String
        /// The monitor's Input Select value for this machine's cable.
        var input: UInt16
        var width: Double = 1920
        var height: Double = 1080

        var id: String { host }
        var size: CGSize { CGSize(width: width, height: height) }
    }

    /// The machines this pointer can reach. Order is only the order they are
    /// offered in; the pointer does not walk through them in a line.
    var machines: [Machine] = []

    /// Whether the panel is currently showing THIS Mac.
    ///
    /// The monitor will not say which input is live — 0x60 reports the last input
    /// it was commanded to, not the one on screen. What is reliable is the Mac's
    /// own display list: when the panel switches away from DisplayPort it stops
    /// being one of this Mac's displays.
    ///
    /// It decides which edge is the doorway. Showing the Mac, the panel is just
    /// more desktop and the doorway is its far edge. Showing another machine, the
    /// panel is not the Mac's at all — the desktop ends at the built-in screen,
    /// and that is where the pointer should leave.
    var panelShowsMac = true

    /// The input the panel was last told to show, so the machine already on
    /// screen can be handed control without a switch.
    var currentInput: UInt16 = 0x0F

    /// Ask the user which machine to go to. Called on the main queue.
    ///
    /// Only when the panel is showing the Mac and there is more than one machine
    /// to choose between: with one machine there is no question, and when the
    /// panel is already showing a machine the answer is that machine.
    /// Carries the point the pointer left at, so the tiles can appear beside it.
    var presentChooser: ((CGPoint) -> Void)?

    /// True while the chooser is on screen. The pointer stays on the Mac and
    /// events pass through untouched — the user needs it to click a tile — and
    /// the edge is not armed, or it would re-trigger the moment they arrive.
    private(set) var choosing = false
    private var pendingCrossing: (point: CGPoint, doorway: CGRect)?
    /// Set by the chooser so the crossing it resumes does not ask again.
    private var chosenIndex: Int?

    /// Whether the panel stays on this machine when the pointer goes home.
    ///
    /// Shown as a padlock ON the far machine, because that is the screen the user
    /// is looking at. Clicking it is recognised here rather than there: the Mac
    /// is the one placing the pointer, so it knows when a click lands on the
    /// badge, and the badge itself is click-through and never steals one meant
    /// for the application underneath.
    /// Which machine the panel is pinned to, if any.
    ///
    /// A lock is a statement about the MONITOR, not about a visit: while it is
    /// held the panel shows that machine and nothing else, so leaving does not
    /// switch back and arriving does not ask where to go. That also makes it the
    /// most reliable thing we have about which input is live — better than the
    /// tracked command, which drifts, and better than the display list, which
    /// only says whether the Mac is on screen.
    private(set) var lockedIndex: Int?

    /// True between a dragging crossing and the release that ends it. The ghost
    /// on the far machine is showing, and the button-up has to put it away.
    private var carrying = false

    /// Stamped on events this class posts to the Mac, so the tap can recognise
    /// its own work and let it through. Without it they would be captured and
    /// forwarded to the far machine like any other input — the tap has no other
    /// way to tell them from the user's.
    private static let selfStamp: Int64 = 0x7A42455A

    var remoteLocked: Bool { lockedIndex != nil }

    /// The badge's side, matching the agent's own constant.
    private static let badgeSide: CGFloat = 140

    /// Where the badge is sitting on the far desktop. The Mac chooses this — it
    /// places the badge — so it also knows where a click on it would land.
    private var badgeOrigin = CGPoint.zero
    private var badgeVisible = false

    private var lockRect: CGRect {
        CGRect(origin: badgeOrigin,
               size: CGSize(width: KVMController.badgeSide, height: KVMController.badgeSide))
    }

    /// Put the badge beside the point the pointer just arrived at, so it is a
    /// short hop away rather than across the desk. Below and to the left, since
    /// arrivals come in at the right edge; clamped so it cannot hang off screen.
    /// The corner the badge sits in once locked, and stays in.
    ///
    /// A locked badge is a status light, not a button waiting to be pressed, so
    /// it must not follow the pointer around: something that moves to meet you
    /// reads as needing attention, and this needs none until you go looking for
    /// it.
    private func parkBadge() {
        let side = KVMController.badgeSide
        badgeOrigin = CGPoint(x: 24, y: max(remoteSize.height - side - 24, 8))
    }

    private func placeBadge(near point: CGPoint) {
        let side = KVMController.badgeSide
        let x = min(max(point.x - side - 24, 8), max(remoteSize.width - side - 8, 8))
        let y = min(max(point.y + 24, 8), max(remoteSize.height - side - 8, 8))
        badgeOrigin = CGPoint(x: x, y: y)
    }
    /// Which of them the pointer is on. Meaningless while `side == .here`.
    private var machineIndex = 0

    /// How far past a machine's right edge the pointer must be pushed to move on
    /// to the next. Mirrors returnThreshold, and for the same reason: an edge
    /// crossing has to be deliberate, not a stray pixel of overshoot.
    static let advanceThreshold: CGFloat = 24

    /// One connection per machine, opened when the KVM is armed so that a
    /// crossing costs no SSH handshake.
    private var transports: [String: KVMTransport] = [:]
    private var transport: KVMTransport {
        if let existing = transports[host] { return existing }
        let fresh = KVMTransport(command: "kvm")
        transports[host] = fresh
        return fresh
    }
    private let clipTransport = KVMTransport(command: "clipboard")
    private let clipboard = ClipboardBridge()

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
    ///
    /// Held as an ID and looked up live, NOT as cached bounds.
    ///
    /// Caching it was justified by an assumption that switching the panel to the
    /// PC would take the display out of the Mac's list — which turned out to be
    /// false: the DisplayPort link stays up while the panel shows something
    /// else. What the cache did instead was go stale whenever the display
    /// re-enumerated at a different size, which is exactly what changing the
    /// DisplayPort version does. A stale right edge does not fail visibly; it
    /// moves the doorway into the middle of the screen, and the pointer starts
    /// crossing two thirds of the way across.
    private var portalDisplay: CGDirectDisplayID?
    /// Only used if the display really has gone away.
    private var lastKnownPortalBounds: CGRect?

    /// The doorway, as it is right now.
    private var portalBounds: CGRect? {
        if let id = portalDisplay {
            let live = CGDisplayBounds(id)
            if !live.isEmpty { return live }
        }
        return lastKnownPortalBounds
    }
    /// Where the pointer lands coming back. Live, for the same reason as the
    /// doorway: a cached rectangle survives the display changing size and then
    /// puts the pointer somewhere that is no longer the edge it names.
    private var mainBounds: CGRect { CGDisplayBounds(CGMainDisplayID()) }

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

    func configurePortal(display: CGDirectDisplayID?) {
        guard let display else { return }
        portalDisplay = display
        lastKnownPortalBounds = CGDisplayBounds(display)
    }

    private var host = ""
    private var exePath = #"$HOME\bezel\BezelAgent.exe"#

    /// Called when control changes hands, so the UI can follow.
    var onChange: (() -> Void)?

    /// Something worth putting in front of the user.
    var onNotice: ((String) -> Void)?

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

        // Clipboard sync runs whenever the KVM is armed, not only while the PC
        // has control: the whole point is to copy here, cross over, and paste
        // there — by which time control has already changed hands.
        clipboard.send = { [weak self] line in self?.clipTransport.send(line) }
        clipboard.onNotice = { [weak self] note in self?.onNotice?(note) }
        clipTransport.onLine = { [weak self] line in
            if line.hasPrefix("S ") {
                let encoded = String(line.dropFirst(2))
                if let data = Data(base64Encoded: encoded), !data.isEmpty {
                    DispatchQueue.main.async { self?.onScreenshot?(data) }
                }
                return
            }
            guard line.hasPrefix("C ") else { return }
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return }
            // AppKit's pasteboard is main-thread work; this arrives on the
            // pipe-reading queue.
            DispatchQueue.main.async {
                self?.clipboard.apply(format: parts[1], base64: parts[2])
            }
        }

        // Every machine in the chain, not just the first: a crossing should cost
        // a line on an open pipe, not an SSH handshake.
        for machine in machines {
            let pipe = transports[machine.host] ?? KVMTransport(command: "kvm")
            transports[machine.host] = pipe
            pipe.connect(host: machine.host, exePath: exePath)
        }
        if machines.isEmpty { transport.connect(host: host, exePath: exePath) }
        clipTransport.connect(host: host, exePath: exePath)
        clipboard.start()
        isEnabled = true
        side = .here
        let first = machines.first?.name ?? host
        status = machines.count > 1
            ? "armed — right edge crosses to \(first), and on through \(machines.count) machines"
            : "armed — pointer at the right edge crosses to \(first)"
        onChange?()
        return nil
    }

    func disable() {
        guard isEnabled else { return }
        KVMLog.write("disable")
        if side == .there { handBack() }
        clipboard.stop()
        removeTap()
        for pipe in transports.values { pipe.disconnect() }
        clipTransport.disconnect()
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
        // Our own synthetic events pass straight through, always.
        if event.getIntegerValueField(.eventSourceUserData) == KVMController.selfStamp {
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        if side == .here {
            // Only looking for the crossing; everything passes through.
            if type == .mouseMoved || type == .leftMouseDragged
                || type == .rightMouseDragged || type == .otherMouseDragged {
                // Which edge is the doorway depends on what the panel is
                // showing. While it shows the Mac it is ordinary desktop and the
                // doorway is its far side; while it shows another machine the
                // desktop stops at the built-in screen, so leaving THAT is the
                // crossing — the pointer should arrive on the machine already
                // visible rather than travelling across a panel it cannot see.
                // A locked panel is showing that machine, so the Mac's desktop
                // effectively ends at the built-in screen even though the panel
                // is still in its display list.
                let panelIsMine = panelShowsMac && lockedIndex == nil
                let doorway = panelIsMine ? (portalBounds ?? macBounds) : mainBounds
                let where_ = event.location
                if where_.x >= doorway.maxX - 1, !choosing {
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
            if remotePoint.x < KVMController.returnThreshold {
                // A lock is a two-place arrangement: this machine and the Mac.
                // Walking the chain would take the pointer through machines whose
                // desktops are not on screen — the panel is pinned here — so it
                // would be travelling blind across a machine it cannot see.
                if lockedIndex == nil, machineIndex > 0 {
                    step(to: machineIndex - 1, enteringFromLeft: false)
                } else {
                    handBack()
                }
                return
            }
            if lockedIndex == nil,
               remotePoint.x > remoteSize.width - 1 + KVMController.advanceThreshold,
               machineIndex + 1 < machines.count {
                step(to: machineIndex + 1, enteringFromLeft: true)
                return
            }

            remotePoint.x = min(remotePoint.x, remoteSize.width - 1)
            remotePoint.y = min(max(remotePoint.y, 0), remoteSize.height - 1)
            let sendX = min(max(remotePoint.x, 0), remoteSize.width - 1)
            transport.send("A \(Int(sendX)) \(Int(remotePoint.y))")

            // Put the Mac's pointer back where it cannot be seen. Cheap, and it
            // generates no event of its own, so it cannot feed back into this
            // tap; the deltas above come from the hardware fields rather than
            // from comparing positions, so warping does not disturb tracking.
            CGWarpMouseCursorPosition(parkingSpot)

        case .leftMouseDown:
            // A click on the badge is a command to this app, not input for the
            // far machine, so it is swallowed rather than forwarded.
            if badgeVisible, lockRect.contains(remotePoint) {
                lockedIndex = (lockedIndex == nil) ? machineIndex : nil
                // Locked, it stops being a thing to click and becomes a thing to
                // notice, so it goes to the corner and out of the way. Unlocked,
                // it returns to the hand that is about to use it.
                if lockedIndex != nil { parkBadge() } else { placeBadge(near: remotePoint) }
                transport.send("L \(remoteLocked ? 1 : 0) "
                             + "\(Int(badgeOrigin.x)) \(Int(badgeOrigin.y))")
                KVMLog.write("lock \(remoteLocked ? "engaged" : "released") on \(host)")
                status = remoteLocked
                    ? "controlling \(host) — locked: the panel stays here"
                    : "controlling \(host) — its left edge brings you back"
                onChange?()
                return
            }
            // A click anywhere else dismisses the badge and gives up the lock:
            // the question has been answered by ignoring it. The click itself
            // still goes through — the user was clicking on something.
            if badgeVisible {
                // Put the badge away, but leave the lock exactly as it was. The
                // lock is a decision; dismissing the badge is just tidying the
                // screen. Releasing it here meant a locked panel silently
                // unlocked itself the moment the user clicked on anything.
                badgeVisible = false
                transport.send("L -1")
                KVMLog.write("badge dismissed; lock stays \(remoteLocked ? "engaged" : "off")")
                onChange?()
            }
            transport.send("B 1 1")
        case .leftMouseUp:
            // Its down was swallowed; sending the up alone would land as a click
            // with no press on the far machine.
            if carrying {
                // The drop. The file is already on its way — the copy started at
                // the crossing — so this only takes the ghost away.
                carrying = false
                // The agent works out what the pointer is over and moves the
                // staged file there. It hides the ghost itself, so there is no
                // separate D command and no window between the two.
                transport.send("DROP")
                releaseMacDrag()
                KVMLog.write("drop requested on \(host)")
            }
            if badgeVisible, lockRect.contains(remotePoint) { return }
            transport.send("B 1 0")
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

    /// Move the pointer from one machine in the chain to its neighbour.
    ///
    /// The vertical position is carried across as a FRACTION of each desktop, so
    /// the pointer stays at the same height on the glass even though the machines
    /// run at different resolutions. Modifiers are released on the machine being
    /// left: crossing while holding Command and releasing it on the next machine
    /// leaves the first one believing it is still held.
    private func step(to index: Int, enteringFromLeft: Bool) {
        guard machines.indices.contains(index) else { return }
        for vk in KeyMap.allModifierVKs { transport.send("K \(vk) 0") }

        let fraction = remoteSize.height > 1
            ? min(max(remotePoint.y / (remoteSize.height - 1), 0), 1) : 0.5
        let leaving = machines.indices.contains(machineIndex)
            ? machines[machineIndex].name : host

        activate(machines[index], at: index)

        remotePoint = CGPoint(
            x: enteringFromLeft ? 0 : remoteSize.width - 1,
            y: fraction * (remoteSize.height - 1))
        transport.send("A \(Int(remotePoint.x)) \(Int(remotePoint.y))")

        KVMLog.write("stepped \(enteringFromLeft ? "right" : "left") "
                   + "from \(leaving) to \(host) at "
                   + "\(Int(remotePoint.x)),\(Int(remotePoint.y))")
        switchPanel(to: pcInput, why: "stepped to \(host)")
        status = "controlling \(machines[index].name)"
            + (index > 0 ? " — left edge goes back to \(machines[index - 1].name)"
                         : " — its left edge brings you back")
        onChange?()
    }

    /// Point the single-remote machinery at one entry in the chain.
    ///
    /// The rest of this class was written for exactly one far machine and still
    /// is; the chain simply re-aims it. Keeping host, size and input as the live
    /// pair rather than threading an index through every send site kept the
    /// change to the edges where it belongs.
    private func activate(_ machine: Machine, at index: Int) {
        machineIndex = index
        host = machine.host
        pcInput = machine.input
        if machine.size.width > 1, machine.size.height > 1 {
            remoteSize = machine.size
        }
    }

    private func handOver(at point: CGPoint, doorway: CGRect) {
        // Whichever machine is already on screen gets the pointer, with no input
        // switch: the user is looking at it, so handing control anywhere else
        // would be a surprise. Only when the panel is showing the Mac is there a
        // choice to make about where to go.
        let onScreen = machines.firstIndex { $0.input == currentInput }
        if let chosen = chosenIndex, machines.indices.contains(chosen) {
            chosenIndex = nil
            activate(machines[chosen], at: chosen)
        } else if let locked = lockedIndex, machines.indices.contains(locked) {
            // Locked: there is no question to ask. The panel is showing that
            // machine and the pointer goes straight back to it.
            activate(machines[locked], at: locked)
        } else if !panelShowsMac, let onScreen {
            activate(machines[onScreen], at: onScreen)
        } else if machines.count > 1, let ask = presentChooser {
            // More than one place to go and nothing on screen to imply which.
            // Hold the crossing, nudge the pointer off the edge so it is not
            // sitting on the trigger, and ask.
            pendingCrossing = (point, doorway)
            choosing = true
            CGWarpMouseCursorPosition(CGPoint(x: doorway.maxX - 40, y: point.y))
            status = "choose a machine"
            DispatchQueue.main.async { ask(point); self.onChange?() }
            return
        } else if let first = machines.first {
            activate(first, at: 0)
        }
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

        // WHERE the pointer lands depends on which wall it came through.
        //
        // Through the panel's own right edge, the panel is about to stop showing
        // the Mac and start showing this machine — same glass — so the pointer
        // belongs at the same spot on it, proportionally.
        //
        // Through the built-in screen's right edge, the machine is on the panel
        // NEXT to that screen. The pointer is arriving from its left, so it
        // enters at its left edge, the way it would cross between two desktops.
        // Carrying the fraction over would drop it on the far side, having
        // apparently skipped the whole screen.
        let fromBuiltIn = (lockedIndex != nil) || !panelShowsMac
        remotePoint = CGPoint(
            x: fromBuiltIn ? 0 : min(max(relX, 0), 1) * (remoteSize.width - 1),
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
        KVMLog.write("doorway was \(Int(doorway.minX))..\(Int(doorway.maxX)) "
                   + "x \(Int(doorway.minY))..\(Int(doorway.maxY))")
        KVMLog.write("crossed OUT at \(Int(point.x)),\(Int(point.y)) -> remote "
                   + "\(Int(remotePoint.x)),\(Int(remotePoint.y)) "
                   + "of \(Int(remoteSize.width))x\(Int(remoteSize.height))")
        transport.send("A \(Int(remotePoint.x)) \(Int(remotePoint.y))")
        // A locked panel stays locked across a second visit; anything else and
        // the badge would contradict what the monitor is about to do.
        // Locked, it stays in its corner across every arrival; only an unlocked
        // badge comes to meet the pointer.
        if lockedIndex != nil { parkBadge() } else { placeBadge(near: remotePoint) }
        badgeVisible = true
        transport.send("L \(remoteLocked ? 1 : 0) "
                     + "\(Int(badgeOrigin.x)) \(Int(badgeOrigin.y))")

        // If this crossing was a drag, the files go too.
        //
        // Read on the main queue, and immediately: the drag pasteboard lives only
        // for the length of the gesture, so a moment later there is nothing to
        // find. The copy itself runs elsewhere and takes as long as it takes.
        let target = host
        DispatchQueue.main.async { [weak self] in
            let files = DragTransfer.draggedFiles()
            guard !files.isEmpty else { return }
            KVMLog.write("drag carried \(files.count) file(s) to \(target)")
            // Show what is being carried, so the drag looks like a drag over
            // there too. It follows the cursor on that machine's own timer.
            let label = files.count == 1
                ? files[0].lastPathComponent
                : "\(files.count) items"
            self?.carrying = true
            self?.transport.send("D \(label)")
            DragTransfer.send(files, to: target,
                              progress: { line in
                                  Task { @MainActor in
                                      self?.status = line
                                      self?.onChange?()
                                  }
                              },
                              done: { line in
                                  Task { @MainActor in
                                      self?.status = line
                                      self?.onChange?()
                                      KVMLog.write("drag copy: \(line)")
                                  }
                              })
        }

        // Send the pointer first, then the panel. The pointer is already on the
        // far machine as far as the user is concerned, and the input switch
        // costs the better part of a second through the proxy.
        // Skip the switch only when we are CERTAIN the panel is already showing
        // this machine: the panel is not showing the Mac, and the input we last
        // commanded is this machine's.
        //
        // The tracked input drifts — the lock deliberately leaves the panel on
        // another machine, and the panel can come back to the Mac by itself with
        // nothing to tell us. Trusting it alone meant the app skipped the very
        // switch the user had just asked for, over and over. A redundant DDC
        // write costs a tenth of a second; a missed one costs the feature.
        // A lock on THIS machine is proof the panel is already showing it.
        let certainlyThere = !panelShowsMac && pcInput == currentInput
        if certainlyThere {
            KVMLog.write("panel already on 0x\(String(pcInput, radix: 16)); no switch")
        } else {
            switchPanel(to: pcInput, why: "arrived at \(host)")
        }
        status = "controlling \(machines.first?.name ?? host)"
            + (machines.count > 1
               ? " — right edge goes on to \(machines[1].name)"
               : " — its left edge brings you back")
        onChange?()
    }

    /// The user picked a machine from the chooser.
    func chooseMachine(at index: Int) {
        guard choosing, machines.indices.contains(index),
              let crossing = pendingCrossing else { return }
        choosing = false
        pendingCrossing = nil
        chosenIndex = index
        handOver(at: crossing.point, doorway: crossing.doorway)
    }

    /// End the drag still running on the Mac.
    ///
    /// The pointer left in the middle of a gesture, so Finder never saw a mouse
    /// up and still believes it is dragging — come back and the icon is still
    /// stuck to the cursor. Escape first, which CANCELS the drag rather than
    /// completing it: a plain mouse up would drop the file wherever the Mac's
    /// pointer happens to be parked, which is not somewhere the user chose.
    private func releaseMacDrag() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            if let key = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) {
                key.setIntegerValueField(.eventSourceUserData, value: KVMController.selfStamp)
                key.post(tap: .cghidEventTap)
            }
        }
        let here = CGEvent(source: nil)?.location ?? parkingSpot
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                            mouseCursorPosition: here, mouseButton: .left) {
            up.setIntegerValueField(.eventSourceUserData, value: KVMController.selfStamp)
            up.post(tap: .cghidEventTap)
        }
        KVMLog.write("cancelled the Mac's drag")
    }

    /// Every automatic input change goes through here.
    ///
    /// While a lock is held the panel belongs to the user, not to the pointer:
    /// nothing this class does moves it. Gating at one point rather than at each
    /// call site means a new crossing path cannot quietly reintroduce a switch —
    /// there were three call sites and each had its own condition, which is how
    /// the panel kept moving when it had been told not to.
    private func switchPanel(to input: UInt16, why reason: String) {
        guard switchesInput else { return }
        if let locked = lockedIndex {
            KVMLog.write("locked on \(machines.indices.contains(locked) ? machines[locked].name : "a machine")"
                       + "; NOT switching to 0x\(String(input, radix: 16)) (\(reason))")
            return
        }
        KVMLog.write("switching panel to 0x\(String(input, radix: 16)) — \(reason)")
        setMonitorInput?(input)
    }

    /// Let go of the panel. Called when the user changes the input themselves —
    /// having done that by hand, they have overruled the lock.
    func clearLock() {
        guard lockedIndex != nil else { return }
        lockedIndex = nil
        badgeVisible = false
        transport.send("L -1")
        KVMLog.write("lock cleared: the input was changed by hand")
        onChange?()
    }

    /// The chooser was dismissed without a choice. Nothing has moved, so there is
    /// nothing to undo — just re-arm the edge.
    func cancelChoice() {
        guard choosing else { return }
        choosing = false
        pendingCrossing = nil
        status = "armed — pointer at the right edge chooses a machine"
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
        switchPanel(to: macInput, why: "returned to the Mac")
        status = "armed — the panel's right edge crosses to \(host)"
        onChange?()
    }

    /// A picture of the far desktop arrived.
    var onScreenshot: ((Data) -> Void)?

    /// Ask for one. Rides the clipboard channel, so it cannot delay pointer
    /// events however large it turns out to be.
    func requestScreenshot(width: Int = 1280) {
        guard isEnabled else { return }
        clipTransport.send("SHOT \(width)")
    }

    /// Take control because the PC's Space came forward, rather than because the
    /// pointer crossed an edge.
    ///
    /// Entering at the doorway's own edge rather than the middle, so the
    /// remote pointer lands where it would have if the user had walked there.
    func takeControlForSpace() {
        guard isEnabled, side == .here else { return }
        let doorway = portalBounds ?? macBounds
        handOver(at: CGPoint(x: doorway.maxX - 1, y: doorway.midY), doorway: doorway)
    }

    func releaseControlForSpace() {
        guard isEnabled, side == .there else { return }
        handBack()
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
