import Foundation
import Darwin

/// Finds machines running the KVM agent on the local network, with nothing
/// configured. Each agent broadcasts a small UDP packet every few seconds
/// naming itself and the monitor product codes it sees; this listens for those
/// and keeps a live map of who is up. A machine appears the moment it starts
/// announcing and drops when it goes quiet, so the KVM's machine set is a
/// reflection of reality rather than a hand-kept list. Beacon- and
/// Tailscale-independent by design: it is plain LAN broadcast.
///
/// Discovery is presence only. Controlling a discovered machine still goes over
/// SSH to the address the packet arrived from, exactly as a typed-in host does.
@MainActor
final class KVMDiscovery: ObservableObject {

    /// One machine the network says is up right now.
    struct Agent: Equatable {
        let host: String        // the machine's own name, for display and SSH
        let address: String     // where its packet came from, for the SSH fallback
        let user: String        // the account the agent runs as, for the by-IP fallback
        let input: UInt16       // which monitor input it drives, read from its product code
        let product: String     // the raw product identity, e.g. HPN36D5
        var lastSeen: Date

        /// A complete SSH target for the fallback: `user@ip`, or just the ip when
        /// no user was announced. Empty when there is no address to fall back to.
        var fallbackTarget: String {
            guard !address.isEmpty else { return "" }
            return user.isEmpty ? address : "\(user)@\(address)"
        }
    }

    /// The agent's broadcast port. Must match DiscoveryPort in BezelAgent.cs.
    static let port: UInt16 = 48222
    /// Missed roughly three 5-second beats and it is considered gone.
    static let staleAfter: TimeInterval = 18

    @Published private(set) var agents: [String: Agent] = [:]    // keyed by host.lowercased()

    /// Called when the SET of live machines, or any machine's input/address,
    /// changes — not on every heartbeat. The controller rebuilds the chain here.
    var onChange: (() -> Void)?

    private var source: DispatchSourceRead?
    private var pruneTimer: Timer?

    func start() {
        guard source == nil else { return }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { NSLog("zBezel discovery: socket() failed (%d)", errno); return }

        // Share the port so a second instance (or a quick relaunch that has not
        // released it yet) does not fail to bind, and so this never fights the
        // agent when both run on one box.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            NSLog("zBezel discovery: bind(udp/%d) failed (%d)", Int(Self.port), errno)
            close(fd)
            return
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: fd,
                                                queue: DispatchQueue.global(qos: .utility))
        src.setEventHandler { [weak self] in
            // Read one datagram off the socket on the background queue, decode the
            // sender's address, then hand the bytes to the main actor. No actor
            // state is touched here.
            var buf = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { raw -> Int in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    recvfrom(fd, &buf, buf.count, 0, sp, &fromLen)
                }
            }
            guard n > 0 else { return }
            let data = Data(buf[0..<n])
            var sender = from.sin_addr
            var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &sender, &ipbuf, socklen_t(INET_ADDRSTRLEN))
            let ip = String(cString: ipbuf)
            Task { @MainActor [weak self] in self?.ingest(data, from: ip) }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()

        pruneTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.prune() }
        }
        NSLog("zBezel discovery: listening on udp/%d", Int(Self.port))
    }

    func stop() {
        source?.cancel(); source = nil
        pruneTimer?.invalidate(); pruneTimer = nil
    }

    private func ingest(_ data: Data, from ip: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["kind"] as? String) == "bezelkvm",
              let rawHost = obj["host"] as? String, !rawHost.isEmpty,
              let products = obj["products"] as? [String]
        else { return }
        // Windows reports its name uppercase; lowercase it so it matches the ssh
        // config, the wakeAccounts map, and the secret names everywhere else.
        let host = rawHost.lowercased()

        // Keep it only if one of its monitors is a face of the panel we manage;
        // that face's product code is also which input it is on.
        guard let product = products.first(where: { HPProfile.input(forProduct: $0) != nil }),
              let input = HPProfile.input(forProduct: product)
        else { return }

        let user = (obj["user"] as? String) ?? ""
        let key = host.lowercased()
        let fresh = Agent(host: host, address: ip, user: user, input: input,
                          product: product, lastSeen: Date())
        let prior = agents[key]
        agents[key] = fresh
        // A plain heartbeat (same host, input and address) is not worth a rebuild;
        // a new machine, or one that moved input or address, is.
        if prior == nil || prior!.input != input || prior!.address != ip {
            onChange?()
        }
    }

    private func prune() {
        let now = Date()
        let gone = agents.filter { now.timeIntervalSince($0.value.lastSeen) > Self.staleAfter }.map(\.key)
        guard !gone.isEmpty else { return }
        for key in gone { agents[key] = nil }
        onChange?()
    }
}
