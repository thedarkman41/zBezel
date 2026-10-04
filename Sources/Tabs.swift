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
struct MonitorSideUnavailable: View {
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
        // Input Source and DisplayPort on the left; Image Optimization, USB-C and
        // KVM Machines on the right. BalancedColumns measures and pins both columns
        // to the taller one's height, and the shorter column's `fill: true` card
        // (DisplayPort on the left, KVM Machines on the right) grows its own
        // background to match — tops and bottoms level, 16-pt gaps throughout, no
        // grey above a card or in an uneven gap between tiles.
        BalancedColumns {
            inputSourceCard
            displayPortCard
        } right: {
            imageOptimizationCard
            usbCCard
            KVMMachinesCard(controller: controller, fill: true)
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
             work over any connection — including one where DDC/CI is unavailable.
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
            .padding(.leading, 14)

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
            .padding(.leading, 14)
        }
    }

    private var displayPortCard: some View {
        Card(title: "DisplayPort", systemImage: "cable.connector",
             help: "Selects the DisplayPort protocol version the monitor negotiates. Not a standard MCCS feature.",
             fill: true) {
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
        // Image sliders on the left, the read-only Panel facts on the right.
        // (The monitor's power mode lives on the Power tab.) Both are single-card
        // columns, which the .fixedSize idiom cannot stretch to match, so this tab
        // measures (BalancedColumns): both adopt the taller one's height and the
        // shorter column's `fill: true` card grows its own background to match —
        // tops and bottoms level, no grey above a card or in a gap between tiles.
        BalancedColumns {
            Card(title: "Image", systemImage: "sun.max",
                 help: "MCCS luminance (0x10), contrast (0x12) and sharpness (0x87).",
                 fill: true) {
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
        } right: {
            Card(title: "Panel", systemImage: "info.circle",
                 help: "Read-only facts the monitor reports about itself.",
                 fill: true) {
                if let edid = controller.selected?.edid {
                    InfoRow("Model", edid.displayName)
                    InfoRow("Manufacturer", edid.manufacturerID)
                    InfoRow("Serial", edid.serialString ?? "—")
                    InfoRow("Manufactured", "week \(edid.manufactureWeek), \(edid.manufactureYear)")
                    InfoRow("Panel size", String(format: "%.1f″ diagonal", edid.diagonalInches))
                    InfoRow("Connection", controller.currentInputName ?? edid.digitalInterface)
                    if let depth = edid.bitDepth { InfoRow("Bit depth", "\(depth) bits per color") }
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

    /// A white the user has dragged the dot to, overriding the active space's
    /// default. Cleared when the color mode changes so the dot snaps to the new
    /// space's white.
    @State private var whiteOverride: EDID.Chromaticity?

    private static let d65 = EDID.Chromaticity(x: 0.3127, y: 0.3290)

    /// What the diagram should draw right now: the triangle of the color space in
    /// force, whether that is a standard target or the panel's native gamut, and
    /// the white that space aims for.
    private struct ActiveSpace {
        let gamut: EDID.ColorPrimaries
        let name: String
        /// A standard space emulated over the native panel — draw the native gamut
        /// faintly behind it, and leave the white fixed (not draggable).
        let isStandard: Bool
        let white: EDID.Chromaticity
    }

    private func activeSpace(_ edid: EDID) -> ActiveSpace {
        let native = edid.colorPrimaries
        let nativeWhite = edid.nativeWhitePoint ?? Self.d65
        func ref(_ name: String) -> EDID.ColorPrimaries {
            guard let r = EDID.referenceGamuts.first(where: { $0.name == name }) else { return native }
            return EDID.ColorPrimaries(red: r.red, green: r.green, blue: r.blue, white: Self.d65)
        }
        switch controller.features[0xDC]?.current ?? 0x00 {
        case 0x01: return ActiveSpace(gamut: ref("sRGB"),   name: "sRGB",       isStandard: true,  white: Self.d65)
        case 0x02: return ActiveSpace(gamut: ref("BT.709"), name: "BT.709",     isStandard: true,  white: Self.d65)
        case 0x05: return ActiveSpace(gamut: ref("DCI-P3"), name: "Display P3", isStandard: true,  white: Self.d65)
        default:
            // Native-primary modes (Native, Color Match, the white-balance
            // presets, Enhance+): native gamut, white read back from the live
            // gains where possible, else the panel's declared white.
            let w = controller.whitePointForCurrentGains(primaries: native) ?? nativeWhite
            let name = HPProfile.colorMode(for: controller.features[0xDC]?.current ?? 0x00)?.name ?? "Native"
            return ActiveSpace(gamut: native, name: name, isStandard: false, white: w)
        }
    }

    private func gamutCaption(_ a: ActiveSpace) -> String {
        if a.isStandard {
            return "White triangle: \(a.name) · dashed: native panel gamut · dot: D65 white"
        }
        return "White triangle: \(a.name) gamut · dot: white point — drag to re-balance"
    }

    var body: some View {
        // Explicit columns rather than the shared two-up grid. The grid fills
        // row by row, which put Black Level under Color Mode; the two channel
        // cards belong together, one under the other.
        VStack(alignment: .trailing, spacing: 9) {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 16) {
            Card(title: "Color Mode", systemImage: "paintpalette",
                 help: "The nine modes on the monitor's Color menu (0xDC). They are "
                     + "three different kinds of setting, so they are grouped rather "
                     + "than listed flat. 0x14 mirrors the choice but is not what the "
                     + "OSD drives.") {
                if let mode = controller.features[0xDC], mode.readable {
                    ColorModeList(current: mode.current,
                                  enabled: controller.controlsLive) { value in
                        // Writes the mode, then re-reads the gains and black levels
                        // it recomputes; holds refreshingColor so the sliders dim
                        // until the new values land.
                        Task<Void, Never> { await controller.setColorMode(value) }
                    }
                } else {
                    StyledPicker(options: [(value: UInt16(1), label: "sRGB")],
                                 selection: .constant(UInt16(1)), enabled: false, width: 220)
                    MonitorSideUnavailable(controller: controller)
                }
            }
            // Stretch so the mode list fills above the white-point card and the
            // two columns end level instead of the taller one trailing off alone.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // The white point in force — the active space's target, or a custom
            // balance dragged on the diagram below. Updates live with the mode and
            // the dot, so it sits with the modes as a readout of the current white.
            Card(title: "White Point", systemImage: "sun.max",
                 help: "The white point in force: the active color space's target, "
                     + "or the custom balance you drag the diagram's dot to — as CIE "
                     + "1931 x, y and correlated color temperature. Drag the dot in "
                     + "Native or a white-balance mode to re-balance the panel.") {
                if let edid = controller.selected?.edid {
                    let active = activeSpace(edid)
                    let w = whiteOverride ?? active.white
                    VStack(alignment: .leading, spacing: 8) {
                        ControlRow(label: "CIE 1931") {
                            Text(w.label)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Theme.textSecond)
                        }
                        if let cct = EDID.cct(x: w.x, y: w.y) {
                            ControlRow(label: "Temperature") {
                                Text("\(cct) K"
                                     + (EDID.illuminant(x: w.x, y: w.y).map { "  ·  \($0)" } ?? ""))
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Theme.textSecond)
                            }
                        }
                        ControlRow(label: whiteOverride == nil ? "Space" : "Balance") {
                            Text(whiteOverride == nil ? active.name : "Custom")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textSecond)
                        }
                    }
                } else {
                    Text("Not declared in the EDID.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
            }
            }
            .frame(maxWidth: .infinity, alignment: .top)

            VStack(spacing: 16) {
            Card(title: "RGB Gain", systemImage: "slider.horizontal.3",
                 help: "MCCS video gain: red 0x16, green 0x18, blue 0x1A.") {
                if [0x16, 0x18, 0x1A].contains(where: { controller.features[$0]?.readable == true }) {
                    Group {
                        FeatureSlider(code: 0x16, label: "Red", controller: controller, tint: Color(red: 0.92, green: 0.34, blue: 0.34))
                        FeatureSlider(code: 0x18, label: "Green", controller: controller, tint: Color(red: 0.34, green: 0.82, blue: 0.44))
                        FeatureSlider(code: 0x1A, label: "Blue", controller: controller, tint: Color(red: 0.36, green: 0.58, blue: 0.98))
                    }
                    // Dim and lock while a mode change re-reads them, so the
                    // outgoing values do not read as current mid-swap.
                    .opacity(controller.refreshingColor ? 0.35 : 1)
                    .disabled(controller.refreshingColor)
                    .animation(.easeInOut(duration: 0.2), value: controller.refreshingColor)
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
                    Group {
                        FeatureSlider(code: 0x6C, label: "Red", controller: controller, tint: Color(red: 0.92, green: 0.34, blue: 0.34))
                        FeatureSlider(code: 0x6E, label: "Green", controller: controller, tint: Color(red: 0.34, green: 0.82, blue: 0.44))
                        FeatureSlider(code: 0x70, label: "Blue", controller: controller, tint: Color(red: 0.36, green: 0.58, blue: 0.98))
                    }
                    .opacity(controller.refreshingColor ? 0.35 : 1)
                    .disabled(controller.refreshingColor)
                    .animation(.easeInOut(duration: 0.2), value: controller.refreshingColor)
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

        // The panel's color identity from the EDID — read-only, a picture of what
        // it can reproduce, kept full-width below the controls.
        if let edid = controller.selected?.edid {
            let active = activeSpace(edid)
            Card(title: "Color Gamut", systemImage: "triangle",
                 help: "The color space in force on the CIE 1931 diagram — the "
                     + "calibrated space a mode selects, or the panel's native gamut "
                     + "— and how much of each standard space the panel covers. Drag "
                     + "the white dot in Native or a white-balance mode to re-balance "
                     + "the panel live.") {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        GamutDiagram(
                            gamut: active.gamut,
                            nativeOutline: active.isStandard ? edid.colorPrimaries : nil,
                            white: Binding(
                                get: { whiteOverride ?? active.white },
                                set: { whiteOverride = $0 }),
                            draggable: controller.controlsLive && !active.isStandard,
                            onWhite: { x, y, commit in
                                guard let nw = edid.nativeWhitePoint else { return }
                                controller.setWhitePoint(x: x, y: y,
                                                         primaries: edid.colorPrimaries,
                                                         nativeWhite: nw, commit: commit)
                            })
                            .frame(maxWidth: 260)
                        Text(gamutCaption(active))
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("COVERAGE")
                                .font(.system(size: 9.5, weight: .semibold)).kerning(0.6)
                                .foregroundStyle(Theme.textDim)
                            // sRGB and BT.709 share primaries, so BT.709 would just
                            // repeat sRGB's number — left out.
                            ForEach(EDID.referenceGamuts.filter { $0.name != "BT.709" }, id: \.name) { ref in
                                ControlRow(label: ref.name) {
                                    Text("\(edid.coverage(of: ref))%")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Theme.textSecond)
                                }
                            }
                        }
                        Divider().overlay(Theme.rule)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PANEL")
                                .font(.system(size: 9.5, weight: .semibold)).kerning(0.6)
                                .foregroundStyle(Theme.textDim)
                            if let g = edid.gamma {
                                ControlRow(label: "Gamma") {
                                    Text(String(format: "%.1f", g))
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Theme.textSecond)
                                }
                            }
                            if let bd = edid.bitDepth {
                                ControlRow(label: "Color depth") {
                                    Text("\(bd)-bit")
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Theme.textSecond)
                                }
                            }
                            if let enc = edid.pixelEncodings {
                                ControlRow(label: "Encoding") {
                                    Text(enc.joined(separator: ", "))
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Theme.textSecond)
                                }
                            }
                            ControlRow(label: "sRGB default") {
                                Text(edid.defaultsToSRGB ? "Yes" : "No")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Theme.textSecond)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        }

        // A whole card for one button was more furniture than the action
        // deserved. As a line of text under the columns it is still findable and
        // stops competing with the settings for attention.
        Button("Restore factory color") {
            Task<Void, Never> { await controller.set(code: 0x08, value: 1) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .foregroundStyle(controller.monitorControlAvailable ? Theme.accent : Theme.textDim)
        .disabled(!controller.monitorControlAvailable)
        .help("MCCS restore factory color defaults (0x08).")
        }
        // Pin the white-balance reference from the panel's native state, so a
        // dragged white solves against gains known to produce the native white.
        .onAppear {
            if let w = controller.selected?.edid?.nativeWhitePoint {
                controller.captureWhiteReference(nativeWhite: w)
            }
        }
        // A new color mode brings its own white; drop any custom drag so the dot
        // snaps to the new space rather than lingering on the old balance.
        .onChange(of: controller.features[0xDC]?.current) { _, _ in
            whiteOverride = nil
        }
    }
}

// MARK: - View

struct ViewTab: View {
    @ObservedObject var controller: MonitorController

    var body: some View {
        // Pivot and On-Screen Display stacked on the left, Monitor Menu (tall: it
        // carries the OSD preview and its sliders) on the right. BalancedColumns
        // measures and pins both columns to the taller one's height; the shorter
        // column's `fill: true` card grows its own background to match — tops and
        // bottoms level, no grey above a card or in an uneven gap between tiles.
        BalancedColumns {
            pivotCard
            onScreenDisplayCard
        } right: {
            monitorMenuCard
        }
    }

    private var pivotCard: some View {
        Card(title: "Pivot", systemImage: "rotate.right",
             help: "Turns the Mac's picture on the panel to match how the "
                 + "display is physically pivoted. A GPU framebuffer transform "
                 + "(IOFramebuffer), faded across the switch — it needs no DDC, "
                 + "so it works even though monitor control is proxied through "
                 + "the PC. Live while the Mac holds the panel's input.") {
            if controller.pivotAvailable {
                PivotControl(current: controller.pivotDegrees,
                             enabled: !controller.pivotBusy,
                             busy: controller.pivotBusy) { deg in
                    Task<Void, Never> { await controller.applyPivot(deg) }
                }
            } else {
                PivotControl(current: 0, enabled: false, busy: false) { _ in }
                Text("Live when a machine is on the panel — the Mac, or a PC on USB-C.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
            }

            Divider().overlay(Theme.rule).padding(.vertical, 2)

            Toggle(isOn: Binding(get: { controller.pivotAutoFollow },
                                 set: { controller.setPivotAutoFollow($0) })) {
                Text("Auto-follow panel")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(StatusToggleStyle())

            // The idle "what this does" description is dropped for compactness;
            // only the live loop status shows, and only while auto-follow is on.
            if controller.pivotAutoFollow {
                Text(controller.pivotFollowStatus.isEmpty ? "Reading the panel…"
                                                          : controller.pivotFollowStatus)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { controller.refreshPivot() }
    }

    // Three settings HP's Menu screen owns, reachable only as 0xE1 sub-selectors
    // and readable through no channel at all — so these show what this app last
    // set, and start at HP's factory values rather than pretending to have asked
    // the panel.
    private var monitorMenuCard: some View {
        Card(title: "Monitor Menu", systemImage: "menubar.rectangle",
             help: "Where the monitor's own menu appears, how long it stays up, "
                 + "and how transparent it is. Vendor sub-selectors 0x3B, 0x3C, "
                 + "0x3E and 0x56 — set only, never reported back.",
             fill: true) {
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
    }

    private var onScreenDisplayCard: some View {
        Card(title: "On-Screen Display", systemImage: "character.bubble",
             help: "MCCS OSD language (0xCC) and OSD/button lock (0xCA).",
             fill: true) {
            // Language and Controls share one row — a label above each dropdown,
            // side by side — so the card stays as short as its two controls.
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Language")
                    if controller.features[0xCC]?.readable == true {
                        FeaturePicker(code: 0xCC, controller: controller)
                    } else {
                        StyledPicker(options: [(value: UInt16(2), label: "English")],
                                     selection: .constant(UInt16(2)), enabled: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Controls")
                    if controller.features[0xCA]?.readable == true {
                        FeaturePicker(code: 0xCA, controller: controller)
                    } else {
                        StyledPicker(options: [(value: UInt16(2), label: "OSD enabled")],
                                     selection: .constant(UInt16(2)), enabled: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if controller.features[0xCA]?.readable != true {
                MonitorSideUnavailable(controller: controller)
            }
        }
    }
}

/// The four-orientation Pivot picker, laid out like HP's: a monitor glyph turned
/// to each angle, a radio dot, and the degree label. The chosen angle is tinted
/// with the accent; tapping one asks the controller to rotate (which fades).
private struct PivotControl: View {
    let current: Int
    var enabled: Bool
    var busy: Bool
    var onPick: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(DisplayRotation.steps, id: \.self) { deg in
                cell(deg)
            }
        }
        .opacity(enabled ? (busy ? 0.7 : 1) : 0.4)
        .overlay(alignment: .center) {
            if busy { ProgressView().controlSize(.small).colorScheme(.dark) }
        }
    }

    private func cell(_ deg: Int) -> some View {
        let chosen = current == deg
        return VStack(spacing: 9) {
            Image(systemName: "display")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(chosen ? Theme.accent : Theme.textSecond)
                .rotationEffect(.degrees(Double(deg)))
                .frame(height: 42)
            HStack(spacing: 6) {
                ZStack {
                    Circle().stroke(chosen ? Theme.accent : Theme.textDim, lineWidth: 1.5)
                    if chosen { Circle().fill(Theme.accent).padding(3) }
                }
                .frame(width: 13, height: 13)
                Text("\(deg)°")
                    .font(.system(size: 12))
                    .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecond)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(chosen ? Theme.accent.opacity(0.08) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(chosen ? Theme.accentDim : Theme.cardStroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if enabled && !busy { onPick(deg) } }
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

    /// The inputs offered for the two PiP sources, labeled.
    private var pipInputOptions: [(value: UInt16, label: String)] {
        [(value: 0x0F, label: HPProfile.inputLabel(0x0F)),
         (value: 0x11, label: HPProfile.inputLabel(0x11)),
         (value: 0x13, label: HPProfile.inputLabel(0x13))]
    }

    private var grid: some View {
        // Picture in Picture on the left, the short Displays list on the right.
        // Both are single-card columns, which the .fixedSize idiom cannot
        // stretch, so this tab measures (BalancedColumns): both adopt the taller
        // one's height and the Displays tile absorbs the slack inside its own
        // bottom, never as grey at the window top or a gap between the tiles.
        BalancedColumns {
            Card(title: "Picture in Picture", systemImage: "rectangle.inset.topright.filled",
                 help: """
                 None of this is in the public MCCS tables. HP puts all four settings behind \
                 0xE1's sub-addressing — 0x11 on/off, 0x12 mode, 0x13 size, 0x14 placement — \
                 found by experiment. The panel obeys these writes but will not report them \
                 back, so what is shown here is what was last sent, not a reading.
                 """,
                 fill: true) {
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

                // Why Placement and Size go dead: in side-by-side the two sources
                // split the panel evenly, so there is no inset to move or resize.
                if controller.pipOn && controller.pipSideBySide {
                    Text("Side by side splits the panel evenly — Placement and Size "
                         + "apply to the inset only, so they're off here. Tap Side by "
                         + "side again to go back to an inset and resize it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.pipOn {
                    Divider().overlay(Theme.rule).padding(.vertical, 2)
                    ControlRow(label: "Main input") {
                        StyledPicker(options: pipInputOptions,
                                     selection: Binding(
                                        get: { controller.pipPrimaryInput },
                                        set: { v in Task<Void, Never> { await controller.applyPiPPrimaryInput(v) } }),
                                     enabled: controller.pipOn, width: 170)
                    }
                    ControlRow(label: "PiP input") {
                        StyledPicker(options: pipInputOptions,
                                     selection: Binding(
                                        get: { controller.pipSecondaryInput },
                                        set: { v in Task<Void, Never> { await controller.applyPiPSecondaryInput(v) } }),
                                     enabled: controller.pipOn, width: 170)
                    }
                    HStack {
                        Text("Changing the main input keeps the PiP input constant.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Swap ⇄") {
                            Task<Void, Never> { await controller.swapPiPInputs() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
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
        } right: {
            Card(title: "Displays macOS Can See", systemImage: "rectangle.on.rectangle",
                 help: "Arrangement and mirroring are macOS-side and unaffected by DDC/CI.",
                 fill: true) {
                ForEach(controller.displays) { display in
                    let mode = DisplayModes.current(for: display.id)
                    HStack(alignment: .top) {
                        Text(display.isBuiltIn ? "Built-in" : "External")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecond)
                            .frame(width: 130, alignment: .leading)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(display.name) — \(mode?.resolutionLabel ?? "—")")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                            if let mode, mode.isHiDPI {
                                // Build as a String so SwiftUI does not apply
                                // locale digit grouping ("5,120") the way it does
                                // to an Int interpolated into a Text literal.
                                Text(verbatim: "HiDPI \(mode.pixelWidth) × \(mode.pixelHeight)")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textDim)
                                    .padding(.leading, 14)
                            }
                            if let w = display.edid?.nativeWhitePoint {
                                Text("White point \(w.label)"
                                     + (display.edid?.whitePointCCT.map { " · \($0) K" } ?? ""))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textDim)
                                    .padding(.leading, 14)
                            }
                        }
                        Spacer(minLength: 0)
                    }
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
    var fill = false
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
                 + "monitor is switched to when the pointer arrives there.",
             fill: fill) {
            if controller.kvmMachines.isEmpty {
                Text("No machines on the network yet. One running the agent will "
                   + "appear here on its own.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(controller.kvmMachines.enumerated()), id: \.element.id) { i, machine in
                HStack(spacing: 8) {
                    Text("\(i + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 14, alignment: .trailing)
                    // Source-code parity at a glance: green = the deployed agent
                    // matches what this app ships, amber = running but a redeploy
                    // would change it, gray = not running (or, with a gray name,
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
                    // A fixed, left-aligned column so the resolutions line up
                    // down the card whatever the host names measure. Reserved
                    // even when a size is unknown, so nothing else shifts.
                    Text(machine.width > 1 ? "\(Int(machine.width))×\(Int(machine.height))" : "")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 84, alignment: .leading)
                    // Read-only: the input is detected from the monitor face the
                    // machine reports, not chosen. A pin gets its input when added.
                    StyledPicker(options: inputChoices,
                                 selection: Binding(get: { machine.input }, set: { _ in }),
                                 enabled: false, width: 150, centered: true)
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
                    // A discovered machine drops on its own when it stops
                    // announcing, so the remove control is only for a pinned host.
                    if !controller.isDiscovered(host: machine.host) {
                        Button {
                            controller.forgetMachine(host: machine.host)
                        } label: {
                            Image(systemName: "minus.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .help("Forget the pinned host \(machine.host)")
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ok)
                            .frame(width: 14)
                            .help("Discovered on the network")
                    }
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
                             enabled: true, width: 150, centered: true)
                Spacer(minLength: 0)
                Button("Pin") {
                    controller.addManualPin(host: newHost, input: newInput)
                    newHost = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            }

            Text("Machines running the agent appear here on their own and drop when "
               + "they go quiet, even while the KVM is on. Pin a host only for one on "
               + "another network that cannot be discovered.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
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
