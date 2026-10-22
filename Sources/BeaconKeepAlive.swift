//
//  BeaconKeepAlive.swift — advertise zBezel to Beacon, and let it keep us alive.
//
//  Beacon (Beacon/INTEGRATION.md) is the owner's menu-bar service directory: it
//  lists what is running on this Mac and, when the owner checks Keep Alive for a
//  row, puts the app back if it disappears. Keep Alive is a per-user LaunchAgent
//  launchd supervises — started at login, RESTARTED ON A CRASH — plus a Beacon
//  startup pass that revives the kept-alive set after a reboot.
//
//  zBezel wants that. It is a menu-bar utility with no window of its own, so a
//  silent quit or crash leaves nothing on screen and nothing brought it back —
//  which is how it stayed down after the disappearance on 2026-10-20. This file
//  is the missing enrolment. §1 of INTEGRATION.md.
//
//  Three things live here, all best-effort:
//
//    LIVENESS    a tiny loopback TCP listener on a fixed port (below). Beacon
//                answers "is this app up?" by looking for a TCP LISTEN socket on
//                the port we report (PortProcess.listeningPorts via lsof), and
//                drives its right-click Quit/Restart off the same port. zBezel
//                otherwise listens on nothing — its discovery socket is UDP,
//                which lsof's TCP scan can't see — so without this, Beacon would
//                think zBezel is never running and bootstrap a DUPLICATE on every
//                Keep-Alive tick and startup pass. The listener also IS the
//                single-instance guard: a second zBezel fails to bind and exits.
//
//    HEARTBEAT   a 30s loopback POST of {name, port, version, frameworkVersion,
//                relaunch}, first beat immediate. Beacon greys the row ~90s after
//                the beats stop.
//
//    KEEP ALIVE  the `relaunch` field: a self-detaching command Beacon runs to
//                bring zBezel back, offered only when Beacon is unlocked, this
//                command is present, AND our frameworkVersion equals Beacon's
//                current one (the "zBezel.beaconfw" resource build-app.sh writes).
//
//  EVERYTHING HERE IS BEST-EFFORT. Beacon runs only on the owner's Mac and may
//  not be running at all. Nothing in this file may block launch, fail a request,
//  or change behaviour when the loopback POST goes nowhere — except the one
//  deliberate exit on a port collision, which means another zBezel owns the slot.
//  Modeled on CCPortalMonitor's BeaconClient.
//

import Foundation
import Darwin

final class BeaconKeepAlive {

    static let shared = BeaconKeepAlive()
    private init() {}

    private var heartbeatTimer: DispatchSourceTimer?
    private var livenessSource: DispatchSourceRead?
    private var stopping = false

    private static let heartbeatURL = URL(string: "http://127.0.0.1:1099/api/heartbeat")!
    private static let removeURL    = URL(string: "http://127.0.0.1:1099/api/remove")!
    private static let heartbeatInterval: TimeInterval = 30

    /// The name of our Beacon row and the /api/remove instance key. The same
    /// name zBezel registers under the secret broker (BeaconSecrets.register)
    /// and the `codesign --identifier` the build stamps — one identity throughout.
    private static let appName = "zBezel"

    /// The fixed loopback TCP port zBezel listens on purely so Beacon has a
    /// truthful liveness surface (see LIVENESS above). 48223 sits one above the
    /// UDP discovery port (KVMDiscovery.port = 48222) as a mnemonic, is unused by
    /// the rest of the fleet, and is below the OS ephemeral range (49152+) so the
    /// kernel never hands it out from under us. Nothing meaningful is served on
    /// it; Beacon only checks that something is LISTENing there.
    private static let port: UInt16 = 48223

    /// zBezel's own release version, shown in Beacon's version column. Stamped
    /// into the bundle by build-app.sh from the repo's VERSION file.
    private static let appVersion: String =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""

