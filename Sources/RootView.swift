import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case display     = "Display"
    case color       = "Color"
    case input       = "Input"
    case view        = "View"
    case advanced    = "Advanced"
    case multiScreen = "MultiScreen"
    case link        = "Link"

    var id: String { rawValue }
}

struct RootView: View {
    @ObservedObject var controller: MonitorController
    @AppStorage("selectedTab") private var storedTab: String = PanelTab.input.rawValue

    private var tab: PanelTab {
        get { PanelTab(rawValue: storedTab) ?? .input }
        nonmutating set { storedTab = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider().overlay(Color.white.opacity(0.08))
            content
        }
        .background(Theme.canvas)
        .background(WindowPlacement())
        // A fixed width so the seven tabs and the two-column grid always lay out
        // the same, and a height that follows whatever the current tab needs
        // rather than being padded out to match the tallest one.
        .frame(width: 980)
        // Nothing here is meant to be selected — it is a control panel, not a
        // document, and a stray drag highlighting a label looks like a bug.
        .textSelection(.disabled)
        .task {
            await controller.bootstrap()
            await controller.refreshVisible()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task<Void, Never> { await controller.refreshVisible() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didChangeScreenParametersNotification)) { _ in
            controller.refreshDisplays()
        }
    }

    // MARK: Navigation

    private var navigationBar: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(controller.displays.filter { !$0.isBuiltIn }) { display in
                    Button {
                        controller.selectedID = display.id
                        Task<Void, Never> { await controller.probe() }
                    } label: {
                        Text(display.name)
                    }
                }
                if !controller.hasLocalDisplay, let remote = controller.remoteTarget {
                    Text("\(remote.description) — reached through \(controller.proxyHost)")
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "display")
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.textPrimary)
                    Text(controller.targetName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecond)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, 22)

            Rectangle()
                .fill(Theme.rule)
                .frame(width: 1, height: 26)
                .padding(.horizontal, 20)

            HStack(spacing: 4) {
                ForEach(PanelTab.allCases) { item in
                    tabButton(item)
                }
            }

            Spacer(minLength: 12)

            if controller.monitorControlAvailable, case .proxy(let host, _, _) = controller.transport {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                    Text("via \(host)")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.accent.opacity(0.15)))
                .padding(.trailing, 10)
                .help("Monitor control is being relayed through \(host), which has an unobstructed DDC/CI path.")
            }

            if controller.isProbing || controller.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.probeStatus)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecond)
                }
            } else {
                Button {
                    Task<Void, Never> { await controller.probe() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecond)
                }
                .buttonStyle(.plain)
                .help("Re-examine the link and re-read the monitor")
            }
        }
        .padding(.trailing, 22)
        .frame(height: 60)
        .background(Theme.canvas)
    }

    private func tabButton(_ item: PanelTab) -> some View {
        let active = tab == item
        return Button {
            tab = item
        } label: {
            VStack(spacing: 5) {
                Text(item.rawValue)
                    .font(.system(size: 14, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textSecond)
                Rectangle()
                    .fill(active ? Theme.accent : .clear)
                    .frame(height: 2)
            }
            .padding(.horizontal, 11)
            .padding(.top, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !controller.monitorControlAvailable && !controller.isProbing {
                    LinkBanner(report: controller.link,
                               proxyDiagnostic: controller.proxyDiagnostic) { tab = .link }
                }

                switch tab {
                case .display:     DisplayTab(controller: controller)
                case .color:       ColorTab(controller: controller)
                case .input:       InputTab(controller: controller)
                case .view:        ViewTab(controller: controller)
                case .advanced:    AdvancedTab(controller: controller)
                case .multiScreen: MultiScreenTab(controller: controller)
                case .link:        LinkTab(controller: controller)
                }
            }
            .padding(22)
        }
        .background(Theme.canvas)
    }
}

/// Two equal columns, matching the HP panel's layout.
struct CardGrid<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 16, alignment: .top),
                      GridItem(.flexible(), spacing: 16, alignment: .top)],
            spacing: 16
        ) {
            content
        }
    }
}

struct LinkBanner: View {
    let report: LinkReport
    var proxyDiagnostic: String? = nil
    var onInspect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(report.headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(report.explanation
                        .split(separator: "\n\n").first.map(String.init) ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecond)
                    .fixedSize(horizontal: false, vertical: true)
                if let proxyDiagnostic {
                    Text("Proxy: \(proxyDiagnostic)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Details", action: onInspect)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.warning.opacity(0.09))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.warning.opacity(0.30), lineWidth: 1)))
    }
}
