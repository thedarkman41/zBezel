import Foundation

/// Fetches secrets from Beacon's broker over its Unix-domain socket.
///
/// zBezel needs one kind of secret: the Windows password for the RDP connection
/// that creates a session on a keyboardless machine, so `BezelAgent reclaim`
/// has something to move onto the console. That password must not sit in a
/// plist or a source file, and asking for it every time defeats the point of a
/// one-button recovery.
///
/// The broker authorizes purely by the caller's verified code-signing
/// identifier, read off the socket from the process's audit token. That is why
/// build-app.sh signs with a STABLE identifier rather than a linker ad-hoc id:
/// an ad-hoc id embeds LC_UUID and changes every build, so every build would be
/// a different caller and the enrollment would stop matching.
///
/// Modelled on Clarinet's BeaconClient. The protocol is one request per
/// connection, read to EOF; the first line is status, the rest is the value
/// verbatim. See Beacon/INTEGRATION.md §3 and §6.
enum BeaconSecrets {

    /// Why there is no value, kept distinct because the remedies differ:
    /// locked means unlock Beacon, notfound means enroll it, unavailable
    /// means Beacon is not running at all.
    enum Status: Equatable {
        case ok
        case locked
        case timeout
        case notFound
        case denied
        case unavailable
        case other(String)

        var explanation: String {
            switch self {
            case .ok:          return "ok"
            case .locked:      return "Beacon is locked — unlock it to release the credential."
            case .timeout:     return "Waited for Beacon to be unlocked and it was not."
            case .notFound:    return "No secret enrolled under that name. Enroll it with Beacon's store-secret.sh."
            case .denied:      return "Beacon does not recognize this build as the secret's owner. Is the app signed with its stable identifier?"
            case .unavailable: return "Beacon is not running."
            case .other(let s): return s
            }
        }
    }

    /// Beacon runs only on the owner's Mac. Build the path from the home
    /// directory — never a hardcoded username.
    private static var socketPath: String {
        NSHomeDirectory() + "/Library/Application Support/Beacon/secrets.sock"
    }

    /// The name zBezel enrolls its secrets under. One per host, so several
    /// machines can each have their own password.
    static func secretName(forHost host: String) -> String {
        "zBezel-rdp-" + host.lowercased()
    }

    /// Fetch a secret.
    ///
    /// `wait` holds the connection through a locked stretch until the owner
    /// unlocks. Send it bare: the timeout is Beacon's own configured setting,
    /// and carrying our own number here would fight it. `prompt` additionally
    /// asks Beacon to raise its unlock UI, which is what you want when a person
    /// just clicked something and is watching.
    static func secret(named name: String,
                       wait: Bool = false,
                       prompt: Bool = false) -> (value: String?, status: Status) {
        var request = name
        if wait   { request += " wait" }
        if prompt { request += " prompt=1" }
        request += "\n"

        // A held connection can legitimately last as long as Beacon's unlock
        // window (capped at 120s), so the receive timeout is only a safety net
        // and must be well clear of it. Without `wait`, replies are immediate.
        guard let reply = roundTrip(request: request, recvTimeout: wait ? 900 : 5) else {
            return (nil, .unavailable)
        }

        guard reply.status == "OK" else {
            let word = reply.status.hasPrefix("ERR ")
                ? String(reply.status.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                : reply.status
            switch word {
            case "locked":   return (nil, .locked)
            case "timeout":  return (nil, .timeout)
            case "notfound": return (nil, .notFound)
            case "denied":   return (nil, .denied)
            default:         return (nil, .other(word.isEmpty ? "no reply" : word))
            }
        }
        return (reply.body, .ok)
    }

    /// Register this app's identity so Beacon can show its Trust button.
    /// Idempotent; call it at startup. A secret fetch works without it, since
    /// authorization is by signing identifier rather than by trust.
    ///
    /// The result goes to a file as well as the log. This is the one call whose
    /// failure is otherwise invisible — the app carries on perfectly happily
    /// while store-secret.sh keeps insisting the app has never registered, and
    /// there is nothing on screen to say why.
    @discardableResult
    static func register(as name: String = "zBezel") -> String {
        let reply = roundTrip(request: "register \(name)\n", recvTimeout: 5)
        let status = reply?.status ?? "unavailable (Beacon not running, or the socket refused us)"
        note("register \(name) -> \(status)")
        return status
    }

    /// Appends to ~/Library/Logs/zBezel-beacon.log.
    static func note(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(stamp)  \(line)\n"
        NSLog("zBezel beacon: %@", line)

        let dir = NSHomeDirectory() + "/Library/Logs"
        let path = dir + "/zBezel-beacon.log"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// Ask whether the padlock is open without attempting a real fetch. Useful
    /// for deciding up front whether to send `wait prompt=1`, and for showing
    /// an honest reason in the UI before anything is attempted.
    static func isLocked() -> Bool? {
        guard let url = URL(string: "http://127.0.0.1:1099/api/lockstate") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        var locked: Bool?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            locked = json["locked"] as? Bool
        }.resume()
        _ = done.wait(timeout: .now() + 3)
        return locked
    }

    // MARK: - Socket

    private struct Reply {
        let status: String
        let body: String
    }

    /// One request, one connection, read to EOF — the broker's whole protocol.
    private static func roundTrip(request: String, recvTimeout: TimeInterval) -> Reply? {
        let path = socketPath
        guard path.utf8.count < 104 else { return nil }   // sun_path is 104 bytes

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var receive = timeval(tv_sec: Int(recvTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))
        var send = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { p in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, p) }
            }
        }

        // A failed connect means Beacon is not running. That is not an error
        // worth waiting on — report unavailable immediately.
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var sent = 0
        let bytes = Array(request.utf8)
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return nil }
            sent += n
        }

        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }

        guard let newline = out.firstIndex(of: 0x0A) else {
            guard !out.isEmpty else { return nil }
            return Reply(status: String(decoding: out, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                         body: "")
        }
        return Reply(
            status: String(decoding: out[..<newline], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces),
            body: String(decoding: out[out.index(after: newline)...], as: UTF8.self))
    }
}
