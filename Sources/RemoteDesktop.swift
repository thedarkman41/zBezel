import Foundation

/// Wakes the desktop on a machine that has no reachable keyboard.
///
/// The problem this solves: after a reboot, a lid-closed box in a dock sits at
/// its login screen, and the software KVM cannot type there — the login screen
/// is the Winlogon secure desktop, and Windows blocks synthetic input to it by
/// design. That is not a limitation to engineer around; it is the mechanism
/// that stops malware approving its own elevation.
///
/// So the way in is RDP, which authenticates over the network and never touches
/// that desktop. Two steps:
///
///   1. Connect, authenticate, disconnect. A session that is *disconnected*
///      rather than signed out survives in `Disconnected` state.
///   2. Ask the machine to move that session onto the physical console. This
///      needs `SeTcbPrivilege`, which an elevated administrator token does not
///      carry — measured, not assumed — so it runs from a SYSTEM scheduled task
///      that install-service.ps1 registers.
///
/// The result is the same as walking up and typing the password, done from here.
/// The Bezel agent then sees real monitors again, which it cannot from an RDP
/// session — it would enumerate the virtual RDP display instead.
@MainActor
final class RemoteDesktop: ObservableObject {

    enum Step: Equatable {
        case idle
        case fetchingCredential
        case connecting
        case reclaiming
        case done
        case failed(String)
    }

    @Published private(set) var step: Step = .idle
    @Published private(set) var log: [String] = []

    /// Learned on first contact and pinned thereafter, the way ssh does it.
    /// Without this we would be trusting whatever answers on that address.
    @Published var pinnedFingerprints: [String: String] =
        UserDefaults.standard.dictionary(forKey: "rdpFingerprints") as? [String: String] ?? [:]

    private func note(_ line: String) {
        log.append(line)
        NSLog("zBezel rdp: %@", line)
    }

