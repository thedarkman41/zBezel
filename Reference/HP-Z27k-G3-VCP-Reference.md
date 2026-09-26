# HP Z27k G3 — DDC/VCP control reference

Interoperability data for driving the HP Z27k G3 over DDC/CI (MCCS), including the
HP **vendor-specific** controls that no VESA standard defines (Sleep Timer, the
monitor's internal clock, Auto-Sleep, Power-LED, PiP, etc.).

**Provenance / copyright.** These are *facts* — VCP code numbers, feature names,
and the value encodings needed to interoperate — determined by inspecting the
public metadata of **HP Display Center 2.5.5** (the vendor's own Windows app,
which drives this panel over the standard `Dxva2.dll SetVCPFeature`). They are
recorded here as interoperability information, not as a copy of HP's source. The
raw decompiled C# is **not** checked in.

## How this was extracted (the method)

HP Display Center is a .NET app (`C:\Program Files (x86)\HP\HP Display Center`).
Its managed assemblies carry the whole map:

- `HP.DisplayCenter.Common.Enums.VcpFunction` (471) / `SubVcpFunction` (1353) —
  the human-named feature/command list.
- `HP.ExternalDisplayControl.Enumerations.VCPMasterFunction` (496) — the abstract
  master features.
- `HP.ExternalDisplayControl` → `VCPCodeHandler` maps abstract → **raw** codes:
  - `GetHexValueOfVCPMasterFunction(master, out isSubCodeArchitect, out featureType, out byte vcpCommandByte, out byte subCodeByte)`
  - `GetHexValueOfVCPSubFunction(master, sub, out byte valueByte)`
- The actual write is the standard `WinApi.SetVCPFeature(handle, byte vcpCommandByte, int value)`.

To dump any control's raw code, reflect `HP.ExternalDisplayControl.dll`, get the
`VCPCodeHandler.Instance` singleton, and invoke those two lookups (pure — no
handle, no DDC side effect, safe to call). `ilspycmd` (install `--version
8.2.0.7535`, run with `$env:DOTNET_ROLL_FORWARD='LatestMajor'`) decompiles the
switch tables if you want the full logic.

Full master-function → raw-code table: [`hp-z27k-vcp-master-map.tsv`](hp-z27k-vcp-master-map.tsv)
(269 mapped controls: `name | cmd | featureType | isSubAddressed | subIndex`).

## Encoding scheme

- **Standard MCCS** codes work as usual (brightness `0x10`, contrast `0x12`,
  input `0x60`, power/DPMS `0xD6`, …). zBezel already drives these.
- **HP vendor codes are sub-addressed.** A single raw code (`0xE1`, `0xE8`, `0xDC`, …)
  fans out to many settings, selected by the **high byte** of the written value:
  `write value = (subIndex << 8) | payload`.
  - `0xE1` example: Auto-Sleep is sub `0x0F` → `0x0F00` off / `0x0F01` on.
  - `0xE8` is where the Sleep-Timer / Power-Off-Timer group lives.
- **Reading a sub-addressed value needs a write-select first.** HP does
  `SetVCPFeature(cmd, GetReadBitOfSubCode(subIndex))` then reads back the low byte.
  A plain read only ever returns whichever sub the panel is currently "pinned" on
  — which is why differential sampling never mapped these. With the codes below
  you write directly; you don't need to read them back.

## Verified controls (✅ = confirmed on hardware)

### Sleep Timer / power — master `0xE8`
| Command | Write | Notes |
|---------|-------|-------|
| ✅ Sleep Timer **OFF** | `set 0 E8 1` | fixes the daily "amber-blink" self-sleep |
| Sleep Timer ON | `set 0 E8 2` | |
| ✅ **Sleep Now** | `set 0 E8 3` | verified: panel slept immediately |
| Power-Off Timer | `0xE8`, sub `0x07` | on/off values TBD |

### The internal clock & timer times — master `0xE8`, sub-addressed, value-carrying
The panel keeps a real-time clock (Set Current Time); when it drifts, the Sleep
Timer fires at the wrong wall-clock time (this is what caused the ~16:20 amber-blink).
Each field is a sub-addressed *continuous* value. ✅ **Encoding confirmed on
hardware 2026-09-25:** `SetVCPFeature(0xE8, (subIndex << 8) | value)`, value in
24-hour form. Writing current-time HH `set 0 E8 276` (0x0114 = sub 0x01, value 20)
and MM `set 0 E8 554` (0x022A = sub 0x02, value 42) set the OSD clock to 20:42, and
it then *ticked forward in real time* — so the write both lands and re-synchronises
the RTC. The OSD renders 24-hour; a 12-hour UI must convert to the 24-hour byte
before writing.

| Field | sub | | Field | sub |
|-------|-----|-|-------|-----|
| Current-time HH | `0x01` | | Sleep-time HH | `0x03` |
| Current-time MM | `0x02` | | Sleep-time MM | `0x04` |
| Sleep-ON HH | `0x05` | | Power-off cur HH | `0x08` |
| Sleep-ON MM | `0x06` | | Power-off cur MM | `0x09` |
| Power-off-time HH | `0x0A` | | Power-off-time MM | `0x0B` |

### Auto-Sleep — master `0xE1`
| Command | Write |
|---------|-------|
| Auto-Sleep OFF | `set 0 E1 0x0F00` (3840) |
| Auto-Sleep ON | `set 0 E1 0x0F01` (3841) |

## See also
- Memory `hp-z27k-vendor-vcp-codes` — the PiP/Menu/Color vendor maps + the
  sampling history this method supersedes.
- Memory `bezel-amber-blink` — the amber-blink was this panel's Sleep Timer;
  `set 0 E8 1` disables it over DDC.
