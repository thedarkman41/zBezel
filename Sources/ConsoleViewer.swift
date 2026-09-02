import AppKit
import WebKit

/// A window on another machine's console, live.
///
/// The agent in that machine's interactive session serves MJPEG on its own
/// loopback (`stream`); nothing on the network can reach it. This opens an SSH
/// tunnel to it — the same key that opens the KVM channel — and shows the page
/// in a web view, which renders a multipart image stream natively. Closing the
/// window drops the tunnel; the agent stops capturing the moment nobody is
/// watching and stops listening after ten idle minutes, so nothing is left
/// running on the far side.
///
/// View-only, on purpose: driving the machine is the KVM's job, and a picture
/// that reacted to clicks would be a second, worse KVM.
///
/// The transport is deliberately the dumbest thing that works. When capture
/// moves to DXGI and the stream to hardware H.264, this window keeps its job
/// and only what it shows changes.
@MainActor
final class ConsoleViewer {
    static let shared = ConsoleViewer()

    private var windows: [String: ViewerWindow] = [:]

    /// One window per machine. Asking again brings the existing one forward.
    func open(host: String, name: String, size: CGSize) {
        if let existing = windows[host] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = ViewerWindow(host: host, name: name, remoteSize: size)
        windows[host] = window
        window.onClosed = { [weak self] in self?.windows[host] = nil }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.begin()
    }

    // MARK: - Plumbing, off the main actor

    /// The agent's stream port on the far machine. Fixed: it is loopback there,
    /// and the tunnel's local end is what varies.
    static let remotePort = 8765

    nonisolated static func run(_ path: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    continuation.resume(returning: (-1, error.localizedDescription)); return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus,
                                                String(decoding: data, as: UTF8.self)
                                                    .trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    /// A local port nothing is using, found the only reliable way: by binding
    /// port 0 and asking what was handed out.
    nonisolated static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Is anything listening on 127.0.0.1:port? ssh binds the tunnel's local
    /// end only once the session is up, so this is how "the tunnel is ready"
    /// is known rather than assumed. A refused connect returns at once.
    nonisolated static func portOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }
}

/// The window itself: a web view on the tunnel, a status line while there is
/// nothing to show yet, and the tunnel process it owns.
private final class ViewerWindow: NSWindow, NSWindowDelegate, WKNavigationDelegate {
    private let host: String
    private let machineName: String
    private var tunnel: Process?
    private let web: WKWebView
    private let status = NSTextField(labelWithString: "")
    var onClosed: (() -> Void)?

    init(host: String, name: String, remoteSize: CGSize) {
        self.host = host
        self.machineName = name

        let aspect = (remoteSize.width > 1 && remoteSize.height > 1)
            ? remoteSize.width / remoteSize.height : 16.0 / 9.0
        let width: CGFloat = 1280
        let frame = NSRect(x: 0, y: 0, width: width, height: (width / aspect).rounded())

        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        web = WKWebView(frame: frame, configuration: configuration)

        super.init(contentRect: frame,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = "\(name) console"
        isReleasedWhenClosed = false
        // The picture keeps the machine's shape as the window is resized;
        // the page inside letterboxes anything left over.
        contentAspectRatio = NSSize(width: aspect, height: 1)
        minSize = NSSize(width: 480, height: (480 / aspect).rounded())
        backgroundColor = NSColor(white: 0.07, alpha: 1)
        center()
        setFrameAutosaveName("console-\(host)")
        delegate = self

        let content = NSView(frame: frame)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        content.addSubview(web)

        status.font = NSFont.systemFont(ofSize: 13)
        status.textColor = NSColor(white: 0.75, alpha: 1)
        status.alignment = .center
        status.frame = NSRect(x: 0, y: frame.midY - 12, width: frame.width, height: 24)
        status.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        content.addSubview(status)

        contentView = content
    }

    // MARK: Lifecycle

    func begin() {
        show("Starting the stream on \(machineName)…")
        let host = self.host
        let remote = ConsoleViewer.remotePort
        Task.detached { [weak self] in
            // 1 — tell the agent to serve. Idempotent: an answer of "already"
            // means someone else is watching too, which is fine.
            let started = await ConsoleViewer.run(
                "/usr/bin/ssh",
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
                 "& \"$HOME\\bezel\\BezelAgent.exe\" client stream start \(remote) 5 1600 65"])
            guard started.output.contains("\"ok\":true") else {
                await self?.fail("Could not start the stream on \(host): "
                                 + (started.output.isEmpty ? "no answer" : started.output))
                return
            }

            // 2 — a tunnel of our own, on a port nothing else is using.
            guard let local = ConsoleViewer.freePort() else {
                await self?.fail("No free local port for the tunnel.")
                return
            }
            let tunnel = Process()
            tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            tunnel.arguments = ["-N",
                                "-o", "BatchMode=yes",
                                "-o", "ExitOnForwardFailure=yes",
                                "-o", "ServerAliveInterval=30",
                                "-o", "ConnectTimeout=10",
                                "-L", "\(local):127.0.0.1:\(remote)",
                                host]
            tunnel.standardOutput = FileHandle.nullDevice
            tunnel.standardError = FileHandle.nullDevice
            do { try tunnel.run() } catch {
                await self?.fail("Could not open the tunnel: \(error.localizedDescription)")
                return
            }
            await self?.adopt(tunnel)

            // 3 — wait for the local end to exist, then show the page.
            var up = false
            for _ in 0..<40 {
                if ConsoleViewer.portOpen(local) { up = true; break }
                if !tunnel.isRunning { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard up else {
                await self?.fail("The tunnel to \(host) did not come up.")
                return
            }
            await self?.load(URL(string: "http://127.0.0.1:\(local)/")!)
        }
    }

    private func show(_ text: String) {
        status.stringValue = text
        status.isHidden = false
    }

    private func fail(_ why: String) {
        show(why)
        NSLog("zBezel console viewer (%@): %@", host, why)
    }

    private func adopt(_ process: Process) {
        tunnel = process
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tunnel === process else { return }
                self.tunnel = nil
                self.show("The tunnel to \(self.host) closed.")
            }
        }
    }

    private func load(_ url: URL) {
        show("Connecting…")
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15))
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("The stream page did not load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("The stream page did not load: \(error.localizedDescription)")
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Drop the tunnel; the agent notices the viewer go and stops capturing.
        // The listener over there stops itself after ten idle minutes.
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
        if let tunnel, tunnel.isRunning { tunnel.terminate() }
        tunnel = nil
        onClosed?()
    }
}
