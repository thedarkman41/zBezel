# zBezel — Code Enforcement Audit

**Project:** `/Volumes/Faraday/Users/darkstar/Documents/GitHub/Bezel`
**Standard:** `/Volumes/Faraday/Users/darkstar/Documents/GitHub/standards/standards/code-enforcement.md`
**Date:** 2026-08-28
**Scope:** 20 Swift files, `Sources/ddc.c` / `ddc.h`, `Agent/BezelAgent.cs`, `Scripts/*.sh` — 6,246 lines total.

**Rating: Good, with two must-fix defects.** The security posture, IOKit resource discipline, and comment quality are genuinely above the rubric's bar. The transport has one real memory-safety bug and one real availability bug, and the project has none of the infrastructure the rubric's own workflow depends on.

**Honesty note on severity.** Sixteen findings follow. Six of them (ZBZ-001 through ZBZ-006) are real risk: memory safety, a permanent hang, silent failures, and a command that has already lost its error-recovery path. The other ten are mechanical — line counts, macro style, an unused parameter, and two defects that are unreachable from any current call site. They are listed because the rubric names them, not because they will bite you. Where a finding cannot actually be triggered today, the entry says so in its own words.

---

## Findings

### ZBZ-001 — Device-controlled length byte reads 65 bytes past the reply buffer
**Rule:** C-004 (Buffer Overflows) · **Severity: High** · **Real risk**
**File:** `Sources/ddc.c:268-273` (buffer declared :254, filled :258)

```c
uint8_t reply[64];                                          // :254
memset(reply, 0, sizeof(reply));                            // :256
IOReturn r = ddc_message(&b, payload, 3, reply, 39, &got);  // :258
...
int payloadLen = (reply[1] & 0x7F);                         // :268
int dataLen = payloadLen - 3;                               // :269
if (dataLen <= 0) break;                                    // :270

for (int i = 0; i < dataLen && written < outCapacity - 1; i++)
    out[written++] = (char)reply[5 + i];                    // :273
```

**Why it violates C-004.** `reply[]` is filled by the monitor through `IOI2CSendRequest` (`raw_xact`, :150), so `reply[1]` is device-supplied. Masked with `0x7F` it reaches 127, so `dataLen` reaches 124 and the loop indexes `reply[5]` through `reply[128]` on a 64-byte stack array — 65 bytes past the end. Nothing between :268 and :273 bounds `dataLen` against `sizeof(reply)`, against the 39 bytes actually requested, or against `got` — the byte count `raw_xact` returns at :151, which is written at :258 and then never read anywhere in the file. The only guards before the loop (:259) check the `IOReturn` and `reply[2] == 0xE3`; there is no checksum validation.

Because :256 zeroes all 64 bytes each iteration, everything read past index 63 is live adjacent stack — the `BezelBus` struct, saved registers, return-address material. Those bytes are copied into the caller's `out`, returned to `MonitorController.swift:852`, parsed by `Capabilities.parse`, rendered in the Advanced tab's "Capabilities String" card, and offered with a Copy button that writes them to `NSPasteboard`. When the remote agent path is in play they also leave the machine.

A monitor with firmware quirks, a truncated reply on a marginal AUX link, or a hostile device on the bus all reach this. `-Wall` does not catch it because the bound is a runtime value. This is CWE-125, and it is the class C-004 exists to prevent — the *write* side is correctly bounded by `outCapacity`, the *read* side is not bounded at all.

**Fix.** Clamp against both the buffer and the bytes actually received, before the copy:

```c
int payloadLen = (reply[1] & 0x7F);
int dataLen = payloadLen - 3;
if (dataLen <= 0) break;

// reply[1] is device-supplied; never let it drive a read past the buffer.
// Fragment layout: 5 header bytes + data + 1 checksum.
int maxFragment = (int)sizeof(reply) - 6;
if (got >= 6 && (int)got - 6 < maxFragment) maxFragment = (int)got - 6;
if (dataLen > maxFragment) dataLen = maxFragment;
if (dataLen <= 0) break;
```

Behaviour is unchanged for any well-formed reply: a compliant fragment answering a 39-byte request has `payloadLen <= 36`, so the clamp never fires in the normal case. Validating the DDC checksum at `reply[payloadLen + 2]` before trusting the frame would be the stronger fix.

---

### ZBZ-002 — Actor-isolated subprocess wait has no timeout; the `timeout:` parameter is dead code
**Rule:** SWIFT-004 (Concurrency), applied in spirit — see the coverage note · **Severity: High** · **Real risk**
**File:** `Sources/RemoteAgent.swift:83-108`

```swift
private func run(_ agentArgs: [String], timeout: TimeInterval = 30) throws -> [String: Any] {   // :83
    ...
    // Read before waiting, so a large reply cannot fill the pipe and deadlock.   // :105
    let data = out.fileHandleForReading.readDataToEndOfFile()                     // :106
    let errorData = err.fileHandleForReading.readDataToEndOfFile()                // :107
    process.waitUntilExit()                                                       // :108
}
```

**Why.** `run` is a synchronous, indefinitely blocking function on `actor RemoteAgent` (:54). The `timeout:` parameter is never referenced in the body — a project-wide grep finds "timeout" only at the declaration and the call sites. Five callers pass an explicit value (45 at :154, 60 at :164, 180 at :192, 90 at :211, 30 at :230) and two more, `health()` and `list()`, take the unenforced default. No watchdog, timer, or cancellation enforces any of them.

`readDataToEndOfFile()` and `waitUntilExit()` block until ssh exits. The invocation uses `ControlMaster`/`ControlPersist=600` (:92-94), and `ConnectTimeout=10` bounds only the establishment of a *new* connection — so a stale master socket or a black-holed TCP connection hangs with no bound at all.

Because this is an actor method, the blocked call holds the actor's serial executor. Every call site in `MonitorController.swift` (173, 546, 558, 564, 635, 770, 791, 806) reaches it through `await agent.<method>`, so every subsequent read, write, capabilities and disconnect call queues behind the hang indefinitely: all monitor control through the proxy dies until the app is relaunched. It also parks a cooperative-pool thread. `readSubSelectorMap` (:189) makes it concrete — 120 samples in one invocation, nominally allowed 180 seconds, actually allowed forever.

**Second, independent block in the same function.** The comment at :105 does not do what it claims. stdout is drained to EOF first, *then* stderr. If ssh writes more than the pipe buffer (~64KB) to stderr while stdout is still open, the child blocks writing stderr, stdout never reaches EOF, and :106 hangs. The 120-sample call is the most likely producer of that volume.

**Rule-coverage note, stated plainly.** SWIFT-004's letter targets "completion handlers or Grand Central Dispatch (GCD) blocks," and this file contains neither — it already uses `actor`. The citation rests on the rule's mandate to model asynchronous work with async/await; blocking a thread on subprocess I/O is that failure, and SWIFT-004 is the standard's only concurrency rule. Cite it as a spirit-level violation, not a literal one. The defect is real regardless of which rule ID it lands under.

**Fix.**
- Mark the subprocess helper `nonisolated` and `async` so the actor's executor is released while ssh runs.
- Drain stdout and stderr concurrently (two child `Task`s, or `readabilityHandler` on both pipes), then await exit.
- Enforce `timeout` with a race: the process in one child task, `Task.sleep(for: .seconds(timeout))` in another; the loser is cancelled. On expiry, kill the process and throw `RemoteAgentError(message: "\(config.host) did not respond within \(Int(timeout))s")`.
- **Guard the kill for SWIFT-005:** `Process.terminate()` raises `NSInvalidArgumentException` — not a catchable Swift error — on a process never launched or already exited. Write `if process.isRunning { process.terminate() }`. If you build the timeout with `withTaskCancellationHandler`, note that `onCancel` runs synchronously at installation time when the Task is already cancelled, so it must check an explicit "launched" flag before touching `process`.
- Apply the same treatment to `disconnect()` (:240-248), which has the identical unbounded `waitUntilExit()` on the actor.

Callers already `try`, so a thrown timeout surfaces as `lastError` with no other change. **If any of this is deferred, delete the `timeout:` parameter** rather than leaving it in place — as written it documents a guarantee the code does not provide.

---

### ZBZ-003 — SSH disconnect discards its launch error, leaving an unguarded unlaunched Process
**Rule:** SWIFT-005, with *Error Handling & Resilience — No Silent Failures* · **Severity: Medium** · **Real risk**
**File:** `Sources/RemoteAgent.swift:246-247`

```swift
try? process.run()
process.waitUntilExit()
```

