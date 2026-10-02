import AppKit
import CoreGraphics
import ScreenCaptureKit

/// A still of one of this Mac's displays.
///
/// Used to fill the left half of the side-by-side diagram, so it shows the two
/// machines rather than two colored rectangles.
///
/// ScreenCaptureKit rather than CGDisplayCreateImage: the older call is
/// deprecated on macOS 14, and a deprecation is a build warning, and the ship
/// script refuses to commit anything that warns. That gate exists precisely so
/// this sort of thing gets dealt with rather than accumulating.
enum ScreenSnapshot {

    /// Whether Screen Recording has been granted, without prompting.
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask for it. The system shows its own dialogue and the answer only takes
    /// effect for this process after a relaunch, which is macOS's rule, not ours.
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// A downscaled still of one display, or nil if it cannot be captured.
    ///
    /// Small on purpose: this is drawn a couple of hundred points wide inside a
    /// diagram, so a full-resolution capture would be several megabytes of
    /// nothing.
    static func capture(display id: CGDirectDisplayID, width: Int = 640) async -> NSImage? {
        guard isPermitted else { return nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id })
                    ?? content.displays.first else { return nil }

            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = max(1, Int(Double(width)
                                              * Double(display.height) / Double(display.width)))
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            return NSImage(cgImage: image,
                           size: NSSize(width: image.width, height: image.height))
        } catch {
            KVMLog.write("snapshot: capture failed — \(error.localizedDescription)")
            return nil
        }
    }
}
