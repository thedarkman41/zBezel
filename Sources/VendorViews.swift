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
        if anyUnmapped {
            VendorHint(controller: controller)
        } else {
            VendorReadingNote(controls: controls, controller: controller)
        }
    }
}

/// Says how much the selection above is worth.
///
/// The settings behind 0xE1 cannot be read on demand — the monitor answers a
/// read with whichever sub-selector its rotation lands on, and the ones that
/// matter here turn up in a few percent of reads. So there are three honest
/// states, and the interface used to draw all three identically as an empty
/// radio group: read and confirmed, remembered from a write or an earlier
/// session, and never seen at all. Only the first deserves silence.
struct VendorReadingNote: View {
    let controls: [VendorControl]
    @ObservedObject var controller: MonitorController

    /// Only sub-addressed controls have this problem; a plain code reads back
    /// every time and needs no caveat.
    private var readings: [(VendorControl, VendorReading?)] {
        controls.compactMap { control in
            guard let binding = controller.vendorMap[control], binding.isSubAddressed
            else { return nil }
            return (control, controller.reading(for: control))
        }
    }

    private var unconfirmed: [(VendorControl, VendorReading?)] {
        readings.filter { $0.1?.confirmed != true }
    }

    var body: some View {
        if !readings.isEmpty && !unconfirmed.isEmpty {
            if controller.vendorSampling {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Reading from the monitor…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecond)
                }
                .padding(.top, 2)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Re-read") {
                        Task<Void, Never> { await controller.refreshVendorReadings() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .disabled(!controller.controlsLive)
                }
                .padding(.top, 2)
                .help("This setting lives behind a manufacturer code that answers with only "
                    + "one of the settings it holds, and which one is not ours to choose. "
                    + "When it will not name this one, the value shown is what it was last "
                    + "read or last set to.")
            }
        }
    }

    private var message: String {
        let known = unconfirmed.filter { $0.1 != nil }
        guard let latest = known.compactMap({ $0.1?.takenAt }).max() else {
            return "The monitor has not reported this. Choosing an option sets it, "
                 + "and it is remembered here."
        }
        return "Last known setting, from \(Self.when(latest)). "
             + "The monitor reports this one only occasionally."
    }

    private static func when(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "a moment ago" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
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
                        Button("Cancel") { controller.cancelVendorMapping() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
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