    /// The Beacon FRAMEWORK version this build was signed against, read from the
    /// "zBezel.beaconfw" resource build-app.sh writes from Beacon's
    /// BeaconVersion.swift (the single source of truth) at sign time.
    ///
    /// It is a sidecar rather than a code-signing entitlement because AMFI
    /// SIGKILLs a binary that carries a custom entitlement. It GATES Keep Alive:
    /// Beacon greys the checkbox unless this equals Beacon's current framework
    /// version (EntryRow compares the value we broadcast here), so a build that
    /// skipped the sidecar — empty below, field then omitted — simply cannot
    /// switch the feature on.
    ///
    /// In a bundled .app the sidecar is a sealed RESOURCE: codesign refuses a
    /// plain file beside the executable in Contents/MacOS (it treats it as
    /// unsigned nested code), so it lives in Contents/Resources. The
    /// executable-path read is the fallback for a bare `swiftc` dev run with no
    /// bundle.
    private static let frameworkVersion: String = {
        if let url = Bundle.main.url(forResource: "zBezel", withExtension: "beaconfw"),
           let raw = try? String(contentsOf: url, encoding: .utf8) {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        if !exe.isEmpty,
           let raw = try? String(contentsOfFile: exe + ".beaconfw", encoding: .utf8) {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }()

    /// The command Beacon runs to bring zBezel back.
    ///
    /// It points at the INNER BINARY (Contents/MacOS/zBezel), NOT `open` of the
    /// bundle, so that:
    ///   • launchd can SUPERVISE it. Beacon's Keep-Alive LaunchAgent strips the
    ///     `nohup`/trailing `&` (LaunchAgentManager.foregroundCommand) and runs
    ///     the bare binary in the foreground under launchd; an `open` would exit
    ///     0 instantly and launchd (KeepAlive:SuccessfulExit:false) would never
    ///     respawn after a crash. The `nohup … &` form is still correct for
    ///     Beacon's OWN (non-launchd) relaunch path, which does not hold it open.
    ///   • Local Network access survives. Launching the inner binary keeps
    ///     Bundle.main resolved to the .app, so with NSLocalNetworkUsageDescription
    ///     in Info.plist (build-app.sh) macOS grants LAN once and remembers it —
    ///     a bundle-less launchd process is silently denied (memory note
    ///     launchd-bare-binary-loses-local-network; the Fuser precedent).
    ///
    /// Built from the running executable so a moved install self-corrects; empty
    /// — so Keep Alive stays greyed — when not run from an .app (a dev bare run).
    private static let relaunchCommand: String = {
        guard let exe = Bundle.main.executablePath, !exe.isEmpty,
              Bundle.main.bundlePath.hasSuffix(".app") else { return "" }
        // Single-quoted: the install path has no spaces on this layout, never a quote.
        return "nohup '\(exe)' >/dev/null 2>&1 &"
    }()

    // MARK: - Lifecycle

    /// Bring up the liveness listener, then begin heartbeating. Call once, early
    /// in launch. If another zBezel already holds the liveness port this exits
    /// the process cleanly (we are the duplicate); any other bind failure just
    /// skips Beacon entirely — the app runs normally, it is simply not advertised.
    func start() {
        switch bindLivenessSocket() {
        case .bound:
            startHeartbeat()
        case .inUse:
            // Another instance owns the slot. Exit 0 so launchd's
            // {SuccessfulExit:false} does not treat us as a crash and respawn;
            // the incumbent keeps the Beacon entry and the KVM session.
            NSLog("zBezel: liveness port %d already held — another instance is running; exiting.", Int(Self.port))
            exit(0)
        case .failed:
            // Loopback bind failed for some reason other than a collision
            // (vanishingly rare). Don't report a port we aren't actually
            // listening on — skip Keep Alive rather than lie to Beacon's sweep.
            NSLog("zBezel: could not bind liveness port %d; skipping Beacon advertise.", Int(Self.port))
        }
    }

    /// Stop advertising and tell Beacon we meant to go.
    ///
    /// This is the KEEP-ALIVE opt-out signal: /api/remove blanks our relaunch
    /// command and removes the LaunchAgent, so neither Beacon nor launchd
    /// resurrects an app that quit on purpose. Beacon remembers the checkbox and
    /// restores it when we gracefully return; during a machine restart it reads
    /// the same call as "everyone is quitting" and leaves Keep Alive intact —
    /// that distinction is Beacon's, so this is called on EVERY clean exit.
    ///
    /// `stopping` is set first so an in-flight timer beat on the utility queue
    /// won't re-POST a heartbeat AFTER the remove and resurrect the entry.
    /// Synchronous with a short timeout, deliberately: the process is about to
    /// exit and a fire-and-forget POST would never leave the machine.
    func stop() {
        stopping = true
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        livenessSource?.cancel()   // cancel handler closes the socket fd
        livenessSource = nil
        guard let body = try? JSONSerialization.data(
                withJSONObject: ["name": Self.appName, "port": Int(Self.port)]) else { return }
        var request = URLRequest(url: Self.removeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 2
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 2.5)
    }

    // MARK: - Liveness listener

    private enum BindResult { case bound, inUse, failed }

    /// Bind 127.0.0.1:<port> and LISTEN. Sets SO_REUSEADDR but NOT SO_REUSEPORT:
    /// SO_REUSEADDR lets a quick relaunch rebind over a lingering TIME_WAIT (the
    /// accept-and-close below leaves one on every inbound connection, e.g.
    /// Beacon's /api/resolve HTTP+TCP probe, for ~30s) WITHOUT weakening the
    /// single-instance guard — a bind still fails EADDRINUSE while a LIVE socket
    /// holds the addr:port; only SO_REUSEPORT would permit two live binds, so we
    /// omit it. Accepts and immediately drops connections: Beacon's liveness is
    /// an lsof LISTEN check so nothing actually dials us, but draining keeps the
    /// backlog clean if anything ever probes.
    private func bindLivenessSocket() -> BindResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback only
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            let err = errno
            close(fd)
            return err == EADDRINUSE ? .inUse : .failed
        }
        guard listen(fd, 8) == 0 else { close(fd); return .failed }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        src.setEventHandler {
            let c = accept(fd, nil, nil)
            if c >= 0 { close(c) }
        }
        src.setCancelHandler { close(fd) }
        livenessSource = src
        src.resume()
        return .bound
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        // `.now()` makes the first beat fire right away, so the entry exists
        // almost immediately; the periodic beats are fire-and-forget. §1.
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in self?.beat() }
        heartbeatTimer?.cancel()
        heartbeatTimer = timer
        timer.resume()
    }

    private func beat() {
        guard !stopping else { return }
        var payload: [String: Any] = [
            "name": Self.appName,
            "port": Int(Self.port),
        ]
        if !Self.appVersion.isEmpty       { payload["version"] = Self.appVersion }
        if !Self.frameworkVersion.isEmpty { payload["frameworkVersion"] = Self.frameworkVersion }
        if !Self.relaunchCommand.isEmpty  { payload["relaunch"] = Self.relaunchCommand }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var request = URLRequest(url: Self.heartbeatURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request).resume()
    }
}
