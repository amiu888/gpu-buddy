// GPU Buddy, Mac App Store edition (compiled with APPSTORE; see app/appstore/project.yml).
//
// A sandboxed, native Mac window around the views shared with the DMG and iOS apps (../GPUBuddy.swift):
// a sidebar of Macs, a toolbar, a Settings window, menu commands, and a first-run tutorial. Unlike the DMG
// app it can't install gpud (the sandbox forbids launchd agents and running Python), so it reads this
// Mac's gpud over loopback when it is installed, falls back to the GPU readings the sandbox allows
// (NativeFeed), watches paired Macs over TLS, and ships the Demo Mac for trying it out.

import AppKit
import Charts
import SwiftUI

let gpudRepo = URL(string: "https://github.com/amiu888/gpu-buddy")!
let gpudReadme = URL(string: "https://github.com/amiu888/gpu-buddy#install-from-source")!
let privacyPolicy = URL(string: "https://miulabs.app/gpubuddy-privacy/")!
/// One line in Terminal: get the code and install only the background service (no app build, no sudo).
let gpudInstallCommand = "git clone https://github.com/amiu888/gpu-buddy.git ~/gpu-buddy && ~/gpu-buddy/install.sh --service-only"

// MARK: - App

@main
struct GPUBuddyStoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var fleet = Fleet(localPort: Int(ProcessInfo.processInfo.environment["GPUD_PORT"] ?? "") ?? 8765)
    @StateObject private var characters = Characters()
    @State private var model = AppModel()

    var body: some Scene {
        Window("GPU Buddy", id: "main") {
            MainWindow(fleet: fleet, characters: characters)
                .environment(model)
        }
        .defaultSize(width: 1040, height: 720)
        .commands { GPUBuddyCommands(fleet: fleet, characters: characters, model: model) }

        Window("LLM Router", id: "router") {
            RouterView()
                .frame(minWidth: 900, minHeight: 480)
                .background(darkGround)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1220, height: 680)

        Window("Request Log", id: "requests") {
            RequestLogView()
                .frame(minWidth: 700, minHeight: 300)
                .background(darkGround)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1040, height: 560)

        Settings {
            AppSettingsView(fleet: fleet)
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // For screenshots and checking both looks: `--args -appearance light` (or dark). Normally it follows the system.
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The dark "instrument" ground the shared live views are drawn on.
let darkGround = Color(red: 0.1, green: 0.09, blue: 0.15)

enum DetailTab: String, CaseIterable, Identifiable {
    case overview, live, ledger
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .live: "Live"
        case .ledger: "Ledger"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .live: "sparkles.tv"
        case .ledger: "book.closed"
        }
    }
}

/// Window-wide UI state shared by the main window, its menus and Settings.
@Observable
@MainActor
final class AppModel {
    /// `--args -startTab live` opens on another tab (for screenshots).
    var tab: DetailTab = DetailTab(rawValue: UserDefaults.standard.string(forKey: "startTab") ?? "") ?? .overview
    var showPairing = UserDefaults.standard.bool(forKey: "showPairing")  // `-showPairing YES` (screenshots)
    var showTutorial = !UserDefaults.standard.bool(forKey: "tutorialDone")

    func finishTutorial() {
        UserDefaults.standard.set(true, forKey: "tutorialDone")
        showTutorial = false
    }
}

// MARK: - Menus