**Why.** `disconnect()` runs `ssh -O exit` to drop the shared ControlMaster, but `try?` throws the launch error away and the function returns `Void`, so a failed teardown is indistinguishable from a successful one. Its only caller, `MonitorController.reconnectProxy()` (`MonitorController.swift:805-808`), calls `await agent.disconnect()` and then unconditionally `await probe()` — so when the launch fails the stale ControlMaster socket survives and the next probe goes out over it, with nothing logged and nothing surfaced. That is the No Silent Failures violation, and it is live today. It is also the precise condition that makes ZBZ-002's unbounded hang reachable.

The SWIFT-005 dimension is the unchecked precondition it leaves behind. I verified on this macOS that `waitUntilExit()` itself tolerates an unlaunched `Process` and returns — so :247 does not abort as written. But `terminationStatus` on that same object raises `NSInvalidArgumentException: *** -[NSConcreteTask terminationStatus]: task not launched` and kills the process with SIGABRT (exit 134). A raised `NSException` is not a Swift `Error`, so no `do`/`catch` upstream can contain it. SWIFT-005 requires the launch precondition to be checked before the call rather than relying on which `Process` member happens to be tolerant — so the natural next edit (adding `if process.terminationStatus != 0` to find out whether the disconnect worked) turns a silent failure into a whole-app crash.

**Fix.** Handle the launch error, matching `AgentInstaller.execute` (`AgentInstaller.swift:427-434`), which already does this correctly:

```swift
do {
    try process.run()
} catch {
    NSLog("Bezel: could not run ssh -O exit for \(config.host): \(error.localizedDescription)")
    return
}
process.waitUntilExit()
```

The early return guarantees no later code reaches `terminationStatus` on an unlaunched task. If `disconnect()` should *report* failure rather than log it, make it `throws` and let `reconnectProxy()` decide whether to proceed to `probe()`.

---

### ZBZ-004 — Failed known_hosts write still arms `StrictHostKeyChecking=yes` against a missing file
**Rule:** *Error Handling & Resilience — No Silent Failures* · **Severity: Medium** · **Real risk**
**File:** `Sources/AgentInstaller.swift:119-124`

```swift
if case .password = auth, hostKeyApproved, let keys = scannedHostKeys {
    let file = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("zbezel-known-" + UUID().uuidString)
    try? keys.write(to: file, atomically: true, encoding: .utf8)
    knownHostsFile = file
}
```

**Why.** The write is `try?` and its result is ignored, but `knownHostsFile` is set unconditionally. `sshOptions` (:332-334) then reacts to the non-nil value by adding `UserKnownHostsFile=<path>` together with `StrictHostKeyChecking=yes`. If the write failed — a full or read-only temp directory, a sandbox denial — ssh is pinned to a file that does not exist, so every subsequent authentication fails with a host-key error immediately after the user has just approved the fingerprint on screen. The `humanise()` helper then reports "The machine's SSH host key changed since last time", which is actively wrong and sends the user to edit `~/.ssh/known_hosts` for no reason. The rubric forbids discarding errors precisely because the failure resurfaces later as a misleading one.

**Fix.**

```swift
do {
    try keys.write(to: file, atomically: true, encoding: .utf8)
    knownHostsFile = file
} catch {
    throw InstallError(message: "Could not record the approved host key: \(error.localizedDescription)")
}
```

Failing here is correct and safe: nothing has been sent to the remote machine yet, and the alternative is sending a password under a host-key policy that cannot succeed. The similar `try?` at :399 is acceptable as-is because :408 has a genuine fallback path.

---

### ZBZ-005 — The command dispatch switch exists three times, and the copies have diverged
**Rule:** *Architecture & Design — DRY* · **Severity: Medium** · **Real risk (correctness, not just readability)**
**File:** `Agent/BezelAgent.cs:619-625`, duplicating `589-602`, which duplicates `303-311`

```csharp
switch (args[0].ToLowerInvariant())          // :619 — the retry copy
{
    case "caps":  CmdCaps(fresh, args);  break;
    case "get":   CmdGet(fresh, args);   break;
    case "set":   CmdSet(fresh, args);   break;
    case "probe": CmdProbe(fresh, args); break;
}                                            // no "setget", no default
```

**Why.** This is the DRY violation that has already cost correctness. Two distinct consequences, both verified:

1. **`setget` is unreachable from the CLI.** `Main`'s switch (:303-311) handles `list`/`caps`/`get`/`set`/`probe`; `Dispatch`'s (:589-602) additionally handles `health` and `setget`. So `BezelAgent setget 0 E1 1234 10 12` run directly on the Windows box answers `{"ok":false,"error":"unknown command: setget"}` even though the command is fully implemented at :421. That is the only way to test or diagnose a sub-addressed write without the service running, and it is the CLI surface the header comment at :10-14 documents (which also omits `setget`).

2. **`setget` silently loses the stale-handle retry.** The retry block exists because cached physical-monitor handles go stale after a hotplug (comment, :609-610) and fires when every read failed (:611). The third copy omits `setget`, and has no `default`, so a `setget` whose reads all failed writes nothing to `retryOut`, `retried.Length > 0` is false at :630, and the caller is handed the original all-failed response as if no retry were possible. The command that loses the retry is exactly the one most likely to need it: `setget`'s own documentation (:417-419) and the enumeration comment (:156-159) say changing a setting such as DisplayPort version makes the panel re-enumerate — that *is* the hotplug that invalidates the handles. Concretely: the Mac sends `setget 0 E1 ... DF 60`, the panel re-enumerates on the write, every read-back fails, and the UI shows a dead monitor until some later command happens to refresh the cache — while the same sequence issued as `set` then `get` recovers on the first try.

The third copy also omits `list` and `health`, which is harmless, so the omission is invisible to inspection.

**Fix.** Collapse all three into one method:

```csharp
private static void RunCommand(List<Target> targets, string[] args)
{
    switch (args[0].ToLowerInvariant())
    {
        case "health": Console.WriteLine("{\"ok\":true,\"monitors\":" + targets.Count + ","
                                          + LinkFields(targets.Count) + "}"); break;
        case "list":   CmdList(targets);         break;
        case "caps":   CmdCaps(targets, args);   break;
        case "get":    CmdGet(targets, args);    break;
        case "setget": CmdSetGet(targets, args); break;
        case "set":    CmdSet(targets, args);    break;
        case "probe":  CmdProbe(targets, args);  break;
        default:       Console.WriteLine("{\"ok\":false,\"error\":\"unknown command\"}"); break;
    }
}
```

`Dispatch` calls `RunCommand(Targets(refresh: false), args)` at :588 and `RunCommand(Targets(refresh: true), args)` at :618. `Main` keeps its own switch only for the process-exit-code cases (`serve`/`client`/`relay`) and otherwise delegates. One dispatch table, so a new command cannot be added to two of three places again. Update the usage comment at :10-14 in the same pass.

---

### ZBZ-006 — Three catch blocks swallow the exception; the retry path's is completely bare
**Rule:** *Error Handling & Resilience — No Silent Failures* · **Severity: Medium** · **Real risk (diagnosability)**
**File:** `Agent/BezelAgent.cs:627`, also `570-573` and `104`

```csharp
catch { }                                             // :627, Dispatch retry

catch (Exception)                                     // :570
{
    // One bad connection must not take the service down.
}

catch { /* nothing useful to do at teardown */ }      // :104, ReleaseAll
```

**Why.** The rule is absolute: no empty catch blocks, every exception logged or re-thrown.

`:627` is the damaging one. It closes the `try` at :616 that wraps the stale-handle re-enumeration (`Targets(refresh: true)`) and the four re-dispatches at :618-625. If any of that throws — a monitor mid-hotplug, dxva2 returning garbage, an index that no longer exists after the display count changed — the exception vanishes, `retryOut` stays empty, the :630 guard is false, and :633 returns the original failing response. The operator sees the same failure twice with no signal that the *recovery attempt itself* broke, which is exactly the failure mode the retry was written to diagnose.

`:570` correctly keeps the service alive, but the exception is not even bound to a name. Dispatch faults are already handled by the inner catch at :564, which returns them to the client as JSON — so what :570 actually swallows is the transport layer: `AcceptTcpClient` failures, `GetStream`, `ReadLine` socket resets and timeouts, `Flush` against a closed socket. The agent runs unattended in a logon task on a machine nobody is watching, so a persistent fault presents as "the proxy answers nothing" with no evidence on either side of the SSH link. Worse, a durable listener failure makes `AcceptTcpClient` throw on every iteration, turning the `while (true)` at :548 into a silent hot spin that burns a core while still looking alive.

