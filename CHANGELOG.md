# Changelog

<!-- shipit.sh inserts new entries directly below this line. Do not remove it. -->

## 0.1.46 — 2026-09-01

**Give every drag its own ghost, and pin the bar to the window**

A drag outlives its gesture. A large file is still landing long after the
user let go of it, and by then they are dragging the next one -- or dragging
a text selection across, which crosses exactly like a file drag and turns
out to hold no files. Both sides kept ONE drag's worth of state, and an
adversarial review of the drop work found what that costs: a second drag
overwrote the first's stage, so the first's scp finishing sent DROP under
the second's name and delivered a half-copied file; a text-selection
crossing reset the slot and stranded a copy in staging forever; a folder's
late size correction resurrected a ghost that nothing would ever clear.

STATE IS PER STAGE NOW, on both sides. The Mac keeps a table of pending
drags, each with its own host and its own two conditions for delivery (the
copy finishing, the user letting go, in either order); every scp callback
names its stage and is ignored if that stage is gone. MARK carries its stage
and waits for the "D" it refers to, since the release can beat the
pasteboard read. Messages go to the machine the bytes went to, not the one
under the pointer when they land. "D - <stage>" stands one drag down; a
bare "D -" clears everything. Abandoning a drag now kills its scp instead of
leaving it saturating the link, and the agent deletes the staging folder.

The agent's DragGhost is a registry of Ghost objects with a window each,
driven by one timer on one hidden dispatcher form, so a second drag never
disturbs one still landing. Drop targets and placeholders are per stage too.

THE CLOCKS RUN FROM THE LAST SIGN OF LIFE. The two-minute self-clear was
measured from the release, so a five-minute copy lost its bar at two
minutes -- the case the bar exists for -- and a failure that arrived after
that was never drawn. Now the clock restarts whenever bytes arrive: two
minutes of nothing goes dormant and comes back if the copy resumes, an hour
of nothing gives up, a failure always wakes the ghost for its four seconds.
Once DROP arrives the bar freezes full and turns green for the move into
place; measuring staging then ran it backwards as the move drained it.

THE BAR RIDES WITH THE WINDOW. Its place was a screen rectangle from a UI
Automation query rerun every 400 ms, so dragging the Explorer window left
the bar behind until the next answer. The item's place is now an offset
from the window's frame, re-pinned every tick from GetWindowRect, and an
EVENT_OBJECT_LOCATIONCHANGE hook (installed only while a ghost is anchored)
follows each step of a window drag in the same message-loop pass.
Automation only corrects the item's place within the frame, and only trusts
a reading the frame held still for. What remains is one compositor frame,
the floor for a separate top-level window.

## 0.1.45 — 2026-09-01

**Answer FreeRDP's AuthenticateEx, so the gate is warning-clean again**

FreeRDP 3.25 deprecated the Authenticate callback for AuthenticateEx, which
adds a reason (NLA, TLS, gateway, smartcard PIN). The vendored build now
carries that deprecation, and shipit's gate refuses any warning from the
app build -- so nothing could be committed until this moved. The answer is
the same whatever the reason: the credentials are already in settings from
Beacon's broker, and there is nobody at a terminal to prompt.

## 0.1.44 — 2026-08-31

**Reach several machines, lock the panel, carry files across**

The KVM reaches more than one machine, and a drag can carry a file across.

MACHINES, NOT A MACHINE. The pointer's destinations are a list now, each with
the monitor input its cable is on, editable on the Input tab. Crossing the
panel's right edge with more than one of them puts a chooser on the glass —
tiles stacked against the right edge at the height the pointer left, sliding out
like a drawer. Click one and the pointer carries on to it.

WHICH EDGE IS THE DOORWAY depends on what the panel is showing. Showing this
Mac, the panel is ordinary desktop and the doorway is its far side. Showing
another machine, the desktop stops at the built-in screen, so leaving THAT is
the crossing — and the pointer arrives on the machine already visible rather
than travelling across a panel it cannot see. Coming in that way it enters at
the far machine's LEFT edge, the way it would cross between two desktops;
through the panel's own edge it keeps its place on the glass, because that is
the same sheet of glass either way.

THE LOCK. A padlock on the far machine's screen, drawn by the agent because
nothing the Mac draws is visible while that machine is on the panel. Click it
and the panel stays there when the pointer goes home; the badge parks in the
corner and stops following the pointer around, being a status light rather than
a button. While a lock is held, this app performs NO automatic input switching
at all — one gate that every crossing goes through, rather than a condition at
each of the three call sites, which is how the panel kept moving after being
told not to. Changing the input by hand releases the lock, caught in set() where
every control converges.

A lock is also the most reliable thing we have about which input is live. The
monitor will not say: 0x60 reports the last input it was COMMANDED to, not the
one on screen, and it drifts every time the panel moves without us. Presence in
the Mac's display list is the other honest signal, and it outranks the tracked
command.

