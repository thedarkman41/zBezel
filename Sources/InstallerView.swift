import SwiftUI

/// Sets up a Windows machine as a control proxy, from nothing.
struct InstallerView: View {
    @ObservedObject var controller: MonitorController
    @StateObject private var installer = AgentInstaller()
    @Environment(\.dismiss) private var dismiss

    @State private var target = AgentInstaller.Target()
    @State private var usePassword = false
    @State private var password = ""
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !installer.running && !installer.finished {
                        form
                    } else {
                        progress
                    }
                }
                .padding(20)
            }

            Divider().overlay(Theme.rule)
            footer
        }
        .frame(width: 560, height: 560)
        .background(Theme.canvas)
        .onAppear {
            if target.host.isEmpty { target.host = controller.proxyHost }
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up a Control Proxy")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Installs the agent on a Windows machine that can reach the monitor directly.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecond)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("""
                 The machine needs Windows with the OpenSSH Server feature enabled, and somebody \
                 signed in at its screen. Nothing else: the C# compiler that builds the agent and \
                 dxva2.dll, which carries the DDC/CI calls, are both parts of Windows.
                 """)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)

            field("Hostname", text: $target.host, placeholder: "hostname or IP address")
            field("Username", text: $target.user, placeholder: "the account signed in at the screen")

            HStack(spacing: 8) {
                Text("Port")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 92, alignment: .leading)
                TextField("22", value: $target.port, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Spacer()
            }

            Divider().overlay(Theme.rule)

            Picker("", selection: $usePassword) {
                Text("Use my SSH key").tag(false)
                Text("Sign in with a password").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if usePassword {
                HStack(spacing: 8) {
                    Text("Password")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 92, alignment: .leading)
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Also install my SSH key, so this is the last time a password is needed",
                       isOn: $target.installKey)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecond)
                    .toggleStyle(.checkbox)
                Text("""
                     The password is held in a private temporary file for the length of the install \
                     and handed to SSH through an askpass helper that answers only password prompts, \
                     so it never reaches a command line where `ps` would show it, and never a \
                     host-key prompt. The file is removed afterwards. You will be asked to confirm \
                     the machine's host key before anything is sent.
                     """)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Uses the key already in ~/.ssh. Choose the password option if this machine has never been connected to before.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 92, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(installer.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: step.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                            .font(.system(size: 12.5,
                                          weight: step.state == .running ? .semibold : .regular))
                            .foregroundStyle(step.state == .pending ? Theme.textDim : Theme.textPrimary)
                        if !step.detail.isEmpty {
                            Text(step.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(step.state == .failed ? Theme.danger : Theme.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            if let fingerprint = installer.hostFingerprint {
                VStack(alignment: .leading, spacing: 4) {
                    Text(installer.awaitingHostKeyApproval
                         ? "Confirm this is the machine you mean, before a password is sent to it:"
                         : "Host key")
                        .font(.system(size: 11.5,
                                      weight: installer.awaitingHostKeyApproval ? .semibold : .regular))
                        .foregroundStyle(installer.awaitingHostKeyApproval
                                         ? Theme.textPrimary : Theme.textSecond)
                    Text(fingerprint)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                    if installer.awaitingHostKeyApproval {
                        Text("Run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the machine "
                             + "itself and check it matches. Nothing has been sent yet.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 6)
            }

            if installer.finished {
                Divider().overlay(Theme.rule)
                Text(installer.succeeded
                     ? "Done. Bezel will use \(target.host) whenever its own DDC/CI path is blocked."
                     : "Install did not finish. The failing step above says why.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(installer.succeeded ? Theme.ok : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Log", isExpanded: $showLog) {
                Text(installer.log.isEmpty ? "—" : installer.log)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecond)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textSecond)
            .padding(.top, 4)
        }
    }

    private func icon(for state: AgentInstaller.StepState) -> some View {
        Group {
            switch state {
            case .pending: Image(systemName: "circle").foregroundStyle(Theme.textDim)
            case .running: ProgressView().controlSize(.small).scaleEffect(0.7)
            case .done:    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok)
            case .failed:  Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
            }
        }
        .font(.system(size: 13))
        .frame(width: 16, height: 16)
    }

    private var footer: some View {
        HStack {
            if installer.awaitingHostKeyApproval {
                Button("Approve Host Key and Continue") {
                    Task<Void, Never> {
                        await installer.install(
                            target: target,
                            auth: usePassword ? .password(password) : .key,
                            hostKeyApproved: true)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            if installer.finished && installer.succeeded {
                Button("Use This Host") {
                    controller.proxyHost = target.host
                    controller.proxyEnabled = true
                    Task<Void, Never> { await controller.reconnectProxy() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
            Button(installer.finished ? "Close" : "Cancel") { dismiss() }
                .disabled(installer.running)
            if !installer.finished {
                Button("Install") {
                    Task<Void, Never> {
                        await installer.install(
                            target: target,
                            auth: usePassword ? .password(password) : .key)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(installer.running || target.host.isEmpty
                          || (usePassword && password.isEmpty))
            }
        }
        .padding(16)
    }
}
