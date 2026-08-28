# Changelog

<!-- shipit.sh inserts new entries directly below this line. Do not remove it. -->

## 0.1.5 — 2026-08-28

**Delete run-agent.ps1, closing ZBZ-S004**

The script built a .bat by wrapping each argument in double quotes with no
escaping, then registered a scheduled task to run it — so an argument
containing a quote would close it and hand cmd.exe the rest, with &, | and
%VAR% all live. It was never reachable: nothing invoked it, and all three
grep hits were file-copy lists. The live path is install-service.ps1 into
`BezelAgent.exe serve`, driven from the Mac through the `client` subcommand,
whose arguments are allowlisted to alphanumerics plus -_. and would reject a
quote outright.

Unreachable is not a reason to keep shipping it. It was copied onto every
proxy host by three separate sites, so the injection-shaped code sat on disk
on each one waiting for something to call it. Shipping less is the fix.

Removed from Scripts/build-app.sh, Scripts/deploy-agent.sh, and the `names`
array in AgentInstaller.bundledAgentFiles(), which throws when a listed file
is absent and would have failed the installer outright once the file was gone.

NOTED, NOT FIXED

While confirming nothing depended on it, one claim in the Code Enforcement
audit turned out to be wrong. ZBZ-C0xx argued that a swallowed exception in
Dispatch was acceptable because "in serve mode stderr is captured by the
scheduled task's redirect in run-agent.ps1". It is not. Serve mode is started
by install-service.ps1, which registers wscript.exe against start-hidden.vbs,
and that does `shell.Run "<exe> serve", 0, False` — window hidden, nothing
redirected anywhere. run-agent.ps1 was never in the serve path, so its
redirect never applied to it.

The practical consequence is that a swallowed exception in the running agent
is invisible: no console, no log file, no event. That is a diagnosability gap
in its own right and wants an agent-side log, which this commit does not add.

## 0.1.4 — 2026-08-28

**Untrack the shipit.sh body file**

CHANGES.txt is scratch input to shipit.sh, not repository content. Tracking it
had two consequences, both visible on the very first run of the new script.

Every commit carried a second copy of its own changelog entry, since the body
file and the CHANGELOG.md entry are generated from the same text — that being
the point of the design. And the worktree was left permanently dirty, because
the script empties the file after committing so the next run cannot silently
reuse the previous message; that emptying always landed after `git add`, so it
was never the version that got committed.

The archived copies shipit.sh leaves behind (.changes.<version>.txt) are now
ignored too. They were untracked and unignored, which meant the next `git add
-A` would have swept them into an unrelated commit.

The durable record is CHANGELOG.md, which is unaffected.

## 0.1.3 — 2026-08-28

**Rebuild shipit.sh from Clarinet's ship.sh**

The previous shipit.sh was written from scratch for this repo and had picked
up none of what Clarinet's ship.sh learned by failing. This replaces it with a
faithful adaptation, keeping the ordering rules that script enforces:

  * Validation never mutates. Every check that can refuse a commit now runs
    strictly before the version bump. The secret scan in particular used to
    run after it, so a rejected run burned a version number and left VERSION
    dirty for the next one to trip over.
  * The build runs before the commit, not after. A commit that does not
    compile is the state every later bisect has to step over.
  * The relaunch proves what is running. It compares the restarted process's
    CFBundleShortVersionString against the version just shipped, so a stale
    process still owning the menu bar is reported instead of assumed. zBezel
    has no window at launch, so this is the only honest check available.
  * The relaunch takes a mutex. Two sessions restarting the one app interleave
    into a menu bar owned by a build neither of them thinks is running. The
    lock lives beside the app's data rather than in the repo, so two checkouts
    contend for it, and it is taken with mkdir because test-then-touch has a
    window between the two halves.
  * The changelog entry is generated from the same subject and body as the
    commit message, and inserted with awk rather than sed, since body text
    containing a backslash or ampersand is a sed replacement metacharacter.
  * The relaunch happens before the push, not after. The push section returns
    early when there is no origin, so ordering it first would mean a repo
    without a remote never relaunches.

Carried over from the previous version: the three-language gate. The Mac build
compiles only the Swift, so gating on it alone would let the other two rot.
ddc.c is checked under -Wall -Wextra because it is the one memory-unsafe file
here and it parses bytes the monitor controls; BezelAgent.cs is compiled on the
proxy host under /warn:4 /warnaserror, and says so out loud when that host is
unreachable rather than passing a gate it never ran.

Also adds the insertion marker to CHANGELOG.md, which the awk step requires and
refuses to proceed without.

## 0.1.2 — 2026-08-28

shipit.sh: run the C# gate, and stamp the version the build actually carries

Two bugs the script's own checks caught on its first run.

The reachability probe ran `ssh <host> true`. The proxy host's SSH shell is
PowerShell, which has no `true`, so the probe failed and every run reported the
host unreachable and skipped compiling the agent — the one gate this machine
cannot perform locally. It now probes with `exit 0`, which both shells accept,
and reuses the multiplexed connection the app already maintains rather than
paying a fresh handshake against an 8-second timeout.

