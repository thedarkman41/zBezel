import SwiftUI

/// Picture-in-Picture, drawn rather than listed.
///
/// These settings are spatial — a corner, a size, a split — and a spatial
/// control says what it means without a label. Four radio buttons reading
/// "upper left, upper right, lower left, lower right" ask the reader to hold a
/// picture in their head that the control could simply have shown them.
///
/// Every diagram is 16:9, and so is every inset inside it, so what is on screen
/// is the shape of what the panel will do.

private let screenAspect: CGFloat = 16.0 / 9.0

/// The panel outline every one of these sits in.
private struct ScreenOutline<Content: View>: View {
    var active: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .aspectRatio(screenAspect, contentMode: .fit)
            .background(Theme.card)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(active ? Theme.accent.opacity(0.55) : Theme.rule, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Placement

/// The four corners, as four corners.
///
/// Laid out as four quadrants rather than four positioned boxes. The first
/// attempt used .position and then .contentShape, which is the wrong order: the
/// tap area is taken AFTER positioning, so each of the four claimed the whole
/// diagram and they fought over every click. Nothing responded.
///
/// Quadrants also make the targets the size of a quarter of the picture rather
/// than the size of the little rectangle drawn inside it.
struct PiPPlacementPicker: View {
    @Binding var placement: Int
    var enabled: Bool
    var busy: Bool = false
    var onPick: (Int) -> Void

    var body: some View {
        ScreenOutline(active: enabled) {
            // 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right — reading
            // order. An earlier mapping here had these rotated, derived from
            // observations that arrived out of step with the writes that caused
            // them. Re-derived one click at a time: every corner was landing in
            // the wrong place, consistently.
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    quadrant(0, .topLeading)
                    quadrant(1, .topTrailing)
                }
                HStack(spacing: 0) {
                    quadrant(2, .bottomLeading)
                    quadrant(3, .bottomTrailing)
                }
            }
        }
        .overlay(alignment: .center) {
            if busy { ProgressView().controlSize(.small).colorScheme(.dark) }
        }
        .opacity(enabled ? (busy ? 0.7 : 1) : 0.4)
    }

    private func quadrant(_ value: Int, _ alignment: Alignment) -> some View {
        let chosen = placement == value
        return RoundedRectangle(cornerRadius: 2)
            .fill(chosen ? Theme.accent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(chosen ? Theme.accent : Theme.textDim, lineWidth: 1)
            )
            .aspectRatio(screenAspect, contentMode: .fit)
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .contentShape(Rectangle())            // the whole quadrant is the target
            .onTapGesture { if enabled && !busy { onPick(value) } }
    }
}

// MARK: - Size

/// The three size presets, named as HP's own menu names them.
///
/// 0xE1 sub-selector 0x13 IS the PIP Size menu, and its five values are that
/// menu's five entries: 0 Enlarge, 1 Reduce, 2 Set to Maximum, 3 Set to Minimum,
/// 4 Set to Default. The capabilities string declares only 02 03 04 — the two
/// step commands are real and undeclared — which is why probing the declared list
/// alone found three "sizes" and no way to move between them.
///
/// The raw values are not in size order, so the enum carries them explicitly
/// rather than letting anything infer an ordering from the number.
///
/// Mapped wrongly twice before anyone looked at the monitor's own menu, and every
/// wrong answer came from inferring meaning out of behaviour: 2 looked like
/// "maximum" and 3 like "minimum" only because each happened to be bigger or
/// smaller than wherever the panel sat at that moment, and 4 was called "medium"
/// when it is the DEFAULT. A photograph of the OSD settled in a minute what hours
/// of differential probing had got backwards. Look at the device's own interface
/// FIRST; it is the specification.
enum PiPSize: Int, CaseIterable, Identifiable {
    case minimum = 3
    case standard = 4
    case maximum = 2

    var id: Int { rawValue }

    /// Small to large, which the raw values do NOT give.
    static let ordered: [PiPSize] = [.minimum, .standard, .maximum]

