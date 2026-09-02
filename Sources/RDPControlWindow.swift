import AppKit

/// The "Control" path: a real RDP session with pixels, in a window you can
/// click and type into. It exists for the one thing the screen-scrape View
/// cannot do — see and answer the secure desktop (a UAC prompt, the sign-in
/// screen) — because Windows renders that into the RDP session while forbidding
/// a local process from capturing it. The cost is that connecting redirects the
/// machine's session to here, so its physical monitor drops to the lock screen
/// until you disconnect. For a box you cannot otherwise reach, that is the whole
/// point.
@MainActor
final class RDPControl {
    static let shared = RDPControl()
    private var windows: [String: RDPControlWindow] = [:]

    /// A Control session for this host has connected: the machine's interactive
    /// session now lives in that window, so its physical panel is dark and the
    /// agent behind it can no longer see a real display.
    var onSessionStarted: ((String) -> Void)?

    /// That session has ended and the console reclaim has finished. The outcome
    /// is nil when the session never connected — nothing was redirected, so
    /// nothing was put back.
    var onSessionEnded: ((String, ConsoleReclaim.Outcome?) -> Void)?

    /// A Control session for this host is LIVE — which is not the same as "a
    /// window for it exists". A window that has ended its session stays on
    /// screen showing the reclaim's verdict, and callers use this to decide
    /// whether somebody is in that session right now. Reporting a finished
    /// window as in use left the console stranded for as long as it stayed
    /// open: a dropped session whose one automatic reclaim failed could never
    /// be retried, because every later attempt was refused on the grounds that
    /// a person was using a session that had been dead for hours.
    ///
    /// Hosts reach us from several stores with inconsistent case, so the window
    /// table is keyed lowercased and compared that way.
    func isOpen(host: String) -> Bool {
        windows[host.lowercased()].map { !$0.sessionEnded } ?? false
    }

    func open(host: String, name: String, size: CGSize) {
        let key = host.lowercased()
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = RDPControlWindow(host: host, name: name, remoteSize: size)
        windows[key] = window
        window.onClosed = { [weak self] in self?.windows[key] = nil }
        window.onConnected = { [weak self] in self?.onSessionStarted?(host) }
        window.onEnded = { [weak self] outcome in self?.onSessionEnded?(host, outcome) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.begin()
    }
}

final class RDPControlWindow: NSWindow, NSWindowDelegate {
    private let host: String
    private let machineName: String
    private let rdp = RDPSession()
    private let view: RDPView
    private let status = NSTextField(labelWithString: "")
    private var connected = false
    /// Readable from RDPControl, which needs to tell a live session apart from a
    /// window still on screen after its session finished.
    private(set) var sessionEnded = false
    var onClosed: (() -> Void)?
    /// Fired once, when the session reaches `.connected`.
    var onConnected: (() -> Void)?
    /// Fired once, after the session has ended and the console reclaim has run.
    /// Nil outcome means the session never connected, so nothing was reclaimed.
    var onEnded: ((ConsoleReclaim.Outcome?) -> Void)?

    // Request a moderate session size regardless of the panel's native 4K:
    // lighter to decode, and plenty to read a dialog. 16:9.
    private let sessionWidth = 1920
    private let sessionHeight = 1080

    init(host: String, name: String, remoteSize: CGSize) {
        self.host = host
        self.machineName = name
        let aspect = CGFloat(sessionWidth) / CGFloat(sessionHeight)
        let w: CGFloat = 1200
        let frame = NSRect(x: 0, y: 0, width: w, height: (w / aspect).rounded())
        view = RDPView(frame: frame, session: rdp,
                       remoteSize: CGSize(width: sessionWidth, height: sessionHeight))

        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "\(name) — Control"
        isReleasedWhenClosed = false
        contentAspectRatio = NSSize(width: aspect, height: 1)
        minSize = NSSize(width: 640, height: (640 / aspect).rounded())
        backgroundColor = NSColor(white: 0.06, alpha: 1)
        center()
        setFrameAutosaveName("rdp-\(host)")
        delegate = self

        let content = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)