The gate built the app before the version bump, so the bundle carried the old
number while the commit claimed the new one. The relaunch check compares the
running bundle against the version being shipped and refused to agree, which is
exactly what that check exists for. The script now rebuilds after the bump.


## 0.1.1 — 2026-08-28

Add shipit.sh, and summarise what the first push contains

WHAT IS IN THE REPOSITORY AS OF THIS VERSION

zBezel is a macOS menu bar app that does what HP Display Center does on
Windows, for the HP Z27k G3. Left-click the menu bar icon to cycle inputs,
right-click for the panel, or open the full window for the six tabs.

The controls come from three different places, and the split is the whole
design:

  * VESA MCCS over DDC/CI drives the monitor's own settings — brightness,
    contrast, sharpness, RGB gain and black level, colour temperature,
    input select, power mode, OSD language and lock, panel hours, firmware.
  * CoreGraphics drives resolution and refresh rate, which are macOS
    settings rather than monitor settings, and therefore keep working even
    when DDC/CI is completely unavailable.
  * Four controls have no standard at all and were mapped by experiment.

WHY THERE IS A WINDOWS AGENT

This monitor sits behind a Thunderbolt dock. The dock's Synaptics DisplayPort
branch chip answers EDID reads on the panel's behalf but refuses the DDC/CI
address, so the monitor is unreachable from this Mac — macOS's own
AppleMCCSControlModule fails identically, and HP's documentation says Display
Center cannot configure a monitor through a dock either.

zBezel therefore relays through a machine that has the monitor on a direct
connection. Agent/BezelAgent.cs is a small C# service using the Win32 Monitor
Configuration API. It runs as a logon scheduled task in the INTERACTIVE
desktop session, because that API enumerates no monitors from session 0, and
listens on loopback; the Mac reaches it over SSH. Sources/AgentInstaller.swift
installs it on a clean Windows box: nothing needs downloading, because both
csc.exe and dxva2.dll ship with Windows.

THE FOUR CODES VESA DOES NOT DEFINE

MCCS reserves 0xE0-0xFF for the manufacturer and puts those codes outside the
standard, so no document describes them. These were found by holding a setting
steady, diffing the monitor's registers, and confirming each with an
independent signal rather than a register read-back:

  0xE6            Auto Switch                   0 off, 1 on
  0xE7            DisplayPort Hot Plug Detection 0 off, 1 on
  0xE1 sub 0x35   DisplayPort version           0x3500 = 1.1, 0x3501 = 1.2
  0xE1 sub 0x39   USB-C Configuration           0x3900 = 4K60+USB2,
                                                0x3901 = 4K30+USB3

0xE1 is sub-addressed: the high byte selects a setting, the low byte carries
its value. HP does this because MCCS allots a vendor only 32 codes. Reading one
back needs sampling, since a plain read returns whichever sub-selector the
monitor's rotation happens to land on.

WHAT THE MONITOR WILL NOT TELL YOU

Port active/inactive status is not readable. All 256 VCP codes were scanned
with DisplayPort unplugged and again with it plugged and the OSD visually
confirmed Active, holding the displayed input constant: 65 codes respond and
not one differs. The OSD reads internal state that never reaches the wire. So
click-to-cycle derives liveness instead — from what the Mac can prove, plus the
user's own ticks — and never from inference about what the panel did after a
switch, which was tried and is wrong on this hardware.

WHAT SHIPS IN THIS VERSION

  * Scripts/shipit.sh — gate, commit, push, relaunch. The gate compiles all
    three languages: ddc.c under -Wall -Wextra, the app with zero warnings,
    and the agent under /warn:4 /warnaserror on the proxy host. That last one
    is skipped with a visible note when the host is unreachable, never
    silently, because nothing on the Mac can compile C#.
  * Scripts/secret-scan.sh — carried over from Clarinet. It refuses a commit
    that stages a secret or a personal identifier, matching secrets by shape
    and reading identifiers from git config at runtime.
  * VERSION, and a build that stamps it rather than carrying the number twice.
  * Audit-trail reports redacted: the code-enforcement report embedded two
    absolute home paths, which the new secret scan would have refused.

AUDITS

Audited before the first commit against standards/security-audit.md and
standards/code-enforcement.md; both reports are in the audit trail folders and
findings are numbered ZBZ-###. Fixed before publishing: an unauthenticated
input-injection command, a Fail() that killed the agent on any failed VCP
write, an SSH password sent before host-key confirmation, a device-supplied
length byte that read 65 bytes past a stack buffer into the capabilities
string, a declared timeout that was never enforced, and three copies of the
command switch that had already drifted apart.

KNOWN GAPS

  * The local IOKit path compiles but cannot be exercised past the dock's
    branch chip, so it is verified only as far as EDID and DPCD reads.
  * Agent/run-agent.ps1 is dead — deployed by three places, invoked by none.
  * The installer has been run against a machine that already had the agent;
    a genuinely clean Windows box has not been tested end to end.
  * No test suite. The rubric's "run the test suite" step has nothing to run.