    /// The panel steps as well as jumps: 0x13 value 0 grows the inset by one
    /// small increment and 1 shrinks it, on a scale much finer than these three
    /// presets. Those two are not in the capabilities string, which declares only
    /// `13(02 03 04)` — the caps list is what the panel admits to, not the whole
    /// of what it accepts.
    ///
    /// A single step is very nearly invisible. Testing five of them and seeing
    /// only the blank-and-redraw that accompanies every size change is what once
    /// got these written off as no-ops; the increment is real and shows over
    /// twenty or thirty.
    static let growCommand = 0
    static let shrinkCommand = 1

    var label: String {
        switch self {
        case .minimum:  return "Set to Minimum Size"
        case .standard: return "Set to Default Size"
        case .maximum:  return "Set to Maximum Size"
        }
    }

    /// How strongly this box is tinted.
    ///
    /// Distinct per size rather than one colour at one opacity. The boxes are
    /// concentric, so each is seen as a ring around the next, and giving each its
    /// own shade makes the three read as three at a glance — deepest at the
    /// centre, where the smallest sits.
    var shade: Double {
        switch self {
        case .minimum:  return 0.78
        case .standard: return 0.46
        case .maximum:  return 0.22
        }
    }

    /// Fraction of the diagram each box occupies.
    ///
    /// The largest fills the outline exactly, so the diagram is THREE boxes and
    /// not three inside a fourth that means nothing. The ratios between them are
    /// the panel's real ones — large is a quarter of the screen, medium and small
    /// step down from it — scaled up so the largest reaches the edge.
    var fraction: CGFloat {
        switch self {
        case .minimum:  return 0.52
        case .standard: return 0.74
        case .maximum:  return 1.00
        }
    }
}

