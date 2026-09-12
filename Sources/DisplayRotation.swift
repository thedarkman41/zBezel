import CoreGraphics
import Foundation

/// The local half of "Pivot": turning the macOS framebuffer that drives the
/// panel.
///
/// The picture on the panel is produced by whichever machine holds the monitor's
/// live input. When that machine is this Mac — the panel is in the Mac's display
/// list — rotating here turns what is on screen. The transform itself lives in
/// the C shim (`bezel_display_rotate`, a GPU-side IOFramebuffer probe that needs
/// no DDC and so works through the dock), and this wrapper brackets it with a
/// fade to black so the reconfigure is never seen as a tear or a flash — the same
/// fade HP's Pivot uses.
enum DisplayRotation {
    /// The four orientations, in the order HP's Pivot control lists them.
    static let steps = [0, 90, 180, 270]

    /// Current rotation of the display, snapped to a multiple of 90. Public CG
    /// API — no probing, no side effects; safe to poll.
    static func current(_ id: CGDirectDisplayID) -> Int {
        let deg = Int(CGDisplayRotation(id).rounded())
        return ((deg % 360) + 360) % 360
    }

    /// Rotate `id` to `degrees`, fading the screens to black across the switch.
    /// The IOKit probe runs off the main thread; the fade is CoreGraphics and
    /// holds the global fade reservation only for its brief life. Returns whether
    /// the framebuffer accepted the transform.
    @discardableResult
    static func rotate(_ id: CGDirectDisplayID, to degrees: Int,
                       fade: Bool = true) async -> Bool {
        var token: CGDisplayFadeReservationToken = 0
        let haveFade = fade &&
            CGAcquireDisplayFadeReservation(3, &token) == .success

        // Synchronous fade-out: return only once the screen is fully black, so
        // the mode change underneath is never shown.
        if haveFade {
            CGDisplayFade(token, 0.32, 0.0, 1.0, 0, 0, 0, 1)
        }

        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: bezel_display_rotate(UInt32(id), Int32(degrees)) == BEZEL_OK)
            }
        }

        if haveFade {
            // Let the framebuffer settle into the new geometry before revealing.
            try? await Task.sleep(nanoseconds: 300_000_000)
            CGDisplayFade(token, 0.5, 1.0, 0.0, 0, 0, 0, 0)
            CGReleaseDisplayFadeReservation(token)
        }
        return ok
    }
}
