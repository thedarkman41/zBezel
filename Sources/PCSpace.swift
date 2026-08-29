import AppKit
import Foundation

/// A macOS Space that stands for the PC.
///
/// A full-screen window on the panel. macOS gives any full-screen window a Space
/// of its own, so it appears in Mission Control beside the real desktops without
/// anything private being called — there is no API to add an entry to that strip,
/// and this does not try to. It IS one.
///
/// Switching to that Space switches the monitor to the PC's input and hands over
/// the keyboard and pointer; switching away gives both back. The two belong
/// together: showing the PC's screen while an invisible Mac pointer moved around
/// on top of it would be worse than either alone.
///
/// What the window draws is a screenshot of the PC, refreshed while the Space is
/// in the background. That is only ever seen as the Mission Control thumbnail —
/// the moment the Space is actually entered, the monitor has switched and the
/// real machine is on screen — so it is fetched small, lossy, and rarely.
@MainActor
final class PCSpace {

    /// The Space became frontmost: hand the panel and the input devices over.
    var onEnter: (() -> Void)?
    /// The Space went away: take them back.
    var onLeave: (() -> Void)?
    /// Ask the far side for a fresh picture of its desktop.
    var onWantScreenshot: (() -> Void)?

    private var window: NSWindow?
    private var imageView: NSImageView?
    private var label: NSTextField?
    private var refresh: Timer?
    private var wasOnActiveSpace = false
    private var observer: Any?

    /// How often the thumbnail is refreshed while nobody is looking at it.
    private static let refreshInterval: TimeInterval = 60

    var isOpen: Bool { window != nil }

    // MARK: Opening

    func open(on display: CGDirectDisplayID, title: String) {
        guard window == nil else { return }
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display
        }) else {
            KVMLog.write("space: no NSScreen matches display \(display)")
            return
        }

        // An LSUIElement app cannot take a window full screen — and full screen
        // is the whole mechanism, since that is what makes macOS mint a Space.
        // Becoming a regular app for as long as the window exists is the price;
        // the policy goes back when it closes.
        NSApp.setActivationPolicy(.regular)

        let window = NSWindow(contentRect: screen.frame,
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: screen)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]

        let image = NSImageView(frame: .zero)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.autoresizingMask = [.width, .height]
        image.frame = window.contentLayoutRect

        let caption = NSTextField(labelWithString: "\(title) — waiting for a picture of its desktop")
        caption.textColor = NSColor.secondaryLabelColor
        caption.font = .systemFont(ofSize: 15)
        caption.alignment = .center
        caption.frame = NSRect(x: 0, y: screen.frame.height / 2 - 12,
                               width: screen.frame.width, height: 24)
        caption.autoresizingMask = [.width, .minYMargin, .maxYMargin]

        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        content.addSubview(image)
        content.addSubview(caption)
        window.contentView = content

        self.window = window
        self.imageView = image
        self.label = caption

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)          // this is what creates the Space

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.activeSpaceChanged() }
        }

        refresh = Timer.scheduledTimer(withTimeInterval: PCSpace.refreshInterval,
                                       repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfUnseen() }
        }

        KVMLog.write("space: opened on display \(display)")
        onWantScreenshot?()                    // one straight away, so it is not blank
    }

    func close() {
        refresh?.invalidate(); refresh = nil
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        if let window {
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            window.close()
        }
        window = nil; imageView = nil; label = nil
        wasOnActiveSpace = false
        NSApp.setActivationPolicy(.accessory)
        KVMLog.write("space: closed")
    }

    // MARK: Entering and leaving

    private func activeSpaceChanged() {
        guard let window else { return }
        let now = window.isOnActiveSpace
        guard now != wasOnActiveSpace else { return }
        wasOnActiveSpace = now
        KVMLog.write("space: \(now ? "entered" : "left")")
        if now { onEnter?() } else { onLeave?() }
    }

    /// Refresh only while the Space is in the background.
    ///
    /// While it is in front the monitor has switched and the user is looking at
    /// the real machine, so a picture of it would be both invisible and a waste
    /// of the channel.
    private func refreshIfUnseen() {
        guard let window, !window.isOnActiveSpace else { return }
        onWantScreenshot?()
    }

    // MARK: Content

    func show(_ image: NSImage) {
        imageView?.image = image
        label?.isHidden = true
    }
}