`:104` is the most defensible, but `DestroyPhysicalMonitors` failing is the one signal that the handle bookkeeping is wrong, and silently leaked handles are the exact thing the comment at :95-96 says the list exists to prevent.

**Fix.** Keep the swallow, add a record. `Console.Error` is not redirected during `Dispatch` (only `Console.Out` is, at :584), and in serve mode stderr is captured by the scheduled task's redirect in `run-agent.ps1`:

```csharp
catch (Exception e) { Console.Error.WriteLine("[retry] re-enumeration failed: " + e); }   // :627
catch (Exception e) { Console.Error.WriteLine("[serve] connection failed: " + e);         // :570
                      Console.Error.Flush(); }
catch (Exception e) { Console.Error.WriteLine("[teardown] DestroyPhysicalMonitors: " + e.Message); } // :104
```

Control flow and observable behaviour are unchanged. At :570, also add a consecutive-failure counter around the accept so a persistent listener fault backs off or exits rather than spinning silently.

---

### ZBZ-007 — CS-004 is unreachable with the pinned compiler, and the half that *is* reachable is simply absent
**Rule:** CS-004 (Nullable Reference Types) · **Severity: Medium** · **Half mechanical, half a documented-trade-off gap**
**Files:** `Scripts/deploy-agent.sh:12,28` and `Sources/AgentInstaller.swift:547-553`

```bash
CSC='C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'                      # :12
& '$CSC' /nologo /optimize+ /target:exe /out:\"\$HOME\\bezel\\BezelAgent.exe\" ...  # :28
```

```swift
private static let compileScript = """
$csc = "$env:WINDIR\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe"
...
& $csc /nologo /optimize+ /target:exe /out:"$dir\\BezelAgent.exe" "$dir\\BezelAgent.cs" 2>&1 | Out-String
"""
```

**Why.** CS-004 requires `<Nullable>enable</Nullable>` in a project file and warnings treated as errors. There is no project file — the agent is compiled by these two direct `csc.exe` invocations — so the rule is unmet. But adding a `.csproj` alone would not fix it: `Framework64\v4.0.30319\csc.exe` is the legacy pre-Roslyn compiler, which tops out at C# 5. Nullable reference types are C# 8. No flag, no `#nullable` directive and no project file can turn them on with this binary. That is visible in the source, which reads accordingly — out-variables pre-declared at :366, no string interpolation, no pattern matching.

So **half of CS-004 is unreachable with the toolchain as chosen, not merely unconfigured**, and that choice is deliberate and well-argued: the installer's whole premise (`AgentInstaller.swift:5-9`) is that a clean Windows box needs no downloads. The half that *is* reachable has been left off for no reason — neither invocation sets `/warn` or `/warnaserror`, so the build is silent about every diagnostic short of an error.

The code is null-careful by hand (`Esc` guards `s == null` at :236, both `ReadLine()` results are checked at :559-560 and :660-661, `targetsCache` is guarded at :213, `Pick` range-checks before indexing at :227), but nothing verifies that at compile time, and `private static List<Target> targetsCache;` (:203) is exactly the shape CS-004 exists to annotate.

**Fix — two parts, and be explicit in the repo about which is which.**

*Achievable now, costs nothing:* add `/warn:4 /warnaserror` to both invocations (`deploy-agent.sh:28` and `AgentInstaller.swift:552`).

*Not achievable with this toolchain:* record in `README.md` that CS-004's nullable requirement is knowingly waived because the agent targets the in-box .NET Framework compiler for zero-dependency install, and that adopting it would mean shipping or requiring a Roslyn/.NET SDK on the target machine. If that trade is ever revisited, a minimal `net48` SDK-style project restores the whole rule:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net48</TargetFramework>
    <Nullable>enable</Nullable>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  </PropertyGroup>
</Project>
```

An unmet rule with a written reason is auditable. An unmet rule with no reason is a defect.

---

### ZBZ-008 — No test suite, no linter config: two of the four workflow steps cannot be run
**Rule:** *Enforcement Workflow* steps 2 and 4 + *Strict Constraints & Guardrails* (section 4) · **Severity: Medium**
**File:** `Scripts/build-app.sh:16-23`

```bash
clang -c -O2 -Wall -o "$OBJ/ddc.o" "$REPO/Sources/ddc.c"          # :16

