# Changelog

<!-- shipit.sh inserts new entries directly below this line. Do not remove it. -->

## 0.1.20 — 2026-08-28

**Serialise the panel's input switching so a return crossing is not lost**

Crossing back to the Mac often left the panel on USB-C. The code path was
running every time — the log recorded "switching panel to the Mac input (0xf)"
on each return — and the command reached the monitor. It simply did not survive.

A DDC input switch is slow: the panel renegotiates the link and takes several
seconds, during which reads report the transition rather than the destination. A
direct write to DisplayPort read back as 0x11 (HDMI) and then, some seconds
later, settled correctly — the switching was never broken, it was being trampled.

Crossings are far quicker than that. The log has pairs 4 seconds apart and one
1.6 seconds apart, so two switches were routinely in flight together and the
panel ended up wherever the collision left it. Swift's actors make it worse
still: calls awaiting an actor are not guaranteed to resume in the order they
were made, so two writes issued a second apart could be applied backwards.

Now one writer at a time, most recent request wins, and a reversal inside a
500ms window asks for nothing at all — which is what changing your mind that
quickly ought to mean. After each write the panel is given 2.5 seconds to finish
before another is considered.

NOTED, NOT CHANGED

Auto Switch (0xE6) is on. It was briefly turned off while testing whether it was
overriding the selection; it was not, and it has been put back as found. Worth
knowing it exists: with it on, the panel may also change input on its own when
the other machine wakes or sleeps, which would look like this feature acting up.

## 0.1.19 — 2026-08-28

**Give the clipboard its own SSH channel, and raise the cap to 32MB**

The clipboard shared the input channel, so a paste went out as one line and every
pointer event behind it waited. That head-of-line blocking is what the 1MB cap
existed to keep short — the cap was never a protocol limit, just a bound on how
long the pointer could freeze mid-motion.

It now has its own SSH connection and its own pipes. The two cannot block each
other at any layer, so the cap is only about memory: the payload is held whole
and base64 inflates it by a third at each end. 32MB, which is where a copy stops
being a copy and starts being a file transfer.

WHY NOT MULTIPLEX ONTO THE DDC CONNECTION

SSH would allow it, and the DDC path already multiplexes: RemoteAgent runs each
call as a short session over a shared ControlMaster, so those cost no new TCP
connection or authentication. Adding a channel there would have worked and saved
a handshake.

It would also have coupled the clipboard to something unrelated.
RemoteAgent.disconnect() drops that master with `ssh -O exit`, taking every
channel on it, and that fires whenever the proxy host changes or Reconnect is
pressed. The clipboard would die as a side effect of a DDC action, which is the
kind of dependency nobody reconstructs later from the symptom. The DDC channel is
also bursty and slow — roughly 0.8s per call, almost all PowerShell startup —
which is what the input channel was already deliberately kept away from.

One handshake at arm time buys independence from both.

RELAY EVICTION REMOVED, AND IT HAD TO BE

A relay used to kill every other session-0 agent on startup, because a stale one
held a pipe's only instance forever: it sat in Console.ReadLine, which never
returned on a dead SSH channel. Reads go through ReadFile now and report
ERROR_BROKEN_PIPE when the channel drops, so a relay exits on its own and the
pipe frees — the condition that eviction guarded against can no longer arise.

Keeping it would have been worse than pointless: there are two relays now, input
and clipboard, both in session 0. Each would have killed the other on startup.

OVERSIZED ITEMS ARE NOW REPORTED

Previously they were dropped to the log only, so the experience was copying
something, walking to the other machine, pasting nothing, and being told nothing.
The panel now says what happened and how big the item was.

VERIFIED

Both channels arm independently and all three pipes connect. A 4MB text payload
— four times what the old cap allowed — arrives intact: sent 4194304 bytes,
received 4194304 bytes.

## 0.1.18 — 2026-08-28

**Remember whether the KVM was left on**

The switch now persists across launches, and the app re-arms itself at startup
if that is how it was left.

