import AppKit

//  RDPView.swift — the interactive surface over an RDPSession.
//
//  Lifted out of RDPControlWindow.swift unchanged, because it is useful on its
//  own: it needs nothing from zBezel but RDPSession, while the window around it
//  is all zBezel — Beacon credentials, the per-host account store, the
//  fingerprint pin. Sibling apps compile this file and RDPSession.swift
//  straight out of this directory rather than keeping a copy that drifts.
//
//  So: nothing here may reach for zBezel state. Anything that needs to belongs
//  in RDPControlWindow.swift instead.

/// Draws the session's framebuffer and turns Mac mouse and keyboard into RDP
/// input. Fills its bounds (the window keeps the session's aspect ratio, so
/// there is no letterbox to map around).
final class RDPView: NSView {
    private let session: RDPSession
    private let remoteSize: CGSize
    private var ready = false
    private var lastFlags = NSEvent.ModifierFlags()

    init(frame: NSRect, session: RDPSession, remoteSize: CGSize) {
        self.session = session
        self.remoteSize = remoteSize
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 1).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func sessionReady() { ready = true; needsDisplay = true }

    /// A remote-pixel rect changed; invalidate the matching view rect.
    func markRemoteDirty(_ remoteRect: CGRect) {
        guard ready, remoteSize.width > 0, remoteSize.height > 0 else { return }
        let sx = bounds.width / remoteSize.width
        let sy = bounds.height / remoteSize.height
        // Remote is top-left origin; the view is bottom-left. Flip Y.
        let vy = bounds.height - (remoteRect.maxY * sy)
        let r = CGRect(x: remoteRect.minX * sx, y: vy,
                       width: remoteRect.width * sx, height: remoteRect.height * sy)
        setNeedsDisplay(r.insetBy(dx: -1, dy: -1))
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard ready, let image = session.makeImage(),
              let ctx = NSGraphicsContext.current?.cgContext else {
            NSColor(white: 0.06, alpha: 1).setFill(); dirtyRect.fill(); return
        }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    // MARK: Coordinate mapping

    private func remotePoint(_ event: NSEvent) -> (Int, Int) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        let rx = Int((p.x / bounds.width) * remoteSize.width)
        // Flip Y: view bottom-left, remote top-left.
        let ry = Int(((bounds.height - p.y) / bounds.height) * remoteSize.height)
        return (rx, ry)
    }

    // MARK: Mouse

    private static let MOVE: UInt16 = 0x0800, DOWN: UInt16 = 0x8000
    private static let B1: UInt16 = 0x1000, B2: UInt16 = 0x2000, B3: UInt16 = 0x4000

    override func mouseMoved(with e: NSEvent)     { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }
    override func mouseDragged(with e: NSEvent)   { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }
    override func rightMouseDragged(with e: NSEvent) { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }
    override func otherMouseDragged(with e: NSEvent) { let (x, y) = remotePoint(e); session.mouse(x: x, y: y, flags: Self.MOVE) }

    override func mouseDown(with e: NSEvent)  { window?.makeFirstResponder(self); button(e, Self.B1, down: true) }
    override func mouseUp(with e: NSEvent)    { button(e, Self.B1, down: false) }
    override func rightMouseDown(with e: NSEvent) { button(e, Self.B2, down: true) }
    override func rightMouseUp(with e: NSEvent)   { button(e, Self.B2, down: false) }
    override func otherMouseDown(with e: NSEvent) { button(e, Self.B3, down: true) }
    override func otherMouseUp(with e: NSEvent)   { button(e, Self.B3, down: false) }

    private func button(_ e: NSEvent, _ b: UInt16, down: Bool) {
        let (x, y) = remotePoint(e)
        session.mouse(x: x, y: y, flags: down ? (Self.DOWN | b) : b)
    }

    override func scrollWheel(with e: NSEvent) {
        let notches = Int(e.scrollingDeltaY.rounded())
        if notches != 0 { session.wheel(notches: notches > 0 ? 1 : -1) }
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent)  { sendKey(e, down: true) }
    override func keyUp(with e: NSEvent)    { sendKey(e, down: false) }

