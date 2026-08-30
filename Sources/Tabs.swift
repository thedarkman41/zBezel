import SwiftUI

// MARK: - Shared helpers

/// A standard MCCS control, rendered live when the monitor supports it.
struct FeatureSlider: View {
    let code: UInt8
    let label: String
    @ObservedObject var controller: MonitorController
    @State private var draft: Double = 0
    @State private var loaded = false
    @State private var dragging = false

    var body: some View {
        let state = controller.features[code]
        SliderRow(
            label: label,
            value: $draft,
            range: 0...Double(max(state?.maximum ?? 100, 1)),
            enabled: state?.readable == true && controller.controlsLive,
            onEditingChanged: { editing in
                dragging = editing
                if !editing {
                    // Whatever the knob ended on is the value that counts, even
                    // if no intermediate update was sent (a click on the track).
                    Task<Void, Never> {
                        await controller.setFinal(code: code, value: UInt16(draft.rounded()))
                    }
                }
            })
        .onAppear { sync(state) }
        .onChange(of: state?.current) { _, _ in sync(state) }
        .onChange(of: draft) { _, newValue in
            // ONLY while the user is actually dragging. SwiftUI also moves this
            // binding during layout and while animating into a synced value, and
            // those must never reach the monitor — writing them would silently
            // change settings the user never touched.
            guard dragging else { return }
            guard let state = controller.features[code], state.readable else { return }
            let rounded = UInt16(newValue.rounded())
            guard rounded != state.current else { return }
            controller.setLive(code: code, value: rounded)
        }
    }

    private func sync(_ state: FeatureState?) {
        // Never yank the knob out from under a drag in progress.
        guard let state, state.readable, !dragging else { return }
        if !loaded || abs(draft - Double(state.current)) > 0.5 {
            draft = Double(state.current)
            loaded = true
        }
    }
}

private struct FeaturePicker: View {
    let code: UInt8
    @ObservedObject var controller: MonitorController

    var body: some View {
        let state = controller.features[code]
        let choices = state?.choices ?? []
        StyledPicker(
            options: choices.map { (value: $0.value, label: $0.label) },
            selection: Binding(
                get: { state?.current ?? 0 },
                set: { newValue in Task<Void, Never> { await controller.set(code: code, value: newValue) } }),
            enabled: state?.readable == true && !choices.isEmpty && controller.controlsLive)
    }
}

/// Shown in place of a card's contents when the monitor side is unreachable.
private struct MonitorSideUnavailable: View {
    @ObservedObject var controller: MonitorController
    var body: some View {
        // While a probe is in flight nothing is known yet, and saying the monitor
        // lacks a control is a stronger claim than the evidence supports.
        if controller.isProbing || controller.isRefreshing {
            Text("Reading from the monitor…")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
        } else {
            UnavailableNote(text: controller.monitorControlAvailable
                ? "This monitor does not report support for this control."
                : "Needs a working DDC/CI link to the monitor.")
        }
    }
}

// MARK: - Input

struct InputTab: View {
    @ObservedObject var controller: MonitorController
    @State private var resolution: String = ""
    @State private var modeID: Int32 = 0
    var body: some View {
        CardGrid {
            inputSourceCard
            imageOptimizationCard
            displayPortCard
            usbCCard
        }
        .onAppear(perform: syncFromCurrent)
        .onChange(of: controller.currentMode?.id) { _, _ in syncFromCurrent() }
    }

    private var inputSourceCard: some View {
        Card(title: "Input Source", systemImage: "rectangle.connected.to.line.below",
             help: VCP.inputSelect.blurb) {
            let state = controller.features[VCP.inputSelect.code]
            if let state, state.readable, !state.choices.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 10) {
                    ForEach(state.choices, id: \.value) { choice in
                        RadioRow(label: choice.label, isOn: state.current == choice.value) {
                            Task<Void, Never> { await controller.set(code: VCP.inputSelect.code, value: choice.value) }
                        }
                    }
                }
            } else {
                HStack(spacing: 20) {
                    ForEach(["DisplayPort", "HDMI", "USB-C1 Video"], id: \.self) { name in
                        RadioRow(label: name, isOn: false, enabled: false) {}
                    }
                }
                MonitorSideUnavailable(controller: controller)
            }

