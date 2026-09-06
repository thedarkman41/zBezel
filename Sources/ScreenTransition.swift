import AppKit

/// A full-screen curtain over the managed panel, used to make an input switch a
/// dissolve rather than a cut.
///
/// It can only ever render the Mac's own output: the moment the panel switches
/// to another machine's input, this window — which lives on the Mac's link to
/// the display — stops being shown at all. So the curtain covers whichever half
/// of a switch has the Mac on screen. Leaving the Mac, it fades the Mac down
/// (`fadeToBlack`); the arriving machine is brought up from black by the
/// backlight instead. Coming home, it is already black over the machine's input
/// (`coverInstantly`) so the Mac is covered the instant the panel switches to it,
/// then cleared (`clear`) to reveal the desktop — the panel's renegotiation
/// flicker never shows either way.
@MainActor
final class ScreenTransition {
    private var window: NSPanel?
    private var blur: NSVisualEffectView?
    private var black: NSView?

    var isActive: Bool { window != nil }

    /// Fade the display down to a blurred black over `duration`, leaving the
    /// curtain up. For the Mac when it is the machine being left.
    func fadeToBlack(on display: CGDirectDisplayID?, duration: TimeInterval) async {
        build(on: display, opaque: false)
        await animate(to: 1, duration: duration)
    }

    /// Put the curtain up already black, no animation. It goes over an input that
    /// is not the Mac's, so it is invisible until the panel comes home — which is
    /// the point: the Mac is covered the instant the switch lands.
    func coverInstantly(on display: CGDirectDisplayID?) {
        build(on: display, opaque: true)
    }

    /// Clear the curtain over `duration`, from blurred black back to sharp and
    /// transparent — the reveal of the Mac — then remove the window.
    func clear(duration: TimeInterval) async {
        guard window != nil else { return }
        await animate(to: 0, duration: duration)
        end()
    }

    /// Remove the curtain at once. Used after a reveal by backlight, where the
    /// curtain is behind the far input and already invisible.
    func end() {
        window?.orderOut(nil)
        window = nil
        blur = nil
        black = nil
    }

    private func animate(to alpha: CGFloat, duration: TimeInterval) async {
        guard let blur, let black else { return }
        await withCheckedContinuation { cont in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                blur.animator().alphaValue = alpha
                black.animator().alphaValue = alpha
            }, completionHandler: { cont.resume() })
        }
    }

    private func build(on display: CGDirectDisplayID?, opaque: Bool) {
        end()   // never stack two curtains
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID) == display
        } ?? NSScreen.main
        guard let frame = screen?.frame else { return }

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // Above the chooser and the menu bar: the curtain covers the whole panel.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Purely visual — the pointer is being warped across while this is up, so
        // it must never intercept an event.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true

        // A dark blur of whatever is behind the window (the desktop).
        let vev = NSVisualEffectView(frame: container.bounds)
        vev.autoresizingMask = [.width, .height]
        vev.blendingMode = .behindWindow
        vev.material = .hudWindow
        vev.state = .active

        // A flat black on top of the blur, so the panel ends genuinely black
        // rather than merely dim.
        let blk = NSView(frame: container.bounds)
        blk.autoresizingMask = [.width, .height]
        blk.wantsLayer = true
        blk.layer?.backgroundColor = NSColor.black.cgColor

        let start: CGFloat = opaque ? 1 : 0
        vev.alphaValue = start
        blk.alphaValue = start

        container.addSubview(vev)
        container.addSubview(blk)
        panel.contentView = container
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        window = panel
        blur = vev
        black = blk
    }
}
