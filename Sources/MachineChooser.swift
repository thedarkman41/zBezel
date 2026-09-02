import AppKit
import SwiftUI

/// Drives the drawer's open/shut animation. Held by the chooser and observed by
/// its view, so the window can slide the tiles closed before it is removed —
/// rather than blinking out — when the pointer leaves without picking.
@MainActor
final class ChooserState: ObservableObject {
    @Published var open = false
}

/// Asks which machine the pointer should go to, on the glass rather than in a
/// menu.
///
/// It appears where the question arose — over the panel, at the moment the
/// pointer reaches its edge — because that is where the user is looking. A
/// menu-bar list would make them travel back across the screen to answer a
/// question about travelling forward.
///
/// A non-activating panel, so answering it does not pull focus away from
/// whatever they were doing; the click lands on a tile and the pointer carries
/// straight on to the machine it names. Moving the pointer back off the edge
/// without picking slides the drawer shut and hands the desktop back (the KVM
/// tap watches for that and calls close).
@MainActor
final class MachineChooser {
    private var window: NSWindow?
    private var state: ChooserState?

    var isOpen: Bool { window != nil }

    func show(on display: CGDirectDisplayID?,
              machines: [KVMController.Machine],
              near exit: CGPoint,
              pick: @escaping (Int) -> Void,
              cancel: @escaping () -> Void) {
        hideNow()
        guard !machines.isEmpty else { return }

        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == display
        } ?? NSScreen.main
        guard let frame = screen?.frame else { return }

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        // The exit point arrives in CoreGraphics global coordinates, whose origin
        // is the top-left of the main display — the same space the event tap
        // reports in. Subtracting the panel display's own origin gives a distance
        // down from the top of this view, with no flipping to get wrong.
        let originY = display.map { CGDisplayBounds($0).minY } ?? 0

        let st = ChooserState()      // fresh per showing, so a close animation of
        state = st                   // the previous one cannot drive this one.
        let view = MachineChooserView(
            state: st,
            machines: machines,
            exitFromTop: exit.y - originY,
            pick:   { [weak self] index in self?.close(animated: false); pick(index) },
            cancel: { [weak self] in self?.close(animated: true); cancel() })
        panel.contentView = NSHostingView(rootView: view)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        window = panel

        // Open on the next runloop, so the tiles animate in from behind the edge
        // rather than appearing already open.
        DispatchQueue.main.async { st.open = true }
    }

    /// Close it. Animated slides the drawer shut, then removes the window a beat
    /// later — for a move-away or a click on the dimmed desktop. Not animated
    /// removes it at once, for a pick, where the pointer is already carrying on
    /// to the chosen machine and a lingering overlay would only be in the way.
    func close(animated: Bool) {
        guard let w = window else { return }
        window = nil                 // isOpen is false at once: the pointer is free
        let st = state
        state = nil
        if !animated { w.orderOut(nil); return }
        st?.open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { w.orderOut(nil) }
    }

    func hide() { close(animated: false) }

    private func hideNow() {
        window?.orderOut(nil)
        window = nil
        state = nil
    }
}

private struct MachineChooserView: View {
    @ObservedObject var state: ChooserState
    let machines: [KVMController.Machine]
    /// How far down this view the pointer left, in points.
    let exitFromTop: CGFloat
    let pick: (Int) -> Void
    let cancel: () -> Void

    @State private var hovered: Int?

    private let tileWidth: CGFloat = 190
    private let tileHeight: CGFloat = 132
    private let spacing: CGFloat = 14
    private let margin: CGFloat = 22

    var body: some View {
        ZStack {
            // Dim the desktop behind, so the tiles read as a layer over it rather
            // than as windows belonging to it. Clicking the dimmed area is a way
            // out — the pointer arrived here by accident often enough.
            Color.black.opacity(state.open ? 0.45 : 0)
                .contentShape(Rectangle())
                .onTapGesture { cancel() }
                .animation(.easeOut(duration: 0.22), value: state.open)

            GeometryReader { geo in
                let stackHeight = CGFloat(machines.count) * tileHeight
                    + CGFloat(max(machines.count - 1, 0)) * spacing
                // Centred on where the pointer left, then pushed back inside the
                // screen if that would hang it off the top or bottom. The point
                // is to appear under the hand, not to be geometrically pure.
                let wanted = exitFromTop
                let centreY = min(max(wanted, stackHeight / 2 + margin),
                                  geo.size.height - stackHeight / 2 - margin)
                VStack(spacing: spacing) {
                    ForEach(Array(machines.enumerated()), id: \.element.id) { index, machine in
                        tile(index: index, machine: machine)
                            // Out from behind the right edge, each a beat after
                            // the one above it. The stagger is what makes it read
                            // as a drawer being pulled rather than a panel simply
                            // appearing — and, run backwards, being pushed shut.
                            .offset(x: state.open ? 0 : tileWidth + margin + 12)
                            .opacity(state.open ? 1 : 0)
                            .animation(.spring(response: 0.36, dampingFraction: 0.78)
                                        .delay(Double(index) * 0.055),
                                       value: state.open)
                    }
                }
                .frame(width: tileWidth, height: stackHeight)
                .position(x: geo.size.width - tileWidth / 2 - margin, y: centreY)
            }
        }
        .ignoresSafeArea()
    }

    private func tile(index: Int, machine: KVMController.Machine) -> some View {
        let lit = hovered == index
        return VStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(lit ? Color.white : Color.white.opacity(0.72))
            Text(machine.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(lit ? Color.white : Color.white.opacity(0.72))
            if machine.width > 1 {
                Text("\(Int(machine.width)) × \(Int(machine.height))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: tileWidth, height: tileHeight)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(lit ? 0.16 : 0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.white.opacity(lit ? 0.6 : 0.18),
                                      lineWidth: lit ? 2 : 1))
        )
        .scaleEffect(lit ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: lit)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .onTapGesture { pick(index) }
    }
}
