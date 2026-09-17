import SwiftUI
import AppKit

@main
struct BezelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Never let a broken pipe take the app down. Every socket and every SSH
        // transport this app writes to can lose its far end — an unreachable
        // machine, Tailscale stopped, a host whose name no longer resolves — and
        // a write into that dead pipe raises SIGPIPE, whose default action kills
        // the process. Ignore it process-wide HERE, before anything opens a pipe.
        // The KVM transport had its own lazy guard, but the DDC relay writes on
        // launch before that guard installs, so a stopped Tailscale was crashing
        // the app at startup (SIGPIPE, exit 141). Ignored, those writes fail with
        // EPIPE instead — which the transports already handle.
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        Window("zBezel", id: "main") {
            RootView(controller: appDelegate.controller)
                .preferredColorScheme(.dark)
        }
        // .contentSize, not .contentMinSize: the window takes the size its
        // content asks for and cannot be dragged away from it. With
        // .contentMinSize it could be stretched, which left large empty areas
        // below tabs that have less in them than the tallest one.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
