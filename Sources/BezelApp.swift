import SwiftUI
import AppKit

@main
struct BezelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
