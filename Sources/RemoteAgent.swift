import CoreGraphics
import Foundation

/// Drives a monitor that this Mac cannot reach over DDC/CI, by asking a machine
/// that can.
///
/// The HP dock's DP branch chip refuses DDC/CI, so the panel is unreachable from
/// here. A Windows box with the same monitor on USB-C has an unobstructed AUX
/// channel and the Win32 Monitor Configuration API, which handles arbitrary VCP
/// codes — including HP's manufacturer-specific ones. BezelAgent exposes that
/// over SSH.
///
/// Commands go down ONE held-open SSH channel. Spawning a process per call cost
/// about 0.65s of PowerShell login shell and .NET startup before any DDC work
/// happened at all; the same command on an open channel measures 0.079s. Reads
/// are still batched where it is natural to, but that is no longer what stands
/// between a click and the panel moving.
struct RemoteAgentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RemoteMonitor: Identifiable, Hashable {
    let index: Int
    let description: String
    let device: String
    let deviceID: String
    var id: Int { index }

    /// EDID-ish identity Windows embeds in the device path, e.g. HPN36D3.
    var pnpID: String? {
        guard let range = deviceID.range(of: #"DISPLAY#([A-Z]{3}[0-9A-Fa-f]{4})"#,
                                         options: .regularExpression) else { return nil }
        return String(deviceID[range]).replacingOccurrences(of: "DISPLAY#", with: "")
    }
}

struct RemoteReading {
    let code: UInt8
    let current: UInt16
    let maximum: UInt16
    let type: UInt8
}

/// The Windows session the agent answered from.
///
/// Which session the agent lives in decides what it can see. Off the console it
/// has no display to enumerate at all, so `list` comes back empty and the host
/// looks broken when it is merely parked; inside a live remote-desktop session
/// it enumerates that connection's VIRTUAL display, so DDC writes succeed
/// without ever reaching the panel — the worse failure of the two, because it
/// looks like success. Older agents do not report this, so every reader must
/// cope with nil.
struct AgentSession: Equatable, Sendable {
    let id: Int
    let console: Int
    let state: String
    let stateCode: Int
    let station: String
    let remote: Bool
    let onConsole: Bool

    /// WTS_CONNECTSTATE_CLASS, the two values worth reasoning about.
    private static let activeState = 0
    private static let disconnectedState = 4

    /// Both of these lean on `onConsole`, and `onConsole` is only meaningful
    /// when the agent could read a console id at all: -1 means
    /// WTSGetActiveConsoleSessionId answered 0xFFFFFFFF, which happens while the
    /// console is mid-transition (just after a tscon, an RDP disconnect
    /// elsewhere, a fast user switch). The agent reports `onConsole:false` for
    /// that, and reading it as "off the console" turned a momentary unknown into
    /// a confident wrong answer — a machine nobody was RDP'd into was refused as
    /// "inside a remote session", and a session sitting on its own console could
    /// be picked for a reclaim. So qualify both on a known console id and let
    /// `remote`, which is the one authoritative signal, speak for itself.

    /// Signed in, but no longer holding the console — what an RDP connection
    /// leaves behind when it closes. `tscon` can put it back.
    var detachedFromConsole: Bool {
        console >= 0 && !onConsole && stateCode == Self.disconnectedState
    }

    /// Somebody is looking at this session through a remote-desktop connection.
    /// Never reclaim one of these: it is in use, and what it enumerates is the
    /// virtual display that connection created.
    ///
    /// `remote` alone is not enough. SM_REMOTESESSION describes the station the
    /// session was LAST attached to, and it stays set after the RDP client
    /// disconnects — measured on rigel: a session left Disconnected by a closed
    /// Control window reported `remote:true, stateCode:4`. That session is not
    /// in use by anyone; it is the very state the reclaim exists to repair. So a
    /// remote flag counts only while the session is not known to be
    /// disconnected, which keeps this and `detachedFromConsole` mutually
    /// exclusive whatever order they are tested in.
    var insideRemoteSession: Bool {
        if remote { return stateCode != Self.disconnectedState }
        return console >= 0 && !onConsole && stateCode == Self.activeState
    }

