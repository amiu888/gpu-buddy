// The LLM Router window: who connects, through which entry port, to which local LLM server, drawn as a diagram.
// Click any box to change it in the panel on the right. Talks to this Mac's gpud (/api/v1/llm-proxy).

import AppKit
import SwiftUI

extension Notification.Name {
    static let openRouter = Notification.Name("GPUBuddyOpenRouter")
}

// MARK: - What gpud reports

struct RouterStatus: Decodable {
    struct Route: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let port: Int
        let target: String
        let defaultServer: String?
        let network: Bool
        let state: String?
        let message: String?
        let urls: [String]?
        enum CodingKeys: String, CodingKey { case id, name, port, target, network, state, message, urls; case defaultServer = "default" }
    }
    struct Server: Decodable, Identifiable {
        let id: String
        let host: String
        let port: Int
        let kind: String
        let kind_name: String?
        let icon: String?
        let process: String?
        let pid: Int?
        let models: [String]
        let any_model: Bool?
        let up: Bool
        let network: Bool?
        let manual: Bool?
        let name: String
    }
    struct Key: Decodable, Identifiable {
        let id: String
        let name: String
        let routes: [String]
        let created: Double?
        let last_used: Double?
        let hint: String
        let key: String?
        var allRoutes: Bool { routes == ["*"] }
    }
    struct Client: Decodable, Identifiable {
        let name: String
        let key: Bool
        let who: String?
        let ip: String?
        let local: Bool
        let agent: String?
        let icon: String?
        let count: Int
        let last: Double?
        let route: String?
        let server: String?
        let blocked: Bool?
        var id: String { (key ? "k:" : "d:") + name + (ip ?? "") }
    }
    let enabled: Bool
    let state: String
    let message: String?
    let allow: [String]
    let require_key: Bool?
    let addresses: [String]?
    let routes: [Route]?
    let servers: [Server]?
    let keys: [Key]?
    let clients: [Client]?
}

@MainActor
final class RouterModel: ObservableObject {
    @Published var st: RouterStatus?
    @Published var problem: String?
    @Published var error: String?
    @Published var busy = false
    private let url = URL(string: "http://127.0.0.1:8765/api/v1/llm-proxy")!

    var routes: [RouterStatus.Route] { st?.routes ?? [] }
    var servers: [RouterStatus.Server] { st?.servers ?? [] }
    var keys: [RouterStatus.Key] { st?.keys ?? [] }
    var mainAddress: String { st?.addresses?.first ?? "127.0.0.1" }

    func server(_ id: String?) -> RouterStatus.Server? { servers.first { $0.id == id } }

    func refresh() async {
        guard let (data, resp) = try? await URLSession.shared.data(from: url) else {
            problem = "GPU Buddy's background service isn't running."
            return
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let s = try? JSONDecoder().decode(RouterStatus.self, from: data), s.routes != nil else {
            problem = "The background service is too old for the LLM Router. Reinstall it from the GPU Buddy menu."
            return
        }
        st = s
        problem = nil
    }

    @discardableResult
    func send(_ change: [String: Any]) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: change)
        req.timeoutInterval = 120
        busy = true
        defer { busy = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode != 200 {
                let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                error = (msg ?? "That didn't work.").prefix(1).uppercased() + (msg ?? "That didn't work.").dropFirst()
                return false
            }
        } catch {
            self.error = "The background service didn't answer: \(error.localizedDescription)"
            return false
        }
        error = nil
        await refresh()
        return true
    }

    func payload(_ routes: [RouterStatus.Route]) -> [[String: Any]] {
        routes.map { r in
            var d: [String: Any] = ["id": r.id, "name": r.name, "port": r.port, "target": r.target, "network": r.network]
            if let def = r.defaultServer { d["default"] = def }
            return d
        }
    }

    /// Models a client reaches through an entry port.
    func models(through route: RouterStatus.Route) -> [String] {
        let live = servers.filter { $0.up }
        let reach = route.target == "auto" ? live : live.filter { $0.id == route.target }
        var seen = Set<String>()
        return reach.flatMap { $0.models }.filter { seen.insert($0).inserted }
    }

    func serverLabel(_ s: RouterStatus.Server) -> String { "\(s.icon ?? "🧠") \(s.name)  :\(s.port)" + (s.up ? "" : "  (not running)") }
}

// MARK: - Small pieces

private let label = Font.system(size: 10.5, weight: .semibold, design: .rounded)
private let small = Font.system(size: 10, design: .rounded)
private let mono = Font.system(size: 10.5, design: .monospaced)
private let green = Color(red: 0.36, green: 0.85, blue: 0.5)

private func ago(_ t: Double?) -> String {
    guard let t else { return "never" }
    let s = Date().timeIntervalSince1970 - t
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86400 { return "\(Int(s / 3600)) h ago" }
    return "\(Int(s / 86400)) d ago"
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// A small copy icon, for tight spots like the diagram's boxes.
private struct CopyIcon: View {
    let text: String
    @State private var done = false
    var body: some View {
        Button {
            copy(text)
            done = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); done = false }
        } label: {
            Image(systemName: done ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(done ? green : .white.opacity(0.7))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(done ? "Copied" : "Copy \(text)")
    }
}

private struct CopyButton: View {
    let text: String
    var title = "Copy"
    @State private var done = false
    var body: some View {
        Button(done ? "Copied" : title) {
            copy(text)
            done = true
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); done = false }
        }
        .controlSize(.small)
    }
}

/// Where each box sits, so the lines between them can be drawn.
private struct CardAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct Link: Identifiable {
    let from: String
    let to: String
    var dashed = false
    var color = Color.white.opacity(0.35)
    var text: String? = nil
    var id: String { from + ">" + to }
}

private struct Card<Content: View>: View {
    let id: String
    let selected: Bool
    var tint = Color.white
    var dim = false
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) { content }
                .frame(width: 210, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(selected ? 0.13 : 0.06)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : tint.opacity(0.35), lineWidth: selected ? 2 : 1))
                .opacity(dim ? 0.55 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: CardAnchors.self, value: .bounds) { [id: $0] }
    }
}

private struct ColumnTitle: View {
    let text: String
    let help: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text.uppercased()).font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundColor(.white.opacity(0.6))
            Text(help).font(small).foregroundColor(.white.opacity(0.4))
        }
        .frame(width: 230, alignment: .leading)
    }
}

private struct AddButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle").font(small)
                .frame(width: 210, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(.white.opacity(0.7))
    }
}

// MARK: - The window

enum RouterPick: Hashable {
    case thisMac, allowed, key(String), route(String), server(String), newRoute, newKey, addServer
}

