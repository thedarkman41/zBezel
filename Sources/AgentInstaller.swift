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
        /// Opt-in, and deliberately not defaulted on. See `disableSacScript`.
        var disableSmartAppControl: Bool = false

        var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
    }

    /// Smart App Control's state, read during preflight.
    ///
    /// Windows 11 ships this in `evaluation` on a fresh install and decides for
    /// itself whether to switch on. So a machine that installs fine today can
    /// start refusing the agent tomorrow, with no change on our side — which is
    /// exactly what happened on the first machine this was tried on.
    enum SmartAppControl: Equatable {
        case off, on, evaluation, absent

        var blocksUnsignedBinaries: Bool { self == .on }

        var describedForLog: String {
            switch self {
            case .off:        return "off"
            case .on:         return "ON — blocks unsigned binaries"
            case .evaluation: return "evaluation — may switch itself on later"
            case .absent:     return "not present on this Windows build"
            }
        }
    }

    @Published private(set) var smartAppControl: SmartAppControl = .absent
    /// The full path to csc.exe the prerequisite check found, handed to the
    /// compile step so an unusual .NET location still builds.
    private var compilerPath: String?

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

    /// The last meaningful line of the log — what a background heal reports back
    /// to the KVM row when it finishes, success or failure, without the caller
    /// having to parse the whole transcript.
    var lastMessage: String {
        log.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
    }

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
                let output = try await self.remotePowerShell(target, auth, Self.authorizedKeysScript(publicKey))
                // The script reports which file it chose. Surfacing it matters: the
                // admin/non-admin split is the difference between a key that works and
                // one that is silently ignored, and the log is where that gets noticed.
                let line = Self.lastMeaningfulLine(output)
                guard line.hasPrefix("ok:") else {
                    throw InstallError(message: "Could not install the public key:\n" + output)
                }
                return "public key added to \(line.dropFirst(3))"
            }
        } else {
            mark(2, .done, detail: "not needed")
        }

        // From here on prefer the key: it is now installed.
        let onward: Auth = (target.installKey && localPublicKey() != nil) ? .key : auth

        // 3 — prerequisites.
        try await step(3) {
            // The probe occasionally comes back empty — a momentary SSH or
            // PowerShell hiccup, or the agent mid-restart — and one empty read
            // must never be taken for "the compiler is missing". So run it a few
            // times, and treat a report that NEVER once names the compiler as a
            // failure to RUN the check, distinct from the compiler being genuinely
            // absent (which the probe states as CSC=no). On success CSC carries
            // the compiler's full path, not a yes.
            var report = ""
            var sawCSC = false
            var cscPath: String?
            var session = false
            var sessionDetail = ""
            for attempt in 1...3 {
                report = try await self.remotePowerShell(target, onward, Self.preflightScript)
                sawCSC = false; cscPath = nil; session = false; sessionDetail = ""
                for line in report.split(separator: "\n") {
                    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasPrefix("CSC=") {
                        sawCSC = true
                        let value = String(text.dropFirst("CSC=".count)).trimmingCharacters(in: .whitespaces)
                        cscPath = value.lowercased() == "no" ? nil : value
                    }
                    if text.hasPrefix("CONSOLE=") {
                        sessionDetail = String(text.dropFirst("CONSOLE=".count))
                        session = sessionDetail != "none"
                    }
                    if text.hasPrefix("SAC=") {
                        switch String(text.dropFirst("SAC=".count)) {
                        case "0":  self.smartAppControl = .off
                        case "1":  self.smartAppControl = .on
                        case "2":  self.smartAppControl = .evaluation
                        default:   self.smartAppControl = .absent
                        }
                    }
                }
                if sawCSC { break }
                if attempt < 3 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            }

            // The probe ran but never named the compiler, even after retries.
            // Almost always a transient rather than a machine missing its
            // toolchain — so say that, and show what it DID return so a real
            // cause is visible instead of hidden behind a guess.
            guard sawCSC else {
                let tail = report.trimmingCharacters(in: .whitespacesAndNewlines)
                throw InstallError(message:
                    "Could not run the prerequisite check on \(target.host) after three tries — it kept "
                  + "returning nothing. That is usually a brief SSH or PowerShell hiccup, or the agent "
                  + "restarting. Wait a moment and run Set Up again."
                  + (tail.isEmpty ? "" : "\n\nWhat it returned:\n\(tail.prefix(400))"))
            }

            // Fail here rather than at step 7. Smart App Control does not stop
            // the copy or the compile — it stops the agent from ever running,
            // so without this check the install appears to succeed for five more
            // steps and then reports a bewildering "the agent did not answer".
            if self.smartAppControl.blocksUnsignedBinaries && !target.disableSmartAppControl {
                throw InstallError(message:
                    "Smart App Control is ON, and it will refuse to run the agent: the agent is "
                  + "compiled on this machine and is therefore unsigned. Either sign the agent with "
                  + "a certificate that has established reputation, or tick \"Turn off Smart App "
                  + "Control\" and install again — but note that turning it off cannot be undone "
                  + "without reinstalling Windows.")
            }
            guard let csc = cscPath else {
                let tail = report.trimmingCharacters(in: .whitespacesAndNewlines)
                throw InstallError(message:
                    "The .NET Framework C# compiler (csc.exe) was not found on \(target.host), in the "
                  + "runtime directory, the standard Framework path, or a search of the .NET folders. "
                  + "It ships with the .NET Framework that is part of Windows, so a machine without it "
                  + "is usually a stripped-down image. Install the .NET Framework and run Set Up again."
                  + (tail.isEmpty ? "" : "\n\nWhat the check returned:\n\(tail.prefix(400))"))
            }
            self.compilerPath = csc
            guard session else {
                throw InstallError(message:
                    "Nobody is signed in at the console. The agent needs an interactive desktop session, because "
                  + "the Windows Monitor Configuration API sees no monitors from an SSH session. Sign in on the "
                  + "machine itself, then install again.")
            }
            return "csc.exe at \(csc), console session \(sessionDetail), "
                 + "Smart App Control \(self.smartAppControl.describedForLog)"
        }

        // 3a — the one-way door, only if it was ticked and is actually needed.
        if target.disableSmartAppControl && smartAppControl.blocksUnsignedBinaries {
            note("Turning Smart App Control off. This cannot be undone without reinstalling Windows.")
            let output = try await remotePowerShell(target, onward, Self.disableSacScript)
            guard output.contains("SACNOW=0") else {
                throw InstallError(message:
                    "Could not turn Smart App Control off:\n" + output)
            }
            note("✓ Smart App Control disabled — the machine must be restarted before the agent will run.")
        } else if target.disableSmartAppControl {
            note("Smart App Control was already \(smartAppControl.describedForLog); left alone.")
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
            let output = try await self.remotePowerShell(
                target, onward, Self.compileScript(csc: self.compilerPath ?? ""))
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
                    "The agent is running but reports no monitors. Its session is not on the "
                  + "physical console — the screen is locked, the session was left disconnected "
                  + "after an RDP connection, or the agent started outside the interactive session.")
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
        let names = ["BezelAgent.cs", "start-hidden.vbs", "install-service.ps1"]
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
        // For an account in the local Administrators group, Windows OpenSSH reads
        // ONLY administrators_authorized_keys and ignores the per-user file. Writing
        // the wrong one leaves authentication failing with no useful error — the key
        // is present, readable, correct, and never consulted.
        //
        // Decide by SID, never by name. A Microsoft Account appears in the group as
        // "MicrosoftAccount\someone@example.com" while $env:USERNAME is the five-
        // character truncation Windows made for the profile (lordchubbus -> lordc),
        // so a name comparison reports "not an admin" for every MSA-backed account.
        // Get-LocalGroupMember also throws outright on groups holding MSA or orphaned
        // SIDs, so fall back to the process token in that case.
        """
        $key = '\(publicKey.replacingOccurrences(of: "'", with: "''"))'

        $me = [Security.Principal.WindowsIdentity]::GetCurrent()
        $mySid = $me.User.Value
        $isAdmin = $null
        try {
            $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop
            $isAdmin = [bool]($admins | Where-Object { $_.SID.Value -eq $mySid })
        } catch {
            $isAdmin = $null
        }
        if ($null -eq $isAdmin) {
            $isAdmin = $me.Groups.Value -contains 'S-1-5-32-544'
        }

        if ($isAdmin) {
            $file = 'C:\\ProgramData\\ssh\\administrators_authorized_keys'
            $dir = Split-Path $file -Parent
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file | Out-Null }
            $existing = Get-Content $file -ErrorAction SilentlyContinue
            if ($existing -notcontains $key) { Add-Content -Path $file -Value $key }
            # sshd refuses this file unless only Administrators and SYSTEM can write it.
            icacls $file /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
        } else {
            $dir = Join-Path $env:USERPROFILE '.ssh'
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $file = Join-Path $dir 'authorized_keys'
            if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file | Out-Null }
            $existing = Get-Content $file -ErrorAction SilentlyContinue
            if ($existing -notcontains $key) { Add-Content -Path $file -Value $key }
            icacls $file /inheritance:r /grant "$($env:USERNAME):F" | Out-Null
        }
        'ok:' + $file
        """
    }

    // Locate the .NET Framework C# compiler and report its FULL PATH, not a
    // yes/no. Windows PowerShell itself runs on that framework, so its own
    // runtime directory is where csc.exe lives — the most reliable answer, and
    // one that does not depend on %WINDIR% resolving to the place we expect
    // (which is exactly what a single hard-coded Test-Path got wrong). The fixed
    // path and a directory search are fallbacks. Whatever it finds is handed to
    // the compile step, so an unusual .NET location still builds.
    private static let preflightScript = """
    $csc = $null
    try {
        $rt = [System.Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
        $p = Join-Path $rt 'csc.exe'
        if (Test-Path $p) { $csc = $p }
    } catch {}
    if (-not $csc) {
        $p = Join-Path $env:WINDIR 'Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe'
        if (Test-Path $p) { $csc = $p }
    }
    if (-not $csc) {
        foreach ($base in @((Join-Path $env:WINDIR 'Microsoft.NET\\Framework64'), (Join-Path $env:WINDIR 'Microsoft.NET\\Framework'))) {
            if (Test-Path $base) {
                $f = Get-ChildItem -Path $base -Recurse -Filter csc.exe -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
                if ($f) { $csc = $f.FullName; break }
            }
        }
    }
    if ($csc) { "CSC=$csc" } else { "CSC=no" }
    $console = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId
    if ($null -ne $console) { "CONSOLE=$console" } else { "CONSOLE=none" }
    $sac = (Get-ItemProperty "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CI\\Policy" `
              -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
    if ($null -eq $sac) { "SAC=absent" } else { "SAC=$sac" }
    """

    /// Turns Smart App Control off.
    ///
    /// This is a ONE-WAY DOOR. Microsoft's documented behavior is that Smart
    /// App Control cannot be re-enabled once disabled without reinstalling
    /// Windows. Nothing here can put it back, so it is opt-in, defaulted off,
    /// and confirmed separately in the UI.
    ///
    /// It exists because the agent is compiled on the target by csc.exe and is
    /// therefore unsigned by construction, which is precisely what Smart App
    /// Control refuses to load. Signing the agent with a certificate that has
    /// real reputation is the better fix and the only one that scales to new
    /// machines without spending this door on each of them.
    private static let disableSacScript = """
    $k = "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CI\\Policy"
    $before = (Get-ItemProperty $k -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name VerifiedAndReputablePolicyState -Value 0 -Type DWord -Force
    $after = (Get-ItemProperty $k -Name VerifiedAndReputablePolicyState).VerifiedAndReputablePolicyState
    "SACWAS=$before"
    "SACNOW=$after"
    """

    /// Built from the compiler path the prerequisite check actually found, so a
    /// non-standard .NET location still compiles. `csc` is a Windows filesystem
    /// path from our own probe; empty falls back to the standard location.
    private static func compileScript(csc: String) -> String {
        let path = csc.isEmpty ? #"$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"# : csc
        return """
        $csc = "\(path)"
        $dir = Join-Path $env:USERPROFILE 'bezel'
        Get-Process BezelAgent -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 600
        & $csc /nologo /optimize+ /warn:4 /warnaserror /target:exe /out:"$dir\\BezelAgent.exe" "$dir\\BezelAgent.cs" 2>&1 | Out-String
        if (Test-Path "$dir\\BezelAgent.exe") { "COMPILED" } else { "COMPILE FAILED" }
        """
    }
}
