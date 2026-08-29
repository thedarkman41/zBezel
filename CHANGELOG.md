# Changelog

<!-- shipit.sh inserts new entries directly below this line. Do not remove it. -->

## 0.1.8 — 2026-08-28

**KVM works end to end: pointer and keyboard cross to the PC**

Verified on rigel. The pointer leaves the right edge of the Mac, control lands
on the Windows machine and tracks continuously, and pushing back past its left
edge returns it. Positions match exactly: the Mac sends "A 113 597" and the
agent places the cursor at 113,597, at about 16ms per event on both sides with
no backlog.

Four separate faults stood between the last commit and that, and none of them
announced itself.

STDIN: Console.ReadLine RETURNS ONE LINE, THEN BLOCKS FOREVER

The one that mattered. In .NET Framework, reading an SSH-provided stdin pipe
with Console.ReadLine() returns the FIRST line and then blocks permanently —
no exception, no EOF, while data keeps arriving and the writer stays open.
A StreamReader over Console.OpenStandardInput() behaves identically. ReadFile
on the very same handle streams every line.

It presented as a transport fault and cost the most time, so the elimination is
worth recording: it is not SSH, and not the shell — `findstr` read the same
stream incrementally through the identical command; not PowerShell's `&` call
operator, which passes `findstr` cleanly; not cmd.exe, which fails the same way;
and not Console.OutputEncoding, since a six-line echo program with no such call
also failed. Only replacing the read fixed it. Both read loops now use ReadFile,
CmdRelay included — it had the same latent bug and would have been a trap later.

TCC: THE APP COULD NEVER HOLD ACCESSIBILITY PERMISSION

zBezel needs Accessibility to capture and suppress input, and the grant would
not stick. Two causes on top of each other.

Ad-hoc signing has no identity to name, so the designated requirement TCC stores
is the binary's cdhash, and every rebuild invalidated it silently: the entry
stayed in the list, still switched on, matching nothing. Scripts/make-signing-cert.sh
now creates a ten-year self-signed certificate and the requirement becomes
"identifier zBezel and certificate root = H..." which survives rebuilds.

That alone was not enough. The repo lives on a file-provider volume that stamps
com.apple.FinderInfo on the bundle, and that xattr fails strict codesign
verification, which TCC applies — so the app was invalid to it however correctly
it was signed. Clearing the xattr does not help, because the volume restores it
the moment Finder touches the bundle, including when the user navigates there in
the very picker used to grant permission. $HOME is on that volume too, so
~/Applications was no better. The build now installs to /Applications, signs it
there, and FAILS if strict verification does not pass — that check is the one
that predicts whether TCC will honour a grant, so it should break the build
rather than resurface as a permission prompt that cannot be dismissed.

A STALE RELAY WEDGED THE PIPE

The input pipe allows one server instance, so a single leftover session-0 relay
blocked every later crossing, silently at both ends. They go stale because
killing ssh on the Mac does not reliably deliver EOF to the far child. A relay
now evicts older ones at startup; verified by abandoning one without EOF and
confirming the next recovered.

CROSSING BOUNCED STRAIGHT BACK

The remote x position started at 0, so any leftward jitter drove it negative and
handed control back immediately — measured at 51ms between crossing out and
crossing back. Crossings now land 4px inside the edge and returning takes a
sustained 24px push.

DIAGNOSABILITY

Added a Mac-side log at ~/Library/Logs/zBezel/kvm.log, matching the agent's.
Neither of the first two faults was findable without them: every symptom was a
success return value or an unchanged screen, and the feature takes over the
pointer, so it cannot be investigated interactively.

STILL TO DO

  * Command maps to the Windows key positionally, so Cmd-C arrives as Win-C.
    Swapping it to Control is the key-remapping feature, kept separate.
  * Scroll direction is untested against natural scrolling.
  * The input pipe remains reachable by any process running as the console
    user, including medium-integrity ones.

## 0.1.7 — 2026-08-28

**KVM: the Mac side — pointer and keyboard cross to the PC**

Completes the hand-off. Moving the pointer off the right edge of the Mac's
screen gives the pointer and keyboard to the Windows machine; bringing it back
to the left edge of that machine's screen returns them.

HOW IT IS PUT TOGETHER

A CGEventTap at session level, created with .defaultTap so it can suppress and
not merely observe. While control is remote every pointer and key event is
swallowed here and forwarded there instead.

The SSH channel is opened when the feature is switched on and held open, not
opened at the crossing. It costs the better part of a second to establish,
almost all of it PowerShell login-shell startup, and paid per crossing that
would stall the pointer for a second at exactly the moment the user is watching
it. Switching on now waits for the agent's own reply before claiming to be
armed, because ssh starting locally says nothing about whether the far end
answered — the failure arrives a second later, and without the wait the UI would
report "armed" and then do nothing at the first crossing.

Positions are sent absolutely, and the far desktop's size is read from the agent
before arming. The Mac cannot infer it, and getting it wrong puts the pointer in
the wrong place by a factor — badly so driving a 4K desktop from a smaller Mac
screen.