struct RouterView: View {
    @StateObject private var m = RouterModel()
    @State private var pick: RouterPick? = RouterView.startPick()
    @State private var showModels = ProcessInfo.processInfo.environment["GPUBUDDY_MODELS_TAB"] != nil
    private static let startTab = ModelsTab.allCases.first { $0.rawValue == ProcessInfo.processInfo.environment["GPUBUDDY_MODELS_TAB"] } ?? .inUse

    /// For checking layouts: GPUBUDDY_ROUTER_PICK=allowed | thisMac | newRoute | newKey | addServer | route:ID | server:ID
    private static func startPick() -> RouterPick? {
        guard let v = ProcessInfo.processInfo.environment["GPUBUDDY_ROUTER_PICK"] else { return nil }
        switch v {
        case "allowed": return .allowed
        case "thisMac": return .thisMac
        case "newRoute": return .newRoute
        case "newKey": return .newKey
        case "addServer": return .addServer
        default:
            if v.hasPrefix("route:") { return .route(String(v.dropFirst(6))) }
            if v.hasPrefix("server:") { return .server(String(v.dropFirst(7))) }
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            HStack(spacing: 0) {
                GeometryReader { geo in
                    ScrollView([.vertical, .horizontal]) {
                        diagram.padding(20)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                    }
                }
                Divider().opacity(0.3)
                ScrollView {
                    inspector.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 360)
                .background(Color.black.opacity(0.15))
            }
        }
        .foregroundColor(.white)
        .background(Color(red: 0.1, green: 0.09, blue: 0.15))
        .overlay {
            // In the window itself (not a sheet), so the in-app snapshot shows it too.
            if showModels {
                ModelsView(tab: RouterView.startTab, onClose: { showModels = false })
                    .transition(.opacity)
            }
        }
        .task {
            while !Task.isCancelled {
                await m.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Text("LLM Router").font(.system(size: 15, weight: .heavy, design: .rounded))
            if let st = m.st {
                stateBadge(st)
                Spacer()
                if st.enabled {
                    Button("Turn off") { Task { await m.send(["enabled": false]) } }.disabled(m.busy)
                } else {
                    Button("Turn on") { Task { await m.send(["enabled": true]) } }.disabled(m.busy).buttonStyle(.borderedProminent)
                }
                Button("Models…") { showModels = true }
                Button("Request Log") { NotificationCenter.default.post(name: .openRequestLog, object: nil) }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.top, 30).padding(.bottom, 10)
    }

    @ViewBuilder private func stateBadge(_ st: RouterStatus) -> some View {
        let (text, color): (String, Color) = switch st.state {
        case "on": ("● On", green)
        case "starting": ("Starting…", .yellow)
        case "stopping": ("Stopping…", .yellow)
        case "error": ("● Problem", .orange)
        default: ("● Off", .gray)
        }
        Text(text).font(label).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
        if let msg = st.message ?? m.problem {
            Text(msg).font(small).foregroundColor(.orange).lineLimit(2)
        }
    }

    // MARK: diagram

    private var diagram: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = m.problem {
                Text("⚠️ " + p).font(label).foregroundColor(.orange)
            } else if m.st?.enabled == false {
                Text("The router is off: apps talk to LLM servers directly. Turn it on to see who uses them, control access and route by model.")
                    .font(small).foregroundColor(.orange.opacity(0.9)).frame(width: 760, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 70) {
                clientsColumn
                routesColumn
                serversColumn
            }
            legend
        }
        .backgroundPreferenceValue(CardAnchors.self) { anchors in
            GeometryReader { geo in
                ForEach(links) { l in
                    if let a = anchors[l.from], let b = anchors[l.to] {
                        let p0 = CGPoint(x: geo[a].maxX, y: geo[a].midY)
                        let p1 = CGPoint(x: geo[b].minX, y: geo[b].midY)
                        Path { p in
                            p.move(to: p0)
                            p.addCurve(to: p1, control1: CGPoint(x: p0.x + 35, y: p0.y), control2: CGPoint(x: p1.x - 35, y: p1.y))
                        }
                        .stroke(l.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: l.dashed ? [5, 4] : []))
                        Circle().fill(l.color).frame(width: 6, height: 6).position(p1)
                        if let t = l.text {
                            Text(t).font(.system(size: 8.5, weight: .semibold, design: .rounded)).foregroundColor(l.color)
                                .padding(.horizontal, 3).background(Color.black.opacity(0.55).cornerRadius(3))
                                .position(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2 - 7)
                        }
                    }
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            Text("──  always").foregroundColor(.white.opacity(0.5))
            Text("- - -  when the request names one of that server's models").foregroundColor(.white.opacity(0.5))
            Text("Click a box to change it.").foregroundColor(.white.opacity(0.4))
        }
        .font(small).padding(.top, 8)
    }

    private var links: [Link] {
        var out: [Link] = []
        let routes = m.routes
        for r in routes {
            out.append(Link(from: "mac", to: "r:" + r.id))
            if r.network { out.append(Link(from: "allowed", to: "r:" + r.id, dashed: m.st?.require_key == true)) }
            if r.target == "auto" {
                let def = r.defaultServer
                for s in m.servers where s.up || s.id == def {
                    if s.id == def {
                        out.append(Link(from: "r:" + r.id, to: "s:" + s.id, color: s.up ? green.opacity(0.8) : .orange, text: "default"))
                    } else if !s.models.isEmpty {
                        out.append(Link(from: "r:" + r.id, to: "s:" + s.id, dashed: true, color: green.opacity(0.55), text: "by model"))
                    }
                }
            } else {
                let up = m.server(r.target)?.up ?? false
                out.append(Link(from: "r:" + r.id, to: "s:" + r.target, color: up ? green.opacity(0.8) : .orange))
            }
        }
        for k in m.keys {
            for r in routes where k.allRoutes || k.routes.contains(r.id) {
                out.append(Link(from: "k:" + k.id, to: "r:" + r.id, color: Color.yellow.opacity(0.55)))
            }
        }
        return out
    }

    private var clientsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColumnTitle(text: "Who connects", help: "This Mac, devices you allow, and apps with a key")
            Card(id: "mac", selected: pick == .thisMac, action: { pick = .thisMac }) {
                Text("💻  This Mac").font(label)
                Text("Always allowed, no key needed").font(small).foregroundColor(.white.opacity(0.55))
            }
            Card(id: "allowed", selected: pick == .allowed, action: { pick = .allowed }) {
                Text("📱  Allowed devices").font(label)
                let allow = m.st?.allow ?? []
                Text(allow.isEmpty ? "None yet: other devices need a key" : allow.joined(separator: ", "))
                    .font(mono).foregroundColor(.white.opacity(0.6)).lineLimit(2)
                if m.st?.require_key == true {
                    Text("…and they must send a key").font(small).foregroundColor(.yellow.opacity(0.8))
                }
                let blocked = blockedDevices.count
                if blocked > 0 {
                    Text(verbatim: "⛔ \(blocked) device\(blocked == 1 ? "" : "s") turned away today").font(small).foregroundColor(.orange)
                }
            }
            ForEach(m.keys) { k in
                Card(id: "k:" + k.id, selected: pick == .key(k.id), tint: .yellow, action: { pick = .key(k.id) }) {
                    Text("🔑  " + k.name).font(label).lineLimit(1)
                    Text("Used " + ago(k.last_used) + " · " + (k.allRoutes ? "all entry ports" : "\(k.routes.count) entry port\(k.routes.count == 1 ? "" : "s")"))
                        .font(small).foregroundColor(.white.opacity(0.55))
                }
            }
            AddButton(title: "New client key…") { pick = .newKey }
        }
    }

