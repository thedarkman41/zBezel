import Foundation
import CryptoKit

/// The health of one KVM machine's agent, as the KVM Machines card shows it.
///
///   ok          the agent is running and its source matches what this app ships
///   mismatch    running, but the source differs — a redeploy would change it
///   notRunning  reachable over SSH, but no agent process is up
///   unreachable SSH itself did not connect (the box is off, or asleep)
///   unknown     not checked yet
enum MachineHealth: Equatable {
    case unknown, unreachable, notRunning, mismatch, ok
}

/// Is each machine running the agent this app would deploy?
///
/// "Source code parity" compares a SHA-256 of the agent's C# against the copy
/// bundled in this app — the exact bytes a redeploy would send. Equal means a
/// redeploy is a no-op; different means the machine is behind (or ahead).
enum AgentParity {

    /// SHA-256 of the agent source THIS app carries, which is the reference every
    /// machine is measured against. Computed from the bundled copy, the same file
    /// the installer ships, so the check tracks the running app rather than
    /// whatever happens to be in a checkout.
    static func bundledSourceHash() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("Agent/BezelAgent.cs")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// One SSH probe: whether the agent is running there, and whether its source
    /// matches `reference`. Blocking — call it off the main actor.
    ///
    /// The far shell is PowerShell (the same reason the KVM's own commands use
    /// the `&` call operator), so this is one PowerShell line. certutil's second
    /// output line is the bare hash. ssh's own exit 255 means the connection
    /// never came up — distinct from the remote command merely failing — so that
    /// alone is "unreachable"; anything else is a reachable box we could not find
    /// a running agent on.
    static func probe(host: String, reference: String) -> MachineHealth {
        guard !host.isEmpty else { return .unknown }

        let powershell =
            "$r=[bool](Get-Process BezelAgent -ErrorAction SilentlyContinue); "
            + "$h=if (Test-Path \"$HOME\\bezel\\BezelAgent.cs\") "
            + "{ (certutil -hashfile \"$HOME\\bezel\\BezelAgent.cs\" SHA256 | Select-Object -Index 1).Trim() } "
            + "else { '' }; "
            + "\"$r|$h\""

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", host, powershell]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return .unreachable }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        if task.terminationStatus == 255 { return .unreachable }   // ssh could not connect

        let line = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let running = parts.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() == "true" } ?? false
        let hash = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces).lowercased() : ""

        if !running { return .notRunning }
        return hash == reference.lowercased() ? .ok : .mismatch
    }
}
