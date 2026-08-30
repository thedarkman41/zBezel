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
struct PiPPlacementPicker: View {
    /// 0 bottom-right, 1 top-left, 2 top-right, 3 bottom-left — the panel's own
    /// numbering, which is not in any sensible order and is therefore mapped
    /// here rather than assumed anywhere else.
    /// nil when the panel's placement is not known — it cannot be read back,
    /// so nothing is filled in until this app has set it.
    @Binding var placement: Int?
    var enabled: Bool
    var onPick: (Int) -> Void

    private static let corners: [(value: Int, x: UnitPoint)] = [
        (1, .topLeading), (2, .topTrailing), (3, .bottomLeading), (0, .bottomTrailing),
    ]

    var body: some View {
        ScreenOutline(active: enabled) {
            GeometryReader { geo in
                let inset = geo.size.width * 0.055
                let w = geo.size.width * 0.26
                let h = w / screenAspect
                ZStack {
                    ForEach(PiPPlacementPicker.corners, id: \.value) { corner in
                        let chosen = placement == corner.value
                        RoundedRectangle(cornerRadius: 2)
                            .fill(chosen ? Theme.accent : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(chosen ? Theme.accent : Theme.textDim, lineWidth: 1)
                            )
                            .frame(width: w, height: h)
                            .position(point(for: corner.x, in: geo.size, box: CGSize(width: w, height: h),
                                            inset: inset))
                            .contentShape(Rectangle())
                            .onTapGesture { if enabled { onPick(corner.value) } }
                    }
                }
            }
        }
        .opacity(enabled ? 1 : 0.4)
    }

    private func point(for anchor: UnitPoint, in size: CGSize,
                       box: CGSize, inset: CGFloat) -> CGPoint {
        let x = anchor.x < 0.5 ? inset + box.width / 2 : size.width - inset - box.width / 2
        let y = anchor.y < 0.5 ? inset + box.height / 2 : size.height - inset - box.height / 2
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Size

/// Four nested boxes growing out of the bottom-left corner.
///
/// Clicking anywhere cycles. The steps are shown filled rather than outlined,
/// each one a little stronger than the last, so the current size reads as a
/// quantity rather than as a number.
struct PiPSizePicker: View {
    @Binding var size: Int
    var steps: Int = 4
    var enabled: Bool
    var onPick: (Int) -> Void

    var body: some View {
        ScreenOutline(active: enabled) {
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    ForEach((0..<steps).reversed(), id: \.self) { step in
                        let scale = CGFloat(step + 1) / CGFloat(steps)
                        let filled = step <= size
                        RoundedRectangle(cornerRadius: 2)
                            .fill(filled
                                  ? Theme.accent.opacity(0.30 + 0.20 * Double(steps - step))
                                  : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(Theme.textDim.opacity(filled ? 0 : 0.8), lineWidth: 1)
                            )
                            .frame(width: geo.size.width * scale,
                                   height: geo.size.height * scale)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if enabled { onPick((size + 1) % steps) } }
            }
        }
        .opacity(enabled ? 1 : 0.4)
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