    private var routesColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColumnTitle(text: "Entry ports", help: "Where apps connect: GPU Buddy listens here")
            ForEach(m.routes) { r in
                Card(id: "r:" + r.id, selected: pick == .route(r.id), tint: .accentColor, action: { pick = .route(r.id) }) {
                    HStack {
                        Text(r.name).font(label).lineLimit(1)
                        Spacer()
                        Text(verbatim: ":\(r.port)").font(mono).foregroundColor(.white.opacity(0.8))
                    }
                    Text(r.network ? "🌐 Whole network" : "🔒 This Mac only").font(small).foregroundColor(.white.opacity(0.6))
                    Text(r.target == "auto" ? "🧭 Picks the server by model" : "➜ Always " + (m.server(r.target)?.name ?? r.target))
                        .font(small).foregroundColor(.white.opacity(0.6))
                    if r.state == "error" {
                        Text("⚠️ " + (r.message ?? "Couldn't start")).font(small).foregroundColor(.orange).lineLimit(2)
                    } else if let u = r.urls?.first {
                        Text(u).font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                            .padding(.trailing, 18)  // room for the copy button
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if r.state != "error", let u = r.urls?.first { CopyIcon(text: u).padding(6) }
                }
                .contextMenu {
                    ForEach(r.urls ?? [], id: \.self) { u in Button("Copy \(u)") { copy(u) } }
                }
            }
            AddButton(title: "Add entry port…") { pick = .newRoute }
        }
    }

    private var serversColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColumnTitle(text: "LLM servers", help: "Found on this Mac, every 15 seconds")
            if m.servers.isEmpty {
                Text("Looking…").font(small).foregroundColor(.white.opacity(0.5)).frame(width: 230, alignment: .leading)
            }
            ForEach(m.servers) { s in
                Card(id: "s:" + s.id, selected: pick == .server(s.id), tint: s.up ? green : .gray, dim: !s.up,
                     action: { pick = .server(s.id) }) {
                    HStack {
                        Text("\(s.icon ?? "🧠")  \(s.name)").font(label).lineLimit(1)
                        Spacer()
                        Text(verbatim: ":\(s.port)").font(mono).foregroundColor(.white.opacity(0.8))
                    }
                    HStack(spacing: 6) {
                        Circle().fill(s.up ? green : .gray).frame(width: 6, height: 6)
                        Text(s.up ? (s.any_model == true ? "Running · answers any model name"
                                     : "Running · \(s.models.count) model\(s.models.count == 1 ? "" : "s")") : "Not running")
                            .font(small).foregroundColor(.white.opacity(0.6))
                    }
                    if let first = s.models.first, s.up {
                        Text(shortModel(first) + (s.models.count > 1 ? " +\(s.models.count - 1)" : ""))
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(.white.opacity(0.45)).lineLimit(1)
                    }
                    if s.network == true {
                        Text("⚠️ Also open to the network directly").font(small).foregroundColor(.orange.opacity(0.9))
                    }
                }
            }
            AddButton(title: "Add a server by address…") { pick = .addServer }
        }
    }

    private var blockedDevices: [RouterStatus.Client] {
        let allow = m.st?.allow ?? []
        return (m.st?.clients ?? []).filter { c in
            c.blocked == true && !c.key && !c.local && !allow.contains(c.ip ?? "") && !allow.contains("*")
        }
    }

    // MARK: inspector

    @ViewBuilder private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let e = m.error {
                HStack(alignment: .top) {
                    Text("⚠️ " + e).font(small).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("OK") { m.error = nil }.controlSize(.small)
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            switch pick {
            case .none: Intro(m: m)
            case .thisMac: ThisMacPanel(m: m)
            case .allowed: AllowedPanel(m: m, blocked: blockedDevices)
            case .key(let id):
                if let k = m.keys.first(where: { $0.id == id }) { KeyPanel(m: m, key: k, onDelete: { pick = nil }) } else { Intro(m: m) }
            case .newKey: NewKeyPanel(m: m) { newID in pick = newID.map { .key($0) } }
            case .route(let id):
                if let r = m.routes.first(where: { $0.id == id }) {
                    RoutePanel(m: m, original: r, onDone: { pick = $0.map { .route($0) } }).id(r.id)
                } else { Intro(m: m) }
            case .newRoute: RoutePanel(m: m, original: nil, onDone: { pick = $0.map { .route($0) } })
            case .server(let id):
                if let s = m.servers.first(where: { $0.id == id }) { ServerPanel(m: m, s: s, onRemove: { pick = nil }).id(s.id) } else { Intro(m: m) }
            case .addServer: AddServerPanel(m: m) { pick = nil }
            }
        }
    }
}

private func shortModel(_ m: String) -> String {
    let parts = m.split(separator: "/").map(String.init)
    guard let last = parts.last else { return m }
    return last == "model" && parts.count > 1 ? parts[parts.count - 2] : last
}

private struct PanelTitle: View {
    let icon: String
    let title: String
    var body: some View {
        Text("\(icon)  \(title)").font(.system(size: 14, weight: .heavy, design: .rounded))
    }
}

private struct Note: View {
    let text: String
    var body: some View {
        Text(text).font(small).foregroundColor(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
    }
}

private struct Intro: View {
    @ObservedObject var m: RouterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: "🧭", title: "How it works")
            Note(text: "Apps connect to an entry port. GPU Buddy checks they're allowed, notes who asked what, and passes each request to an LLM server on this Mac.")
            Note(text: "An entry port either always uses one server, or picks the server that has the model the request names (Ollama's “qwen3:30b”, Kapitsa's model, …). If no server has it, its default server answers.")
            Note(text: "Other devices get in when they're on the allow list, or with a client key you make for them. Keys can be limited to some entry ports, and you can see when each was last used.")
            Note(text: "Click any box on the left to change it.")
        }
    }
}