FILES CROSS WITH THE POINTER. Drag off the edge and the file is copied by scp
into C:\Temp while a wireframe page follows the cursor on the far machine; on
release the agent asks UI Automation what is under the pointer, resolves it to a
folder -- an Explorer window through Shell.Application's LocationURL, or the
Desktop when the window is Progman -- and moves the file there. It never
overwrites; a same-named file becomes "name (2)".

Windows will not accept a drop synthesised from outside a process, so this is
not a drop: it is a copy, a question, and a move. It behaves like one.

The Mac's own drag is cancelled with Escape when the pointer leaves, rather than
completed. Without that the Finder never sees a button-up and the icon is still
stuck to the cursor on return; completing it instead would drop the file
wherever the Mac's pointer happened to be parked, which is nowhere the user
chose. Events this app posts are stamped so its own tap lets them through.

A DEAD CHANNEL RECONNECTS. The first failed write drops the handle and reopens
it a second later, throttled. Restarting an agent underneath a running KVM used
to leave the app claiming control of a machine it had not reached in minutes:
the input switch is a local DDC write, so the panel still moved, and only the
pointer stayed behind.

The agent is compiled against UIAutomationClient, UIAutomationTypes and
WindowsBase, referenced by full path -- csc does not find them by name.

## 0.1.43 — 2026-08-30

**Stop cards inflating the window; read PiP state at launch**

The window fits its contents again, and the pill stops spinning.

CARDS NO LONGER INFLATE. A Spacer sat at the bottom of every card to make cards
in a row match heights, and a Spacer takes every point of height it is offered:
each card grew to its container, the container grew to the window, and the window
had no reason to shrink. A tab of six short cards rendered as six tall ones
separated by black. Cards now hug their content, and where two of them should end
level — the two lower cards on the Advanced tab — that is asked for explicitly and
bounded with fixedSize so it cannot run away again.

The Advanced tab is two deliberate columns rather than a row-major grid, which
had been pairing a five-row card with a twenty-row one. Reset was a whole card
holding three links and is now a row of them along the bottom. Cards have a
restrained drop shadow: on a dark ground there is little tonal room beneath the
background, so anything heavier reads as smudge rather than depth.

THE TRANSPORT PILL span forever. repeatForever in SwiftUI runs for the life of
the view and reassigning the value it animates does not cancel it, so stopping
the spin by setting the angle back to zero did nothing. Both the glyph and the
sweep now run off a TimelineView that only exists while a probe is in flight —
the animation's lifetime is the condition, so there is nothing to cancel. Also
slowed from 1.1s to 2.2s a revolution.

PIP STATE IS READ AT LAUNCH, at last. 0x11 does report whether PiP is on, but the
sub-selector rotation is savagely lopsided: in a 300-read pass with side-by-side
active, 0x13 took 263 of them and 0x11 appeared three times. The old sync asked
for 24 samples and therefore missed it almost every launch, leaving the toggle
off while the panel was plainly split in two. It now samples in chunks and stops
the moment 0x11 turns up.

The MODE cannot be read — 0x12 did not appear once in that same pass — so it
stays restored from what this app last set, which is what the preferences have
been holding correctly all along.

The Link tab's Control Proxy card lists every monitor the proxy can see, named
first and numbered second, since the name is what identifies a display to a
person and the index is only the handle the agent uses.

## 0.1.42 — 2026-08-30

**Draw the monitor's menu, unify the transport pill, fix the vendor mapper**

A pass over the controls, mostly making them tell the truth about what the
monitor is doing.

COLOR MODE. The nine presets are now an expanded list with radio buttons,
grouped by what each one actually is: calibrated colour spaces, white balance,
and HP's enhancement processing. A flat list put Warm beside P3 and implied they
were the same kind of choice. Each row carries its own description and what it
is for as a tooltip — the reason it is a list rather than a pop-up menu, since
macOS will not reliably show a tooltip on an item inside an open menu, and those
descriptions were written and unreachable.

P3 keys on 0x05, not the 0x21 the capabilities string lists. Writing 0x21 works
but the panel reports 0x05 back, so the row never showed as selected.

THE MONITOR'S MENU, drawn instead of typed. Two numbered sliders described where
HP's own menu sits; "position across 97" is not a picture of anything. There is
now a 16:9 screen with a likeness of the menu inside it — title strip, section
column, settings, input line — that can be dragged anywhere and writes both
coordinates on release. The panel counts vertical from the BOTTOM, which is why
the first version put the menu at the top when it was dropped at the bottom.

Underneath it, the transparency slider has a detent at each of the six reachable
steps, and the mock's opacity follows the knob live so the effect is visible
before it is written.

SHARPNESS is a seven-detent slider showing the step's NAME where brightness and
contrast show their number, with a line-pair test target beneath it. Monitor
sharpness is edge enhancement, not detail: the target softens at low steps and
rings at high ones, which is what the setting does. It is a simulation drawn by
the Mac and says so on the card — nothing reports the shape of the panel's
filter, and a preview implying otherwise would be worse than none.

