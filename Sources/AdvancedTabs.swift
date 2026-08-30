import SwiftUI
import AppKit

// MARK: - Advanced

struct AdvancedTab: View {
    @ObservedObject var controller: MonitorController

    var body: some View {
        // Firmware and the capabilities string share the right column: firmware
        // is six short rows and was leaving most of a column empty next to the
        // tallest card on the tab, while the capabilities string sat below in a
        // row of its own.
        CardGrid {
            VendorMapperCard(controller: controller)
            VStack(spacing: 16) {
                monitorIdentityCard
                capabilitiesCard
            }
            vendorCodeCard
            resetCard
        }
    }

    private var monitorIdentityCard: some View {
        Card(title: "Monitor Firmware", systemImage: "cpu",
             help: "Values the monitor reports over MCCS.") {
            if controller.monitorControlAvailable {
                if let version = controller.features[0xDF] {
                    InfoRow("MCCS version", String(format: "%d.%d",
                                                   version.current >> 8, version.current & 0xFF))
                }
                if let fw = controller.features[0xC9] {
                    InfoRow("Firmware level", String(format: "%u.%u", fw.current >> 8, fw.current & 0xFF))
                }
                if let ct = controller.features[0xC8] {
                    InfoRow("Controller", String(format: "0x%04X", ct.current))
                }
                if let caps = controller.capabilities {
                    InfoRow("Model string", caps.model ?? "—")
                    InfoRow("Panel type", caps.type ?? "—")
                    InfoRow("Declared codes", "\(caps.supportedCodes.count)")
                }
            } else {
                MonitorSideNote(controller: controller)
            }
        }
    }

    private var vendorCodeCard: some View {
        Card(title: "Manufacturer-Specific Codes", systemImage: "wrench.and.screwdriver",
             help: """
             MCCS reserves 0xE0–0xFF for the manufacturer. HP's Auto Switch, DisplayPort version, \
             USB-C configuration and PiP controls live here. No public standard documents them, so \
             the only way to find them is to read the codes this monitor declares and observe how \
             each one changes.
             """) {
            if let caps = controller.capabilities, !caps.manufacturerCodes.isEmpty {
                Text("This monitor declares \(caps.manufacturerCodes.count) manufacturer codes. "
                     + "Hover one for what it accepts.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecond)
                // Two columns. Fourteen codes in a single list ran longer than
                // everything else on the tab put together; side by side they
                // take half the height and the card stops setting the height of
                // the window on its own.
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .topLeading),
                                    GridItem(.flexible(), spacing: 14, alignment: .topLeading)],
                          alignment: .leading, spacing: 2) {
                    ForEach(caps.manufacturerCodes, id: \.self) { code in
                        VendorCodeRow(code: code, controller: controller)
                    }
                }
            } else if controller.monitorControlAvailable {
                Text("This monitor declared no manufacturer-specific codes.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            } else {
                MonitorSideNote(controller: controller)
            }
        }
    }

    private var capabilitiesCard: some View {
        Card(title: "Capabilities String", systemImage: "doc.plaintext",
             help: "The raw VCP 0xF3 response — the monitor's own statement of what it supports.") {
            if let caps = controller.capabilities {
                ScrollView {
                    Text(caps.raw)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecond)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Exempt from the panel-wide selection ban: this is a value
                        // someone pastes into a bug report, which is the whole reason
                        // it is on screen.
                        .textSelection(.enabled)
                }
                .frame(height: 150)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(caps.raw, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            } else {
                MonitorSideNote(controller: controller)
            }
        }
    }

    private var resetCard: some View {
        Card(title: "Reset", systemImage: "arrow.counterclockwise",
             help: "MCCS restore-defaults commands. These change the monitor, not macOS.") {
            ResetButton(title: "Restore factory defaults", code: 0x04, controller: controller)
            ResetButton(title: "Restore brightness & contrast", code: 0x05, controller: controller)
            ResetButton(title: "Restore factory colour", code: 0x08, controller: controller)
            if !controller.monitorControlAvailable {
                MonitorSideNote(controller: controller)
            }
        }
    }
}

