import SwiftUI

/// Visual language modelled on HP Display Center: near-black canvas, flat cards
/// with a hairline rule under each title, and a single blue accent.
enum Theme {
    static let canvas       = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let card         = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let cardStroke   = Color.white.opacity(0.06)
    static let rule         = Color.white.opacity(0.14)

    static let accent       = Color(red: 0.114, green: 0.549, blue: 0.925)
    static let accentDim    = Color(red: 0.114, green: 0.549, blue: 0.925).opacity(0.35)

    static let textPrimary  = Color(white: 0.94)
    static let textSecond   = Color(white: 0.62)
    static let textDim      = Color(white: 0.42)

    static let warning      = Color(red: 0.98, green: 0.68, blue: 0.22)
    static let danger       = Color(red: 0.95, green: 0.36, blue: 0.33)
    static let ok           = Color(red: 0.36, green: 0.80, blue: 0.47)

    static let cardRadius: CGFloat = 8
}

// MARK: - Card

struct Card<Content: View>: View {
    let title: String
    var systemImage: String
    var help: String? = nil
    @ViewBuilder var content: Content

    @State private var showHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let help {
                    Button { showHelp.toggle() } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                        Text(help)
                            .font(.system(size: 12))
                            .frame(width: 320, alignment: .leading)
                            .padding(14)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Rectangle()
                .fill(Theme.rule)
                .frame(height: 1)
                .padding(.horizontal, 18)

            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)

            // No Spacer here. One used to sit at the bottom to make cards in a
            // row match heights, and a Spacer takes every point of height it is
            // offered — so each card grew to its container, the container grew to
            // the window, and the window had no reason to shrink. A tab of six
            // short cards rendered as six tall ones separated by black.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1))
                // Enough to lift the card off the canvas and no more. On a dark
                // ground a heavy shadow reads as smudge rather than depth, since
                // there is very little tonal room beneath the background to cast
                // into.
                .shadow(color: .black.opacity(0.45), radius: 9, x: 0, y: 3)
        )
    }
}

// MARK: - Controls styled like the HP panel

struct RadioRow: View {
    let label: String
    let isOn: Bool
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .strokeBorder(isOn ? Theme.accent : Theme.textDim, lineWidth: 1.6)
                        .frame(width: 16, height: 16)
                    if isOn {
                        Circle().fill(Theme.accent).frame(width: 8, height: 8)
                    }
                }
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
            }
            // Without this only the drawn glyphs are hit-testable, so the hollow
            // middle of the ring — the obvious place to aim — did nothing.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? (hovering ? 0.5 : 1) : 0.5)
        .onHover { inside in
            guard enabled else { return }
            hovering = inside
        }
    }
}

struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
            Spacer(minLength: 8)
            Button {
                if enabled { isOn.toggle() }
            } label: {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn ? Theme.accent : Color.white.opacity(0.18))
                        .frame(width: 40, height: 21)
                    Circle()
                        .fill(.white)
                        .frame(width: 15, height: 15)
                        .padding(.horizontal, 3)
                }
                .animation(.easeInOut(duration: 0.15), value: isOn)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            Text(isOn ? "On" : "Off")
                .font(.system(size: 13))
                .foregroundStyle(enabled ? Theme.textSecond : Theme.textDim)
                .frame(width: 26, alignment: .leading)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Dropdown drawn to match the HP panel's bordered select.
struct StyledPicker<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var enabled: Bool = true
    var width: CGFloat? = nil

    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button(option.label) { selection = option.value }
            }
        } label: {
            HStack {
                Text(options.first { $0.value == selection }?.label ?? "—")
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecond)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled || options.isEmpty)
        .opacity(enabled ? 1 : 0.5)
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var enabled: Bool = true
    /// Fires true when a drag starts and false when it ends.
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onCommit: () -> Void = {}
    /// The filled part of the track. Channel sliders use their own colour, so a
    /// row of three reads as red, green and blue at a glance rather than as three
    /// identical blue bars with words above them.
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
                Spacer()
                Text("\(Int(value))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecond)
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                onEditingChanged(editing)
                if !editing { onCommit() }
            })
            .tint(tint)
            .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