THE TRANSPORT PILL is one control instead of a label beside an unrelated glyph.
It carries the refresh action inside it, and during a probe the pill itself
becomes the progress indicator: a gradient sweeps across it and the glyph turns
with it. A sweep rather than a filling bar, because a probe has no percentage to
report. The old spinner and status text appeared beside the pill and shoved the
toolbar sideways mid-refresh.

THE LINK TAB no longer reads as a fault when everything works. It says "Monitor
Control (via rigel)" or "(direct)", and the two DDC/CI rows go green whenever
control genuinely works, naming where it was verified — through USB-C on the
proxy, or through this Mac's own connector from the EDID. Those rows previously
reported only this Mac's path, so a monitor being driven perfectly well showed
two grey dashes.

THE VENDOR MAPPER was reporting a change every single time and the change it
printed was nonsense. It snapshotted 0xE1 with one plain read, and a plain read
of 0xE1 returns whichever sub-selector the monitor's rotation lands on — so two
snapshots were usually different SETTINGS rather than a changed one. The
decomposition then took the selector from the later reading and applied it to
both. Sub-addressed codes are now sampled and diffed per selector, and only
where a selector appeared in both samples: absence says the rotation did not
offer it, not that nothing changed. That made snapshots take hundreds of reads,
so there is now a Cancel beside the spinner, answered between chunks.

RGB Gain and Black Level sliders are tinted their own colour, so a row of three
reads as red, green and blue rather than three identical blue bars with words
above them. The Volume card is gone; this panel has no speakers and the card
existed only to say so.

WRITE HOLDS. Every control bound to a value the monitor confirms asynchronously
now holds what the user set until the write completes. Without it the knob
springs back to the stale reading the instant the drag ends and jumps forward
again when the answer arrives. This was one bug in six places — sliders, radio
rows, the drag — and it was fixed three times individually before being
recognised as a pattern.

Two of tonight's faults were self-inflicted and are recorded here rather than
quietly repaired. The first version of that hold only released when the monitor
reported back the exact value written, so the first time it answered with
anything else the control froze solid; Contrast was stuck at 0 until it was
found. And the Monitor Menu card was deleted by an edit that sliced between two
anchors without checking what sat between them.

## 0.1.41 — 2026-08-30

**Name the colour presets, add menu transparency**

The Colour Preset card lists the monitor's nine presets by name, and drives the
code the OSD actually uses.

0xDC is that code. MCCS calls it "display application" and defines it as picture
modes — Standard, Productivity, Movie — and none of that applies here: on the
Z27k G3 it IS the Colour menu, and its values are nowhere near the standard ones.
The card that used to sit on the View tab as "Viewing Mode" was this same
register under that wrong name, showing raw hex; it is gone. The Colour tab's
preset card used to drive 0x14, which mirrors the choice but is not what the menu
sets.

Six of the nine presets named themselves. Writing a 0xDC value and reading 0x14
back gives a standard MCCS name, so Native, sRGB and the three colour
temperatures fell out by machine; only HP Enhance+, P3 and Color Match needed
the OSD.

HP declares this code as DC(00(00 01 02 13 14 15 1D 21 2B) 02(...) 04(...)),
which reads exactly like 0xE1's sub-addressing and is not — writing a plain 0x01
selects sRGB. The parser had it as three sub-selectors, which is why the picker
offered three meaningless entries. 0xDC is now marked as a code whose
capabilities entry does not describe what it accepts.

Menu Transparency is controllable, in the steps the monitor's menu shows. Only
six of its eight steps can be reached over DDC: everything from raw 0 to 43 lands
on 89 and everything from 95 to 255 lands on 35, so the two extremes are settable
from the monitor's buttons and not from here. The spacing between the six is
irregular, so it is a picker rather than a slider, which would imply a continuum
that does not exist. Nothing reports it back: every plain VCP code was read at 89
and at 35, twice over, and not one differs.

Reads no longer touch the write-only restore commands 0x04, 0x05, 0x06, 0x08 and
0x0A. This monitor demonstrably ignores a read of them — a controlled single read
of 0x04 changed nothing — but asking a display to restore its factory defaults in
order to discover what value it holds is not a sensible thing to do, and the
capabilities string lists them beside real settings with nothing to mark the
difference.

## 0.1.40 — 2026-08-30

**Read the monitor's menu: correct PIP size, add the Menu controls**

The monitor's own menu turned out to be the specification, and reading it
corrected two mappings that probing had got backwards.

PIP Size (0xE1 sub-selector 0x13) is HP's PIP Size menu, and its five values are
that menu's five entries: 0 Enlarge, 1 Reduce, 2 Set to Maximum, 3 Set to
Minimum, 4 Set to Default. Earlier probing only ever sent 0-3, so value 4 — the
default — was never tried, and 2 and 3 were labelled "maximum" and "minimum"
merely because each happened to be bigger or smaller than wherever the inset sat
at the time.

The size control is now three nested boxes at the panel's real proportions, each
in its own shade, with a spring-loaded jog knob beneath. The knob reports a
direction and an intensity rather than a value, which suits a panel that will not
say what size it is and only accepts "one step bigger": hold it off centre and
it steps until released, faster the further it is pushed.

