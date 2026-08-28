import Foundation

/// Installs BezelAgent onto a Windows machine over SSH.
///
/// Aimed at a clean install: nothing is assumed present except Windows itself and
/// an OpenSSH server. The C# compiler used to build the agent (`csc.exe`) ships
/// with the .NET Framework that is part of Windows, so no toolchain download is
/// needed. `dxva2.dll`, which actually carries the DDC/CI calls, is likewise a
/// Windows component — nothing of HP's is required.
///
/// Every remote command is sent as PowerShell `-EncodedCommand`. That sidesteps
/// quoting entirely and works whether the SSH default shell is cmd.exe (the
/// Windows default) or powershell.exe.
@MainActor
final class AgentInstaller: ObservableObject {

    enum StepState: Equatable { case pending, running, done, failed }

    struct Step: Identifiable, Equatable {
        let id: Int
        let title: String
        var state: StepState = .pending
        var detail: String = ""
    }

    struct Target: Equatable {
        var host: String = ""
        var user: String = ""
        var port: Int = 22
        var installKey: Bool = true

        var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    }

    enum Auth: Equatable {
        case key
        case password(String)
    }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var succeeded = false
    @Published private(set) var log: String = ""
    @Published private(set) var hostFingerprint: String?

    private var askpassDirectory: URL?
    private var knownHostsFile: URL?
    private var scannedHostKeys: String?

    // MARK: Running

    /// Set when the install is paused waiting for the user to approve the host
    /// key. Nothing has been sent to the machine at that point.
    @Published private(set) var awaitingHostKeyApproval = false

    func install(target: Target, auth: Auth, hostKeyApproved: Bool = false) async {
        guard !running else { return }
        awaitingHostKeyApproval = false
        running = true
        finished = false
        succeeded = false
        log = ""
        hostFingerprint = nil

        steps = [
            Step(id: 0, title: "Reach the machine over SSH"),
            Step(id: 1, title: "Authenticate"),
            Step(id: 2, title: "Install the SSH key for future runs"),
            Step(id: 3, title: "Check Windows prerequisites"),
            Step(id: 4, title: "Copy the agent source"),
            Step(id: 5, title: "Compile BezelAgent.exe"),
            Step(id: 6, title: "Register the logon task"),
            Step(id: 7, title: "Verify the monitor is visible"),
        ]

        defer {
            if let known = knownHostsFile { try? FileManager.default.removeItem(at: known) }
            knownHostsFile = nil
            tearDownAskpass()
            running = false
            finished = true
        }

        do {
            try await run(target: target, auth: auth, hostKeyApproved: hostKeyApproved)
            succeeded = true
        } catch let error as InstallError {
            note(error.message)
        } catch {
            note(error.localizedDescription)
        }
    }

    struct InstallError: Error { let message: String }

    private func run(target: Target, auth: Auth, hostKeyApproved: Bool) async throws {
        guard !target.host.isEmpty else {
            throw InstallError(message: "Enter the machine's hostname or IP address.")
        }

        if case .password(let password) = auth, !password.isEmpty {
            try setUpAskpass(password: password)
        }

        // 0 — is anything listening?
        try await step(0) {
            let fingerprint = try await self.scanHostKey(target)
            self.hostFingerprint = fingerprint
            return "host key \(fingerprint)"
        }

        // A password must not go out before the operator has seen whose key this
        // is. Stop here the first time and let them look at the fingerprint.
        if case .password = auth, !hostKeyApproved {
            awaitingHostKeyApproval = true
            throw InstallError(message: "Check the host key below, then continue.")
        }
        if case .password = auth, hostKeyApproved, let keys = scannedHostKeys {
            let file = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("zbezel-known-" + UUID().uuidString)
            do {
                try keys.write(to: file, atomically: true, encoding: .utf8)
                knownHostsFile = file
            } catch {
                // Arming StrictHostKeyChecking=yes against a file that does not
                // exist would fail every later step with a confusing error.
                throw InstallError(message:
                    "Could not record the approved host key: \(error.localizedDescription)")
            }
        }

        // 1 — can we log in?
        try await step(1) {
            let whoami = try await self.remotePowerShell(
                target, auth,
                "[System.Security.Principal.WindowsIdentity]::GetCurrent().Name")
            let name = Self.lastMeaningfulLine(whoami)
            guard !name.isEmpty else {
                throw InstallError(message: "Logged in but the machine returned nothing. Is this a Windows host?")
            }
            return "signed in as \(name)"
        }

        // 2 — leave a key behind so nothing needs a password again.
        if target.installKey, case .password = auth {
            try await step(2) {
                guard let publicKey = self.localPublicKey() else {
                    return "skipped — no SSH public key found on this Mac"
                }
                _ = try await self.remotePowerShell(target, auth, Self.authorizedKeysScript(publicKey))
                return "public key added to authorized_keys"
            }
        } else {
            mark(2, .done, detail: "not needed")
        }

        // From here on prefer the key: it is now installed.
        let onward: Auth = (target.installKey && localPublicKey() != nil) ? .key : auth

        // 3 — prerequisites.
        try await step(3) {
            let report = try await self.remotePowerShell(target, onward, Self.preflightScript)
            var csc = false, session = false
            var sessionDetail = ""
            for line in report.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("CSC=") { csc = text.hasSuffix("yes") }
                if text.hasPrefix("CONSOLE=") {
                    sessionDetail = String(text.dropFirst("CONSOLE=".count))
                    session = sessionDetail != "none"
                }
            }
            guard csc else {
                throw InstallError(message:
                    "csc.exe was not found. It ships with the .NET Framework, which is normally part of Windows — "
                  + "check that the machine is not a stripped-down image.")
            }
            guard session else {
                throw InstallError(message:
                    "Nobody is signed in at the console. The agent needs an interactive desktop session, because "
                  + "the Windows Monitor Configuration API sees no monitors from an SSH session. Sign in on the "
                  + "machine itself, then install again.")
            }
            return "csc.exe present, console session \(sessionDetail)"
        }