/// A slider over named steps rather than numbers.
///
/// Laid out exactly like SliderRow — same row, same geometry — but the readout on
/// the right is the step's NAME where a plain slider shows its value. That suits a
/// setting whose positions the monitor names ("Soft", "Level 2", "Sharp"): the
/// spacing is a real progression, so a slider is honest, but the numbers behind it
/// mean nothing to anyone.
///
/// Writes as the knob crosses each detent, so the panel tracks the drag.
///
/// While a drag is in progress the knob follows the finger and NOTHING else moves
/// it. That is the whole trick: each write updates the monitor's reported value,
/// and if the knob is bound to that value it gets yanked backwards every time one
/// lands, which reads as the control fighting you. The monitor's value is ignored
/// until the drag ends.
///
/// One write per detent crossed, never one per pixel of travel — each is its own
/// round trip.
struct NamedStepSlider: View {
    let label: String
    /// In display order, smallest first.
    let steps: [(value: UInt16, label: String)]
    let current: UInt16
    var enabled: Bool = true
    let onChange: (UInt16) -> Void

    @State private var live: Double?
    @State private var dragging = false
    @State private var lastSent: Int?
    /// The step just written, held until the monitor reports it.
    @State private var pending: UInt16?

    private var index: Int { steps.firstIndex { $0.value == current } ?? 0 }

    var body: some View {
        // Under the finger while dragging; under the monitor's control otherwise.
        let held = pending.flatMap { p in steps.firstIndex { $0.value == p } }
        let shown = dragging ? (live ?? Double(index)) : Double(held ?? index)
        let at = Int(shown.rounded())
        let name = steps.indices.contains(at) ? steps[at].label : "—"
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
                Spacer()
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecond)
            }
            Slider(value: Binding(get: { shown },
                                  set: { newValue in
                                      live = newValue
                                      let i = Int(newValue.rounded())
                                      guard i != lastSent, steps.indices.contains(i)
                                      else { return }
                                      lastSent = i
                                      let sent = steps[i].value
                                      pending = sent
                                      onChange(sent)
                                      Task { @MainActor in
                                          try? await Task.sleep(nanoseconds: 1_500_000_000)
                                          if pending == sent { pending = nil }
                                      }
                                  }),
                   in: 0...Double(max(steps.count - 1, 1)),
                   step: 1,
                   onEditingChanged: { editing in
                       dragging = editing
                       if editing {
                           lastSent = index      // where this drag started
                       } else {
                           live = nil
                           lastSent = nil
                       }
                   })
            .tint(Theme.accent)
            .disabled(!enabled)
        }
        .opacity(enabled ? 1 : 0.5)
        .onChange(of: current) { _, now in
            if now == pending { pending = nil }
        }
    }
}

/// Explains why a control is inert, in place, instead of silently disabling it.
struct UnavailableNote: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}


/// Dims a control to half opacity while the pointer is over it.
struct HoverDim: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .opacity(hovering ? 0.5 : 1)
            .onHover { hovering = $0 }
    }
}

/// A switch that keeps its colour when the window is not the active one.
///
/// The stock macOS switch draws itself grey whenever its window is inactive,
/// and a menu bar popover is inactive most of the time — so the one control
/// whose state matters at a glance was the one control refusing to show it.
/// Reading "is the PC holding my keyboard right now" should not depend on which
/// window happens to have focus.
///
/// Green for on, amber for off, drawn the same either way.
struct StatusToggleStyle: ToggleStyle {
    var on: Color = Theme.ok
    var off: Color = Theme.warning

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = 20
        let width: CGFloat = 34
        return Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? on : off)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .frame(width: height - 4, height: height - 4)
                    .padding(.horizontal, 2)
            }
            .frame(width: width, height: height)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