swiftc -O -parse-as-library \                                     # :18
  -import-objc-header "$REPO/Sources/Bridging.h" \
  -o "$BIN/zBezel" \
  "$REPO"/Sources/*.swift \
  "$OBJ/ddc.o" \
  -framework IOKit -framework CoreGraphics -framework AppKit -framework SwiftUI   # :23
```

See the *Missing Infrastructure* section below for the full treatment. In short: verified by a find across the whole tree, the repo contains no `Package.swift`, no `.csproj`, no `.swiftlint.yml`, no `.github/` directory, and no test file of any kind. Step 2 has nothing to run for Swift, C or C# — the rubric's command table covers Node, Python, Go and Rust only. Step 4 and section 4's "ALWAYS run the test suite" cannot be satisfied by anyone, human or agent. I am reporting this rather than claiming a command exists.

---

### ZBZ-009 — `AgentInstaller.run` is 137 lines against the rubric's 40-50 line ceiling
**Rule:** *Architecture & Design — SRP* · **Severity: Low** · **Mechanical**
**File:** `Sources/AgentInstaller.swift:97-233`

```swift
private func run(target: Target, auth: Auth, hostKeyApproved: Bool) async throws {
    ... 8 inline step closures, host-key approval gating, known-hosts staging,
        preflight output parsing, JSON parsing of the agent's monitor list ...
}
```

**Why.** 137 lines, roughly 3× the ceiling, holding at least four responsibilities: install sequencing across eight inline step closures (`step(0)` at :107 through `step(7)` at :212), the host-key approval gate and known-hosts staging (:113-124), ad-hoc parsing of the preflight report (:159-166), and JSON parsing plus validation of the agent's reply (:216-231). The remote PowerShell payloads have already been extracted to named statics under the "Remote scripts" MARK at :522 — the right instinct; the Swift-side bodies have not followed.

**Fix.** Extract the two parsing blocks first — they are pure functions over a `String` already returned by `remotePowerShell`, with no SSH or IOKit dependency, so extracting them is the only way any of this becomes testable at all (see ZBZ-008):

```swift
private struct PreflightReport { let hasCSC: Bool; let consoleSession: String? }
static func parsePreflight(_ report: String) -> PreflightReport
static func parseMonitorList(_ output: String) throws -> [String]
```

Then lift each step body into its own private method (`verifyLogin`, `installPublicKey`, `checkPrerequisites`, `copyPayload`, `compileAgent`, `registerLogonTask`, `verifyMonitorVisible`) and move the host-key gate into `resolveHostKey(auth:approved:)` returning the onward `Auth`. That brings `run` to roughly 25-30 lines of ordered calls. Message text and step ordering stay byte-identical.

---

### ZBZ-010 — `bezel_diagnose` is 84 lines running four numbered probes plus bus setup inline
**Rule:** *Architecture & Design — SRP* · **Severity: Low** · **Mechanical**
**File:** `Sources/ddc.c:306-389`

```c
int32_t bezel_diagnose(uint32_t displayID, BezelLinkReport *out) {   // :306
    ...
    uint8_t buf[32];                                                  // :321
    // 1. Can we read the EDID over I2C-over-AUX? ...                 :323
    // 2. Does anything ACK the DDC/CI address? ...                   :334
    // 3. Full DDC/CI round trip ...                                  :350
    // 4. DPCD — identifies who is actually terminating the AUX channel.  :356
}                                                                     // :389
```

**Why.** 84 lines against the 40-50 line threshold, carrying five responsibilities: bus setup and bus-property capture (:310-319), then EDID readability (:323-332), DDC/CI address ACK via the null message (:334-348), a full round trip on VCP 0xDF (:350-354), and DPCD identity — itself five reads at 0x00000, 0x00021, 0x00111, 0x00400 and 0x00500 (:356-385). The author has already recognised the seams: the probes are numbered in comments and two are wrapped in bare braces at :324 and :338 specifically to scope their locals. The structure is present, just not expressed as functions. The cost is testability — each probe is a self-contained question against an already-open bus, and none can be exercised in isolation.

**Not a defect:** the shared uninitialised `buf` at :321 is a symptom of the loose scoping, not a bug. Every read of it is short-circuit-guarded on the transaction succeeding (:329, :357, :365, :367, :370, :377), so stale bytes from a shorter read are never consumed.

**Fix.** Extract `probe_edid`, `probe_ddc_address_ack`, `probe_ddc_roundtrip`, `probe_dpcd_identity`, each `static void f(BezelBus *b, BezelLinkReport *out)` with its own local buffer — a mechanical move, since each already has its own brace scope and writes only to `out`. `bezel_diagnose` then reads as argument validation, `bus_open`, bus-property capture, four calls with the existing `usleep` pacing, `bus_close`: about 20 lines.

---

### ZBZ-011 — GCD `DispatchWorkItem` used for a cancellable delay instead of a `Task`
**Rule:** SWIFT-004 · **Severity: Low** · **Mechanical**
**File:** `Sources/AppDelegate.swift:104-106` (same shape at `Sources/WindowPlacement.swift:15`)

```swift
let work = DispatchWorkItem { [weak self] in self?.statusItem?.button?.title = "" }
titleResetWork = work
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
```

**Why.** This is a cancel-and-reschedule timer — the exact shape `Task` + `Task.sleep` expresses natively — and unlike the C-transport bridges in `MonitorController` there is no blocking call being hosted, so there is no reason to reach for a queue. The class is already `@MainActor` and already uses `Task` at :43, :46, :58 and :81, so this is the odd one out. A genuine letter-and-spirit SWIFT-004 hit, and a trivial one.

**Fix.**

```swift
private var titleResetTask: Task<Void, Never>?

private func flash(_ text: String) {
    titleResetTask?.cancel()
    statusItem?.button?.title = text
    titleResetTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        self?.statusItem?.button?.title = ""
    }
}
```

Cancellation semantics are identical. For `WindowPlacement.swift:15`, `Task { @MainActor in … }` replaces the async hop with the same next-turn timing.

---

### ZBZ-012 — The local DDC transport has no serialization, unlike the proxy path which is an actor
**Rule:** SWIFT-004 (the actor clause) · **Severity: Low** · **Latent hazard, not a reproduced bug**
**File:** `Sources/MonitorController.swift:838-876`

**This is deliberately narrow, and it is not the finding the GCD hop invites.** The `DispatchQueue.global` bridges themselves are correct and I would not change them — see *Clean areas* for the reasoning. What *does* violate SWIFT-004's spirit is that these four entry points give the I2C bus no serialization. Each independently runs `bus_open → IOFBCopyI2CInterfaceForBus → transact → bus_close` on the same framebuffer. `@MainActor` does not prevent overlap, because every caller suspends at an `await`: a menu-bar click running `cycleInput → reread` can interleave with an open window's slider drag running `setLive → writeRaw`, putting two `IOI2CSendRequest` transactions on one bus concurrently. The proxy path solves exactly this by making `RemoteAgent` an `actor`; the local path is the inconsistent half.

The existing guards are thinner than they look. `inFlight` (:701) is keyed per VCP code, so it only coalesces repeat writes of the *same* code — it does not stop a brightness write (0x10) overlapping an input-select read (0x60). And `isProbing`/`isRefreshing`/`isBusyWriting` are applied only in `refreshVisible()` (:425); neither `cycleInput()` (:392) nor `setLive()` (:697) takes them.

I have not observed a failure from this, so it is a latent hazard, honestly labelled.

**Fix.** A serializing actor, bodies unchanged:

```swift
actor LocalDDC {
    static let shared = LocalDDC()
    func readFeature(_ id: CGDirectDisplayID, _ code: UInt8) async -> (current: UInt16, maximum: UInt16)? {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async { /* existing body */ }
        }
    }
    // diagnose, readCapabilities, writeFeature likewise
}
```

Call sites become `await LocalDDC.shared.readFeature(id, code)`. The actor guarantees one bus transaction at a time; the GCD hop stays, because the C call is still blocking.

---

### ZBZ-013 — Parameter named `expected` is never compared to anything
**Rule:** *Naming & Readability* (section 2) · **Severity: Low** · **Mechanical**
**File:** `Sources/MonitorController.swift:751`

```swift
private func confirmInputAfterSettling(expected: UInt16) {
    Task<Void, Never> { [weak self] in
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        guard let self else { return }
        _ = await self.reread(codes: [VCP.inputSelect.code])
    }
}
```

**Why.** `expected` appears exactly twice in `Sources/` — this declaration and the call site at :647 — and none of the four statements in the body touches it. The name, and the doc comment above it ("in case the monitor ended up somewhere other than where it was sent"), both promise a comparison that does not happen, so a reader debugging an input switch will believe a check exists. Swift does not warn on unused function parameters, so no tool flags it.

**Scope note:** the settling re-read itself is not broken. `reread` (:777) assigns `features[code]?.current` from the monitor on both the local and proxy paths, so the comment's promise is honored by that side effect. The `_ =` discards only the returned dictionary. The defect is confined to the parameter.

**Fix.** Either delete the parameter (and update :647), or make the name true — which is the better option here, since the doc comment names a real failure mode and surfacing it costs one comparison on a value already in hand:

```swift
let readings = await self.reread(codes: [VCP.inputSelect.code])
if let actual = readings[VCP.inputSelect.code], actual != expected {
    self.lastError = String(format: "Input settled on 0x%02X, not the requested 0x%02X", actual, expected)
}
```

That second form changes observable behaviour (it can now set `lastError`), so take the first if that message is not wanted.

**Same class, verified:** `Sources/VendorViews.swift:82` — `@State private var assigning: VendorChange?` is the only occurrence of `assigning` in `Sources/`; never read, never written. Delete it.

---

### ZBZ-014 — Bus addresses, the timing helper, and the public result codes are `#define` macros
**Rule:** C-002 (Macros vs. Constants) · **Severity: Low** · **Mechanical**
**File:** `Sources/ddc.c:24-30` and `Sources/ddc.h:13-20`

```c
#define DDC_WRITE_ADDR   0x6E      // ddc.c:24
#define DDC_READ_ADDR    0x6F
#define DDC_SOURCE_ADDR  0x51
#define EDID_WRITE_ADDR  0xA0
#define EDID_READ_ADDR   0xA1
#define MS(x) ((uint64_t)(x) * 1000000ULL)   // :30

#define BEZEL_OK               0    // ddc.h:13
#define BEZEL_UNSUPPORTED      1
#define BEZEL_ERR_NO_FB       -1    // ... through :20
```

**Why.** C-002 asks for `const` variables and `inline` functions over `#define`. The address macros are untyped literals flowing into `raw_xact`'s `uint32_t` parameters and into the checksum arithmetic at :166. `MS(x)` is a function-shaped macro — correctly parenthesised, so no expansion hazard, but exactly the case the rule names. The header's result codes matter most: they are the library's public contract, consumed from Swift (`rc == BEZEL_OK`), and as bare `#define`s they arrive in Swift as loose `Int32` globals with no enum type to switch over exhaustively, so a new error code cannot be caught at the call sites. No runtime defect today.

**Fix.** In `ddc.c`: `static const uint32_t kDDCWriteAddr = 0x6E;` and siblings, plus `static inline uint64_t milliseconds_to_ns(uint32_t ms) { return (uint64_t)ms * 1000000ULL; }`. In `ddc.h`, make the result codes an `enum BezelResult` so both languages get a type. Function signatures keep returning `int32_t`, names stay identical, every existing comparison keeps compiling.

---

### ZBZ-015 — `ddc_message`'s frame-size guard can be defeated by unsigned overflow
**Rule:** C-004 · **Severity: Low** · **Not reachable today — stated plainly**
**File:** `Sources/ddc.c:158-163`

```c
uint8_t frame[40];
if (payloadLen + 3 > sizeof(frame)) return kIOReturnBadArgument;

frame[0] = DDC_SOURCE_ADDR;
frame[1] = (uint8_t)(0x80 | payloadLen);
memcpy(&frame[2], payload, payloadLen);
```

**Why.** `payloadLen` is `uint32_t` (:156), so `payloadLen + 3` is evaluated in 32-bit unsigned arithmetic and wraps *before* being widened to `size_t` for the comparison. A `payloadLen` of `0xFFFFFFFD..0xFFFFFFFF` yields 0..2, passes a guard whose entire purpose is to reject it, and reaches `memcpy` with a ~4GB length against a 40-byte stack buffer. The same wrapping expression recurs at :167, :168 and :171.

**Reachability, honestly:** not reachable. `ddc_message` is `static` with exactly three callers, all passing literals — 2 at :197, 4 at :232, 3 at :258. No input path reaches it. It is worth the one-line fix anyway because this check is the function's only defence and it reads as sound; the narrowing cast at :162 already documents that the real domain is a single byte.