struct GPUBuddyCommands: Commands {
    @ObservedObject var fleet: Fleet
    @ObservedObject var characters: Characters
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Pair a Mac…") { model.showPairing = true }
                .keyboardShortcut("n")
        }
        CommandGroup(before: .sidebar) {
            Picker("Show", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { i, tab in
                    Text(tab.title).tag(tab).keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Next Character") { characters.next() }
                .keyboardShortcut("j")
            Button("Add Character from Photo…") { characters.addFromPanel() }
            Divider()
        }
        CommandMenu("Mac") {
            Button("Next Mac") { fleet.step(1) }
                .keyboardShortcut("]")
            Button("Previous Mac") { fleet.step(-1) }
                .keyboardShortcut("[")
            Divider()
            Button("Show Demo Mac") { fleet.showDemo() }
            Button("Forget \(fleet.current.host.isDemo ? "Demo Mac" : fleet.current.host.name)") { fleet.remove(fleet.current.host.id) }
                .disabled(fleet.current.host.isLocal)
            Divider()
            Button("LLM Router…") { openWindow(id: "router") }
                .keyboardShortcut("e")
            Button("Request Log…") { openWindow(id: "requests") }
                .keyboardShortcut("r")
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started with GPU Buddy") { model.showTutorial = true }
            Button("Install gpud (GitHub)") { openURL(gpudReadme) }
            Button("Copy gpud Install Command") { copyToClipboard(gpudInstallCommand) }
            Divider()
            Button("Privacy Policy") { openURL(privacyPolicy) }
        }
    }
}

// MARK: - Main window

struct MainWindow: View {
    @ObservedObject var fleet: Fleet
    @ObservedObject var characters: Characters
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var started = false
    private let anim = Anim()

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            MacSidebar(fleet: fleet)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            MacDetail(store: fleet.current, fleet: fleet, characters: characters, anim: anim)
                .id(fleet.current.host.id)
        }
        .navigationTitle(fleet.current.host.isLocal ? "This Mac" : fleet.current.host.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.tab) {
                    ForEach(DetailTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .help("Overview, the live view with Chippy, or the token ledger (⌘1, ⌘2, ⌘3)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { openWindow(id: "router") } label: { Label("LLM Router", systemImage: "point.3.connected.trianglepath.dotted") }
                    .help("LLM Router: share this Mac's local AI with other devices (⌘E). Needs gpud.")
                Button { model.showPairing = true } label: { Label("Pair a Mac", systemImage: "plus") }
                    .help("Pair a Mac that runs gpud (⌘N)")
            }
        }
        .sheet(isPresented: $model.showPairing) { PairSheet(fleet: fleet) }
        .sheet(isPresented: $model.showTutorial) { TutorialSheet(fleet: fleet) }
        .onReceive(NotificationCenter.default.publisher(for: .openRouter)) { _ in openWindow(id: "router") }
        .onReceive(NotificationCenter.default.publisher(for: .openRequestLog)) { _ in openWindow(id: "requests") }
        .task {
            guard !started else { return }
            started = true
            fleet.onOpenLedger = { model.tab = .ledger }
            fleet.onOpenMacs = { model.showPairing = true }
            fleet.onUpdate = { DockBadge.update($0) }
            fleet.start()
            if UserDefaults.standard.bool(forKey: "showSettings") {  // `-showSettings YES` (screenshots)
                openSettings()
            }
        }
    }
}

/// The Dock icon shows the selected Mac's GPU load, like the DMG app.
@MainActor
enum DockBadge {
    private static var last = -2
    static func update(_ s: GPUStore) {
        let pct = s.online ? Int(s.liveUtil * 100) : -1
        guard pct != last else { return }
        last = pct
        let r = ImageRenderer(content: DockIcon(util: s.liveUtil, online: s.online))
        r.scale = 1
        if let img = r.nsImage { NSApp.applicationIconImage = img }
    }
}

// MARK: - Sidebar

struct MacSidebar: View {
    @ObservedObject var fleet: Fleet
    @Environment(AppModel.self) private var model

    private var selection: Binding<String?> {
        Binding(get: { fleet.current.host.id },
                set: { id in if let s = fleet.stores.first(where: { $0.host.id == id }) { fleet.select(s) } })
    }