Three settings on HP's Menu screen are now controllable, found by writing a
different number to each unmapped sub-selector at once and then reading the
menu — whichever setting showed 55 named 0x3B, 56 named 0x3C, 57 named 0x3E. None
of the three has ever appeared in the read rotation, so sampling could not have
found them.

Sharpness is seven named steps (Soft, Level 2-6, Sharp), not a slider inventing a
1-to-7 scale. Image Scaling carries HP's own names, since the MCCS table's name
for value 02 was wrong for this panel.

0x2E is declared, writable, and controls nothing observable; it keeps its entry
for the Advanced listing but is deliberately given no control.

## 0.1.39 — 2026-08-29

**Assert the PiP state instead of trying to read it**

Switching PiP on left the diagram disagreeing with the panel: the inset sat
bottom-left and largish while the picture showed no corner at all and the
smallest size.

Placement and mode cannot be read — 0x12 and 0x14 never appear in the monitor's
selector rotation, a thousand consecutive reads returned neither. The previous
answer was to draw them as unknown, which was honest and useless: a diagram
declining to say where the inset is, beside a monitor visibly showing where the
inset is.

They are asserted now. Switching PiP on writes all four settings, so the panel is
in the state the diagram claims because the app just put it there. The two ends
agree by construction rather than by hope.

This only became the right answer once a write cost 0.09s. At the 3s it cost
this morning, pushing four settings on every enable would have been three
unbearable seconds; at a third of a second it is not worth noticing. A
performance fix changed which design was correct, which is not the usual
direction of that relationship.

The trade is real and worth stating: change PiP from the monitor's own OSD and
the app will not notice, and will overwrite it the next time PiP is switched on
here. Given the panel refuses to report two of the four settings, the choice is
between the app being authoritative or the diagram being decorative.

## 0.1.38 — 2026-08-29

**Size: make each box pick its own size**

The whole diagram was a single target that cycled, so clicking a particular box
did nothing in particular — the size changed, but never to the one under the
pointer. Each nested box is now its own target.

They are stacked largest at the back and smallest in front, so a click lands on
the smallest box containing it, which is the one the eye says it is on.

## 0.1.37 — 2026-08-29

**Write without reading back: PiP changes go from ten seconds to a tenth**

Two independent costs, each about eight times, and they multiply.

THE CHANNEL

Every DDC call spawned ssh plus a PowerShell login shell plus a .NET start before
any DDC work happened. Down a channel already open the identical command is
0.079s against 0.648s. The agent has had a relay mode for this since it was
written and nothing used it.

THE READ-BACK

`set` follows every write with a read of the same code. That is right for a value
the caller wants confirmed, and wrong for a write that makes the panel
reconfigure: the read then lands while the monitor is busy and the retry logic
waits it out. It is why the same placement write measured 8.09s once and 0.61s
immediately after — the variance was the read waiting on a display mid-change,
not the write.

Added `setraw`, which writes and returns. Measured over five writes each:

    set     mean 0.71s
    setraw  mean 0.09s

Nothing is given up. 0xE1 answers a read with whichever sub-setting it chooses,
so the read-back could never confirm these writes in the first place — it was
paying for a receipt that was never legible.

Used only for the sub-addressed writes. Brightness and the rest keep their
read-back, where the value on screen should follow the panel.

## 0.1.36 — 2026-08-29

**Use the relay: monitor control is eight times faster**

Every DDC call spawned `ssh host "BezelAgent.exe client ..."`, paying for a
PowerShell login shell and a .NET start before any DDC work happened. Measured
against the identical command sent down a channel already open:

    process per call    0.648s mean
    held-open relay     0.079s mean     (0.53s to open, paid once)

The agent has had a `relay` mode for exactly this since it was written, and
nothing ever used it — the Mac spoke to `client` and paid the startup every time.
It is a dead-code path that was worth eight times the throughput of the live one.

The actor already serialises callers, so exactly one command is ever in flight
and the channel needs no locking of its own.

FALLBACK KEPT

If the relay will not start, or the channel drops, the call falls back to
spawning a one-shot client as before. This is the path every monitor control
uses, and a relay that fails must degrade to slow rather than to broken. The
channel is also torn down when the proxy host changes, so it cannot keep talking
to the previous machine.

The reply is read on a background queue with a timeout rather than blocking on
availableData, which has none: this runs on the actor, so a far side that stops
answering would otherwise wedge every later call behind it.

## 0.1.35 — 2026-08-29

**PiP: one write per change, not three with read-backs**

A corner took ten seconds. Measured through the proxy, it was three write-and-
read-back exchanges at about 3.2 seconds each.

THE READ-BACK

The generic set() re-reads every volatile code after each write, costing roughly
two extra seconds — 3.22s against 1.29s for a bare write. That is a fair trade
for brightness, where what is on screen should follow the panel. It is pure waste
for 0xE1: a read of that code returns whichever sub-setting the panel feels like
naming, so it can neither confirm what was written nor refresh anything that
changed. These writes now go bare.

THE TWO WRITES NOBODY ASKED FOR