private struct ThisMacPanel: View {
    @ObservedObject var m: RouterModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: "💻", title: "This Mac")
            Note(text: "Apps on this Mac can use every entry port without a key. Any API key they send (like “mlx-local”) is fine.")
            ForEach(m.routes) { r in
                HStack {
                    Text(verbatim: "http://127.0.0.1:\(r.port)/v1").font(mono).textSelection(.enabled)
                    Spacer()
                    CopyButton(text: "http://127.0.0.1:\(r.port)/v1")
                }
            }
            let local = (m.st?.clients ?? []).filter { $0.local }
            if !local.isEmpty {
                Text("Used today").font(label).padding(.top, 4)
                ForEach(local) { c in
                    Text("\(c.icon ?? "•") \(c.name) · \(c.who ?? "") · \(c.count)× · \(ago(c.last))").font(small).foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }
}

private struct AllowedPanel: View {
    @ObservedObject var m: RouterModel
    let blocked: [RouterStatus.Client]
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: "📱", title: "Allowed devices")
            Note(text: "Devices on your network that may use the “whole network” entry ports. Separate with commas. 10.0.2.0/24 allows a whole network, * allows everyone.")
            HStack {
                TextField("e.g. 10.0.2.126", text: $text).textFieldStyle(.roundedBorder).font(mono)
                    .onSubmit(save)
                Button("Save", action: save).disabled(text == (m.st?.allow ?? []).joined(separator: ", "))
            }
            Toggle("Every other device also needs a client key", isOn: Binding(
                get: { m.st?.require_key ?? false },
                set: { v in Task { await m.send(["require_key": v]) } }))
                .toggleStyle(.checkbox).font(small)
            Note(text: "With this on, being on the list isn't enough: devices must send one of your client keys too. Apps with a key get in from any address.")
            if !blocked.isEmpty {
                Text("Turned away today").font(label).padding(.top, 4)
                ForEach(blocked) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("⛔ \(c.who ?? c.ip ?? "?")").font(small)
                            Text("\(c.agent ?? "") · \(c.count)× · \(ago(c.last))").font(small).foregroundColor(.white.opacity(0.5))
                        }
                        Spacer()
                        if let ip = c.ip, !(m.st?.allow ?? []).contains(ip) {
                            Button("Allow") {
                                Task { await m.send(["allow": (m.st?.allow ?? []) + [ip]]); text = ((m.st?.allow ?? [])).joined(separator: ", ") }
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .onAppear { if !loaded { text = (m.st?.allow ?? []).joined(separator: ", "); loaded = true } }
    }

    private func save() {
        let list = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
        Task { if await m.send(["allow": list]) { text = (m.st?.allow ?? []).joined(separator: ", ") } }
    }
}

private struct RoutePicker: View {
    @ObservedObject var m: RouterModel
    @Binding var ports: Set<String>
    @Binding var all: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("All entry ports, now and later", isOn: $all).toggleStyle(.checkbox).font(small)
            if !all {
                ForEach(m.routes) { r in
                    Toggle(String("\(r.name)  :\(r.port)"), isOn: Binding(
                        get: { ports.contains(r.id) },
                        set: { on in if on { ports.insert(r.id) } else { ports.remove(r.id) } }))
                        .toggleStyle(.checkbox).font(small).padding(.leading, 16)
                }
            }
        }
    }
}

private struct KeyPanel: View {
    @ObservedObject var m: RouterModel
    let key: RouterStatus.Key
    let onDelete: () -> Void
    @State private var name = ""
    @State private var all = true
    @State private var ports = Set<String>()
    @State private var show = false
    @State private var model = ""
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: "🔑", title: key.name)
            Note(text: "Made \(ago(key.created)) · last used \(ago(key.last_used))")

            HStack {
                Text(show ? (key.key ?? key.hint) : key.hint).font(mono).textSelection(.enabled).lineLimit(1)
                Spacer()
                Button(show ? "Hide" : "Show") { show.toggle() }.controlSize(.small)
                if let k = key.key { CopyButton(text: k) }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))

            setup

            Text("Can use").font(label).padding(.top, 4)
            RoutePicker(m: m, ports: $ports, all: $all)
            Button("Save") {
                Task { await m.send(["key_routes": ["id": key.id, "routes": all ? ["*"] : Array(ports)]]) }
            }
            .disabled(all ? key.allRoutes : (Set(key.routes) == ports && !key.allRoutes) || ports.isEmpty)

            Text("Name").font(label).padding(.top, 4)
            HStack {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                Button("Rename") { Task { await m.send(["rename_key": ["id": key.id, "name": name]]) } }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == key.name)
            }

            Button(role: .destructive) { confirm = true } label: { Text("Delete this key…") }
                .padding(.top, 6)
                .confirmationDialog("Delete “\(key.name)”?", isPresented: $confirm) {
                    Button("Delete key", role: .destructive) {
                        Task { if await m.send(["remove_key": key.id]) { onDelete() } }
                    }
                } message: { Text("Apps using it will be turned away, unless their device is on the allow list.") }
        }
        .onAppear {
            name = key.name
            all = key.allRoutes
            ports = Set(key.allRoutes ? [] : key.routes)
        }
    }

    /// Ready-to-paste settings for the app that gets this key.
    @ViewBuilder private var setup: some View {
        let routes = m.routes.filter { key.allRoutes || key.routes.contains($0.id) }
        if let r = routes.first(where: { $0.network }) ?? routes.first {
            let base = "http://\(r.network ? m.mainAddress : "127.0.0.1"):\(r.port)/v1"
            let models = m.models(through: r)
            let chosen = models.contains(model) ? model : (models.first ?? "")
            let block = "Base URL: \(base)\nAPI key:  \(key.key ?? "")\nModel:    \(chosen)"
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up the app").font(label)
                Note(text: "In Cline, Continue, Open WebUI…: choose “OpenAI Compatible”, then:")
                Text(block).font(mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if models.count > 1 {
                    Picker("Model", selection: Binding(get: { chosen }, set: { model = $0 })) {
                        ForEach(models, id: \.self) { Text(shortModel($0)).tag($0) }
                    }
                    .font(small)
                }
                HStack {
                    CopyButton(text: block, title: "Copy all")
                    CopyButton(text: base, title: "Copy URL")
                }
                if routes.count > 1 {
                    Note(text: "Also works on: " + routes.dropFirst().map { "\($0.name) :\($0.port)" }.joined(separator: ", "))
                }
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
        }
    }
}

