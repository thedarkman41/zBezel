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

            TransportPill(controller: controller)
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

    /// No ScrollView here, deliberately.
    ///
    /// This was the reason the window would not size itself: a scroll view is
    /// content to be any height at all, so it reports a tiny ideal size, the
    /// window shrinks to that and scrolls instead of growing. .contentSize
    /// resizability cannot work against it — the window was sized to fit the
    /// scroll view rather than to fit the tab.
    private var content: some View {
        Group {
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


/// How the monitor is being reached, and the button that re-reads it — one
/// control rather than a label sitting next to an unrelated glyph.
///
/// While a probe is running the whole pill becomes the progress indicator: a
/// gradient sweeps across it, thickening from transparent to solid. That says
/// "working" using the shape that is already there, instead of a spinner and a
/// line of status text appearing beside it and shifting the toolbar around.
private struct TransportPill: View {
    @ObservedObject var controller: MonitorController

    private var busy: Bool { controller.isProbing || controller.isRefreshing }

    /// Seconds per revolution of the glyph, and per pass of the sweep.
    ///
    /// Both are driven by a TimelineView rather than a repeatForever animation.
    /// A repeating animation in SwiftUI does not end when the value it animates
    /// is reassigned — it keeps running for the life of the view, which is why
    /// the first version span on long after the read had finished. A timeline
    /// simply stops existing when `busy` goes false.
    private let spinPeriod: Double = 2.2
    private let sweepPeriod: Double = 1.6

    private var label: String {
        if case .proxy(let host, _, _) = controller.transport { return "via \(host)" }
        return controller.monitorControlAvailable ? "direct" : "no link"
    }

    private var symbol: String {
        if case .proxy = controller.transport { return "arrow.triangle.branch" }
        return controller.monitorControlAvailable ? "cable.connector" : "bolt.horizontal"
    }

    var body: some View {
        Button {
            Task<Void, Never> { await controller.probe() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                refreshGlyph
            }
            .foregroundStyle(controller.monitorControlAvailable ? Theme.accent : Theme.warning)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(background)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(
                (controller.monitorControlAvailable ? Theme.accent : Theme.warning)
                    .opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(busy ? controller.probeStatus : "Re-examine the link and re-read the monitor")
    }

    private var refreshGlyph: some View {
        Group {
            if busy {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = t.truncatingRemainder(dividingBy: spinPeriod) / spinPeriod
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(phase * 360))
                }
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
    }

    private var background: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.15))
                if busy {
                    // A band the length of the pill, transparent at its leading
                    // edge and solid at its trailing one, swept across.
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let phase = t.truncatingRemainder(dividingBy: sweepPeriod) / sweepPeriod
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Theme.accent.opacity(0),
                                         Theme.accent.opacity(0.20),
                                         Theme.accent.opacity(0.55)],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width)
                            .offset(x: (phase * 2 - 1) * geo.size.width)
                    }
                }
            }
        }
    }
}
