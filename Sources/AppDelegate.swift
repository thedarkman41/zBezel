import SwiftUI
import AppKit
import Combine

/// Owns the menu bar item.
///
/// Built on NSStatusItem rather than SwiftUI's MenuBarExtra because the two
/// mouse buttons need to do different things, and MenuBarExtra gives no way to
/// tell a left click from a right click.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let controller = MonitorController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var titleResetWork: DispatchWorkItem?
    private var switching = false
    private var observation: AnyCancellable?
    private var refreshTimer: Timer?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FIRST, before any UI or side effects: enrol in Beacon Keep Alive and
        // bring up the liveness listener. launchd then starts zBezel at login and
        // restarts it on a crash, and Beacon revives it after a reboot — the
        // enrolment that was missing when zBezel silently stayed down after the
        // disappearance on 2026-10-20. This call also owns the single-instance
        // guard: if another zBezel already holds the liveness port, start() exits
        // this process cleanly, so running it first avoids flashing a second
        // menu-bar icon. Best-effort; never blocks launch. See BeaconKeepAlive.swift.
        BeaconKeepAlive.shared.start()

        // Now that Beacon can reach zBezel by its liveness port, its right-click
        // Quit (and pkill, and the ship scripts) send SIGTERM — which AppKit does
        // NOT route through applicationWillTerminate. Without this the process
        // would die without handing the pointer back or stopping the clipboard
        // (the decoupled-mouse state applicationWillTerminate guards against) and
        // without POSTing /api/remove. Route SIGTERM through the normal terminate
        // path. (Mirrors Kelvin's Diagnostics.swift.)
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        sigtermSource = term

        // Arm the amber-blink instrumentation: macOS display-reconfiguration and
        // sleep/wake go to linkwatch.log with no DDC cost, so the next mid-work
        // link drop leaves a timestamped trail. See LinkWatch.swift.
        DisplayEventMonitor.start()

        // Tell Beacon who we are, so its panel can offer a Trust button and
        // store-secret.sh can resolve "--app zBezel" to a signing identifier.
        // Idempotent by design; the contract says to call it every startup.
        //
        // Off the main thread: Beacon may not be running, and while a failed
        // connect() returns immediately, this is not worth blocking launch on.
        // A secret fetch does not depend on the outcome — the broker authorizes
        // by signature, not by trust — so nothing here is fatal.
        DispatchQueue.global(qos: .utility).async {
            let state = BeaconSecrets.register()
            NSLog("zBezel beacon: register -> %@", state)
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "zBezel")
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        // Without this the action only ever fires for the left button.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        // Follow the controller rather than refreshing the tooltip at a handful of
        // chosen moments: those moments turned out to include ones where a probe
        // was still in flight, leaving the tooltip stuck on stale data forever.
        observation = controller.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTooltip() }

        // The monitor changes underneath us — its own buttons, the other machine,
        // waking from suspend. Poll while the user is actually looking at the app,
        // so a window left open does not quietly show stale values.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self, NSApp.isActive else { return }
            Task { @MainActor in await self.controller.refreshVisible() }
        }

        Task { @MainActor in
            await controller.bootstrap()
            updateTooltip()
        }

        // Cables get plugged and unplugged. Re-probe when the display layout
        // changes, so the app notices without being asked. Lives here rather than
        // in the window, because the window is usually closed.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Give the display stack a moment to settle before asking.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.controller.refreshDisplays()
                // The doorway moves when the layout does.
                self.controller.syncKVMPortal()
                await self.controller.probe()
                self.updateTooltip()
            }
        }
    }

    /// An accessory app should outlive its window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Give the pointer back before going away. While control is handed to the
    /// PC the mouse is decoupled from the cursor and the cursor is hidden;
    /// quitting in that state would leave the Mac with a mouse that moves
    /// nothing and no obvious cause.
    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdownKVM()
        // Tell Beacon we meant to go: /api/remove blanks our relaunch command and
        // pulls the LaunchAgent, so a deliberate quit is NOT resurrected (it
        // re-arms when we gracefully return). Synchronous with a short cap,
        // because the process is about to exit. See BeaconKeepAlive.swift.
        BeaconKeepAlive.shared.stop()
    }

    // MARK: Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true

        if isSecondary {
            togglePopover(sender)
        } else {
            Task { @MainActor in await cycleInput() }
        }
    }

    private func cycleInput() async {
        guard !switching else { return }
        switching = true
        defer { switching = false }

        statusItem?.button?.title = " …"
        guard let name = await controller.cycleInput() else {
            flash(controller.monitorControlAvailable ? " —" : " ✕")
            updateTooltip()
            return
        }
        flash(" " + shortName(name))
        updateTooltip()
    }

    /// Show the new input beside the icon briefly, then go back to just the icon.
    private func flash(_ text: String) {
        titleResetWork?.cancel()
        statusItem?.button?.title = text
        let work = DispatchWorkItem { [weak self] in self?.statusItem?.button?.title = "" }
        titleResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func shortName(_ name: String) -> String {
        switch name {
        case "DisplayPort":  return "DP"
        case "HDMI":         return "HDMI"
        case "USB-C1 Video": return "USB-C"
        default:             return name
        }
    }

    private func updateTooltip() {
        let input = controller.currentInputName ?? "unknown"
        let cycle = controller.cyclableInputs.map { HPProfile.inputLabel($0) }
        let cycleLine = cycle.count > 1
            ? "Click cycles: " + cycle.joined(separator: " → ")
            : "Only one active input, so clicking does nothing"
        statusItem?.button?.toolTip =
            "zBezel — showing \(input)\n\(cycleLine)\nRight-click for the menu"
    }

    // MARK: Popover

    private func togglePopover(_ sender: NSStatusBarButton) {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let panel = MenuPanel(controller: controller)
        let hosting = NSHostingController(rootView: panel)
        hosting.view.layoutSubtreeIfNeeded()

        let popover = NSPopover()
        popover.contentViewController = hosting
        popover.contentSize = hosting.view.fittingSize
        popover.behavior = .transient
        popover.animates = false
        self.popover = popover

        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)

        // Whatever the panel shows must be true at the moment it is opened.
        Task { @MainActor in
            await controller.refreshVisible()
            updateTooltip()
        }
    }
}