private struct NewKeyPanel: View {
    @ObservedObject var m: RouterModel
    let onCreated: (String?) -> Void
    @State private var name = ""
    @State private var all = true
    @State private var ports = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: "🔑", title: "New client key")
            Note(text: "Make one key per app or device, so you can see who's using the LLM and turn one away without touching the others.")
            Text("Who gets it").font(label)
            TextField("e.g. Cline on MacBook", text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            Text("Can use").font(label)
            RoutePicker(m: m, ports: $ports, all: $all)
            Button("Make key", action: create).buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (!all && ports.isEmpty))
        }
    }

    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        Task {
            if await m.send(["new_key": ["name": n, "routes": all ? ["*"] : Array(ports)]]) {
                onCreated(m.keys.first(where: { $0.name == n })?.id)
            }
        }
    }
}

private struct RoutePanel: View {
    @ObservedObject var m: RouterModel
    let original: RouterStatus.Route?
    let onDone: (String?) -> Void
    @State private var name = ""
    @State private var port = ""
    @State private var network = true
    @State private var target = "auto"
    @State private var fallback = ""
    @State private var confirm = false
    @State private var moreAddresses = false

    /// Model names apps can pick through this port (follows the unsaved choice of server).
    @ViewBuilder private var modelList: some View {
        let live = m.servers.filter { $0.up }
        let reach = target == "auto" ? live : live.filter { $0.id == target }
        let models: [String] = { var seen = Set<String>(); return reach.flatMap { $0.models }.filter { seen.insert($0).inserted } }()
        Text("Models apps can use (\(models.count))").font(label)
        if models.isEmpty {
            let s = m.servers.first { $0.id == target }
            Note(text: s == nil || target == "auto"
                 ? "No running server has any models."
                 : (s!.up ? "\(s!.name) has no models, so apps see an empty list. "
                           + (s!.kind == "ollama" ? "Download one in Terminal (e.g. ollama pull qwen3:8b), " : "Load one in it, ")
                           + "or send this port to another server below."
                          : "\(s!.name) isn't running, so there are no models to show."))
                .foregroundColor(.orange)
        } else {
            Note(text: "Type one of these as the model name in your app (Cline: Model ID).")
            ForEach(models.prefix(40), id: \.self) { mdl in
                HStack {
                    Text(mdl).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    CopyButton(text: mdl)
                }
            }
        }
    }

    private func addressRow(_ u: String) -> some View {
        HStack {
            Text(u).font(mono).textSelection(.enabled).lineLimit(1)
            Spacer()
            CopyButton(text: u)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: "🚪", title: original == nil ? "New entry port" : original!.name)
            Note(text: "Apps connect here. Point each app at the address below, then choose which LLM server answers.")

            Text("Name").font(label)
            TextField("e.g. Ollama for the family", text: $name).textFieldStyle(.roundedBorder)

            Text("Port").font(label)
            HStack {
                TextField("8090", text: $port).textFieldStyle(.roundedBorder).font(mono).frame(width: 90)
            }
            Note(text: "Any free number from 1024 to 65535. LLM servers' own ports and 8765 are taken.")

            if let p = Int(port), (1024...65535).contains(p) {
                Text("Addresses for your apps").font(label)
                let all = urls(p)
                let main = all.count > 2 ? [all[0], all[all.count - 1]] : all
                ForEach(main, id: \.self) { u in addressRow(u) }
                if all.count > 2 {
                    DisclosureGroup(isExpanded: $moreAddresses) {
                        ForEach(Array(all[1..<(all.count - 1)]), id: \.self) { u in addressRow(u) }
                    } label: {
                        Text("More addresses (\(all.count - 2))").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                    }
                }
                Note(text: (network ? "Other devices use the first one; " : "") + "apps on this Mac can use 127.0.0.1."
                     + (original == nil || changed ? " Save first: these start working after you save." : ""))
            }

            modelList

            Text("Who can reach it").font(label)
            Picker("", selection: $network) {
                Text("🌐 Whole network").tag(true)
                Text("🔒 This Mac only").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()

            Text("Sends requests to").font(label)
            Picker("", selection: $target) {
                Text("🧭 The server that has the model (recommended)").tag("auto")
                Divider()
                ForEach(m.servers) { s in Text("➜ " + m.serverLabel(s)).tag(s.id) }
            }
            .labelsHidden()
            if target == "auto" {
                Text("If no server has the model").font(label)
                Picker("", selection: $fallback) {
                    ForEach(m.servers) { s in Text(m.serverLabel(s)).tag(s.id) }
                }
                .labelsHidden()
                Note(text: "Kapitsa answers any model name, so it makes a good default. Apps can list every model with GET /v1/models on this port.")
            } else if let s = m.server(target), !s.models.isEmpty {
                Note(text: "Models: " + s.models.prefix(6).map(shortModel).joined(separator: ", ") + (s.models.count > 6 ? "…" : ""))
            }

            HStack {
                Button(original == nil ? "Add entry port" : "Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(!valid || m.busy)
                if original != nil {
                    Button("Cancel") { load() }.disabled(!changed)
                }
            }
            .padding(.top, 4)

            if let o = original, m.routes.count > 1 {
                Button(role: .destructive) { confirm = true } label: { Text("Remove this entry port…") }
                    .padding(.top, 8)
                    .confirmationDialog(String("Remove “\(o.name)” (port \(o.port))?"), isPresented: $confirm) {
                        Button("Remove", role: .destructive) {
                            Task { if await m.send(["routes": m.payload(m.routes.filter { $0.id != o.id })]) { onDone(nil) } }
                        }
                    } message: { Text(verbatim: "Apps using port \(o.port) will stop reaching the LLM.") }
            }
            if let o = original, o.id == m.routes.first?.id, o.port == 8080 {
                Note(text: "This is the entry port your apps used before the router (8080). The LLM server that used to listen there now runs behind it.")
            }
        }
        .onAppear(perform: load)
    }

    /// Where apps reach this entry port: this Mac's network addresses (when it's open to the network), then 127.0.0.1.
    private func urls(_ p: Int) -> [String] {
        let hosts = (network ? (m.st?.addresses ?? []) : []) + ["127.0.0.1"]
        return hosts.map { "http://\($0):\(p)/v1" }
    }

    private var valid: Bool {
        guard let p = Int(port), (1024...65535).contains(p) else { return false }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && (target != "auto" || !fallback.isEmpty)
    }

    private var changed: Bool {
        guard let o = original else { return true }
        return name != o.name || port != String(o.port) || network != o.network || target != o.target
            || (target == "auto" && fallback != (o.defaultServer ?? ""))
    }

    private func load() {
        if let o = original {
            name = o.name; port = String(o.port); network = o.network; target = o.target
            fallback = o.defaultServer ?? (m.servers.first { $0.up }?.id ?? "")
        } else {
            let used = Set(m.routes.map(\.port)).union(m.servers.map(\.port))
            let free = (8090...8199).first { !used.contains($0) } ?? 8090
            name = ""; port = String(free); network = true; target = "auto"
            fallback = m.servers.first(where: { $0.up && $0.any_model == true })?.id ?? m.servers.first(where: { $0.up })?.id ?? ""
        }
    }

    private func save() {
        guard let p = Int(port) else { return }
        let id = original?.id ?? "r" + String(Int.random(in: 1000...99999))
        var d: [String: Any] = ["id": id, "name": name.trimmingCharacters(in: .whitespaces), "port": p, "target": target, "network": network]
        if target == "auto" { d["default"] = fallback }
        var list = m.payload(m.routes)
        if let i = list.firstIndex(where: { ($0["id"] as? String) == original?.id }) { list[i] = d } else { list.append(d) }
        Task { if await m.send(["routes": list]) { onDone(id) } }
    }
}

private struct ServerPanel: View {
    @ObservedObject var m: RouterModel
    let s: RouterStatus.Server
    let onRemove: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: s.icon ?? "🧠", title: s.name)
            HStack(spacing: 6) {
                Circle().fill(s.up ? green : .gray).frame(width: 7, height: 7)
                Text(s.up ? "Running" : "Not answering right now").font(small)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow { Text("Software").font(label); Text(s.kind_name ?? s.kind).font(small) }
                GridRow {
                    Text("Address").font(label)
                    HStack {
                        Text(verbatim: "http://\(s.host):\(s.port)/v1").font(mono).textSelection(.enabled)
                        CopyIcon(text: "http://\(s.host):\(s.port)/v1")
                    }
                }
                if let p = s.process { GridRow { Text("Program").font(label); Text(p + (s.pid.map { "  (pid \($0))" } ?? "")).font(small) } }
            }
            if s.network == true {
                Note(text: "⚠️ This server also listens on the network itself, so devices can reach it without GPU Buddy (no allow list, no log). Start it for this Mac only (host 127.0.0.1) to make GPU Buddy the only way in.")
                    .foregroundColor(.orange)
            }
            if s.any_model == true {
                Note(text: "Kapitsa runs one model and answers whatever model name a request uses.")
            }

