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
            } else {
                note("connect failed: \(name) (0x\(String(code, radix: 16)))")
                step = .failed("RDP connection failed: \(name)")
            }
            return

        case .success(let fingerprint):
            if pinned == nil, let fingerprint, !fingerprint.isEmpty {
                pinnedFingerprints[host.lowercased()] = fingerprint
                UserDefaults.standard.set(pinnedFingerprints, forKey: "rdpFingerprints")
                note("pinned host key \(fingerprint.prefix(23))…")
            }
            note("session created and dropped — now Disconnected")
        }

        // 2 — hand it to the console. Over SSH, because when nobody is logged
        // in the agent's own relay is not running either.
        step = .reclaiming
        let target = sshTarget ?? host
        note("asking \(target) to move the session to the console")
        let reclaim = await Self.run("/usr/bin/ssh",
                                     ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                      target, "schtasks /run /tn BezelReclaimConsole"])
        guard reclaim.status == 0 else {
            note("reclaim task failed: \(reclaim.output)")
            step = .failed("The session exists but could not be moved to the console. "
                         + "Is BezelReclaimConsole installed? \(reclaim.output)")
            return
        }

        note("done — the console should be showing the desktop")
        step = .done
    }

    // MARK: - The C call

    private enum TouchResult {
        case success(String?)
        case failure(String, Int32)
    }

    /// Blocking, so it goes off the main actor.
    private nonisolated static func touch(host: String, user: String, domain: String?,
                                          password: String,
                                          expecting fingerprint: String?) async -> TouchResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var errorName = [CChar](repeating: 0, count: 128)
                var seen      = [CChar](repeating: 0, count: 256)

                let rc = host.withCString { h in
                    user.withCString { u in
                        password.withCString { p in
                            withOptionalCString(domain) { d in
                                withOptionalCString(fingerprint) { f in
                                    zbezel_rdp_touch(h, 3389, u, d, p, f,
                                                     &errorName, Int32(errorName.count),
                                                     &seen, Int32(seen.count))
                                }
                            }
                        }
                    }
                }

                let seenFingerprint = String(cString: seen)
                if rc == 0 {
                    continuation.resume(returning: .success(seenFingerprint.isEmpty ? nil : seenFingerprint))
                } else {
                    continuation.resume(returning: .failure(String(cString: errorName), Int32(rc)))
                }
            }
        }
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async
        -> (status: Int32, output: String) {
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
}

/// `withCString` on an Optional, so a nil domain or fingerprint reaches C as
/// NULL rather than an empty string — the shim distinguishes the two.
private func withOptionalCString<R>(_ value: String?,
                                    _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
