import SwiftUI

/// A control HP exposes that this app knows directly — its code, sub-selector and
/// value encoding taken from HP Display Center's own tables
/// (Reference/HP-Z27k-G3-VCP-Reference.md), not discovered by probing like a
/// `VendorControl`. HP multiplexes many of these behind one MCCS code (0xE8, 0xE1)
/// and none of them can be read back, so the model carries the write encoding and
/// the interface shows what it last set.
///
/// This is the reusable base for a fuller panel UI: the 269-row master map lists
/// far more of these, and each becomes one more `HPControl` value here rather than
/// a new piece of view code.
struct HPControl: Identifiable {
    enum Kind {
        /// Two states written as whole values (any sub-selector is baked into the
        /// value): e.g. Sleep Timer 0xE8 1/2, Auto-Sleep 0xE1 0x0F00/0x0F01.
        case toggle(off: UInt16, on: UInt16)
        /// A one-shot command written once: e.g. Sleep Now 0xE8 = 3.
        case command(UInt16)
        /// A sub-addressed value in a range, written as (sub << 8) | value:
        /// e.g. the clock hour 0xE8 sub 0x01, 0…23.
        case continuous(sub: UInt8, range: ClosedRange<Int>, unit: String)
    }

    let id: String
    let name: String
    /// The MCCS master code the setting lives behind (0xE8 for sleep/clock, 0xE1
    /// for auto-sleep).
    let code: UInt8
    let kind: Kind
    var help: String? = nil
}

extension HPControl {
    // Sleep & Power
    static let sleepTimer = HPControl(
        id: "sleepTimer", name: "Sleep Timer", code: 0xE8,
        kind: .toggle(off: 1, on: 2))
    static let autoSleep = HPControl(
        id: "autoSleep", name: "Auto-Sleep", code: 0xE1,
        kind: .toggle(off: 0x0F00, on: 0x0F01))
    static let sleepNow = HPControl(
        id: "sleepNow", name: "Sleep Now", code: 0xE8,
        kind: .command(3))

    // Panel clock (Set Current Time), 24-hour internally.
    static let currentTimeHH = HPControl(
        id: "currentTimeHH", name: "Hour", code: 0xE8,
        kind: .continuous(sub: 0x01, range: 0...23, unit: "h"))
    static let currentTimeMM = HPControl(
        id: "currentTimeMM", name: "Minute", code: 0xE8,
        kind: .continuous(sub: 0x02, range: 0...59, unit: "m"))
}

/// HP's panel-level power controls — the ones behind the manufacturer codes rather
/// than MCCS: the panel's scheduled Sleep Timer (the amber-blink culprit),
/// Auto-Sleep, an immediate Sleep Now, and the panel's own real-time clock, which
/// the Sleep Timer runs on.
struct PowerTab: View {
    @ObservedObject var controller: MonitorController

    var body: some View {
        // Sleep & Power on the left; the clock and the monitor's power mode stacked
        // on the right. BalancedColumns measures and pins both columns to the
        // taller one's height, and the `fill: true` card in the shorter column
        // grows its own background to match — tops and bottoms level, 16-pt gaps
        // in both directions, no grey above a card or in an uneven gap.
        BalancedColumns {
            SleepPowerCard(controller: controller, fill: true)
        } right: {
            PanelClockCard(controller: controller)
            PowerModeCard(controller: controller, fill: true)
        }
    }
}

private struct SleepPowerCard: View {
    @ObservedObject var controller: MonitorController
    var fill = false