private struct MonitorSideNote: View {
    @ObservedObject var controller: MonitorController
    var body: some View {
        UnavailableNote(text: "Needs a working DDC/CI link to the monitor. See the Link tab.")
    }
}

private struct ResetButton: View {
    let title: String
    let code: UInt8
    @ObservedObject var controller: MonitorController
    @State private var confirming = false

    var body: some View {
        Button(title) { confirming = true }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(controller.controlsLive ? Theme.accent : Theme.textDim)
            .disabled(!controller.controlsLive)
            .alert(title, isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    Task<Void, Never> { await controller.set(code: code, value: 1) }
                }
            } message: {
                Text("This tells the monitor to discard its current settings. It cannot be undone from here.")
            }
    }
}

/// One manufacturer-specific code: its value now, and a guarded way to change it.
private struct VendorCodeRow: View {
    let code: UInt8
    @ObservedObject var controller: MonitorController
    @State private var editing = false
    @State private var newValue = ""

    var body: some View {
        let state = controller.features[code]
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(String(format: "0x%02X", code))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 46, alignment: .leading)
                if let state, state.readable {
                    // Raw VCP values: plain digits, never locale grouping.
                    Text(String(format: "= %u (0x%04X)  max %u",
                                state.current, state.current, state.maximum))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textSecond)
                } else {
                    Text("unreadable")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                }
                Spacer(minLength: 6)
                Button(editing ? "Cancel" : "Set") { editing.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            if editing {
                HStack(spacing: 8) {
                    TextField("value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 90)
                    Button("Write") {
                        if let v = UInt16(newValue) ?? UInt16(newValue.replacingOccurrences(
                                of: "0x", with: ""), radix: 16) {
                            Task<Void, Never> { await controller.set(code: code, value: v) }
                        }
                        editing = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.danger)
                }
                Text("Writing an undocumented code is a guess. Note the value above first so you can put it back.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(detail)
    }

    /// Everything that used to be printed under each code.
    ///
    /// Fourteen codes each carrying two or three lines of hex was most of the
    /// height of the tab, to show values that matter only when someone is
    /// actually poking at that one code.
    private var detail: String {
        var parts: [String] = []
        let subSelectors = controller.capabilities?.subSelectors(for: code) ?? []
        if !subSelectors.isEmpty {
            parts.append("sub-settings: "
                + subSelectors.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        } else if let permitted = controller.capabilities?.values(for: code), !permitted.isEmpty {
            parts.append("accepts: "
                + permitted.map { String(format: "0x%02X", $0) }.joined(separator: " "))
        }
        if let note = HPProfile.note(for: code) { parts.append(note) }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Link

struct LinkTab: View {
    @ObservedObject var controller: MonitorController
    @State private var showInstaller = false

    var body: some View {
        // Two by two. The verdict used to run full width above a grid of three,
        // which left half of the second row empty; now that it is a title and
        // five rows it sits alongside the others instead of dwarfing them.
        VStack(alignment: .leading, spacing: 16) {
            CardGrid {
                verdictCard
                proxyCard
                busCard
                dpcdCard
            }
        }
        .sheet(isPresented: $showInstaller) {
            InstallerView(controller: controller)
        }
    }

    /// When the local path cannot carry DDC/CI, a machine that can reach the
    /// monitor directly relays commands on our behalf.
    private var proxyCard: some View {
        Card(title: "Control Proxy", systemImage: "arrow.triangle.branch",
             help: """
             A host with this monitor on a direct connection can issue DDC/CI for us.              It runs BezelAgent in its interactive desktop session and is reached over SSH.
             """) {
            ToggleRow(label: "Use a proxy when direct DDC/CI fails",
                      isOn: Binding(get: { controller.proxyEnabled },
                                    set: { controller.proxyEnabled = $0 }))

            HStack(spacing: 8) {
                Text("Host")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 46, alignment: .leading)
                TextField("hostname", text: Binding(get: { controller.proxyHost },
                                                    set: { controller.proxyHost = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 150)
                Button("Reconnect") {
                    Task<Void, Never> { await controller.reconnectProxy() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                Button("Set Up…") { showInstaller = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .help("Install the agent on a Windows machine from scratch")
            }

            Divider().overlay(Theme.rule).padding(.vertical, 2)

            switch controller.transport {
            case .proxy:
                // The host and the monitor are both named in the list below, so
                // repeating them here was the same two facts twice.
                CheckRow("Proxy Info", true)
            case .local:
                CheckRow("Direct DDC/CI in use; no proxy needed", true)
            case .none:
                CheckRow("No control channel", false,
                         detail: controller.proxyDiagnostic ?? "proxy not in use")
            }

            if !controller.remoteMonitors.isEmpty {
                Text("Visible monitors on Proxy")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.textSecond)
                    .padding(.top, 2)
                // Named first, numbered second: the name is what identifies a
                // display to a person, and the index only matters as the handle
                // the agent uses. Every monitor the proxy can see is listed, so a
                // machine driving several shows all of them.
                ForEach(controller.remoteMonitors) { monitor in
                    InfoRow(monitor.description + (monitor.pnpID.map { " (\($0))" } ?? ""),
                            "Monitor #\(monitor.index)")
                }
            }
        }
    }

    /// The verdict on how this monitor is being controlled.
    ///
    /// When the proxy is carrying the controls this card used to announce
    /// "DDC/CI blocked in the video path" under a warning triangle, and advise
    /// plugging the monitor in differently — beside a panel whose brightness,
    /// contrast and input were all working perfectly. It described the local
    /// path as though the local path were the only one, which stopped being
    /// true the moment the proxy came up.
    ///
    /// It now reports what IS happening. The local checks stay, because they
    /// are why the proxy exists and are worth being able to see, but the ones
    /// the dock blocks are drawn as expected rather than as failures.
    private var verdictCard: some View {
        let report = controller.link
        var proxyHost: String? = nil
        if case .proxy(let host, _, _) = controller.transport { proxyHost = host }

        let title = proxyHost.map { "Monitor Control (via \($0))" }
            ?? (report.monitorSideAvailable ? "Monitor Control (direct)" : report.headline)
        let symbol = (proxyHost != nil || report.monitorSideAvailable)
            ? "checkmark.seal" : "exclamationmark.triangle"

        // Which wire the working path runs over. Through a proxy that is the
        // connector on the OTHER machine, which its monitor description names;
        // directly it is this Mac's own, from the EDID.
        let remote = controller.remoteTarget?.description ?? ""
        let proxyLink = ["USB-C", "DisplayPort", "HDMI"].first { remote.contains($0) }
        let path: String = {
            if proxyHost != nil {
                return proxyLink.map { "verified through \($0) on proxy" }
                    ?? "verified on proxy"
            }
            let wire = controller.selected?.edid?.digitalInterface ?? "this connection"
            return "verified through \(wire)"
        }()

        // No prose. The title already says whether control works and the rows
        // say which parts of the local path do; the paragraphs that used to sit
        // here explained a problem that, with the proxy up, has no visible
        // symptom on this screen. The detail worth keeping is which input the
        // panel is actually showing, which is otherwise nowhere on this tab.
        return Card(title: title, systemImage: symbol,
                    help: proxyHost.map {
                        "Controls are relayed over SSH to \($0), which has the monitor on "
                        + "USB-C. The rows below are this Mac's own DDC/CI path, which the "
                        + "dock blocks — expected here, and the reason the proxy exists."
                    } ?? report.explanation) {
            CheckRow("IOFramebuffer matched", report.framebufferFound)
            CheckRow("I2C bus present", report.i2cBusCount > 0,
                     detail: controller.currentInputName
                          ?? (report.busType == 2 ? "DisplayPort AUX" : "native I2C"))
            CheckRow("EDID readable over the bus", report.edidReadOK,
                     detail: "proves the I2C path itself works")
            // Green when control genuinely works, wherever it works FROM. These
            // rows used to report only this Mac's own path, so a monitor being
            // driven perfectly well through the proxy showed two grey dashes and
            // read as a fault.
            let controlWorks = proxyHost != nil || report.monitorSideAvailable
            CheckRow("DDC/CI address acknowledged",
                     report.ddcAddressACK || controlWorks,
                     detail: controlWorks
                        ? path
                        : "address 0x37 — a one-byte write, independent of DDC framing")
            CheckRow("DDC/CI round trip",
                     report.ddcReplyOK || controlWorks,
                     detail: controlWorks ? path : "a full Get VCP Feature exchange")
        }
    }

    private var busCard: some View {
        let report = controller.link
        return Card(title: "Devices on the Link", systemImage: "point.3.connected.trianglepath.dotted",
                    help: """
                    DPCD identifies whatever terminates the AUX channel. A named branch device with \
                    an empty sink block means an intermediate device — a dock or MST hub — is \
                    answering instead of the monitor.
                    """) {
            InfoRow("Branch device", report.branchPresent ? report.branchDescription : "none")
            if report.branchPresent {
                InfoRow("Branch firmware", report.branchFirmware)
            }
            InfoRow("Sink device", report.sinkPresent
                    ? report.sinkOUI.map { String(format: "%02X", $0) }.joined(separator: ":")
                        + (report.sinkDeviceID.isEmpty ? "" : " “\(report.sinkDeviceID)”")
                    : "not reported")
            if report.branchPresent && !report.sinkPresent {
                UnavailableNote(text: """
                    Monitor is controlled via proxy. EDID reads work and control \
                    commands are routed through the proxy.
                    """)
            }
        }
    }

    private var dpcdCard: some View {
        let report = controller.link
        return Card(title: "DisplayPort Link", systemImage: "waveform.path",
                    help: "Raw DPCD values read over the native AUX channel.") {
            InfoRow("DPCD revision", String(format: "%d.%d", report.dpcdRev >> 4, report.dpcdRev & 0x0F))
            InfoRow("Max link rate", linkRateName(report.maxLinkRate))
            InfoRow("Max lane count", "\(report.maxLaneCount & 0x1F)")
            InfoRow("Downstream port", report.downstreamPort & 0x01 != 0 ? "present" : "none")
            InfoRow("MST capable", report.mstCap & 0x01 != 0 ? "yes" : "no")
            InfoRow("MST enabled", report.mstEnabled ? "yes" : "no (single-stream)")
        }
    }

    private func linkRateName(_ raw: UInt8) -> String {
        switch raw {
        case 0x06: return "RBR (1.62 Gbps/lane)"
        case 0x0A: return "HBR (2.7 Gbps/lane)"
        case 0x14: return "HBR2 (5.4 Gbps/lane)"
        case 0x1E: return "HBR3 (8.1 Gbps/lane)"
        default:   return String(format: "0x%02X", raw)
        }
    }
}

private struct CheckRow: View {
    let label: String
    let ok: Bool
    var detail: String? = nil

    /// When true, a check that did not pass is not a fault: it is the known
    /// state of a path this setup deliberately does not use. Drawn as a neutral
    /// dash rather than a red cross, because a red cross beside working
    /// hardware reads as something to go and fix.
    var expected: Bool = false

    init(_ label: String, _ ok: Bool, detail: String? = nil, expected: Bool = false) {
        self.label = label; self.ok = ok; self.detail = detail; self.expected = expected
    }
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: ok ? "checkmark.circle.fill"
                                 : (expected ? "minus.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 13))
                .foregroundStyle(ok ? Theme.ok : (expected ? Theme.textDim : Theme.danger))
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textDim)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
