import SwiftUI

/// "Wake Console" — the way back into a machine with no reachable keyboard.
///
/// It sits on the Link tab beside the proxy card because it solves that card's
/// worst failure: the proxy host reboots, nobody signs in, and the agent never
/// starts. From here the KVM is useless — the login screen is the Winlogon
/// secure desktop and Windows refuses synthetic input to it — so the only way
/// in is to authenticate over the network and push the resulting session onto
/// the console.
struct WakeConsoleCard: View {
    @ObservedObject var controller: MonitorController
    @StateObject private var desktop = RemoteDesktop()

    @AppStorage("wakeUser")   private var user: String = ""
    @AppStorage("wakeDomain") private var domain: String = ""
    @State private var showDetail = false

    private var host: String { controller.proxyHost }

    var body: some View {
        Card(title: "Wake Console", systemImage: "person.badge.key",
             help: """
             After a reboot the proxy host sits at its login screen, and no KVM can \
             type there: that screen is Windows' secure desktop and synthetic input \
             to it is blocked by design. This signs in over RDP instead, then asks \
             the machine to move that session onto the physical console, where the \
             agent can see the real monitors again. The password comes from Beacon.
             """) {

            HStack(spacing: 8) {
                Text("User")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 46, alignment: .leading)
                TextField("windows account", text: $user)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 150)
                Button(action: { Task { await wake() } }) {
                    Text(isBusy ? "Waking…" : "Wake \(host.isEmpty ? "Console" : host)")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(canWake ? Theme.accent : Theme.textDim)
                .disabled(!canWake)
            }

            Divider().overlay(Theme.rule).padding(.vertical, 2)

            statusLine

            // The log is where a failure explains itself: which of the two
            // steps went wrong, and whether the credential or the move was the
            // problem. Hidden until there is something to say.
            if !desktop.log.isEmpty {
                DisclosureGroup(isExpanded: $showDetail) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(desktop.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Details")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecond)
                }
            }

            if let pinned = desktop.pinnedFingerprints[host.lowercased()], !pinned.isEmpty {
                Text("Host key pinned · \(String(pinned.prefix(17)))…")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .help("Recorded on first connection. A change means the machine was "
                        + "rebuilt — or that this is not the same machine.")
            }
        }
    }

    private var isBusy: Bool {
        switch desktop.step {
        case .fetchingCredential, .connecting, .reclaiming: return true
        default: return false
        }
    }

    private var canWake: Bool { !host.isEmpty && !user.isEmpty && !isBusy }

    @ViewBuilder
    private var statusLine: some View {
        switch desktop.step {
        case .idle:
            Text(host.isEmpty ? "Set a proxy host above first."
                              : "Signs in to \(host) and hands the session to its console.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

        case .fetchingCredential:
            label("Waiting for Beacon…", "lock", Theme.textSecond)
        case .connecting:
            label("Signing in over RDP…", "network", Theme.textSecond)
        case .reclaiming:
            label("Moving the session to the console…", "display", Theme.textSecond)
        case .done:
            label("Done — the console is showing the desktop.", "checkmark.circle", .green)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 3) {
                label("Did not work", "exclamationmark.triangle", .orange)
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(_ text: String, _ symbol: String, _ colour: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.system(size: 11.5))
        }
        .foregroundStyle(colour)
    }

    private func wake() async {
        await desktop.wakeConsole(host: host,
                                  user: user,
                                  domain: domain.isEmpty ? nil : domain,
                                  sshTarget: host)
        // A failure is worth reading; a success explains itself in one line.
        if case .failed = desktop.step { showDetail = true }
    }
}