            Text("Models (\(s.models.count))").font(label).padding(.top, 4)
            if s.models.isEmpty {
                Note(text: s.up ? "None loaded or downloaded." : "Unknown while it's not running.")
            }
            ForEach(s.models.prefix(40), id: \.self) { mdl in
                HStack {
                    Text(mdl).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    CopyButton(text: mdl)
                }
            }

            Text("Name in GPU Buddy").font(label).padding(.top, 4)
            HStack {
                TextField(s.kind_name ?? "Name", text: $name).textFieldStyle(.roundedBorder)
                Button("Rename") { Task { await m.send(["server_name": ["id": s.id, "name": name]]) } }
                    .disabled(name == s.name)
            }
            if s.manual == true {
                Button(role: .destructive) {
                    Task { if await m.send(["remove_server": s.id]) { onRemove() } }
                } label: { Text("Forget this server") }
            }
        }
        .onAppear { name = s.name }
    }
}

private struct AddServerPanel: View {
    @ObservedObject var m: RouterModel
    let onDone: () -> Void
    @State private var host = "127.0.0.1"
    @State private var port = ""
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(icon: "➕", title: "Add a server")
            Note(text: "GPU Buddy finds most servers by itself (Kapitsa, Ollama, LM Studio, llama.cpp, MLX, vLLM…). Add one here if it's missing, or if it runs on another computer. It must answer the OpenAI API (GET /v1/models).")
            Text("Address").font(label)
            HStack {
                TextField("127.0.0.1", text: $host).textFieldStyle(.roundedBorder).font(mono)
                Text(":")
                TextField("8000", text: $port).textFieldStyle(.roundedBorder).font(mono).frame(width: 80)
            }
            Text("Name (optional)").font(label)
            TextField("e.g. NAS Ollama", text: $name).textFieldStyle(.roundedBorder)
            Button("Add") {
                Task { if await m.send(["add_server": ["host": host, "port": Int(port) ?? 0, "name": name]]) { onDone() } }
            }
            .buttonStyle(.borderedProminent).disabled(Int(port) == nil || host.isEmpty)
        }
    }
}

// MARK: - Models: what's on this Mac, on the NAS and on ollama.com, and which ones clients use

struct ModelsStatus: Decodable {
    struct Installed: Decodable, Identifiable {
        let name: String
        let server: String
        let size: Int64
        let cloud: Bool
        let params: String?
        let quant: String?
        let loaded: Bool?
        var id: String { server + "/" + name }
    }
    struct Nas: Decodable, Identifiable {
        let name: String
        let size: Int64
        let cloud: Bool
        let on_mac: Bool?
        var id: String { name }
    }
    struct Lib: Decodable, Identifiable {
        let name: String
        let desc: String
        let sizes: [String]
        let caps: [String]
        let pulls: String
        var id: String { name }
    }
    struct Job: Decodable {
        let state: String
        let source: String
        let done: Int64
        let total: Int64
        let error: String?
        let step: String?
    }
    struct Usage: Decodable, Identifiable {
        struct C: Decodable { let name: String; let requests: Int }
        let server: String
        let model: String
        let requests: Int
        let errors: Int
        let clients: [C]
        let last: Double
        let out_tokens: Int
        let now: Int
        let now_tps: Double?
        let tps: Double?
        let tps_last: Double?
        var id: String { server + "/" + model }
    }
    let ollama_running: Bool
    let installed: [Installed]
    let nas: [Nas]
    let nas_path: String?
    let nas_error: String?
    let nas_looked: [String]?
    let library: [Lib]
    let library_time: Double?
    let library_loading: Bool
    let library_error: String?
    let jobs: [String: Job]
    let free: Int64
    let keep_free: Int64
    let usage: [Usage]?
}

@MainActor
final class ModelsModel: ObservableObject {
    @Published var st: ModelsStatus?
    @Published var problem: String?
    private let url = URL(string: "http://127.0.0.1:8765/api/v1/llm-proxy/models")!