Setting a corner first wrote PiP on, then wrote the mode, then wrote the corner.
The preambles fired because pipOn defaults to false and the read almost never
corrects it: 0x11 turns up in about one read in a hundred, so a twenty-four
sample sync essentially never sees it. The app was switching on something already
on, and switching off a mode already off, every single time.

They are gone. Setting placement or size while PiP is off is harmless — the value
takes effect when PiP is switched on, and that toggle is immediately above.

The confirming read after a size change is gone too. 0x13's share of the rotation
swings from 82% of a thousand reads to absent from thirty, so a check usually
costs two seconds to learn nothing — and worse, the read it queues delays the
next click behind it.

One write. About 1.3 seconds, most of which is the panel.

## 0.1.34 — 2026-08-29

**PiP: correct the corners, and stop taking ten seconds to do it**

FOUR CORNERS, ALL WRONG

Every corner put the inset somewhere else: top-left produced top-right, top-right
produced bottom-left, and so on. The mapping came from observations made last
night that arrived out of step with the writes that caused them, and the result
was a consistent rotation nobody noticed because each value did move the inset
somewhere.

Re-derived one click at a time. It is reading order — 0 top-left, 1 top-right,
2 bottom-left, 3 bottom-right.

TEN SECONDS

Measured through the proxy: a write is 1.14s, a single read 0.65s, twenty-four
reads 2.04s. The verify was sampling TWO HUNDRED times, so it alone was about
fifteen seconds. That was the delay in its entirety; nothing else was slow.

The verify is now off the critical path. The write is shown immediately and
confirmed afterwards, because the write either took or it did not and waiting
does not change which. A size change is now one write, about a second.

THE SIZE THAT CHANGED BY ITSELF

The snapshot loop was calling the panel read every eight seconds, and a read
landing mid-change reports the transition rather than the result. So the diagram
wandered on its own. It now reads once when the tab appears.

The confirm also no longer treats silence as disagreement. 0x13's share of the
selector rotation is not constant — 82% of a thousand reads on one occasion,
absent from thirty on another — so "not seen" is commonplace and must not be
mistaken for "changed".

SPINNER

It sat on the size diagram whatever was being changed. It is now on whichever
control is actually mid-write.

TESTED AND REFUTED

Writing a selector does not make the panel report that selector: after writing
0x14, thirty consecutive reads contained no 0x14 at all. Placement stays
unreadable, and it is the panel's choice, not the agent's — single codes are read
and written atomically already.

## 0.1.33 — 2026-08-29

**PiP controls: fix the dead corners, and verify the size instead of assuming it**

THE CORNERS DID NOTHING

The four placement targets were positioned and THEN given a tap shape, which is
the wrong order — the shape is taken after positioning, so all four claimed the
whole diagram and fought over every click. Rebuilt as four quadrants, which fixes
the hit testing and incidentally makes each target a quarter of the picture
rather than the small rectangle drawn inside it.

THE SIZE MOVED IN THE UI AND NOT ON THE PANEL, THEN ALL AT ONCE

The UI advanced on click while the writes queued behind one another through the
actor, so the diagram ran ahead and the monitor caught up in a burst several
clicks later. It read as a control that did nothing and then did everything.

Size is one of the two selectors this panel will actually report, so it is now
written, given a moment to settle, read back, and only then reflected — and if
the monitor reports something else, that is said rather than hidden. Clicks
during a write are dropped rather than queued, since queueing them is what
produced the burst, and the diagram shows that it is working.

Placement takes the same lock. It cannot be verified — the panel will not report
it — but a queue of writes to something that needs seconds per change is what
caused the problem in the first place, whether or not the result can be read.

## 0.1.32 — 2026-08-29

**Stop the PiP diagram claiming things it cannot know**

The diagram disagreed with the panel: it showed a large inset at bottom-right
while the monitor had a small one at top-left.

All four settings were being held locally and drawn as fact. That is only ever
what this app last wrote, so on launch the diagram showed stored defaults while
the panel sat wherever it actually was. A control that reports a remembered
default as the current state is worse than one that admits it does not know,
because there is no way to tell the two apart by looking.

Two of the four can be read after all. 0x11 and 0x13 do surface in the selector
rotation, so on/off and size are now sampled from the monitor and shown truthfully
— the read said size 0, smallest, which matched the panel.

The other two cannot. A thousand consecutive reads of 0xE1 returned 0x12 and 0x14
not once, so mode and placement are genuinely unreadable. They are now unknown
until this app sets them: nothing is filled in, and a note says why. Once set in
a session they are known, because we did it.

That is the honest shape of this hardware. The panel takes these writes and obeys
them, and declines to say where it stands.

## 0.1.31 — 2026-08-29

**Side-by-side diagram: correct the order, and fit instead of crop**

Two faults, both visible the moment it was compared against a photograph of the
panel actually in side-by-side mode.

The panes were the wrong way round. The monitor puts the PC on the LEFT and this
Mac on the RIGHT; the diagram had it reversed, so it was a mirror of the thing it
was describing — the one job a diagram has.

