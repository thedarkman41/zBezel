import Foundation

/// BezelAgent's secure-desktop commands, spoken over SSH: whether a machine is
/// sitting at its Windows sign-in screen, and — when it is — waking that screen
/// so the KVM can type the password into it.
///
/// The ordinary KVM injector runs as the signed-in user and is refused at the
/// sign-in screen (Windows' secure desktop). When a machine is locked, the KVM
/// routes the keyboard through a SYSTEM worker instead; these two calls are how
/// the Mac learns it needs to, and asks the far side to stand that worker up.
enum SecureDesktop {
    struct Status { var locked: Bool; var user: String }

    private static let sshOpts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6"]

    /// The hosts to try, most-preferred first: the configured (Tailscale) name,
    /// then the LAN mDNS name. After a reboot a box answers on `<name>.local` over
    /// the LAN before Tailscale has come up, so the pre-login sign-in stays
    /// reachable either way. Only a bare short name has a `.local` form.
    private nonisolated static func reachOrder(_ host: String) -> [String] {
        (host.contains(".") || host.isEmpty) ? [host] : [host, "\(host).local"]
    }

    /// Whether the machine's console is showing the lock/sign-in screen (LogonUI
    /// is up). nil when the query fails on every path — unreachable, or no agent —
    /// which the caller treats as "not locked", so a hiccup never traps the
    /// keyboard on a hunch. Works before anyone has signed in (a cold boot),
    /// because sshd is a service and the check needs no interactive session.
    nonisolated static func status(host: String) async -> Status? {
        let hosts = reachOrder(host)
        if hosts.count == 1 { return await statusOnce(host: hosts[0]) }
        // Race the Tailscale name and the LAN name; take the first that answers,
        // so a down tailnet costs no extra latency while the LAN is up.
        return await withTaskGroup(of: Status?.self) { group in
            for h in hosts { group.addTask { await statusOnce(host: h) } }
            for await result in group where result != nil {
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    private nonisolated static func statusOnce(host: String) async -> Status? {
        let r = await ConsoleReclaim.run("/usr/bin/ssh",
            sshOpts + [host, #"& "$HOME\bezel\BezelAgent.exe" secure-status"#])
        guard r.status == 0 else { return nil }
        let line = r.output.split(separator: "\n").last.map(String.init) ?? r.output
        let json = String(line.drop(while: { $0 != "{" }))
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let locked = obj["locked"] as? Bool else { return nil }
        return Status(locked: locked, user: obj["user"] as? String ?? "")
    }

    /// Fire the SYSTEM task that wakes the sign-in and stands up the secure-input
    /// worker. Fire-and-forget: the worker announces itself on its own named pipe,
    /// which is what the `secure-kvm` channel then connects to. Tries the Tailscale
    /// name, then the LAN name, so it fires on whichever path is up post-reboot.
    nonisolated static func wake(host: String) async {
        for h in reachOrder(host) {
            let r = await ConsoleReclaim.run("/usr/bin/ssh",
                sshOpts + [h, "schtasks /run /tn BezelSecureInject | Out-Null"])
            if r.status == 0 { return }
        }
    }
}