**Fix.** Move the constant to the other side so the subtraction happens in `size_t`:

```c
if (payloadLen > sizeof(frame) - 3) return kIOReturnBadArgument;
```

`sizeof(frame) - 3` is a compile-time constant 37, and `payloadLen` widens for the comparison. This transitively bounds :167, :168 and :171. Better still, change the parameter to `uint8_t` to match the DDC/CI length field it is written into.

---

### ZBZ-016 — `IOServiceMatching`'s allocation is passed on without a NULL check
**Rule:** C-001 (Memory Management) · **Severity: Low** · **Mechanical; mild consequence**
**File:** `Sources/ddc.c:75-76`

```c
io_iterator_t it;
if (IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching("IOFramebuffer"), &it) != KERN_SUCCESS) return 0;
```

**Why.** C-001 requires checking every allocation for NULL. `IOServiceMatching` creates a `CFMutableDictionary` and can return NULL under memory pressure; the result goes straight into `IOServiceGetMatchingServices` unexamined. The consequence is mild — the callee rejects NULL with an error rather than dereferencing it, so the existing `!= KERN_SUCCESS` test happens to contain the failure, and no reference leaks because the callee consumes it either way. It is still an unchecked allocation on the one path every public entry point in this file depends on, and the failure it produces (`BEZEL_ERR_NO_FB`, "no monitor found") is indistinguishable from an unplugged display — a bad diagnostic for an app whose whole purpose is diagnosing why a monitor is unreachable. Contrast `number_prop` at :37-38, which checks its Create call correctly.

**Fix.**

```c
CFMutableDictionaryRef matching = IOServiceMatching("IOFramebuffer");
if (!matching) return 0;
io_iterator_t it = IO_OBJECT_NULL;
if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) != KERN_SUCCESS) return 0;
```

Initialising `it` at declaration also satisfies C-003's spirit for the out-parameter.

---

## Missing Infrastructure

The rubric's own workflow depends on tooling this project does not have. Verified by a `find` across the whole tree excluding `.git`: the repo is `Agent/`, `Scripts/`, `Sources/`, `docs/`, `README.md`, `.gitignore` — and `build/` output. There is **no `Package.swift`, no `.xcodeproj`, no `.csproj`, no `.swiftlint.yml`, no `.swift-format`, no `.github/` directory, and no test file of any kind.**

**Step 2 — Deterministic Linting — has nothing to run.** The rubric's command table (section 1) covers Node/TypeScript, Python, Go and Rust. This project is Swift + C + C#. No entry applies, and no linter or formatter is configured for any of the three. The instruction "YOU MUST run the project's configured linters and formatters first" is unexecutable here, not merely skipped.

**Step 4 — Verification — and section 4's "ALWAYS run the test suite" — are impossible to satisfy.** Section 4 names `swift test` among its examples, which requires the `Package.swift` this repo does not have. There is consequently no way to prove a refactor preserved behaviour. That matters more than usual here, because the code drives hardware whose responses cannot be reproduced without the monitor attached — and because the two most fragile parsers in the project take adversarial device input.

**CS-004's project-file requirement has no project file to live in.** Covered as ZBZ-007. The nullable half is additionally blocked by the pinned pre-Roslyn compiler, which is a defensible trade that should be written down rather than left implicit.

**The one gate that does exist is weaker than it looks.** `clang -Wall` with no `-Wextra` and no `-Werror` (`build-app.sh:16`); `swiftc` with no `-warnings-as-errors` (:18-23); `csc.exe` with no `/warn` and no `/warnaserror` (`deploy-agent.sh:28`). Warnings are advisory across all three toolchains, in scripts that otherwise run under `set -euo pipefail`.

**Recommended, in increasing cost:**