            if controller.knownInputs.count > 1 {
                Divider().overlay(Theme.rule).padding(.vertical, 2)
                FieldLabel(text: "Click-to-cycle")
                Text("Clicking the menu bar icon steps through the ticked inputs. The monitor does "
                     + "not report which ports are live — no VCP code tracks it — so a port is only "
                     + "ticked automatically when this Mac can prove it is driving it. Everything "
                     + "else is yours to set, and stays as you set it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(controller.knownInputs, id: \.self) { input in
                    // Deliberately NOT a Toggle bound to a computed property.
                    // That binding writes back whatever it is currently showing,
                    // which froze transient derived values into permanent user
                    // overrides — it is how HDMI kept re-ticking itself. A plain
                    // button writes only when a person actually clicks it.
                    Button {
                        controller.setInputActive(input, !controller.activeInputs.contains(input))
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: controller.activeInputs.contains(input)
                                  ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(controller.activeInputs.contains(input)
                                                 ? Theme.accent : Theme.textDim)
                            Text(HPProfile.inputLabel(input))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.textPrimary)
                            if controller.currentInput == input {
                                Text("in use").font(.system(size: 10)).foregroundStyle(Theme.ok)
                            } else if controller.derivedActiveInputs.contains(input) {
                                Text("this Mac").font(.system(size: 10)).foregroundStyle(Theme.ok)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modifier(HoverDim())
                }

                if case .proxy(let host, _, _) = controller.transport,
                   controller.activeInputs.count < 2 {
                    UnavailableNote(text: "\(host) is driving one of these inputs, but nothing on "
                        + "this Mac can tell which — a USB-C connection reports itself as "
                        + "DisplayPort from the far side too. Tick the one \(host) is plugged into "
                        + "and it will stay ticked.")
                }
                Button("Reset detection") { controller.resetInputDetection() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }

            Divider().overlay(Theme.rule).padding(.vertical, 2)

            VendorGroup(controls: [.autoSwitch, .dpHotPlugDetection], controller: controller)
        }
    }