    var body: some View {
        Card(title: "Sleep & Power", systemImage: "powersleep",
             help: "The panel's own sleep behavior, held in the monitor rather than "
                 + "in macOS. These are HP manufacturer codes (0xE8 / 0xE1); the panel "
                 + "does not report them back, so each row shows what this app last set "
                 + "it to.",
             fill: fill) {
            if controller.controlsLive {
                toggle(.sleepTimer)
                Text("The daily amber-blink was this timer firing on a wrong clock. "
                     + "Keep it off unless you set the clock, at right, to the real time.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.rule).padding(.vertical, 2)

                toggle(.autoSleep)
                Text("Sleeps when the current source stops sending video.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)

                Divider().overlay(Theme.rule).padding(.vertical, 2)

                if controller.panelAsleep {
                    ControlRow(label: "Panel is asleep — last commanded") {
                        Button("Wake Now") {
                            Task<Void, Never> { await controller.wakePanel() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ok)
                    }
                    Text("Wakes by re-selecting the current input. If it woke another "
                         + "way, this clears on its own when the input next changes.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ControlRow(label: "Put the panel to sleep now") {
                        Button("Sleep Now") {
                            Task<Void, Never> { await controller.sleepPanelNow() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    }
                    Text("Any input activity wakes it again.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                }
            } else {
                ToggleRow(label: HPControl.sleepTimer.name,
                          isOn: .constant(false), enabled: false)
                UnavailableNote(text: "Needs a working control channel to the monitor.")
            }
        }
    }

    private func toggle(_ control: HPControl) -> some View {
        ToggleRow(
            label: control.name,
            isOn: Binding(
                get: { controller.isHPToggleOn(control) },
                set: { on in
                    Task<Void, Never> { await controller.applyHPToggle(control, on: on) }
                }),
            enabled: controller.controlsLive)
    }
}

private struct PanelClockCard: View {
    @ObservedObject var controller: MonitorController
    var fill = false

    @State private var hour12 = 12
    @State private var minute = 0
    @State private var isPM = false
    /// Seed the pickers from the Mac clock once, not on every re-entry — otherwise
    /// switching tabs and coming back would silently discard a manual selection.
    @State private var didSeed = false

    private var hourOptions: [(value: Int, label: String)] {
        ([12] + Array(1...11)).map { (value: $0, label: String($0)) }
    }
    private var minuteOptions: [(value: Int, label: String)] {
        (0...59).map { (value: $0, label: String(format: "%02d", $0)) }
    }

    var body: some View {
        Card(title: "Panel Clock", systemImage: "clock",
             help: "The monitor keeps its own real-time clock, which the Sleep Timer "
                 + "runs on. When it drifts, the timer fires at the wrong hour. This "
                 + "sets it (HP code 0xE8, 24-hour internally); the panel cannot report "
                 + "the time back, so this shows what was last set, not the live clock.",
             fill: fill) {
            if controller.controlsLive {
                ControlRow(label: "Mac clock") {
                    TimelineView(.periodic(from: Date(), by: 20)) { context in
                        Text(context.date.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Theme.textSecond)
                    }
                }
                Divider().overlay(Theme.rule).padding(.vertical, 2)

                FieldLabel(text: "Set manually")
                ControlRow(label: "Time") {
                    HStack(spacing: 12) {
                        // Sync sits with the pickers it drives, to their left: one
                        // tap sets every field to the Mac's time at once (the panel
                        // keeps a 24-hour clock; the AM/PM is converted on write).
                        Button("Sync Clocks") {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
                            let hh = c.hour ?? 0, mm = c.minute ?? 0
                            isPM = hh >= 12
                            hour12 = (hh % 12 == 0) ? 12 : hh % 12
                            minute = mm
                            Task<Void, Never> { await controller.syncPanelClockToMac() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .disabled(!controller.controlsLive)

                        HStack(spacing: 6) {
                            StyledPicker(options: hourOptions,
                                         selection: Binding(get: { hour12 },
                                                            set: { hour12 = $0; writeHour() }),
                                         enabled: controller.controlsLive, width: 62)
                            Text(":").font(.system(size: 13)).foregroundStyle(Theme.textSecond)
                            StyledPicker(options: minuteOptions,
                                         selection: Binding(get: { minute },
                                                            set: { minute = $0; writeMinute() }),
                                         enabled: controller.controlsLive, width: 62)
                            StyledPicker(options: [(value: false, label: "AM"),
                                                   (value: true, label: "PM")],
                                         selection: Binding(get: { isPM },
                                                            set: { isPM = $0; writeHour() }),
                                         enabled: controller.controlsLive, width: 62)
                        }
                    }
                }
            } else {
                FieldLabel(text: "Set current time")
                UnavailableNote(text: "Needs a working control channel to the monitor.")
            }
        }
        .onAppear {
            guard !didSeed else { return }
            didSeed = true
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            let hh = c.hour ?? 0
            isPM = hh >= 12
            hour12 = (hh % 12 == 0) ? 12 : hh % 12
            minute = c.minute ?? 0
        }
    }

    /// Convert the 12-hour picker plus AM/PM to the panel's 24-hour hour and write it.
    private func writeHour() {
        let hh = isPM ? (hour12 % 12) + 12 : (hour12 % 12)
        Task<Void, Never> { await controller.applyHP(.currentTimeHH, value: hh) }
    }
    private func writeMinute() {
        Task<Void, Never> { await controller.applyHP(.currentTimeMM, value: minute) }
    }
}

/// The monitor's MCCS power mode (0xD6). Lived on the Display tab until the Power
/// tab existed to hold it. The code reports the last value written rather than
/// the live state, so it is presented as commands, not a readable setting.
private struct PowerModeCard: View {
    @ObservedObject var controller: MonitorController
    var fill = false

    var body: some View {
        Card(title: "Power", systemImage: "powerplug",
             help: """
             MCCS power mode (0xD6). On this panel the code reports the last value \
             written to it rather than the monitor's live state, so it is presented as \
             commands rather than as a setting you can read back.
             """,
             fill: fill) {
            if let state = controller.features[0xD6], state.readable {
                FieldLabel(text: "Power Mode")
                HStack(spacing: 8) {
                    ForEach(state.choices.filter { $0.value <= 4 }, id: \.value) { choice in
                        Button(choice.label) {
                            Task<Void, Never> { await controller.set(code: 0xD6, value: choice.value) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    }
                }
                Text("Monitor reports: \(state.labelFor(value: state.current))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecond)
                if state.current != 1 {
                    UnavailableNote(text: "The panel keeps reporting this after it has woken by "
                        + "other means — switching input powers it back on without clearing the "
                        + "value. Press On to bring the reading back in line.")
                }
            } else {
                FieldLabel(text: "Power Mode")
                MonitorSideUnavailable(controller: controller)
            }
        }
    }
}