This reverses a deliberate default. The old comment said the KVM should never
come up automatically because it takes over the pointer, and that conflated two
different things: armed only means the panel's right edge becomes a doorway, and
the pointer does not go anywhere until it is deliberately driven through it.
Restoring the switch takes nothing away from anyone, and having to re-arm after
every launch made a setting behave like a toy.

The choice is recorded even when arming fails, so a machine that happened to be
asleep does not quietly switch the feature off for good. The restore runs
detached from the startup probe, because bringing the channel up waits for the
far side to answer and a host that is off would otherwise hold the first probe
open for that whole timeout. A failure is written to the log rather than raised:
the usual cause is the other machine not being on yet, and the switch is still
sitting there to be flicked again.

## 0.1.17 — 2026-08-28

**Link tab: drop the prose, show the current input, tile the cards evenly**

The verdict card carried two paragraphs explaining that DDC/CI was blocked and
what to do about it. With the proxy up there is no symptom of that on the screen
— the title already says control is working and the rows already say which parts
of the local path do — so the paragraphs were explaining a problem the user
cannot see and cannot act on. They are gone; the same text is on the card's help
for anyone who wants it.

The one fact worth adding in their place is which input the panel is actually
showing, which was nowhere on this tab. It replaces the bus-type detail under
"I2C bus present", which read "DisplayPort AUX" — close enough to an input name
to be read as one, and never the answer to the question being asked.

Also removes a rendering fault visible in the screenshot: the paragraphs had
runs of blank space mid-sentence. Swift's backslash line-continuation inside a
multi-line string joins the lines but keeps the next line's indentation, so the
source indentation was being drawn.

Layout: the verdict ran full width above a grid of three, which left half of the
second row empty. Now that it is a title and five rows, all four cards tile two
by two.

## 0.1.16 — 2026-08-28

**Say that control is working, instead of warning that one path is not**

With the proxy carrying the controls, the Advanced tab announced "DDC/CI blocked
in the video path" under a warning triangle, explained that commands never reach
the panel, and advised plugging the monitor in differently — directly above
brightness, contrast and input controls that were all working. It described the
local path as though the local path were the only one, which stopped being true
the moment the proxy came up.

The card now leads with what is actually happening: control is working, through
the named host. The local checks stay, because they are the reason the proxy
exists and are worth being able to look at, but they are labelled as this Mac's
own direct path and the two the dock blocks are drawn as expected — a neutral
dash rather than a red cross.

A red cross next to hardware that is working reads as something to go and fix,
and there is nothing here to fix.

## 0.1.15 — 2026-08-28

**Fix PC-to-Mac clipboard: split incoming lines on bytes, not Characters**

Nothing sent from the PC ever reached the Mac. The PC side was doing its job —
its log recorded "clipboard: sent text, 23 bytes" — and the channel was plainly
healthy, since pointer control was crossing back and forth over it at the time.

The receiving end never assembled a single line. The far side is Console.WriteLine
on Windows, which ends lines "\r\n", and in Swift "\r\n" is ONE Character rather
than two: searching a String for "\n" therefore never matches it. Confirmed
against the wire — the ready line arrives as 7d 0d 0a.

The reason this took a second look is that it broke something already working.
The ready handshake had been detected by a raw `contains` on each chunk, which
never cared about line endings; introducing proper line buffering for clipboard
payloads replaced that with a search that could not succeed. The symptom recorded
in the log was "transport ready=false connected=true" beside a KVM that was
visibly working — the handshake and the clipboard were failing for one reason,
not two.

Now buffered as Data and split on the 0x0A byte, with the carriage return
trimmed. Grapheme clustering cannot apply to bytes, so any line ending works.

## 0.1.14 — 2026-08-28

**Clipboard synchronisation between the Mac and the PC**

Copy on one machine, paste on the other. Text, rich text and images, in both
directions, running whenever the KVM is armed rather than only while the PC has
control — the point is to copy here, cross over, and paste there, by which time
control has already changed hands.

NOTHING WAS INTEGRATED, AND THAT WAS THE FINDING

Deskflow and Barrier both have mature clipboard sharing and both are GPL-2.0.
Vendoring their code would put this project under GPL, and it is C++ built around
its own protocol and event loop, so it would have been a rewrite rather than an
integration. No permissively licensed library covers macOS-to-Windows clipboard
sync in a form this architecture could use.