    /// nil when the far agent predates the session contract.
    static func parse(_ raw: Any?) -> AgentSession? {
        guard let object = raw as? [String: Any] else { return nil }
        return AgentSession(id: (object["id"] as? Int) ?? 0,
                            console: (object["console"] as? Int) ?? -1,
                            state: (object["state"] as? String) ?? "unknown",
                            stateCode: (object["stateCode"] as? Int) ?? -1,
                            station: (object["station"] as? String) ?? "",
                            remote: (object["remote"] as? Bool) ?? false,
                            onConsole: (object["onConsole"] as? Bool) ?? false)
    }
}

/// What `list` answers: the monitors, and the session that looked for them.
/// The session is the difference between "there is no monitor here" and "this
/// process is in no position to see one".
struct AgentListing {
    let monitors: [RemoteMonitor]
    let session: AgentSession?
}

/// What the far end says about the video link at the moment it answered.
/// A value read while the monitor is re-enumerating is not wrong so much as
/// meaningless, and without this the caller cannot tell the two apart.
enum LinkQuality: String {
    case active                 // clean
    case degraded               // some reads failed alongside ones that worked
    case renegotiating          // a link event is in progress
    case absent                 // the monitor is not there at all
    case unknown

    var trustworthy: Bool { self == .active }
}