        status.font = NSFont.systemFont(ofSize: 13)
        status.textColor = NSColor(white: 0.8, alpha: 1)
        status.alignment = .center
        status.frame = NSRect(x: 0, y: frame.midY - 12, width: frame.width, height: 24)
        status.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        content.addSubview(status)
        contentView = content

        makeToolbar()

        rdp.onState = { [weak self] state, detail in self?.handleState(state, detail) }
        rdp.onFrame = { [weak self] rect in self?.view.markRemoteDirty(rect) }
    }

    // MARK: Toolbar — the keystrokes you cannot type

    private func makeToolbar() {
        let bar = NSToolbar(identifier: "rdpControls")
        bar.displayMode = .iconAndLabel
        bar.delegate = self
        toolbar = bar
    }

    @objc private func sendCAD() {
        // Ctrl+Alt+Del: the one sequence the secure desktop is waiting for, and
        // the one you cannot send as a keystroke because the OS intercepts it.
        rdp.key(scancode: 0x1D, extended: false, down: true)   // Ctrl
        rdp.key(scancode: 0x38, extended: false, down: true)   // Alt
        rdp.key(scancode: 0x53, extended: true,  down: true)   // Del
        rdp.key(scancode: 0x53, extended: true,  down: false)
        rdp.key(scancode: 0x38, extended: false, down: false)
        rdp.key(scancode: 0x1D, extended: false, down: false)
    }

    // MARK: Lifecycle