Maccy (MIT) earned its place anyway, as a reference rather than a dependency. It
documents the thing that would otherwise have been learned the hard way and late:
password managers mark their copies with org.nspasteboard.ConcealedType
precisely so clipboard tools do not persist or forward them. Sending those over a
network to another machine is exactly what that marker exists to prevent.
Transient and AutoGenerated items are skipped for the same reason.

TWO PIPES, NOT ONE DUPLEX PIPE

The return direction was first built by making the existing input pipe duplex.
That cost a long detour: with both directions on one handle the server stopped
receiving anything at all the moment a client connected, while the client went on
writing perfectly happily. Rather than keep probing it, the directions were split
into two one-directional pipes — which restored the input path to exactly the
code already proven, and made the return path just as dull. It worked first try.

The return pipe detects a dead client by writing a heartbeat to it. IsConnected
is not enough: on a server stream it stays true after a client dies without any
I/O, so one abandoned relay held the pipe's only instance forever and every later
one timed out against it — the same leak already fixed on the input side.

THE LOG WAS LOSING LINES, WHICH SENT THE INVESTIGATION SIDEWAYS

Two processes write to agent.log — the session-1 service and the session-0 relay
— and File.AppendAllText opens for exclusive write, so simultaneous writes threw
a sharing violation that the logger swallowed by design. Lines went missing
exactly when both ends were busy, which is exactly when the log is being read: a
thread that was running fine appeared never to have started. It now shares the
handle and retries.

DETAILS

  * Images cross as PNG. macOS TIFF-only pasteboards are converted.
  * HTML is deliberately not sent. Windows wants CF_HTML, a header carrying byte
    offsets into the markup, and raw html would paste as visible tags. Browsers
    are exactly where html appears and they also offer rtf or plain text, so
    falling through costs formatting occasionally and never produces garbage.
  * Payloads are capped at 1MB. Clipboard data shares the channel with pointer
    events, and a several-megabyte image would sit in front of them — the
    pointer would visibly stall mid-motion while a paste went across.
  * Each side ignores the payload it was just handed, or the two machines return
    one item to each other indefinitely.
  * A `clip` command reports the interactive session's clipboard, because SSH
    lands in session 0 and would otherwise answer confidently about a clipboard
    nothing ever writes to.

VERIFIED

Mac to PC end to end: a payload sent down the channel arrives on the PC's
clipboard and reads back correctly. The return path is verified as far as the
plumbing — the back pipe connects and its traffic reaches the Mac's channel —
but a real copy made on the PC has not yet been round-tripped.

## 0.1.13 — 2026-08-28

**Control switch reads green for on, amber for off**

The stock macOS switch draws itself grey whenever its window is not the active
one, and a menu bar popover is inactive most of the time — so the one control
whose state matters at a glance was the one control refusing to show it.
Whether the PC is currently holding the keyboard should not depend on which
window happens to have focus.

Replaced with a switch that draws its own colours: Theme.ok for on and
Theme.warning for off, identical whether the popover is active or not, and
dimmed when there is no proxy host to control.

## 0.1.12 — 2026-08-28

**Park the Mac's pointer out of sight while the PC has control**

It was visibly wandering around the main screen the whole time control was
handed over.

Two calls were supposed to prevent that and neither can: CGDisplayHideCursor and
CGAssociateMouseAndMouseCursorPosition only take effect while the CALLING
application is frontmost, and zBezel is an LSUIElement menu bar app that is
essentially never frontmost. Both were no-ops. They are still made — they cost
nothing and do work on the occasions the app is active — but nothing depends on
them now.

The pointer is parked in the middle of the panel instead, and re-parked on every
pointer event so it cannot drift. While the PC has control the panel is showing
the PC, so the Mac is drawing its pointer to a screen nobody is looking at:
invisible without needing to be hidden, and stationary without needing an
association that does not hold.

The warp generates no event of its own, so it cannot feed back into the tap, and
the deltas driving the remote pointer come from the event's hardware fields
rather than from comparing positions — so re-parking does not disturb tracking.