And each pane was filling and cropping rather than fitting. The panel squeezes a
whole desktop into half the width and letterboxes the remainder; cropping instead
showed a magnified corner of one machine and presented it as the layout. They now
fit within a black pane, which is what the panel does.

Neither was findable from the code. The order is a fact about the hardware, and
the only way to know it was to look at the screen.

## 0.1.30 — 2026-08-29

**Live desktops in the side-by-side diagram**

The two panes now show what each machine is actually displaying, refreshed every
eight seconds while the MultiScreen tab is open.

The Mac half is the display the PANEL is showing, not the built-in screen. Side
by side composites what this Mac sends to that panel next to what the PC sends,
so the built-in would be the wrong picture entirely. The PC half is the capture
already added for the Mission Control thumbnail, requested over the clipboard
channel so it cannot delay pointer events.

Captured through ScreenCaptureKit rather than CGDisplayCreateImage. The older
call still works but is deprecated on macOS 14, a deprecation is a build
warning, and the ship script refuses to commit anything that warns — which is
what that gate is for.

Refresh runs from a task tied to the tab's lifetime, so it stops when the tab is
not on screen. Nothing captures this Mac's display or wakes the PC while nobody
is looking at the diagram.

Screen Recording is required and is asked for in place, with a button that only
appears while the permission is missing. macOS applies it after a relaunch,
which is its rule rather than ours. The still is downscaled to 640px on capture:
it is drawn a couple of hundred points wide inside a diagram, and a
full-resolution frame would be megabytes of nothing.

Also confirms the size mapping: 0-3 run smallest to largest, as shipped.

## 0.1.29 — 2026-08-29

**Picture in Picture, mapped and drawn instead of listed**

All four settings are now controllable, and the MultiScreen tab shows them as
diagrams rather than radio buttons.

WHAT THE PANEL ACTUALLY EXPOSES

  0xE1 sub 0x11   on/off        0 off, 1 on
  0xE1 sub 0x12   mode          0 picture-in-picture, 1+ side by side
  0xE1 sub 0x13   size          0-3
  0xE1 sub 0x14   placement     0 bottom-right, 1 top-left, 2 top-right, 3 bottom-left

SIDE BY SIDE EXISTS, AND YESTERDAY'S CONCLUSION WAS WRONG

It was recorded as settled that this panel has no side-by-side mode. That was a
bad inference from good data. Selector 0x11 was probed with every value from 2 to
17, all refused, and the conclusion drawn was that the MODE did not exist — when
what had actually been established was only that the ENABLE takes two values.
Side by side is a different selector entirely, and the test could never have
found it. Testing one axis exhaustively says nothing about a second axis.

Placement was not findable by sampling either: 0x12 and 0x14 essentially never
appear in the monitor's selector rotation, so no amount of watching would have
surfaced them. Eight batches across four position changes recorded no movement at
all. They were found by writing candidate selectors and watching the screen —
0x14 turned up next to the three already known.

The same rotation is why these are held locally rather than read back. The panel
obeys the writes and simply will not report them, so the UI shows what was last
sent and never claims to have re-read it.

THE DIAGRAMS

Placement is four corners drawn as four corners; click one to fill it. Size is
four nested boxes growing from the bottom-left, clicked to cycle, each step
shaded a little stronger so it reads as a quantity rather than a number. Side by
side is two centred panes in two shades.

Every outline is 16:9, and so is every inset, so the control is the shape of what
the panel will do. These settings are spatial, and four radio buttons reading
"upper left, upper right, lower left, lower right" ask the reader to hold a
picture in their head that the control could just show them.

## 0.1.28 — 2026-08-29

**Advanced tab: cut its height roughly in half**

It was the tab that overflowed once the window started sizing to its content —
the one flagged as the likely candidate when the outer scroll view came out.
Nearly all of the height was reference detail printed permanently on screen.

MOVED TO TOOLTIPS

Each of the fourteen manufacturer codes printed its sub-settings or accepted
values and, for the sub-addressed ones, a paragraph explaining the scheme. That
is two or three lines each, forty-odd lines in total, to show values that matter
only while someone is actually poking at that one code. Hovering gives them now.

The same for the mapped controls, where the evidence behind each mapping ran to
four lines for Picture in Picture. It is the reason to trust the mapping and
worth keeping — but not worth setting the height of the whole tab to hold prose
nobody reads twice.

LAYOUT

The fourteen codes are in two columns rather than one list, halving that card.

Monitor Firmware and the capabilities string now share the right column.
Firmware is six short rows and was leaving most of a column empty beside the
tallest card on the tab, while the capabilities string sat in a row of its own
below.

REMOVED

"Discover Vendor Controls" is now "Vendor Controls" — the discovering is one
button in it, not the point of it.

The list of vendor codes above the Snapshot button restated the card beside it,
and the numbered step above it restated the button. Two paragraphs of preamble
over a one-word action.

Forget is gone. It removed a mapping that took a long evening of differential
probing to establish, sat one click from the action that uses it, and had no
confirmation.

## 0.1.27 — 2026-08-29