    var body: some View {
        let local = fleet.stores.filter { $0.host.isLocal }
        let paired = fleet.stores.filter { !$0.host.isLocal && !$0.host.isDemo }
        let demo = fleet.stores.filter { $0.host.isDemo }
        List(selection: selection) {
            Section("This Mac") {
                ForEach(local, id: \.host.id) { MacRow(store: $0).tag($0.host.id as String?) }
            }
            Section("Paired Macs") {
                ForEach(paired, id: \.host.id) { s in
                    MacRow(store: s).tag(s.host.id as String?)
                        .contextMenu { Button("Forget \(s.host.name)", role: .destructive) { fleet.remove(s.host.id) } }
                }
                Button { model.showPairing = true } label: {
                    Label("Pair a Mac…", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            Section("Sample") {
                ForEach(demo, id: \.host.id) { s in
                    MacRow(store: s).tag(s.host.id as String?)
                        .contextMenu { Button("Remove Demo Mac", role: .destructive) { fleet.remove(s.host.id) } }
                }
                if demo.isEmpty {
                    Button { fleet.showDemo() } label: { Label("Show Demo Mac", systemImage: "play.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("A pretend Mac Studio with sample data, to try every screen")
                }
            }
            if !fleet.found.filter({ !fleet.isPaired($0.id) }).isEmpty {
                Section("On Your Network") {
                    ForEach(fleet.found.filter { !fleet.isPaired($0.id) }) { f in
                        Button { model.showPairing = true } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(f.name)
                                    Text("Not paired").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: { Image(systemName: "desktopcomputer").foregroundStyle(.secondary) }
                        }
                        .buttonStyle(.borderless)
                        .help(f.summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The SF Symbol for a Mac model ("Mac Studio" → macstudio).
@MainActor func machineSymbol(_ store: GPUStore) -> String {
    let m = (store.snap?.host?.model_name ?? (store.host.isDemo ? "Mac Studio" : "")).lowercased()
    if m.contains("studio") { return "macstudio" }
    if m.contains("mini") { return "macmini" }
    if m.contains("book") { return "laptopcomputer" }
    if m.contains("pro") { return "macpro.gen3" }
    return "desktopcomputer"
}

struct MacRow: View {
    @ObservedObject var store: GPUStore

    private var symbol: String { machineSymbol(store) }

    private var status: (String, Color) {
        if !store.online { return ("Offline", .secondary) }
        if store.host.isDemo { return ("Sample data", .purple) }
        if store.host.isLocal && store.client.usingNative { return ("Basic readings", .orange) }
        return ("Connected", .green)
    }

    var body: some View {
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.host.isLocal ? (store.snap?.host?.name ?? "This Mac") : store.host.name).lineLimit(1)
                    Text(status.0).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.online {
                    Text("\(Int(store.liveUtil * 100))%")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: symbol)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(status.1).frame(width: 7, height: 7).offset(x: 3, y: 2)
                }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.host.title), \(status.0)\(store.online ? ", GPU \(Int(store.liveUtil * 100)) percent" : "")")
    }
}

// MARK: - Detail

struct MacDetail: View {
    @ObservedObject var store: GPUStore
    @ObservedObject var fleet: Fleet
    @ObservedObject var characters: Characters
    let anim: Anim
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.tab {
            case .overview: OverviewView(store: store, fleet: fleet)
            case .live: liveView
            case .ledger: ledgerView
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var liveView: some View {
        ScrollView {
            ContentView(store: store, fleet: fleet, characters: characters, anim: anim)
                .frame(width: fleet.compact ? 230 : 300)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .background(.background.secondary)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var ledgerView: some View {
        if store.host.isLocal && store.client.usingNative {
            NeedsGpud(feature: "The Token Ledger", detail: "gpud records every token your local LLMs read and write, with the energy used and what the same work would cost in the cloud.")
        } else if !store.online {
            OfflineView(store: store, fleet: fleet)
        } else {
            LedgerTab(store: store)
                .id(store.host.id)
                .background(darkGround)
                .environment(\.colorScheme, .dark)
        }
    }
}

/// The ledger for one Mac. Owns its Ledger so it's made once per Mac, not on every redraw.
struct LedgerTab: View {
    @StateObject private var ledger: Ledger
    init(store: GPUStore) {
        _ledger = StateObject(wrappedValue: Ledger(client: store.client, hostName: store.host.title,
                                                   machine: store.snap?.host?.model_name ?? "Mac"))
    }
    var body: some View { ScrollView { LedgerView(ledger: ledger).frame(maxWidth: 520).frame(maxWidth: .infinity) } }
}

struct NeedsGpud: View {
    let feature: String
    let detail: String
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("\(feature) needs gpud", systemImage: "shippingbox")
        } description: {
            Text(detail + "\n\ngpud is GPU Buddy's free, open-source background service. Install it once from GitHub and GPU Buddy picks it up automatically.")
        } actions: {
            Button("How to Install gpud") { model.showTutorial = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct OfflineView: View {
    @ObservedObject var store: GPUStore
    @ObservedObject var fleet: Fleet

    var body: some View {
        ContentUnavailableView {
            Label("Can't reach \(store.host.name)", systemImage: "wifi.exclamationmark")
        } description: {
            Text("\(store.problem.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "No answer").\nMake sure that Mac is awake, on the same network, and running gpud. GPU Buddy keeps trying.")
        } actions: {
            Button("Forget This Mac", role: .destructive) { fleet.remove(store.host.id) }
        }
    }
}

struct OverviewView: View {
    @ObservedObject var store: GPUStore
    @ObservedObject var fleet: Fleet
    @Environment(AppModel.self) private var model

    private var basic: Bool { store.host.isLocal && store.client.usingNative }

    var body: some View {
        if !store.online && !store.host.isLocal {
            OfflineView(store: store, fleet: fleet)
        } else if !store.online {
            ContentUnavailableView("Reading this Mac's GPU…", systemImage: "hourglass")
        } else if let s = store.snap {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(s)
                    if basic { basicBanner }
                    if store.host.isDemo { demoBanner }
                    metrics(s)
                    chart
                    if !s.processes.isEmpty { processes(s) }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func header(_ s: Snapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: machineSymbol(store))
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 48, height: 48)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.host.isLocal ? (s.host?.name ?? "This Mac") : store.host.name).font(.title2.bold())
                Text(s.host?.hardware ?? s.gpu.model).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            sourceBadge
        }
    }

    private var sourceBadge: some View {
        let (text, color): (String, Color) = store.host.isDemo ? ("Sample data", .purple)
            : basic ? ("Built-in readings", .orange)
            : ("gpud \(store.snap?.host?.gpud_version ?? "")", .green)
        return Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .help(basic ? "gpud isn't running on this Mac, so GPU Buddy shows what the App Sandbox can read: GPU load and GPU memory."
                        : store.host.isDemo ? "Made-up data built into the app" : "Live data from gpud")
    }

    private var basicBanner: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle.fill").foregroundStyle(.orange).font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Showing basic readings").font(.headline)
                    Text("Install gpud, GPU Buddy's free open-source service, to add power and energy, which apps use the GPU, LLM token speeds, the Token Ledger and 24 hours of history.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("How to Install") { model.showTutorial = true }
            }
            .padding(4)
        }
    }

    private var demoBanner: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.purple).font(.title3).accessibilityHidden(true)
                Text("The Demo Mac is a pretend Mac Studio running a local LLM. Pair a real Mac to see yours.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Pair a Mac…") { model.showPairing = true }
            }
            .padding(4)
        }
    }

    private func metrics(_ s: Snapshot) -> some View {
        let util = Double(s.gpu.utilization_percent) / 100
        let mem = s.memory.used_percent / 100
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
            MetricCard(title: "GPU Load", value: "\(s.gpu.utilization_percent)%", detail: s.gpu.mood.capitalized,
                       fraction: util, symbol: "gauge.with.dots.needle.67percent", tint: .accentColor)
            MetricCard(title: "GPU Memory", value: bytesText(s.memory.used_bytes),
                       detail: "of \(bytesText(s.memory.total_bytes)) (\(Int(s.memory.used_percent))%)",
                       fraction: mem, symbol: "memorychip", tint: .teal)
            if let w = s.power?.gpu_w, s.power?.available ?? false {
                MetricCard(title: "GPU Power", value: String(format: "%.1f W", w),
                           detail: s.power?.system_w.map { String(format: "%.0f W total", $0) } ?? "",
                           fraction: min(w / max(s.power?.gpu_peak_w ?? 60, 1), 1), symbol: "bolt.fill", tint: .yellow)
            } else {
                MetricCard(title: "GPU Power", value: "—", detail: basic ? "Needs gpud" : "Not available",
                           fraction: nil, symbol: "bolt.slash", tint: .secondary)
            }
            if let t = s.tokens {
                MetricCard(title: "Local AI", value: t.speed_tok_s > 0 ? "\(Int(t.speed_tok_s)) tok/s" : "Idle",
                           detail: "\(shortCount(t.generated_24h)) written · 24 h",
                           fraction: nil, symbol: "brain", tint: .pink)
            } else {
                MetricCard(title: "Local AI", value: "—", detail: basic ? "Needs gpud" : "No LLM server seen",
                           fraction: nil, symbol: "brain", tint: .secondary)
            }
        }
    }

    @ViewBuilder private var chart: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("GPU load").font(.headline)
                    Spacer()
                    Picker("Range", selection: $store.range) {
                        Text("1 hour").tag(3600.0)
                        Text("6 hours").tag(21600.0)
                        Text("24 hours").tag(86400.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    .disabled(basic)
                }
                let pts = store.timeline?.samples ?? []
                if pts.isEmpty {
                    Text(basic ? "Collecting… (without gpud, history starts when GPU Buddy opens)" : "No history yet")
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Chart(pts, id: \.t) { p in
                        AreaMark(x: .value("Time", Date(timeIntervalSince1970: p.t)), y: .value("GPU %", p.util))
                            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.5), .accentColor.opacity(0.05)],
                                                             startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: p.t)), y: .value("GPU %", p.util))
                            .foregroundStyle(Color.accentColor)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel("\(v.as(Int.self) ?? 0)%") } }
                    .frame(height: 180)
                    .accessibilityLabel("GPU load chart")
                }
                if basic {
                    Text("Without gpud the history covers only the time GPU Buddy has been open.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
        .task(id: store.host.id) { await store.fetchTimeline() }
    }

    private func processes(_ s: Snapshot) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Using the GPU").font(.headline)
                ForEach(s.processes.prefix(6)) { p in
                    HStack {
                        Image(systemName: p.is_ai ? "brain" : "macwindow").foregroundStyle(p.is_ai ? .pink : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.label).lineLimit(1)
                            if let e = p.explain { Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", p.gpu_percent)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    if p.id != s.processes.prefix(6).last?.id { Divider() }
                }
            }
            .padding(4)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let fraction: Double?
    let symbol: String
    let tint: Color

    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Text(value).font(.title.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let fraction {
                    Gauge(value: min(max(fraction, 0), 1)) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(4)
        }
        .accessibilityElement(children: .combine)
    }
}

func bytesText(_ b: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}

// MARK: - Pairing

struct PairSheet: View {
    @ObservedObject var fleet: Fleet
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pair a Mac").font(.title2.bold())
            Text("On the Mac you want to watch, install gpud, then copy its pairing code: in GPU Buddy on that Mac open Macs (⌘K) or Settings › This Mac, or run `python3 ~/gpu-buddy/daemon/gpud.py --pairing-code` in Terminal.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let unpaired = fleet.found.filter { !fleet.isPaired($0.id) }
            if !unpaired.isEmpty {
                GroupBox("Found on your network") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(unpaired) { f in
                            HStack {
                                Image(systemName: "desktopcomputer").foregroundStyle(.secondary).accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(f.name)
                                    Text(f.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Use") { address = f.address }
                            }
                        }
                    }
                    .padding(4)
                }
            }

            Form {
                TextField("Address", text: $address, prompt: Text("Studio.local or 10.0.0.5"))
                TextField("Pairing code", text: $code, prompt: Text("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX"))
                    .font(.body.monospaced())
            }
            .formStyle(.columns)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if let mine = fleet.thisMac?.code {
                    Button { copyToClipboard(mine) } label: { Label("Copy This Mac's Code", systemImage: "doc.on.doc") }
                        .help("Paste it on another Mac to let it watch this one")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    busy = true
                    Task {
                        error = await fleet.pair(address: address, code: code)
                        busy = false
                        if error == nil { dismiss() }
                    }
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Pair") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || address.isEmpty || code.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

// MARK: - Getting started

struct TutorialSheet: View {
    @ObservedObject var fleet: Fleet
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var step = min(max(UserDefaults.standard.integer(forKey: "tutorialStep"), 0), 3)  // `-tutorialStep 2` (screenshots)
    @State private var copied = false

    private let steps = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: install
                case 2: pair
                default: demo
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36).padding(.top, 32)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<steps, id: \.self) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Step \(step + 1) of \(steps)")
                Spacer()
                if step == 0 {
                    Button("Skip") { model.finishTutorial() }
                } else {
                    Button("Back") { withAnimation { step -= 1 } }
                }
                Button(step == steps - 1 ? "Start Using GPU Buddy" : "Continue") {
                    if step == steps - 1 { model.finishTutorial() } else { withAnimation { step += 1 } }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
    }

    private func title(_ symbol: String, _ text: String, _ sub: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(text).font(.title.bold()).multilineTextAlignment(.center)
            Text(sub).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().frame(width: 96, height: 96)
                .accessibilityHidden(true)
            title("", "Welcome to GPU Buddy", "See what your Mac's GPU is doing: load, memory, power, local AI token speeds and what that work would cost in the cloud.")
            VStack(alignment: .leading, spacing: 10) {
                bullet("gauge.with.dots.needle.67percent", "Works right away", "GPU load and GPU memory for this Mac, read inside the App Sandbox.")
                bullet("shippingbox", "Fuller with gpud", "A free, open-source background service adds power, apps, tokens and 24-hour history.")
                bullet("desktopcomputer.and.arrow.down", "Watch every Mac", "Pair other Macs and switch between them in the sidebar.")
            }
            .frame(maxWidth: 460)
        }
    }

    private var install: some View {
        VStack(spacing: 18) {
            title("shippingbox", "Install gpud", "Do this once on each Mac you want to see in full. App Store apps can't install background services, so it's one line in Terminal.")
            GroupBox {
                HStack(alignment: .top) {
                    Text(gpudInstallCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        copyToClipboard(gpudInstallCommand)
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                }
                .padding(6)
            }
            VStack(alignment: .leading, spacing: 6) {
                numbered(1, "Open Terminal (Applications › Utilities), paste the line and press Return.")
                numbered(2, "If macOS offers to install the Command Line Developer Tools, click Install, then run the line again.")
                numbered(3, "That's it: gpud starts now and at every login. GPU Buddy switches to it by itself.")
            }
            .frame(maxWidth: 520, alignment: .leading)
            Button("View gpud on GitHub") { openURL(gpudReadme) }.buttonStyle(.link)
        }
    }

    private var pair: some View {
        VStack(spacing: 18) {
            title("link", "Watch Other Macs", "Every Mac running gpud has a pairing code. It lets only you see that Mac, over an encrypted connection.")
            VStack(alignment: .leading, spacing: 6) {
                numbered(1, "On the other Mac, install gpud (previous step), then run:  python3 ~/gpu-buddy/daemon/gpud.py --pairing-code")
                numbered(2, "Here, choose File › Pair a Mac… (⌘N). Macs on your network show up by themselves.")
                numbered(3, "Paste the code and click Pair. The Mac appears in the sidebar.")
                numbered(4, "When macOS asks to let GPU Buddy find devices on your local network, click Allow.")
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
    }

    private var demo: some View {
        VStack(spacing: 18) {
            title("play.circle", "Try the Demo Mac", "No gpud yet? The Demo Mac is a pretend Mac Studio running a local LLM, so you can explore every screen: Overview, Live with Chippy, and the Token Ledger.")
            Button {
                fleet.showDemo()
                model.finishTutorial()
            } label: { Label("Show the Demo Mac", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Text("You can open this guide again from Help › Getting Started with GPU Buddy.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func bullet(_ symbol: String, _ head: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(head).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

// MARK: - Settings

struct AppSettingsView: View {
    @ObservedObject var fleet: Fleet

    var body: some View {
        TabView {
            GeneralSettings(fleet: fleet)
                .tabItem { Label("General", systemImage: "gearshape") }
            CostSettings()
                .tabItem { Label("Energy & Cost", systemImage: "dollarsign.circle") }
            ThisMacSettings(fleet: fleet)
                .tabItem { Label("This Mac", systemImage: "desktopcomputer") }
        }
        .frame(width: 520)
    }
}

struct GeneralSettings: View {
    @ObservedObject var fleet: Fleet
    @Environment(AppModel.self) private var model
    @AppStorage("tempFahrenheit") private var tempFahrenheit = false

    var body: some View {
        Form {
            Picker("Temperature", selection: $tempFahrenheit) {
                Text("Celsius").tag(false)
                Text("Fahrenheit").tag(true)
            }
            Toggle("Show the Demo Mac in the sidebar", isOn: Binding(
                get: { fleet.demo != nil },
                set: { $0 ? fleet.showDemo() : fleet.demo.map { fleet.remove($0.host.id) } }))
            LabeledContent("Getting started") {
                Button("Show Guide") { model.showTutorial = true }
            }
        }
        .formStyle(.grouped)
        .frame(height: 220)
    }
}

struct CostSettings: View {
    @AppStorage("kwhPrice") private var kwhPrice = 0.15
    @AppStorage("cost.cacheHit") private var cacheHit = 0.0
    @AppStorage("cost.thinking") private var thinking = 0.0
    @AppStorage("cost.tokenizer") private var tokenizer = 1.0
    @AppStorage("cost.region") private var region = "all"
    @AppStorage("cost.batch") private var batch = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Electricity price") {
                    HStack {
                        Slider(value: $kwhPrice, in: 0.01...0.50)
                        Text("$\(String(format: "%.2f", kwhPrice))/kWh").monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
            } footer: { Text("Used for the energy cost of local AI in the Token Ledger.").foregroundStyle(.secondary) }
            Section("Cloud price comparison") {
                LabeledContent("Prompt cache hits") {
                    HStack { Slider(value: $cacheHit, in: 0...0.9); Text("\(Int(cacheHit * 100))%").monospacedDigit().frame(width: 50, alignment: .trailing) }
                }
                LabeledContent("Hidden thinking") {
                    HStack { Slider(value: $thinking, in: 0...2); Text("+\(Int(thinking * 100))%").monospacedDigit().frame(width: 50, alignment: .trailing) }
                }
                LabeledContent("Tokenizer") {
                    HStack { Slider(value: $tokenizer, in: 0.8...1.4); Text(String(format: "%.2f×", tokenizer)).monospacedDigit().frame(width: 50, alignment: .trailing) }
                }
                Toggle("Batch API (50% off, results within 24 hours)", isOn: $batch)
                Picker("Models", selection: $region) {
                    Text("All").tag("all")
                    Text("US").tag("us")
                    Text("China").tag("cn")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .frame(height: 400)
    }
}

struct ThisMacSettings: View {
    @ObservedObject var fleet: Fleet
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let local = fleet.stores.first { $0.host.isLocal }
        Form {
            Section("gpud on this Mac") {
                if let local, local.online, !local.client.usingNative {
                    LabeledContent("Status") { Label("Running", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    LabeledContent("Version", value: local.snap?.host?.gpud_version ?? "—")
                    if let code = fleet.thisMac?.code {
                        LabeledContent("Pairing code") {
                            HStack {
                                Text(code).font(.body.monospaced()).textSelection(.enabled)
                                Button { copyToClipboard(code) } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless).help("Copy").accessibilityLabel("Copy pairing code")
                            }
                        }
                    }
                } else {
                    LabeledContent("Status") { Label("Not running", systemImage: "xmark.circle").foregroundStyle(.secondary) }
                    LabeledContent("Install") {
                        HStack {
                            Button("Copy Install Command") { copyToClipboard(gpudInstallCommand) }
                            Button("Show Guide") { model.showTutorial = true }
                        }
                    }
                }
            }
            Section {
                Button("View gpud on GitHub") { openURL(gpudRepo) }.buttonStyle(.link)
                Button("Privacy Policy") { openURL(privacyPolicy) }.buttonStyle(.link)
            } footer: {
                Text("GPU Buddy collects no data. gpud keeps its history on your Mac; paired Macs talk to each other directly over TLS.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }
}