    func begin() {
        show("Fetching the credential from Beacon…")
        let host = self.host, name = self.machineName
        let w = sessionWidth, h = sessionHeight
        let rdp = self.rdp     // a local, so the background work never reaches through self
        // GCD rather than a detached Task, to match RemoteDesktop.swift: the
        // blocking Beacon fetch and connect run off the main actor and hop back
        // for every UI touch.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // 1 — the password, from Beacon (may raise its unlock UI and wait).
            let secretName = BeaconSecrets.secretName(forHost: host)
            let locked = BeaconSecrets.isLocked()
            let (password, secretStatus) = BeaconSecrets.secret(named: secretName, wait: true, prompt: locked ?? true)
            guard let password, !password.isEmpty else {
                DispatchQueue.main.async { self?.fail("No credential: \(secretStatus.explanation)") }
                return
            }
            // 2 — user + domain, shared with Wake Console's per-host store.
            let (user, domain) = Self.account(for: host)
            guard !user.isEmpty else {
                DispatchQueue.main.async {
                    self?.fail("No account set for \(host). Set the user in Wake Console first "
                               + "(the Link tab), then reconnect.")
                }
                return
            }
            DispatchQueue.main.async { self?.show("Connecting to \(name) over RDP…") }

            // 3 — the session. Blocks until up or failed.
            let pinnedKey = "rdpFingerprints"
            let pinned = (UserDefaults.standard.dictionary(forKey: pinnedKey) as? [String: String])?[host.lowercased()]
            var seen = [CChar](repeating: 0, count: 256)
            let err = rdp.open(host: host, port: 3389, user: user, domain: domain.isEmpty ? nil : domain,
                               password: password, pinnedFingerprint: pinned,
                               width: w, height: h, fingerprintOut: &seen, fingerprintOutLen: 256)
            let fingerprint = String(cString: seen)
            DispatchQueue.main.async {
                guard let self else { return }
                if let err, !err.isEmpty {
                    if err == "HOST_KEY_MISMATCH" {
                        self.fail("The host key for \(host) changed. Clear the pin only if you know why.")
                    } else {
                        self.fail("RDP did not connect: \(err)")
                    }
                    return
                }
                if pinned == nil, !fingerprint.isEmpty {
                    var all = UserDefaults.standard.dictionary(forKey: pinnedKey) as? [String: String] ?? [:]
                    all[host.lowercased()] = fingerprint
                    UserDefaults.standard.set(all, forKey: pinnedKey)
                }
                // connected — onState(.connected) will clear the status line.
            }
        }
    }

    nonisolated private static func account(for host: String) -> (user: String, domain: String) {
        let all = UserDefaults.standard.dictionary(forKey: "wakeAccounts") as? [String: [String: String]] ?? [:]
        if let a = all[host.lowercased()] { return (a["user"] ?? "", a["domain"] ?? "") }
        // Fall back to the pre-per-host single account, which was the proxy's.
        return (UserDefaults.standard.string(forKey: "wakeUser") ?? "",
                UserDefaults.standard.string(forKey: "wakeDomain") ?? "")
    }

    private func handleState(_ state: RDPSession.State, _ detail: String?) {
        switch state {
        case .connecting: show("Connecting…")
        case .connected:
            let first = !connected
            connected = true
            status.isHidden = true
            view.sessionReady()
            makeFirstResponder(view)
            if first { onConnected?() }
        case .resized:
            view.needsDisplay = true
        case .disconnected:
            endSession()
        case .error:
            if connected {
                // Connected and then dropped: whatever the transport called it,
                // the thing that matters now is that the console is stranded.
                NSLog("zBezel rdp control (%@): %@", host, detail ?? "the session ended unexpectedly")
                endSession()
            } else {
                fail(detail ?? "The session ended unexpectedly.")
                endSession()
            }
        }
    }

    /// The session is over — because the window closed, or because the far side
    /// dropped it. Runs at most once per window.
    ///
    /// Connecting redirected the machine's interactive session into this window;
    /// disconnecting leaves it `Disconnected` while an empty console session
    /// owns the physical monitor, and the agent in that stranded session sees no
    /// displays. So put it back, the same way Wake Console does. `rdp.close()`
    /// joins the FreeRDP thread, so by the time it returns the far side has seen
    /// the disconnect and the session is settled: reclaiming before that would
    /// race the state Windows is still leaving.
    private func endSession() {
        guard !sessionEnded else { return }
        sessionEnded = true
        rdp.close()

        guard connected else {
            // Nothing was ever redirected, so there is nothing to put back.
            let finished = onEnded
            onEnded = nil
            finished?(nil)
            return
        }

        show("Disconnected. Putting \(machineName)'s console back on its monitor…")
        let host = self.host
        // A strong capture on purpose: closing the window is the ordinary way a
        // session ends, so by the time the verdict lands nothing else may be
        // holding this window — and the callback still has to be delivered.
        Task {
            let outcome = await ConsoleReclaim.reclaim(host: host)
            self.finish(outcome)
        }
    }

    /// The reclaim's verdict, said plainly. The window is usually closed by now.
    private func finish(_ outcome: ConsoleReclaim.Outcome) {
        if isVisible {
            switch outcome {
            case .moved, .alreadyActive:
                show("\(machineName)'s console is back on its own monitor.")
            default:
                show("Could not put \(machineName)'s console back: \(Self.reason(outcome)). "
                     + "Run Wake Console or sign in there.")
            }
        }
        let finished = onEnded
        onEnded = nil
        finished?(outcome)
    }

    /// One short clause naming why the console is still stranded.
    private static func reason(_ outcome: ConsoleReclaim.Outcome) -> String {
        switch outcome {
        case .moved, .alreadyActive: return ""
        case .notMoved(let why):     return why
        case .noTask:                return "BezelReclaimConsole is not installed there"
        case .noVerdict:             return "the reclaim task reported nothing"
        case .unreachable(let output):
            let first = output.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return first.isEmpty ? "SSH could not reach it" : "SSH: \(first)"
        }
    }

    private func show(_ text: String) { status.stringValue = text; status.isHidden = false }
    private func fail(_ why: String) { show(why); NSLog("zBezel rdp control (%@): %@", host, why) }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        endSession()
        onClosed?()
    }
}

