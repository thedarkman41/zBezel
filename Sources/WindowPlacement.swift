import SwiftUI
import AppKit

/// Keeps the window on the primary display.
///
/// macOS restores a window to whichever screen it was last closed on, which on a
/// multi-display desk means the app can reopen on a screen the user is not
/// looking at. This pulls it back to the primary screen — the one with the menu
/// bar — but only when it has actually drifted off it, so moving the window
/// around *within* the primary display is still respected.
struct WindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = NSView()
        // The view has no window until it is in the hierarchy.
        DispatchQueue.main.async {
            guard let window = probe.window else { return }
            window.isRestorable = false      // stop macOS putting it back on the other screen
            WindowPlacement.moveToPrimaryIfElsewhere(window)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// `NSScreen.screens.first` is the primary screen. (`NSScreen.main` is the one
    /// holding the key window, which is a different thing and not what we want.)
    static var primaryScreen: NSScreen? { NSScreen.screens.first }

    static func isOnPrimary(_ window: NSWindow) -> Bool {
        guard let primary = primaryScreen else { return true }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return primary.frame.contains(center)
    }

    static func moveToPrimaryIfElsewhere(_ window: NSWindow) {
        guard !isOnPrimary(window) else { return }
        centreOnPrimary(window)
    }

    static func centreOnPrimary(_ window: NSWindow) {
        guard let primary = primaryScreen else { return }
        let visible = primary.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = visible.midY - frame.height / 2
        window.setFrame(frame, display: true)
    }

    /// For the menu command.
    static func centreFrontmostOnPrimary() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        else { return }
        centreOnPrimary(window)
    }
}
