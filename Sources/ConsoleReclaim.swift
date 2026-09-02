import Foundation

/// Puts a Windows machine's interactive session back onto its own monitor.
///
/// Any remote-desktop connection *moves* the machine's session into the
/// connection: while it is up the physical panel shows the lock screen, and the
/// Bezel agent — which lives in that session — enumerates the virtual RDP
/// display instead of the real one, so DDC over the proxy stops working.
/// Disconnecting does not undo that. The session stays in `Disconnected` state
/// while an empty console session owns the monitor, and it takes `tscon` to
/// move it back.
///
/// `tscon` needs `SeTcbPrivilege`, which an elevated administrator token does
/// not carry — measured, not assumed — so the work runs from the SYSTEM
/// scheduled task `BezelReclaimConsole` that install-service.ps1 registers.
/// Everything here is the client half of that: start the task over ssh and find
/// out what it decided.
///
/// Two callers share this: Wake Console (which reclaims after making a session
/// exist) and the Control window (which reclaims after its own session ends).
enum ConsoleReclaim {

    enum Outcome: Equatable, Sendable {
        /// tscon moved the disconnected session to the console.
        case moved(from: Int?)
        /// The console was already showing a desktop; nothing to move.
        case alreadyActive
        /// The task ran and declined to move anything; the text is its reason.
        case notMoved(String)
        /// BezelReclaimConsole is not installed on that machine.
        case noTask
        /// The task started but wrote no verdict within its 30 s window.
        case noVerdict
        /// ssh could not run the task at all; the text is what it printed.
        case unreachable(String)
    }

    /// Runs BezelReclaimConsole on `host` and waits for its verdict.
    ///
    /// Blocking network work — up to ~40 s — so it is `nonisolated` and safe to
    /// await from the main actor or anywhere else.
    ///
    /// - Parameter expecting: the session the caller meant to put back, when it
    ///   knows. The task picks its own target — the first disconnected user
    ///   session it enumerates — and on a machine where two people are signed in
    ///   and both disconnected that need not be the agent's session at all: it
    ///   would put a stranger's desktop on the panel and report success while
    ///   the agent stayed blind. There is no way to tell the task which session
    ///   to take (`schtasks /run` carries no arguments), so the check happens
    ///   here: a move of anything other than the session asked for is not a
    ///   heal, and saying so is what stops the caller treating it as one.
    ///   Pass nil — Wake Console does — to accept whatever it moved.
    nonisolated static func reclaim(host: String, expecting sessionID: Int? = nil) async -> Outcome {
        // `schtasks /run` returns the moment the task is QUEUED, so its exit
        // status says nothing about tscon. The agent appends one JSON line to
        // bezel\reclaim.log beside itself when it finishes — "moved" and a
        // reason — so: note the file's size, start the task, wait for the
        // file to grow, and read that line. Reading without waiting would
        // report the PREVIOUS run's verdict as this one's.
        let script = """
        $log = "$HOME\\bezel\\reclaim.log"; \
        $before = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }; \
        schtasks /run /tn BezelReclaimConsole | Out-Null; \
        if ($LASTEXITCODE -ne 0) { 'NOTASK'; exit 0 }; \
        $grew = $false; \
        for ($i = 0; $i -lt 60; $i++) { \
            Start-Sleep -Milliseconds 500; \
            $len = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }; \
            if ($len -gt $before) { $grew = $true; break } \
        }; \
        if ($grew) { Get-Content $log -Tail 1 } else { 'NOVERDICT' }
        """
        let result = await run("/usr/bin/ssh",
                               ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                host, script])
        let verdict = result.output.split(separator: "\n").last.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard result.status == 0, !verdict.isEmpty else {
            return log(host, .unreachable(result.output))
        }

        switch verdict {
        case "NOTASK":
            return log(host, .noTask)
        case "NOVERDICT":
            return log(host, .noVerdict)
        default:
            // "<timestamp>  {json}" — the verdict is the object.
            let json = verdict.drop(while: { $0 != "{" })
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            let moved = object?["moved"] as? Bool ?? false
            let reason = object?["reason"] as? String ?? ""
            if moved {
                let from = object?["from"] as? Int
                // A `from` the caller did not ask for means the task moved
                // somebody else's session. It cannot be undone from here, but it
                // must not be reported as the link being back: the agent is
                // still off the console, and treating this as success would send
                // the caller on to re-list a machine that cannot see anything.
                // A missing `from` is not a mismatch — older agents that do not
                // report one are still trusted.
                if let want = sessionID, let got = from, got != want {
                    return log(host, .notMoved("it put session \(got) on the console, not the "
                                               + "agent's session \(want) — another signed-in "
                                               + "user is disconnected on that machine"))
                }
                return log(host, .moved(from: from))
            } else if reason == "console already active" {
                return log(host, .alreadyActive)
            } else {
                let tscon = object?["tscon"] as? String ?? ""
                return log(host, .notMoved(reason.isEmpty ? (tscon.isEmpty ? verdict : tscon) : reason))
            }
        }
    }

    /// One line per outcome, so a failure that nobody was watching for is still
    /// in the system log afterwards. Returns its argument so the call sites can
    /// log and return in one step.
    @discardableResult
    private nonisolated static func log(_ host: String, _ outcome: Outcome) -> Outcome {
        let text: String
        switch outcome {
        case .moved(let from):
            text = "moved session \(from.map(String.init) ?? "?") to the console"
        case .alreadyActive:  text = "the console was already showing a desktop"
        case .notMoved(let why): text = "not moved — \(why)"
        case .noTask:         text = "BezelReclaimConsole is not installed"
        case .noVerdict:      text = "the task reported nothing in 30 s"
        case .unreachable(let output): text = "could not run the task — \(output)"
        }
        NSLog("zBezel reclaim (%@): %@", host, text)
        return outcome
    }

    /// Run a command and collect everything it says. Shared with the other
    /// ssh-shaped work; blocking, so it goes off whatever actor called it.
    nonisolated static func run(_ path: String, _ arguments: [String]) async
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