/// The three sizes as three nested rectangles, with a jog slider beneath.
///
/// Nested and anchored in one corner because that is how the inset behaves — it
/// grows out of wherever it is placed — and drawn to the real proportions, so the
/// largest box really is a quarter of the screen. Three boxes and no fourth: the
/// largest IS the panel outline.
///
/// Nothing is highlighted until a size is chosen in this session. The panel does
/// not report its size — 0x13 reads a latched constant that follows neither the
/// presets nor the steps, no plain VCP code differs between sizes, and the
/// sub-selector read channel only surfaces 8 of the ~40 the panel declares. So the
/// picker shows what it set, and claims nothing before that.
struct PiPSizePicker: View {
    var current: PiPSize?
    var enabled: Bool
    var busy: Bool = false
    var onPick: (PiPSize) -> Void
    /// The knob is off centre: step in this direction, at this intensity.
    /// True grows. Intensity runs 0 at the dead zone to 1 at full deflection.
    var onJogBegin: (Bool, Double) -> Void
    /// The knob was released or came back to centre: stop.
    var onJogEnd: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            boxes
            JogSlider(enabled: enabled, onJog: onJogBegin, onEnd: onJogEnd)
        }
    }

    private var boxes: some View {
        ScreenOutline(active: enabled) {
            GeometryReader { geo in
                // Largest at the back so a click lands on the smallest box that
                // contains it — the one the eye says it is on.
                ZStack(alignment: .bottomLeading) {
                    ForEach(PiPSize.ordered.reversed()) { size in
                        let chosen = current == size
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Theme.accent.opacity(size.shade))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(chosen ? Color.white : Theme.textDim.opacity(0.6),
                                            lineWidth: chosen ? 2 : 1)
                            )
                            .frame(width: geo.size.width * size.fraction,
                                   height: geo.size.height * size.fraction)
                            .contentShape(Rectangle())
                            .onTapGesture { if enabled && !busy { onPick(size) } }
                            .help(size.label)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .overlay(alignment: .center) {
            if busy { ProgressView().controlSize(.small).colorScheme(.dark) }
        }
        .opacity(enabled ? (busy ? 0.7 : 1) : 0.4)
    }
}

/// A spring-loaded jog knob: hold it off centre to keep stepping, let go and it
/// returns.
///
/// Not a value slider. Its position means a RATE, not a size — which suits a
/// panel that reports no size at all and can only be told "one step bigger".
/// Dragging right steps the inset up as fast as the writes complete, left steps
/// it down, and letting go springs the knob back to the middle.
private struct JogSlider: View {
    var enabled: Bool
    /// Direction and how hard, reported on every movement so the rate can follow
    /// the knob rather than only its side of centre.
    var onJog: (Bool, Double) -> Void
    var onEnd: () -> Void

    @State private var offset: CGFloat = 0
    /// nil when centred; otherwise the direction currently being stepped.
    @State private var direction: Bool?

    /// How far from centre before it counts as a direction. Without it, the
    /// tiniest tremor at rest would start and stop the write loop repeatedly.
    private let deadZone: CGFloat = 6
    private let knob: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let travel = max(0, (geo.size.width - knob) / 2)
            ZStack {
                track
                glassKnob
                    .offset(x: min(max(offset, -travel), travel))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard enabled else { return }
                                offset = min(max(value.translation.width, -travel), travel)
                                update(travel: travel)
                            }
                            .onEnded { _ in
                                stop()
                                // The spring is the whole point of the control:
                                // it says the knob was never holding a value.
                                withAnimation(.spring(response: 0.32,
                                                      dampingFraction: 0.55)) {
                                    offset = 0
                                }
                            }
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: knob + 4)
        .opacity(enabled ? 1 : 0.4)
        .help("Drag right to grow, left to shrink — springs back when released")
    }

    private var track: some View {
        ZStack {
            Capsule()
                .fill(Theme.card)
                .overlay(Capsule().stroke(Theme.rule, lineWidth: 1))
            HStack {
                Image(systemName: "minus.magnifyingglass")
                Spacer()
                Image(systemName: "plus.magnifyingglass")
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 7)
            // Centre detent, so the resting position is visibly a position.
            Rectangle()
                .fill(Theme.textDim.opacity(0.5))
                .frame(width: 1, height: 7)
        }
        .frame(height: 14)
    }

    /// Glass, hand-built rather than .glassEffect: that modifier needs the macOS
    /// 26 SDK, and this has to compile against whatever is installed.
    private var glassKnob: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle().fill(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.03)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
            .overlay(
                Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                    .blur(radius: 1).offset(y: 1).mask(Circle())
            )
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .frame(width: knob, height: knob)
    }

    /// Start, stop, reverse or re-rate the write loop as the knob moves.
    ///
    /// Reported on EVERY change, not only on crossing the dead zone, because the
    /// rate follows how far the knob is pushed and not merely which side of
    /// centre it is on.
    private func update(travel: CGFloat) {
        let now: Bool? = offset > deadZone ? true : (offset < -deadZone ? false : nil)
        if now != direction {
            direction = now
            if now == nil { onEnd() }
        }
        guard let now else { return }
        // 0 at the edge of the dead zone, 1 at the end of the track.
        let span = max(1, travel - deadZone)
        let t = min(1, max(0, (abs(offset) - deadZone) / span))
        onJog(now, Double(t))
    }

    private func stop() {
        if direction != nil { onEnd() }
        direction = nil
    }
}

// MARK: - Side by side

/// Two panes, in the order the panel actually puts them.
///
/// The PC is on the LEFT and the Mac on the RIGHT. That is not a guess or a
/// convention — it is what the monitor does, checked against a photograph of the
/// panel in side-by-side mode. It was the other way round here at first, which
/// made the diagram a mirror of the thing it was describing.
struct PiPSideBySidePicker: View {
    var active: Bool
    var enabled: Bool
    var onPick: () -> Void
    /// This Mac's display.
    var mac: NSImage?
    /// The PC's display.
    var pc: NSImage?

    var body: some View {
        ScreenOutline(active: active && enabled) {
            HStack(spacing: 1) {
                pane(image: pc, shade: 0.50)      // left
                pane(image: mac, shade: 0.28)     // right
            }
            .contentShape(Rectangle())
            .onTapGesture { if enabled { onPick() } }
        }
        .opacity(enabled ? 1 : 0.4)
    }

    private func pane(image: NSImage?, shade: Double) -> some View {
        ZStack {
            Rectangle().fill(Color.black)
            if active, let image {
                // .fit, not .fill. The panel squeezes each whole desktop into
                // half the width and letterboxes what is left over; filling and
                // cropping would show a magnified corner of one machine and
                // claim it was the layout.
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(active ? Theme.accent.opacity(shade) : Color.clear)
                    .overlay(Rectangle().stroke(active ? Color.clear : Theme.textDim, lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}