    private var imageOptimizationCard: some View {
        Card(title: "Image Optimization", systemImage: "sparkles.rectangle.stack",
             help: """
             Resolution and refresh rate are set by macOS, not by the monitor, so these \
             work over any connection — including one where DDC/CI is unavailable. \
             “Preferred Resolution” selects the native timing the panel advertises in its EDID.
             """) {
            if !controller.hasLocalDisplay {
                UnavailableNote(text: "Resolution and refresh rate are macOS settings for a display "
                    + "this Mac can see. The monitor is currently reachable only through "
                    + "\(controller.proxyHost), so there is no local display to configure.")
            }
            FieldLabel(text: "Resolution")
            StyledPicker(
                options: controller.modeGroups.map { (value: $0.resolution, label: $0.resolution) },
                selection: Binding(
                    get: { resolution },
                    set: { newValue in
                        resolution = newValue
                        if let first = modes(for: newValue).first {
                            modeID = first.id
                            controller.apply(mode: first)
                        }
                    }),
                enabled: controller.hasLocalDisplay && !controller.modeGroups.isEmpty && !controller.isProbing,
                width: 300)

            HStack(spacing: 12) {
                Text("Preferred Resolution")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                Button("Apply") { controller.applyPreferredTiming() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .disabled(controller.preferredTimingLabel == nil)
            }
            if let preferred = controller.preferredTimingLabel {
                Text("Panel reports \(preferred) as its native timing.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
            }

            FieldLabel(text: "Refresh Rate")
            StyledPicker(
                options: modes(for: resolution).map {
                    (value: $0.id, label: $0.refreshShortLabel)
                },
                selection: Binding(
                    get: { modeID },
                    set: { newValue in
                        modeID = newValue
                        if let mode = modes(for: resolution).first(where: { $0.id == newValue }) {
                            controller.apply(mode: mode)
                        }
                    }),
                enabled: controller.hasLocalDisplay && !modes(for: resolution).isEmpty && !controller.isProbing,
                width: 200)

            if let current = controller.currentMode {
                Text("Currently \(current.detailLabel) at \(current.refreshLabel).")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    private var displayPortCard: some View {
        Card(title: "DisplayPort", systemImage: "cable.connector",
             help: "Selects the DisplayPort protocol version the monitor negotiates. Not a standard MCCS feature.") {
            VendorGroup(controls: [.displayPortVersion], controller: controller)
        }
    }

    private var usbCCard: some View {
        Card(title: "USB-C Configuration", systemImage: "cable.connector.horizontal",
             help: """
             Trades DisplayPort lanes against USB bandwidth on the USB-C input. Four lanes of DP \
             give 4K60 with USB 2.0; two lanes leave room for USB 3.0. Not a standard MCCS feature.
             """) {
            VendorGroup(controls: [.usbCConfiguration], controller: controller)
        }
    }

    private func modes(for resolution: String) -> [DisplayMode] {
        controller.modeGroups.first { $0.resolution == resolution }?.modes ?? []
    }

    private func syncFromCurrent() {
        guard let current = controller.currentMode else { return }
        resolution = current.resolutionLabel
        modeID = current.id
    }
}

// MARK: - Display

struct DisplayTab: View {
    @ObservedObject var controller: MonitorController

    var body: some View {
        CardGrid {
            // The three image sliders in one card, and Panel promoted beside
            // them. Split across two cards, Sharpness was a single slider in a
            // card the height of two, and Power — three words and a row of
            // buttons — sat next to the tallest card on the tab. Grouping what
            // is adjusted together leaves the tall card paired with the tall one.
            Card(title: "Image", systemImage: "sun.max",
                 help: "MCCS luminance (0x10), contrast (0x12) and sharpness (0x87).") {
                if controller.features[0x10]?.readable == true ||
                   controller.features[0x12]?.readable == true {
                    FeatureSlider(code: 0x10, label: "Brightness", controller: controller)
                    FeatureSlider(code: 0x12, label: "Contrast", controller: controller)
                } else {
                    SliderRow(label: "Brightness", value: .constant(50), range: 0...100, enabled: false)
                    SliderRow(label: "Contrast", value: .constant(75), range: 0...100, enabled: false)
                    MonitorSideUnavailable(controller: controller)
                }
                if controller.features[0x87]?.readable == true {
                    FeatureSlider(code: 0x87, label: "Sharpness", controller: controller)
                } else {
                    SliderRow(label: "Sharpness", value: .constant(50), range: 0...100, enabled: false)
                }
            }

            Card(title: "Panel", systemImage: "info.circle",
                 help: "Read-only facts the monitor reports about itself.") {
                if let edid = controller.selected?.edid {
                    InfoRow("Model", edid.displayName)
                    InfoRow("Manufacturer", edid.manufacturerID)
                    InfoRow("Serial", edid.serialString ?? "—")
                    InfoRow("Manufactured", "week \(edid.manufactureWeek), \(edid.manufactureYear)")
                    InfoRow("Panel size", String(format: "%.1f″ diagonal", edid.diagonalInches))
                    InfoRow("Connection", edid.digitalInterface)
                    if let depth = edid.bitDepth { InfoRow("Bit depth", "\(depth) bits per colour") }
                    if let preferred = edid.preferredTiming {
                        InfoRow("Native timing", preferred.description)
                    }
                    if let hours = controller.features[0xC0], hours.readable {
                        InfoRow("Backlight hours", String(hours.current))
                    }
                } else {
                    Text("EDID unavailable.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
            }

            Card(title: "Power", systemImage: "powerplug",
                 help: """
                 MCCS power mode (0xD6). On this panel the code reports the last value \
                 written to it rather than the monitor's live state, so it is presented as \
                 commands rather than as a setting you can read back.
                 """) {
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
}

struct InfoRow: View {
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
    var body: some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecond)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Color

struct ColorTab: View {
    @ObservedObject var controller: MonitorController

    var body: some View {
        CardGrid {
            Card(title: "Colour Preset", systemImage: "paintpalette",
                 help: VCP.selectColorPreset.blurb) {
                if controller.features[0x14]?.readable == true {
                    FeaturePicker(code: 0x14, controller: controller)
                } else {
                    StyledPicker(options: [(value: UInt16(1), label: "sRGB")],
                                 selection: .constant(UInt16(1)), enabled: false, width: 220)
                    MonitorSideUnavailable(controller: controller)
                }
            }

            Card(title: "RGB Gain", systemImage: "slider.horizontal.3",
                 help: "MCCS video gain: red 0x16, green 0x18, blue 0x1A.") {
                if [0x16, 0x18, 0x1A].contains(where: { controller.features[$0]?.readable == true }) {
                    FeatureSlider(code: 0x16, label: "Red", controller: controller)
                    FeatureSlider(code: 0x18, label: "Green", controller: controller)
                    FeatureSlider(code: 0x1A, label: "Blue", controller: controller)
                } else {
                    ForEach(["Red", "Green", "Blue"], id: \.self) { channel in
                        SliderRow(label: channel, value: .constant(50), range: 0...100, enabled: false)
                    }
                    MonitorSideUnavailable(controller: controller)
                }
            }

            Card(title: "Black Level", systemImage: "circle.lefthalf.filled",
                 help: "MCCS video black level: red 0x6C, green 0x6E, blue 0x70.") {
                if [0x6C, 0x6E, 0x70].contains(where: { controller.features[$0]?.readable == true }) {
                    FeatureSlider(code: 0x6C, label: "Red", controller: controller)
                    FeatureSlider(code: 0x6E, label: "Green", controller: controller)
                    FeatureSlider(code: 0x70, label: "Blue", controller: controller)
                } else {
                    ForEach(["Red", "Green", "Blue"], id: \.self) { channel in
                        SliderRow(label: channel, value: .constant(50), range: 0...100, enabled: false)
                    }
                    MonitorSideUnavailable(controller: controller)
                }
            }

            Card(title: "Restore Colour", systemImage: "arrow.uturn.backward",
                 help: "MCCS restore factory colour defaults (0x08).") {
                Button("Restore factory colour") {
                    Task<Void, Never> { await controller.set(code: 0x08, value: 1) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(controller.monitorControlAvailable ? Theme.accent : Theme.textDim)
                .disabled(!controller.monitorControlAvailable)
                if !controller.monitorControlAvailable {
                    MonitorSideUnavailable(controller: controller)
                }
            }
        }
    }
}

// MARK: - View

struct ViewTab: View {
    @ObservedObject var controller: MonitorController

    var body: some View {
        CardGrid {
            Card(title: "Viewing Mode", systemImage: "eye",
                 help: VCP.displayApplication.blurb) {
                if controller.features[0xDC]?.readable == true {
                    FeaturePicker(code: 0xDC, controller: controller)
                } else {
                    StyledPicker(options: [(value: UInt16(0), label: "Standard")],
                                 selection: .constant(UInt16(0)), enabled: false, width: 220)
                    MonitorSideUnavailable(controller: controller)
                }
            }

            Card(title: "On-Screen Display", systemImage: "character.bubble",
                 help: "MCCS OSD language (0xCC) and OSD/button lock (0xCA).") {
                FieldLabel(text: "Language")
                if controller.features[0xCC]?.readable == true {
                    FeaturePicker(code: 0xCC, controller: controller)
                } else {
                    StyledPicker(options: [(value: UInt16(2), label: "English")],
                                 selection: .constant(UInt16(2)), enabled: false, width: 220)
                }
                FieldLabel(text: "Controls")
                if controller.features[0xCA]?.readable == true {
                    FeaturePicker(code: 0xCA, controller: controller)
                } else {
                    StyledPicker(options: [(value: UInt16(2), label: "OSD enabled")],
                                 selection: .constant(UInt16(2)), enabled: false, width: 220)
                    MonitorSideUnavailable(controller: controller)
                }
            }

            Card(title: "Volume", systemImage: "speaker.wave.2",
                 help: "MCCS audio speaker volume (0x62).") {
                if controller.features[0x62]?.readable == true {
                    FeatureSlider(code: 0x62, label: "Volume", controller: controller)
                } else {
                    SliderRow(label: "Volume", value: .constant(30), range: 0...100, enabled: false)
                    MonitorSideUnavailable(controller: controller)
                }
            }
        }
    }
}

// MARK: - MultiScreen

struct MultiScreenTab: View {
    @ObservedObject var controller: MonitorController

    /// Refresh the two stills while this tab is visible, and stop when it is
    /// not — the task is cancelled on disappear, so nothing captures the screen
    /// or wakes the PC while nobody is looking at the diagram.
    private func liveSnapshots() async {
        while !Task.isCancelled {
            await controller.refreshSnapshots()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }
    }

    /// A diagram with its name under it.
    private func diagram<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 5) {
            content()
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecond)
        }
    }

    var body: some View {
        grid.task { await liveSnapshots() }
    }

    private var grid: some View {
        CardGrid {
            Card(title: "Picture in Picture", systemImage: "rectangle.inset.topright.filled",
                 help: """
                 None of this is in the public MCCS tables. HP puts all four settings behind \
                 0xE1's sub-addressing — 0x11 on/off, 0x12 mode, 0x13 size, 0x14 placement — \
                 found by experiment. The panel obeys these writes but will not report them \
                 back, so what is shown here is what was last sent, not a reading.
                 """) {
                Toggle(isOn: Binding(
                    get: { controller.pipOn },
                    set: { on in Task<Void, Never> { await controller.applyPiPOn(on) } })) {
                    Text("Picture in Picture")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                }
                .toggleStyle(StatusToggleStyle())

                HStack(alignment: .top, spacing: 14) {
                    diagram("Placement") {
                        PiPPlacementPicker(
                            placement: Binding(get: { controller.pipPlacement }, set: { _ in }),
                            enabled: controller.pipOn && !controller.pipSideBySide) { corner in
                            Task<Void, Never> { await controller.applyPiPPlacement(corner) }
                        }
                    }
                    diagram("Size") {
                        PiPSizePicker(
                            size: Binding(get: { controller.pipSize }, set: { _ in }),
                            enabled: controller.pipOn && !controller.pipSideBySide) { next in
                            Task<Void, Never> { await controller.applyPiPSize(next) }
                        }
                    }
                    diagram("Side by side") {
                        PiPSideBySidePicker(
                            active: controller.pipSideBySide,
                            enabled: controller.pipOn,
                            onPick: {
                                Task<Void, Never> {
                                    await controller.applyPiPSideBySide(!controller.pipSideBySide)
                                }
                            },
                            left: controller.macSnapshot,
                            right: controller.pcSnapshot)
                    }
                }

                if controller.needsScreenRecording {
                    Button("Allow screen recording to preview both desktops") {
                        controller.askForScreenRecording()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .help("macOS only applies this after zBezel is relaunched.")
                }
            }

            Card(title: "Displays macOS Can See", systemImage: "rectangle.on.rectangle",
                 help: "Arrangement and mirroring are macOS-side and unaffected by DDC/CI.") {
                ForEach(controller.displays) { display in
                    InfoRow(display.isBuiltIn ? "Built-in" : "External",
                            "\(display.name) — \(DisplayModes.current(for: display.id)?.detailLabel ?? "—")")
                }
                Button("Open Displays settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
        }
    }
}