actor RemoteAgent {
    struct Config: Equatable {
        var host: String = ""      // configured per install; no default
        var exePath: String = #"$HOME\bezel\BezelAgent.exe"#
        var enabled: Bool = true
    }

    private(set) var config: Config

    init(config: Config = Config()) { self.config = config }

    func update(config: Config) {
        if config.host != self.config.host { stopRelay() }
        self.config = config
    }

    /// Short path: a Unix socket path is capped at 104 bytes.
    private var controlPath: String {
        NSHomeDirectory() + "/.bezel-cm-" + config.host
    }

    // MARK: Invocation

    /// Arguments reach a remote shell, so allow only what the protocol needs.
    private func sanitize(_ argument: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !argument.isEmpty, argument.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw RemoteAgentError(message: "refusing to send unexpected argument “\(argument)”")
        }
        return argument
    }

    // MARK: The relay
    //
    // One SSH channel, held open, carrying one command per line.
    //
    // Spawning `ssh host "BezelAgent.exe client ..."` per call pays for a
    // PowerShell login shell and a .NET start EVERY time, and that is nearly all
    // of the cost: measured 0.648s per call that way against 0.079s down a
    // channel already open — eight times faster for the identical DDC work. The
    // agent has had a `relay` mode for this all along; nothing was using it.
    //
    // The actor serialises callers, so exactly one command is ever in flight.

    private var relay: Process?
    private var relayIn: FileHandle?
    private var relayOut: FileHandle?
    private var relayBuffer = Data()

    private func startRelay() -> Bool {
        stopRelay()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=20",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=600",
            config.host, "& \"\(config.exePath)\" relay",
        ]
        let input = Pipe(), output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }

        relay = task
        relayIn = input.fileHandleForWriting
        relayOut = output.fileHandleForReading
        relayBuffer.removeAll()

        // The agent announces itself; without waiting for that, the first real
        // command would read the banner as its own reply.
        guard let ready = readRelayLine(timeout: 20), ready.contains("\"relay\"") else {
            stopRelay()
            return false
        }
        return true
    }

    private func stopRelay() {
        if let handle = relayIn { try? handle.write(contentsOf: Data("quit\n".utf8)) }
        relayIn = nil
        relayOut = nil
        if let task = relay, task.isRunning { task.terminate() }
        relay = nil
        relayBuffer.removeAll()
    }

    /// One line from the relay, or nil on timeout or EOF.
    ///
    /// The read happens on another queue with a semaphore, because
    /// availableData blocks with no timeout of its own — and this runs on the
    /// actor, so a far side that never answers would wedge every other call
    /// behind it.
    private func readRelayLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = relayBuffer.firstIndex(of: 0x0A) {
                let raw = relayBuffer[relayBuffer.startIndex..<newline]
                relayBuffer.removeSubrange(relayBuffer.startIndex...newline)
                let line = String(decoding: raw, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                return line
            }
            guard let handle = relayOut, Date() < deadline else { return nil }

            var chunk = Data()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                chunk = handle.availableData
                done.signal()
            }
            if done.wait(timeout: .now() + max(0.1, deadline.timeIntervalSinceNow)) == .timedOut {
                return nil
            }
            if chunk.isEmpty { return nil }        // the channel closed
            relayBuffer.append(chunk)
        }
    }

    private func runViaRelay(_ safe: [String], timeout: TimeInterval) -> [String: Any]? {
        if relay?.isRunning != true, !startRelay() { return nil }
        guard let handle = relayIn else { return nil }
        guard let payload = (safe.joined(separator: "\t") + "\n").data(using: .utf8) else { return nil }
        do { try handle.write(contentsOf: payload) } catch { stopRelay(); return nil }

        guard let line = readRelayLine(timeout: timeout) else { stopRelay(); return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return nil }
        return json
    }

    private func run(_ agentArgs: [String], timeout: TimeInterval = 30) throws -> [String: Any] {
        let safe = try agentArgs.map(sanitize)

        // Try the open channel first; fall back to spawning a one-shot client if
        // it is not there. The fallback matters: this is the path every monitor
        // control uses, and a relay that will not start must degrade to slow
        // rather than to broken.
        if let json = runViaRelay(safe, timeout: timeout) {
            if let ok = json["ok"] as? Bool, ok == false {
                throw RemoteAgentError(message: (json["error"] as? String) ?? "agent reported failure")
            }
            lastLinkQuality = LinkQuality(rawValue: (json["link"] as? String) ?? "") ?? .unknown
            lastSession = AgentSession.parse(json["session"]) ?? lastSession
            return json
        }

        let remote = "& \"\(config.exePath)\" client " + safe.joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=600",
            config.host, remote,
        ]

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do { try process.run() }
        catch { throw RemoteAgentError(message: "could not start ssh: \(error.localizedDescription)") }

        // Read on background queues so a large reply cannot fill a pipe and
        // deadlock, and so the wait below can be bounded.
        var data = Data(), errorData = Data()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile(); reading.leave()
        }
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = err.fileHandleForReading.readDataToEndOfFile(); reading.leave()
        }

        // This runs on the actor's executor, so an unbounded wait would block
        // every other proxy call behind it. ConnectTimeout only bounds opening a
        // NEW connection; a stale ControlMaster socket or a black-holed TCP
        // connection hangs indefinitely without this.
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit(); exited.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            // SWIFT-005: terminate() raises NSInvalidArgumentException on a
            // process that is not running, and that would kill the app.
            if process.isRunning { process.terminate() }
            _ = exited.wait(timeout: .now() + 3)
            throw RemoteAgentError(
                message: "\(config.host) did not answer within \(Int(timeout))s.")
        }
        reading.wait()

        guard let text = String(data: data, encoding: .utf8) else {
            throw RemoteAgentError(message: "agent returned unreadable output")
        }
        // The reply is the last JSON line; SSH banners may precede it.
        guard let line = text.split(separator: "\n")
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .last(where: { $0.hasPrefix("{") }),
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else {
            let stderr = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteAgentError(message: stderr.isEmpty
                ? "no response from \(config.host)"
                : "\(config.host): \(stderr)")
        }
        if let ok = json["ok"] as? Bool, ok == false {
            throw RemoteAgentError(message: (json["error"] as? String) ?? "agent reported failure")
        }
        lastLinkQuality = LinkQuality(rawValue: (json["link"] as? String) ?? "") ?? .unknown
        lastSession = AgentSession.parse(json["session"]) ?? lastSession
        return json
    }

    /// Link quality reported by the most recent call.
    private(set) var lastLinkQuality: LinkQuality = .unknown
    private(set) var lastDisconnectError: String?
    /// The session the far agent last answered from — `health` and `list` both
    /// carry it, so this is current after either. Stays nil against an agent
    /// too old to report one.
    private(set) var lastSession: AgentSession?

    // MARK: Commands

    func health() throws -> Int {
        let json = try run(["health"])
        return (json["monitors"] as? Int) ?? 0
    }

    func list() throws -> AgentListing {
        let json = try run(["list"])
        let raw = (json["monitors"] as? [[String: Any]]) ?? []
        let monitors = raw.map {
            RemoteMonitor(index: ($0["index"] as? Int) ?? 0,
                          description: ($0["description"] as? String) ?? "",
                          device: ($0["device"] as? String) ?? "",
                          deviceID: ($0["deviceId"] as? String) ?? "")
        }
        return AgentListing(monitors: monitors, session: AgentSession.parse(json["session"]))
    }

    func capabilities(monitor: Int) throws -> String {
        let json = try run(["caps", String(monitor)], timeout: 45)
        return (json["capabilities"] as? String) ?? ""
    }

    /// One round trip for many codes — the whole point, given the per-call cost.
    func read(monitor: Int, codes: [UInt8]) throws -> [UInt8: RemoteReading] {
        guard !codes.isEmpty else { return [:] }
        var args = ["get", String(monitor)]
        args.append(contentsOf: codes.map { String(format: "%02X", $0) })

        let json = try run(args, timeout: 60)
        guard let values = json["values"] as? [[String: Any]] else { return [:] }

        var result: [UInt8: RemoteReading] = [:]
        for entry in values {
            guard let code = entry["code"] as? Int,
                  (entry["ok"] as? Bool) == true,
                  let current = entry["current"] as? Int,
                  let maximum = entry["maximum"] as? Int else { continue }
            result[UInt8(code)] = RemoteReading(code: UInt8(code),
                                                current: UInt16(clamping: current),
                                                maximum: UInt16(clamping: maximum),
                                                type: UInt8(clamping: (entry["type"] as? Int) ?? 0))
        }
        return result
    }

    /// Read the whole sub-selector map of a sub-addressed code in one round trip.
    ///
    /// HP packs many settings behind 0xE1: the high byte selects which, the low
    /// byte is its value. A read returns whichever the monitor's rotation lands
    /// on, and the distribution is very uneven — 0x13 comes back 81% of the time
    /// while the interesting ones appear in about 6%. Sampling for one selector
    /// at a time therefore misses it often, so take many samples at once and
    /// build the entire map from them.
    func readSubSelectorMap(monitor: Int, code: UInt8, samples: Int = 120) throws -> [UInt8: UInt16] {
        var args = ["get", String(monitor)]
        args.append(contentsOf: Array(repeating: String(format: "%02X", code), count: samples))
        let json = try run(args, timeout: 180)
        guard let values = json["values"] as? [[String: Any]] else { return [:] }

        var map: [UInt8: UInt16] = [:]
        for entry in values {
            guard (entry["ok"] as? Bool) == true, let current = entry["current"] as? Int else { continue }
            let value = UInt16(clamping: current)
            map[UInt8(value >> 8)] = value
        }
        return map
    }

    /// Write one code and read several back in a single round trip.
    /// Every call to the proxy costs the better part of a second, so a UI action
    /// that was write-then-confirm-then-refresh is now one exchange.
    func writeAndRead(monitor: Int, code: UInt8, value: UInt16,
                      readCodes: [UInt8]) throws -> [UInt8: RemoteReading] {
        var args = ["setget", String(monitor), String(format: "%02X", code), String(value)]
        args.append(contentsOf: readCodes.map { String(format: "%02X", $0) })
        let json = try run(args, timeout: 90)
        guard let values = json["values"] as? [[String: Any]] else { return [:] }

        var result: [UInt8: RemoteReading] = [:]
        for entry in values {
            guard let code = entry["code"] as? Int, (entry["ok"] as? Bool) == true,
                  let current = entry["current"] as? Int,
                  let maximum = entry["maximum"] as? Int else { continue }
            result[UInt8(code)] = RemoteReading(code: UInt8(code),
                                                current: UInt16(clamping: current),
                                                maximum: UInt16(clamping: maximum),
                                                type: UInt8(clamping: (entry["type"] as? Int) ?? 0))
        }
        return result
    }

    /// Write and read nothing back.
    ///
    /// For codes where the read-back cannot tell you anything — 0xE1 answers
    /// with whichever sub-setting it chooses — and where the write makes the
    /// panel reconfigure, so the read lands while it is busy and waits it out.
    /// Measured: 0.71s per write with the read-back, 0.09s without.
    func writeOnly(monitor: Int, code: UInt8, value: UInt16) throws {
        _ = try run(["setraw", String(monitor), String(format: "%02X", code), String(value)],
                    timeout: 20)
    }

    @discardableResult
    func write(monitor: Int, code: UInt8, value: UInt16) throws -> RemoteReading? {
        let json = try run(["set", String(monitor), String(format: "%02X", code), String(value)],
                           timeout: 30)
        guard let wrote = json["wrote"] as? [String: Any],
              let current = wrote["current"] as? Int,
              let maximum = wrote["maximum"] as? Int else { return nil }
        return RemoteReading(code: code, current: UInt16(clamping: current),
                             maximum: UInt16(clamping: maximum),
                             type: UInt8(clamping: (wrote["type"] as? Int) ?? 0))
    }

    /// Where the far pointer is, and the desktop it lives on.
    ///
    /// The KVM needs the size before it can send an absolute position that means
    /// anything, and it cannot infer it: the far desktop is whatever resolution
    /// and scale that machine is set to, and its origin can be negative when it
    /// has more than one display.
    func cursor() throws -> (point: CGPoint, bounds: CGRect) {
        let json = try run(["cursor"])
        let x = (json["x"] as? Int) ?? 0
        let y = (json["y"] as? Int) ?? 0
        guard let v = json["virtual"] as? [String: Any],
              let vw = v["w"] as? Int, let vh = v["h"] as? Int else {
            throw RemoteAgentError(message: "agent did not report the virtual screen")
        }
        let vx = (v["x"] as? Int) ?? 0
        let vy = (v["y"] as? Int) ?? 0
        return (CGPoint(x: x, y: y),
                CGRect(x: vx, y: vy, width: vw, height: vh))
    }

    /// Ask ANY host how big its desktop is, without disturbing this agent's own
    /// connection.
    ///
    /// The KVM chain has a machine per host and none of them is necessarily the
    /// DDC proxy, so sizing them cannot go through the configured connection.
    /// One short-lived ssh each, paid once when the KVM is armed.
    static func desktopSize(host: String, exePath: String) -> CGSize? {
        guard !host.isEmpty else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                          host, "& \"\(exePath)\" client cursor"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = json["virtual"] as? [String: Any],
              let w = v["w"] as? Int, let h = v["h"] as? Int,
              w > 1, h > 1 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Drop the shared SSH connection, e.g. when the host setting changes.
    func disconnect() {
        stopRelay()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "ControlPath=\(controlPath)", "-O", "exit", config.host]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // Leaving the stale master socket in place is what makes a hung call
            // possible, so this failure is worth surfacing rather than dropping.
            lastDisconnectError = error.localizedDescription
            return
        }
        process.waitUntilExit()
    }
}