    private func sendKey(_ e: NSEvent, down: Bool) {
        if let (code, ext) = RDPKeymap.map[e.keyCode] {
            session.key(scancode: code, extended: ext, down: down)
        } else if let chars = e.charactersIgnoringModifiers, let u = chars.unicodeScalars.first, u.value <= 0xFFFF {
            // Anything the table does not carry goes as its character.
            session.unicode(UInt16(u.value), down: down)
        }
    }

    override func flagsChanged(with e: NSEvent) {
        let now = e.modifierFlags
        toggle(.shift,   now, 0x2A, extended: false)
        toggle(.control, now, 0x1D, extended: false)
        toggle(.option,  now, 0x38, extended: false)
        toggle(.command, now, 0x5B, extended: true)   // Cmd → Windows key
        lastFlags = now
    }

    private func toggle(_ mask: NSEvent.ModifierFlags, _ now: NSEvent.ModifierFlags,
                        _ scancode: UInt8, extended: Bool) {
        let was = lastFlags.contains(mask), is_ = now.contains(mask)
        if was != is_ { session.key(scancode: scancode, extended: extended, down: is_) }
    }
}

/// Mac virtual key codes to RDP (scan-code set 1). Letters and digits, the
/// punctuation, the nav cluster, and the function keys — enough to type a
/// password and drive a dialog. The extended flag marks the E0-prefixed keys.
enum RDPKeymap {
    static let map: [UInt16: (UInt8, Bool)] = [
        0x00: (0x1E, false), 0x0B: (0x30, false), 0x08: (0x2E, false), 0x02: (0x20, false), // A B C D
        0x0E: (0x12, false), 0x03: (0x21, false), 0x05: (0x22, false), 0x04: (0x23, false), // E F G H
        0x22: (0x17, false), 0x26: (0x24, false), 0x28: (0x25, false), 0x25: (0x26, false), // I J K L
        0x2E: (0x32, false), 0x2D: (0x31, false), 0x1F: (0x18, false), 0x23: (0x19, false), // M N O P
        0x0C: (0x10, false), 0x0F: (0x13, false), 0x01: (0x1F, false), 0x11: (0x14, false), // Q R S T
        0x20: (0x16, false), 0x09: (0x2F, false), 0x0D: (0x11, false), 0x07: (0x2D, false), // U V W X
        0x10: (0x15, false), 0x06: (0x2C, false),                                           // Y Z
        0x12: (0x02, false), 0x13: (0x03, false), 0x14: (0x04, false), 0x15: (0x05, false), // 1 2 3 4
        0x17: (0x06, false), 0x16: (0x07, false), 0x1A: (0x08, false), 0x1C: (0x09, false), // 5 6 7 8
        0x19: (0x0A, false), 0x1D: (0x0B, false),                                           // 9 0
        0x24: (0x1C, false), 0x30: (0x0F, false), 0x31: (0x39, false), 0x33: (0x0E, false), // Return Tab Space Backspace
        0x35: (0x01, false),                                                                // Escape
        0x1B: (0x0C, false), 0x18: (0x0D, false), 0x21: (0x1A, false), 0x1E: (0x1B, false), // - = [ ]
        0x2A: (0x2B, false), 0x29: (0x27, false), 0x27: (0x28, false), 0x32: (0x29, false), // \ ; ' `
        0x2B: (0x33, false), 0x2F: (0x34, false), 0x2C: (0x35, false),                      // , . /
        0x7B: (0x4B, true),  0x7C: (0x4D, true),  0x7D: (0x50, true),  0x7E: (0x48, true),  // arrows L R Down Up
        0x73: (0x47, true),  0x77: (0x4F, true),  0x74: (0x49, true),  0x79: (0x51, true),  // Home End PgUp PgDn
        0x75: (0x53, true),  0x72: (0x52, true),                                            // FwdDelete Insert
        0x7A: (0x3B, false), 0x78: (0x3C, false), 0x63: (0x3D, false), 0x76: (0x3E, false), // F1-F4
        0x60: (0x3F, false), 0x61: (0x40, false), 0x62: (0x41, false), 0x64: (0x42, false), // F5-F8
        0x65: (0x43, false), 0x6D: (0x44, false), 0x67: (0x57, false), 0x6F: (0x58, false), // F9-F12
    ]
}
