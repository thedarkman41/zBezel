import AppKit

/// Swift owner of one `zbezel_rdp_session`.
///
/// The C session decodes the remote desktop on its own thread and hands us
/// changed rectangles; we keep a full BGRA backing store, patch the changed
/// rows into it, and tell the view to redraw. Input goes the other way, out
/// through the C session's queue. This is the pixel path — the one that can
/// see and answer a UAC prompt, which the screen-scrape stream cannot.
///
/// `@unchecked Sendable`: every field touched from more than one thread is
/// guarded by `lock`, and the callbacks marshal to main themselves — so this
/// is safe to hand to the background connect without the compiler proving it.
final class RDPSession: @unchecked Sendable {

    /// Called on the MAIN thread when a region changed (the rect, in remote
    /// pixels, top-left origin) and when the session's state changes.
    var onFrame: ((CGRect) -> Void)?
    var onState: ((State, String?) -> Void)?

    enum State { case connecting, connected, disconnected, error, resized }

    private(set) var width = 0
    private(set) var height = 0

    private var session: OpaquePointer?
    private var backing: UnsafeMutablePointer<UInt8>?
    private var backingBytes = 0
    private let lock = NSLock()

    // MARK: Open / close

    /// Blocks until connected or failed, so call it off the main thread. On
    /// success `onState(.connected, nil)` has already fired and frames follow.
    /// Returns the FreeRDP error name on failure, nil on success.
    func open(host: String, port: UInt16, user: String, domain: String?, password: String,
              pinnedFingerprint: String?, width: Int, height: Int,
              fingerprintOut: UnsafeMutablePointer<CChar>, fingerprintOutLen: Int32) -> String? {
        var errorName = [CChar](repeating: 0, count: 128)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        let handle: OpaquePointer? = host.withCString { h in
            user.withCString { u in
                password.withCString { p in
                    withOptionalCString(domain) { d in
                        withOptionalCString(pinnedFingerprint) { f in
                            zbezel_rdp_open(h, port, u, d, p, f,
                                            Int32(width), Int32(height),
                                            rdpFrameThunk, rdpStateThunk, ctx,
                                            &errorName, Int32(errorName.count),
                                            fingerprintOut, fingerprintOutLen)
                        }
                    }
                }
            }
        }

        guard let handle else { return String(cString: errorName) }
        session = handle
        let w = Int(zbezel_rdp_width(handle))
        let h = Int(zbezel_rdp_height(handle))
        allocateBacking(w, h)
        return nil
    }

    func close() {
        let s = session
        session = nil
        if let s { zbezel_rdp_close(s) }   // joins the C thread: no callback after this
        lock.lock()
        backing?.deallocate()
        backing = nil
        lock.unlock()
    }

    deinit { close() }

    private func allocateBacking(_ w: Int, _ h: Int) {
        lock.lock()
        backing?.deallocate()
        width = w; height = h
        backingBytes = max(1, w * h * 4)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: backingBytes)
        buf.initialize(repeating: 0, count: backingBytes)
        backing = buf
        lock.unlock()
    }

    // MARK: Frames

    /// From the C session thread. Copy the changed rows, then ask the view to
    /// redraw on main.
    fileprivate func ingest(_ bgra: UnsafePointer<UInt8>, _ srcW: Int, _ srcH: Int, _ srcStride: Int,
                            _ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        lock.lock()
        if width != srcW || height != srcH { lock.unlock(); allocateBacking(srcW, srcH); lock.lock() }
        if let dst = backing {
            let dstStride = width * 4
            let rowBytes = w * 4
            for row in 0..<h {
                let sy = y + row
                if sy < 0 || sy >= srcH { continue }
                let srcRow = bgra.advanced(by: sy * srcStride + x * 4)
                let dstRow = dst.advanced(by: sy * dstStride + x * 4)
                dstRow.update(from: srcRow, count: min(rowBytes, dstStride - x * 4))
            }
        }
        lock.unlock()

        let rect = CGRect(x: x, y: y, width: w, height: h)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(rect) }
    }

    fileprivate func state(_ code: Int32, _ detail: String?) {
        let s: State
        switch code {
        case 0: s = .connecting
        case 1: s = .connected
        case 2: s = .disconnected
        case 4: s = .resized
        default: s = .error
        }
        DispatchQueue.main.async { [weak self] in self?.onState?(s, detail) }
    }

    /// A CGImage over the current backing store. Held under the lock only long
    /// enough to copy, so a mid-frame draw cannot tear against a resize.
    func makeImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let backing, width > 0, height > 0 else { return nil }
        let data = Data(bytes: backing, count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Input

    func mouse(x: Int, y: Int, flags: UInt16) {
        guard let session else { return }
        zbezel_rdp_mouse(session, Int32(clampX(x)), Int32(clampY(y)), flags)
    }
    func wheel(notches: Int) { if let session { zbezel_rdp_wheel(session, Int32(notches)) } }
    func key(scancode: UInt8, extended: Bool, down: Bool) {
        if let session { zbezel_rdp_key(session, scancode, extended ? 1 : 0, down ? 1 : 0) }
    }
    func unicode(_ code: UInt16, down: Bool) {
        if let session { zbezel_rdp_unicode(session, code, down ? 1 : 0) }
    }
    func refresh() { if let session { zbezel_rdp_refresh(session) } }

    private func clampX(_ x: Int) -> Int { min(max(x, 0), max(0, width - 1)) }
    private func clampY(_ y: Int) -> Int { min(max(y, 0), max(0, height - 1)) }
}

// The C session's callbacks reach Swift through these @convention(c) thunks,
// which carry the RDPSession as an opaque context pointer. The session outlives
// them because zbezel_rdp_close joins the C thread before we release it.
private func rdpFrameThunk(_ ctx: UnsafeMutableRawPointer?, _ bgra: UnsafePointer<UInt8>?,
                           _ width: Int32, _ height: Int32, _ stride: Int32,
                           _ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32) {
    guard let ctx, let bgra else { return }
    let session = Unmanaged<RDPSession>.fromOpaque(ctx).takeUnretainedValue()
    session.ingest(bgra, Int(width), Int(height), Int(stride), Int(x), Int(y), Int(w), Int(h))
}

private func rdpStateThunk(_ ctx: UnsafeMutableRawPointer?, _ state: Int32, _ detail: UnsafePointer<CChar>?) {
    guard let ctx else { return }
    let session = Unmanaged<RDPSession>.fromOpaque(ctx).takeUnretainedValue()
    session.state(state, detail.map { String(cString: $0) })
}

private func withOptionalCString<R>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