1. Add `-Werror` to the clang line and `-warnings-as-errors` to the swiftc line, and `/warn:4 /warnaserror` to both csc invocations. The compilers become the missing linter. *(For C#, this is required by CS-004. For clang and swiftc the rubric mandates nothing of the sort — it is sound practice offered as a recommendation, not a finding.)*
2. Add `clang --analyze -Xanalyzer -analyzer-output=text "$REPO/Sources/ddc.c"` before the compile. One line, no new dependency, and it covers the buffer-indexing class the C lens is about.
3. Add a `Package.swift` with a library target for the pure-logic files — `EDID`, `Capabilities`, `VCP`, `HPProfile`, `VendorMapping`, `LinkReport` — plus a test target, so `swift test` exists. The app bundle build can keep using `build-app.sh` unchanged.
4. Add a `.swiftlint.yml` and a lint step guarded by `command -v swiftlint`.

**Do not expect (1) or (2) to have caught ZBZ-001.** That index is a runtime value, so no warning flag catches it, and a static analyser would have to constrain a symbolic value written by an opaque IOKit transaction — possible, not something to count on. What catches it is the bounds check in the fix plus a unit test feeding a synthetic reply frame with an oversized length byte, which is the strongest argument for (3). The cheapest and highest-value tests in this project are exactly the pure functions over untrusted bytes and strings: `bezel_ddc_capabilities`' fragment assembly, `Capabilities.parse`'s hand-written bracket scanner, `EDID.init?`, `ExtractVcpCodes` (`BezelAgent.cs:475`) and `Esc` (:234).

Until (3) lands, no finding in this report can be verified by a test — only by inspection. Note that in `README.md` so the gap is a recorded decision rather than an assumed one.

---

## Clean Areas Reviewed

### Swift

**SWIFT-001 (Optionals & Unwrapping) — clean.** No `try!` and no `as!` anywhere in the 20 files (verified by grep). Exactly one force-unwrap exists — `Displays.swift:171`, `buckets[$0]!` — and it is provably safe: a key is appended to `order` at :168 only in the branch that first inserts it into `buckets`. SWIFT-001 permits force-unwrapping where nil is impossible. (`buckets[$0] ?? []` would remove the need to prove it, at no cost.) `guard let` for early exit and `if let` for binding are used correctly throughout.

**SWIFT-002 (Value Semantics) — clean.** Thirty of the thirty-three top-level types are `struct` or `enum`: `FeatureState`, `DisplayInfo`, `DisplayMode`, `EDID`, `EDID.DetailedTiming`, `Capabilities`, `LinkReport`, `VCPFeature`, `VendorBinding`, `VendorMap`, `VendorChange`, `RemoteMonitor`, `RemoteReading`, `Step`, `Target`, `Config`, and every view. The three classes earn it — `AppDelegate` (NSObject/NSApplicationDelegate, ObjC interop), `MonitorController` and `AgentInstaller` (both `final class ObservableObject`, reference semantics required by SwiftUI) — and `RemoteAgent` is an `actor`. Enums with associated values (`Transport`, `Auth`, `LinkReport.Verdict`) were not reached for as classes.

**SWIFT-003 (Memory Management) — clean, and unusually careful.** Every escaping closure that could capture self does so weakly: `AppDelegate.swift:36` (Combine sink), :41 (repeating Timer), :56 (NotificationCenter block observer), :104 (DispatchWorkItem), each followed by `guard let self`; `MonitorController.swift:704`, :742, :752 (detached Tasks). The view files' `Task { await controller.… }` closures capture `controller`, not self, and views are structs. `AgentInstaller.swift:414` is the hardest case and the best handled — it avoids self entirely off-actor with an explicit `[environment = environment(for: auth)]` capture list, evaluating the actor-isolated call *before* the hop rather than reaching back for self inside the block. No retain cycle found.

**SWIFT-005 — no exposure, checked case by case.**
- *Process:* `terminate()` and `interrupt()` appear nowhere. Both `Process` users (`AgentInstaller.execute`, `RemoteAgent.run`) run to completion. The canonical hazard has no site — but see ZBZ-002: implementing the timeout *introduces* it, and the kill must be written `if process.isRunning { process.terminate() }`.
- *withTaskCancellationHandler:* not used anywhere, so the install-time-`onCancel` trap has no site.
- *KVO:* no `addObserver`/`removeObserver` pair exists. The one block-based NotificationCenter observer (`AppDelegate.swift:54`) uses the closure form, which cannot raise on removal.
- *NSWorkspace:* the single call site, `Tabs.swift:525`, is guarded by `if let url = URL(string: …)` around a compile-time-constant URL.
- *FileManager:* every call is either a throwing API used with `try`/`try?` (these return Swift `Error`s, not exceptions) or a Bool-returning call whose result is checked (`createFile` at `AgentInstaller.swift:275` and :294 both `guard` and throw `InstallError`).
- *Indexing:* every subscript has a real guard. `MonitorController.swift:412` `inputs[0]` under `guard inputs.count > 1`; :585/:586/:596 `monitors[0]` under `guard !monitors.isEmpty`; `AgentInstaller.swift:408` `keyLines[0]` under `guard !keyLines.isEmpty`. `EDID.swift` indexes fixed offsets 8-126 only after `init?` rejects anything under 128 bytes (:23) and validates the header; its descriptor slices (:80, :86, :88) stride from that guaranteed 128 and end exactly at 126. `Capabilities.swift`'s three hand-written bracket scanners (:39-72, :107-134, :147-171) clamp every range with `min(j, count)` and bound every loop on `< count`.
- *`String(cString:)`* at `MonitorController.swift:853` — safe, and worth recording because it traps on a non-terminated buffer. `ddc.c` guarantees termination on every path: the fill loop is bounded by `written < outCapacity - 1` (:252, :272) and `out[written] = '\0'` is written unconditionally at :278 before return. The Swift side additionally only converts when `n > 0`.

**SWIFT-004 in `MonitorController.swift:838-876` — judged not a violation. This is the call the brief asked me to make explicitly, so here is the reasoning in full.**

Each of the four `DispatchQueue.global(qos: .userInitiated).async` calls sits entirely inside `withCheckedContinuation`, wrapping a synchronous C entry point that blocks: `get_vcp_on` retries four times with `usleep(60000)` between attempts, and `bezel_ddc_capabilities` sleeps 50ms per fragment across up to 8192 bytes. Swift concurrency provides no executor for blocking work, and its cooperative pool is sized to the core count — calling these directly from an async function would block a pool thread and can starve or deadlock the pool under concurrent use. The continuation-over-GCD hop is the sanctioned bridge for exactly this case, not a leftover from an older style.

The rule's actual targets are absent: there are no completion handlers anywhere in the project, the public surface of all four functions is `async`, and UI state stays isolated because `MonitorController` is `@MainActor` (:57) with these four marked `nonisolated static` specifically so they cannot touch it. Every continuation resumes exactly once on every path. The MARK at :836 ("Off-main-actor bridges to the local C transport") names the intent.

**Verdict: violated in letter, since a GCD block appears; honoured in spirit, and I would not change them.** The same reasoning covers `AgentInstaller.swift:413-449`, which wraps a blocking `Process` run. The one thing they are not is cancellation-aware — a cancelled Task waits for the C call to finish — but since the resume is unconditional there is no leaked continuation, and DDC transactions are short enough that `withTaskCancellationHandler` would add complexity for no practical gain. A one-line comment in each saying *the C call blocks, which is why this is not a Task* would close the gap for a future reader. The serialization point in ZBZ-012 is a separate, narrower issue and is filed on its own.

### C

**C-001 (Memory Management) — clean.** `ddc.c` performs no `malloc`, `calloc`, `realloc` or `free` at all; every buffer is a fixed stack array with an explicit size, or caller-supplied. There is no ownership lifecycle to get wrong. The real ownership question here is IOKit reference counting, and it is correct on every path — see below. The only Create/Copy calls are balanced: `IORegistryEntryCreateCFProperty` (:37) is `CFRelease`d at :41 on both the type-match and type-mismatch branches, and `IOFBCopyI2CInterfaceForBus` (:115) is released through `bus_close`. The one gap is ZBZ-016.

**IOKit release on every path, including early returns — clean, and this is the part of the C I checked hardest because it is the easiest to get wrong.** `framebuffer_identity` releases `child` *before* the conditional break (:61-62) rather than after, so the early exit does not leak, and releases the iterator at :64. `framebuffer_for_display` handles the exact/loose tie-break correctly: a duplicate serial match falls through to the loose slot rather than being dropped (:83-84), non-matching framebuffers are released in-loop at :87, the iterator at :89, and the losing candidate at :91 before the winner returns — all four combinations of (exact set, loose set) are correct. `bus_open` unwinds precisely at each of its three failure branches (:112, :116-117, :120-121), releasing exactly what it acquired. Every public entry point that reaches `bus_open` calls `bus_close` on every return path, including the four mid-loop breaks in `bezel_ddc_capabilities` (:260, :270) and `bezel_read_edid` (:297, :299), which fall through to `bus_close` at :279 and :302 rather than returning early.

**C-003 (Pointer Safety) — clean.** `BezelBus` is memset to zero as the first statement of `bus_open` (:106), so `connect`/`iface`/`fb` are never indeterminate even on the earliest failure; each failure branch additionally zeroes the specific fields it released; and `bus_close` memsets the struct again after releasing (:131), which is exactly C-003's post-free NULL discipline applied to IOKit handles. `bus_close` is idempotent and safe on an already-closed bus.

**C-004 (unbounded string functions) — clean as to the named functions.** No `strcpy`, `strcat`, `sprintf`, `gets`, `scanf` or `strlen`-on-untrusted-input anywhere; `stdio.h` is included but no stdio function is called. The capabilities buffer is explicitly NUL-terminated at :278, and the `outCapacity < 2` guard at :242 makes the `outCapacity - 1` arithmetic at :252 and :272 safe from underflow. ZBZ-001 and ZBZ-015 are length-derivation defects, not classic function misuse.

**Fixed-size memcpy bounds in `bezel_diagnose` — clean.** Each of the four copies at :371-372 and :378-379 is within its destination: `sinkOUI`/`branchOUI` are `uint8_t[3]` receiving 3 bytes; `sinkDeviceID`/`branchDeviceID` are `char[8]` receiving 6 plus an explicit terminator at index 6 (:373, :380), leaving a byte spare. Source `buf` is `uint8_t[32]` and the largest DPCD read requested is 12 bytes, so `buf+3+6` and `buf[9..11]` are all in range. `bezel_read_edid`'s block loop is bounded by both `outCapacity / 128` and `block < 2` (:291) against a guaranteed 128-byte minimum (:285).

**`get_vcp_on` (:190) handles short replies safely** despite ignoring `bytesRead`, because `reply` is memset to zero before every attempt (:196), so a truncated response fails the `reply[2]`/`reply[3]`/`reply[4]` checks and retries. Worth keeping as-is when the `got` validation is added in ZBZ-001.

**`dpcd_read` (:177-184) is read-only by construction** — the send phase is hardcoded to `kIOI2CNoTransactionType`, so the function *cannot* write DPCD — and the comment says both that this is deliberate and why it matters (writing DPCD can perturb link training). Enforcing a safety property in the shape of the call rather than by convention is exactly right, and `ddc.h:74` repeats the guarantee at the API boundary.

### C#

**CS-001 (Naming Conventions) — satisfied.** PascalCase for the type, all nested types (`Target`, `RECT`, `PHYSICAL_MONITOR`, `MONITORINFOEX` — the Win32 ones deliberately mirror the SDK names) and every method; camelCase for locals and parameters throughout. The underscore-prefix clause scopes to private *instance* fields, and this is a static class with none — the private statics (`enumAttempts`, `readFailures`, `readSuccesses`, `servingRequests`, `targetsCache`, `targetsCachedAt`) are outside the rule as written and are consistent with each other. (Microsoft's own convention would use `s_`; worth knowing, not a violation of this rubric.)

**CS-002 (LINQ and Collections) — clean, and correctly so.** No LINQ is written, so the rule's specific hazard — enumerating a deferred query twice — cannot occur. The loops that build JSON (`CmdList` 324-333, `CmdGet` 389-393, `CmdSetGet` 433-437, `CmdProbe` 463-468) are index-walks over `string[]` appending to a `StringBuilder`; LINQ would not improve them and would allocate more. `Owned` is materialised as a `List` and iterated once. `List.Contains` in `Flush` (:518) is O(n) over a set bounded at 255 VCP codes, the right trade at that size. Note the C# 5 toolchain *does* support LINQ, so this is a style choice, and the right one.

**CS-003 (Asynchronous Programming) — clean by absence, verified rather than assumed.** No async methods, no Task-returning methods, and critically **no `.Result` and no `.Wait()` anywhere** — the deadlock and pool-starvation hazard the rule exists to prevent has no site. The synchronous single-connection `TcpListener` loop (:548-574) with explicit socket timeouts (:557-558, :652-653, :686-687) is a deliberate fit for the hardware: DDC/CI is a serial bus, and concurrent transactions on one monitor would interleave badly.

**P/Invoke struct layouts — clean, checked field by field against the Win32 definitions on x64.** `MONITORINFOEX`: 4 + 16 + 16 + 4 = 40, plus `WCHAR[32]` = 64, gives 104, matching `MONITORINFOEXW`, with `cbSize` set via `Marshal.SizeOf` at :125. `DISPLAY_DEVICE`: 4 + 64 + 256 + 4 + 256 + 256 = 840 with `StateFlags` at offset 324 (4-byte aligned), matching `DISPLAY_DEVICEW`, `cb` set at :130. `PHYSICAL_MONITOR`: `IntPtr`(8) + `WCHAR[128]`(256) = 264, 8-byte aligned, matching `PHYSICAL_MONITOR_DESCRIPTION_SIZE = 128`. `RECT` is four ints. All four use `LayoutKind.Sequential`; the three string-bearing structs declare `CharSet.Unicode` with `ByValTStr` and the correct `SizeConst`; `GetMonitorInfo`/`EnumDisplayDevices` declare `CharSet.Unicode` so they bind to the W entry points those layouts match. `EDD_GET_DEVICE_INTERFACE_NAME = 0x00000001` at :131 is correct.

**Marshal usage beyond the layouts — clean.** Win32 `BOOL` returns are declared `bool`, taking the default `UnmanagedType.Bool` (4-byte) marshalling, correct for `BOOL` rather than 1-byte C++ `bool`. The `MonitorEnumProc` delegate (:59) matches `MONITORENUMPROC` — `ref RECT` for `LPRECT`, default Winapi/StdCall — and the instance is a live local for the whole duration of the synchronous `EnumDisplayMonitors` call (:115-120), so there is no premature-collection hazard. `Marshal.GetLastWin32Error` is safe at each of its four sites because every import feeding it declares `SetLastError = true` and no P/Invoke intervenes before the read.

**IntPtr handle leaks — no unbounded leak, though the release is later than the comment at :95-96 implies.** Every array from `GetPhysicalMonitorsFromHMONITOR` is recorded in `Owned` at :139, the line immediately after the call, with nothing between that can throw; `ReleaseAll` (:99-107) destroys the previous generation at the top of every `Enumerate` (:111). I traced the use-after-destroy question specifically: `Dispatch`'s retry path destroys the handles the first pass's local `targets` points to, but that local is dead by then and the fresh list is used instead — no dangling-handle call. What is missing is a release on process teardown: nothing calls `ReleaseAll` from `Main`'s return paths, and `Fail`'s `Environment.Exit(1)` (:269) runs no `finally` blocks, so handles survive until the OS reclaims them at process exit. Bounded and harmless in one-shot CLI use, and in serve mode each re-enumeration cleans up its predecessor. To make the comment's promise literal, wrap `Main`'s body in `try/finally { ReleaseAll(); }` and register `AppDomain.CurrentDomain.ProcessExit += (s,e) => ReleaseAll()` in `CmdServe`.

**Null discipline is maintained by hand and holds**, despite CS-004 being unavailable (ZBZ-007): `Esc` guards `s == null` (:236), both `ReadLine()` results are checked before use (:559-560, :660-661, :694), the marshalled string uses `?? ""` (:147), `targetsCache` is checked before the `.Count` access (:213), and `Pick` validates the parsed index against the collection bounds before indexing (:227). I found no unguarded dereference in the file.

### Security Guardrails (OWASP Baseline)

**No Hardcoded Secrets — clean across the entire tree.** No API key, token, password or credential literal anywhere in `Sources/`, `Agent/` or `Scripts/`. `RemoteAgent.Config.host` defaults to empty with the comment "configured per install; no default" (:56); the proxy host is a UserDefaults value the user supplies; `deploy-agent.sh`'s default host `rigel` is a plain hostname, not a secret. `.gitignore:8-14` pre-emptively ignores `*.pem`, `*.key`, `*.p12`, `.gh-token` and `secrets/`.

**Credential handling exceeds what the rubric asks — the strongest security work in the project.** `AgentInstaller` stages the SSH password in a 0700 directory (:270-272) as a 0600 file (:275-278), with an explicit failure if those permissions cannot be set; hands it to ssh through an `SSH_ASKPASS` helper that pattern-matches the prompt (`*[Pp]assword*|*[Pp]assphrase*`, :286-292) so it answers only password prompts and **never a host-key prompt** — a genuinely subtle correctness point, documented in place at :283-285; overwrites the file with zeros before unlinking (:306-311) from a `defer` (:77-83) so teardown happens on every exit path including thrown errors; and refuses to send the password at all until the user has seen and approved the fingerprint (:113-118). Nothing ever reaches a command line where `ps` could read it.

**Input Sanitization — clean at the boundary that matters.** `RemoteAgent.sanitize` (:75-81) allowlists every argument reaching the remote shell to alphanumerics plus `-_.` and throws on anything else, and every command path goes through it via `run()`; the remote string is otherwise built from a constant `exePath`. Everything user-supplied (hostname, port, username) travels as a distinct element of `process.arguments` with no shell in between. `AgentInstaller` wraps all PowerShell in base64 UTF-16LE `-EncodedCommand` (:351-358), removing remote quoting as a category, and doubles single quotes for the one value it does interpolate into a PowerShell literal (:528). On the Windows side, `ParseCode` (:272-277) parses with `NumberStyles.HexNumber` and `InvariantCulture`, `Pick` (:224-230) range-checks before subscripting, and `Esc` (:234-254) escapes quote, backslash, the three named control characters and the whole sub-0x20 range via `\u` — so a malformed capabilities string cannot break out of the JSON the Mac parses. Decoded wire values are narrowed with `UInt16(clamping:)`/`UInt8(clamping:)` rather than trapping initialisers. No `shell=true`, no string-concatenated command lines. **`BezelAgent` binds `IPAddress.Loopback` (:543), not `Any`** — the correct default, and it means the line protocol's lack of authentication is not reachable from the network.

**Path Traversal — clean.** No filesystem operation anywhere takes a filename from the monitor, from the agent's JSON, or from any network reply. Every temp path is UUID-named under `NSTemporaryDirectory` (:120-121, :268-269, :396-397); `bundledAgentFiles` (:494-509) resolves a fixed four-name allowlist against `Bundle.main.resourceURL` and verifies existence; `localPublicKey` (:511-520) reads a fixed list of three names under `~/.ssh`; remote paths are `$env:USERPROFILE\bezel` literals inside encoded scripts.

**Untrusted device input in `EDID.swift` is handled correctly (:22-27)** — a failable initialiser validating both length (`bytes.count >= 128`) and the E-EDID magic header before storing anything, with every subsequent accessor at a compile-time-constant offset below 128. This is the model ZBZ-001's fix should follow.

### Section 2 — Semantic Standards

**Comments & Documentation (Why, Not What) — the strongest part of this codebase, and worth saying so plainly.** I read every comment in the Swift files, `ddc.c`/`.h` and `BezelAgent.cs` looking for the `// increment i by 1` class the rubric targets, and found none — not one comment restates its code. They consistently record findings that cost real experiments: `Tabs.swift:34-37` (SwiftUI moves a slider binding during layout, and those writes reached the monitor), `Tabs.swift:141-145` (why a Button and not a Toggle — "it is how HDMI kept re-ticking itself"), `MonitorController.swift:253-263` (why input liveness cannot be inferred by switching, including the theory that was tried and rejected), :276-283 (the storage key that flipped between two identities for one panel), :639-644 (the observed `0x0F → 0x11 → 0x0F → 0x13` transit that makes an immediate read-back lie), `Theme.swift:115-116` (the hollow middle of a radio ring was not hit-testable), `ddc.c:1-12` (what actually travels the AUX channel), :177-179 (why `dpcd_read` is read-only by construction), :334-337 (why the DDC/CI null message is the right probe), `BezelAgent.cs:259-265` (why `Fail` must not exit inside the service, and why Task Scheduler cannot recover it), `deploy-agent.sh:42-44` (why a logon task rather than a service). Several record theories that were tested and abandoned — the most expensive kind of comment to write and the most valuable to inherit.

**Docstrings — substantially clean.** Public types and non-obvious functions carry `///` documentation describing purpose and, where relevant, the failure mode being guarded (`MonitorController.swift` at 105, 113, 127, 146, 155-160, 186, 203-209, 218-221, 238-244, 318-323, 388-390, 469-472, 489-490, 615-616, 670-671, 721-722, 738-740, 748-750, 759, 776; `RemoteAgent.swift` 67, 74, 158, 181-188, 204-206; `AgentInstaller.swift` 3-13, 53-54, 263-266, 350, 452-453, 472). `ddc.h` is the best of them — every result code (:13-20) and all twenty `BezelLinkReport` fields (:25-58) carry their meaning and, where relevant, their DPCD offset, and :43-45 explains what a populated branch block with an empty sink block implies. The rubric does not require a formal parameter/return grammar for Swift and none is missing in substance. The only gaps are the two parameters documented-by-implication but unused, filed as ZBZ-002 and ZBZ-013.

**Error Handling — Fail Fast — clean.** Validation sits at the top, before expensive work, throughout: `bezel_ddc_capabilities` checks `!out || outCapacity < 2` at :242 and `bezel_read_edid` checks `outCapacity < 128` at :285, both before opening a bus; `bezel_diagnose` null-checks at :307. Every `BezelAgent` command validates `args.Length` and calls `Pick` before touching a handle (:341, 384, 401, 423, 447). `AgentInstaller.run` rejects an empty host at :98 before any network work. `Main` routes serve/client/relay before enumeration (:286-295) *specifically* so those paths do not pay the six-second hotplug wait — the comment documents the reasoning. `RemoteAgent` guards `codes.isEmpty` at :160 before spawning ssh.

**The deliberate `try?` uses are correct and were not counted against the code:** `Task.sleep` at `MonitorController.swift:733`, :743, :753 and `AppDelegate.swift:60` can only throw `CancellationError`, which is exactly the outcome being ignored; `VendorMapping.load`/`save` (:73, :79) degrade to an empty map by design. ZBZ-003 and ZBZ-004 are the two that discard a *meaningful* error.

**Early Returns — clean in all three languages.** `BezelAgent.cs` is guard-claused throughout — every command is `if (args.Length < N) { Fail(…); return 1; }` followed by flat happy-path code, with `continue` guards at :135 and :138 rather than nesting; maximum real block nesting is three (the 63-column indentation a scan finds is a P/Invoke signature continuation at :76, not a block). `ddc.c` is the same, with early returns at :38, 50, 76, 108, 113, 117, 122, 242, 285, 307 and maximum nesting of four inside `framebuffer_for_display`'s loop. Swift uses `guard`-with-early-exit as its default idiom; the deepest nesting in the app logic is the transport `switch` in `writeRaw`, a flat three-case switch rather than an if-ladder.

**Descriptive Naming — clean.** None of the rubric's banned generics (`data`, `temp`, `val`, `obj`, `res`) appears as a variable name — the one `data` binding (`RemoteAgent.swift:106`) holds subprocess stdout and is immediately converted, and `outData`/`errData` at `AgentInstaller.swift:432-433` are explicitly qualified. Short local names appear only inside tight numeric loops in the EDID and capabilities parsers, where the surrounding comment names the bytes. C uses `found`, `exact`, `loose` — short but unambiguous in a 25-line function.

**Boolean Variables — clean.** Consistently state-prefixed: `isProbing`, `isRefreshing`, `isBusyWriting`, `isAvailable`, `isBuiltIn`, `isHiDPI`, `isUsableForDesktop`, `isToggle`, `isSubAddressed`, `isIdentifiedInput`, `hasLocalDisplay`, `hasPrefix`, `monitorControlAvailable`, `controlsLive`, `awaitingHostKeyApproval`, `servingRequests`, `localDisplayIsTarget`, `vendorReadingsIncomplete`, `sawAnything`.

**Function Names — substantially clean.** Verb-led throughout: Swift `refreshDisplays`, `refreshModes`, `refreshVisible`, `refreshVendorReadings`, `loadFeaturesLocally`, `loadFeaturesViaProxy`, `deriveActiveInputs`, `snapshotVendorCodes`, `compareVendorCodes`, `resetInputDetection`, `cycleInput`, `setUpAskpass`, `tearDownAskpass`, `scanHostKey`, `applyPreferredTiming`; C `bus_open`, `bus_close`, `ddc_message`, `dpcd_read`, `framebuffer_for_display`, `bezel_diagnose`; C# `Enumerate`, `EnumerateSettled`, `Dispatch`, `ReadOne`, `ParseCode`, `SendToService`, `ReleaseAll`, `Pick`, `Flush`. Three noun-named exceptions do work rather than accessing: `Targets(bool refresh)` (:211, enumerates and caches), `LinkFields(int)` (:195, serialises), and Swift's `bundledAgentFiles` (a pure accessor, so fine). `GetTargets`/`BuildLinkFields` would read better — a two-name deviation in a codebase that otherwise applies the rule consistently, not a pattern, and not filed as a finding.

**Component reuse in the SwiftUI layer — clean.** The shared vocabulary is genuinely extracted and reused rather than copy-pasted: `Card` (`Theme.swift:27`) is used at 26 call sites across four files, `CardGrid` (`RootView.swift:182`) at every tab root, and `SliderRow`, `StyledPicker`, `RadioRow`, `FieldLabel`, `InfoRow`, `UnavailableNote`, `HoverDim`, `FeatureSlider` (`Tabs.swift:6`), `FeaturePicker` (:56), `VendorGroup` and `VendorControlView` are all single-definition. `Theme.swift` centralises every colour and rule token, so no view hardcodes a colour.

**Typed Errors — satisfied.** `RemoteAgentError` and `AgentInstaller.InstallError` are custom error types rather than generic `Error` instances, and the C layer returns a documented result-code set (`ddc.h:13-20`) that callers switch on — though see ZBZ-014 for making that set an actual type.

### Shell Scripts

Outside the rubric's language sections, but both `build-app.sh` and `deploy-agent.sh` open with `set -euo pipefail`, resolve `$REPO` from `$0` and then **prove they are in the right repo before acting** (`build-app.sh:6` checks for `Sources/BezelApp.swift`, `deploy-agent.sh:14` for `Agent/BezelAgent.cs`), and quote every expansion. The single `|| true` (`build-app.sh:58`) is on a post-signing xattr cleanup and is explained by the comment above it.

### Not Applicable

**HTML-001 – HTML-004, PERL-001 – PERL-004, CPP-001 – CPP-004** — this project contains no HTML, no Perl and no C++.

---

## Summary

| ID | Rule | File:Line | Sev | Class |
|---|---|---|---|---|
| ZBZ-001 | C-004 | `Sources/ddc.c:268-273` | High | Real |
| ZBZ-002 | SWIFT-004 (spirit) | `Sources/RemoteAgent.swift:83-108` | High | Real |
| ZBZ-003 | SWIFT-005 / No Silent Failures | `Sources/RemoteAgent.swift:246-247` | Med | Real |
| ZBZ-004 | No Silent Failures | `Sources/AgentInstaller.swift:119-124` | Med | Real |
| ZBZ-005 | DRY | `Agent/BezelAgent.cs:619-625` | Med | Real |
| ZBZ-006 | No Silent Failures | `Agent/BezelAgent.cs:627, 570, 104` | Med | Real |
| ZBZ-007 | CS-004 | `Scripts/deploy-agent.sh:12,28` | Med | Half trade-off |
| ZBZ-008 | Workflow steps 2, 4 | `Scripts/build-app.sh:16-23` | Med | Infrastructure |
| ZBZ-009 | SRP | `Sources/AgentInstaller.swift:97-233` | Low | Mechanical |
| ZBZ-010 | SRP | `Sources/ddc.c:306-389` | Low | Mechanical |
| ZBZ-011 | SWIFT-004 | `Sources/AppDelegate.swift:104-106` | Low | Mechanical |
| ZBZ-012 | SWIFT-004 (actor clause) | `Sources/MonitorController.swift:838-876` | Low | Latent |
| ZBZ-013 | Naming & Readability | `Sources/MonitorController.swift:751` | Low | Mechanical |
| ZBZ-014 | C-002 | `Sources/ddc.c:24-30`, `ddc.h:13-20` | Low | Mechanical |
| ZBZ-015 | C-004 | `Sources/ddc.c:158-163` | Low | Unreachable |
| ZBZ-016 | C-001 | `Sources/ddc.c:75-76` | Low | Mechanical |

Two findings are worth losing sleep over. ZBZ-001 is a genuine out-of-bounds read whose bytes reach the clipboard and, on the proxy path, the network. ZBZ-002 will eventually hang the proxy permanently, and ZBZ-003 is what makes it reachable. ZBZ-005 is the one that has already silently cost correctness — `setget` lost its retry and nobody noticed, because the same table was written three times.

Everything below that is worth doing on a quiet afternoon. The security work, the IOKit ownership discipline, and the comments are better than the standard requires, and should be preserved as-is through any refactor.