**Size the window to the tab, and group the Display tab's cards better**

The window was still too short for its content, with a scrollbar down the side
and the Panel card cut off mid-row.

The cause was an outer ScrollView wrapping every tab. A scroll view is content to
be any height at all, so it reports a tiny ideal size — the window sized itself to
fit the scroll view rather than to fit the tab, and then scrolled. Asking for
.contentSize resizability could never work against that: the content was, as far
as the window was concerned, arbitrarily small. Removed, so each tab's real
height drives the window.

DISPLAY TAB

Brightness, contrast and sharpness are now one Image card. Split in two,
Sharpness was a single slider occupying a card the height of two, and Power —
three words and a row of buttons — sat beside Panel, the tallest thing on the
tab. Panel now pairs with the Image card and Power takes the short row beneath,
so the column heights roughly match instead of one running twice the other.

WORTH WATCHING

With the outer scroll gone, a tab taller than the screen would produce a window
taller than the screen rather than a scrollbar. The Advanced tab is the candidate
— it lists every manufacturer code the panel declares, fourteen on this one. If
it overflows, the fix is to bound that card the way the capabilities string
already is, rather than to put the outer scroll back.

## 0.1.26 — 2026-08-29

**Step out of the new Space by activating the previous app, not by faking a keypress**

Creating the Space still left the user standing in it, having to switch back by
hand.

The step-back was a synthesised Control-Left, and it does not work. macOS routes
the Space-switching hotkeys through the WindowServer, which ignores posted
CGEvents — the shortcut is enabled, the event is accepted, and nothing moves. The
log shows it plainly: the step-back recorded at 08:54:09, then five seconds of
silence, then the user leaving the Space themselves at 08:54:15. Worth writing
down, because the failure looks exactly like a timing problem and is not one.

Activating an application takes the user to whatever Space that application is
on, which is ordinary public API and is what clicking a Dock icon already does.
So the app that was frontmost before the Space stole focus is captured on the way
in, and activated once the transition finishes. Falls back to hiding this app if
there is nothing sensible to go back to, which at least leaves the Space rather
than sitting in it.

Still one visible transition when the switch is flipped. That part is not
avoidable from public API: creating a full-screen Space always animates into it.

## 0.1.25 — 2026-08-29

**Create the PC's Space without leaving the user standing in it**

Switching the Space on dropped the user into it and left them to switch back out.

Creating a full-screen Space always animates into it. There is no public way to
mint one in the background, and the only alternative is private SkyLight calls,
which is not a trade worth making for an animation. So the Space is created and
then immediately stepped out of: one brief transition when the switch is flipped,
after which it simply sits at the far right until it is chosen. macOS appends
full-screen Spaces after the desktops, so it lands on the right by itself.

Stepping back is a synthesised Control-Left, because switching Spaces has no
public API either. Once, on creation, never again — every later entry is the user
asking for it.

The creation round trip also had to stop counting as real. Entering the new Space
and leaving it again would otherwise read as a genuine enter followed by a
genuine leave: control handed over and taken straight back, and the monitor
switched to the PC and back, all for an animation nobody wanted. Space changes
during creation now update the remembered state without acting on it, and the
watch starts once the transition has settled.

This does not deliver "it just appears there" — that was asked for and cannot be
done from public API. It reduces it to a single blip at the moment the feature is
switched on, which is the closest honest approximation.

## 0.1.24 — 2026-08-29

**A Mission Control Space that stands for the PC**

Switch to it and the panel switches to the PC's input and hands over the
keyboard and pointer; switch away and both come back. Its Mission Control
thumbnail shows the PC's actual desktop.

WHAT IS NOT POSSIBLE, AND WHAT IS

There is no way to add an entry to Mission Control's Spaces strip. It is
system-owned, no public API exposes it, and the private ones other tools use to
manipulate Spaces still cannot insert something that is not a real Space.

So this does not imitate one. It IS one: a full-screen window on the panel, and
macOS mints a Space for any full-screen window. It therefore appears beside the
real desktops, and responds to a click on the thumbnail, a swipe, or
Control-arrow, because there is nothing special about it.

That costs one concession. An LSUIElement accessory app cannot take a window
full screen, and full screen is the entire mechanism, so the app becomes a
regular one for as long as the Space exists and goes back to being an accessory
when it closes.

ENTERING TAKES THE KEYBOARD TOO, DELIBERATELY

The two could have been separated. They should not be: switching the panel
without handing over input would show the PC's screen while an invisible Mac
pointer moved around on top of it, which is worse than doing either alone.

THE THUMBNAIL, AND WHY NOT VIA THE CLIPBOARD

The picture is a screenshot of the PC, refreshed once a minute and only while
the Space is in the background — in front, the monitor has already switched and
the real machine is on screen, so a picture of it would be invisible and a waste
of the channel.

It was suggested that the PC put the screenshot on its clipboard and let the
existing sync carry it. The transport was the right instinct and is reused, but
not the clipboard itself: that would overwrite the user's own clipboard every
sixty seconds, which turns a useful feature into a hostile one. It travels as
its own message type on the same channel instead — the clipboard connection, so
a picture can never delay a pointer event however large it is.