        // 4 — payload.
        try await step(4) {
            _ = try await self.remotePowerShell(
                target, onward,
                #"New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\bezel" | Out-Null; "ok""#)
            let files = try self.bundledAgentFiles()
            try await self.copy(files: files, to: target, auth: onward)
            return "copied \(files.count) files to %USERPROFILE%\\bezel"
        }

        // 5 — build.
        try await step(5) {
            let output = try await self.remotePowerShell(target, onward, Self.compileScript)
            guard output.contains("COMPILED") else {
                throw InstallError(message: "Compile failed:\n" + output)
            }
            return "BezelAgent.exe built"
        }

        // 6 — service.
        try await step(6) {
            let output = try await self.remotePowerShell(
                target, onward,
                #"powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bezel\install-service.ps1""#)
            guard output.contains("SERVICE RUNNING") else {
                throw InstallError(message: "The logon task did not start:\n" + output)
            }
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 7 — does it actually see a monitor?
        try await step(7) {
            let output = try await self.remotePowerShell(
                target, onward,
                #"& "$env:USERPROFILE\bezel\BezelAgent.exe" client list"#)
            guard let line = output.split(separator: "\n")
                    .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                    .last(where: { $0.hasPrefix("{") }),
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let monitors = json["monitors"] as? [[String: Any]]
            else {
                throw InstallError(message: "The agent did not answer:\n" + output)
            }
            guard !monitors.isEmpty else {
                throw InstallError(message:
                    "The agent is running but reports no monitors. That usually means it is not in the "
                  + "interactive session, or the screen is locked.")
            }
            let names = monitors.compactMap { $0["description"] as? String }
            return names.joined(separator: ", ")
        }
    }

    // MARK: Step plumbing

    private func step(_ id: Int, _ body: () async throws -> String) async throws {
        mark(id, .running)
        do {
            let detail = try await body()
            mark(id, .done, detail: detail)
            note("✓ \(steps[id].title) — \(detail)")
        } catch {
            let message = (error as? InstallError)?.message ?? error.localizedDescription
            mark(id, .failed, detail: message)
            note("✗ \(steps[id].title) — \(message)")
            throw InstallError(message: message)
        }
    }

    private func mark(_ id: Int, _ state: StepState, detail: String = "") {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[index].state = state
        if !detail.isEmpty { steps[index].detail = detail }
    }

    private func note(_ text: String) {
        log += text + "\n"
    }

    // MARK: SSH

    /// Password handling: SSH is pointed at a throwaway askpass helper in a
    /// 0700 directory that reads a 0600 file. Both are shredded when the install
    /// finishes. The password is never placed in a command line, where it would
    /// be visible to `ps`.
    private func setUpAskpass(password: String) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zbezel-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let secret = directory.appendingPathComponent("secret")
        guard FileManager.default.createFile(
                atPath: secret.path,
                contents: Data(password.utf8),
                attributes: [.posixPermissions: 0o600]) else {
            throw InstallError(message: "Could not stage credentials securely.")
        }

        let helper = directory.appendingPathComponent("askpass")
        // SSH passes the prompt text as $1. Answer only a password prompt: an
        // unconditional `cat` would also answer the host-key confirmation, handing
        // the password to whatever machine happened to respond.
        let script = """
        #!/bin/sh
        case "$1" in
          *[Pp]assword*|*[Pp]assphrase*) exec /bin/cat '\(secret.path)' ;;
        esac
        exit 1
        """

        guard FileManager.default.createFile(
                atPath: helper.path,
                contents: Data(script.utf8),
                attributes: [.posixPermissions: 0o700]) else {
            throw InstallError(message: "Could not stage credentials securely.")
        }
        askpassDirectory = directory
    }

    private func tearDownAskpass() {
        guard let directory = askpassDirectory else { return }
        let secret = directory.appendingPathComponent("secret")
        // Overwrite before unlinking rather than just deleting.
        if let handle = try? FileHandle(forWritingTo: secret),
           let size = try? FileManager.default.attributesOfItem(atPath: secret.path)[.size] as? Int {
            try? handle.write(contentsOf: Data(repeating: 0, count: max(size, 1)))
            try? handle.close()
        }
        try? FileManager.default.removeItem(at: directory)
        askpassDirectory = nil
    }

    private func sshOptions(_ target: Target, _ auth: Auth) -> [String] {
        var options = [
            "-o", "ConnectTimeout=12",
            "-p", String(target.port),
        ]
        if knownHostsFile == nil {
            options += ["-o", "StrictHostKeyChecking=accept-new"]
        }
        switch auth {
        case .key:
            options += ["-o", "BatchMode=yes"]
        case .password:
            options += ["-o", "NumberOfPasswordPrompts=1",
                        "-o", "PreferredAuthentications=password,keyboard-interactive"]
            // The user approved a specific host key, so pin it: a substituted key
            // must now be a hard failure rather than a silent first-use accept.
            if let known = knownHostsFile {
                options += ["-o", "UserKnownHostsFile=\(known.path)",
                            "-o", "StrictHostKeyChecking=yes"]
            }
        }
        return options
    }

    private func environment(for auth: Auth) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if case .password = auth, let directory = askpassDirectory {
            env["SSH_ASKPASS"] = directory.appendingPathComponent("askpass").path
            env["SSH_ASKPASS_REQUIRE"] = "force"     // OpenSSH 8.4+; this host has 10.3
            env["DISPLAY"] = env["DISPLAY"] ?? ":0"
        }
        return env
    }

    /// Wrap a PowerShell script as -EncodedCommand: immune to remote shell quoting.
    private func encoded(_ script: String) -> String {
        var utf16 = Data()
        for unit in Array(script.utf16) {
            utf16.append(UInt8(unit & 0xFF))
            utf16.append(UInt8(unit >> 8))
        }
        return utf16.base64EncodedString()
    }

    @discardableResult
    private func remotePowerShell(_ target: Target, _ auth: Auth, _ script: String) async throws -> String {
        let quiet = "$ProgressPreference = 'SilentlyContinue'\n" + script
        return try await execute("/usr/bin/ssh",
                          sshOptions(target, auth) + [
                            target.destination,
                            "powershell", "-NoProfile", "-NonInteractive",
                            "-ExecutionPolicy", "Bypass",
                            "-EncodedCommand", encoded(quiet)],
                          auth: auth)
    }

    private func copy(files: [URL], to target: Target, auth: Auth) async throws {
        var arguments = ["-o", "ConnectTimeout=12",
                         "-o", "StrictHostKeyChecking=accept-new",
                         "-P", String(target.port)]
        if case .key = auth { arguments += ["-o", "BatchMode=yes"] }
        arguments += files.map(\.path)
        arguments.append("\(target.destination):bezel/")
        _ = try await execute("/usr/bin/scp", arguments, auth: auth)
    }

    private func scanHostKey(_ target: Target) async throws -> String {
        let scan = try await execute("/usr/bin/ssh-keyscan",
                                     ["-T", "8", "-p", String(target.port), target.host],
                                     auth: .key, allowFailure: true)
        scannedHostKeys = scan
        let keyLines = scan.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        guard !keyLines.isEmpty else {
            throw InstallError(message:
                "No SSH server answered on \(target.host):\(target.port). On a clean Windows install "
              + "the OpenSSH Server feature is off by default — enable it in "
              + "Settings → System → Optional features, then start the sshd service.")
        }
        // Run the scanned key through ssh-keygen for a real SHA256 fingerprint,
        // which is the thing actually worth comparing against the machine.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zbezel-hostkey-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try? scan.write(to: scratch, atomically: true, encoding: .utf8)
        if let printed = try? await execute("/usr/bin/ssh-keygen", ["-lf", scratch.path],
                                            auth: .key, allowFailure: true),
           let first = printed.split(separator: "\n").first(where: { $0.contains("SHA256:") }) {
            let fields = first.split(separator: " ")
            let hash = fields.first(where: { $0.hasPrefix("SHA256:") }).map(String.init) ?? ""
            let kind = fields.last.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "()")) } ?? ""
            return kind.isEmpty ? hash : "\(hash) (\(kind))"
        }
        return String(keyLines[0].split(separator: " ").dropFirst().first ?? "")
    }

    private func execute(_ launchPath: String, _ arguments: [String],
                         auth: Auth, allowFailure: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [environment = environment(for: auth)] in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                process.environment = environment
                // Detach from any terminal so SSH cannot fall back to a TTY prompt
                // that nobody can answer from inside a GUI app.
                process.standardInput = FileHandle.nullDevice

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do { try process.run() } catch {
                    continuation.resume(throwing: InstallError(
                        message: "Could not run \(launchPath): \(error.localizedDescription)"))
                    return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                if process.terminationStatus != 0 && !allowFailure {
                    let detail = Self.stripCLIXML(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: InstallError(
                        message: detail.isEmpty ? "exit code \(process.terminationStatus)"
                                                : Self.humanise(detail)))
                    return
                }
                // stderr is deliberately dropped on success. PowerShell writes
                // CLIXML progress records to it that are not errors.
                continuation.resume(returning: Self.stripCLIXML(stdout))
            }
        }
    }

    /// PowerShell over SSH prefixes remote output with CLIXML progress objects.
    /// They are noise, not errors, and they break naive parsing.
    private nonisolated static func stripCLIXML(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("#< CLIXML")
                    && !trimmed.hasPrefix("<Objs")
                    && !trimmed.hasPrefix("</Objs")
            }
            .joined(separator: "\n")
    }

    private nonisolated static func lastMeaningfulLine(_ text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
    }

    /// Turn the more common SSH failures into something worth reading.
    private nonisolated static func humanise(_ stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("permission denied") {
            return "Authentication was refused. Check the username and password, and that this "
                 + "account may sign in over SSH."
        }
        if lower.contains("connection refused") {
            return "Connection refused — the OpenSSH Server feature is probably not running."
        }
        if lower.contains("could not resolve") || lower.contains("name or service not known") {
            return "That hostname did not resolve."
        }
        if lower.contains("host key verification failed") {
            return "The machine's SSH host key changed since last time. Remove the old entry from "
                 + "~/.ssh/known_hosts if that is expected."
        }
        return stderr
    }

    // MARK: Payload

    private func bundledAgentFiles() throws -> [URL] {
        let names = ["BezelAgent.cs", "start-hidden.vbs", "install-service.ps1", "run-agent.ps1"]
        guard let resources = Bundle.main.resourceURL else {
            throw InstallError(message: "The app bundle has no resources directory.")
        }
        let directory = resources.appendingPathComponent("Agent")
        var found: [URL] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw InstallError(message: "\(name) is missing from the app bundle.")
            }
            found.append(url)
        }
        return found
    }

    private func localPublicKey() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in ["id_ed25519.pub", "id_rsa.pub", "id_ecdsa.pub"] {
            let url = home.appendingPathComponent(".ssh/\(name)")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    // MARK: Remote scripts

    private static func authorizedKeysScript(_ publicKey: String) -> String {
        // Note: for an administrator account, Windows OpenSSH reads
        // administrators_authorized_keys, not the per-user file.
        """
        $key = '\(publicKey.replacingOccurrences(of: "'", with: "''"))'
        $dir = Join-Path $env:USERPROFILE '.ssh'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $file = Join-Path $dir 'authorized_keys'
        if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file | Out-Null }
        $existing = Get-Content $file -ErrorAction SilentlyContinue
        if ($existing -notcontains $key) { Add-Content -Path $file -Value $key }
        icacls $file /inheritance:r /grant "$($env:USERNAME):F" | Out-Null
        'ok'
        """
    }

    private static let preflightScript = """
    $csc = "$env:WINDIR\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe"
    if (Test-Path $csc) { "CSC=yes" } else { "CSC=no" }
    $console = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId
    if ($null -ne $console) { "CONSOLE=$console" } else { "CONSOLE=none" }
    """

    private static let compileScript = """
    $csc = "$env:WINDIR\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe"
    $dir = Join-Path $env:USERPROFILE 'bezel'
    Get-Process BezelAgent -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600
    & $csc /nologo /optimize+ /warn:4 /warnaserror /target:exe /out:"$dir\\BezelAgent.exe" "$dir\\BezelAgent.cs" 2>&1 | Out-String
    if (Test-Path "$dir\\BezelAgent.exe") { "COMPILED" } else { "COMPILE FAILED" }
    """
}
