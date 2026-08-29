import SwiftUI
import AppKit

/// The compact panel behind the menu bar item. Carries the controls worth
/// reaching without opening a window; everything else lives in the full panel.
struct MenuPanel: View {
    @ObservedObject var controller: MonitorController
    @Environment(\.openWindow) private var openWindow
    @State private var showInstaller = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.rule)

            VStack(alignment: .leading, spacing: 14) {
                if controller.monitorControlAvailable {
                    FeatureSlider(code: 0x10, label: "Brightness", controller: controller)
                    FeatureSlider(code: 0x12, label: "Contrast", controller: controller)
                    inputRow
                } else {
                    unavailable
                }

                // Outside the availability check on purpose: the KVM rides the
                // SSH channel, not DDC/CI, so it still works on a machine whose
                // monitor control is blocked by the dock.
                Divider().overlay(Theme.rule)
                kvmRow
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider().overlay(Theme.rule)
            actions
        }
        .frame(width: 320)
        .background(Theme.canvas)
        .task {
            await controller.bootstrap()
            await controller.refreshVisible()
        }
        .sheet(isPresented: $showInstaller) {
            InstallerView(controller: controller)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "display")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text(controller.targetName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(controller.transport.label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(controller.monitorControlAvailable ? Theme.accent : Theme.warning)
            }
            Spacer(minLength: 0)
            if controller.isProbing || controller.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task<Void, Never> { await controller.probe() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecond)
                }
                .buttonStyle(.plain)
                .help("Re-read the monitor")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var inputRow: some View {
        let state = controller.features[VCP.inputSelect.code]
        return Group {
            if let state, state.readable, !state.choices.isEmpty {
                HStack(spacing: 8) {
                    Text("Input")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 6)
                    StyledPicker(
                        options: state.choices.map { (value: $0.value, label: $0.label) },
                        selection: Binding(
                            get: { state.current },
                            set: { value in
                                Task<Void, Never> {
                                    await controller.set(code: VCP.inputSelect.code, value: value)
                                }
                            }),
                        enabled: true)
                }
            }
        }
    }

    /// Keyboard and mouse hand-off. The setting persists across launches.
    ///
    /// This said "never automatic" on the grounds that it takes over the
    /// pointer. That conflated two things: armed only means the panel's right
    /// edge becomes a doorway, and the pointer does not go anywhere until it is
    /// deliberately driven through it. Restoring the switch takes nothing away,
    /// and re-arming after every launch made a setting behave like a toy.
    private var kvmRow: some View {
        let target = controller.proxyHost.isEmpty ? "the PC" : controller.proxyHost
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Control \(target)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                    Text(controller.kvmStatus)
                        .font(.system(size: 10.5))
                        .foregroundStyle(controller.kvmControllingRemote
                                         ? Theme.accent : Theme.textSecond)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { controller.kvmEnabled },
                    set: { on in Task<Void, Never> { await controller.setKVM(on) } }))
                    .labelsHidden()
                    .toggleStyle(StatusToggleStyle())
                    .disabled(controller.proxyHost.isEmpty)
            }
            // The Space that stands for the PC. Separate switch, because it is a
            // bigger commitment than arming the edge: it puts a full-screen
            // window on the panel and takes over a Mission Control slot.
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(target) as a Space")
                        .font(.system(size: 13))
                        .foregroundStyle(controller.kvmEnabled ? Theme.textPrimary : Theme.textDim)
                    Text(controller.pcSpaceOpen
                         ? "in Mission Control — switch to it to use \(target)"
                         : "adds it beside your desktops")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textSecond)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { controller.pcSpaceOpen },
                    set: { on in controller.setPCSpace(on) }))
                    .labelsHidden()
                    .toggleStyle(StatusToggleStyle())
                    .disabled(!controller.kvmEnabled)
            }

            if let problem = controller.kvmError {
                Text(problem)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(controller.link.headline)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.warning)
            Text(controller.proxyDiagnostic
                 ?? (controller.link.explanation.split(separator: "\n\n").first.map(String.init) ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            row("Open Full Panel", "macwindow") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            row("Set Up a Control Proxy…", "arrow.down.circle") {
                showInstaller = true
                NSApp.activate(ignoringOtherApps: true)
            }
            row("Move Window to Primary Display", "rectangle.on.rectangle") {
                WindowPlacement.centreFrontmostOnPrimary()
            }
            Divider().overlay(Theme.rule).padding(.vertical, 4)
            row("Quit zBezel", "power") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
