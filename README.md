# zBezel

A macOS menu bar app for the HP Z27k G3, modelled on HP's Windows
"HP Display Center". It adjusts the monitor itself over VESA DDC/CI (MCCS), and
the host-side display settings over CoreGraphics.

Lives in the menu bar as **zBezel**:

- **Left-click** cycles the monitor's input. The new input's name appears beside
  the icon for a couple of seconds; the tooltip always names the current one.
- **Right-click** (or control-click) opens the panel: brightness, contrast,
  input, and the way through to the full window.

That split is why the menu bar item is a plain `NSStatusItem` rather than
SwiftUI's `MenuBarExtra` — `MenuBarExtra` gives no way to tell the two mouse
buttons apart.

Cycling re-reads the input before deciding where to go next, because the panel
can change input by itself; stepping from a cached value would skip or repeat
one. Only inputs that exist are cycled or listed: the monitor declares `0x21`,
`0x2F` and `0x3D` alongside DisplayPort, HDMI and USB-C, but no socket on the
back matches them — they most likely belong to other models sharing this
firmware — so they are hidden rather than offered as a way to blank the screen.

### Which ports are live

The OSD labels inputs Active/Inactive, but that state is **not readable over
DDC/CI**. All 256 VCP codes were scanned with DisplayPort unplugged and again
with it plugged and the OSD visually confirmed Active, holding the displayed
input constant so `0x60` could not move: 65 codes respond, and not one differs.
(`0x52` reports which code last changed and `0xE1` rotates its sub-selector on
every read; both are noise. `0xEF`/`0xF0`/`0xFB` all read low byte `0b101`, which
looks exactly like a three-input liveness mask and is a coincidence.)

So liveness is derived instead, and deliberately conservatively:

1. **What this Mac can prove.** A port this Mac drives is live iff macOS lists
   the display. That corrects itself — the display vanishes when the cable goes.
2. **The user's ticks**, on the Input tab, which are sticky.

Seeding happens exactly once per monitor; after that the set only changes when
you change it. Which port the *proxy host* occupies cannot be determined
automatically — a USB-C DP-alt connection reports itself as DisplayPort from the
far side too — so the app says so and asks for one tick.

An earlier version tried to learn liveness by switching to an input and seeing
whether the monitor stayed, on the theory that it refuses to sit on a dead port.
**That theory is false here**: select HDMI with nothing attached and the panel
sits there showing black. It also condemned a live DisplayPort, because a port
that has not been displaying takes seconds to train. It has been removed.

## The manufacturer-specific controls

MCCS reserves `0xE0`–`0xFF` for the manufacturer and explicitly places those
codes outside the standard — Table 8-18 lists all 32 as "Manufacturer Specific /
TBD / May be defined by display manufacturer", and §9.2 puts private codes
outside compliance entirely. So no document, free or paid, says which code drives
which control. All four were mapped by experiment:

| Control | Write | Values |
| --- | --- | --- |
| Auto Switch | `0xE6` | `0` off, `1` on |
| DisplayPort Hot Plug Detection | `0xE7` | `0` off, `1` on |
| DisplayPort version | `0xE1` | `0x3500` = 1.1, `0x3501` = 1.2 |
| USB-C Configuration | `0xE1` | `0x3900` = 4K60 + USB 2.0, `0x3901` = 4K30 + USB 3.0 |

**`0xE1` is sub-addressed.** Thirty-two vendor codes are not enough, so HP packs
several settings into one: the high byte selects the setting, the low byte is its
value. That is why sweeping plain code numbers finds nothing — DisplayPort
version was never going to have a code of its own. Reading one back needs
sampling, because a plain read of `0xE1` returns whichever sub-selector the
monitor's rotation lands on; the app asks for the code thirty times in a single
call and picks out the selector it wants.

**Discover Vendor Controls** on the Advanced tab does the same for anything not
yet mapped: snapshot, change one setting elsewhere, and it reports what moved.
Hold the setting steady rather than toggling back and forth — round trips take
seconds and a toggle-and-back slips between samples.

