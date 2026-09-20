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

