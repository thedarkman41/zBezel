import SwiftUI

/// A control HP defines but the standard does not. Renders live once the code
/// behind it has been discovered, and explains how to discover it until then.
struct VendorControlView: View {
    let control: VendorControl
    @ObservedObject var controller: MonitorController
    /// Suppressed when a group of these shares one explanation.
    var showHint: Bool = true

    var body: some View {
        if let binding = controller.vendorMap[control] {
            let current = controller.currentValue(for: control)
            let selected = current.flatMap { binding.optionIndex(forValue: $0) }

            if control.isToggle {
                ToggleRow(
                    label: control.rawValue,
                    isOn: Binding(
                        get: { selected == 1 },
                        set: { isOn in
                            Task<Void, Never> {
                                await controller.setVendor(control, optionIndex: isOn ? 1 : 0)
                            }
                        }),
                    enabled: controller.controlsLive)
            } else {
                ForEach(Array(control.options.enumerated()), id: \.offset) { index, label in
                    RadioRow(label: label,
                             isOn: selected == index,
                             enabled: controller.controlsLive) {
                        Task<Void, Never> { await controller.setVendor(control, optionIndex: index) }
                    }
                }
            }

        } else {
            if control.isToggle {
                ToggleRow(label: control.rawValue, isOn: .constant(false), enabled: false)
            } else {
                ForEach(Array(control.options.enumerated()), id: \.offset) { _, label in
                    RadioRow(label: label, isOn: false, enabled: false) {}
                }
            }
            if showHint { VendorHint(controller: controller) }
        }
    }
}

/// One explanation for a group of unmapped vendor controls, rather than the
/// same sentence repeated under each of them.
struct VendorHint: View {
    @ObservedObject var controller: MonitorController
    var body: some View {
        UnavailableNote(text: controller.monitorControlAvailable
            ? "Not yet mapped. HP does not publish these codes — use Discover Vendor Controls on the Advanced tab to find them."
            : "Needs a working control channel to the monitor.")
    }
}

/// Renders several vendor controls with a single shared explanation.
struct VendorGroup: View {
    let controls: [VendorControl]
    @ObservedObject var controller: MonitorController

    private var anyUnmapped: Bool {
        controls.contains { controller.vendorMap[$0] == nil }
    }

    var body: some View {
        ForEach(controls) { control in
            VendorControlView(control: control, controller: controller, showHint: false)
        }
        if anyUnmapped { VendorHint(controller: controller) }
    }
}

/// Snapshot the vendor codes, have the operator change one setting elsewhere,
/// then see exactly which code moved.
struct VendorMapperCard: View {
    @ObservedObject var controller: MonitorController
    @State private var assigning: VendorChange?

    var body: some View {
        Card(title: "Vendor Controls", systemImage: "scope",
             help: """
             HP's Auto Switch, DisplayPort version, USB-C configuration and PiP controls live in \
             the manufacturer-reserved VCP range, which no public document describes. This finds \
             them by watching which code moves when you change one setting.
             """) {
            if !controller.monitorControlAvailable {
                UnavailableNote(text: "Needs a working control channel to the monitor.")
            } else if controller.vendorCodes.isEmpty {
                UnavailableNote(text: "This monitor declares no manufacturer-specific codes.")
            } else {
                // The code list and the numbered step used to sit here. Both
                // were restating what is either on screen already — every code
                // is listed in the card beside this one — or obvious from the
                // button. Two paragraphs of preamble above a one-word action.
                Button(controller.vendorBaseline == nil ? "Snapshot" : "Re-snapshot") {
                    Task<Void, Never> { await controller.snapshotVendorCodes() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .disabled(controller.mapperBusy)

                if controller.vendorBaseline != nil {
                    stepRow(2, "Change exactly one setting — in HP Display Center on the other "
                             + "machine, or with the monitor's own buttons.")
                    stepRow(3, "Come back and compare.")
                    Button("Compare") {
                        Task<Void, Never> { await controller.compareVendorCodes() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .disabled(controller.mapperBusy)
                }

                if controller.mapperBusy {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reading the monitor…")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textSecond)
                    }
                }

                if !controller.vendorChanges.isEmpty {
                    Divider().overlay(Theme.rule).padding(.vertical, 2)
                    Text(controller.vendorChanges.count == 1
                         ? "One code moved — that is your control."
                         : "\(controller.vendorChanges.count) codes moved. Change only one setting "
                           + "per pass to narrow it down.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    ForEach(controller.vendorChanges) { change in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(change.description)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.ok)
                            if let decomposed = change.decomposed {
                                Text(decomposed)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.textDim)
                            }
                            Menu("Assign to…") {
                                ForEach(VendorControl.allCases) { control in
                                    Button(control.rawValue) { controller.bind(control, to: change) }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .font(.system(size: 11.5))
                        }
                        .padding(.vertical, 2)
                    }
                } else if controller.vendorBaseline != nil && !controller.mapperBusy {
                    Text("No differences yet. Change a setting, then compare.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                }

                if !controller.vendorMap.bindings.isEmpty {
                    Divider().overlay(Theme.rule).padding(.vertical, 2)
                    Text("Mapped controls")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    ForEach(VendorControl.allCases) { control in
                        if let binding = controller.vendorMap[control] {
                            // The evidence is a tooltip now. It is the reason to
                            // trust the mapping and worth keeping, but it runs to
                            // four lines for some controls and was setting the
                            // height of the whole tab to hold prose nobody reads
                            // twice.
                            HStack(alignment: .firstTextBaseline) {
                                Text(control.rawValue)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 6)
                                Text(String(format: "0x%02X", binding.code))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textSecond)
                            }
                            .contentShape(Rectangle())
                            .help(String(format: "0x%02X — %@", binding.code, binding.evidence))
                            .padding(.vertical, 1)
                        }
                    }
                }
            }
        }
    }

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.canvas)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Theme.textSecond))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecond)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
