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
        settling = true
        // Captured BEFORE going full screen: afterwards, the frontmost app is us.
        previousApp = NSWorkspace.shared.frontmostApplication

        window.makeKeyAndOrderFront(nil)
        window.toggleFullScreen(nil)          // this is what creates the Space

        // Creating a full-screen Space always animates INTO it. There is no
        // public way to mint one in the background — the only alternative is
        // private SkyLight calls, which is not a trade worth making for an
        // animation. So go back to where the user was as soon as the transition
        // finishes: they see one brief blip when they switch this on, and after
        // that the Space simply sits at the far right until they choose it.
        //
        // macOS appends full-screen Spaces after the desktops, so it lands on
        // the right on its own.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.returnToPreviousSpace() }
        }

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
        hasBouncedBack = false
        NSApp.setActivationPolicy(.accessory)
        KVMLog.write("space: closed")
    }

    /// Step back out of the Space that creating it forced us into.
    ///
    /// By activating the app that was in front beforehand, NOT by synthesising
    /// Control-Left. The keyboard route was tried first and does not work:
    /// macOS routes the Space-switching hotkeys through the WindowServer, which
    /// ignores posted CGEvents. The event was accepted and nothing moved — the
    /// log recorded the step-back and then five seconds of the user doing it by
    /// hand.
    ///
    /// Activating an application, on the other hand, takes the user to whatever
    /// Space that application is on. That is ordinary public API and it is what
    /// clicking the app in the Dock already does.
    ///
    /// Done once, on creation, never again — every later entry is the user
    /// asking for it.
    private func returnToPreviousSpace() {
        guard !hasBouncedBack else { return }
        hasBouncedBack = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let mine = Bundle.main.bundleIdentifier
            if let previous = self.previousApp, previous.bundleIdentifier != mine,
               !previous.isTerminated {
                previous.activate()
                KVMLog.write("space: created, returned to "
                           + (previous.localizedName ?? "the previous app"))
            } else {
                // Nothing sensible to go back to — hiding at least leaves the
                // full-screen Space rather than sitting in it.
                NSApp.hide(nil)
                KVMLog.write("space: created, hid the app to step out")
            }

            // Only start acting on Space changes once the dust has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                Task { @MainActor in
                    self.settling = false
                    KVMLog.write("space: now watching for real switches")
                }
            }
        }
    }

    private var hasBouncedBack = false
    private var previousApp: NSRunningApplication?

    /// True from creation until the bounce back has finished.
    ///
    /// Creating the Space enters it and the bounce leaves it again, which would
    /// otherwise read as a genuine enter followed by a genuine leave: control
    /// handed over and taken back, and the monitor switched to the PC and back,
    /// all for an animation nobody asked for. The transitions still update the
    /// remembered state, they just do not act on it.
    private var settling = true

    // MARK: Entering and leaving

    private func activeSpaceChanged() {
        guard let window else { return }
        let now = window.isOnActiveSpace
        guard now != wasOnActiveSpace else { return }
        wasOnActiveSpace = now
        if settling {
            KVMLog.write("space: \(now ? "entered" : "left") while settling — ignored")
            return
        }
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