A register that stores a value proves nothing on its own. `0xEF` accepts writes
and reads them back faithfully while controlling nothing — it moves in lockstep
with `0xF0`, the two being an internal pair. Every mapping above was confirmed
against an independent signal: `0xAC`/`0xAE` timing changing, an audible hotplug,
or HP's own UI agreeing.

Readings taken while the link is renegotiating are the other trap — they look
like ordinary values and quietly become evidence. The agent tags every response
with `link` and `stable`, so unsettled samples are discarded rather than believed.

## Layout

```
Sources/
  ddc.c / ddc.h        DDC/CI + DisplayPort AUX over IOFramebuffer's I2C interface.
                       C because IOKit's i2c headers are absent from the Swift
                       module map. Diagnosis is read-only by construction.
  RemoteAgent.swift    SSH client for the Windows proxy.
  Capabilities.swift   Capabilities-string parser, including HP's nested form.
  EDID.swift           E-EDID 1.4 parser: identity and preferred timing.
  Displays.swift       CoreGraphics mode enumeration and switching.
  LinkReport.swift     Turns the probe results into a diagnosis.
  VendorMapping.swift  Discovery and persistence of manufacturer-specific codes.
  HPProfile.swift      Value names confirmed on this panel; nothing guessed.
  AgentInstaller.swift Sets up a Windows machine over SSH, from a clean install.
  InstallerView.swift  The installer's UI.
  MenuPanel.swift      The menu bar item's panel.
  AppDelegate.swift    The status item: click to cycle inputs, right-click for the panel.
  WindowPlacement.swift Keeps the window on the primary display.
Agent/
  BezelAgent.cs        The Windows side: list / caps / get / set / probe /
                       serve / client / relay.
```

Build with `./Scripts/build-app.sh`.

## Caveats

- Switching the input while control is relayed through another machine takes the
  panel off that machine's output, which is the path the relay depends on. Bezel
  warns before doing it; recovering needs the monitor's own buttons.
- The monitor presents a **different EDID per input** — product code `36D4` on
  DisplayPort, `36D3` on USB-C, `36D5` on HDMI — so no two hosts agree on its
  product ID. Anything keyed on product code must therefore treat these as one
  monitor; the codes are not a stable identity. The HDMI value was confirmed on
  the second Windows box, whose agent reports
  `\\?\DISPLAY#HPN36D5#...` while `0x60` reads `0x11`.
- The monitor can be reached through the proxy with no local connection at all —
  it does not train the DisplayPort link while displaying another input, so macOS
  often cannot see it even with the cable in. Monitor-side controls work anyway;
  only resolution and refresh rate need a display this Mac can see.
- The local IOKit path is written and compiles, but on this hardware it cannot be
  exercised past the branch chip, so it is verified only as far as EDID and DPCD
  reads. It should work unchanged on a direct connection.
- Sliders write continuously while dragged, coalescing to one in-flight write so
  the link cannot be flooded. Writes are gated on an actual drag: SwiftUI also
  moves the binding during layout, and those values reached the monitor once,
  silently changing settings nobody touched. Keyboard adjustment of a slider is
  therefore not wired to the monitor.
- The installer has been exercised against a machine that already had the agent;
  its individual steps are verified, but a genuinely clean Windows box has not
  been tested end to end.
- `0xD6` (power mode) reports the last value written to it, not the monitor's
  live state: suspend it and wake it by switching input and it still says
  Suspend. It is therefore presented as commands rather than as a setting,
  with what the monitor claims shown separately. Pressing On resyncs it.
- Readings are refreshed when a panel opens, after an input change, and every
  15 s while the app is frontmost — not otherwise polled. The monitor can change state on its own — a cached value shown hours
  later was a real bug — so anything long-lived on screen should be assumed
  as fresh as its last open.
- HP ships a macOS build of Display Center
  (`ftp.hp.com/pub/softpaq/sp165501-166000/hpdc-mac.tar`). It would face the same
  dock limitation, but its `HPDC_Display.framework` is the authoritative source
  for HP's proprietary VCP map if you would rather read than probe.