    func refresh(library: Bool = false) async {
        let u = library ? URL(string: url.absoluteString + "?refresh=1")! : url
        guard let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            problem = "GPU Buddy's background service didn't answer. Reinstall it from the GPU Buddy menu if this stays."
            return
        }
        do {
            st = try JSONDecoder().decode(ModelsStatus.self, from: data)
            problem = nil
        } catch {
            problem = "Couldn't read the model list: \(error.localizedDescription)"
        }
    }

    func send(_ change: [String: Any]) async {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: change)
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode != 200 {
            problem = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        }
        await refresh()
    }

    var installedNames: Set<String> { Set((st?.installed ?? []).filter { $0.server == "Ollama" }.map { $0.name }) }
    func job(_ name: String) -> ModelsStatus.Job? {
        st?.jobs[name] ?? st?.jobs[name.contains(":") ? name : name + ":latest"]
    }
}

private func gb(_ b: Int64) -> String {
    let g = Double(b) / 1e9
    return g >= 10 ? String(format: "%.0f GB", g) : g >= 0.1 ? String(format: "%.1f GB", g) : String(format: "%.0f MB", Double(b) / 1e6)
}

private func tps(_ v: Double?) -> String { v.map { String(format: $0 >= 100 ? "%.0f tok/s" : "%.1f tok/s", $0) } ?? "–" }

private func serverIcon(_ s: String) -> String {
    switch s.lowercased() { case "ollama": return "🦙"; case "kapitsa": return "⚡"; default: return "🧠" }
}

