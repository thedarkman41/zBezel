import SwiftUI

/// "Wake Console" — the way back into a machine with no reachable keyboard.
///
/// It sits on the Link tab beside the proxy card because it solves that card's
/// worst failure: the proxy host reboots, nobody signs in, and the agent never
/// starts. From here the KVM is useless — the login screen is the Winlogon
/// secure desktop and Windows refuses synthetic input to it — so the only way
/// in is to authenticate over the network and push the resulting session onto
/// the console.
///
/// Any KVM machine can lose its keyboard the same way, so every one of them is
/// offered, not just the proxy.
struct WakeConsoleCard: View {
    @ObservedObject var controller: MonitorController
    @StateObject private var desktop = RemoteDesktop()

    /// Which machine to wake. Remembered across launches.
    @AppStorage("wakeHost") private var chosenHost: String = ""
    /// The account, kept per host: the proxy may be a plain local account and
    /// a KVM machine a Microsoft one, and the two sign in differently.
    @State private var user = ""
    @State private var domain = ""
    @State private var showDetail = false

    /// The proxy host and every KVM machine, once each, proxy first.
    private var hosts: [String] {
        var out: [String] = []
        for h in [controller.proxyHost] + controller.kvmMachines.map(\.host)
        where !h.isEmpty && !out.contains(h) {
            out.append(h)
        }
        return out
    }

    private var host: String {
        hosts.contains(chosenHost) ? chosenHost : (hosts.first ?? "")
    }

    var body: some View {
        Card(title: "Wake Console", systemImage: "person.badge.key",
             help: """
             After a reboot a machine sits at its login screen, and no KVM can type \
             there: that screen is Windows' secure desktop and synthetic input to it \
             is blocked by design. This signs in over RDP instead, then asks the \
             machine to move that session onto the physical console, where the agent \
             can see the real monitors again. The password comes from Beacon, under \
             the name zBezel-rdp-<host>.
             """) {

            if hosts.count > 1 {
                HStack(spacing: 8) {
                    Text("Machine")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 46, alignment: .leading)
                    Picker("", selection: Binding(get: { host }, set: { pick($0) })) {
                        ForEach(hosts, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
            }

            HStack(spacing: 8) {
                Text("User")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 46, alignment: .leading)
                TextField("windows account", text: userField)
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

            // A Microsoft Account does not sign in under the short local name
            // Windows made for its profile folder: NLA wants the account's real
            // identity, which means domain "MicrosoftAccount" and the full
            // address as the user. Leave both blank for an ordinary local
            // account. (And note a PIN is not the password — NLA needs the
            // password, which is easy to forget if you only ever type a PIN.)
            HStack(spacing: 8) {
                Text("Domain")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 46, alignment: .leading)
                TextField("blank, or MicrosoftAccount", text: domainField)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 150)
                if domain.isEmpty && user.contains("@") {
                    Text("looks like a Microsoft account")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .help("Set the domain to MicrosoftAccount for an address like this.")
                }
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
        .onAppear { load() }
        .onChange(of: desktop.step) { _, now in
            // Waking the console exists to put the agent back in front of the
            // real monitor. Noticing that without being asked is the difference
            // between "done" and "done, and the controls work again".
            if now == .done { controller.reprobeSoon() }
        }
    }

    // MARK: Per-host account

    private static let accountsKey = "wakeAccounts"

    private func pick(_ h: String) {
        chosenHost = h
        load()
    }

    /// Bindings that write through to the per-host store on every edit, so
    /// switching machines and back never loses what was typed.
    private var userField: Binding<String> {
        Binding(get: { user }, set: { user = $0; save() })
    }
    private var domainField: Binding<String> {
        Binding(get: { domain }, set: { domain = $0; save() })
    }

    private func load() {
        let all = UserDefaults.standard.dictionary(forKey: Self.accountsKey)
            as? [String: [String: String]] ?? [:]
        if let saved = all[host.lowercased()] {
            user = saved["user"] ?? ""
            domain = saved["domain"] ?? ""
        } else if host.lowercased() == controller.proxyHost.lowercased() {
            // Before accounts were per host there was one, and it was the proxy's.
            user = UserDefaults.standard.string(forKey: "wakeUser") ?? ""
            domain = UserDefaults.standard.string(forKey: "wakeDomain") ?? ""
        } else {
            user = ""
            domain = ""
        }
    }

    private func save() {
        var all = UserDefaults.standard.dictionary(forKey: Self.accountsKey)
            as? [String: [String: String]] ?? [:]
        all[host.lowercased()] = ["user": user, "domain": domain]
        UserDefaults.standard.set(all, forKey: Self.accountsKey)
    }

    // MARK: State

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
            Text(host.isEmpty ? "Set a proxy host or a KVM machine first."
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

    private func label(_ text: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.system(size: 11.5))
        }
        .foregroundStyle(color)
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
