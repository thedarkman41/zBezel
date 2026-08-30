import SwiftUI

/// Where the monitor's own menu sits, and how see-through it is — shown rather
/// than typed.
///
/// Two numbered sliders described this before. They were accurate and told the
/// reader nothing: "position across 97" is not a picture of anything. Dragging a
/// model of the menu around a model of the screen is the same two values with the
/// meaning left in.
///
/// The panel reports neither setting, so this shows what the app last set. It is
/// a schematic, not a measurement: the real menu's size relative to the screen is
/// not something DDC will tell us, so the proportions here are drawn to be
/// draggable rather than claimed to be exact.
struct OSDMenuPreview: View {
    /// 0-100, as HP's own menu numbers them.
    let horizontal: Int
    let vertical: Int
    let transparency: MonitorController.Transparency?
    var enabled: Bool
    let onMove: (Int, Int) -> Void
    let onTransparency: (MonitorController.Transparency) -> Void

    /// The menu's width as a fraction of the screen's. Chosen for a usable drag
    /// range; the real menu is larger. What is left over IS the travel, so the
    /// smaller this is the further the menu can go — and it reaches every corner,
    /// upper left to lower right, at any size.
    private let menuWidth: CGFloat = 0.45
    /// The menu is wider than it is tall by roughly this much, matching the shape
    /// of the real thing.
    private let menuAspect: CGFloat = 1.7

    @State private var drag: CGSize = .zero
    @State private var dragging = false
    @State private var liveStep: Int?
    /// Where the menu was dropped, held until the model agrees.
    ///
    /// Without this the picture springs back to the old position the instant the
    /// finger lifts and then jumps forward again when the write lands — twice
    /// wrong, and it reads as the drag having failed.
    @State private var pending: (h: Int, v: Int)?
    /// The transparency step just committed, held until the model reports it.
    @State private var pendingStep: MonitorController.Transparency?

    /// Most transparent on the LEFT, fully opaque on the right, which is the way
    /// round every other slider in the app runs.
    private var steps: [MonitorController.Transparency] {
        MonitorController.Transparency.allCases.reversed()
    }

    /// The step the preview is drawn at — the one under the finger while the
    /// slider is moving, the committed one otherwise.
    private var shownStep: MonitorController.Transparency {
        if let i = liveStep, steps.indices.contains(i) { return steps[i] }
        if let pendingStep { return pendingStep }
        return transparency ?? .p89
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = w * 9 / 16
                let mw = w * menuWidth
                let mh = mw / menuAspect
                // What is left over is the whole of the menu's travel, so 0 and
                // 100 put its edges against the screen's.
                let travelX = max(w - mw, 1)
                let travelY = max(h - mh, 1)
                let baseX = CGFloat(pending?.h ?? horizontal) / 100 * travelX
                // The panel counts vertical from the BOTTOM: its 0 is the bottom
                // of the screen, not the top. Observed directly — a menu dropped
                // at the bottom-left of this preview appeared at the top-left of
                // the monitor.
                let baseY = CGFloat(100 - (pending?.v ?? vertical)) / 100 * travelY
                let x = min(max(baseX + drag.width, 0), travelX)
                let y = min(max(baseY + drag.height, 0), travelY)

                ZStack(alignment: .topLeading) {
                    screen
                    menu(width: mw, height: mh)
                        .opacity(Double(shownStep.shown) / 100)
                        .offset(x: x, y: y)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    guard enabled else { return }
                                    dragging = true
                                    drag = v.translation
                                }
                                .onEnded { _ in
                                    dragging = false
                                    let hx = Int((x / travelX * 100).rounded())
                                    let vy = 100 - Int((y / travelY * 100).rounded())
                                    // Hold the drop, THEN clear the drag, so the
                                    // two never cancel out into the old position.
                                    pending = (hx, vy)
                                    drag = .zero
                                    onMove(hx, vy)
                                }
                        )
                }
                .frame(width: w, height: h)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            // Let go of the held position only once the model has caught up.
            .onChange(of: horizontal) { _, now in
                if let p = pending, p.h == now, p.v == vertical { pending = nil }
            }
            .onChange(of: vertical) { _, now in
                if let p = pending, p.v == now, p.h == horizontal { pending = nil }
            }

            HStack {
                Text("Position")
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
                Spacer()
                Text("\(horizontal), \(vertical)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecond)
            }

            transparencySlider
        }
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: The screen behind it

    private var screen: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.rule, lineWidth: 1))
    }

    // MARK: The menu itself

    /// A small likeness of HP's menu: title strip, the column of section names,
    /// the settings beside them, and the input line along the bottom.
    private func menu(width: CGFloat, height: CGFloat) -> some View {
        let unit = height / 22
        return VStack(spacing: 0) {
            Rectangle()
                .fill(Color(white: 0.42))
                .frame(height: unit * 2.2)
                .overlay(alignment: .leading) {
                    bar(w: width * 0.26, h: unit * 0.9, shade: 0.85)
                        .padding(.leading, unit)
                }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: unit * 0.75) {
                    ForEach(0..<8, id: \.self) { i in
                        bar(w: width * (i == 2 ? 0.17 : 0.13), h: unit * 0.8,
                            shade: i == 2 ? 0.9 : 0.55)
                    }
                }
                .padding(unit)
                .frame(width: width * 0.34, alignment: .topLeading)
                .background(Color(white: 0.30))

                VStack(alignment: .leading, spacing: unit * 0.95) {
                    ForEach(0..<6, id: \.self) { i in
                        HStack {
                            bar(w: width * 0.2, h: unit * 0.8, shade: 0.75)
                            Spacer(minLength: 0)
                            bar(w: width * 0.12, h: unit * 0.8, shade: 0.55)
                        }
                    }
                }
                .padding(unit)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(white: 0.24))
            Rectangle()
                .fill(Color(white: 0.34))
                .frame(height: unit * 1.8)
                .overlay {
                    HStack {
                        bar(w: width * 0.22, h: unit * 0.7, shade: 0.8)
                        Spacer()
                        bar(w: width * 0.22, h: unit * 0.7, shade: 0.8)
                    }
                    .padding(.horizontal, unit)
                }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
    }

    private func bar(w: CGFloat, h: CGFloat, shade: Double) -> some View {
        RoundedRectangle(cornerRadius: h / 2)
            .fill(Color(white: shade))
            .frame(width: w, height: h)
    }

    // MARK: Transparency

    private var transparencySlider: some View {
        let index = liveStep ?? steps.firstIndex(of: shownStep) ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Transparency")
                    .font(.system(size: 13))
                    .foregroundStyle(enabled ? Theme.textPrimary : Theme.textDim)
                Spacer()
                Text("\(shownStep.shown)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecond)
            }
            Slider(value: Binding(get: { Double(index) },
                                  set: { liveStep = Int($0.rounded()) }),
                   in: 0...Double(steps.count - 1),
                   step: 1,
                   onEditingChanged: { editing in
                       guard !editing, let i = liveStep,
                             steps.indices.contains(i) else { return }
                       pendingStep = steps[i]
                       liveStep = nil
                       onTransparency(steps[i])
                   })
            .tint(Theme.accent)
            .disabled(!enabled)
            .onChange(of: transparency) { _, now in
                if now == pendingStep { pendingStep = nil }
            }
        }
    }
}