On crossing, the mouse is decoupled from the cursor and the cursor hidden, so it
stops grinding along the screen edge while deltas keep arriving. Re-entry height
is proportional, so the pointer appears to carry straight on. Coming back lands
two pixels inside the edge rather than on it, because landing exactly on the
edge re-triggers the crossing test on the next movement and the pointer bounces.

KeyMap is a positional table. macOS keycodes are positional and Windows virtual
keys are not, so it has to be one. Command currently maps to the Windows key and
Option to Alt, which is the literal positional mapping: predictable, but not what
muscle memory wants, since Cmd-C arrives as Win-C. Swapping Command to Control is
the remapping feature and is deliberately not smuggled in here.

GETTING YOUR INPUT BACK

This tap swallows the keyboard and the pointer. If it kept doing that when it
could no longer deliver them, the input needed to recover would be the input
being eaten, so there are three ways out, all checked before anything is
swallowed:

  * Control-Option-Command-Escape hands control back immediately. Handled
    locally, so it works even if the far machine is wedged.
  * If the channel drops, control returns at once and that event is passed
    through rather than eaten.
  * Quitting zBezel unwinds it synchronously. Handing over decouples the mouse
    from the cursor, and quitting while that was in force would leave a mouse
    that moves nothing and no visible cause.

Modifiers are released on the far side at every hand-back. Crossing while
holding one and letting go on this side means the release is never forwarded and
the far machine believes it is held forever.

VERIFIED, AND NOT

The wire protocol is verified against rigel: absolute positioning lands within
3px, Caps Lock toggles, buttons and wheel are accepted. The Mac half compiles
clean and the codesign identifier is stable across rebuilds, so the Accessibility
grant it needs will survive them.

The tap itself is NOT yet exercised end to end: creating it requires
Accessibility permission, which only the user can grant. Untested until then:
edge detection, delta accumulation, and whether scroll direction needs inverting
for natural scrolling.

## 0.1.6 — 2026-08-28

**KVM receiver: the Windows half of pointer and keyboard hand-off**

The agent can now replay mouse and keyboard events into the console session, so
the Mac can drive this machine once the pointer crosses its screen edge. This is
the receiving end only; nothing on the Mac sends to it yet.

TRANSPORT

Events arrive on a named pipe, deliberately not on the loopback TCP socket the
DDC commands already use. Any local process, running as any user, can connect to
127.0.0.1 — a socket that sets brightness and a socket that types into the
console session are very different propositions, and that is why the earlier
`inject` command was deleted rather than repaired. The pipe's DACL carries a
single Allow entry naming the account running the interactive session.

The session-0 half is `BezelAgent kvm`, run over one long-lived SSH channel: the
~0.8s PowerShell login cost is paid once per crossing rather than per event.

WHY IT DID NOT WORK, AND WHY THAT TOOK A WHILE

Injection failed silently at first. SendInput returned success for every event
and nothing moved; SetCursorPos returned false. Ruled out in turn: the pipe
(events arrived and parsed correctly), the desktop and window station (WinSta0
and Default, both right — worth checking explicitly, because every window
station has a desktop called "Default" and a process stranded on the wrong one
looks identical), the lock state, cursor suppression, and the coordinate maths.

The cause was UIPI. Synthetic input from a process at a lower integrity level
than the receiving window is discarded without an error being reported anywhere:
SendInput still returns the number of events it queued. install-service.ps1 set
-RunLevel Limited, so the agent was medium integrity. At Highest the same events
land exactly.

That is a genuine privilege increase and is documented at length in
install-service.ps1 rather than slipped in. The pipe admits only the console
account, which is an administrator that can elevate unaided, so nothing
Microsoft treats as a security boundary is crossed — it says plainly that UAC
and UIPI are not one. A medium-integrity process running as that same user could
still reach the pipe, which is recorded below as a gap rather than claimed to be
handled.

ABSOLUTE, NOT RELATIVE

Relative events are measured in mickeys and pass through the pointer
acceleration curve: asking for +200,-300 produced +522,-785. The far end cannot
predict where the pointer will land, which is unusable for a KVM that has to
know when the pointer has reached an edge. Absolute positioning is now the
primary path. Both are implemented; the Mac will use absolute.

DIAGNOSABILITY

Serve mode is launched by wscript with nothing redirected, so until now a
failure inside the running agent left no trace of any kind. Added an agent.log
alongside the executable, bounded at 256KB. Without it none of the above would
have been findable: every symptom in this change was a success return value.

Added `cursor` and `keystate` commands, both answered from session 1. The Mac
needs cursor position to detect the return crossing, and keystate exists because
a KVM strands modifiers when control changes hands mid-chord.

Made the agent DPI-aware. It had been reporting the desktop as 2560x1440 while
it is 3840x2160 at 150%, so absolute coordinates would have landed two thirds of
the way to where they were aimed, on scaled displays only.

VERIFIED ON RIGEL

Absolute positioning lands within 3px, exact at the origin; keyboard toggles
Caps Lock; buttons and wheel are accepted. Residual x error is bounded and does
not accumulate.

KNOWN GAPS

  * The input pipe is reachable by any process running as the console user,
    including medium-integrity ones, which is a UIPI bypass for that account.
    Wants a mandatory-label SACL or a client integrity check on connect.
  * Absolute x lands within 3px rather than exactly; y is exact.
  * Nothing sends events yet. The Mac side is next.

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


