import SwiftUI

// MARK: - Shared helpers

/// A standard MCCS control, rendered live when the monitor supports it.
struct FeatureSlider: View {
    let code: UInt8
    let label: String
    @ObservedObject var controller: MonitorController
    var tint: Color = Theme.accent
    /// The value just written, held until the monitor reports it back. Without it
    /// the knob springs to the old value the instant the drag ends and jumps
    /// forward again when the read catches up.
    @State private var pending: UInt16?
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
                    let committed = UInt16(draft.rounded())
                    pending = committed
                    Task<Void, Never> {
                        await controller.setFinal(code: code, value: committed)
                        // Release the hold when the WRITE finishes, not when the
                        // monitor happens to report the exact value back. Waiting
                        // for equality froze Contrast solid: the panel answered
                        // with something else, the hold never lifted, and the
                        // slider stopped tracking the model entirely.
                        pending = nil
                    }
                }
            },
            tint: tint)
        .onAppear { pending = nil; sync(state) }
        .onChange(of: state?.current) { _, now in
            if let p = pending, now == p { pending = nil }
            sync(state)
        }
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
        // Never yank the knob out from under a drag in progress, nor back to a
        // stale value while the one just written is still in flight.
        guard let state, state.readable, !dragging, pending == nil else { return }
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
            KVMMachinesCard(controller: controller)
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
                if let sharp = controller.features[0x87], sharp.readable {
                    NamedStepSlider(label: "Sharpness",
                                    steps: sharp.choices,
                                    current: sharp.current,
                                    enabled: controller.controlsLive) { value in
                        Task<Void, Never> { await controller.set(code: 0x87, value: value) }
                    }
                    SharpnessPreview(level: sharp.choices.count > 1
                        ? Double(sharp.choices.firstIndex { $0.value == sharp.current } ?? 0)
                          / Double(sharp.choices.count - 1)
                        : 0)
                } else {
                    SliderRow(label: "Sharpness", value: .constant(50), range: 0...100, enabled: false)
                }
                // Only drawn when the panel reports them. Both are declared in the
                // capabilities string, but a declaration is not a promise — the
                // readable flag is what says the control answered.
                if controller.features[0x86]?.readable == true {
                    ControlRow(label: "Scaling") {
                        FeaturePicker(code: 0x86, controller: controller)
                    }
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

/// The Color Mode menu, grouped by what each mode actually is.
///
/// A flat list would put Warm beside P3 and imply they are the same kind of
/// choice. They are not: one is a white-point preference, the other a gamut
/// target, and the third group is HP's image processing. The sections say so
/// without a paragraph of explanation, and each entry carries its own — what the
/// mode is, and what it is for — as a tooltip.
private struct ColorModeList: View {
    let current: UInt16
    var enabled: Bool
    let onPick: (UInt16) -> Void

    /// The mode just chosen, shown as selected until the monitor confirms it.
    ///
    /// The write is a round trip and the panel changes long before the answer
    /// comes back, so binding the dot purely to the reported value left the click
    /// looking ignored for the better part of a second while the screen had
    /// already changed.
    @State private var pending: UInt16?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(HPProfile.colorModeGroups.enumerated()), id: \.element.title) { i, group in
                Text(group.title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(Theme.textDim)
                    .padding(.top, i == 0 ? 0 : 7)
                    .padding(.bottom, 1)
                ForEach(group.modes) { row($0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: current) { _, now in
            if now == pending { pending = nil }
        }
    }

    /// Every row carries its own tooltip. That is the reason this is a list and
    /// not a pop-up menu: macOS will not reliably show a tooltip on an item
    /// inside an open menu, so the descriptions were written and unreachable.
    private func row(_ m: HPProfile.ColorMode) -> some View {
        let chosen = m.value == (pending ?? current)
        return HStack(spacing: 8) {
            Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(chosen ? Theme.accent : Theme.textDim)
            Text(m.name)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard enabled else { return }
            pending = m.value
            onPick(m.value)
            // Backstop: never let the optimistic dot outlive the write, even if
            // the monitor answers with a value we did not send.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if pending == m.value { pending = nil }
            }
        }
        .help(m.help)
    }
}

/// A label beside a control, for cards holding more than one picker.
///
/// Cards with a single control use the card's own title as the label; these two
/// share the Image card with the sliders, so they need their own.
struct ControlRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            content
        }
    }
}