Sent small and lossy on purpose. A full 4K PNG is about 2MB for something drawn
a couple of hundred pixels wide in a thumbnail; 1280 wide as JPEG measured 62KB,
which makes once a minute free rather than merely affordable.

The capture runs only while the KVM is armed, is held in memory, and is never
written to disk.

## 0.1.23 — 2026-08-28

**Look the doorway up live; a cached screen edge had drifted to mid-screen**

Crossing was firing about two thirds of the way across the panel instead of at
its right edge.

The crossing test was correct and the log proves it — every crossing fired at
x=5119, which IS the panel's right edge in the geometry the app was holding. The
geometry was the stale part. The doorway was captured once and refreshed only
when macOS reported a screen-parameter change, so any re-enumeration that the app
missed, or that it sampled while the link was still settling, left it pointing at
an edge that no longer existed. Changing the DisplayPort version does exactly
that kind of re-enumeration, and today's side-by-side investigation did it
repeatedly.

That failure is quiet in the worst way. A stale edge does not throw or read as
obviously wrong — it silently relocates the doorway into the middle of the
screen, and the pointer starts crossing early with nothing to explain why.

The cache existed on a premise I later disproved myself: that switching the panel
to the PC would take the display out of the Mac's list, so the geometry had to be
remembered before switching. It does not — the DisplayPort link stays up while
the panel shows another input, which was verified while building the feature.
With that premise gone the cache had no justification and only the failure mode.

Both rectangles are now read at the moment they are used. CGDisplayBounds is a
cheap lookup, and the display id is stable across resolution changes in a way its
bounds are not. The last known bounds are still kept, used only if the display
really has gone.

The crossing log now records the doorway it used, so an edge in the wrong place
is visible in the log rather than only in the pointer's behaviour.

## 0.1.22 — 2026-08-28

**Map Picture in Picture, and stop offering a mode this panel does not have**

Picture in Picture is 0xE1 sub-selector 0x11: 0 off, 1 on.

HOW IT WAS FOUND

Nothing in any plain vendor code moved. A poll across E6, E7, EA, EB, EF, F0,
F5 and FA-FE, sampling every three seconds while the setting was toggled, saw no
change at all — the only movement was the input select, which was the KVM doing
its own job.

That left the two sub-addressed codes, where HP packs many settings behind one
code and a read returns whichever selector the monitor's rotation lands on. The
distribution is severely lopsided: in one 150-sample pass 0x13 came back 144
times and two other selectors three times each, while 0x35 and 0x39 — both
already mapped on this panel, and therefore certainly present — did not appear
once. Absence at that sample size means nothing, which is worth writing down
because it is exactly how this kind of probing produces a confident wrong answer.

At 300 samples per state the picture resolved. Nine selectors surfaced in both
states and exactly one differed in VALUE: 0x11, reading 1 with PiP on and 0 with
it off. Writing 0x1101 and then 0x1100 switched the panel and switched it back,
confirmed on screen.

THERE IS NO SIDE-BY-SIDE MODE

The tab offered Off, Picture in Picture and Picture beside Picture. This panel's
own OSD offers only the first two. Probed anyway, since firmware is often shared
across models that do have it: selector 0x11 was written with 2, 3, 16 and 17,
and every one produced a brief flicker — the panel re-evaluating — before
landing back on 0. It accepts two states and clamps everything else.

So the third option is gone. A control the hardware cannot enter is worse than
no control: it looks like a feature and behaves like a bug.

DISCOVERED BINDINGS NOW SHIP

The four codes mapped previously lived only in this machine's preferences, so a
fresh install would have started blind and been asked to repeat an hour of
differential probing to arrive at an answer already known. They are now compiled
in, applied only when the capabilities string confirms an HP Z-series G3 — these
are manufacturer-specific codes, and writing HP's sub-selectors at another
vendor's 0xE1 would be poking at something entirely unrelated — and never over a
binding discovered locally.

## 0.1.21 — 2026-08-28

**Fixed-size window, sized to its content, with nothing selectable**

The window was .contentMinSize, so it could be dragged to any size above a
940x660 minimum. Stretched, tabs with less in them than the tallest one showed a
large empty area below the cards.

It is now .contentSize: the window takes the size its content asks for and
cannot be dragged away from it. The width is pinned at 980 so the seven tabs and
the two-column grid always lay out identically; the height follows whatever the
current tab needs.

That does mean the window changes height when switching between tabs of
different lengths, which is the direct consequence of sizing around content
rather than padding every tab out to match the tallest. Easy to pin instead if
it reads as restless.

Text selection is off everywhere. Four places had deliberately opted in — the
capabilities string, the manufacturer-code dump, and two panes of the installer
log — on the grounds that they are the things you would want to copy out. That
is a real loss and worth stating: those are exactly the values someone would
paste into a bug report. It is a control panel rather than a document, though,
and a stray drag highlighting half a label looks like a fault. Disabled at the
root as well as at the four sites, so anything added later inherits it.

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