extension RDPControlWindow: NSToolbarDelegate {
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == .cad else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Ctrl+Alt+Del"
        item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Ctrl+Alt+Del")
        item.target = self
        item.action = #selector(sendCAD)
        return item
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.cad] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.cad] }
}

private extension NSToolbarItem.Identifier {
    static let cad = NSToolbarItem.Identifier("cad")
}

// MARK: - The view

/// Draws the session's framebuffer and turns Mac mouse and keyboard into RDP
/// input. Fills its bounds (the window keeps the session's aspect ratio, so
/// there is no letterbox to map around).
final class RDPView: NSView {
    private let session: RDPSession
    private let remoteSize: CGSize
    private var ready = false
    private var lastFlags = NSEvent.ModifierFlags()

    init(frame: NSRect, session: RDPSession, remoteSize: CGSize) {
        self.session = session
        self.remoteSize = remoteSize
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func sessionReady() { ready = true; needsDisplay = true }

    /// A remote-pixel rect changed; invalidate the matching view rect.
    func markRemoteDirty(_ remoteRect: CGRect) {
        guard ready, remoteSize.width > 0, remoteSize.height > 0 else { return }
        let sx = bounds.width / remoteSize.width
        let sy = bounds.height / remoteSize.height
        // Remote is top-left origin; the view is bottom-left. Flip Y.
        let vy = bounds.height - (remoteRect.maxY * sy)
        let r = CGRect(x: remoteRect.minX * sx, y: vy,
                       width: remoteRect.width * sx, height: remoteRect.height * sy)
        setNeedsDisplay(r.insetBy(dx: -1, dy: -1))
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard ready, let image = session.makeImage(),
              let ctx = NSGraphicsContext.current?.cgContext else {
            NSColor(white: 0.06, alpha: 1).setFill(); dirtyRect.fill(); return
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Coordinate mapping

    private func remotePoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let rx = Int((p.x / bounds.width) * remoteSize.width)
        // Flip Y: view bottom-left, remote top-left.
        let ry = Int(((bounds.height - p.y) / bounds.height) * remoteSize.height)
        return (rx, ry)
    }

    // MARK: Mouse

    private static let MOVE: UInt16 = 0x0800, DOWN: UInt16 = 0x8000
    private static let B1: UInt16 = 0x1000, B2: UInt16 = 0x2000, B3: UInt16 = 0x4000

    override func mouseMoved(with e: NSEvent)     { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }
    override func mouseDragged(with e: NSEvent)   { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }
    override func rightMouseDragged(with e: NSEvent) { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }
    override func otherMouseDragged(with e: NSEvent) { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }

    override func mouseDown(with e: NSEvent)  { window?.makeFirstResponder(self); button(e, Self.B1, down: true) }
    override func mouseUp(with e: NSEvent)    { button(e, Self.B1, down: false) }
    override func rightMouseDown(with e: NSEvent) { button(e, Self.B2, down: true) }
    override func rightMouseUp(with e: NSEvent)   { button(e, Self.B2, down: false) }
    override func otherMouseDown(with e: NSEvent) { button(e, Self.B3, down: true) }
    override func otherMouseUp(with e: NSEvent)   { button(e, Self.B3, down: false) }

    private func button(_ e: NSEvent, _ b: UInt16, down: Bool) {
        let (x, y) = remotePoint(e)
        session.mouse(x: x, y: y, flags: down ? (Self.DOWN | b) : b)
    }

    override func scrollWheel(with e: NSEvent) {
        let notches = Int(e.scrollingDeltaY.rounded())
        if notches != 0 { session.wheel(notches: notches > 0 ? 1 : -1) }
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent)  { sendKey(e, down: true) }
    override func keyUp(with e: NSEvent)    { sendKey(e, down: false) }

    private func sendKey(_ e: NSEvent, down: Bool) {
        if let (code, ext) = RDPKeymap.map[e.keyCode] {
            session.key(scancode: code, extended: ext, down: down)
        } else if let chars = e.charactersIgnoringModifiers, let u = chars.unicodeScalars.first, u.value <= 0xFFFF {
            // Anything the table does not carry goes as its character.
            session.unicode(UInt16(u.value), down: down)
        }
    }

    override func flagsChanged(with e: NSEvent) {
        let now = e.modifierFlags
        toggle(.shift,   now, 0x2A, extended: false)
        toggle(.control, now, 0x1D, extended: false)
        toggle(.option,  now, 0x38, extended: false)
        toggle(.command, now, 0x5B, extended: true)   // Cmd → Windows key
        lastFlags = now
    }

    private func toggle(_ mask: NSEvent.ModifierFlags, _ now: NSEvent.ModifierFlags,
                        _ scancode: UInt8, extended: Bool) {
        let was = lastFlags.contains(mask), is_ = now.contains(mask)
        if was != is_ { session.key(scancode: scancode, extended: extended, down: is_) }
    }
}

/// Mac virtual key codes to RDP (scan-code set 1). Letters and digits, the
/// punctuation, the nav cluster, and the function keys — enough to type a
/// password and drive a dialog. The extended flag marks the E0-prefixed keys.
enum RDPKeymap {
    static let map: [UInt16: (UInt8, Bool)] = [
        0x00: (0x1E, false), 0x0B: (0x30, false), 0x08: (0x2E, false), 0x02: (0x20, false), // A B C D
        0x0E: (0x12, false), 0x03: (0x21, false), 0x05: (0x22, false), 0x04: (0x23, false), // E F G H
        0x22: (0x17, false), 0x26: (0x24, false), 0x28: (0x25, false), 0x25: (0x26, false), // I J K L
        0x2E: (0x32, false), 0x2D: (0x31, false), 0x1F: (0x18, false), 0x23: (0x19, false), // M N O P
        0x0C: (0x10, false), 0x0F: (0x13, false), 0x01: (0x1F, false), 0x11: (0x14, false), // Q R S T
        0x20: (0x16, false), 0x09: (0x2F, false), 0x0D: (0x11, false), 0x07: (0x2D, false), // U V W X
        0x10: (0x15, false), 0x06: (0x2C, false),                                           // Y Z
        0x12: (0x02, false), 0x13: (0x03, false), 0x14: (0x04, false), 0x15: (0x05, false), // 1 2 3 4
        0x17: (0x06, false), 0x16: (0x07, false), 0x1A: (0x08, false), 0x1C: (0x09, false), // 5 6 7 8
        0x19: (0x0A, false), 0x1D: (0x0B, false),                                           // 9 0
        0x24: (0x1C, false), 0x30: (0x0F, false), 0x31: (0x39, false), 0x33: (0x0E, false), // Return Tab Space Backspace
        0x35: (0x01, false),                                                                // Escape
        0x1B: (0x0C, false), 0x18: (0x0D, false), 0x21: (0x1A, false), 0x1E: (0x1B, false), // - = [ ]
        0x2A: (0x2B, false), 0x29: (0x27, false), 0x27: (0x28, false), 0x32: (0x29, false), // \ ; ' `
        0x2B: (0x33, false), 0x2F: (0x34, false), 0x2C: (0x35, false),                      // , . /
        0x7B: (0x4B, true),  0x7C: (0x4D, true),  0x7D: (0x50, true),  0x7E: (0x48, true),  // arrows L R Down Up
        0x73: (0x47, true),  0x77: (0x4F, true),  0x74: (0x49, true),  0x79: (0x51, true),  // Home End PgUp PgDn
        0x75: (0x53, true),  0x72: (0x52, true),                                            // FwdDelete Insert
        0x7A: (0x3B, false), 0x78: (0x3C, false), 0x63: (0x3D, false), 0x76: (0x3E, false), // F1-F4
        0x60: (0x3F, false), 0x61: (0x40, false), 0x62: (0x41, false), 0x64: (0x42, false), // F5-F8
        0x65: (0x43, false), 0x6D: (0x44, false), 0x67: (0x57, false), 0x6F: (0x58, false), // F9-F12
    ]
}
