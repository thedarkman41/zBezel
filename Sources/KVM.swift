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
    /// Set by disconnect(), cleared by connect(). A reconnect or fallback timer
    /// that was already in flight when we deliberately closed the channel must
    /// NOT fire — otherwise a channel shut on purpose (e.g. handed to secure-kvm
    /// at the sign-in screen) reopens itself a second later and thrashes.
    private var closed = false
    /// The IP the machine announced itself from, tried if the hostname never
    /// resolves. A discovered box whose name the Mac cannot look up is still
    /// reachable at the address its packet arrived on. Nil for a plain host.
    private var lastFallback: String?

    /// The agent subcommand this channel runs.
    private let command: String

    init(command: String) { self.command = command }

    private var process: Process?
    private var input: FileHandle?
    /// The read ends of the child's stdout/stderr, held so `disconnect()` can
    /// disarm their readability handlers and close them. Without this, each
    /// reconnect left the previous handles armed and "readable at EOF", spinning a
    /// core forever and orphaning the pipe fd.
    private var stdoutReader: FileHandle?
    private var stderrReader: FileHandle?
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

    func connect(host: String, exePath: String, fallback: String? = nil) {
        _ = KVMTransport.ignoreSIGPIPE
        lastHost = host
        lastExePath = exePath
        lastFallback = (fallback == host) ? nil : fallback
        disconnect()
        closed = false        // AFTER disconnect() (which sets it): we are opening.
        readyLock.lock(); readyFlag = false; readyLock.unlock()

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            // Accept a first-contact host key on its own. BatchMode cannot answer
            // the usual prompt, so without this a machine the Mac has never SSHed
            // to — a freshly discovered box, or the by-IP fallback whose key is
            // filed under the name, not the address — is refused before it can
            // even try to authenticate. accept-new takes a NEW key silently but
            // still rejects a CHANGED one, so it does not weaken a known host.
            "-o", "StrictHostKeyChecking=accept-new",
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
        scheduleFallbackWatchdog(for: host)

        // Drain both so a full pipe cannot block the far side, and keep the
        // last stderr line as the reason if the channel dies.
        let stdoutReader = stdout.fileHandleForReading
        let stderrReader = stderr.fileHandleForReading
        self.stdoutReader = stdoutReader
        self.stderrReader = stderrReader

        stdoutReader.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF: the ssh child closed stdout. A file handle stays PERMANENTLY
                // readable at EOF, so leaving the handler armed re-invokes it in a
                // tight loop and pins a core; the pipe fd also never frees. Disarm
                // and close this handle. A deliberate disconnect() disarms first,
                // so reaching here means the far side went away on its own — mark
                // the channel dead so the next write reconnects rather than writing
                // into a corpse.
                handle.readabilityHandler = nil
                try? handle.close()
                self.channelEnded()
                return
            }

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
        stderrReader.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // Same EOF spin/leak as stdout — disarm and close. stdout drives the
                // reconnect; stderr just carries the reason, so nothing more to do.
                handle.readabilityHandler = nil
                try? handle.close()
                return
            }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self?.lastError = text }
        }
    }

    /// The channel closed on its own (stdout hit EOF), as opposed to our own
    /// `disconnect()`. Drop the write side and reconnect — the same recovery a
    /// failed `send()` triggers, so a silently dead channel is noticed even when
    /// nothing is being written.
    private func channelEnded() {
        // disconnect() nils these before terminating (and disarms the handler
        // first), so if either is still set the end was unexpected.
        guard process != nil || input != nil else { return }
        KVMLog.write("channel to \(lastHost ?? "?") ended (stdout EOF); reconnecting")
        input = nil
        scheduleReconnect()
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
        let fallback = lastFallback
        KVMLog.write("channel to \(host) died; reconnecting")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.reconnecting = false
            guard !self.closed else { return }   // deliberately shut in the meantime
            self.connect(host: host, exePath: exe, fallback: fallback)
        }
    }

    /// If the hostname never brings the channel up, try the announced IP.
    ///
    /// A working host answers in a second or two; a name that does not resolve
    /// fails in about one; an unreachable one takes the ten-second connect
    /// timeout. Waiting six seconds and then, if the far side still has not said
    /// "ready", switching to the IP covers the "name will not resolve" case the
    /// audit flagged without stealing a slow-but-fine host away from its name. The
    /// IP is authoritative — it is where the packet actually came from — so once
    /// we fall back to it there is nothing further to fall back to.
    private func scheduleFallbackWatchdog(for attemptHost: String) {
        guard let ip = lastFallback else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self,
                  !self.closed,                     // not deliberately shut since
                  self.lastHost == attemptHost,   // not already reconnected elsewhere
                  self.lastFallback == ip,          // fallback still pending
                  !self.isReady                     // and it never came up
            else { return }
            KVMLog.write("channel to \(attemptHost) never became ready; falling back to \(ip)")
            self.connect(host: ip, exePath: self.lastExePath)   // no fallback beyond the IP
        }
    }

    func disconnect() {
        closed = true       // suppress any reconnect/fallback timer already in flight
        // Stop reading FIRST: disarm the handlers and close the read ends before
        // the child exits, so terminating it cannot leave a handle "readable at
        // EOF" spinning a core, and the pipe fds are released rather than orphaned
        // across reconnects. Disarming first also means the EOF that follows does
        // not fire channelEnded() and trigger an unwanted reconnect.
        stdoutReader?.readabilityHandler = nil
        stderrReader?.readabilityHandler = nil
        try? stdoutReader?.close()
        try? stderrReader?.close()
        stdoutReader = nil
        stderrReader = nil

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
    /// The chooser is open and the pointer has moved back off the edge without
    /// picking — slide the drawer shut and hand the desktop back. Wired to the
    /// same teardown as a cancel; the tap below decides when to fire it.
    var dismissChooser: (() -> Void)?
    /// The pointer has crossed home and the panel should return to the Mac. When
    /// set, the controller runs the switch inside a dissolve (fade the machine
    /// out, switch, reveal the Mac) and calls resumeEdge when it is done. Carries
    /// the host being left, so the controller can fade that machine's own curtain.
    /// When nil, handBack switches plainly. See MonitorController.runReturnDissolve.
    var beginReturnDissolve: ((String) -> Void)?

    /// Whether the panel's input can be switched right now — in practice,
    /// whether the app currently has a DDC/CI channel to the monitor. Nil means
    /// assume it can.
    ///
    /// Without a channel a crossing has nowhere to go: the tiles would appear,
    /// a pick would ask for an input switch that cannot happen, and the pointer
    /// would then be captured for a machine that is not on the panel — a frozen
    /// cursor with nothing on screen to say why. So the crossing is refused up
    /// front, and only on the paths that need a switch: a machine the panel is
    /// already showing can still take the pointer, since that needs no DDC.
    var canSwitchPanel: (() -> Bool)?

    /// The IP a machine last announced itself from, or nil. Handed to each SSH
    /// channel as a fallback so a discovered box whose hostname the Mac cannot
    /// resolve is still reached at its address. Supplied by the controller, which
    /// owns discovery; looked up live so a machine that moved keeps working.
    var addressForHost: ((String) -> String?)?
    private var lastRefusalNotice = Date.distantPast

    /// How far in from the doorway edge the chooser's tiles (and a margin) reach.
    /// While the pointer is inside this band the drawer stays; moving left of it
    /// is the "changed my mind, going back to the Mac" gesture that closes it.
    /// The tiles are ~190pt wide against a 22pt margin, so this clears them.
    static let chooserHotZone: CGFloat = 300

    /// True while the chooser is on screen. The pointer stays on the Mac and
    /// events pass through untouched — the user needs it to click a tile — and
    /// the edge is not armed, or it would re-trigger the moment they arrive.
    private(set) var choosing = false
    private var pendingCrossing: (point: CGPoint, doorway: CGRect)?
    /// Set by the chooser so the crossing it resumes does not ask again.
    private var chosenIndex: Int?
    /// Whether the crossing the chooser interrupted was a drag.
    private var pendingWasDrag = false
    /// Held between takeChoice and commitChoice: the pick has been decided but the
    /// pointer has not crossed yet because a dissolve is playing. While this is
    /// set the edge logic stands down entirely, so a pointer drift during those
    /// few hundred milliseconds cannot re-open a crossing or cancel this one.
    private var suspendCrossing = false
    /// Stashed by takeChoice for commitChoice to act on once the dissolve is done.
    private var stashedChoice: (point: CGPoint, doorway: CGRect, index: Int, wasDrag: Bool)?
    /// Set by the outbound dissolve across the handover: the panel is still showing
    /// the Mac (a black curtain) while it renegotiates, so parking the cursor at
    /// the panel's centre now would leave it sitting visibly on the black. While
    /// this is set the handover leaves the cursor where it is; the controller
    /// reparks it to the centre with reparkAtPanelCentre once the panel is on the
    /// PC and the centre is behind it, out of sight.
    var deferCenterPark = false

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

    /// The drags in flight, by stage.
    ///
    /// Not one slot: a large file is still copying long after the user let go
    /// of it, and by then they may be dragging the next one — or dragging a
    /// text selection across, which crosses exactly like a file drag and turns
    /// out to hold no files. Each drag keeps its own two conditions for
    /// delivery (the copy finishing and the user letting go, in either order)
    /// and its own host, and every scp callback names the stage it belongs to.
    /// A callback for a stage that is no longer here is about a drag that was
    /// abandoned, and does nothing.
    private struct PendingDrag {
        /// Where the bytes went — not necessarily the machine under the pointer
        /// by the time they have all landed.
        let host: String
        /// A "D" has gone out for it, so a "D -" must follow if it dies, and
        /// its MARK may go out (MARK must never precede the "D" it refers to).
        var announced = false
        var marked = false
        var copied = false
        var released = false
    }
    private var pending: [String: PendingDrag] = [:]

    /// The drag in hand: crossed over and not yet released. The ghost on the
    /// far machine is following the cursor, and the button-up has to park it.
    private var carriedStage: String?
    private var carrying: Bool { carriedStage != nil }

    /// Keeps every channel warm while the KVM is armed.
    ///
    /// With a lock held the user works on the Mac for minutes at a time and not a
    /// byte crosses the wire. Something in between -- a NAT mapping, most likely
    /// -- drops the idle connection, and the first anyone knows of it is a
    /// crossing where the pointer moves and the far machine does not. A line
    /// every twenty-five seconds costs nothing and removes the whole failure.
    private var heartbeat: Timer?

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
        // A machine at its Windows sign-in screen accepts keystrokes only through
        // the SYSTEM secure-input worker; route there while it is locked, and back
        // to the ordinary channel the instant it signs in. secureLocked is driven
        // by superviseLockState (engageSecure / disengageSecure), all on the main
        // thread — the same thread this getter is read from (the event tap).
        secureLocked.contains(host) ? securePipe(for: host) : pipe(for: host)
    }

    /// Machines the far side reports are at their sign-in screen, so input is
    /// routed through `secure-kvm` instead of `kvm`. Empty is the normal case.
    private var secureLocked: Set<String> = []
    private var secureTransports: [String: KVMTransport] = [:]
    private func securePipe(for machineHost: String) -> KVMTransport {
        if let existing = secureTransports[machineHost] { return existing }
        let fresh = KVMTransport(command: "secure-kvm")
        secureTransports[machineHost] = fresh
        return fresh
    }

    /// The channel to a machine by name. A drag's messages go to the machine
    /// its bytes went to, which by the time the copy finishes need not be the
    /// one the pointer is on.
    private func pipe(for machineHost: String) -> KVMTransport {
        if let existing = transports[machineHost] { return existing }
        let fresh = KVMTransport(command: "kvm")
        transports[machineHost] = fresh
        return fresh
    }
    /// One clipboard channel per machine, so a copy is shared with whichever one
    /// you cross to — not only the machine that happened to be first when the KVM
    /// was armed, which is why copies reached one box and not the other. The Mac's
    /// clipboard fans out to all of them; a copy made on any comes back here.
    /// Reconciled with the chain exactly like the input channels.
    private var clipTransports: [String: KVMTransport] = [:]
    private func clipPipe(for machineHost: String) -> KVMTransport {
        if let existing = clipTransports[machineHost] { return existing }
        let fresh = KVMTransport(command: "clipboard")
        wireClipboard(fresh)
        clipTransports[machineHost] = fresh
        return fresh
    }
    /// A clipboard channel's line handler: a screenshot ("S ") or a clipboard
    /// payload ("C ") arriving FROM that machine, applied to the Mac.
    private func wireClipboard(_ pipe: KVMTransport) {
        pipe.onLine = { [weak self] line in
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
    }
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
        // The Mac's clipboard fans out to every machine's channel, so a copy is
        // already waiting wherever the pointer crosses to.
        clipboard.send = { [weak self] line in
            guard let self else { return }
            for pipe in self.clipTransports.values { pipe.send(line) }
        }
        clipboard.onNotice = { [weak self] note in self?.onNotice?(note) }

        // Open the input and clipboard channels to the whole chain. A crossing
        // should cost a line on an open pipe, not an SSH handshake.
        // reconcileTransports does the work and keeps doing it as the chain
        // changes; enable only has to flip isEnabled first so it will run.
        isEnabled = true
        reconcileTransports()
        // Single-host fallback: a bare proxy with no discovered chain yet.
        if machines.isEmpty {
            let fallback = addressForHost?(host)
            transport.connect(host: host, exePath: exePath, fallback: fallback)
            clipPipe(for: host).connect(host: host, exePath: exePath, fallback: fallback)
        }
        clipboard.start()
        startHeartbeat()
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
        abandonAllDrags(why: "the KVM was disabled")
        clipboard.stop()
        removeTap()
        heartbeat?.invalidate()
        heartbeat = nil
        for pipe in transports.values { pipe.disconnect() }
        for pipe in clipTransports.values { pipe.disconnect() }
        for pipe in secureTransports.values { pipe.disconnect() }
        secureTransports.removeAll()
        secureLocked.removeAll()
        supervising.removeAll()
        secureSetPointerLock = false
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
            KVMLog.write("tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            return nil
        }
        // Our own synthetic events pass straight through, always.
        if event.getIntegerValueField(.eventSourceUserData) == KVMController.selfStamp {
            return Unmanaged.passUnretained(event)
        }
        guard isEnabled else { return Unmanaged.passUnretained(event) }

        if side == .here {
            // A pick has been made and its dissolve is playing; the pointer will
            // cross when commitChoice runs. Until then the edge is inert, so a
            // stray move neither starts a second crossing nor cancels this one.
            if suspendCrossing { return Unmanaged.passUnretained(event) }
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
                    // Whether a button is DOWN is the only trustworthy sign that
                    // this crossing is a drag. The drag pasteboard cannot answer
                    // it: macOS never empties it, so it still holds the last
                    // drag's files days later, and reading it on every crossing
                    // made the same document follow the pointer for ever.
                    let isDrag = (type == .leftMouseDragged
                                  || type == .rightMouseDragged
                                  || type == .otherMouseDragged)
                    handOver(at: where_, doorway: doorway, dragging: isDrag)
                    return nil
                } else if choosing, let crossing = pendingCrossing,
                          where_.x < crossing.doorway.maxX - KVMController.chooserHotZone {
                    // The tiles are out at the edge and the pointer has moved well
                    // left of them without picking one: the user is heading back
                    // to the Mac. Slide the drawer shut and re-arm the edge, using
                    // the doorway the chooser opened for rather than the recomputed
                    // one, which can shift while the question is on screen.
                    dismissChooser?()
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

    private var lastTapProbe = ""

    private func forward(type: CGEventType, event: CGEvent) {
        // While carrying, record what the tap sees against what the hardware
        // says — on change only, so it is a handful of lines per drag, and it
        // is the line that proves (or disproves) how the release arrives.
        if carrying {
            let probe = "tap \(type.rawValue) hid=\(CGEventSource.buttonState(.hidSystemState, button: .left))"
            if probe != lastTapProbe { lastTapProbe = probe; KVMLog.write(probe) }
        }
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
                // The left edge of ANY machine is the boundary with the Mac's
                // primary screen, and the only place the pointer goes from here
                // is home. There used to be a chain here — left edge stepped to
                // the previous machine, right edge advanced to the next — which
                // switched the panel machine-to-machine on nothing more than a
                // push of the mouse. The owner's rule is that the panel never
                // goes Rigel<->Bellatrix except by a person's explicit choice,
                // so the chain is gone: no stepping left, no advancing right.
                handBack()
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
            markDrop()
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

    static let armedStatus = "armed — pointer at the right edge chooses a machine"
    static let noLinkStatus = "armed, but there is no link to the monitor: its input "
                            + "cannot be switched, so the pointer stays here"

    /// A crossing that would need the panel's input switched, at a moment when
    /// it cannot be. Nothing is captured and nothing moves. The pointer is
    /// nudged back off the trigger so the edge does not re-fire on the very next
    /// delta, the reason goes on the status line, and a notice is raised — once
    /// in a while, not on every push at the wall.
    private func refuseCrossing(at point: CGPoint, doorway: CGRect) {
        chosenIndex = nil
        CGWarpMouseCursorPosition(CGPoint(x: doorway.maxX - 40, y: point.y))
        status = Self.noLinkStatus
        KVMLog.write("crossing refused: no DDC/CI channel, the panel's input cannot be switched")
        if Date().timeIntervalSince(lastRefusalNotice) > 30 {
            lastRefusalNotice = Date()
            onNotice?("The panel cannot be switched right now (no DDC/CI link), "
                    + "so the pointer stays on the Mac. zBezel keeps retrying the link.")
        }
        onChange?()
    }

    /// The link came or went while armed. Keep the status line truthful without
    /// waiting for the next crossing to rewrite it — and touch only the armed
    /// texts, never a "controlling …" line that describes a live handover.
    func linkAvailabilityChanged() {
        guard !choosing, status.hasPrefix("armed") else { return }
        let up = canSwitchPanel?() ?? true
        let wanted = up ? Self.armedStatus : Self.noLinkStatus
        guard status != wanted else { return }
        status = wanted
        onChange?()
    }

    private func handOver(at point: CGPoint, doorway: CGRect, dragging: Bool = false) {
        // Whichever machine is already on screen gets the pointer, with no input
        // switch: the user is looking at it, so handing control anywhere else
        // would be a surprise. Only when the panel is showing the Mac is there a
        // choice to make about where to go.
        let onScreen = machines.firstIndex { $0.input == currentInput }
        // Every branch below that is not "the panel already shows it" ends in an
        // input switch, and that needs the DDC channel. Checked here, before
        // anything is captured, for the reason on canSwitchPanel.
        let linkUp = canSwitchPanel?() ?? true
        if let chosen = chosenIndex, machines.indices.contains(chosen) {
            chosenIndex = nil
            let alreadyShowing = !panelShowsMac && machines[chosen].input == currentInput
            guard linkUp || alreadyShowing else { refuseCrossing(at: point, doorway: doorway); return }
            activate(machines[chosen], at: chosen)
        } else if let locked = lockedIndex, machines.indices.contains(locked) {
            // Locked: there is no question to ask. The panel is showing that
            // machine and the pointer goes straight back to it.
            activate(machines[locked], at: locked)
        } else if !panelShowsMac, let onScreen {
            activate(machines[onScreen], at: onScreen)
        } else if !linkUp {
            // The panel shows the Mac and no switch is possible: no tiles, no
            // capture. Offering a choice that cannot be honoured is worse than
            // offering none.
            refuseCrossing(at: point, doorway: doorway)
            return
        } else if !machines.isEmpty, let ask = presentChooser {
            // Always ask when the panel is showing the Mac — even for a single
            // machine. The tiles are the ONLY gesture that switches the panel, so
            // a stray brush of the right edge can never switch inputs on its own.
            // (This once fired only for two or more machines, and a lone machine
            // was switched to directly, which read as an inadvertent switch.)
            // Hold the crossing, nudge the pointer off the edge so it is not
            // sitting on the trigger, and ask.
            pendingCrossing = (point, doorway)
            pendingWasDrag = dragging
            choosing = true
            CGWarpMouseCursorPosition(CGPoint(x: doorway.maxX - 40, y: point.y))
            status = "choose a machine"
            DispatchQueue.main.async { ask(point); self.onChange?() }
            return
        } else if let first = machines.first {
            // No chooser UI wired up (should not happen in the app) — fall back to
            // the single deterministic target rather than trapping the pointer.
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
        //
        // During the outbound dissolve the panel is NOT yet showing the PC — it is
        // still the Mac's black curtain — so parking at the centre now would draw
        // the cursor onto the black. Hold it where it already is; the controller
        // reparks it to the centre once the panel has switched (reparkAtPanelCentre).
        if deferCenterPark {
            parkingSpot = CGEvent(source: nil)?.location ?? point
        } else {
            parkingSpot = portalBounds.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? CGPoint(x: macBounds.maxX - 2, y: macBounds.maxY - 2)
        }
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
        if dragging {
            // Bookkeeping BEFORE the async hop. A release in the runloop turn
            // between the crossing and the block below used to find nothing in
            // hand and was simply lost — the same symptom as the missing-release
            // bug, from a different cause. The release watch starts here too.
            //
            // Only THIS drag is touched. An earlier one still copying keeps its
            // own entry, and if the pasteboard turns out to be empty only this
            // one is stood down.
            if let stale = carriedStage {
                abandonDrag(stale, why: "a new drag crossed before it was released")
            }
            let stage = "zb" + String(UInt64(Date().timeIntervalSince1970 * 1000))
            carriedStage = stage
            pending[stage] = PendingDrag(host: target)
            startReleaseWatch()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let files = DragTransfer.draggedFiles()
                guard !files.isEmpty else {
                    // Nothing on the pasteboard after all — a text selection, a
                    // tab, an image off a web page. Stand this one down, or its
                    // entry stays armed and the far side shows a ghost for nothing.
                    self.abandonDrag(stage, why: "the drag pasteboard was empty")
                    return
                }
                // Released and brought home in the turn between the crossing
                // and here: nothing to carry any more.
                guard self.pending[stage] != nil else { return }
                KVMLog.write("drag \(stage) carried \(files.count) file(s) to \(target)")
                // Show what is being carried, so the drag looks like a drag over
                // there too. It follows the cursor on that machine's own timer.
                let label = files.count == 1
                    ? files[0].lastPathComponent
                    : "\(files.count) items"
                // End the Mac's drag NOW, before anything else can finish it.
                //
                // It used to be cancelled when the user released on the far machine,
                // which left a live Finder drag for the whole crossing. If the
                // Escape did not land, the mouse up completed the drop wherever the
                // Mac's pointer had been parked — and the file was MOVED into
                // whatever folder it had last passed over. The pasteboard has already
                // been read by this point, so the drag has served its purpose.
                self.cancelMacDrag()

                // The far side draws the progress bar from these two numbers alone:
                // bytes landed in the staging folder against the total. Nothing has
                // to be reported back across the wire while the copy runs.
                let total = files.reduce(0) { sum, url in
                    sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
                // Send the real icon before the ghost appears, so the far side has
                // something to draw with on its first paint rather than showing a
                // hand-drawn page and swapping it a moment later.
                //
                // This is the icon Finder itself shows — a thumbnail for an image, a
                // document icon for a Pages file, the app's own icon for an app — so
                // the ghost looks like what was picked up rather than a generic sheet
                // that happens to mean "a file".
                let pipe = self.pipe(for: target)
                if let icon = Self.dragIconPNG(for: files) {
                    pipe.send("DI \(icon.base64EncodedString())")
                }
                pipe.send("D \(stage) \(total) \(label)")
                self.pending[stage]?.announced = true
                // The release may already have happened; its MARK waited for this.
                self.sendMarkIfDue(stage)
                DragTransfer.send(files, to: target, stage: stage,
                                  total: { [weak self] bytes in
                                      // A folder's size is unknown at the crossing
                                      // (fileSize is nil for a directory), so the
                                      // first "D" may carry 0; this corrects it.
                                      Task { @MainActor in
                                          self?.sizeKnown(stage, bytes: bytes, label: label)
                                      }
                                  },
                                  progress: { [weak self] line in
                                      Task { @MainActor in
                                          self?.status = line
                                          self?.onChange?()
                                      }
                                  },
                                  done: { [weak self] ok, line in
                                      Task { @MainActor in
                                          self?.copyFinished(stage, ok: ok, line: line)
                                      }
                                  })
            }
        } else if let stale = carriedStage {
            // Left over from a previous crossing that never saw its button up.
            abandonDrag(stale, why: "a plain crossing arrived with a drag still in hand")
        }

        // The channel to this machine has to be live to carry anything at all.
        // reconcileTransports normally has it open well before now, but this is
        // the backstop for a machine that appeared a heartbeat ago, or a channel
        // that just died: reopen it on arrival rather than swallow input into a
        // dead pipe. The connect is quick and the first events may not land, but
        // control recovers within the second rather than staying dead.
        if !transport.isConnected {
            KVMLog.write("arrive: channel to \(host) was down; reopening")
            pipe(for: host).connect(host: host, exePath: exePath, fallback: addressForHost?(host))
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
        let name = machines.first(where: { $0.host == host })?.name ?? host
        status = "controlling \(name) — its left edge brings you back"
        onChange?()
        // Watch this machine's sign-in state for as long as we control it, so the
        // keyboard routes through the secure worker the instant it locks — on
        // arrival OR later, if you press Win+L while on it — and hands back the
        // instant it signs in.
        superviseLockState(host)
    }

    /// The machine's short name, or its host when it is a bare proxy.
    private func nameFor(_ machineHost: String) -> String {
        machines.first(where: { $0.host == machineHost })?.name ?? machineHost
    }

    /// One supervisor per machine, so pressing Win+L while controlling it is
    /// caught, not just a lock found on arrival.
    private var supervising: Set<String> = []

    /// Watch a machine's lock state and reconcile the secure routing on every
    /// change: engage when it locks (route the keyboard to `secure-kvm`, wake the
    /// sign-in, pin the pointer), disengage when it signs in. Runs while we control
    /// the machine, and keeps running while it is still in secure mode after the
    /// pointer leaves, so a cross-away mid-sign-in still hands back. ~2 s cadence.
    private func superviseLockState(_ machineHost: String) {
        guard !supervising.contains(machineHost) else { return }
        supervising.insert(machineHost)
        Task { @MainActor [weak self] in
            while let self,
                  (self.side == .there && self.host == machineHost) || self.secureLocked.contains(machineHost) {
                let st = await SecureDesktop.status(host: machineHost)
                let locked = st?.locked ?? false
                if locked && !self.secureLocked.contains(machineHost) {
                    self.engageSecure(machineHost)
                } else if !locked && self.secureLocked.contains(machineHost) {
                    self.disengageSecure(machineHost)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self?.supervising.remove(machineHost)
        }
    }

    /// Did we engage the pointer-lock for a sign-in, so we release only ours.
    private var secureSetPointerLock = false

    /// Enter secure mode: route the keyboard to the secure worker, wake the
    /// sign-in, and pin the pointer to the machine so entering the password cannot
    /// stray off the edge.
    private func engageSecure(_ machineHost: String) {
        secureLocked.insert(machineHost)
        // Hush the ordinary channels first. At the Windows secure desktop the
        // session-1 `kvm` and `clipboard` workers are refused, so their pipes hit
        // stdout EOF and reconnect every ~30s — pointless thrash against a box
        // that can only be typed at through the SYSTEM secure-input worker. Drop
        // them; the secure channel below carries the keyboard until sign-in, and
        // reconcileTransports leaves a secure-locked host's ordinary channels shut.
        pipe(for: machineHost).disconnect()
        clipPipe(for: machineHost).disconnect()
        securePipe(for: machineHost).connect(host: machineHost,
            exePath: exePath, fallback: addressForHost?(machineHost))
        Task { await SecureDesktop.wake(host: machineHost) }
        if lockedIndex == nil, let idx = machines.firstIndex(where: { $0.host == machineHost }) {
            // Point the single-remote machinery at this machine BEFORE locking —
            // above all its remoteSize. lockTo does not activate, and the secure
            // desktop is often reached without a prior edge-crossing, so without
            // this remoteSize stays at the 1920x1080 default. On a 3840x2160 panel
            // that confines the pointer to the top-left quarter, leaving the
            // sign-in field (below the midline) unreachable. Mirrors followManualInput.
            if machineIndex != idx { activate(machines[idx], at: idx) }
            lockTo(machineIndex: idx, why: "locked at the sign-in screen")
            secureSetPointerLock = true
        }
        KVMLog.write("\(machineHost) is locked; routing keyboard to secure-kvm")
        status = "\(nameFor(machineHost)) is locked — type your password to sign in"
        onChange?()
    }

    /// Leave secure mode for a machine: drop the secure channel, release the
    /// pointer-lock if we set it, and make the ordinary channel live again.
    private func disengageSecure(_ machineHost: String) {
        secureLocked.remove(machineHost)
        secureTransports[machineHost]?.disconnect()
        secureTransports[machineHost] = nil
        if secureSetPointerLock, lockedIndex == machines.firstIndex(where: { $0.host == machineHost }) {
            clearLock()
            secureSetPointerLock = false
        }
        let fallback = addressForHost?(machineHost)
        pipe(for: machineHost).connect(host: machineHost, exePath: exePath,
                                       fallback: fallback)
        clipPipe(for: machineHost).connect(host: machineHost, exePath: exePath,
                                           fallback: fallback)
        KVMLog.write("\(machineHost) signed in; keyboard back on the ordinary channel")
        if side == .there, host == machineHost {
            status = "controlling \(nameFor(machineHost)) — its left edge brings you back"
            onChange?()
        }
    }

    /// The user picked a machine from the chooser.
    func chooseMachine(at index: Int) {
        guard choosing, let crossing = pendingCrossing else { return }
        // Cleared on EVERY exit path from here. The chooser window is already
        // gone by the time this runs, so cancelChoice() can never be reached;
        // returning early with `choosing` still true left the right edge dead
        // until the KVM was toggled off and on, with nothing on screen to say why.
        choosing = false
        pendingCrossing = nil
        guard machines.indices.contains(index) else {
            KVMLog.write("chooser picked machine \(index), which this chain does not have — crossing dropped")
            status = "armed — pointer at the right edge chooses a machine"
            onChange?()
            return   // deliberately not re-run: the pointer sits 40 px from the trigger, one push re-asks
        }
        chosenIndex = index
        handOver(at: crossing.point, doorway: crossing.doorway, dragging: pendingWasDrag)
    }

    /// chooseMachine split in two, so a dissolve can play between deciding on a
    /// machine and the pointer actually crossing to it.
    ///
    /// This half settles the decision at once: it clears the choosing state (so
    /// the edge cannot re-ask or the crossing be cancelled while the animation
    /// runs) and suspends the edge logic until commitChoice. It stashes what the
    /// crossing needs. Returns false, having stood the crossing down, when the
    /// index is not one this chain has — the caller then plays no animation.
    @discardableResult
    func takeChoice(at index: Int) -> Bool {
        guard choosing, let crossing = pendingCrossing else { return false }
        choosing = false
        pendingCrossing = nil
        guard machines.indices.contains(index) else {
            KVMLog.write("chooser picked machine \(index), which this chain does not have — crossing dropped")
            status = "armed — pointer at the right edge chooses a machine"
            stashedChoice = nil
            onChange?()
            return false
        }
        stashedChoice = (crossing.point, crossing.doorway, index, pendingWasDrag)
        suspendCrossing = true
        return true
    }

    /// The second half: the dissolve has covered the switch, so carry the pointer
    /// across and move the panel, exactly as chooseMachine's tail would.
    func commitChoice() {
        suspendCrossing = false
        guard let choice = stashedChoice else { return }
        stashedChoice = nil
        chosenIndex = choice.index
        handOver(at: choice.point, doorway: choice.doorway, dragging: choice.wasDrag)
    }

    /// Re-arm the edge after a return dissolve. handBack suspends it so a stray
    /// move cannot start a crossing while the panel is coming home; the controller
    /// calls this once the Mac has been revealed.
    func resumeEdge() { suspendCrossing = false }

    /// Park the held cursor at the panel's centre now that the panel is showing
    /// the PC, so it is hidden behind that input. The outbound dissolve calls this
    /// after the switch, having set deferCenterPark so the handover left the cursor
    /// alone until the centre was safe to hide it in. A no-op if control has since
    /// gone home.
    func reparkAtPanelCentre() {
        guard side == .there else { return }
        parkingSpot = portalBounds.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: macBounds.maxX - 2, y: macBounds.maxY - 2)
        CGWarpMouseCursorPosition(parkingSpot)
    }

    /// Drive the black fade curtain on a machine's own screen — the machine's
    /// half of an input-switch dissolve. While a machine is on the panel nothing
    /// the Mac draws is visible, so the machine fades itself, over its own
    /// channel, exactly as it draws the lock badge. opaquePercent 0...100; ms 0
    /// arms it at once (for a machine not yet on screen, where there is nothing to
    /// animate). A no-op if that machine's channel is not open.
    func fadeMachine(host: String, toOpaque opaquePercent: Int, overMs ms: Int) {
        pipe(for: host).send("F \(opaquePercent) \(ms)")
    }

    // MARK: Release

    /// The physical release, whichever way it arrives.
    ///
    /// Where the pointer was when released is what decides the destination, so
    /// the agent must resolve it NOW even if the copy is still running. It
    /// remembers the spot; deliverIfReady sends the command once the bytes have
    /// landed. Idempotent: the tap's .leftMouseUp and the release watch can both
    /// call it, and whichever is second must do nothing.
    private func markDrop() {
        guard let stage = carriedStage else { return }
        carriedStage = nil
        stopReleaseWatch()
        pending[stage]?.released = true
        KVMLog.write("drop marked on \(host) for \(stage)")
        sendMarkIfDue(stage)
    }

    /// MARK names its stage and must follow that stage's "D" — the agent parks
    /// the ghost the MARK is about, and there is no ghost before the "D". The
    /// release can beat the pasteboard read that sends the "D", so the MARK
    /// goes out from whichever of the two happens second.
    private func sendMarkIfDue(_ stage: String) {
        guard let drag = pending[stage], drag.released, drag.announced, !drag.marked else { return }
        pending[stage]?.marked = true
        pipe(for: drag.host).send("MARK \(stage)")
        deliverIfReady(stage)
    }

    /// scp has walked a folder and knows its true size.
    private func sizeKnown(_ stage: String, bytes: Int, label: String) {
        // Abandoned while the tree was being walked: a late "D" here would
        // put a ghost back that nothing will ever clear.
        guard let drag = pending[stage] else { return }
        pipe(for: drag.host).send("D \(stage) \(bytes) \(label)")
    }

    /// scp has finished, one way or the other.
    private func copyFinished(_ stage: String, ok: Bool, line: String) {
        guard pending[stage] != nil else {
            KVMLog.write("drag copy for \(stage), already abandoned: \(line)")
            return
        }
        status = line
        onChange?()
        KVMLog.write("drag copy \(stage): \(line)")
        if ok {
            pending[stage]?.copied = true
            deliverIfReady(stage)
        } else {
            // Nothing will land, so nothing will ever send DROP — without
            // this the ghost sat at its bar forever.
            abandonDrag(stage, why: line)
        }
    }

    /// The tap does not see the release of a drag that crossed over — the
    /// app's own log shows every "drop marked" preceded by a fresh press, so the
    /// drop needed a second click. Motion after the crossing still arrives as
    /// leftMouseDragged, which means the hardware button state is intact; so
    /// while carrying, watch that state at 60 Hz and treat the first "up" as the
    /// release. Armed only after it has first read "down": if it never does,
    /// the state is not to be trusted and the behaviour is exactly today's
    /// rather than a MARK at the arrival point.
    private var releaseWatch: Timer?
    private var releaseArmed = false
    private var releaseWatchStarted = Date()

    private func startReleaseWatch() {
        stopReleaseWatch()
        releaseArmed = false
        releaseWatchStarted = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.releaseTick() }
        }
        // .common is required: the main runloop sits in event-tracking mode
        // during a drag, the same reason the tap source uses .commonModes.
        RunLoop.main.add(timer, forMode: .common)
        releaseWatch = timer
    }

    private func stopReleaseWatch() {
        releaseWatch?.invalidate()
        releaseWatch = nil
    }

    private func releaseTick() {
        guard carrying else { stopReleaseWatch(); return }
        let down = CGEventSource.buttonState(.hidSystemState, button: .left)
        if !releaseArmed {
            if down {
                releaseArmed = true
            } else if Date().timeIntervalSince(releaseWatchStarted) > 0.5 {
                KVMLog.write("release watch never armed — hardware already reports the button up; falling back to the tap")
                stopReleaseWatch()
            }
            return
        }
        if !down {
            KVMLog.write("release seen by the watch")
            markDrop()
        }
    }

    /// Stand one drag down: nothing will land, so nothing must wait. The scp
    /// filling its folder is stopped, and the far side told to forget it.
    private func abandonDrag(_ stage: String, why: String) {
        if carriedStage == stage {
            carriedStage = nil
            stopReleaseWatch()
        }
        guard let drag = pending.removeValue(forKey: stage) else { return }
        DragTransfer.cancel(stage: stage)
        if drag.announced { pipe(for: drag.host).send("D - \(stage)") }
        KVMLog.write("drag \(stage) abandoned: \(why)")
    }

    /// Every drag, when the KVM itself goes away.
    private func abandonAllDrags(why: String) {
        for stage in Array(pending.keys) { abandonDrag(stage, why: why) }
    }

    /// Deliver only when the copy has finished AND the user has let go.
    ///
    /// Either order is possible: a small file lands long before the release, a
    /// large one long after. Delivering on the release alone moved an empty
    /// folder and left the file to be swept up by the NEXT drop.
    private func deliverIfReady(_ stage: String) {
        guard let drag = pending[stage], drag.released, drag.copied, drag.marked else { return }
        pending[stage] = nil
        pipe(for: drag.host).send("DROP \(stage)")
        KVMLog.write("delivering \(stage) on \(drag.host)")
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                // Every machine, not just the one in use: the point is that the
                // channel to a machine you have NOT visited for ten minutes is
                // still there when you finally cross to it.
                for pipe in self.transports.values { pipe.send("P") }
                for pipe in self.clipTransports.values { pipe.send("P") }
            }
        }
    }

    /// End the drag still running on the Mac.
    ///
    /// The pointer left in the middle of a gesture, so Finder never saw a mouse
    /// up and still believes it is dragging — come back and the icon is still
    /// stuck to the cursor. Escape first, which CANCELS the drag rather than
    /// completing it: a plain mouse up would drop the file wherever the Mac's
    /// pointer happens to be parked, which is not somewhere the user chose.
    private func cancelMacDrag() {
        // Park the pointer somewhere a drop can do no harm FIRST. The top-left of
        // the main display is the menu bar, which refuses every drop — so even if
        // the cancel below fails and the gesture completes, it completes onto
        // nothing. Belt and braces, because the failure here moves the user's
        // file somewhere they did not choose.
        let safe = CGPoint(x: mainBounds.minX + 4, y: mainBounds.minY + 4)
        CGWarpMouseCursorPosition(safe)

        // Posted at the SESSION tap, not the HID tap. Measured on 2026-09-01:
        // posted at .cghidEventTap, the synthetic up flipped the system's
        // left-button state to "up" 144 ms after the crossing while the finger
        // was still down (kvm.log: "tap 6 hid=true" then "tap 6 hid=false").
        // From then on the physical release was an up->up non-transition and
        // generated no event at all, so the drop needed a second click, and no
        // poll of the hardware state could rescue it because the state itself
        // was wrong. Finder tracks its drag from the session stream, so an up
        // inserted there still ends the drag; the HID layer never sees it and
        // keeps reading "down" until the real release, which then arrives as a
        // genuine .leftMouseUp. The events are still stamped, so our own tap
        // passes them through without acting on them.
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            if let key = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) {
                key.setIntegerValueField(.eventSourceUserData, value: KVMController.selfStamp)
                key.post(tap: .cgSessionEventTap)
            }
        }
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                            mouseCursorPosition: safe, mouseButton: .left) {
            up.setIntegerValueField(.eventSourceUserData, value: KVMController.selfStamp)
            up.post(tap: .cgSessionEventTap)
        }

        // Back to the parking spot. The corner was needed for the instant of the
        // release and no longer: left there, the pointer sits clamped against the
        // edge of the display, and with the cursor disassociated a leftward push
        // yields no horizontal delta at all — the far machine's pointer pins to
        // its left edge and only moves up and down.
        CGWarpMouseCursorPosition(parkingSpot)
        KVMLog.write("cancelled the Mac's drag at the crossing")
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
        // Never machine-to-machine on the pointer's say-so. A person may do it
        // from zBezel's menu or the monitor's buttons; those paths do not come
        // through here. Everything that does is pointer-driven, and for that the
        // only legal moves are Mac -> machine and machine -> Mac.
        if input != macInput, currentInput != macInput, input != currentInput {
            KVMLog.write("REFUSED switch 0x\(String(currentInput, radix: 16)) -> "
                       + "0x\(String(input, radix: 16)) (\(reason)): machine-to-machine is never automatic")
            return
        }
        KVMLog.write("switching panel to 0x\(String(input, radix: 16)) — \(reason)")
        setMonitorInput?(input)
    }

    /// Take the pointer to a machine and hold it there, exactly as clicking the
    /// badge does — but without a pointer having crossed to ask.
    ///
    /// This exists for the input watcher: switching the panel to a machine by
    /// hand is as clear a statement of intent as clicking the lock, so it should
    /// mean the same thing. Doing it through one method keeps the two paths from
    /// drifting, which matters because the lock is not one flag — it also parks
    /// the badge and tells the far side, and a second implementation would
    /// forget one of those.
    ///
    /// Returns false when the index is not a machine we know, so a caller acting
    /// on a monitor reading cannot silently lock to nothing.
    @discardableResult
    func lockTo(machineIndex index: Int, why: String) -> Bool {
        guard machines.indices.contains(index) else { return false }
        guard lockedIndex != index else { return true }   // already there

        lockedIndex = index
        parkBadge()
        badgeVisible = true
        transport.send("L 1 \(Int(badgeOrigin.x)) \(Int(badgeOrigin.y))")
        KVMLog.write("lock engaged on \(machines[index].host): \(why)")
        status = "controlling \(machines[index].host) — locked: the panel stays here"
        onChange?()
        return true
    }

    /// The icon Finder shows for what is being dragged, as a PNG.
    ///
    /// Taken from NSWorkspace rather than drawn, so it is genuinely the same
    /// artwork: a thumbnail for an image, the document icon for a Pages file,
    /// an application's own icon. Dragging several sends the first one — macOS
    /// stacks them with a count badge, which is more than the far side draws.
    ///
    /// 256 px because the ghost is 170 wide and Retina rendering can ask for
    /// twice that; larger only makes the message bigger for no visible gain.
    private static func dragIconPNG(for files: [URL]) -> Data? {
        guard let first = files.first else { return nil }

        let icon = NSWorkspace.shared.icon(forFile: first.path)
        let side = 256
        icon.size = NSSize(width: side, height: side)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }

        // Draw into a bitmap of our own rather than asking the NSImage for a
        // representation: an icon carries several sizes, and the one it hands
        // back is not reliably the one that was asked for.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// A person chose an input from zBezel itself — the menu-bar icon, its
    /// pulldown, or the Input tab. That is the same statement of intent as
    /// switching on the monitor's buttons and it means the same thing: pin the
    /// panel there and hold the pointer to that machine, badge parked in the
    /// corner. Choosing the Mac's own input is the one way to let go.
    ///
    /// Re-aims the single-remote machinery first, because the badge message
    /// goes down the pipe of whichever machine is current, and the one just
    /// chosen may not be.
    func followManualInput(_ input: UInt16) {
        if input == macInput { clearLock(); return }
        guard let index = machines.firstIndex(where: { $0.input == input }) else {
            clearLock()   // an input with nobody behind it: nothing to hold
            return
        }
        if machineIndex != index { activate(machines[index], at: index) }
        currentInput = input
        panelShowsMac = false
        lockTo(machineIndex: index, why: "input chosen in zBezel")
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
        suspendCrossing = false
        stashedChoice = nil
        guard choosing else { return }
        choosing = false
        pendingCrossing = nil
        status = "armed — pointer at the right edge chooses a machine"
        onChange?()
    }

    /// Replace the machine chain while the KVM is live, because discovery saw a
    /// machine appear or drop. Safe mid-session: if the pointer is currently on a
    /// machine that has just left the network, it is brought home first so it is
    /// not stranded controlling something that no longer exists. The doorway is
    /// the panel's edge and does not move with the chain, so nothing else shifts.
    /// True while the pointer is on this machine right now. The input watcher
    /// consults it to tell the KVM's own crossing apart from a by-hand monitor
    /// switch: the panel sitting on the input of the machine you are actively
    /// controlling is not a change to follow, and locking to it would pin the
    /// panel and stop the pointer ever returning to the Mac.
    func isControlling(host candidate: String) -> Bool {
        isEnabled && side == .there && host == candidate
    }

    func updateChain(_ new: [Machine]) {
        machines = new
        reconcileTransports()
        guard isEnabled, side == .there else { onChange?(); return }
        if let index = new.firstIndex(where: { $0.host == host }) {
            machineIndex = index                 // same machine, possibly a new slot
        } else {
            KVMLog.write("controlled machine \(host) left the network; bringing the pointer home")
            handBack()
        }
        onChange?()
    }

    /// Bring the open input channels into line with the machine set: open one to a
    /// machine that has none, and close the ones to machines that have left.
    ///
    /// This is what lets control survive the chain changing under it. The old code
    /// opened a channel to every machine ONCE, in enable(), so a machine that
    /// appeared later — through discovery — was controlled through a channel that
    /// was never connected, and its input went nowhere. Just as important, a
    /// machine whose agent restarts drops out of discovery and comes back; because
    /// leaving closes its channel here, returning opens a FRESH one instead of
    /// reusing the dead pipe the old agent left behind. Keyed by host, so the
    /// stale upper/lower-case duplicates from earlier arming also get swept.
    private func reconcileTransports() {
        guard isEnabled else { return }
        let wanted = Set(machines.map(\.host))
        for machine in machines {
            // A machine locked at its sign-in screen takes input only through the
            // secure-kvm channel; its ordinary input + clipboard channels are
            // refused at the secure desktop and would thrash (connect, EOF,
            // reconnect). engageSecure shut them — leave them shut until it signs
            // in, when disengageSecure brings them back.
            if secureLocked.contains(machine.host) { continue }
            let fallback = addressForHost?(machine.host)
            let pipe = transports[machine.host] ?? KVMTransport(command: "kvm")
            transports[machine.host] = pipe
            if !pipe.isConnected {
                KVMLog.write("reconcile: opening input channel to \(machine.host)")
                pipe.connect(host: machine.host, exePath: exePath, fallback: fallback)
            }
            // The clipboard channel gets the same treatment, so a copy reaches
            // every machine, not only the one armed first.
            let clip = clipPipe(for: machine.host)
            if !clip.isConnected {
                KVMLog.write("reconcile: opening clipboard channel to \(machine.host)")
                clip.connect(host: machine.host, exePath: exePath, fallback: fallback)
            }
        }
        for (host, pipe) in transports where !wanted.contains(host) {
            KVMLog.write("reconcile: closing input channel to \(host) — left the chain")
            pipe.disconnect()
            transports[host] = nil
        }
        for (host, pipe) in clipTransports where !wanted.contains(host) {
            pipe.disconnect()
            clipTransports[host] = nil
        }
    }

    private func handBack() {
        if let stage = carriedStage {
            abandonDrag(stage, why: "the pointer came home before the file was released")
        }
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
        // Adopt the Mac as the live input NOW, before the async switch and the
        // input poll catch up. The panel is on its way home; leaving the tracked
        // input reading the machine we just left means a quick cross-back-and-
        // forth is judged against that machine — the doorway stays at the built-in
        // edge and the crossing sees the panel "already on" the machine, so it
        // jumps straight back with no chooser. The poll confirms or corrects this
        // within its interval either way.
        currentInput = macInput
        panelShowsMac = true
        KVMLog.write("crossed BACK to \(Int(landing.maxX - 2)),\(Int(y))")
        // The return gets the same dissolve as a pick, run by the controller: it
        // fades the machine out, switches, and reveals the Mac. Hold the edge
        // until it is done (resumeEdge, from the controller) so a stray move does
        // not start a fresh crossing while the panel is mid-dissolve.
        //
        // BUT NOT WHILE LOCKED. A lock pins the panel to this machine; the panel
        // must not move. switchPanel refuses the write while locked — the panel
        // stays, the pointer still comes home — exactly as this did before the
        // dissolve. The dissolve writes 0x60 directly and would bypass that
        // refusal, moving the panel to the Mac while the lock still points here;
        // the next crossing then recaptured a machine no longer on screen and the
        // pointer froze. So the dissolve runs only for an unlocked return.
        if lockedIndex == nil, let begin = beginReturnDissolve {
            suspendCrossing = true
            begin(host)
        } else {
            switchPanel(to: macInput, why: "returned to the Mac")
        }
        status = "armed — the panel's right edge crosses to \(host)"
        onChange?()
    }

    /// A picture of the far desktop arrived.
    var onScreenshot: ((Data) -> Void)?

    /// Ask for one. Rides the clipboard channel, so it cannot delay pointer
    /// events however large it turns out to be.
    func requestScreenshot(width: Int = 1280) {
        guard isEnabled else { return }
        clipPipe(for: host).send("SHOT \(width)")
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