Middle of the panel rather than a corner, deliberately: a pointer shoved into a
screen corner can trigger a hot corner, and Mission Control opening behind the
scenes every time control is handed over would be a strange thing to debug later.

## 0.1.11 — 2026-08-28

**Drop the fn diagnostic; it was telling the opposite of the truth**

The note that fired when Control-Option-Command appeared without fn was meant to
identify a keyboard that does not report fn. In practice it fires 11ms before
every successful chord, because pressing four modifiers is a sequence and fn is
usually last. Left in, it would have filled the log with a message asserting the
chord could not work, immediately above the line recording it working.

The fn chord is confirmed on this keyboard. Control-Option-Command-Escape stays
as a fallback: it is no longer covering a known failure, but an unknown one, on
whatever day nobody is reading the log.

## 0.1.10 — 2026-08-28

**Panic chord is now fn-Control-Option-Command**

Held together, no letter. Reachable with one hand while the other is still on
the mouse, which matters for something whose whole job is to be used when
control has gone somewhere unhelpful.

Tested against the flags of EVERY event rather than only flagsChanged. A chord
made purely of modifiers has no keystroke to hang the test on, and the natural
thing to do while holding it is to move the mouse. Requiring a modifier
transition would mean the chord did nothing until the user let go and pressed
again, which is the opposite of what an escape hatch should ask of anyone.

CONTROL-OPTION-COMMAND-ESCAPE STILL WORKS

Deliberately kept as a fallback rather than replaced. Not every keyboard reports
fn: Apple's own do, but a third-party keyboard may never set the flag, and the
way that failure presents is the user holding the new chord with no pointer, no
keyboard, and nothing happening — precisely the situation the mechanism exists
to prevent. A second hatch costs one comparison, and this one has already been
used in anger.

If the intended chord ever fails to fire, the log says why: holding
Control-Option-Command without fn appearing in the flags is recorded, with the
raw flag value, since that is the signature of a keyboard that does not report
fn and it is otherwise indistinguishable from the feature being broken.

## 0.1.9 — 2026-08-28

**The panel follows the pointer: crossing switches the monitor input too**

The monitor is an extended display for the Mac on DisplayPort and the PC's only
display on USB-C, which makes it the same sheet of glass either way. Crossing
its right edge now switches the panel to the PC and hands over the pointer
together, and the pointer keeps the spot on the glass it already had. Pushing
back past the PC's left edge switches the panel to DisplayPort and returns the
pointer to the Mac.

THE DOORWAY IS THE PANEL, NOT THE DESKTOP

The crossing test was the right edge of the whole desktop. That happened to be
correct only because the panel is the rightmost display; with the panel on the
left it would have been the wrong wall entirely. It is now the panel's own
right edge, taken from the display this app is controlling.

KEEPING THE SPOT ON THE GLASS

The entry position is mapped proportionally rather than by pixel, because the
two machines drive the same panel at different resolutions — the Mac at
2560x1440 logical, the PC at 3840x2160. Equal fractions land on the same glass;
equal coordinates would not.

COMING BACK LANDS ON THE MAIN DISPLAY

Deliberately not on the panel. The panel has just been told to show the Mac
again and takes a second or two to renegotiate the link, and a pointer parked on
a screen that is still black is indistinguishable from a pointer that has been
lost — the reflex is to move the mouse harder, which would only push it back
through the doorway. It lands two pixels inside the main display's right edge,
which is where the panel's left edge adjoins it, so the motion still reads as
continuous.

THE ASSUMPTION THIS RESTS ON, VERIFIED

Switching the panel to USB-C does not take the display away from the Mac. The
DisplayPort link stays up while the panel shows something else, so the desktop
geometry does not change, no windows move, and the doorway's bounds stay valid
throughout. Confirmed by reading the monitor's input as 19 (USB-C) while macOS
continued to report the external display at (2560,0 2560x1440).

The KVM keeps the last known geometry regardless, so the way back is still
computable if a future layout does drop the display.

The input switch is fired, never awaited: a DDC write through the proxy costs
the better part of a second, and blocking the event tap on it would stall every
input event on the Mac behind it. The pointer moves first and the panel catches
up.

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