private struct Chip: View {
    let text: String
    var color: Color = .white
    var body: some View {
        Text(text).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

enum ModelsTab: String, CaseIterable, Identifiable {
    case inUse = "In use", mac = "On this Mac", nas = "On the NAS", library = "ollama.com"
    var id: String { rawValue }
}

struct ModelsView: View {
    @StateObject private var m = ModelsModel()
    @State var tab: ModelsTab
    @State private var search = ""
    @State private var ask: (name: String, from: String, note: String)?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Models").font(.system(size: 15, weight: .heavy, design: .rounded))
                Picker("", selection: $tab) { ForEach(ModelsTab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 420)
                Spacer()
                if tab != .inUse {
                    TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
                }
                if let onClose { Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
            }
            .padding(16)
            Divider().opacity(0.3)
            if let p = m.problem { Text("⚠️ " + p).font(small).foregroundColor(.orange).padding(.horizontal, 16).padding(.top, 8) }
            jobsBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    switch tab {
                    case .inUse: inUse
                    case .mac: onMac
                    case .nas: onNas
                    case .library: library
                    }
                }
                .padding(16)
            }
        }
        .foregroundColor(.white)
        .background(Color(red: 0.1, green: 0.09, blue: 0.15))
        .task {
            while !Task.isCancelled {
                await m.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .alert(ask?.name ?? "", isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })) {
            Button(ask?.from == "nas" ? "Copy to this Mac" : "Download") {
                if let a = ask { Task { await m.send(["pull": a.name, "from": a.from]) } }
                ask = nil
            }
            Button("Cancel", role: .cancel) { ask = nil }
        } message: { Text(ask?.note ?? "") }
    }

    private func matches(_ s: String) -> Bool { search.isEmpty || s.localizedCaseInsensitiveContains(search) }

    // Downloads running (or just finished/failed), on every tab.
    @ViewBuilder private var jobsBar: some View {
        let jobs = (m.st?.jobs ?? [:]).sorted { $0.key < $1.key }
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(jobs, id: \.key) { name, j in
                    HStack(spacing: 10) {
                        Text(name).font(mono).frame(width: 220, alignment: .leading).lineLimit(1)
                        if j.state == "running" {
                            if j.total > 0 { ProgressView(value: Double(j.done), total: Double(max(j.total, 1))).frame(width: 200) }
                            else { ProgressView().controlSize(.small) }
                            Text((j.step ?? "") + (j.total > 0 ? "  \(gb(j.done)) of \(gb(j.total))" : "")).font(small)
                            Spacer()
                            Button("Stop") { Task { await m.send(["cancel": name]) } }
                        } else {
                            Text(j.state == "done" ? "✓ Ready to use" : j.state == "cancelled" ? "Stopped" : "⚠️ " + (j.error ?? "Failed"))
                                .font(small).foregroundColor(j.state == "done" ? green : .orange).lineLimit(2)
                            Spacer()
                        }
                    }
                }
                if jobs.allSatisfy({ $0.value.state != "running" }) {
                    Button("Clear") { Task { await m.send(["clear": true]) } }.font(small)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    // MARK: In use

    @ViewBuilder private var inUse: some View {
        let rows = m.st?.usage ?? []
        Note(text: "Models your apps asked for through GPU Buddy's entry ports: who uses them, how often (last 24 hours) and how fast they write. Speed counts only the writing, after the first word.")
        if rows.isEmpty {
            Note(text: "Nothing yet. Requests show up here once apps use an entry port (the router has to be on).").padding(.top, 8)
        }
        ForEach(rows) { r in
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.model).font(mono).lineLimit(1).truncationMode(.middle)
                        CopyIcon(text: r.model)
                        if r.now > 0 { Chip(text: "● writing now", color: green) }
                        if r.errors > 0 && r.errors == r.requests { Chip(text: "not working", color: .orange) }
                    }
                    Text("\(serverIcon(r.server)) \(r.server)  ·  " + r.clients.map { $0.name }.joined(separator: ", "))
                        .font(small).foregroundColor(.white.opacity(0.6)).lineLimit(2)
                    if r.errors > 0 && r.errors == r.requests {
                        Note(text: "Every request failed: the server doesn't have a model with this name. Use a name from “On this Mac”.")
                            .foregroundColor(.orange)
                    }
                }
                Spacer()
                stat(r.now > 0 && r.now_tps != nil ? tps(r.now_tps) : tps(r.tps), r.now > 0 && r.now_tps != nil ? "right now" : "typical")
                stat(tps(r.tps_last), "last request")
                stat("\(r.requests)" + (r.errors > 0 ? " (\(r.errors) failed)" : ""), "requests")
                stat(r.now > 0 ? "now" : ago(r.last), "last used")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        }
    }

    private func stat(_ v: String, _ k: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(v).font(.system(size: 12, weight: .bold, design: .rounded)).lineLimit(1)
            Text(k).font(.system(size: 9)).foregroundColor(.white.opacity(0.5))
        }
        .frame(width: 92, alignment: .trailing)
    }

    // MARK: On this Mac

    @ViewBuilder private var onMac: some View {
        let rows = (m.st?.installed ?? []).filter { matches($0.name) }
        Note(text: "Downloaded and ready: put the name in your app as the model. Cloud models are listed by Ollama but run on ollama.com, not on this Mac."
             + (m.st?.ollama_running == false ? "  ⚠️ Ollama isn't running, so its models aren't listed." : ""))
        if let s = m.st { Note(text: "\(gb(s.free)) free on this Mac.") }
        ForEach(rows) { r in
            HStack(spacing: 8) {
                Text(serverIcon(r.server)).frame(width: 18)
                Text(r.name).font(mono).lineLimit(1).truncationMode(.middle)
                if r.cloud { Chip(text: "cloud", color: .cyan) } else { Chip(text: "on this Mac", color: green) }
                if r.loaded == true { Chip(text: "in memory", color: .yellow) }
                if let p = r.params, !p.isEmpty { Chip(text: p + ((r.quant ?? "").isEmpty ? "" : " · " + r.quant!)) }
                Spacer()
                Text(r.cloud ? "–" : gb(r.size)).font(small).foregroundColor(.white.opacity(0.6)).frame(width: 60, alignment: .trailing)
                Text(r.server).font(small).foregroundColor(.white.opacity(0.5)).frame(width: 60, alignment: .leading)
                CopyButton(text: r.name)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        }
        if rows.contains(where: { $0.server == "Kapitsa" }) {
            Note(text: "Kapitsa runs one model at a time and answers any model name.").padding(.top, 4)
        }
    }

    // MARK: NAS

    @ViewBuilder private var onNas: some View {
        let rows = (m.st?.nas ?? []).filter { matches($0.name) }
        if let e = m.st?.nas_error {
            Note(text: "⚠️ " + e).foregroundColor(.orange)
        } else if m.st?.nas_path == nil {
            Note(text: "No NAS model folder found (looked in " + (m.st?.nas_looked ?? []).joined(separator: ", ")
                 + "). Connect to the NAS in Finder, or set GPUBUDDY_NAS_MODELS for gpud to your Ollama models folder on it.")
        } else {
            Note(text: "Ollama models stored on the NAS (\(m.st?.nas_path ?? "")). Copy one to this Mac to use it: it loads in seconds from the SSD instead of minutes over the network.")
        }
        ForEach(rows) { r in
            HStack(spacing: 8) {
                Text("🗄️").frame(width: 18)
                Text(r.name).font(mono).lineLimit(1)
                if r.cloud { Chip(text: "cloud", color: .cyan) }
                Spacer()
                Text(r.cloud ? "–" : gb(r.size)).font(small).foregroundColor(.white.opacity(0.6)).frame(width: 60, alignment: .trailing)
                nasAction(r).frame(width: 150, alignment: .trailing)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        }
    }

    @ViewBuilder private func nasAction(_ r: ModelsStatus.Nas) -> some View {
        if r.on_mac == true {
            HStack(spacing: 6) { Chip(text: "✓ on this Mac", color: green); CopyIcon(text: r.name) }
        } else if let j = m.job(r.name), j.state == "running" {
            Text(j.total > 0 ? "\(Int(Double(j.done) / Double(max(j.total, 1)) * 100))%" : "…").font(small)
        } else if r.cloud {
            Text("runs on ollama.com").font(small).foregroundColor(.white.opacity(0.5))
        } else {
            let room = (m.st?.free ?? 0) - (m.st?.keep_free ?? 0) > r.size
            Button("Copy to this Mac") {
                ask = (r.name, "nas", "Copies \(gb(r.size)) from the NAS into Ollama on this Mac. Then any app can use it as “\(r.name)”.")
            }
            .disabled(!room)
            .help(room ? "" : "Not enough free space (GPU Buddy keeps 20 GB free).")
        }
    }

    // MARK: ollama.com

    @ViewBuilder private var library: some View {
        let rows = (m.st?.library ?? []).filter { matches($0.name) || matches($0.desc) }
        HStack {
            Note(text: "Every model in Ollama's library, most popular first. Click a size to download it into Ollama on this Mac. ✓ = already downloaded."
                 + (m.st?.library_time.map { "  Updated \(ago($0))." } ?? ""))
            Spacer()
            if m.st?.library_loading == true { ProgressView().controlSize(.small) }
            Button("Refresh") { Task { await m.refresh(library: true) } }.font(small)
        }
        if let e = m.st?.library_error { Note(text: "⚠️ " + e).foregroundColor(.orange) }
        ForEach(rows) { r in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(r.name).font(.system(size: 12, weight: .bold, design: .monospaced))
                    ForEach(r.caps, id: \.self) { Chip(text: $0, color: $0 == "cloud" ? .cyan : .purple) }
                    Spacer()
                    if !r.pulls.isEmpty { Text("\(r.pulls) downloads").font(.system(size: 9)).foregroundColor(.white.opacity(0.45)) }
                }
                if !r.desc.isEmpty { Text(r.desc).font(small).foregroundColor(.white.opacity(0.6)).lineLimit(2) }
                HStack(spacing: 5) {
                    ForEach(r.sizes.isEmpty ? ["latest"] : r.sizes, id: \.self) { s in sizeButton(r.name, s) }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)))
        }
    }

    @ViewBuilder private func sizeButton(_ model: String, _ size: String) -> some View {
        let name = model + ":" + size
        let have = m.installedNames.contains(name)
        if have {
            Button { copy(name) } label: { Text("✓ " + size).font(.system(size: 10, weight: .semibold, design: .monospaced)) }
                .buttonStyle(.plain).foregroundColor(green)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(green.opacity(0.15)))
                .help("Downloaded. Click to copy “\(name)”.")
        } else if let j = m.job(name), j.state == "running" {
            Text("↓ \(size) \(j.total > 0 ? "\(Int(Double(j.done) / Double(max(j.total, 1)) * 100))%" : "…")")
                .font(.system(size: 10, design: .monospaced)).padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.25)))
        } else {
            Button {
                let est = estimate(size)
                ask = (name, "ollama", "Ollama downloads it from ollama.com" + (est.map { " (about \($0))" } ?? "")
                       + ". Then any app can use it as “\(name)”. Big models need lots of memory to run: this Mac has \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB.")
            } label: { Text(size).font(.system(size: 10, design: .monospaced)) }
                .buttonStyle(.plain)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .help("Download \(name)")
        }
    }

    /// Rough download size for a 4-bit model of this many parameters.
    private func estimate(_ size: String) -> String? {
        let s = size.lowercased()
        var n: Double?
        if s.hasSuffix("b") { n = Double(s.dropFirst(s.hasPrefix("e") ? 1 : 0).dropLast().split(separator: "x").map { Double($0) ?? 0 }.reduce(1, *)) }
        if s.hasSuffix("m") { n = (Double(s.dropLast()) ?? 0) / 1000 }
        guard let n, n > 0 else { return nil }
        return gb(Int64(n * 0.62e9))
    }
}