    /// The whole recovery, end to end.
    ///
    /// `user` is the Windows account. The password comes from Beacon's broker
    /// and is never persisted here, never logged, and never placed on a command
    /// line where `ps` would show it.
    func wakeConsole(host: String, user: String, domain: String? = nil,
                     sshTarget: String? = nil) async {
        step = .fetchingCredential
        log.removeAll()
        note("waking \(host) as \(user)")

        // Beacon may be locked, and after a reboot it usually is. Ask it to
        // raise its unlock UI and wait — Beacon owns the timeout, we do not.
        let name = BeaconSecrets.secretName(forHost: host)
        note("fetching \(name) from Beacon")
        let locked = BeaconSecrets.isLocked()
        let (password, status) = BeaconSecrets.secret(named: name,
                                                      wait: true,
                                                      prompt: locked ?? true)
        guard let password, !password.isEmpty else {
            let why = status.explanation
            note("no credential: \(why)")
            step = .failed(why)
            return
        }
        note("credential obtained")

        // 1 — make a session exist.
        step = .connecting
        let pinned = pinnedFingerprints[host.lowercased()]
        note(pinned == nil ? "no pinned host key yet; will record one"
                           : "checking against the pinned host key")

        let result = await Self.touch(host: host, user: user, domain: domain,
                                      password: password, expecting: pinned)

        switch result {
        case .failure(let name, let code):
            if name == "HOST_KEY_MISMATCH" {
                note("HOST KEY MISMATCH — refusing. Either the machine was rebuilt, or this is not it.")
                step = .failed("The host key for \(host) has changed. Clear the pin only if you know why.")
            } else if name == "ERRCONNECT_LOGON_FAILURE" {
                // The server answered and refused the credentials, which is a
                // very different problem from not reaching it — and the usual
                // cause is not a wrong password. A Microsoft Account will not
                // authenticate under the short local name Windows invented for
                // its profile folder.
                note("connect failed: \(name) — the server rejected these credentials")
                let hint = (domain?.isEmpty ?? true) && !user.contains("@")
                    ? " If \(user) is a Microsoft account, use the full address as the user "
                    + "and set the domain to MicrosoftAccount. A PIN is not the password."
                    : " Check the password enrolled as \(BeaconSecrets.secretName(forHost: host))."
                step = .failed("\(host) rejected the sign-in." + hint)
            } else if name == "LOGON_TIMEOUT" {
                // The credentials passed NLA and the connection came up, but
                // Winlogon never reported a session in 30 s. Nothing to reclaim.
                note("connect ok, but \(host) never reported the session logged on")
                step = .failed("\(host) accepted the sign-in but never logged the session on. "
                             + "Nothing was changed on its console.")
            } else if name.hasPrefix("LOGON_") {
                note("logon refused after NLA: \(name)")
                step = .failed("\(host) accepted the credentials but refused the logon: \(name).")
            } else if name == "DROPPED_BEFORE_LOGON" {
                note("the server dropped the connection before reporting a logon")
                step = .failed("\(host) dropped the connection before the session logged on.")
            } else {
                note("connect failed: \(name) (0x\(String(code, radix: 16)))")
                step = .failed("RDP connection failed: \(name)")
            }
            return

        case .success(let fingerprint, let session):
            if pinned == nil, let fingerprint, !fingerprint.isEmpty {
                pinnedFingerprints[host.lowercased()] = fingerprint
                UserDefaults.standard.set(pinnedFingerprints, forKey: "rdpFingerprints")
                note("pinned host key \(fingerprint.prefix(23))…")
            }
            note(session > 0 ? "logged on as session \(session), then dropped — now Disconnected"
                             : "logged on and dropped — now Disconnected")
        }

        // 2 — hand it to the console. Over SSH, because when nobody is logged
        // in the agent's own relay is not running either.
        step = .reclaiming
        let target = sshTarget ?? host
        note("asking \(target) to move the session to the console")

        // The task, the ssh call and the verdict parsing live in ConsoleReclaim,
        // because the Control window has to do exactly the same thing when its
        // session ends. All that is left here is turning the verdict into the
        // wording this sheet shows.
        switch await ConsoleReclaim.reclaim(host: target) {
        case .moved(let from):
            note("done — session \(from.map(String.init) ?? "?") is on the console")
            step = .done
        case .alreadyActive:
            note("done — the console was already showing a desktop")
            step = .done
        case .notMoved(let reason):
            note("reclaim: not moved — \(reason)")
            step = .failed("The session exists but was not moved to the console: " + reason)
        case .noTask:
            note("reclaim: BezelReclaimConsole is not installed")
            step = .failed("BezelReclaimConsole is not installed on \(host). "
                         + "Run the agent installer against it again.")
        case .noVerdict:
            note("reclaim: the task reported nothing in 30 s")
            step = .failed("The reclaim task on \(host) started but reported nothing in 30 s. "
                         + "Is the agent there current?")
        case .unreachable(let output):
            note("reclaim: could not run the task — \(output)")
            step = .failed("The session exists but \(target) could not be reached over SSH "
                         + "to move it to the console: \(output)")
        }
    }

    // MARK: - The C call

    private enum TouchResult {
        case success(fingerprint: String?, session: UInt32)
        case failure(String, Int32)
    }

    /// Blocking (up to ~40 s while it waits for Winlogon), so it goes off the
    /// main actor.
    private nonisolated static func touch(host: String, user: String, domain: String?,
                                          password: String,
                                          expecting fingerprint: String?) async -> TouchResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorName = [CChar](repeating: 0, count: 128)
                var seen      = [CChar](repeating: 0, count: 256)
                var session: UInt32 = 0

                let rc = host.withCString { h in
                    user.withCString { u in
                        password.withCString { p in
                            withOptionalCString(domain) { d in
                                withOptionalCString(fingerprint) { f in
                                    zbezel_rdp_touch(h, 3389, u, d, p, f,
                                                     &errorName, Int32(errorName.count),
                                                     &seen, Int32(seen.count),
                                                     &session)
                                }
                            }
                        }
                    }
                }

                let seenFingerprint = String(cString: seen)
                if rc == 0 {
                    continuation.resume(returning: .success(fingerprint: seenFingerprint.isEmpty ? nil : seenFingerprint,
                                                            session: session))
                } else {
                    continuation.resume(returning: .failure(String(cString: errorName), Int32(rc)))
                }
            }
        }
    }

}

/// `withCString` on an Optional, so a nil domain or fingerprint reaches C as
/// NULL rather than an empty string — the shim distinguishes the two.
private func withOptionalCString<R>(_ value: String?,
                                    _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