/// A slider for a setting the monitor will not report.
///
/// Writes on release rather than continuously: each write closes HP's menu, so a
/// live drag would slam the panel dozens of times and the user could never see
/// the result anyway.
struct OSDMenuSlider: View {
    let label: String
    let value: Int
    let range: ClosedRange<Int>
    var suffix: String = ""
    let onCommit: (Int) -> Void

    @State private var live: Double?
    /// The value just committed, held until the model reports it. Clearing `live`
    /// on release without this drops the knob back to the old number for as long
    /// as the write takes, which reads as a bounce.
    @State private var pending: Int?

    var body: some View {
        let shown = live ?? Double(pending ?? value)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(Int(shown))\(suffix)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecond)
            }
            Slider(value: Binding(get: { shown },
                                  set: { live = $0 }),
                   in: Double(range.lowerBound)...Double(range.upperBound),
                   onEditingChanged: { editing in
                       guard !editing, let v = live else { return }
                       let committed = Int(v.rounded())
                       pending = committed
                       live = nil
                       onCommit(committed)
                   })
            .onChange(of: value) { _, now in
                if now == pending { pending = nil }
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
        // Explicit columns rather than the shared two-up grid. The grid fills
        // row by row, which put Black Level under Color Mode; the two channel
        // cards belong together, one under the other.
        VStack(alignment: .trailing, spacing: 9) {
        HStack(alignment: .top, spacing: 16) {
            Card(title: "Color Mode", systemImage: "paintpalette",
                 help: "The nine modes on the monitor's Colour menu (0xDC). They are "
                     + "three different kinds of setting, so they are grouped rather "
                     + "than listed flat. 0x14 mirrors the choice but is not what the "
                     + "OSD drives.") {
                if let mode = controller.features[0xDC], mode.readable {
                    ColorModeList(current: mode.current,
                                  enabled: controller.controlsLive) { value in
                        Task<Void, Never> { await controller.set(code: 0xDC, value: value) }
                    }
                } else {
                    StyledPicker(options: [(value: UInt16(1), label: "sRGB")],
                                 selection: .constant(UInt16(1)), enabled: false, width: 220)
                    MonitorSideUnavailable(controller: controller)
                }
            }
            // Stretch to the height of the column beside it, so the two columns
            // end level instead of the taller one trailing off on its own.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            VStack(spacing: 16) {
            Card(title: "RGB Gain", systemImage: "slider.horizontal.3",
                 help: "MCCS video gain: red 0x16, green 0x18, blue 0x1A.") {
                if [0x16, 0x18, 0x1A].contains(where: { controller.features[$0]?.readable == true }) {
                    FeatureSlider(code: 0x16, label: "Red", controller: controller, tint: Color(red: 0.92, green: 0.34, blue: 0.34))
                    FeatureSlider(code: 0x18, label: "Green", controller: controller, tint: Color(red: 0.34, green: 0.82, blue: 0.44))
                    FeatureSlider(code: 0x1A, label: "Blue", controller: controller, tint: Color(red: 0.36, green: 0.58, blue: 0.98))
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
                    FeatureSlider(code: 0x6C, label: "Red", controller: controller, tint: Color(red: 0.92, green: 0.34, blue: 0.34))
                    FeatureSlider(code: 0x6E, label: "Green", controller: controller, tint: Color(red: 0.34, green: 0.82, blue: 0.44))
                    FeatureSlider(code: 0x70, label: "Blue", controller: controller, tint: Color(red: 0.36, green: 0.58, blue: 0.98))
                } else {
                    ForEach(["Red", "Green", "Blue"], id: \.self) { channel in
                        SliderRow(label: channel, value: .constant(50), range: 0...100, enabled: false)
                    }
                    MonitorSideUnavailable(controller: controller)
                }
            }

            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)

        // A whole card for one button was more furniture than the action
        // deserved. As a line of text under the columns it is still findable and
        // stops competing with the settings for attention.
        Button("Restore factory colour") {
            Task<Void, Never> { await controller.set(code: 0x08, value: 1) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(controller.monitorControlAvailable ? Theme.accent : Theme.textDim)
        .disabled(!controller.monitorControlAvailable)
        .help("MCCS restore factory colour defaults (0x08).")
        }
    }
}

// MARK: - View

struct ViewTab: View {
    @ObservedObject var controller: MonitorController

    var body: some View {
        CardGrid {
            // Three settings HP's Menu screen owns, reachable only as 0xE1
            // sub-selectors and readable through no channel at all — so these
            // show what this app last set, and start at HP's factory values
            // rather than pretending to have asked the panel.
            Card(title: "Monitor Menu", systemImage: "menubar.rectangle",
                 help: "Where the monitor's own menu appears, how long it stays up, "
                     + "and how transparent it is. Vendor sub-selectors 0x3B, 0x3C, "
                     + "0x3E and 0x56 — set only, never reported back.") {
                if controller.controlsLive {
                    OSDMenuPreview(
                        horizontal: controller.osdMenuH,
                        vertical: controller.osdMenuV,
                        transparency: controller.osdTransparency,
                        enabled: true,
                        onMove: { h, v in
                            Task<Void, Never> {
                                await controller.applyOSDMenu(horizontal: h)
                                await controller.applyOSDMenu(vertical: v)
                            }
                        },
                        onTransparency: { step in
                            Task<Void, Never> {
                                await controller.applyOSDMenu(transparency: step)
                            }
                        })
                    OSDMenuSlider(label: "Stays up for", value: controller.osdMenuTimeout,
                                  range: 5...60, suffix: "s") { v in
                        Task<Void, Never> { await controller.applyOSDMenu(timeout: v) }
                    }
                } else {
                    SliderRow(label: "Position across", value: .constant(97),
                              range: 0...100, enabled: false)
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
        grid
            .task { await liveSnapshots() }
            // Read the panel ONCE on arrival. Doing it on the snapshot loop
            // meant re-reading every eight seconds, and a read that lands mid
            // change reports the transition — which is why the size diagram
            // appeared to wander on its own.
            .task { await controller.syncPiPFromPanel() }
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
                            enabled: controller.pipOn && !controller.pipSideBySide,
                            busy: controller.pipBusyControl == "placement") { corner in
                            Task<Void, Never> { await controller.applyPiPPlacement(corner) }
                        }
                    }
                    diagram("Size") {
                        PiPSizePicker(
                            current: controller.pipSize,
                            enabled: controller.pipOn && !controller.pipSideBySide,
                            busy: controller.pipBusyControl == "size",
                            onPick: { size in
                                Task<Void, Never> { await controller.applyPiPSize(size) }
                            },
                            onJogBegin: { up, intensity in
                                controller.startPiPJog(up: up, intensity: intensity)
                            },
                            onJogEnd: { controller.stopPiPJog() })
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
                            mac: controller.macSnapshot,
                            pc: controller.pcSnapshot)
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


/// The machines the pointer travels through, in the order it reaches them.
///
/// An ordered list rather than a single "PC host", because the pointer walks a
/// row of desks: off the Mac's panel into the first machine, off ITS right edge
/// into the next. Each needs the monitor input its cable is on, which is what
/// the panel is switched to when the pointer arrives.
private struct KVMMachinesCard: View {
    @ObservedObject var controller: MonitorController
    @State private var newHost = ""
    @State private var newInput: UInt16 = 0x11      // HDMI: the usual spare

    private var inputChoices: [(value: UInt16, label: String)] {
        HPProfile.inputNames.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        Card(title: "KVM Machines", systemImage: "rectangle.on.rectangle.angled",
             help: "The pointer leaves the Mac at the panel's right edge and "
                 + "enters the first machine. Pushing past that machine's right "
                 + "edge enters the next. Each machine's input is what the "
                 + "monitor is switched to when the pointer arrives there.") {
            if controller.kvmMachines.isEmpty {
                Text("No machines yet. Add the host you can already reach over SSH.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
            }
            ForEach(Array(controller.kvmMachines.enumerated()), id: \.element.id) { i, machine in
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 14, alignment: .trailing)
                    // Source-code parity at a glance: green = the deployed agent
                    // matches what this app ships, amber = running but a redeploy
                    // would change it, grey = not running (or, with a grey name,
                    // the box is unreachable).
                    let health = controller.machineHealth[machine.host] ?? .unknown
                    Circle()
                        .fill(dotColor(health))
                        .frame(width: 7, height: 7)
                        .help(healthDescription(health))
                    Text(machine.host)
                        .font(.system(size: 13))
                        .foregroundStyle(health == .unreachable ? Theme.textDim : Theme.textPrimary)
                    Spacer(minLength: 8)
                    if machine.width > 1 {
                        Text("\(Int(machine.width))×\(Int(machine.height))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textDim)
                    }
                    StyledPicker(options: inputChoices,
                                 selection: Binding(
                                    get: { machine.input },
                                    set: { controller.kvmMachines[i].input = $0 }),
                                 enabled: !controller.kvmEnabled, width: 150)
                    // Eyes on that machine, whatever the panel is showing. Live,
                    // view-only, through its agent and an SSH tunnel of its own.
                    Button {
                        ConsoleViewer.shared.open(host: machine.host, name: machine.name,
                                                  size: CGSize(width: machine.width, height: machine.height))
                    } label: {
                        Image(systemName: "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("View \(machine.host)'s screen, live")
                    // The heavier path: a real RDP session with pixels, which
                    // CAN see and answer a UAC prompt or the sign-in screen.
                    // Connecting takes the console over until you disconnect.
                    Button {
                        RDPControl.shared.open(host: machine.host, name: machine.name,
                                               size: CGSize(width: machine.width, height: machine.height))
                    } label: {
                        Image(systemName: "cursorarrow.rays")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Control \(machine.host) over RDP — sees the sign-in / UAC screen; "
                        + "takes its console over while connected")
                    Button {
                        controller.kvmMachines.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.kvmEnabled)
                    .help("Remove \(machine.host) from the chain")
                }
            }

            Divider().overlay(Theme.rule).padding(.vertical, 2)

            HStack(spacing: 8) {
                TextField("ssh host", text: $newHost)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.35)))
                    .frame(width: 140)
                StyledPicker(options: inputChoices, selection: $newInput,
                             enabled: true, width: 150)
                Spacer(minLength: 0)
                Button("Add") {
                    let host = newHost.trimmingCharacters(in: .whitespaces)
                    guard !host.isEmpty,
                          !controller.kvmMachines.contains(where: { $0.host == host }) else { return }
                    controller.kvmMachines.append(
                        KVMController.Machine(name: host, host: host, input: newInput))
                    newHost = ""
                }
                .buttonStyle(.plain)
                // Greyed while armed, like the picker and the remove button: a
                // machine added now has no transport (those are opened once, in
                // enable()), and the chooser would offer a tile that hands
                // control straight back.
                .disabled(controller.kvmEnabled)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            }

            if controller.kvmEnabled {
                Text("Switch the KVM off to change the chain.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textDim)
            }
        }
        // Refresh the parity dots when the card comes into view, throttled so a
        // tab flick does not fan out a burst of SSH probes.
        .onAppear { controller.checkParityNow() }
    }

    private func dotColor(_ health: MachineHealth) -> Color {
        switch health {
        case .ok:          return Theme.ok
        case .mismatch:    return Theme.warning
        case .notRunning, .unreachable, .unknown: return Theme.textDim
        }
    }

    private func healthDescription(_ health: MachineHealth) -> String {
        switch health {
        case .ok:          return "Agent source matches this app — a redeploy would change nothing."
        case .mismatch:    return "Agent is running but its source differs from this app. Redeploy to match."
        case .notRunning:  return "Reachable, but no agent is running there."
        case .unreachable: return "Not reachable over SSH — the machine may be off or asleep."
        case .unknown:     return "Checking…"
        }
    }
}
