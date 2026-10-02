import SwiftUI
import AppKit

/// One entry in a `HeldMenu`.
struct HeldMenuItem {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void
}

/// A pull-down that opens while the button is pressed and closes when it is
/// released — the behavior SwiftUI's `Menu` does not give (that one latches open
/// on a click and stays until you click an item or click away).
///
/// An `NSMenu` popped up from within `mouseDown` keeps tracking the held mouse,
/// so dragging onto an item and releasing chooses it, and releasing anywhere
/// else just dismisses — the way a toolbar pull-down has always worked. The
/// SwiftUI `label` is kept as the visible control; a transparent AppKit view
/// overlaid on it catches the press.
struct HeldMenu<Label: View>: View {
    let items: [HeldMenuItem]
    @ViewBuilder let label: () -> Label

    var body: some View {
        label().overlay(Popper(items: items))
    }
}

private struct Popper: NSViewRepresentable {
    let items: [HeldMenuItem]

    func makeNSView(context: Context) -> NSView { PopperView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PopperView)?.items = items
    }

    final class PopperView: NSView {
        var items: [HeldMenuItem] = []

        override func mouseDown(with event: NSEvent) {
            guard !items.isEmpty else { return }
            let menu = NSMenu()
            for (index, item) in items.enumerated() {
                let entry = NSMenuItem(
                    title: item.title,
                    action: item.isEnabled ? #selector(choose(_:)) : nil,
                    keyEquivalent: "")
                entry.target = self
                entry.tag = index
                entry.isEnabled = item.isEnabled
                menu.addItem(entry)
            }
            // Drop it just below the label. Convert the label's bottom-left corner
            // to screen coordinates and pop up there (in: nil treats the point as
            // screen), so it lands under the label regardless of how the hosting
            // view is flipped — popping up "in: self" put it in the wrong place.
            let corner = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY)
            if let window = self.window {
                let onScreen = window.convertPoint(toScreen: convert(corner, to: nil))
                menu.popUp(positioning: nil, at: onScreen, in: nil)
            } else {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
            }
        }

        @objc private func choose(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            items[sender.tag].action()
        }
    }
}
