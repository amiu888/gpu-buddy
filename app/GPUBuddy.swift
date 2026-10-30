// GPU Buddy — a tiny, animated window that shows what your GPU is doing.
// Talks to the gpud daemon (http://127.0.0.1:8765, or other Macs over TLS).
// This file is shared by the macOS app (mac/main.swift, ./build.sh) and the iOS app (ios/, ./build-ios.sh).

import Charts
import CoreImage
import CryptoKit
import ImageIO
import Network
import SwiftUI
import UniformTypeIdentifiers
import Vision
#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// Room for the Mac's traffic lights, drawn over the content of GPU Buddy's borderless windows.
#if os(macOS)
let titleBarInset = 22.0
#else
let titleBarInset = 8.0
#endif

func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

/// ~/Library/Application Support/GPUBuddy on the Mac; the app's own container on iOS.
let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("GPUBuddy")

/// Below this number of days, "per day" and "per month" values can be misleading.
let MIN_PERIOD_DAYS = 7

extension View {
    /// A fixed width on the Mac (small windows); the full screen width on iPhone and iPad.
    @ViewBuilder func panelWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width)
        #else
        frame(maxWidth: .infinity)
        #endif
    }
}

// MARK: - API model

struct Snapshot: Decodable {
    struct GPU: Decodable {
        let model: String
        let cores: Int
        let utilization_percent: Int
        let mood: String
    }
    struct Memory: Decodable {
        let used_bytes: Double
        let total_bytes: Double
        let used_percent: Double
    }
    struct Proc: Decodable, Identifiable {
        let pid: Int
        let name: String
        let gpu_percent: Double
        let is_ai: Bool
        let activity: String?
        let command: String?
        let cwd: String?
        let tok_s: Double?
        /// What it's doing, in plain English (from gpud's explainer): a short headline, a few facts,
        /// and for an LLM server the request it's working on (icon, and the user's words if snippets are on).
        let explain: String?
        let explain_facts: [String]?
        let explain_icon: String?
        let explain_quote: String?
        var id: Int { pid }

        /// "train.py · ~/projects/demo"
        var detail: String {
            [activity, cwd].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        /// "python (train.py)"
        var label: String {
            guard let a = activity, !a.isEmpty else { return name }
            return "\(name) (\(a))"
        }
    }
    struct Fun: Decodable {
        let est_peak_tflops: Double
        let est_current_tflops: Double
        let est_ops_since_start: Double
        let peak_utilization_percent: Int
    }
    let gpu: GPU
    let memory: Memory
    let processes: [Proc]
    let ai_active: Bool
    struct Tokens: Decodable {
        struct Source: Decodable {
            let name: String
            let url: String
            let model: String
            let tok_s: Double
            let in_flight: Double?
            let generated_total: Double?
            let prompt_total: Double?
            let ttft_s: Double?      // time to first token of the server's latest request
            let ttft_avg_s: Double?  // average over its recent requests
        }
        let generated_per_s: Double
        let prompt_per_s: Double
        let generated_24h: Double
        let prompt_24h: Double
        let speed_tok_s: Double
        // Time to first token of the most recent request on any server (nil from older gpud versions).
        let ttft_s: Double?
        let ttft_avg_s: Double?
        let ttft_model: String?
        let ttft_prompt_tokens: Double?  // prompt size of that request (first-token time mostly depends on it)
        let ttft_cache: Bool?            // the server's prompt cache was on for it
        let ttft_samples: Double?        // requests in the average (same model and cache setting)
        let ttft_pending_since: Double?  // unix time a request still running started (its time comes when it finishes)
        let sources: [Source]
        /// The LLMs loaded right now (newer gpud): speed now, last speed (kept until the next request), 24h tokens.
        struct LLM: Decodable, Identifiable {
            let server: String
            let model: String
            let in_flight: Double?
            let tok_s: Double?
            let last_tok_s: Double?
            let last_tok_at: Double?
            let generated_24h: Double?
            let prompt_24h: Double?
            var id: String { server + "/" + model }
        }
        let llms: [LLM]?
    }
    struct Power: Decodable {
        let available: Bool
        let error: String?
        let gpu_w: Double?
        let cpu_w: Double?
        let ane_w: Double?
        let dram_w: Double?
        let other_w: Double?
        let soc_w: Double?
        let ai_w: Double?
        let gpu_peak_w: Double?
        let system_w: Double?
        let gpu_temp: Double?
        let j_per_token: Double?
        let tokens_per_wh: Double?
        let gpu_wh_24h: Double?
        let ai_wh_24h: Double?
        let j_per_token_24h: Double?
    }
    let fun: Fun
    let tokens: Tokens?
    let power: Power?
    /// Who's using the local LLM server, from gpud's request log (nil from older gpud versions).
    let llm_requests: LLMRequests?
    struct LLMRequests: Decodable {
        let on: Bool
        let active: [LLMRequest]
        let recent: [LLMRequest]
    }
    let host: HostInfo?
}

/// Who a Mac is: its names, hardware, macOS and network addresses (from gpud).
struct HostInfo: Decodable {
    struct Address: Decodable {
        let interface: String
        let kind: String
        let ip: String
    }
    let name: String
    let hostname: String
    let model_name: String
    let model_id: String?
    let chip: String
    let gpu_cores: Int
    let cpu_cores: Int?
    let cpu_performance_cores: Int?
    let cpu_efficiency_cores: Int?
    let memory_bytes: Double
    let macos: String
    let macos_build: String?
    let addresses: [Address]
    let gpud_version: String?

    /// "Mac Studio · M4 Max · 40-core GPU · 64 GB"
    var hardware: String {
        "\(model_name) · \(chip.replacingOccurrences(of: "Apple ", with: "")) · \(gpu_cores)-core GPU · \(Int((memory_bytes / 1_073_741_824).rounded())) GB"
    }
    /// "Ethernet 10.0.2.124 · Wi-Fi 10.0.2.123"
    var network: String {
        addresses.isEmpty ? "no network" : addresses.map { "\($0.kind) \($0.ip)" }.joined(separator: " · ")
    }
    /// Everything, for tooltips.
    var details: String {
        var cpu = cpu_cores.map { "\($0)-core CPU" } ?? ""
        if let p = cpu_performance_cores, let e = cpu_efficiency_cores { cpu += " (\(p) performance + \(e) efficiency)" }
        return [
            name,
            "\(model_name)\(model_id.map { " (\($0))" } ?? "")",
            "\(chip) · \(gpu_cores)-core GPU · \(cpu)",
            "\(Int((memory_bytes / 1_073_741_824).rounded())) GB memory",
            "macOS \(macos)\(macos_build.map { " (\($0))" } ?? "")",
            "Network name: \(hostname)",
        ].joined(separator: "\n") + addresses.map { "\n\($0.kind) (\($0.interface)): \($0.ip)" }.joined()
            + (gpud_version.map { "\ngpud \($0)" } ?? "")
    }
}

struct Timeline: Decodable {
    struct Point: Decodable {
        let t: Double
        let util: Double
        let max: Int
        let mem: Double
        let ai: Bool
        let top: String?
        let tok_gen: Double?
        let tok_prompt: Double?
        let gpu_w: Double?
    }
    struct Energy: Decodable {
        let gpu_j: Double
        let ai_j: Double
        let peak_gpu_w: Double?
    }
    struct LegendItem: Decodable {
        let label: String
        let seconds: Int
        let avg_pct: Double
        let is_ai: Bool
        let last_t: Double
    }
    let bucket_seconds: Double
    let samples: [Point]
    let legend: [LegendItem]?
    let tokens: TokenTotals?
    let energy: Energy?

    struct TokenTotals: Decodable {
        let generated: Double
        let prompt: Double
    }
}

// MARK: - Connections (this Mac over loopback, other Macs over TLS)

/// RFC 4648 base32, the alphabet gpud uses for its id and pairing codes.
func base32(_ data: Data) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    var out = "", buffer = 0, bits = 0
    for byte in data {
        buffer = (buffer << 8) | Int(byte)
        bits += 8
        while bits >= 5 {
            out.append(alphabet[(buffer >> (bits - 5)) & 31])
            bits -= 5
        }
        buffer &= (1 << bits) - 1
    }
    if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
    return out
}

/// A Mac running gpud. "local" is this Mac; the others were paired with a pairing code.
struct HostRecord: Codable, Identifiable, Equatable {
    var id: String       // gpud's id (its certificate fingerprint prefix), or "local"
    var name: String
    var address: String  // "Studio.local:8766"
    var token: String = ""
    var isLocal: Bool { id == "local" }
    var title: String { isLocal ? "This Mac" : name }
}

struct Health: Decodable {
    let ok: Bool
    let id: String?
    let name: String?
    let model: String?
    let host: HostInfo?
}

struct Pairing: Decodable {
    let remote: Bool
    let code: String?
    let id: String?
    let name: String?
    let host: String?
    let port: Int?
}

/// Talks to one gpud. For other Macs every request goes over TLS, the server's certificate must
/// match the fingerprint from the pairing code (so nobody can pretend to be that Mac), and the
/// pairing token rides along in the Authorization header.
final class APIClient: NSObject, URLSessionDelegate, @unchecked Sendable {
    let base: String
    private let token: String?
    private let pin: String?
    private let lock = NSLock()
    private var _problem: String?
    private var pinFailed = false
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    /// Why the last request failed, in words.
    var problem: String? { lock.withLock { _problem } }

    init(host: HostRecord, localPort: Int) {
        if host.isLocal {
            base = "http://127.0.0.1:\(localPort)"  // loopback never leaves this Mac
            token = nil
            pin = nil
        } else {
            base = "https://\(host.address)"
            token = host.token
            pin = host.id
        }
    }

    func get<T: Decodable>(_ path: String, timeout: Double = 2) async -> T? {
        var req = URLRequest(url: URL(string: base + path)!)
        req.timeoutInterval = timeout
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            lock.withLock { _problem = code == 200 ? nil : code == 401 ? "pairing code not accepted" : "error \(code)" }
            return code == 200 ? try? JSONDecoder().decode(T.self, from: data) : nil
        } catch {
            if Task.isCancelled { return nil }
            lock.withLock {
                _problem = pinFailed ? "its certificate doesn't match the pairing code" : pin == nil ? "gpud isn't running" : "offline"
            }
            return nil
        }
    }

    func close() { session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard let pin, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              base32(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))).hasPrefix(pin) else {
            lock.withLock { pinFailed = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        lock.withLock { pinFailed = false }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Live state of one Mac.
@MainActor
final class GPUStore: ObservableObject {
    @Published var snap: Snapshot?
    @Published var online = false
    @Published private(set) var problem: String?
    @Published var history: [Double] = []
    @Published var visible = true
    @Published var timeline: Timeline?
    @Published var range: Double = 3600 {
        didSet { Task { await fetchTimeline() } }
    }
    /// The moment being replayed; nil means live.
    @Published private(set) var scrubTime: Double?
    @Published private(set) var replay: Snapshot?
    var onUpdate: ((GPUStore) -> Void)?
    /// The one on screen; only it fetches the timeline.
    var active = false

    /// Name and address; the name follows the Mac if it's renamed.
    @Published private(set) var host: HostRecord
    /// How long the last status request took, in milliseconds.
    @Published private(set) var latency: Double?
    var onRenamed: (() -> Void)?
    let client: APIClient
    private var timer: Timer?
    private var ticks = 0
    private var replayTask: Task<Void, Never>?

    init(host: HostRecord, localPort: Int) {
        self.host = host
        client = APIClient(host: host, localPort: localPort)
    }

    /// What the UI shows: the live snapshot, or the replayed one while scrubbing.
    var shown: Snapshot? { scrubTime == nil ? snap : (replay ?? snap) }
    var util: Double { online ? Double(shown?.gpu.utilization_percent ?? 0) / 100 : 0 }
    var liveUtil: Double { online ? Double(snap?.gpu.utilization_percent ?? 0) / 100 : 0 }
    var mood: String { online ? (shown?.gpu.mood ?? "sleeping") : "offline" }

    func scrub(to t: Double?) {
        scrubTime = t
        replayTask?.cancel()
        guard let t else {
            replay = nil
            return
        }
        replayTask = Task {
            try? await Task.sleep(nanoseconds: 25_000_000)  // coalesce drag events
            guard !Task.isCancelled, let s: Snapshot = await client.get("/api/v1/at?t=\(t)"), !Task.isCancelled else { return }
            replay = s
        }
    }

    func fetchTimeline() async {
        if let tl: Timeline = await client.get("/api/v1/history?seconds=\(Int(range))&points=300") { timeline = tl }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            Task { @MainActor in await self.poll() }
        }
        Task { await poll() }
    }

    func stop() {
        timer?.invalidate()
        replayTask?.cancel()
        client.close()
    }

    private func poll() async {
        let t0 = Date()
        if let s: Snapshot = await client.get("/api/v1/status") {
            latency = Date().timeIntervalSince(t0) * 1000
            snap = s
            online = true
            if !host.isLocal, let name = s.host?.name, !name.isEmpty, name != host.name {
                host.name = name
                onRenamed?()
            }
            history.append(Double(s.gpu.utilization_percent))
            if history.count > 60 { history.removeFirst(history.count - 60) }
        } else {
            online = false
            latency = nil
        }
        problem = online ? nil : client.problem
        if online && active && (timeline == nil || ticks % 10 == 0) { await fetchTimeline() }
        ticks += 1
        onUpdate?(self)
    }
}

/// Every Mac the window can show: this one, plus the ones paired over the network.
/// Finds gpud's on the local network over Bonjour (_gpubuddy._tcp).
@MainActor
final class Fleet: ObservableObject {
    struct Found: Identifiable, Equatable {
        let id: String
        let name: String
        let address: String
        let model: String
        let txt: [String: String]

        /// "Mac Studio · M4 Max · 40-core GPU · 64 GB · macOS 26.5"
        var summary: String {
            var parts = [txt["mac"], model.replacingOccurrences(of: "Apple ", with: "")].compactMap { $0 }.filter { !$0.isEmpty }
            if let g = txt["gpu"] { parts.append("\(g)-core GPU") }
            if let m = txt["mem"] { parts.append("\(m) GB") }
            if let os = txt["os"] { parts.append("macOS \(os)") }
            return parts.joined(separator: " · ")
        }
    }

    @Published private(set) var stores: [GPUStore] = []
    @Published private(set) var current: GPUStore
    /// gpud's seen on the network right now (not counting this Mac).
    @Published private(set) var found: [Found] = []
    /// This Mac's own pairing code, for sharing with other Macs.
    @Published private(set) var thisMac: Pairing?
    @Published var compact = UserDefaults.standard.bool(forKey: "compact") {
        didSet {
            UserDefaults.standard.set(compact, forKey: "compact")
            if compact { current.scrub(to: nil) }
            onCompactChange?()
        }
    }
    /// Sections of the full view that are folded away (remembered between launches).
    @Published var collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(collapsed).sorted(), forKey: "collapsedSections")
            onCompactChange?()  // the window refits to its new height
        }
    }
    func toggleSection(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }
    var onCompactChange: (() -> Void)?
    var onSelect: (() -> Void)?
    var onUpdate: ((GPUStore) -> Void)?
    var onOpenLedger: (() -> Void)?
    var onOpenMacs: (() -> Void)?

    let localPort: Int
    private var browser: NWBrowser?
    private var seen: [Found] = []
    /// Paired Macs, including their tokens: readable only by you.
    private let file = appSupport.appendingPathComponent("viewer-hosts.json")

    init(localPort: Int) {
        self.localPort = localPort
        var records = [HostRecord(id: "local", name: "This Mac", address: "127.0.0.1:\(localPort)")]
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([HostRecord].self, from: data) {
            records += saved.filter { !$0.isLocal }
        }
        let all = records.map { GPUStore(host: $0, localPort: localPort) }
        stores = all
        let saved = all.first { $0.host.id == UserDefaults.standard.string(forKey: "selectedHost") }
        // On iOS the local entry is only a placeholder, so start on a paired Mac when there is one.
        current = saved.flatMap { Self.hasLocal || !$0.host.isLocal ? $0 : nil }
            ?? (Self.hasLocal ? all[0] : all.first { !$0.host.isLocal } ?? all[0])
        current.active = true
        all.forEach(wire)
    }

    private func wire(_ s: GPUStore) {
        s.onRenamed = { [weak self] in self?.save() }
        s.onUpdate = { [weak self] s in
            guard let self, s === self.current else { return }
            self.onUpdate?(s)
        }
    }

    /// iPhones and iPads can't run gpud, so there "local" is only a placeholder until a Mac is paired.
    static var hasLocal: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// The Macs to show: on iOS, the local placeholder is left out.
    var watched: [GPUStore] { Self.hasLocal ? stores : stores.filter { !$0.host.isLocal } }

    func start() {
        stores.filter { Self.hasLocal || !$0.host.isLocal }.forEach { $0.start() }
        browse()
        Task {
            if Self.hasLocal { thisMac = await stores[0].client.get("/api/v1/pairing") }
            update(found: seen)
        }
    }

    func select(_ s: GPUStore) {
        guard s !== current else { return }
        current.scrub(to: nil)
        current.active = false
        current = s
        s.active = true
        UserDefaults.standard.set(s.host.id, forKey: "selectedHost")
        Task { await s.fetchTimeline() }
        onSelect?()
        onUpdate?(s)
    }

    func step(_ n: Int) {
        let list = watched
        guard !list.isEmpty else { return }
        let i = list.firstIndex(where: { $0 === current }) ?? 0
        select(list[(i + n + list.count) % list.count])
    }

    func isPaired(_ id: String) -> Bool { stores.contains { $0.host.id == id } }

    /// Checks the code against the Mac at address and, if it answers, adds it. Returns an error message.
    func pair(address: String, code: String) async -> String? {
        let clean = code.uppercased().filter { $0.isLetter || $0.isNumber }
        guard clean.count == 28 else { return "A pairing code has 28 letters and digits (7 groups of 4)." }
        var addr = address.trimmingCharacters(in: .whitespaces)
        if addr.isEmpty { return "Enter the Mac's address, like Studio.local" }
        if !addr.contains(":") || addr.hasSuffix("]") { addr += ":8766" }
        var rec = HostRecord(id: String(clean.suffix(12)), name: addr, address: addr, token: String(clean.prefix(16)))
        if rec.id == thisMac?.id { return "That's this Mac's own code. Enter the code shown on the other Mac." }
        let client = APIClient(host: rec, localPort: localPort)
        let health: Health? = await client.get("/health", timeout: 6)
        client.close()
        guard let health, health.ok else {
            return "Couldn't connect: \(client.problem ?? "no answer")."
        }
        rec.name = health.name ?? addr
        if stores.contains(where: { $0.host.id == rec.id }) { remove(rec.id) }
        let s = GPUStore(host: rec, localPort: localPort)
        wire(s)
        stores.append(s)
        s.start()
        save()
        select(s)
        return nil
    }

    func remove(_ id: String) {
        guard id != "local", let s = stores.first(where: { $0.host.id == id }) else { return }
        if s === current { select(watched.first { $0 !== s } ?? stores[0]) }
        s.stop()
        stores.removeAll { $0 === s }
        save()
    }

    private func save() {
        let remote = stores.map(\.host).filter { !$0.isLocal }
        guard let data = try? JSONEncoder().encode(remote) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    private func browse() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_gpubuddy._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let list = results.compactMap { r -> Found? in
                guard case .service(let name, _, _, _) = r.endpoint, case .bonjour(let txt) = r.metadata else { return nil }
                let d = txt.dictionary
                guard let id = d["id"], let host = d["host"] else { return nil }
                return Found(id: id, name: name, address: "\(host):\(d["port"] ?? "8766")", model: d["model"] ?? "", txt: d)
            }
            MainActor.assumeIsolated { self?.update(found: list) }
        }
        b.start(queue: .main)
        browser = b
    }

    private func update(found list: [Found]) {
        seen = list
        var ids = Set<String>()
        found = list.filter { $0.id != thisMac?.id && ids.insert($0.id).inserted }.sorted { $0.name < $1.name }
        // A paired Mac that now answers at a different address (renamed, new network): follow it.
        for f in found {
            guard let i = stores.firstIndex(where: { $0.host.id == f.id }), stores[i].host.address != f.address else { continue }
            let old = stores[i]
            var rec = old.host
            rec.address = f.address
            rec.name = f.name
            let n = GPUStore(host: rec, localPort: localPort)
            wire(n)
            old.stop()
            stores[i] = n
            n.start()
            if old === current {
                current = n
                n.active = true
                onSelect?()
            }
            save()
        }
    }
}

// MARK: - Animation state (integrated per frame so speed changes never jump)

func hash(_ n: Double) -> Double {
    let x = sin(n * 12.9898) * 43758.5453
    return x - floor(x)
}

final class Anim {
    struct Particle {
        var x, y, vx, vy, life, maxLife, size, hue: Double
        var glyph: String?
    }

    var last: Date?
    var time = 0.0
    var util = 0.0
    var mem = 0.0
    var runPhase = 0.0
    var fanPhase = 0.0
    var scroll = 0.0
    var wave = 0.0
    var blinkAt = 2.0
    var particles: [Particle] = []
    private var spawnAcc = 0.0
    private static let glyphs = ["✦", "◆", "0", "1", "λ", "∑", "⋆", "π", "∂"]

    var hue: Double { (0.64 + util * 0.36).truncatingRemainder(dividingBy: 1) }
    var blinking: Bool { time > blinkAt && time < blinkAt + 0.12 }

    func step(_ now: Date, util target: Double, mem memTarget: Double, ai: Bool, tokS: Double = 0) {
        let dt = max(0, min(0.1, last.map { now.timeIntervalSince($0) } ?? 0))
        last = now
        time += dt
        util += (target - util) * min(1, dt * 3)
        mem += (memTarget - mem) * min(1, dt * 2)
        runPhase += dt * (util < 0.05 ? 0 : 1.2 + util * 4.5)
        fanPhase += dt * (1.5 + util * 28)
        // The road moves with the GPU: stopped when idle, faster as the load goes up.
        scroll += dt * (util < 0.02 ? 0 : 40 + util * 300)
        wave += dt * (1.5 + util * 4)
        if time > blinkAt + 0.12 { blinkAt = time + 2 + hash(time) * 3 }

        spawnAcc += dt * (util * 20 + min(25, tokS / 5))
        while spawnAcc >= 1 {
            spawnAcc -= 1
            let r = hash(time * 91 + Double(particles.count))
            let r2 = hash(time * 37 + r)
            particles.append(Particle(
                x: (r - 0.5) * 26, y: 0,
                vx: (r2 - 0.5) * 34 - util * 40, vy: -(28 + r * 40),
                life: 1.2 + r2, maxLife: 1.2 + r2, size: 3 + r * 3,
                hue: (hue + r * 0.3).truncatingRemainder(dividingBy: 1),
                glyph: ai || tokS > 0 ? Self.glyphs[Int(r2 * Double(Self.glyphs.count)) % Self.glyphs.count] : nil))
        }
        for i in particles.indices {
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            particles[i].vy += 12 * dt
            particles[i].life -= dt
        }
        particles.removeAll { $0.life <= 0 }
        if particles.count > 60 { particles.removeFirst(particles.count - 60) }
    }
}

// MARK: - Characters (Chippy, Witch Bunny, or any photo you add)

/// What the scene draws.
enum CharacterKind {
    case chippy
    case bunny
    case photo(PlatformImage)
}

/// The characters to choose from: the built-in ones plus photo characters, which are cut out of
/// your photos with Vision and kept in ~/Library/Application Support/GPUBuddy/characters.
@MainActor
final class Characters: ObservableObject {
    struct Entry: Identifiable, Codable {
        let id: String
        let name: String
    }

    static let builtIn = [Entry(id: "chippy", name: "🐱 Chippy"), Entry(id: "bunny", name: "🐰 Witch Bunny")]

    @Published var selected = UserDefaults.standard.string(forKey: "character") ?? "chippy" {
        didSet { UserDefaults.standard.set(selected, forKey: "character") }
    }
    @Published private(set) var photos: [Entry] = []
    @Published private(set) var busy = false
    /// iOS: show the photo picker (the Mac uses an open panel instead).
    @Published var pickingPhoto = false
    private var images: [String: PlatformImage] = [:]
    private let dir = appSupport.appendingPathComponent("characters")
    private var index: URL { dir.appendingPathComponent("index.json") }

    init() {
        if let data = try? Data(contentsOf: index), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            for e in list {
                if let img = PlatformImage(contentsOfFile: dir.appendingPathComponent("\(e.id).png").path) {
                    images[e.id] = img
                    photos.append(e)
                }
            }
        }
        if Self.builtIn.allSatisfy({ $0.id != selected }) && images[selected] == nil { selected = "chippy" }
    }

    var all: [Entry] { Self.builtIn + photos.map { Entry(id: $0.id, name: "📷 " + $0.name) } }

    var current: CharacterKind {
        switch selected {
        case "bunny": return .bunny
        case "chippy": return .chippy
        default: return images[selected].map { .photo($0) } ?? .chippy
        }
    }

    var currentIsPhoto: Bool { images[selected] != nil }
    var currentName: String { all.first { $0.id == selected }?.name ?? "" }

    func next() {
        let ids = all.map(\.id)
        selected = ids[((ids.firstIndex(of: selected) ?? -1) + 1) % ids.count]
    }

    /// Lifts the subject out of a photo and adds it as a character.
    func add(from url: URL, name: String) async throws {
        busy = true
        defer { busy = false }
        let png = try await Task.detached(priority: .userInitiated) { try Self.cutout(url) }.value
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "photo-" + UUID().uuidString.prefix(8).lowercased()
        try png.write(to: dir.appendingPathComponent("\(id).png"))
        guard let img = PlatformImage(data: png) else { return }
        images[id] = img
        photos.append(Entry(id: id, name: name))
        saveIndex()
        selected = id
    }

    func remove(_ id: String) {
        guard images[id] != nil else { return }
        images[id] = nil
        photos.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).png"))
        saveIndex()
        if selected == id { selected = "chippy" }
    }

    /// iOS: a photo from the picker.
    func add(imageData: Data, name: String) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try imageData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await add(from: tmp, name: name)
    }

    func addFromPanel() {
        #if os(iOS)
        pickingPhoto = true
        #else
        let panel = NSOpenPanel()
        panel.message = "Pick a photo of a toy, pet or anything with a clear subject. GPU Buddy cuts it out and animates it."
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await add(from: url, name: url.deletingPathExtension().lastPathComponent)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't make a character from that photo"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        #endif
    }

    private func saveIndex() {
        try? JSONEncoder().encode(photos).write(to: index)
    }

    /// The photo's main subject on a transparent background, cropped to it, as PNG.
    nonisolated static func cutout(_ url: URL) throws -> Data {
        let fail = { (msg: String) in NSError(domain: "GPUBuddy", code: 2, userInfo: [NSLocalizedDescriptionKey: msg]) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw fail("That file isn't an image.") }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,  // upright, whatever the camera did
                                     kCGImageSourceThumbnailMaxPixelSize: 1400]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw fail("Couldn't read the image.") }
        let handler = VNImageRequestHandler(cgImage: cg)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            throw fail("No clear subject found. Try a photo where it stands out from the background.")
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
        let ci = CIImage(cvPixelBuffer: buffer)
        // Keep it light: the scene draws it at most ~100pt tall.
        let scale = min(1, 600 / ci.extent.height)
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        #if os(macOS)
        let encode = { (cg: CGImage) in NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) }
        #else
        let encode = { (cg: CGImage) in UIImage(cgImage: cg).pngData() }
        #endif
        guard let out = CIContext().createCGImage(small, from: small.extent), let png = encode(out) else {
            throw fail("Couldn't save the cut-out.")
        }
        return png
    }
}

// MARK: - The scene: Chippy (or another character) running as hard as your GPU

/// Chippy is drawn in a 150pt-tall design space and scaled to fit, so the same
/// drawing serves the full window and the compact strip.
let sceneDesignHeight = 150.0

struct SceneCanvas: View {
    let anim: Anim
    let mood: String
    var badge: String? = nil
    var character: CharacterKind = .chippy
    /// Full view: the temperature and first-token badges sit top-left, so the character moves a little right and shrinks a touch.
    var roomForBadges = false
    /// The animation clock for this frame. `anim` is the same object every frame, so without a value that changes
    /// SwiftUI sees identical inputs and skips redrawing: the road and the character would freeze.
    var frameTime: Double = 0

    var body: some View {
        Canvas { ctx, size in
            let k = size.height / sceneDesignHeight
            ctx.scaleBy(x: k, y: k)
            draw(&ctx, CGSize(width: size.width / k, height: sceneDesignHeight))
        }
    }

    private func heart(_ c: CGPoint, _ r: Double) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y + r))
        p.addCurve(to: CGPoint(x: c.x - r, y: c.y - r * 0.2), control1: CGPoint(x: c.x - r * 0.4, y: c.y + r * 0.6), control2: CGPoint(x: c.x - r, y: c.y + r * 0.3))
        p.addArc(center: CGPoint(x: c.x - r * 0.5, y: c.y - r * 0.25), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addArc(center: CGPoint(x: c.x + r * 0.5, y: c.y - r * 0.25), radius: r * 0.5, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addCurve(to: CGPoint(x: c.x, y: c.y + r), control1: CGPoint(x: c.x + r, y: c.y + r * 0.3), control2: CGPoint(x: c.x + r * 0.4, y: c.y + r * 0.6))
        return p
    }

    // MARK: Chippy: the kitty-eared chip.

    private func drawChippy(_ ctx: GraphicsContext, cx: Double, groundY: Double, bob: Double, sleeping: Bool,
                            offline: Bool) -> (GraphicsContext, CGRect) {
        let a = anim, u = a.util, t = a.time
            var c = ctx
            c.translateBy(x: cx, y: groundY)
            c.rotate(by: .radians(sleeping ? 0 : u * 0.12))
            c.translateBy(x: -cx, y: -groundY)

            let bw = 64.0, bh = 54.0
            let bodyBottom = groundY - 11 - bob
            let body = CGRect(x: cx - bw / 2, y: bodyBottom - bh, width: bw, height: bh)
            let gold = Color(red: 1, green: 0.8, blue: 0.45)
            let shell1 = Color(red: 0.98, green: 0.96, blue: 1)
            let shell2 = Color(red: 0.8, green: 0.78, blue: 0.97)
            let pink = Color(red: 1, green: 0.55, blue: 0.7)

            // Turbo rocket flames.
            if u > 0.82 && !sleeping {
                let f = 0.75 + 0.25 * sin(t * 40) + 0.15 * sin(t * 23)
                let outer = CGRect(x: body.minX - 4 - 30 * f, y: body.midY + 6 - 9 * f, width: 34 * f, height: 18 * f)
                c.drawLayer { l in
                    l.addFilter(.blur(radius: 3))
                    l.fill(Path(ellipseIn: outer), with: .color(.orange.opacity(0.85)))
                    l.fill(Path(ellipseIn: outer.insetBy(dx: 8 * f, dy: 4 * f).offsetBy(dx: 5, dy: 0)), with: .color(.yellow))
                }
            }

            // USB-cable tail, wagging faster with load.
            let wag = sin(t * (2 + u * 10)) * (sleeping ? 2 : 7)
            var tail = Path()
            let tailStart = CGPoint(x: body.minX + 4, y: body.maxY - 12)
            tail.move(to: tailStart)
            let tailEnd = CGPoint(x: tailStart.x - 22, y: tailStart.y - 16 + wag)
            tail.addCurve(to: tailEnd, control1: CGPoint(x: tailStart.x - 14, y: tailStart.y + 6), control2: CGPoint(x: tailEnd.x + 4, y: tailEnd.y + 14))
            c.stroke(tail, with: .color(Color(white: 0.35)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            c.fill(Path(roundedRect: CGRect(x: tailEnd.x - 4, y: tailEnd.y - 7, width: 8, height: 9), cornerRadius: 2), with: .color(Color(white: 0.75)))

            // Stubby pin legs.
            let stride = sleeping ? 0 : min(1, u * 2)
            for i in 0..<2 {
                let ph = a.runPhase * .pi * 2 + Double(i) * .pi
                let hip = CGPoint(x: cx + (i == 0 ? -13 : 13), y: bodyBottom - 2)
                let foot = CGPoint(x: hip.x + sin(ph) * 9 * stride, y: groundY - 3 - max(0, cos(ph)) * 6 * stride)
                var leg = Path()
                leg.move(to: hip)
                leg.addLine(to: foot)
                c.stroke(leg, with: .color(gold), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                c.fill(Path(ellipseIn: CGRect(x: foot.x - 6, y: foot.y - 3, width: 12, height: 6)), with: .color(Color(red: 0.98, green: 0.7, blue: 0.8)))
            }

            // Little arm pins.
            for side in [-1.0, 1.0] {
                let swing = sin(a.runPhase * .pi * 2 + (side > 0 ? 0 : .pi)) * 5 * stride
                let px = side < 0 ? body.minX - 6 : body.maxX - 1
                c.fill(Path(roundedRect: CGRect(x: px, y: body.midY + 2 + swing - 2.5, width: 7, height: 5), cornerRadius: 2.5), with: .color(gold))
            }

            // Kitty ears.
            for side in [-1.0, 1.0] {
                let ex = cx + side * 20
                var ear = Path()
                ear.move(to: CGPoint(x: ex - 9, y: body.minY + 6))
                ear.addQuadCurve(to: CGPoint(x: ex + side * 3, y: body.minY - 12 - (sleeping ? 0 : sin(t * 3) * u * 2)), control: CGPoint(x: ex - 7, y: body.minY - 6))
                ear.addQuadCurve(to: CGPoint(x: ex + 9, y: body.minY + 6), control: CGPoint(x: ex + 7, y: body.minY - 6))
                c.fill(ear, with: .color(shell2))
                var inner = Path()
                inner.move(to: CGPoint(x: ex - 4.5, y: body.minY + 4))
                inner.addQuadCurve(to: CGPoint(x: ex + side * 2, y: body.minY - 6), control: CGPoint(x: ex - 3.5, y: body.minY - 2))
                inner.addQuadCurve(to: CGPoint(x: ex + 4.5, y: body.minY + 4), control: CGPoint(x: ex + 3.5, y: body.minY - 2))
                c.fill(inner, with: .color(pink.opacity(0.75)))
            }

            // Chubby body.
            let bodyPath = Path(roundedRect: body, cornerRadius: 22)
            c.fill(bodyPath, with: .linearGradient(Gradient(colors: [shell1, shell2]),
                                                   startPoint: CGPoint(x: body.minX, y: body.minY), endPoint: CGPoint(x: body.maxX, y: body.maxY)))
            c.fill(Path(ellipseIn: CGRect(x: body.minX + 9, y: body.minY + 5, width: 16, height: 7)), with: .color(.white.opacity(0.9)))

            // Propeller beanie between the ears.
            var stem = Path()
            stem.move(to: CGPoint(x: cx, y: body.minY + 1))
            stem.addLine(to: CGPoint(x: cx, y: body.minY - 7))
            c.stroke(stem, with: .color(Color(white: 0.5)), lineWidth: 2)
            let blade = abs(cos(a.fanPhase)) * 12 + 2
            c.fill(Path(ellipseIn: CGRect(x: cx - blade, y: body.minY - 10, width: blade * 2, height: 4.5)),
                   with: .color(Color(hue: a.hue, saturation: 0.45, brightness: 1).opacity(u > 0.6 ? 0.75 : 1)))
            c.fill(Path(ellipseIn: CGRect(x: cx - 2.5, y: body.minY - 10, width: 5, height: 5)), with: .color(pink))

            // Face.
            let ink = Color(red: 0.2, green: 0.17, blue: 0.32)
            let ey = body.minY + 22
            for side in [-1.0, 1.0] {
                let ex = cx + side * 12
                if offline {
                    var xp = Path()
                    xp.move(to: CGPoint(x: ex - 3.5, y: ey - 3.5)); xp.addLine(to: CGPoint(x: ex + 3.5, y: ey + 3.5))
                    xp.move(to: CGPoint(x: ex + 3.5, y: ey - 3.5)); xp.addLine(to: CGPoint(x: ex - 3.5, y: ey + 3.5))
                    c.stroke(xp, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                } else if sleeping {
                    var arc = Path()
                    arc.addArc(center: CGPoint(x: ex, y: ey - 1), radius: 4.5, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                    c.stroke(arc, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                } else if mood == "turbo" {
                    var ch = Path()
                    ch.move(to: CGPoint(x: ex - side * 4, y: ey - 4.5))
                    ch.addLine(to: CGPoint(x: ex + side * 3, y: ey))
                    ch.addLine(to: CGPoint(x: ex - side * 4, y: ey + 4.5))
                    c.stroke(ch, with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                } else if a.blinking {
                    var lid = Path()
                    lid.move(to: CGPoint(x: ex - 4.5, y: ey)); lid.addLine(to: CGPoint(x: ex + 4.5, y: ey))
                    c.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                } else {
                    // Big sparkly anime eyes.
                    c.fill(Path(ellipseIn: CGRect(x: ex - 5, y: ey - 6.5, width: 10, height: 13)), with: .color(ink))
                    c.fill(Path(ellipseIn: CGRect(x: ex - 3, y: ey - 4.5, width: 4.2, height: 4.2)), with: .color(.white))
                    c.fill(Path(ellipseIn: CGRect(x: ex + 1, y: ey + 1.5, width: 2, height: 2)), with: .color(.white.opacity(0.9)))
                    if mood == "hustling" {
                        var brow = Path()
                        brow.move(to: CGPoint(x: ex - side * 5, y: ey - 11))
                        brow.addLine(to: CGPoint(x: ex + side * 4, y: ey - 9))
                        c.stroke(brow, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    }
                }
                c.fill(Path(ellipseIn: CGRect(x: ex + side * 5 - 5, y: ey + 6, width: 10, height: 5)),
                       with: .color(pink.opacity(offline ? 0 : 0.35 + 0.5 * u)))
            }

            let my = ey + 10
            var mouth = Path()
            switch mood {
            case "offline":
                mouth.addArc(center: CGPoint(x: cx, y: my + 3), radius: 3.5, startAngle: .degrees(200), endAngle: .degrees(340), clockwise: false)
                c.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            case "sleeping":
                c.fill(Path(ellipseIn: CGRect(x: cx - 1.8, y: my - 1, width: 3.6, height: 3 + sin(t * 1.6))), with: .color(ink))
            case "chill", "working":
                // Cat mouth: ω
                mouth.addArc(center: CGPoint(x: cx - 2.6, y: my - 1.5), radius: 2.6, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                mouth.addArc(center: CGPoint(x: cx + 2.6, y: my - 1.5), radius: 2.6, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                c.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            default:  // hustling / turbo: open grin with a tongue
                let r = mood == "turbo" ? 5.5 : 4.5
                mouth.move(to: CGPoint(x: cx - r, y: my - 2))
                mouth.addArc(center: CGPoint(x: cx, y: my - 2), radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                mouth.closeSubpath()
                c.fill(mouth, with: .color(ink))
                c.fill(Path(ellipseIn: CGRect(x: cx - r * 0.55, y: my + r * 0.25 - 2, width: r * 1.1, height: r * 0.7)), with: .color(pink))
            }

            // Tiny gold chip badge on the tummy.
            c.fill(Path(roundedRect: CGRect(x: cx - 6, y: body.maxY - 12, width: 12, height: 7), cornerRadius: 2), with: .color(gold.opacity(0.85)))
        return (c, body)
    }

    // MARK: Witch Bunny: a chunky crocheted bunny in a witch hat that hops harder as the GPU works.

    /// Rows of little V stitches clipped to a shape, so it reads as chenille yarn.
    private func knit(_ ctx: GraphicsContext, _ shape: Path, _ rect: CGRect, _ color: Color, spacing: Double = 4.6) {
        var k = ctx
        k.clip(to: shape)
        var stitches = Path()
        var y = rect.minY + 1.5
        var row = 0
        while y < rect.maxY + 2 {
            var x = rect.minX + (row % 2 == 0 ? 0 : spacing / 2)
            while x < rect.maxX + 2 {
                stitches.move(to: CGPoint(x: x - spacing * 0.42, y: y - 1.4))
                stitches.addQuadCurve(to: CGPoint(x: x, y: y + 1.4), control: CGPoint(x: x - spacing * 0.3, y: y + 1.2))
                stitches.addQuadCurve(to: CGPoint(x: x + spacing * 0.42, y: y - 1.4), control: CGPoint(x: x + spacing * 0.3, y: y + 1.2))
                x += spacing
            }
            y += spacing * 0.85
            row += 1
        }
        k.stroke(stitches, with: .color(color), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        // Soft plush shading: lit from the top left.
        k.fill(shape, with: .radialGradient(Gradient(colors: [.white.opacity(0.28), .clear, .black.opacity(0.16)]),
                                            center: CGPoint(x: rect.minX + rect.width * 0.32, y: rect.minY + rect.height * 0.25),
                                            startRadius: 0, endRadius: max(rect.width, rect.height) * 0.95))
    }

    private func drawBunny(_ ctx: GraphicsContext, cx: Double, groundY: Double, sleeping: Bool, offline: Bool) -> CGRect {
        let a = anim, u = a.util, t = a.time
        let stride = sleeping ? 0 : min(1, u * 2.5)
        let turbo = mood == "turbo" && !sleeping
        let ph = a.runPhase * .pi
        let hop = turbo ? 0 : abs(sin(ph)) * (3 + 11 * u) * stride
        let fly = turbo ? 9 + sin(t * 3) * 2.5 : 0
        let landing = 1 - abs(sin(ph))
        let squash = sleeping ? 1 + 0.025 * sin(t * 1.6) : 1 - 0.09 * landing * stride
        let lift = hop + fly

        let cream = offline ? Color(white: 0.82) : Color(red: 0.98, green: 0.95, blue: 0.87)
        let shade = offline ? Color(white: 0.62) : Color(red: 0.8, green: 0.72, blue: 0.58)
        let ink = Color(red: 0.07, green: 0.06, blue: 0.09)
        let hatColor = Color(red: 0.14, green: 0.12, blue: 0.18)
        let lavender = offline ? Color(white: 0.7) : Color(red: 0.74, green: 0.64, blue: 0.94)
        let pink = Color(red: 1, green: 0.6, blue: 0.72)

        var c = ctx
        c.translateBy(x: cx, y: groundY - 2 - lift)
        c.rotate(by: .radians(sleeping ? -0.04 : u * 0.1))
        let k = 0.86  // hat and all, she's taller than Chippy
        c.scaleBy(x: (2 - squash) * k, y: squash * k)

        // Turbo: she hops on her broom and flies.
        if turbo {
            var stick = Path()
            stick.move(to: CGPoint(x: -40, y: 3))
            stick.addLine(to: CGPoint(x: 42, y: -9))
            c.stroke(stick, with: .color(Color(red: 0.56, green: 0.37, blue: 0.21)), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            var straw = Path()
            for i in 0..<11 {
                let spread = (Double(i) / 10 - 0.5) * 1.1
                let len = 17 + 4 * sin(t * 30 + Double(i) * 1.7)
                straw.move(to: CGPoint(x: -38, y: 3))
                straw.addLine(to: CGPoint(x: -38 - cos(spread) * len, y: 3 + 2 + sin(spread) * len * 0.8))
            }
            c.stroke(straw, with: .color(Color(red: 0.98, green: 0.8, blue: 0.4)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            c.fill(Path(roundedRect: CGRect(x: -41, y: -0.5, width: 6, height: 7), cornerRadius: 1.5), with: .color(lavender))
        }

        // Long floppy ears hanging down the sides, flapping with each hop (streaming back in turbo).
        let flap = sleeping ? 0.03 * sin(t * 1.6) : -cos(a.runPhase * .pi * 2) * 0.2 * stride
        for side in [-1.0, 1.0] {
            let angle = turbo ? 0.95 + 0.08 * sin(t * 9 + side) : -side * (0.3 + flap)
            let tf = CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: side * 19, y: -78))
            let rect = CGRect(x: -9.5, y: -4, width: 19, height: 62)
            let ear = Path(roundedRect: rect, cornerRadius: 9.5).applying(tf)
            c.fill(ear, with: .color(cream))
            knit(c, ear, ear.boundingRect, shade.opacity(0.55))
            c.stroke(ear, with: .color(shade.opacity(0.75)), lineWidth: 0.8)
        }

        // Feet, body, head.
        for side in [-1.0, 1.0] {
            let foot = Path(ellipseIn: CGRect(x: side * 13 - 10.5, y: -12, width: 21, height: 13))
            c.fill(foot, with: .color(cream))
            knit(c, foot, foot.boundingRect, shade.opacity(0.55))
            c.stroke(foot, with: .color(shade.opacity(0.75)), lineWidth: 0.8)
        }
        let bodyRect = CGRect(x: -24, y: -46, width: 48, height: 42)
        let body = Path(ellipseIn: bodyRect)
        c.fill(body, with: .color(cream))
        knit(c, body, bodyRect, shade.opacity(0.55))
        c.stroke(body, with: .color(shade.opacity(0.75)), lineWidth: 0.8)
        let headRect = CGRect(x: -29, y: -88, width: 58, height: 47)
        let head = Path(ellipseIn: headRect)
        c.fill(head, with: .color(cream))
        knit(c, head, headRect, shade.opacity(0.55))
        c.stroke(head, with: .color(shade.opacity(0.75)), lineWidth: 0.8)

        // Little paws held at the chest, bouncing as she hops.
        for side in [-1.0, 1.0] {
            let py = -38 + sin(a.runPhase * .pi * 2 + (side > 0 ? 0 : .pi)) * 2.5 * stride
            let pawRect = CGRect(x: side * 12 - 7.5, y: py - 8, width: 15, height: 16)
            let paw = Path(ellipseIn: pawRect)
            c.fill(paw, with: .color(cream))
            knit(c, paw, pawRect, shade.opacity(0.6), spacing: 4)
            c.stroke(paw, with: .color(shade.opacity(0.75)), lineWidth: 0.8)
        }

        // Bead eyes, set wide and low like the real one.
        let ey = -60.0
        for side in [-1.0, 1.0] {
            let ex = side * 13.5
            if offline {
                var xp = Path()
                xp.move(to: CGPoint(x: ex - 3, y: ey - 3)); xp.addLine(to: CGPoint(x: ex + 3, y: ey + 3))
                xp.move(to: CGPoint(x: ex + 3, y: ey - 3)); xp.addLine(to: CGPoint(x: ex - 3, y: ey + 3))
                c.stroke(xp, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else if sleeping || a.blinking {
                var lid = Path()
                lid.addArc(center: CGPoint(x: ex, y: ey - 1.5), radius: 3.6, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                c.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
            } else if turbo {
                var ch = Path()
                ch.move(to: CGPoint(x: ex - side * 3.5, y: ey - 3.5))
                ch.addLine(to: CGPoint(x: ex + side * 2.5, y: ey))
                ch.addLine(to: CGPoint(x: ex - side * 3.5, y: ey + 3.5))
                c.stroke(ch, with: .color(ink), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            } else {
                c.fill(Path(ellipseIn: CGRect(x: ex - 3.4, y: ey - 3.6, width: 6.8, height: 7.2)), with: .color(ink))
                c.fill(Path(ellipseIn: CGRect(x: ex - 2, y: ey - 2.6, width: 2.2, height: 2.2)), with: .color(.white.opacity(0.9)))
            }
            c.fill(Path(ellipseIn: CGRect(x: ex + side * 3.5 - 4.5, y: ey + 5, width: 9, height: 4.5)),
                   with: .color(pink.opacity(offline ? 0 : 0.18 + 0.5 * u)))
        }
        var mouth = Path()
        switch mood {
        case "working":
            mouth.addArc(center: CGPoint(x: -1.8, y: ey + 5), radius: 1.8, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            mouth.addArc(center: CGPoint(x: 1.8, y: ey + 5), radius: 1.8, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            c.stroke(mouth, with: .color(ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        case "hustling", "turbo":
            let r = mood == "turbo" ? 3.6 : 3
            mouth.move(to: CGPoint(x: -r, y: ey + 4))
            mouth.addArc(center: CGPoint(x: 0, y: ey + 4), radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            mouth.closeSubpath()
            c.fill(mouth, with: .color(ink))
            c.fill(Path(ellipseIn: CGRect(x: -r * 0.55, y: ey + 4 + r * 0.3, width: r * 1.1, height: r * 0.6)), with: .color(pink))
        default:
            break
        }

        // The witch hat: black cone, lavender band, wide brim. It lags behind each hop and droops when she naps.
        let tilt = sleeping ? -0.34 : -0.12 + sin(a.runPhase * .pi * 2 - 0.8) * 0.1 * stride - (turbo ? 0.28 : 0)
        var hc = c
        hc.translateBy(x: 1, y: headRect.minY + 7)
        hc.rotate(by: .radians(tilt))
        hc.scaleBy(x: 1.12, y: 1.12)
        let wobble = sleeping ? 0 : sin(t * 4 + 1) * 2.5 * stride
        var cone = Path()
        cone.move(to: CGPoint(x: -17, y: -6))
        cone.addQuadCurve(to: CGPoint(x: 5 + wobble, y: -48), control: CGPoint(x: -9, y: -30))
        cone.addQuadCurve(to: CGPoint(x: 17, y: -6), control: CGPoint(x: 10, y: -25))
        cone.closeSubpath()
        hc.fill(cone, with: .color(hatColor))
        knit(hc, cone, cone.boundingRect, .white.opacity(0.16), spacing: 4)
        let bandRect = CGRect(x: -17.5, y: -13, width: 35, height: 7.5)
        let band = Path(roundedRect: bandRect, cornerRadius: 2)
        hc.fill(band, with: .color(lavender))
        knit(hc, band, bandRect, .black.opacity(0.18), spacing: 3.6)
        let brimRect = CGRect(x: -27, y: -8, width: 54, height: 11)
        let brim = Path(ellipseIn: brimRect)
        hc.fill(brim, with: .color(hatColor))
        knit(hc, brim, brimRect, .white.opacity(0.14), spacing: 4)

        // Where the effects (sweat, Zzz, sparkles) attach, in scene coordinates.
        return CGRect(x: cx - 29 * k, y: groundY - 2 - lift + headRect.minY * squash * k, width: 58 * k, height: headRect.height * squash * k)
    }

    // MARK: Photo characters: your cut-out, squashing, stretching and hopping.

    private func drawPhoto(_ ctx: GraphicsContext, _ image: PlatformImage, cx: Double, groundY: Double, sleeping: Bool, offline: Bool) -> CGRect {
        let a = anim, u = a.util, t = a.time
        let stride = sleeping ? 0 : min(1, u * 2.5)
        let turbo = mood == "turbo" && !sleeping
        let ph = a.runPhase * .pi
        let hop = abs(sin(ph)) * (3 + 10 * u) * stride
        let landing = 1 - abs(sin(ph))
        // Jelly: squash on landing, stretch in the air, breathe while napping.
        let squash = sleeping ? 1 + 0.03 * sin(t * 1.6) : 1 - 0.1 * landing * stride + 0.05 * (1 - landing) * stride
        let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        var hgt = 100.0
        var wid = hgt * aspect
        if wid > 120 {
            wid = 120
            hgt = wid / aspect
        }

        var c = ctx
        c.translateBy(x: cx, y: groundY - 1 - hop)
        c.rotate(by: .radians(sleeping ? -0.08 + 0.02 * sin(t * 1.6) : u * 0.1 + sin(a.runPhase * .pi * 2) * 0.05 * stride))
        c.scaleBy(x: 2 - squash, y: squash)

        if turbo {
            let f = 0.75 + 0.25 * sin(t * 40) + 0.15 * sin(t * 23)
            let outer = CGRect(x: -wid / 2 - 30 * f, y: -hgt * 0.45 - 9 * f, width: 34 * f, height: 18 * f)
            c.drawLayer { l in
                l.addFilter(.blur(radius: 3))
                l.fill(Path(ellipseIn: outer), with: .color(.orange.opacity(0.85)))
                l.fill(Path(ellipseIn: outer.insetBy(dx: 8 * f, dy: 4 * f).offsetBy(dx: 5, dy: 0)), with: .color(.yellow))
            }
        }
        var pc = c
        if offline { pc.addFilter(.grayscale(1)) }
        if sleeping { pc.opacity = 0.9 }
        pc.draw(pc.resolve(Image(platformImage: image)), in: CGRect(x: -wid / 2, y: -hgt, width: wid, height: hgt))

        return CGRect(x: cx - wid / 2, y: groundY - 1 - hop - hgt * squash, width: wid, height: hgt * 0.5)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let a = anim, u = a.util, t = a.time
        let w = size.width, h = size.height
        let offline = mood == "offline"
        let sleeping = mood == "sleeping" || offline

        // Pastel sky that warms from lavender to peach-pink as the GPU heats up.
        let top = Color(hue: a.hue, saturation: offline ? 0 : 0.42, brightness: 0.34 + u * 0.1)
        let bottom = Color(hue: (a.hue + 0.05).truncatingRemainder(dividingBy: 1), saturation: offline ? 0 : 0.5, brightness: 0.16)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [top, bottom]), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        // Twinkly parallax stars.
        for i in 0..<20 {
            let d = Double(i)
            let depth = 0.2 + hash(d + 3) * 0.8
            let span = w * 1.2
            var sx = (hash(d) * span - a.scroll * 0.25 * depth).truncatingRemainder(dividingBy: span)
            if sx < 0 { sx += span }
            let sy = hash(d + 7) * (h - 50)
            let tw = 0.35 + 0.65 * abs(sin(t * (0.8 + depth) + d))
            let r = 0.6 + depth * 1.1
            ctx.fill(Path(ellipseIn: CGRect(x: sx, y: sy, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.6 * tw * depth)))
        }

        let groundY = h - 22
        let cx = w * (roomForBadges ? 0.56 : 0.5)  // a little right of center when the badges are showing
        // The character and its effects (speed lines, shadow, sweat, z's, hearts) are drawn a touch smaller,
        // scaled around the spot where it stands.
        var cg = ctx
        cg.translateBy(x: cx, y: groundY)
        cg.scaleBy(x: roomForBadges ? 0.9 : 1, y: roomForBadges ? 0.9 : 1)
        cg.translateBy(x: -cx, y: -groundY)

        // Rolling grassy hill + treadmill dashes.
        ctx.fill(Path(roundedRect: CGRect(x: -20, y: groundY, width: w + 40, height: 60), cornerRadius: 24),
                 with: .color(Color(hue: (a.hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.25, brightness: 0.3).opacity(0.7)))
        // Lane dashes scroll at the road's speed and stretch into streaks when the GPU is busy.
        let dash = 22.0
        let streak = 8 + 10 * u
        var x = -a.scroll.truncatingRemainder(dividingBy: dash)
        while x < w {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: groundY + 7, width: streak, height: 3), cornerRadius: 1.5),
                     with: .color(.white.opacity(0.22 + 0.13 * u)))
            x += dash
        }
        // Roadside grass tufts and little posts passing by, so the speed is easy to see.
        let span = 70.0
        var gx = -(a.scroll * 1.15).truncatingRemainder(dividingBy: span)
        var k = Int((a.scroll * 1.15 / span).rounded(.down))
        while gx < w + 10 {
            let r = hash(Double(k) * 7.3)
            let px = gx + r * 30
            let tuftY = groundY + 18
            if r < 0.35 {  // a small post with a light on top
                ctx.fill(Path(roundedRect: CGRect(x: px, y: tuftY - 6, width: 2.5, height: 9), cornerRadius: 1),
                         with: .color(.white.opacity(0.28)))
                ctx.fill(Path(ellipseIn: CGRect(x: px - 0.5, y: tuftY - 8, width: 3.5, height: 3.5)),
                         with: .color(Color(hue: (a.hue + r).truncatingRemainder(dividingBy: 1), saturation: 0.5, brightness: 1).opacity(0.7)))
            } else {  // a grass tuft, leaning back more the faster it goes
                let lean = 1.5 + 4 * u
                for b in 0..<3 {
                    var blade = Path()
                    let bx = px + Double(b) * 2.5
                    blade.move(to: CGPoint(x: bx, y: tuftY + 2))
                    blade.addQuadCurve(to: CGPoint(x: bx - lean, y: tuftY - 4 - Double(b % 2) * 1.5),
                                       control: CGPoint(x: bx + 0.5, y: tuftY - 1))
                    ctx.stroke(blade, with: .color(Color(red: 0.55, green: 0.85, blue: 0.55).opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            gx += span
            k += 1
        }

        // Swooshy speed lines.
        if u > 0.2 {
            for i in 0..<Int(u * 9) {
                let d = Double(i)
                let y = groundY - 58 + hash(d + 11) * 48
                let len = 14 + hash(d + 5) * 26
                let travel = (t * 300 * u + hash(d) * 200).truncatingRemainder(dividingBy: 120)
                let lx = cx - 46 - travel
                var p = Path()
                p.move(to: CGPoint(x: lx, y: y))
                p.addLine(to: CGPoint(x: lx - len, y: y))
                cg.stroke(p, with: .color(.white.opacity(0.5 * (1 - travel / 120))), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }

        let bob = sleeping ? sin(t * 1.6) * 1.5 : abs(sin(a.runPhase * .pi * 2)) * (2 + 5 * u)
        cg.fill(Path(ellipseIn: CGRect(x: cx - 30 + bob, y: groundY - 3, width: 60 - bob * 2, height: 7)), with: .color(.black.opacity(0.25)))

        let c: GraphicsContext
        let body: CGRect
        switch character {
        case .chippy:
            (c, body) = drawChippy(cg, cx: cx, groundY: groundY, bob: bob, sleeping: sleeping, offline: offline)
        case .bunny:
            (c, body) = (cg, drawBunny(cg, cx: cx, groundY: groundY, sleeping: sleeping, offline: offline))
        case .photo(let image):
            (c, body) = (cg, drawPhoto(cg, image, cx: cx, groundY: groundY, sleeping: sleeping, offline: offline))
        }
        // Sparkles rise from above the head (and above the bunny's hat).
        var sparkleTop = body.minY - 8
        if case .bunny = character { sparkleTop -= 22 }

        // Sweat drops.
        if u > 0.6 && !sleeping {
            for k in 0..<(u > 0.85 ? 2 : 1) {
                let p = (t * 1.3 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let dx = k == 0 ? body.maxX - 3 : body.minX + 3
                let dy = body.minY + 8 + p * 18
                var drop = Path()
                drop.move(to: CGPoint(x: dx, y: dy - 5))
                drop.addQuadCurve(to: CGPoint(x: dx, y: dy + 3), control: CGPoint(x: dx + 5, y: dy + 2))
                drop.addQuadCurve(to: CGPoint(x: dx, y: dy - 5), control: CGPoint(x: dx - 5, y: dy + 2))
                c.fill(drop, with: .color(Color(red: 0.6, green: 0.87, blue: 1).opacity(1 - p)))
            }
        }

        // Zzz while napping.
        if sleeping && !offline {
            for k in 0..<3 {
                let p = (t * 0.35 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                let txt = Text("z").font(.system(size: 9 + p * 9, weight: .heavy, design: .rounded)).foregroundColor(.white.opacity(1 - p))
                cg.draw(txt, at: CGPoint(x: body.maxX + 6 + p * 18 + sin(p * 6) * 3, y: body.minY - p * 34))
            }
        }

        // Hearts and stars (or AI glyphs) floating off the work.
        for p in a.particles {
            let o = max(0, p.life / p.maxLife)
            let pos = CGPoint(x: cx + p.x, y: sparkleTop + p.y)
            let col = Color(hue: p.hue, saturation: 0.45, brightness: 1).opacity(o)
            if let g = p.glyph {
                cg.draw(Text(g).font(.system(size: 6 + p.size * 1.5, weight: .bold, design: .rounded)).foregroundColor(col), at: pos)
            } else {
                cg.fill(heart(pos, p.size * 0.8), with: .color(col))
            }
        }

        if let badge {
            let txt = ctx.resolve(Text(badge).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.white))
            let sz = txt.measure(in: size)
            let r = CGRect(x: w - sz.width - 22, y: 32, width: sz.width + 14, height: sz.height + 6)
            ctx.fill(Path(roundedRect: r, cornerRadius: r.height / 2), with: .color(.white.opacity(0.18)))
            ctx.draw(txt, at: CGPoint(x: r.midX, y: r.midY))
        }
    }
}

/// The badges are drawn at 80% of their design size, so they stay clear of the character.
let badgeScale = 0.8

/// A little thermometer friend for the scene's top-left corner: the GPU temperature, with a face that
/// shivers when it's cold, sweats when it's toasty and steams when it's hot. Click to switch °C / °F.
struct ThermoBuddy: View {
    private let k: Double  // drawn at this size directly (not scaled afterwards) so text stays sharp
    let celsius: Double
    let time: Double
    let mini: Bool
    @AppStorage("tempFahrenheit") private var fahrenheit = false

    /// `mini`: a small chip (little thermometer + temperature) for the compact view.
    init(celsius: Double, time: Double, mini: Bool = false) {
        self.celsius = celsius
        self.time = time
        self.mini = mini
        self.k = mini ? 0.42 : badgeScale
    }

    private var degrees: String {
        fahrenheit ? "\(Int((celsius * 9 / 5 + 32).rounded()))°F" : "\(Int(celsius.rounded()))°C"
    }

    /// "55°C · warm" (or °F, following the badge's setting), for places that show the temperature as text.
    static func text(_ c: Double, fahrenheit: Bool) -> String {
        let t = fahrenheit ? "\(Int((c * 9 / 5 + 32).rounded()))°F" : "\(Int(c.rounded()))°C"
        let word = c < 40 ? "chilly" : c < 55 ? "comfy" : c < 70 ? "warm" : c < 85 ? "toasty" : "spicy!"
        return "\(t) · \(word)"
    }

    private enum Feel { case chilly, comfy, warm, toasty, spicy }
    private var feel: Feel {
        switch celsius {
        case ..<40: return .chilly
        case ..<55: return .comfy
        case ..<70: return .warm
        case ..<85: return .toasty
        default: return .spicy
        }
    }
    private var label: String {
        switch feel {
        case .chilly: return "chilly ❄︎"
        case .comfy: return "comfy"
        case .warm: return "warm"
        case .toasty: return "toasty"
        case .spicy: return "spicy!"
        }
    }
    private var color: Color {
        switch feel {
        case .chilly: return Color(red: 0.5, green: 0.78, blue: 1)
        case .comfy: return Color(red: 0.45, green: 0.92, blue: 0.62)
        case .warm: return Color(red: 1, green: 0.82, blue: 0.38)
        case .toasty: return Color(red: 1, green: 0.58, blue: 0.3)
        case .spicy: return Color(red: 1, green: 0.32, blue: 0.38)
        }
    }

    var body: some View {
        if mini { miniBody } else { fullBody }
    }

    private var miniBody: some View {
        HStack(spacing: 2) {
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: 26 * k, height: 42 * k)
            Text(degrees)
                .font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundColor(color)
                .lineLimit(1).fixedSize()
        }
        .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 1)
        .background(Capsule().fill(.white.opacity(0.08)))
        .contentShape(Capsule())
        .onTapGesture { fahrenheit.toggle() }
        .help("GPU temperature: \(degrees), \(label). Click to switch °C / °F.")
    }

    private var fullBody: some View {
        HStack(spacing: 4 * k) {
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: 26 * k, height: 42 * k)
            VStack(alignment: .leading, spacing: -1 * k) {
                Text(fahrenheit ? "\(Int((celsius * 9 / 5 + 32).rounded()))°F" : "\(Int(celsius.rounded()))°C")
                    .font(.system(size: 16 * k, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white)
                Text(label)
                    .font(.system(size: 9.5 * k, weight: .black, design: .rounded))
                    .foregroundColor(color)
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)  // as wide as the wider badge (see the stack in ContentView)
        .padding(.leading, 4 * k).padding(.trailing, 10 * k).padding(.vertical, 3 * k)
        .background(Capsule().fill(Color(red: 0.08, green: 0.07, blue: 0.12).opacity(0.82)))
        .overlay(Capsule().stroke(color.opacity(0.35 + (feel == .spicy ? 0.3 * sin(time * 8) : 0)), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { fahrenheit.toggle() }
        .help("GPU temperature (average of the chip's GPU sensors), \(label). Click to switch °C / °F.")
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        ctx.scaleBy(x: k, y: k)
        let t = time
        // Shiver when chilly, a slow happy sway otherwise.
        let dx = feel == .chilly ? sin(t * 45) * 0.7 : sin(t * 1.6) * 0.5
        ctx.translateBy(x: dx, y: 0)
        let cx = 11.0
        let tube = CGRect(x: cx - 4, y: 6, width: 8, height: 24)
        let bulbC = CGPoint(x: cx, y: 33), bulbR = 7.5
        let glass = Color.white.opacity(0.9)

        // Glass: tube and bulb.
        ctx.fill(Path(roundedRect: tube, cornerRadius: 4), with: .color(glass))
        ctx.fill(Path(ellipseIn: CGRect(x: bulbC.x - bulbR, y: bulbC.y - bulbR, width: bulbR * 2, height: bulbR * 2)), with: .color(glass))

        // Mercury: rises from 30 °C (empty) to 95 °C (full), with a little wobble on top.
        let frac = min(1, max(0.08, (celsius - 30) / 65)) + 0.03 * sin(t * 3)
        let inner = tube.insetBy(dx: 2, dy: 2)
        let topY = inner.maxY - inner.height * frac
        ctx.fill(Path(roundedRect: CGRect(x: inner.minX, y: topY, width: inner.width, height: inner.maxY - topY + 4),
                      cornerRadius: 2), with: .color(color))
        let br = bulbR - 2
        ctx.fill(Path(ellipseIn: CGRect(x: bulbC.x - br, y: bulbC.y - br, width: br * 2, height: br * 2)), with: .color(color))
        // Tick marks on the tube.
        for i in 1...3 {
            let y = tube.minY + Double(i) * tube.height / 4
            var tick = Path(); tick.move(to: CGPoint(x: tube.maxX - 2.5, y: y)); tick.addLine(to: CGPoint(x: tube.maxX, y: y))
            ctx.stroke(tick, with: .color(.black.opacity(0.25)), lineWidth: 0.7)
        }

        // Face on the bulb: eyes blink now and then, cheeks blush, mouth shows the mood.
        let ink = Color(red: 0.2, green: 0.12, blue: 0.25)
        let blink = (t.truncatingRemainder(dividingBy: 3.7)) < 0.12
        for ex in [-2.6, 2.6] {
            let e = CGPoint(x: bulbC.x + ex, y: bulbC.y - 1.5)
            if blink || feel == .spicy {
                // closed / squeezed eyes: little arcs
                var p = Path(); p.move(to: CGPoint(x: e.x - 1.3, y: e.y)); p.addLine(to: CGPoint(x: e.x + 1.3, y: e.y))
                ctx.stroke(p, with: .color(ink), lineWidth: 1)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - 1, y: e.y - 1.2, width: 2, height: 2.4)), with: .color(ink))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 1.6 + (ex > 0 ? 0.9 : -0.9), y: e.y + 1.8, width: 2.4, height: 1.4)),
                     with: .color(Color(red: 1, green: 0.45, blue: 0.6).opacity(0.75)))
        }
        var mouth = Path()
        let m = CGPoint(x: bulbC.x, y: bulbC.y + 2.6)
        switch feel {
        case .chilly:  // wobbly, chattering teeth
            mouth.move(to: CGPoint(x: m.x - 2.2, y: m.y))
            for i in 1...4 { mouth.addLine(to: CGPoint(x: m.x - 2.2 + Double(i) * 1.1, y: m.y + (i % 2 == 0 ? 0 : 0.8))) }
            ctx.stroke(mouth, with: .color(ink), lineWidth: 0.8)
        case .comfy, .warm:  // smile
            mouth.addArc(center: CGPoint(x: m.x, y: m.y - 1), radius: 1.8, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            ctx.stroke(mouth, with: .color(ink), lineWidth: 0.9)
        case .toasty:  // little panting "o"
            let r = 0.9 + 0.3 * sin(t * 9)
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - r, y: m.y - r, width: r * 2, height: r * 2.2)), with: .color(ink))
        case .spicy:  // wide open, tongue out
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - 1.8, y: m.y - 1.2, width: 3.6, height: 3)), with: .color(ink))
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - 1, y: m.y + 0.4, width: 2, height: 1.4)), with: .color(Color(red: 1, green: 0.5, blue: 0.6)))
        }

        // Weather around it.
        switch feel {
        case .chilly:  // a snowflake drifting down
            let y = (t * 6).truncatingRemainder(dividingBy: 30)
            ctx.draw(Text("❄︎").font(.system(size: 6)).foregroundColor(.white.opacity(0.8)), at: CGPoint(x: 21, y: 4 + y))
        case .toasty, .spicy:  // sweat drops sliding down the tube
            for k in 0..<(feel == .spicy ? 2 : 1) {
                let ph = (t * 0.9 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let d = CGPoint(x: tube.maxX + 2.5 + Double(k) * 2.5, y: 9 + ph * 16)
                var drop = Path()
                drop.move(to: CGPoint(x: d.x, y: d.y - 2.2))
                drop.addQuadCurve(to: CGPoint(x: d.x, y: d.y + 1.4), control: CGPoint(x: d.x + 2.2, y: d.y + 0.8))
                drop.addQuadCurve(to: CGPoint(x: d.x, y: d.y - 2.2), control: CGPoint(x: d.x - 2.2, y: d.y + 0.8))
                ctx.fill(drop, with: .color(Color(red: 0.55, green: 0.85, blue: 1).opacity(1 - ph * 0.7)))
            }
            if feel == .spicy {  // steam curling off the top
                for k in 0..<2 {
                    let ph = (t * 0.7 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                    var s = Path()
                    let x0 = cx - 2 + Double(k) * 4, y0 = tube.minY - 1 - ph * 6
                    s.move(to: CGPoint(x: x0, y: y0))
                    s.addCurve(to: CGPoint(x: x0, y: y0 - 5), control1: CGPoint(x: x0 + 2.5, y: y0 - 1.5), control2: CGPoint(x: x0 - 2.5, y: y0 - 3.5))
                    ctx.stroke(s, with: .color(.white.opacity(0.6 * (1 - ph))), lineWidth: 1)
                }
            }
        default:
            break
        }
    }
}

/// A little stopwatch friend under the thermometer: how long the model took to start answering (time to first
/// token). Its face and hand speed follow the time: zippy and spinning when it's fast, sleepy when it's slow.
/// The numbers follow the latest request's model and prompt-cache setting (gpud starts the average over when they change).
struct StopwatchBuddy: View {
    private let k: Double  // drawn at this size directly (not scaled afterwards) so text stays sharp
    let tokens: Snapshot.Tokens
    let time: Double
    let mini: Bool

    /// `mini`: a small chip (little stopwatch + first-token time) for the compact view.
    init(tokens: Snapshot.Tokens, time: Double, mini: Bool = false) {
        self.tokens = tokens
        self.time = time
        self.mini = mini
        self.k = mini ? 0.5 : badgeScale
    }

    private var seconds: Double { tokens.ttft_s ?? tokens.ttft_avg_s ?? 0 }
    private enum Feel { case zippy, quick, thinking, slow }
    private var feel: Feel {
        switch seconds {
        case ..<1: return .zippy
        case ..<5: return .quick
        case ..<20: return .thinking
        default: return .slow
        }
    }
    private var label: String {
        switch feel {
        case .zippy: return "zippy!"
        case .quick: return "quick"
        case .thinking: return "thinking…"
        case .slow: return "sloooow"
        }
    }
    private var color: Color {
        switch feel {
        case .zippy: return Color(red: 0.45, green: 0.95, blue: 0.6)
        case .quick: return Color(red: 0.55, green: 0.9, blue: 0.85)
        case .thinking: return Color(red: 1, green: 0.7, blue: 0.35)
        case .slow: return Color(red: 1, green: 0.45, blue: 0.55)
        }
    }
    private var helpText: String {
        var lines = ["Time to first token: how long \(tokens.ttft_model ?? "the model") took to start answering, "
                     + "\(ttftText(seconds)) for the latest request."]
        if let p = tokens.ttft_prompt_tokens, p > 0 {
            let n = NumberFormatter.localizedString(from: NSNumber(value: Int(p)), number: .decimal)
            var line = "📖 It read \(n) prompt tokens before the first token"
            if seconds > 0 {
                line += " (about \(NumberFormatter.localizedString(from: NSNumber(value: Int(p / seconds)), number: .decimal)) tokens/s)"
            }
            lines.append(line + ". Longer prompts mean a longer wait.")
        }
        if let c = tokens.ttft_cache {
            lines.append("⚡ Prompt cache: \(c ? "on, so repeated text is read faster" : "off").")
        }
        if let avg = average {
            lines.append("Average \(ttftText(avg)) over \(Int(tokens.ttft_samples ?? 0)) recent requests with the same model "
                         + "and cache setting. It starts over when either changes.")
        }
        return lines.joined(separator: "\n")
    }

    /// The average, shown only when it covers more than the latest request.
    private var average: Double? {
        guard tokens.ttft_s != nil, (tokens.ttft_samples ?? 0) > 1 else { return nil }
        return tokens.ttft_avg_s
    }

    var body: some View {
        if mini { miniBody } else { fullBody }
    }

    private var miniBody: some View {
        HStack(spacing: 2) {
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: 26 * k, height: 34 * k)
            Text(ttftText(seconds))
                .font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundColor(color)
                .lineLimit(1).fixedSize()
            if let since = tokens.ttft_pending_since {  // a request is running: count up live
                Text("⏳\(ttftText(max(0, Date().timeIntervalSince1970 - since)))")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, 3).padding(.trailing, 6).padding(.vertical, 1)
        .background(Capsule().fill(.white.opacity(0.08)))
        .help(helpText)
    }

    private var fullBody: some View {
        HStack(spacing: 4 * k) {
            Canvas { ctx, size in draw(&ctx, size) }
                .frame(width: 26 * k, height: 34 * k)
            VStack(alignment: .leading, spacing: -1 * k) {
                HStack(spacing: 3 * k) {
                    Text("1ST TOKEN")
                        .font(.system(size: 7.5 * k, weight: .black, design: .rounded))
                        .foregroundColor(.white.opacity(0.72))
                    if let c = tokens.ttft_cache {  // tiny bolt: prompt cache on (filled) or off (crossed out)
                        Image(systemName: c ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 5.5 * k, weight: .heavy))
                            .foregroundColor(c ? .black.opacity(0.75) : .white.opacity(0.6))
                            .frame(width: 10 * k, height: 10 * k)
                            .background(Circle().fill(c ? color : .white.opacity(0.14)))
                    }
                }
                Text(ttftText(seconds))
                    .font(.system(size: 16 * k, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: seconds)
                Text(label)
                    .font(.system(size: 9.5 * k, weight: .black, design: .rounded))
                    .foregroundColor(color)
                // How much it read before answering: the prompt is what the first-token wait is spent on.
                if let p = tokens.ttft_prompt_tokens, p > 0 {
                    HStack(spacing: 2.5 * k) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 9 * k, weight: .bold))
                            .foregroundColor(color)
                        Text("\(shortCount(p)) read")
                            .font(.system(size: 11 * k, weight: .heavy, design: .rounded)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.95))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: p)
                    }
                    .padding(.top, 1.5 * k)
                }
                // A request is running now: count up live until its first-token time comes in.
                if let since = tokens.ttft_pending_since {
                    let waited = max(0, Date().timeIntervalSince1970 - since)
                    HStack(spacing: 2.5 * k) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 8.5 * k, weight: .bold))
                            .foregroundColor(color)
                            .rotationEffect(.degrees(waited.truncatingRemainder(dividingBy: 2) < 1 ? 0 : 180))
                        Text("now \(ttftText(waited))")
                            .font(.system(size: 9.5 * k, weight: .heavy, design: .rounded)).monospacedDigit()
                            .foregroundColor(.white.opacity(0.95))
                    }
                    .help("A new request is running. Its first-token time shows up here when it finishes.")
                }
                if let avg = average {
                    Text("avg \(ttftText(avg))")
                        .font(.system(size: 8.5 * k, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundColor(.white.opacity(0.68))
                }
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)  // as wide as the wider badge (see the stack in ContentView)
        .padding(.leading, 4 * k).padding(.trailing, 10 * k).padding(.vertical, 4 * k)
        .background(RoundedRectangle(cornerRadius: 16 * k).fill(Color(red: 0.08, green: 0.07, blue: 0.12).opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 16 * k).stroke(color.opacity(0.4), lineWidth: 1))
        .help(helpText)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        ctx.scaleBy(x: k, y: k)
        let t = time
        let c = CGPoint(x: 13, y: 19), r = 10.0
        let ink = Color(red: 0.2, green: 0.12, blue: 0.25)
        // A happy hop when it's zippy, a slow droop when it's slow.
        let dy = feel == .zippy ? -abs(sin(t * 7)) * 1.6 : (feel == .slow ? sin(t * 1.2) * 0.6 : 0)
        ctx.translateBy(x: 0, y: dy)

        // Speed lines behind it when zippy.
        if feel == .zippy {
            for k in 0..<3 {
                let ph = (t * 3 + Double(k) * 0.33).truncatingRemainder(dividingBy: 1)
                var l = Path()
                let y = c.y - 4 + Double(k) * 4
                l.move(to: CGPoint(x: 2 - ph * 2, y: y)); l.addLine(to: CGPoint(x: 5 - ph * 2, y: y))
                ctx.stroke(l, with: .color(color.opacity(1 - ph)), lineWidth: 1)
            }
        }
        // Crown and side button.
        ctx.fill(Path(roundedRect: CGRect(x: c.x - 2.5, y: c.y - r - 4.5, width: 5, height: 3), cornerRadius: 1),
                 with: .color(.white.opacity(0.9)))
        ctx.fill(Path(CGRect(x: c.x - 1, y: c.y - r - 2, width: 2, height: 2.5)), with: .color(.white.opacity(0.9)))
        var side = Path()
        side.move(to: CGPoint(x: c.x + r * 0.62, y: c.y - r * 0.85)); side.addLine(to: CGPoint(x: c.x + r * 0.9, y: c.y - r * 1.1))
        ctx.stroke(side, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

        // Face, with a colored ring that fills up to 30 s.
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.92)))
        var ring = Path()
        ring.addArc(center: c, radius: r - 1.2, startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * min(1, max(0.06, seconds / 30))), clockwise: false)
        ctx.stroke(ring, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // The hand: spins fast when zippy, creeps when slow.
        let speed: Double = tokens.ttft_pending_since != nil ? 6 : ([Feel.zippy: 9, .quick: 4, .thinking: 1.5, .slow: 0.4][feel] ?? 1)
        let ang = t * speed
        var hand = Path()
        hand.move(to: c); hand.addLine(to: CGPoint(x: c.x + sin(ang) * (r - 4), y: c.y - cos(ang) * (r - 4)))
        ctx.stroke(hand, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 1, lineCap: .round))

        // Eyes, cheeks and mouth.
        let blink = (t.truncatingRemainder(dividingBy: 4.3)) < 0.12
        for ex in [-3.0, 3.0] {
            let e = CGPoint(x: c.x + ex, y: c.y - 1)
            switch feel {
            case .zippy:  // happy ^ ^ eyes
                var p = Path()
                p.move(to: CGPoint(x: e.x - 1.3, y: e.y + 0.6)); p.addLine(to: CGPoint(x: e.x, y: e.y - 0.7))
                p.addLine(to: CGPoint(x: e.x + 1.3, y: e.y + 0.6))
                ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            case .slow:  // sleepy, half-closed
                var p = Path()
                p.addArc(center: CGPoint(x: e.x, y: e.y - 0.3), radius: 1.3, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
                ctx.stroke(p, with: .color(ink), lineWidth: 0.9)
            case .thinking:  // looking up and to the side
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - 0.6, y: e.y - 2, width: 1.9, height: 2.2)), with: .color(ink))
            case .quick:
                if blink {
                    var p = Path(); p.move(to: CGPoint(x: e.x - 1.2, y: e.y)); p.addLine(to: CGPoint(x: e.x + 1.2, y: e.y))
                    ctx.stroke(p, with: .color(ink), lineWidth: 0.9)
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: e.x - 1, y: e.y - 1.2, width: 2, height: 2.4)), with: .color(ink))
                }
            }
            ctx.fill(Path(ellipseIn: CGRect(x: e.x - 1.2 + (ex > 0 ? 0.8 : -0.8), y: e.y + 2, width: 2.4, height: 1.3)),
                     with: .color(Color(red: 1, green: 0.45, blue: 0.6).opacity(0.7)))
        }
        let m = CGPoint(x: c.x, y: c.y + 3.6)
        var mouth = Path()
        switch feel {
        case .zippy, .quick:  // smile (big one when zippy)
            let mr = feel == .zippy ? 2.2 : 1.6
            mouth.addArc(center: CGPoint(x: m.x, y: m.y - mr * 0.6), radius: mr, startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            ctx.stroke(mouth, with: .color(ink), lineWidth: 0.9)
        case .thinking:  // a little sideways "hmm"
            mouth.move(to: CGPoint(x: m.x - 1.4, y: m.y + 0.3)); mouth.addLine(to: CGPoint(x: m.x + 1.4, y: m.y - 0.3))
            ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        case .slow:  // yawning "o"
            let yr = 0.8 + 0.4 * max(0, sin(t * 1.5))
            ctx.fill(Path(ellipseIn: CGRect(x: m.x - yr, y: m.y - yr, width: yr * 2, height: yr * 2.2)), with: .color(ink))
        }

        // Thought dots when thinking, a floating "z" when slow.
        if feel == .thinking {
            for k in 0..<3 {
                let on = Int(t * 2.5) % 4 > k
                ctx.fill(Path(ellipseIn: CGRect(x: c.x + r - 1 + Double(k) * 2.6, y: c.y - r - 3 - Double(k) * 1.2, width: 1.8, height: 1.8)),
                         with: .color(.white.opacity(on ? 0.85 : 0.2)))
            }
        } else if feel == .slow {
            let ph = (t * 0.5).truncatingRemainder(dividingBy: 1)
            ctx.draw(Text("z").font(.system(size: 6 + ph * 2, weight: .heavy, design: .rounded)).foregroundColor(.white.opacity(1 - ph)),
                     at: CGPoint(x: c.x + r + 1 + ph * 3, y: c.y - r - ph * 6))
        }
    }
}

struct CoreGrid: View {
    let anim: Anim
    let cores: Int

    var body: some View {
        Canvas { ctx, size in
            let n = max(cores, 1)
            let rows = n > 20 ? 2 : 1
            let cols = Int((Double(n) / Double(rows)).rounded(.up))
            let gap = 3.0
            let cw = (size.width - gap * Double(cols - 1)) / Double(cols)
            let ch = (size.height - gap * Double(rows - 1)) / Double(rows)
            for i in 0..<n {
                let d = Double(i)
                let tick = floor(anim.time * (3 + anim.util * 9) + hash(d) * 10)
                let lit = hash(d * 7.1 + tick * 1.3) < anim.util
                let r = CGRect(x: Double(i % cols) * (cw + gap), y: Double(i / cols) * (ch + gap), width: cw, height: ch)
                let color = lit ? Color(hue: (anim.hue + hash(d) * 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.65, brightness: 1)
                                : Color.white.opacity(0.08)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(color))
            }
        }
    }
}

struct MemoryTank: View {
    let anim: Anim

    var body: some View {
        Canvas { ctx, size in
            let box = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7)
            ctx.fill(box, with: .color(.white.opacity(0.08)))
            var c = ctx
            c.clip(to: box)
            let fillX = size.width * anim.mem
            var liquid = Path()
            liquid.move(to: .zero)
            var y = 0.0
            while y <= size.height {
                liquid.addLine(to: CGPoint(x: fillX + sin(y * 0.35 + anim.wave * 2) * 3 * min(1, anim.mem * 10), y: y))
                y += 2
            }
            liquid.addLine(to: CGPoint(x: 0, y: size.height))
            liquid.closeSubpath()
            c.fill(liquid, with: .linearGradient(
                Gradient(colors: [Color(red: 0.35, green: 0.55, blue: 1), Color(red: 0.7, green: 0.4, blue: 1)]),
                startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)))
            // Bubbles.
            for i in 0..<6 {
                let d = Double(i)
                let p = (anim.time * (0.3 + hash(d) * 0.4) + hash(d + 2)).truncatingRemainder(dividingBy: 1)
                let bx = hash(d + 9) * fillX
                c.fill(Path(ellipseIn: CGRect(x: bx, y: size.height * (1 - p), width: 3, height: 3)), with: .color(.white.opacity(0.35 * (1 - p))))
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / 59
            let start = size.width - step * Double(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: start + Double(i) * step, y: size.height * (1 - v / 100))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: start, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [Color.pink.opacity(0.45), .clear]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(.pink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

/// Tokens generated (written) and used (prompt tokens read) by local LLM servers over 24h.
struct TokenCard: View {
    let tokens: Snapshot.Tokens?
    let time: Double
    var onTap: (() -> Void)?

    private let gold = Color(red: 1, green: 0.85, blue: 0.5)

    var body: some View {
        VStack(spacing: 4) {
            // One row per loaded LLM: its name and speed, and below it the tokens it read and wrote (24 h).
            // The speed stays after a request ends (dimmed, "last") until the next one; a row goes when the model
            // is unloaded.
            if let llms = tokens?.llms {
                if llms.isEmpty {
                    Text("No LLM loaded right now.")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(llms) { llmRow($0) }
                HStack(spacing: 4) {
                    Text("ALL · 24h").font(.system(size: 8, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.45))
                    Spacer(minLength: 2)
                    Text("📖 \(tokens.map { shortCount($0.prompt_24h) } ?? "--") read   ✍️ \(tokens.map { shortCount($0.generated_24h) } ?? "--") generated")
                        .font(.system(size: 9, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundColor(gold.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 4)
            } else {
                // Older gpud: one banner and the two totals.
                HStack(spacing: 5) {
                    Image(systemName: "cpu").font(.system(size: 9, weight: .semibold))
                    Text(bannerModel.map(shortModelName) ?? "No LLM answering yet")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(gold.opacity(0.15)))
                HStack(spacing: 8) {
                    stat("📖 READ · 24h", tokens?.prompt_24h, live: nil)
                    stat("✍️ GENERATED · 24h", tokens?.generated_24h, live: tokens.flatMap { $0.speed_tok_s > 0 ? "⚡\(Int($0.speed_tok_s)) tok/s" : nil })
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .help(sourcesHelp + "\n\nClick for the Token Ledger (⌘L): today, this week, month, YTD, all time.")
    }

    private func llmRow(_ l: Snapshot.Tokens.LLM) -> some View {
        let live = (l.in_flight ?? 0) > 0 && (l.tok_s ?? 0) > 0
        let icon = l.server == "Kapitsa" ? "⚡" : l.server == "Ollama" ? "🦙" : "🧠"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(icon).font(.system(size: 10))
                Text(shortModelName(l.model.isEmpty ? l.server : l.model))
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .help("\(l.model) on \(l.server)")
                Text(l.server).font(.system(size: 8.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.45))
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if live {
                    Text("⚡\(Int(l.tok_s ?? 0)) tok/s").font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundColor(gold).lineLimit(1).fixedSize()
                        .opacity(0.65 + 0.35 * sin(time * 6))
                } else if let v = l.last_tok_s {
                    Text("\(v >= 100 ? String(Int(v)) : String(format: "%.1f", v)) tok/s").font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundColor(gold.opacity(0.75)).lineLimit(1).fixedSize()
                        .help("Speed of its last answer" + (l.last_tok_at.map { ", \(agoText($0))" } ?? "") + ". Stays until the next one.")
                } else {
                    Text("idle").font(.system(size: 9, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.4))
                }
            }
            HStack(spacing: 8) {
                Text("📖 \(shortCount(l.prompt_24h ?? 0)) read")
                Text("✍️ \(shortCount(l.generated_24h ?? 0)) generated")
                Spacer(minLength: 0)
                if !live, l.last_tok_s != nil, let at = l.last_tok_at {
                    Text("last · " + agoText(at)).foregroundColor(.white.opacity(0.4))
                }
            }
            .font(.system(size: 8.5, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundColor(.white.opacity(0.7))
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(gold.opacity(live ? 0.22 : 0.12)))
    }

    private func activeModel(_ src: [Snapshot.Tokens.Source]) -> String? {
        guard let active = src.first(where: { $0.tok_s > 0 }) else { return nil }
        return active.model.isEmpty ? active.name : active.model
    }

    /// The model writing right now, or else the one that answered last (so the first-token time stays visible).
    private var bannerModel: String? {
        if let src = tokens?.sources, let m = activeModel(src) { return m }
        return tokens?.ttft_model
    }

    private func stat(_ title: String, _ value: Double?, live: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8.5, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
                .lineLimit(1).fixedSize()
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value.map(shortCount) ?? "--")
                    .font(.system(size: 16, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundColor(value ?? 0 > 0 ? gold : .white.opacity(0.5))
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 0)
                if let live {
                    Text(live).font(.system(size: 8.5, weight: .heavy, design: .rounded)).foregroundColor(gold)
                        .lineLimit(1).fixedSize()
                        .opacity(0.65 + 0.35 * sin(time * 6))
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(live == nil ? 0.06 : 0.12)))
    }

    private var sourcesHelp: String {
        guard let src = tokens?.sources, !src.isEmpty else {
            return "No local LLM servers found.\nSupported: MLX servers with /metrics, llama.cpp (--metrics), vLLM, SGLang.\nOllama doesn't report token counts."
        }
        return src.map { s in
            let port = s.url.split(separator: ":").last.map(String.init) ?? ""
            var line = "\(s.name) :\(port)\(s.model.isEmpty ? "" : " · \(s.model)")"
            if let g = s.generated_total, let p = s.prompt_total {
                line += "\n   \(shortCount(g)) generated · \(shortCount(p)) used since server start"
            }
            if let t = s.ttft_s ?? s.ttft_avg_s {
                line += "\n   first token in \(ttftText(t))" + (s.ttft_s != nil ? s.ttft_avg_s.map { " (avg \(ttftText($0)))" } ?? "" : " on average")
            }
            return line
        }.joined(separator: "\n")
    }
}

/// One request to the local LLM server, as gpud's request log saw it.
struct LLMRequest: Decodable, Identifiable {
    let id: String
    let started: Double
    let ip: String?
    let agent: String?
    let icon: String?
    let who: String?          // this Mac's program (curl, node…) or the device's name
    let app: String?          // the app that program runs in (iTerm, Visual Studio Code…)
    let local: Bool?
    let model: String?
    let snippet: String?      // first 100 characters of the user's message, when snippets are on
    let prompt_tokens: Double?
    let output_tokens: Double?
    let est_tokens: Double?        // prompt size guessed from the request's length, when the answer didn't say
    let output_estimated: Bool?    // answer size counted from the streamed pieces
    let live_tokens: Double?       // written so far, while it's answering
    let server: String?            // the LLM server the router sent it to
    let ttft: Double?
    let seconds: Double?
    let status: Int?

    /// "28.9K", or "~29K" when estimated.
    var readText: String? { prompt_tokens.map(shortCount) ?? est_tokens.map { "~" + shortCount($0) } }
    var wroteText: String? { output_tokens.map { (output_estimated == true ? "~" : "") + shortCount($0) } }
    var readKey: Double { prompt_tokens ?? est_tokens ?? -1 }
    let state: String?        // sending, waiting, answering, done, cancelled, blocked, error
    let path: String?

    var running: Bool { ["sending", "waiting", "answering"].contains(state ?? "") }

    /// "curl in iTerm", "MacBook-Pro", "10.0.2.126".
    var caller: String {
        if local == true {
            let w = who ?? "this Mac"
            if let app, !app.isEmpty, app.lowercased() != w.lowercased() { return "\(w) in \(app)" }
            return w
        }
        return who ?? ip ?? "?"
    }
}

/// Who's using the local LLM server: requests running now (live) and the latest ones.
struct RequestsCard: View {
    let requests: Snapshot.LLMRequests
    let time: Double
    var onOpenLog: (() -> Void)?

    private let green = Color(red: 0.45, green: 0.95, blue: 0.6)
    private let orange = Color(red: 1, green: 0.62, blue: 0.35)

    private var rows: [LLMRequest] {
        Array((requests.active + requests.recent).prefix(max(3, requests.active.count)))
    }

    var body: some View {
        VStack(spacing: 4) {
            if rows.isEmpty {
                Text("No requests yet. They show up here as soon as an app asks your LLM something.")
                    .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(rows) { row($0) }
            if let onOpenLog {
                Button(action: onOpenLog) {
                    Text("📜 Open the request log").font(.system(size: 9.5, weight: .heavy, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Every request from the last days: who, what, sizes and timings (⌘R)")
            }
        }
    }

    private func row(_ r: LLMRequest) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(r.icon ?? "❔").font(.system(size: 14))
                .frame(width: 20)
                .scaleEffect(r.state == "answering" ? 1 + 0.08 * sin(time * 8) : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(r.agent ?? "unknown").font(.system(size: 10, weight: .heavy, design: .rounded))
                        .lineLimit(1).fixedSize()
                    Text("· " + r.caller).font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    badge(r)
                }
                if let sn = r.snippet, !sn.isEmpty {
                    Text("“\(sn)”").font(.system(size: 9, weight: .regular, design: .rounded)).italic()
                        .foregroundColor(.white.opacity(0.8)).lineLimit(1).truncationMode(.tail)
                }
                if let m = r.model, !m.isEmpty {
                    Text("🧠 " + shortModelName(m) + (r.server.map { " · \($0)" } ?? ""))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.75)).lineLimit(1).minimumScaleFactor(0.7)
                }
                if !details(r).isEmpty {
                    Text(details(r)).font(.system(size: 8.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor(Color(red: 1, green: 0.85, blue: 0.5).opacity(0.85))
                        .lineLimit(1).minimumScaleFactor(0.65)
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(r.running ? 0.12 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(r.running ? green.opacity(0.35) : .clear, lineWidth: 1))
        .help(helpText(r))
    }

    @ViewBuilder private func badge(_ r: LLMRequest) -> some View {
        let now = Date().timeIntervalSince1970
        switch r.state ?? "" {
        case "sending", "waiting":
            label("⏳ reading \(ttftText(max(0, now - r.started)))", orange)
        case "answering":
            label("✍️ answering \(ttftText(max(0, now - r.started)))", green).opacity(0.7 + 0.3 * sin(time * 6))
        case "blocked": label("⛔ blocked", .red)
        case "cancelled": label("✋ stopped · \(agoText(r.started))", .white.opacity(0.5))
        case "error": label("⚠️ error \(r.status.map(String.init) ?? "")", orange)
        default: label(agoText(r.started), .white.opacity(0.5))
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 8.5, weight: .heavy, design: .rounded)).monospacedDigit()
            .foregroundColor(color).lineLimit(1).fixedSize()
    }

    /// The token line: read, written, writing speed, first-token time.
    private func details(_ r: LLMRequest) -> String {
        var parts: [String] = []
        if let p = r.readText { parts.append("📖 \(p)") }
        let now = Date().timeIntervalSince1970
        if r.running, let n = r.live_tokens, n > 0 {
            parts.append("✍️ \(shortCount(n))")
            if let t = r.ttft, now - r.started - t > 0.2 { parts.append("⚡\(Int(n / (now - r.started - t))) tok/s") }
        } else if let o = r.wroteText {
            parts.append("✍️ \(o)")
            if let n = r.output_tokens, n >= 5, let s = r.seconds {
                let gen = (r.ttft.map { s - $0 > 0.2 ? s - $0 : s }) ?? s
                if gen > 0.05 { parts.append("⚡\(Int(n / gen)) tok/s") }
            }
        }
        if let t = r.ttft { parts.append("⏱ \(ttftText(t))") }
        if parts.isEmpty, r.model == nil { return r.path ?? "" }
        return parts.joined(separator: "  ")
    }

    private func helpText(_ r: LLMRequest) -> String {
        var lines = ["\(r.agent ?? "unknown") · \(r.caller)"]
        if let ip = r.ip { lines.append("From \(ip)\(r.local == true ? " (this Mac)" : "")") }
        lines.append("Started \(clockText(r.started))" + (r.path.map { " · \($0)" } ?? ""))
        if let m = r.model { lines.append("Model: \(m)") }
        if let p = r.prompt_tokens { lines.append("Read \(Int(p)) tokens" + (r.ttft.map { ", first token after \(ttftText($0))" } ?? "")) }
        if let o = r.output_tokens { lines.append("Wrote \(Int(o)) tokens" + (r.seconds.map { " · \(ttftText($0)) in all" } ?? "")) }
        if let sn = r.snippet { lines.append("“\(sn)”") }
        if r.state == "blocked" { lines.append("Refused: not on the allow list, or a missing API key (Settings).") }
        return lines.joined(separator: "\n")
    }
}

/// Live chip power and how much energy each token takes.
struct PowerCard: View {
    let power: Snapshot.Power?

    private let orange = Color(red: 1, green: 0.62, blue: 0.35)

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                stat("⚡ GPU", power?.gpu_w.map { String(format: $0 < 10 ? "%.1f W" : "%.0f W", $0) },
                     power?.gpu_peak_w.map { "peak " + String(format: $0 < 10 ? "%.1f W" : "%.0f W", $0) })
                stat("🔌 CHIP", power?.soc_w.map { String(format: "%.0f W", $0) },
                     power?.system_w.map { "whole Mac \(Int($0)) W" } ?? power?.cpu_w.map { "CPU \(Int($0)) W" })
                stat("🍃 PER TOKEN", perToken, perTokenSub)
            }
        }
        .help(breakdown)
    }

    private var perToken: String? {
        if let j = power?.j_per_token { return String(format: "%.2f J", j) }
        if let j = power?.j_per_token_24h { return String(format: "%.2f J", j) }
        return power?.available == true ? "–" : nil
    }

    private var perTokenSub: String? {
        if let n = power?.tokens_per_wh { return "\(shortCount(n)) tok/Wh" }
        return power?.j_per_token_24h != nil ? "24h avg" : power?.available == true ? "no tokens" : nil
    }

    private func stat(_ title: String, _ value: String?, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 8, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
                .lineLimit(1).fixedSize()
            Text(value ?? "--").font(.system(size: 14, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundColor(value == nil ? .white.opacity(0.5) : orange).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub ?? " ").font(.system(size: 8, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    }

    private var breakdown: String {
        guard let p = power, p.available else {
            return "Power readings aren't available\(power?.error.map { ": \($0)" } ?? ".")"
        }
        let w = { (v: Double?) in String(format: "%.1f W", v ?? 0) }
        var lines = ["GPU \(w(p.gpu_w)) · CPU \(w(p.cpu_w)) · Neural Engine \(w(p.ane_w))",
                     "Memory \(w(p.dram_w)) · rest of the chip \(w(p.other_w)) · total \(w(p.soc_w))"]
        if let sys = p.system_w { lines.append("Whole Mac (power controller): \(w(sys)), about \(w(sys / 0.9)) at the wall") }
        if let ai = p.ai_w, ai > 0 { lines.append("Local LLM servers are using \(w(ai)) of GPU power") }
        if let j = p.j_per_token { lines.append(String(format: "Right now: %.2f J per generated token", j)) }
        if let g = p.gpu_wh_24h {
            var l = String(format: "Last 24h: GPU used %.2f Wh", g)
            if let a = p.ai_wh_24h, a > 0 { l += String(format: ", %.2f Wh of it making tokens", a) }
            lines.append(l)
        }
        if let j = p.j_per_token_24h { lines.append(String(format: "24h average: %.2f J per generated token (prompt reading included)", j)) }
        lines.append("Chip numbers come from its own energy counters; the whole Mac from its power controller (SMC).")
        return lines.joined(separator: "\n")
    }
}

struct ProcessRow: View {
    let p: Snapshot.Proc

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(p.is_ai ? "🤖" : "▸").font(.system(size: 10)).frame(width: 14)
                Text(p.name).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
                Spacer()
                if let tps = p.tok_s, tps > 0 {
                    Text("⚡\(Int(tps)) tok/s")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundColor(Color(red: 1, green: 0.85, blue: 0.5))
                }
                Text(String(format: "%.0f%%", p.gpu_percent))
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.75))
            }
            if let e = p.explain, !e.isEmpty {
                Text("🗣 " + e)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
                    .padding(.leading, 20)
            } else if !p.detail.isEmpty {
                Text(p.detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
            }
        }
        .contentShape(Rectangle())
        .help([p.explain.map { "🗣 \($0)\n" }, p.command, p.cwd.map { "in \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: "\n"))
        .contextMenu {
            Button("Copy Command") { copyToClipboard(p.command ?? p.name) }
            Text("PID \(p.pid)")
        }
    }
}

/// What the busiest script is doing, in plain English.
struct ExplainCard: View {
    let p: Snapshot.Proc

    private let gold = Color(red: 1, green: 0.85, blue: 0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("🗣 WHAT'S HAPPENING").font(.system(size: 8.5, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                Spacer(minLength: 4)
                Text(p.label).font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.4)).lineLimit(1).truncationMode(.middle)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let icon = p.explain_icon { Text(icon).font(.system(size: 12)) }
                Text(p.explain ?? "")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let facts = p.explain_facts, !facts.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { i, f in
                        Text(f)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundColor(i == 0 ? gold : .white.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(i == 0 ? gold.opacity(0.16) : .white.opacity(0.09)))
                    }
                }
            }
            if let q = p.explain_quote, !q.isEmpty {
                Text("“\(q)”").font(.system(size: 9.5, weight: .regular, design: .rounded)).italic()
                    .foregroundColor(.white.opacity(0.7)).lineLimit(2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
        .help((p.command ?? p.name) + (p.explain_icon != nil
              ? "\n\nFrom GPU Buddy's request log: who is asking your LLM server right now."
              : "\n\nSummed up by a model running on your Mac, from the script's own description, "
                + "the files it has open, its log and the programs it started."))
    }
}

/// Lays its children out left to right, wrapping onto new lines (for fact chips).
struct FlowLayout: Layout {
    var spacing: Double = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * Double(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width = 0.0; var height = 0.0 }

    private func arrange(_ subviews: Subviews, width: Double) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let w = min(size.width, width)
            if !rows[rows.count - 1].items.isEmpty && rows[rows.count - 1].width + spacing + w > width { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + w
            r.height = max(r.height, size.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

/// Drag here to move the window. The rest of the window no longer moves on drag,
/// so the timeline can be scrubbed.
#if os(macOS)
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
struct WindowDragArea: View {
    var body: some View { Color.clear.allowsHitTesting(false) }
}
#endif

/// Distinct colors for the busiest processes, in legend order.
let processPalette: [Color] = [
    Color(red: 0.55, green: 0.9, blue: 0.65), Color(red: 1, green: 0.7, blue: 0.35), Color(red: 0.45, green: 0.75, blue: 1),
    Color(red: 0.95, green: 0.5, blue: 0.75), Color(red: 0.95, green: 0.9, blue: 0.45), Color(red: 0.7, green: 0.55, blue: 1),
]

func durationText(_ s: Int) -> String {
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    return "\(s / 3600)h \(s % 3600 / 60)m"
}

/// 1h / 6h / 24h strip of GPU history. Hover to peek, drag to replay that moment.
/// The colored band under the chart shows which process was doing the work.
struct TimelineBar: View {
    @ObservedObject var store: GPUStore
    @State private var hoverT: Double?

    private let ranges: [(Double, String)] = [(3600, "1h"), (21600, "6h"), (86400, "24h")]

    private func color(_ label: String) -> Color {
        let idx = store.timeline?.legend?.firstIndex { $0.label == label }
        return idx.map { processPalette[$0 % processPalette.count] } ?? Color.white.opacity(0.3)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 5) {
                Text("HISTORY").font(.system(size: 10, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
                Spacer()
                ForEach(ranges, id: \.0) { r, label in
                    Button(label) { store.range = r }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(store.range == r ? 0.25 : 0.06)))
                }
                Button { store.scrub(to: nil) } label: {
                    Text(store.scrubTime == nil ? "● LIVE" : "⏩ LIVE")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(store.scrubTime == nil ? .red : .white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(.white.opacity(store.scrubTime == nil ? 0.06 : 0.25)))
                }
                .buttonStyle(.plain)
            }

            GeometryReader { geo in
                Canvas { ctx, size in draw(&ctx, size) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let t = time(at: v.location.x, width: geo.size.width)
                        hoverT = t
                        store.scrub(to: t)
                    })
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hoverT = time(at: p.x, width: geo.size.width) } else { hoverT = nil }
                    }
            }
            .frame(height: 44)

            readout
            legend
        }
    }

    /// nil when the pointer is at the right edge, meaning "live".
    private func time(at x: CGFloat, width: CGFloat) -> Double? {
        let f = min(max(x / width, 0), 1)
        return f > 0.99 ? nil : Date().timeIntervalSince1970 - store.range * (1 - f)
    }

    private func sample(near t: Double) -> Timeline.Point? {
        guard let tl = store.timeline else { return nil }
        return tl.samples.min { abs($0.t - t) < abs($1.t - t) }.flatMap { abs($0.t - t) <= tl.bucket_seconds ? $0 : nil }
    }

    // What was happening at the hovered / replayed moment.
    private var readout: some View {
        HStack(spacing: 5) {
            if let t = hoverT ?? store.scrubTime {
                let pt = sample(near: t)
                Text(clockText(t)).foregroundColor(.orange)
                if let top = pt?.top {
                    Circle().fill(color(top)).frame(width: 6, height: 6)
                    Text("\(pt?.ai == true ? "🤖 " : "")\(top)").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let g = pt?.tok_gen, g > 0 { Text("✍️\(shortCount(g))").foregroundColor(Color(red: 1, green: 0.85, blue: 0.5)) }
                    if let w = pt?.gpu_w { Text("⚡\(Int(w))W").foregroundColor(Color(red: 1, green: 0.62, blue: 0.35)) }
                    Text("\(Int(pt?.util ?? 0))%").monospacedDigit()
                } else {
                    Text(pt == nil ? "no data" : "idle 😴").foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
            } else {
                Text("-\(ranges.first { $0.0 == store.range }?.1 ?? "")")
                Spacer()
                if let tk = store.timeline?.tokens, tk.generated + tk.prompt > 0 {
                    Text("✍️ \(shortCount(tk.generated)) · 📖 \(shortCount(tk.prompt))"
                         + (store.timeline?.energy.map { $0.gpu_j > 0 ? " · ⚡ \(energyText($0.gpu_j))" : "" } ?? ""))
                        .foregroundColor(Color(red: 1, green: 0.85, blue: 0.5))
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else if let e = store.timeline?.energy, e.gpu_j > 0 {
                    Text("⚡ GPU used \(energyText(e.gpu_j))").foregroundColor(Color(red: 1, green: 0.62, blue: 0.35))
                } else {
                    #if os(macOS)
                    Text("hover to peek · drag to rewind")
                    #else
                    Text("drag to rewind")
                    #endif
                }
                Spacer()
                Text("now")
            }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .foregroundColor(.white.opacity(0.7))
        .frame(height: 13)
    }

    // Who used the GPU most in this range. Tap one to jump to its last appearance.
    private var legend: some View {
        let items = Array((store.timeline?.legend ?? []).prefix(3))
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(items, id: \.label) { item in
                Button { store.scrub(to: item.last_t) } label: {
                    HStack(spacing: 5) {
                        Circle().fill(color(item.label)).frame(width: 7, height: 7)
                        Text("\(item.is_ai ? "🤖 " : "")\(item.label)").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 1)
                        Text(durationText(item.seconds)).foregroundColor(.white.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(item.label)\nbusiest process for \(durationText(item.seconds)) · avg \(Int(item.avg_pct))%\nclick to jump to its last appearance")
            }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .foregroundColor(.white.opacity(0.8))
        .frame(height: 40, alignment: .top)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width
        let stripH = 6.0
        let h = size.height - stripH - 3
        ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 6), with: .color(.white.opacity(0.05)))
        let end = Date().timeIntervalSince1970
        let start = end - store.range
        let x = { (t: Double) in (t - start) / store.range * w }

        let hour = 3600.0
        var tick = (start / hour).rounded(.up) * hour
        while tick < end {
            var p = Path()
            p.move(to: CGPoint(x: x(tick), y: 0))
            p.addLine(to: CGPoint(x: x(tick), y: h))
            ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 1)
            tick += store.range > 6 * hour ? 3 * hour : hour
        }

        if let tl = store.timeline {
            let bw = max(1, tl.bucket_seconds / store.range * w)
            var mem = Path()
            for (i, pt) in tl.samples.enumerated() {
                let px = x(pt.t) - bw / 2
                let hueU = (0.64 + pt.util / 100 * 0.36).truncatingRemainder(dividingBy: 1)
                ctx.fill(Path(CGRect(x: px, y: h * (1 - Double(pt.max) / 100), width: bw, height: h * Double(pt.max) / 100)),
                         with: .color(.white.opacity(0.08)))
                ctx.fill(Path(CGRect(x: px, y: h * (1 - pt.util / 100), width: bw, height: h * pt.util / 100)),
                         with: .color(Color(hue: hueU, saturation: 0.6, brightness: 1).opacity(0.85)))
                // Who was doing the work.
                if let top = pt.top {
                    ctx.fill(Path(CGRect(x: px, y: h + 3, width: bw + 0.5, height: stripH)), with: .color(color(top)))
                }
                let mp = CGPoint(x: x(pt.t), y: h * (1 - pt.mem / 100))
                i == 0 ? mem.move(to: mp) : mem.addLine(to: mp)
            }
            ctx.stroke(mem, with: .color(Color(red: 0.45, green: 0.65, blue: 1).opacity(0.8)), lineWidth: 1)
            // GPU watts, scaled to the busiest moment in range.
            let peakW = max(tl.samples.compactMap(\.gpu_w).max() ?? 0, 1)
            var watts = Path()
            var started = false
            for pt in tl.samples {
                guard let gw = pt.gpu_w else { started = false; continue }
                let wp = CGPoint(x: x(pt.t), y: h * (1 - gw / peakW * 0.95))
                started ? watts.addLine(to: wp) : watts.move(to: wp)
                started = true
            }
            ctx.stroke(watts, with: .color(Color(red: 1, green: 0.62, blue: 0.35).opacity(0.9)), lineWidth: 1)
            // Golden sparkle along the top wherever tokens were generated.
            let maxTok = tl.samples.compactMap(\.tok_gen).max() ?? 0
            if maxTok > 0 {
                for pt in tl.samples {
                    guard let g = pt.tok_gen, g > 0 else { continue }
                    let o = 0.35 + 0.65 * g / maxTok
                    ctx.fill(Path(roundedRect: CGRect(x: x(pt.t) - bw / 2, y: 1, width: bw + 0.5, height: 3), cornerRadius: 1),
                             with: .color(Color(red: 1, green: 0.85, blue: 0.4).opacity(o)))
                }
            }
        }

        if let t = hoverT, t != store.scrubTime {
            var line = Path()
            line.move(to: CGPoint(x: x(t), y: 0))
            line.addLine(to: CGPoint(x: x(t), y: size.height))
            ctx.stroke(line, with: .color(.white.opacity(0.4)), lineWidth: 1)
        }
        if let t = store.scrubTime {
            let px = x(t)
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: size.height))
            ctx.stroke(line, with: .color(.orange), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: -2, width: 8, height: 8)), with: .color(.orange))
        }
    }
}

// MARK: - Hype copy

func agoText(_ t: Double) -> String {
    let m = Int((Date().timeIntervalSince1970 - t) / 60)
    if m < 1 { return "just now" }
    if m < 60 { return "\(m)m ago" }
    return m % 60 == 0 ? "\(m / 60)h ago" : "\(m / 60)h \(m % 60)m ago"
}

func clockText(_ t: Double) -> String {
    let f = DateFormatter()
    f.timeStyle = .medium
    return f.string(from: Date(timeIntervalSince1970: t))
}

/// Joules as something readable: "350 J", "0.26 Wh", "42 Wh", "1.20 kWh".
func energyText(_ joules: Double) -> String {
    let wh = joules / 3600
    if wh >= 1000 { return String(format: "%.2f kWh", wh / 1000) }
    if wh >= 10 { return String(format: "%.0f Wh", wh) }
    if wh >= 0.1 { return String(format: "%.2f Wh", wh) }
    return String(format: "%.0f J", joules)
}

func moneyText(_ v: Double) -> String {
    if v >= 10_000 { return "$" + fullCount(v.rounded()) }
    if v >= 100 { return String(format: "$%.0f", v) }
    if v >= 0.01 { return String(format: "$%.2f", v) }
    return v > 0 ? "<$0.01" : "$0"
}

/// 1234 -> "1.2K", 3_400_000 -> "3.4M"
func shortCount(_ v: Double) -> String {
    for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where v >= scale {
        return String(format: v / scale >= 100 ? "%.0f%@" : "%.1f%@", v / scale, suffix)
    }
    return String(format: "%.0f", v)
}

/// A time-to-first-token in seconds, short: "0.18 s", "2.4 s", "52 s", "1m 05s".
func ttftText(_ s: Double) -> String {
    if s < 1 { return String(format: "%.2f s", s) }
    if s < 10 { return String(format: "%.1f s", s) }
    if s < 60 { return "\(Int(s.rounded())) s" }
    let t = Int(s.rounded())
    return String(format: "%dm %02ds", t / 60, t % 60)
}

func bigNumber(_ v: Double) -> String {
    let units: [(Double, String)] = [(1e21, "sextillion"), (1e18, "quintillion"), (1e15, "quadrillion"), (1e12, "trillion"), (1e9, "billion"), (1e6, "million")]
    for (scale, name) in units where v >= scale {
        return String(format: "%.1f %@", v / scale, name)
    }
    return String(format: "%.0f", v)
}

@MainActor func hype(_ store: GPUStore, tick: Int) -> String {
    guard store.online, let s = store.shown else {
        if store.host.isLocal {
            #if os(macOS)
            return Service.isInstalled ? "gpud is starting… (logs: ~/Library/Logs/gpud.log) 🔌"
                                       : "Install the background service (GPU Buddy menu) to wake me up 🔌"
            #else
            return "Pair a Mac running gpud in the Macs tab to see its GPU 🔌"
            #endif
        }
        return "Can't reach \(store.host.name): \(store.problem ?? "offline") 🔌"
    }
    let top = s.processes.first?.label ?? "something"
    if let t = store.scrubTime {
        let ago = agoText(t)
        if s.gpu.mood == "sleeping" { return "⏪ \(ago): I was napping 😴" }
        return "⏪ \(ago): \(top) had me at \(s.gpu.utilization_percent)%"
    }
    let cores = s.gpu.cores
    let ops = bigNumber(s.fun.est_ops_since_start)
    if let p = s.power, let n = p.tokens_per_wh, tick % 4 == 3 {
        return "🍃 \(shortCount(n)) tokens per watt-hour, on \(Int(p.gpu_w ?? 0)) W!"
    }
    if let tk = s.tokens, tk.speed_tok_s > 0, tick % 2 == 0 {
        return "⚡ Writing \(Int(tk.speed_tok_s)) tokens/sec for you!"
    }
    if let tk = s.tokens, tk.generated_24h > 0, tick % 3 == 1 {
        return ["✍️ \(shortCount(tk.generated_24h)) tokens generated for you today!",
                "📖 Read \(shortCount(tk.prompt_24h)) tokens of your prompts today",
                "🧠 \(shortCount(tk.generated_24h + tk.prompt_24h)) tokens of thinking in 24h"][tick / 3 % 3]
    }
    let lines: [String]
    switch s.gpu.mood {
    case "sleeping":
        lines = ["Napping… give me something to crunch 😴",
                 "All \(cores) cores rested and ready for you",
                 "~\(ops) ops crunched for you so far 💤"]
    case "turbo":
        lines = s.ai_active
            ? ["🧠 AI is thinking SO hard for you right now!",
               "\(top) has all \(cores) cores flexing 💪",
               "~\(String(format: "%.1f", s.fun.est_current_tflops)) TFLOPS of pure thinking ⚡",
               "Tensors flying at full speed 🚀"]
            : ["🔥 TURBO! Every core is going brrrr",
               "\(top) is pushing me to the limit 🚀",
               "~\(String(format: "%.1f", s.fun.est_current_tflops)) TFLOPS, full send ⚡"]
    default:
        lines = s.ai_active
            ? ["🧠 AI is working hard for you",
               "\(top) is crunching numbers on my cores ✨",
               "~\(ops) ops crunched for you since start"]
            : ["\(top) has me on the job ✨",
               "~\(ops) ops crunched for you since start",
               "Peak so far: \(s.fun.peak_utilization_percent)%, can we beat it? 🏆"]
    }
    return lines[tick % lines.count]
}

// MARK: - Main view

let moodLabel = ["sleeping": "NAPPING", "chill": "CHILLING", "working": "WORKING",
                 "hustling": "HUSTLING", "turbo": "TURBO!", "offline": "OFFLINE"]

struct RootView: View {
    @ObservedObject var fleet: Fleet
    @ObservedObject var characters: Characters
    let anim: Anim

    var body: some View { ContentView(store: fleet.current, fleet: fleet, characters: characters, anim: anim) }
}

struct ContentView: View {
    @ObservedObject var store: GPUStore
    @ObservedObject var fleet: Fleet
    @ObservedObject var characters: Characters
    var anim = Anim()
    @State private var searchQuery = ""
    @AppStorage("tempFahrenheit") private var tempFahrenheit = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.visible)) { tl in
            let s = store.shown
            let _ = anim.step(tl.date, util: store.util, mem: store.online ? (s?.memory.used_percent ?? 0) / 100 : 0,
                              ai: s?.ai_active ?? false, tokS: store.online ? (s?.tokens?.speed_tok_s ?? 0) : 0)
            Group {
                if fleet.compact { compact(s) } else { full(s) }
            }
        }
        .foregroundColor(.white)
        .background(Color(red: 0.1, green: 0.09, blue: 0.15))
        .ignoresSafeArea()
    }

    private var badge: String? {
        if let t = store.scrubTime { return "⏪ \(clockText(t))" }
        return store.online && (store.shown?.ai_active ?? false) ? "🧠 AI at work" : nil
    }

    private var moodColor: Color { Color(hue: anim.hue, saturation: 0.45, brightness: 1) }

    private var characterMenu: some View {
        Menu {
            ForEach(characters.all) { ch in
                Button((ch.id == characters.selected ? "✓ " : "") + ch.name) { characters.selected = ch.id }
            }
            Divider()
            Button("Add Character from Photo…") { characters.addFromPanel() }
            if characters.currentIsPhoto {
                Button("Remove \(characters.currentName)") { characters.remove(characters.selected) }
            }
        } label: {
            Image(systemName: characters.busy ? "hourglass" : "theatermasks.fill")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change character (⌘J)")
    }

    /// Opens the LLM Router: a tiny version of its diagram (one entry fanning out to two servers) with a status light.
    #if os(macOS)
    @ViewBuilder private var routerButton: some View {
        if store.host.isLocal {
            let lr = store.online ? store.shown?.llm_requests : nil
            let busy = !(lr?.active.isEmpty ?? true)
            Button { NotificationCenter.default.post(name: .openRouter, object: nil) } label: {
                RouterGlyph(on: lr?.on ?? false, busy: busy, time: anim.time)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
            .help(lr?.on == true
                  ? (busy ? "LLM Router: answering \(lr!.active.count) request\(lr!.active.count == 1 ? "" : "s") now. Click to see who's connected (⌘E)"
                          : "LLM Router is on: see who connects to your local AI and where it goes (⌘E)")
                  : "LLM Router: share your local AI with other devices and apps (⌘E)")
        }
    }
    #endif

    private func modeButton(_ symbol: String) -> some View {
        Button { fleet.compact.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .help(fleet.compact ? "Full view (⌘1)" : "Compact view (⌘1)")
    }

    // Full window: Chippy, stats, processes, hype and the 24h timeline.
    private func full(_ s: Snapshot?) -> some View {
        VStack(spacing: 8) {
            SceneCanvas(anim: anim, mood: store.mood, badge: badge, character: characters.current, roomForBadges: true,
                        frameTime: anim.time)
                .frame(height: sceneHeight)
                .clipped()
                .overlay(WindowDragArea())
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 5) {
                        #if os(macOS)
                        routerButton
                        #endif
                        characterMenu
                        #if os(macOS)
                        modeButton("rectangle.compress.vertical")
                        #endif
                    }
                    .padding(8)
                }
                .overlay(alignment: .topLeading) {
                    // GPU temperature and time to first token, as little friends (below the window buttons on the Mac).
                    if store.online, store.scrubTime == nil {
                        VStack(alignment: .leading, spacing: 4 * badgeScale) {
                            if let c = s?.power?.gpu_temp {
                                ThermoBuddy(celsius: c, time: anim.time)
                            }
                            if let tk = s?.tokens, tk.ttft_s ?? tk.ttft_avg_s != nil {
                                StopwatchBuddy(tokens: tk, time: anim.time)
                            }
                        }
                        .fixedSize(horizontal: true, vertical: false)  // both badges take the wider one's width
                        #if os(macOS)
                        .padding(.top, 30)
                        #else
                        .padding(.top, 8)
                        #endif
                        .padding(.leading, 8)
                    }
                }

            VStack(spacing: 8) {
                HostBar(fleet: fleet)

                FoldSection(fleet: fleet, id: "gpu", title: "GPU",
                            summary: store.online ? "\(s?.gpu.utilization_percent ?? 0)% · \(moodLabel[store.mood] ?? "")" : "--") {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(store.online ? "\(s?.gpu.utilization_percent ?? 0)%" : "--")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .monospacedDigit().lineLimit(1).fixedSize()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(moodLabel[store.mood] ?? "")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundColor(moodColor)
                            Text(store.scrubTime.map { "⏪ \(agoText($0))" }
                                 ?? s.map { snap in
                                     let chip = "\(snap.gpu.model.replacingOccurrences(of: "Apple ", with: "")) · \(snap.gpu.cores) cores"
                                     return fleet.stores.count > 1 ? "\(snap.host?.name ?? store.host.title) · \(chip)" : chip
                                 }
                                 ?? "waiting for gpud")
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        Spacer(minLength: 4)
                        Sparkline(values: store.history).frame(width: 56, height: 26)
                    }
                    CoreGrid(anim: anim, cores: s?.gpu.cores ?? 16).frame(height: 17)
                }

                FoldSection(fleet: fleet, id: "memory", title: "MEMORY", summary: memText(s), showSummaryWhenOpen: true) {
                    MemoryTank(anim: anim).frame(height: 13)
                }

                FoldSection(fleet: fleet, id: "tokens", title: "TOKENS", summary: tokenSummary(s)) {
                    TokenCard(tokens: store.online ? s?.tokens : nil, time: anim.time) { fleet.onOpenLedger?() }
                }
                if store.online, let lr = s?.llm_requests, lr.on || !lr.active.isEmpty {
                    FoldSection(fleet: fleet, id: "requests", title: "WHO'S ASKING", summary: requestsSummary(lr)) {
                        RequestsCard(requests: lr, time: anim.time,
                                     onOpenLog: store.host.isLocal ? { NotificationCenter.default.post(name: .openRequestLog, object: nil) } : nil)
                    }
                }
                FoldSection(fleet: fleet, id: "power", title: "POWER", summary: powerSummary(s)) {
                    PowerCard(power: store.online ? s?.power : nil)
                }

                FoldSection(fleet: fleet, id: "processes", title: "PROCESSES",
                            summary: topProcesses(s, 1).first.map { "\($0.is_ai ? "🤖 " : "")\($0.label)" } ?? (store.online ? "nothing running" : "--")) {
                if let p = topProcesses(s, 5).first(where: { !($0.explain ?? "").isEmpty }) {
                    ExplainCard(p: p)
                }

                VStack(spacing: 4) {
                    #if os(macOS)
                    TextField("Search processes…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
                        .padding(.horizontal, 1)
                    #endif
                    ForEach(topProcesses(s, 3, filter: searchQuery)) { ProcessRow(p: $0) }
                }
                .frame(minHeight: 84, alignment: .top)  // grows when rows take two lines, instead of running into the next section
                }

                FoldSection(fleet: fleet, id: "cheer", title: "\(characters.currentName.uppercased()) SAYS") {
                Text(hype(store, tick: Int(anim.time / 5)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(moodColor.opacity(0.14)))
                }
                .padding(.top, 4)

                FoldSection(fleet: fleet, id: "timeline", title: "TIMELINE · 24H") {
                    TimelineBar(store: store)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .panelWidth(264)
    }

    #if os(macOS)
    private let sceneHeight = 150.0
    #else
    private let sceneHeight = 210.0
    #endif

    // Compact strip: mini Chippy + the essentials.
    private func compact(_ s: Snapshot?) -> some View {
        HStack(spacing: 10) {
            SceneCanvas(anim: anim, mood: store.mood, character: characters.current, frameTime: anim.time)
                .frame(width: 92, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(WindowDragArea())
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(store.online ? "\(s?.gpu.utilization_percent ?? 0)%" : "--")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .monospacedDigit().lineLimit(1).fixedSize()
                    Text(moodLabel[store.mood] ?? "")
                        .font(.system(size: 9.5, weight: .black, design: .rounded))
                        .foregroundColor(moodColor)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    #if os(macOS)
                    routerButton
                    #endif
                    modeButton("rectangle.expand.vertical")
                }
                MemoryTank(anim: anim).frame(height: 7)
                Text((fleet.stores.count > 1 ? "\(store.host.title) · " : "") + "mem " + memText(s)
                     + (store.online ? s?.power?.gpu_w.map { " · ⚡\(Int($0)) W" } ?? "" : ""))
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1).minimumScaleFactor(0.75)
                if let tk = store.online ? s?.tokens : nil {
                    VStack(alignment: .leading, spacing: 1) {
                        if let m = tk.sources.first(where: { $0.tok_s > 0 }).map({ $0.model.isEmpty ? $0.name : $0.model }) ?? tk.ttft_model {
                            Text("🧠 " + shortModelName(m) + (tk.speed_tok_s > 0 ? "  ⚡\(Int(tk.speed_tok_s))/s" : ""))
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .help(m)
                        }
                        Text("📖 read \(shortCount(tk.prompt_24h))  ✍️ generated \(shortCount(tk.generated_24h))")
                            .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundColor(Color(red: 1, green: 0.85, blue: 0.5))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .onTapGesture { fleet.onOpenLedger?() }
                    .help("Tokens in the last 24 hours. Click for the Token Ledger (⌘L)")
                }
                Text(topProcesses(s, 1).first.map { "\($0.is_ai ? "🤖 " : "")\($0.label)" } ?? (store.online ? "😴 nothing running" : "gpud offline"))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7).truncationMode(.middle)
                    .help(topProcesses(s, 1).first?.command ?? "")
                // Little thermometer and stopwatch chips: GPU temperature and time to first token.
                // The row always keeps its height, so the window doesn't jump when they appear.
                HStack(spacing: 5) {
                    if store.online, let c = s?.power?.gpu_temp {
                        ThermoBuddy(celsius: c, time: anim.time, mini: true)
                    }
                    if store.online, let tk = s?.tokens, tk.ttft_s ?? tk.ttft_avg_s != nil {
                        StopwatchBuddy(tokens: tk, time: anim.time, mini: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 20)
            }
        }
        .padding(8)
        .frame(width: 272)
    }

    private func requestsSummary(_ lr: Snapshot.LLMRequests) -> String {
        if let a = lr.active.first {
            return "\(lr.active.count) now · \(a.icon ?? "") \(a.agent ?? "") · \(a.caller)"
        }
        if let r = lr.recent.first { return "last: \(r.icon ?? "") \(r.agent ?? "") · \(agoText(r.started))" }
        return "no requests yet"
    }

    private func tokenSummary(_ s: Snapshot?) -> String {
        guard store.online, let tk = s?.tokens else { return "--" }
        return "📖\(shortCount(tk.prompt_24h)) ✍️\(shortCount(tk.generated_24h))" + (tk.speed_tok_s > 0 ? " ⚡\(Int(tk.speed_tok_s))/s" : "")
    }

    private func powerSummary(_ s: Snapshot?) -> String {
        guard store.online, let p = s?.power, p.available else { return "--" }
        return [p.gpu_w.map { "GPU \(Int($0)) W" }, p.system_w.map { "Mac \(Int($0)) W" }].compactMap { $0 }.joined(separator: " · ")
    }

    private func memText(_ s: Snapshot?) -> String {
        guard let s, store.online else { return "--" }
        return String(format: "%.1f / %.0f GB · %.0f%%", s.memory.used_bytes / 1_073_741_824, s.memory.total_bytes / 1_073_741_824, s.memory.used_percent)
    }

    private func topProcesses(_ s: Snapshot?, _ n: Int, filter: String = "") -> [Snapshot.Proc] {
        guard store.online, let s else { return [] }
        let filtered = s.processes.filter { $0.gpu_percent >= 0.5 }
        let searched = filter.isEmpty ? filtered : filtered.filter {
            $0.name.localizedCaseInsensitiveContains(filter) ||
            ($0.command ?? "").localizedCaseInsensitiveContains(filter) ||
            ($0.activity ?? "").localizedCaseInsensitiveContains(filter)
        }
        return Array(searched.prefix(n))
    }
}

/// A section of the full view that folds away: a small header with an arrow, and a one-line summary when folded.
struct FoldSection<Content: View>: View {
    @ObservedObject var fleet: Fleet
    let id: String
    let title: String
    var summary: String? = nil
    var showSummaryWhenOpen = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let open = !fleet.collapsed.contains(id)
        VStack(alignment: .leading, spacing: 4) {
            Button { fleet.toggleSection(id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .black))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 8)
                    Text(title)
                        .font(.system(size: 9.5, weight: .black, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    if let summary, !open || showSummaryWhenOpen {
                        Text(summary)
                            .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundColor(.white.opacity(open ? 1 : 0.8))
                            .lineLimit(1).minimumScaleFactor(0.6)  // shrink to fit rather than end in "…"
                    }
                }
                .foregroundColor(.white.opacity(0.45))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Fold away \(title.lowercased())" : "Show \(title.lowercased())")
            if open { content() }
        }
    }
}

// MARK: - Dock icon: live percentage ring

struct DockIcon: View {
    let util: Double
    let online: Bool

    var body: some View {
        let hue = (0.64 + util * 0.36).truncatingRemainder(dividingBy: 1)
        ZStack {
            RoundedRectangle(cornerRadius: 56)
                .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.6, brightness: 0.4), Color(hue: hue, saturation: 0.7, brightness: 0.12)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(12)
            Circle().stroke(.white.opacity(0.15), lineWidth: 22).padding(44)
            Circle().trim(from: 0, to: util)
                .stroke(Color(hue: hue, saturation: 0.5, brightness: 1), style: StrokeStyle(lineWidth: 22, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(44)
            Text(online ? "\(Int(util * 100))" : "zz")
                .font(.system(size: 78, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: 256, height: 256)
    }
}

/// The app's Finder/DMG icon: Chippy in the sky, on a rounded square.
struct AppIcon: View {
    var body: some View {
        let anim = Anim()
        let _ = (0..<45).forEach { anim.step(Date(timeIntervalSince1970: Double($0) / 30), util: 0.6, mem: 0.5, ai: true, tokS: 30) }
        SceneCanvas(anim: anim, mood: "working")
            .frame(width: 880, height: 880)
            .clipShape(RoundedRectangle(cornerRadius: 196, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .frame(width: 1024, height: 1024)
    }
}

// MARK: - About page

#if os(macOS)
struct AboutView: View {
    let daemonVersion: String?
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.13.0"

    var body: some View {
        VStack(spacing: 16) {
            AppIcon()
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))

            Text("GPU Buddy").font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundColor(.white)
            Text("Version \(appVersion)").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.6))

            if let dv = daemonVersion {
                Text("Daemon v\(dv)").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.4))
            }

            Text("Real-time GPU visualization for Apple Silicon Macs — with animated characters.").font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            Divider().foregroundColor(.white.opacity(0.1))

            VStack(alignment: .leading, spacing: 8) {
                aboutRow("⚡ GPU", "Real-time GPU utilization with animated visualization")
                aboutRow("🔌 Power", "GPU, CPU, ANE, DRAM, and total system power (no sudo)")
                aboutRow("📊 Tokens", "AI token generation and cost estimation")
                aboutRow("☁️ Cloud", "Compare local vs cloud frontier models")
                aboutRow("🖥 Multi-Mac", "Pair and monitor multiple Macs over TLS")
                aboutRow("🎭 Characters", "Chippy, Witch Bunny, and custom photo characters")
            }

            Spacer()
        }
        .padding(.top, titleBarInset)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
    }

    private func aboutRow(_ emoji: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(emoji).font(.system(size: 13, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .regular, design: .rounded)).foregroundColor(.white.opacity(0.7))
        }
    }
}
#else
struct AboutView: View {
    let daemonVersion: String?
    var body: some View { Text("About not available on iOS") }
}
#endif

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("kwhPrice") private var kwhPrice = 0.15
    @AppStorage("cost.cacheHit") private var cacheHit = 0.0
    @AppStorage("cost.thinking") private var thinking = 0.0
    @AppStorage("cost.tokenizer") private var tokenizer = 1.0
    @AppStorage("cost.region") private var region = "all"
    @AppStorage("cost.batch") private var batch = false
    @AppStorage("skipServiceSetup") private var skipService = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("⚙️ Settings").font(.system(size: 17, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, titleBarInset)
                .background(WindowDragArea())

            section("Energy & Cloud Cost") {
                VStack(alignment: .leading, spacing: 12) {
                    settingSlider("Electricity price", text: "$\(String(format: "%.2f", kwhPrice))", unit: "/kWh", value: $kwhPrice, range: 0.01...0.50)
                    settingSlider("Prompt cache", text: "\(Int(cacheHit * 100))%", value: $cacheHit, range: 0...0.9)
                    settingSlider("Hidden thinking", text: "+\(Int(thinking * 100))%", value: $thinking, range: 0...2)
                    settingSlider("Tokenizer", text: String(format: "%.2f×", tokenizer), value: $tokenizer, range: 0.8...1.4)

                    Toggle("Batch API (50% off, results within 24h)", isOn: $batch)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .toggleStyle(.checkbox)

                    Picker("Region", selection: $region) {
                        Text("All models").tag("all")
                        Text("🇺🇸 US").tag("us")
                        Text("🇨🇳 China").tag("cn")
                    }
                    .pickerStyle(.segmented)
                }
            }

            section("Who's Using My LLM") {
                RequestLogSettings()
            }

            section("Appearance") {
                Text("Character preferences and animations are handled within the app.").font(.system(size: 11, weight: .regular, design: .rounded)).foregroundColor(.white.opacity(0.6))
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 8.5, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
            content()
        }
    }

    private func settingSlider(_ title: String, text: String, unit: String = "", value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).frame(width: 120, alignment: .leading)
                Slider(value: value, in: range).controlSize(.mini)
                Text(text).monospacedDigit().frame(width: 40, alignment: .trailing)
                if !unit.isEmpty { Text(unit).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.4)) }
            }
        }
    }
}

extension Notification.Name {
    /// Opens the Request Log window (posted by the WHO'S ASKING card and Settings).
    static let openRequestLog = Notification.Name("GPUBuddyOpenRequestLog")
}

// MARK: - LLM request log window

@MainActor
final class RequestLogModel: ObservableObject {
    struct Page: Decodable { let on: Bool; let active: [LLMRequest]; let entries: [LLMRequest] }
    @Published var page: Page?
    @Published var problem: String?

    func load() async {
        guard let url = URL(string: "http://127.0.0.1:8765/api/v1/llm-proxy/log?limit=5000"),
              let (data, resp) = try? await URLSession.shared.data(from: url) else {
            problem = "gpud isn't running."
            return
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let p = try? JSONDecoder().decode(Page.self, from: data) else {
            problem = "This gpud is too old for the request log."
            return
        }
        page = p
        problem = nil
    }
}

#if os(macOS)
/// Every request to the local LLM server that the log kept: live, searchable, sortable.
struct RequestLogView: View {
    @StateObject private var model = RequestLogModel()
    @State private var query = ""
    @State private var agent = "All"
    @State private var sort = [KeyPathComparator(\LLMRequest.started, order: .reverse)]
    @State private var selection: LLMRequest.ID?

    private var all: [LLMRequest] { (model.page?.active ?? []) + (model.page?.entries ?? []) }

    private var rows: [LLMRequest] {
        let q = query.lowercased()
        return all.filter { r in
            (agent == "All" || r.agent == agent)
            && (q.isEmpty || [r.agent, r.caller, r.model, r.snippet, r.ip, r.state].compactMap { $0?.lowercased() }.contains { $0.contains(q) })
        }.sorted(using: sort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("📜 Request Log").font(.system(size: 17, weight: .heavy, design: .rounded))
                Spacer()
                Picker("", selection: $agent) {
                    Text("All agents").tag("All")
                    ForEach(Array(Set(all.compactMap(\.agent))).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 150)
                TextField("Search who, model, words…", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 220)
            }
            .padding(.top, titleBarInset)
            .background(WindowDragArea())

            totals

            if let p = model.problem {
                Text("⚠️ " + p).foregroundColor(.orange)
            } else if model.page?.on == false && all.isEmpty {
                Text("The request log is off. Turn it on in Settings → Who's Using My LLM.")
                    .foregroundColor(.white.opacity(0.6))
            }

            Table(rows, selection: $selection, sortOrder: $sort) {
                TableColumn("When", value: \.started) { r in
                    Text(timeText(r.started)).monospacedDigit()
                }.width(min: 70, ideal: 92)
                TableColumn("Agent", value: \.agentKey) { r in
                    Text("\(r.icon ?? "") \(r.agent ?? "?")").fontWeight(.semibold)
                }.width(min: 80, ideal: 110)
                TableColumn("From", value: \.caller) { r in
                    Text(r.caller).help(r.ip ?? "")
                }.width(min: 80, ideal: 150)
                TableColumn("Model", value: \.modelKey) { r in Text(r.model ?? "") }.width(min: 60, ideal: 110)
                TableColumn("Read", value: \.readKey) { r in
                    Text(r.readText ?? "").monospacedDigit()
                }.width(min: 40, ideal: 52)
                TableColumn("1st token", value: \.ttftKey) { r in
                    Text(r.ttft.map(ttftText) ?? "").monospacedDigit()
                }.width(min: 50, ideal: 62)
                TableColumn("Wrote", value: \.outputKey) { r in
                    Text(r.wroteText ?? "").monospacedDigit()
                }.width(min: 40, ideal: 50)
                TableColumn("Total", value: \.secondsKey) { r in
                    Text(r.seconds.map(ttftText) ?? (r.running ? "…" : "")).monospacedDigit()
                }.width(min: 40, ideal: 56)
                TableColumn("Status", value: \.stateKey) { r in
                    Text(stateText(r)).foregroundColor(stateColor(r))
                }.width(min: 60, ideal: 84)
                TableColumn("What") { r in
                    Text(r.snippet ?? "").foregroundColor(.white.opacity(0.75)).help(r.snippet ?? "")
                }.width(min: 80, ideal: 260)
            }
            .font(.system(size: 11, design: .rounded))

            HStack {
                Text("Kept on this Mac for 7 days. Snippets appear only when “Keep the first 100 characters” is on in Settings.")
                    .font(.system(size: 10, design: .rounded)).foregroundColor(.white.opacity(0.45))
                Spacer()
                Button("Show the file in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: NSHomeDirectory()
                        + "/Library/Application Support/GPUBuddy/llm-requests.jsonl")])
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .task {
            while !Task.isCancelled {
                await model.load()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Requests, tokens and the busiest agent for the rows shown.
    private var totals: some View {
        let r = rows
        let read = r.compactMap { $0.prompt_tokens ?? $0.est_tokens }.reduce(0, +)
        let wrote = r.compactMap(\.output_tokens).reduce(0, +)
        let ttfts = r.compactMap(\.ttft)
        let byAgent = Dictionary(grouping: r, by: { $0.agent ?? "?" }).mapValues(\.count).sorted { $0.value > $1.value }
        let blocked = r.filter { $0.state == "blocked" }.count
        return HStack(spacing: 8) {
            chip("\(r.count) requests")
            chip("📖 \(shortCount(read)) read")
            chip("✍️ \(shortCount(wrote)) written")
            if !ttfts.isEmpty { chip("⏱ avg 1st token \(ttftText(ttfts.reduce(0, +) / Double(ttfts.count)))") }
            if let top = byAgent.first { chip("most: \(top.key) (\(top.value))") }
            if blocked > 0 { chip("⛔ \(blocked) blocked").foregroundColor(.red) }
        }
    }

    private func chip(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.08)))
    }

    private func timeText(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "MMM d HH:mm"
        return f.string(from: d)
    }

    private func stateText(_ r: LLMRequest) -> String {
        switch r.state ?? "" {
        case "sending", "waiting": return "⏳ reading"
        case "answering": return "✍️ answering"
        case "done": return "✓ done"
        case "cancelled": return "✋ stopped"
        case "blocked": return "⛔ blocked"
        default: return "⚠️ \(r.status.map(String.init) ?? "error")"
        }
    }

    private func stateColor(_ r: LLMRequest) -> Color {
        switch r.state ?? "" {
        case "sending", "waiting", "answering": return .green
        case "blocked", "error": return .red
        case "cancelled": return .white.opacity(0.5)
        default: return .white.opacity(0.8)
        }
    }
}
#endif

/// Sort keys for the log table (Table sorts on non-optional values).
extension LLMRequest {
    var agentKey: String { agent ?? "" }
    var modelKey: String { model ?? "" }
    var promptKey: Double { prompt_tokens ?? -1 }
    var ttftKey: Double { ttft ?? -1 }
    var outputKey: Double { output_tokens ?? -1 }
    var secondsKey: Double { seconds ?? .infinity }
    var stateKey: String { state ?? "" }
}

// MARK: - LLM request log settings

/// gpud's LLM request log: on/off, allow list, API key and snippets. Talks to this Mac's gpud only.
@MainActor
final class RequestLog: ObservableObject {
    struct Status: Decodable {
        struct Moved: Decodable { let file: String; let backup: String }
        let enabled: Bool
        let state: String
        let message: String?
        let listen_port: Int
        let upstream_port: Int
        let allow: [String]
        let key_required: Bool
        let api_key: String?
        let snippets: Bool
        let retention_days: Int
        let log_file: String
        let addresses: [String]?
        let moved: Moved?
    }
    @Published var status: Status?
    @Published var problem: String?
    @Published var allowText = ""
    @Published var sending = false
    private let url = URL(string: "http://127.0.0.1:8765/api/v1/llm-proxy")!

    func refresh() async {
        guard let (data, resp) = try? await URLSession.shared.data(from: url) else {
            problem = "gpud isn't running, so the request log can't be changed."
            return
        }
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let st = try? JSONDecoder().decode(Status.self, from: data) else {
            problem = "This gpud is too old for the request log. Update GPU Buddy's background service."
            return
        }
        if status?.allow != st.allow { allowText = st.allow.joined(separator: ", ") }
        status = st
        problem = nil
    }

    func send(_ change: [String: Any]) async {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: change)
        req.timeoutInterval = 120  // turning off waits for the LLM server to restart
        sending = true
        defer { sending = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode != 200 {
                problem = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "That didn't work."
                return
            }
        } catch {
            problem = "gpud didn't answer: \(error.localizedDescription)"
            return
        }
        await refresh()
    }
}

struct RequestLogSettings: View {
    @StateObject private var log = RequestLog()
    @State private var copied = false

    private let small = Font.system(size: 9.5, weight: .regular, design: .rounded)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Log who uses my local LLM server", isOn: Binding(
                get: { log.status?.enabled ?? false },
                set: { on in Task { await log.send(["enabled": on]) } }))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                #if os(macOS)
                .toggleStyle(.checkbox)
                #endif
                .disabled(log.status == nil || log.sending || log.status?.state == "starting")

            statusLine

            if let st = log.status, st.enabled || st.state == "on" {
                #if os(macOS)
                Toggle("Keep the first 100 characters of each request", isOn: Binding(
                    get: { st.snippets }, set: { v in Task { await log.send(["snippets": v]) } }))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .toggleStyle(.checkbox)
                    .help("Shows what each request is about. It stays on this Mac, is never sent to your other Macs, and is deleted after \(st.retention_days) days.")
                #endif

                #if os(macOS)
                Text("Who may connect, client keys, extra entry ports and which LLM server answers are set in the LLM Router.")
                    .font(small).foregroundColor(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                Button("Open the LLM Router…") { NotificationCenter.default.post(name: .openRouter, object: nil) }
                #endif
                Button("Open the Request Log") { NotificationCenter.default.post(name: .openRequestLog, object: nil) }
            } else {
                Text("GPU Buddy sits in front of your LLM server on port 8080 and notes which app or device asks, the agent (Claude Code, Cline…), sizes and timings. Your server moves to port 8081 for this Mac only (GPU Buddy edits its start script and keeps a backup), so apps keep their settings. Turning this off puts everything back.")
                    .font(small).foregroundColor(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            while !Task.isCancelled {
                await log.refresh()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        if let p = log.problem {
            Text("⚠️ " + p).font(small).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
        } else if let st = log.status {
            switch st.state {
            case "starting", "stopping":
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(st.message ?? (st.state == "starting" ? "Starting…" : "Putting your LLM server back on port \(st.listen_port)…"))
                        .font(small).foregroundColor(.white.opacity(0.7))
                }
            case "on":
                VStack(alignment: .leading, spacing: 2) {
                    Text("✅ On. Your LLM server runs on port \(st.upstream_port) (this Mac only); apps keep using port \(st.listen_port).")
                    if let ip = st.addresses?.first {
                        Text("Other devices: http://\(ip):\(st.listen_port)/v1").textSelection(.enabled)
                    }
                    if let m = st.message { Text(m).foregroundColor(.orange) }
                }
                .font(small).foregroundColor(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            case "error":
                Text("⚠️ " + (st.message ?? "Couldn't start.")).font(small).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                if let m = st.message {
                    Text(m).font(small).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func saveAllow() {
        let list = log.allowText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
        Task { await log.send(["allow": list]) }
    }
}

// MARK: - Macs (switch between this Mac and others on the network)

/// One chip per Mac with its live %, plus a ＋ to pair more.
struct HostBar: View {
    @ObservedObject var fleet: Fleet

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(fleet.watched, id: \.host.id) { s in
                        HostChip(store: s, selected: s === fleet.current) { fleet.select(s) }
                    }
                }
            }
            Button { fleet.onOpenMacs?() } label: {
                Text(fleet.stores.count > 1 ? "＋" : "＋ Macs")
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .padding(.horizontal, 7).frame(height: 20)
                    .background(Capsule().fill(.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("Watch other Macs (⌘K)")
        }
    }
}

struct HostChip: View {
    @ObservedObject var store: GPUStore
    let selected: Bool
    let action: () -> Void

    private let gold = Color(red: 1, green: 0.85, blue: 0.5)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(store.online ? Color.green : Color.red.opacity(0.7)).frame(width: 6, height: 6)
                Text(store.host.title).lineLimit(1).frame(maxWidth: 90)
                if store.online {
                    Text("\(store.snap?.gpu.utilization_percent ?? 0)%").monospacedDigit().opacity(0.75)
                }
            }
            .font(.system(size: 9.5, weight: .heavy, design: .rounded))
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(selected ? gold.opacity(0.3) : .white.opacity(0.07)))
            .overlay(Capsule().stroke(selected ? gold.opacity(0.8) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(hostTooltip(store))
    }
}

/// Name, hardware, network and connection of one Mac, for tooltips.
@MainActor func hostTooltip(_ store: GPUStore) -> String {
    var lines = [store.snap?.host?.details ?? store.host.name]
    if store.host.isLocal {
        lines.append("This Mac, over 127.0.0.1")
    } else {
        lines.append("Connected to \(store.host.address) · 🔒 TLS, certificate pinned"
                     + (store.latency.map { String(format: " · %.0f ms", $0) } ?? ""))
    }
    if let p = store.problem, !store.online { lines.append("⚠️ \(p)") }
    return lines.joined(separator: "\n")
}

/// Pair with GPU Buddy on other Macs, and share this Mac's pairing code.
struct MacsView: View {
    @ObservedObject var fleet: Fleet
    @State private var pairing: String?  // Found.id being paired
    @State private var code = ""
    @State private var address = ""
    @State private var manualCode = ""
    @State private var error: String?
    @State private var busy = false
    @State private var copied = false

    private let gold = Color(red: 1, green: 0.85, blue: 0.5)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🖥 Macs").font(.system(size: 17, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, titleBarInset)
                .background(WindowDragArea())

            section("WATCHING") {
                if fleet.watched.isEmpty {
                    note("No Macs yet. Pair one below: on the Mac, open GPU Buddy → Macs and copy its pairing code.")
                }
                ForEach(fleet.watched, id: \.host.id) { s in PairedRow(store: s, fleet: fleet) }
            }

            section("ON YOUR NETWORK") {
                if fleet.found.isEmpty {
                    note("Looking for Macs running gpud… Install it on the other Mac with ./install.sh.")
                }
                ForEach(fleet.found) { f in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(size: 12, weight: .bold, design: .rounded))
                                Text(f.summary).font(.system(size: 9.5, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.65)).lineLimit(1).minimumScaleFactor(0.8)
                                Text("🌐 \(f.address)").font(.system(size: 9.5, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.5)).lineLimit(1)
                            }
                            Spacer()
                            if fleet.isPaired(f.id) {
                                Text("✓ paired").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.green)
                            } else if pairing != f.id {
                                pill("Pair…") {
                                    pairing = f.id
                                    code = ""
                                    error = nil
                                }
                            }
                        }
                        if pairing == f.id {
                            HStack(spacing: 6) {
                                TextField("Pairing code from that Mac", text: $code)
                                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                                    .onSubmit { connect(f.address, code) }
                                pill(busy ? "…" : "Connect") { connect(f.address, code) }
                            }
                        }
                    }
                }
            }

            section("ADD BY ADDRESS") {
                HStack(spacing: 6) {
                    TextField("Studio.local or 192.168.1.20", text: $address).textFieldStyle(.roundedBorder)
                        .font(.system(size: 11)).frame(width: 150)
                    TextField("Pairing code", text: $manualCode).textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .onSubmit { connect(address, manualCode) }
                    pill(busy ? "…" : "Add") { connect(address, manualCode) }
                }
            }

            if let error {
                Text("⚠️ " + error).font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if Fleet.hasLocal {
            section("SHARE THIS MAC") {
                if let p = fleet.thisMac, p.remote, let c = p.code {
                    HStack {
                        Text(c).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(gold)
                            .textSelection(.enabled)
                        Spacer()
                        pill(copied ? "Copied" : "Copy") {
                            copyToClipboard(c)
                            copied = true
                        }
                    }
                    note("On another Mac, open GPU Buddy → Macs (⌘K) and enter this code to watch \(p.name ?? "this Mac") (\(p.host ?? "")). Everything is encrypted with TLS, and the code also proves it's really this Mac. Keep it private: anyone with it can see this Mac's GPU activity.")
                } else if fleet.thisMac != nil {
                    note("Remote viewing is off on this Mac (gpud was started with --remote-port 0).")
                } else {
                    note("gpud isn't running on this Mac, so it can't be watched from elsewhere. You can still watch other Macs.")
                }
            }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 16)
        .panelWidth(400)
        .foregroundColor(.white)
        .background(Color(red: 0.1, green: 0.09, blue: 0.15))
        #if os(macOS)
        .ignoresSafeArea()
        #endif
    }

    private func connect(_ address: String, _ code: String) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            let e = await fleet.pair(address: address, code: code)
            busy = false
            error = e
            if e == nil {
                pairing = nil
                self.code = ""
                manualCode = ""
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9.5, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(gold)).foregroundColor(.black)
        }
        .buttonStyle(.plain)
    }
}

struct PairedRow: View {
    @ObservedObject var store: GPUStore
    @ObservedObject var fleet: Fleet

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.online ? Color.green : Color.red.opacity(0.7)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(store.host.isLocal ? "This Mac" : store.host.name).font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    if store.host.isLocal, let n = store.snap?.host?.name {
                        Text(n).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                    }
                    if store.online {
                        Text("\(store.snap?.gpu.utilization_percent ?? 0)%").font(.system(size: 10, weight: .heavy, design: .rounded))
                            .monospacedDigit().foregroundColor(Color(red: 1, green: 0.85, blue: 0.5))
                    }
                }
                if let h = store.snap?.host {
                    Text("\(h.hardware) · macOS \(h.macos)").lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundColor(.white.opacity(0.65))
                    Text("🌐 \(h.hostname) · \(h.network)").lineLimit(1).minimumScaleFactor(0.8)
                }
                Text(store.online
                     ? (store.host.isLocal ? "local" : "🔒 TLS · \(store.host.address)"
                        + (store.latency.map { String(format: " · %.0f ms", $0) } ?? ""))
                     : "⚠️ " + (store.problem ?? "connecting…"))
                    .lineLimit(1)
            }
            .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.5))
            .help(hostTooltip(store))
            Spacer()
            if store !== fleet.current {
                Button("Show") { fleet.select(store) }.buttonStyle(.plain)
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded)).foregroundColor(Color(red: 1, green: 0.85, blue: 0.5))
            }
            if !store.host.isLocal {
                Button { fleet.remove(store.host.id) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundColor(.white.opacity(0.5)).help("Forget this Mac")
            }
        }
    }
}

// MARK: - Token Ledger (all-time token usage with period filters)

struct Usage: Decodable {
    struct Bucket: Decodable, Identifiable {
        let key: String
        let t: Double
        let generated: Double
        let prompt: Double
        let gpu_j: Double?
        let ai_j: Double?
        var id: String { key }
        var date: Date { Date(timeIntervalSince1970: t) }
    }
    struct Model: Decodable, Identifiable {
        let server: String
        let model: String
        let generated: Double
        let prompt: Double
        let energy_j: Double?
        let j_per_token: Double?
        var id: String { server + "|" + model }
    }
    struct Energy: Decodable {
        let gpu_j: Double
        let soc_j: Double
        let system_j: Double?
        let ai_j: Double
        let measured_seconds: Double
        let j_per_token: Double?
    }
    let from: Double
    let to: Double
    let group: String
    let first_recorded: Double?
    let generated: Double
    let prompt: Double
    let total: Double
    let series: [Bucket]
    let models: [Model]
    let energy: Energy?
}

/// What a period's tokens would cost on frontier cloud models (from gpud's /api/v1/cost).
struct CloudCost: Decodable {
    struct Row: Decodable, Identifiable {
        let provider: String
        let model: String
        let cost: Double
        let per_day: Double
        let per_month: Double
        let input: Double
        let cache_read: Double
        let output: Double
        let region: String?
        let note: String?
        var id: String { provider + model }
    }
    /// Electricity over the same span, with unmeasured hours filled in at the measured average.
    struct Local: Decodable {
        let chip_j: Double?
        let system_j: Double?
        let measured_hours: Double
        let period_hours: Double
        let system_overhead_w: Double?
    }
    let as_of: String?
    let sources: [String]
    let days: Double
    let models: [Row]
    let local: Local?
}

struct UsageSummary: Decodable {
    struct Totals: Decodable {
        let generated: Double
        let prompt: Double
        let total: Double
    }
    let today: Totals
    let week: Totals
    let month: Totals
    let ytd: Totals
    let total: Totals
    let first_recorded: Double?

    func totals(_ preset: Ledger.Preset) -> Totals? {
        switch preset {
        case .today: return today
        case .week: return week
        case .month: return month
        case .ytd: return ytd
        case .total: return total
        case .custom: return nil
        }
    }
}

@MainActor
final class Ledger: ObservableObject {
    enum Preset: String, CaseIterable, Identifiable {
        case today = "Today", week = "Week", month = "Month", ytd = "YTD", total = "All time", custom = "Custom"
        var id: String { rawValue }
    }
    enum CustomMode: String, CaseIterable, Identifiable {
        case day = "Day", month = "Month", range = "From – To"
        var id: String { rawValue }
    }

    @Published var preset: Preset = .today { didSet { refresh() } }
    @Published var mode: CustomMode = .day { didSet { refresh() } }
    @Published var day = Date() { didSet { refresh() } }
    @Published var monthOf = Date() { didSet { refresh() } }
    @Published var from = Calendar.current.date(byAdding: .day, value: -6, to: Date())! { didSet { refresh() } }
    @Published var to = Date() { didSet { refresh() } }
    // Assumptions for the cloud estimate, remembered between launches.
    @Published var cacheHit = UserDefaults.standard.double(forKey: "cost.cacheHit") { didSet { saveCostOptions() } }
    @Published var batch = UserDefaults.standard.bool(forKey: "cost.batch") { didSet { saveCostOptions() } }
    @Published var thinking = UserDefaults.standard.double(forKey: "cost.thinking") { didSet { saveCostOptions() } }
    @Published var tokenizer = UserDefaults.standard.object(forKey: "cost.tokenizer") as? Double ?? 1 { didSet { saveCostOptions() } }
    @Published private(set) var cloud: CloudCost?
    @Published private(set) var usage: Usage?
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var online = true

    let hostName: String
    /// "Mac Studio", for labelling its electricity.
    let machine: String
    private let client: APIClient
    private let cal = Calendar.current
    private var timer: Timer?
    private var task: Task<Void, Never>?

    init(client: APIClient, hostName: String, machine: String = "Mac") {
        self.client = client
        self.hostName = hostName
        self.machine = machine
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            Task { @MainActor in self.refresh() }
        }
    }

    /// (start, end, bucket size) for the selected period, in local time.
    var period: (start: Date, end: Date, group: String?) {
        let now = Date()
        let soon = now.addingTimeInterval(3600)  // includes the hour in progress
        switch preset {
        case .today: return (cal.startOfDay(for: now), soon, "hour")
        case .week: return (cal.dateInterval(of: .weekOfYear, for: now)!.start, soon, "day")
        case .month: return (cal.dateInterval(of: .month, for: now)!.start, soon, "day")
        case .ytd: return (cal.dateInterval(of: .year, for: now)!.start, soon, nil)
        case .total: return (Date(timeIntervalSince1970: 0), soon, nil)
        case .custom:
            switch mode {
            case .day:
                let d = cal.startOfDay(for: day)
                return (d, cal.date(byAdding: .day, value: 1, to: d)!, "hour")
            case .month:
                let m = cal.dateInterval(of: .month, for: monthOf)!
                return (m.start, m.end, "day")
            case .range:
                let a = cal.startOfDay(for: min(from, to)), b = cal.startOfDay(for: max(from, to))
                return (a, cal.date(byAdding: .day, value: 1, to: b)!, nil)
            }
        }
    }

    var title: String {
        let (start, end, _) = period
        let f = DateFormatter()
        switch preset {
        case .today: f.dateFormat = "EEEE, MMM d"; return f.string(from: start)
        case .week, .month, .ytd:
            f.dateFormat = "MMM d"
            return "\(f.string(from: start)) – today"
        case .total:
            guard let first = usage?.first_recorded else { return "Everything gpud has counted" }
            f.dateStyle = .medium
            return "Since \(f.string(from: Date(timeIntervalSince1970: first)))"
        case .custom:
            switch mode {
            case .day: f.dateFormat = "EEEE, MMM d, yyyy"; return f.string(from: start)
            case .month: f.dateFormat = "MMMM yyyy"; return f.string(from: start)
            case .range:
                f.dateStyle = .medium
                return "\(f.string(from: start)) – \(f.string(from: end.addingTimeInterval(-1)))"
            }
        }
    }

    func shiftMonth(_ n: Int) { monthOf = cal.date(byAdding: .month, value: n, to: monthOf)! }
    func shiftDay(_ n: Int) { day = cal.date(byAdding: .day, value: n, to: day)! }

    private func saveCostOptions() {
        let d = UserDefaults.standard
        d.set(cacheHit, forKey: "cost.cacheHit")
        d.set(batch, forKey: "cost.batch")
        d.set(thinking, forKey: "cost.thinking")
        d.set(tokenizer, forKey: "cost.tokenizer")
        refresh()
    }

    func refresh() {
        let (start, end, group) = period
        var path = "/api/v1/usage?from=\(Int(start.timeIntervalSince1970))&to=\(Int(end.timeIntervalSince1970))"
        if let group { path += "&group=\(group)" }
        let costPath = "/api/v1/cost?from=\(Int(start.timeIntervalSince1970))&to=\(Int(end.timeIntervalSince1970))"
            + String(format: "&cache_hit=%.2f&thinking=%.2f&tokenizer=%.2f", cacheHit, thinking, tokenizer)
            + (batch ? "&batch=1" : "")
        task?.cancel()
        task = Task { [path] in
            async let u: Usage? = client.get(path, timeout: 3)
            async let s: UsageSummary? = client.get("/api/v1/usage/summary?week_start=\(cal.firstWeekday)", timeout: 3)
            async let c: CloudCost? = client.get(costPath, timeout: 3)
            let (usage, summary, cloud) = await (u, s, c)
            guard !Task.isCancelled else { return }
            online = usage != nil
            if let usage { self.usage = usage }
            if let summary { self.summary = summary }
            if let cloud { self.cloud = cloud }
        }
    }
}

/// "Oct 23, 9 PM"
func sinceText(_ t: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d, h a"
    return f.string(from: Date(timeIntervalSince1970: t))
}

/// 1234567 -> "1,234,567"
func fullCount(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
}

struct LedgerView: View {
    @StateObject var ledger: Ledger
    @State private var show = "Both"
    @State private var hover: Usage.Bucket?

    private let gold = Color(red: 1, green: 0.85, blue: 0.5)
    private let lilac = Color(red: 0.72, green: 0.66, blue: 1)
    private let ground = Color(red: 0.1, green: 0.09, blue: 0.15)

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .panelWidth(380)
        #if os(macOS)
        .frame(minHeight: 560)
        #endif
        .background(ground)
        #if os(macOS)
        .ignoresSafeArea()
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("📒 Token Ledger").font(.system(size: 17, weight: .heavy, design: .rounded))
                Text(ledger.hostName).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Spacer()
                Text(ledger.online ? "" : "gpud offline").font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
            }
            .padding(.top, titleBarInset)
            .background(WindowDragArea())

            presets
            if ledger.preset == .custom { customControls }

            Text(ledger.title)
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.6))
            if let first = ledger.usage?.first_recorded, first > ledger.period.start.timeIntervalSince1970 {
                Text("📅 Counting started \(sinceText(first)). Earlier days in this period have no data yet.")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            totals
            energy
            cloudCost
            chart
            models
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .panelWidth(380)
        .foregroundColor(.white)
    }

    private var presets: some View {
        HStack(spacing: 4) {
            ForEach(Ledger.Preset.allCases) { p in
                let on = ledger.preset == p
                Button { ledger.preset = p } label: {
                    VStack(spacing: 1) {
                        Text(p.rawValue).font(.system(size: 10, weight: .heavy, design: .rounded))
                            .lineLimit(1).fixedSize()
                        Text(ledger.summary?.totals(p).map { shortCount($0.total) } ?? (p == .custom ? "📅" : "–"))
                            .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundColor(on ? .black.opacity(0.6) : gold.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 9).fill(on ? gold : .white.opacity(0.08)))
                    .foregroundColor(on ? .black : .white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var customControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $ledger.mode) {
                ForEach(Ledger.CustomMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 6) {
                switch ledger.mode {
                case .day:
                    stepButton("chevron.left") { ledger.shiftDay(-1) }
                    DatePicker("", selection: $ledger.day, displayedComponents: .date).labelsHidden()
                    stepButton("chevron.right") { ledger.shiftDay(1) }
                case .month:
                    stepButton("chevron.left") { ledger.shiftMonth(-1) }
                    Text(monthText(ledger.monthOf)).font(.system(size: 13, weight: .heavy, design: .rounded))
                        .frame(minWidth: 130)
                    stepButton("chevron.right") { ledger.shiftMonth(1) }
                case .range:
                    Text("From").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.6))
                    DatePicker("", selection: $ledger.from, displayedComponents: .date).labelsHidden()
                    Text("to").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.6))
                    DatePicker("", selection: $ledger.to, displayedComponents: .date).labelsHidden()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22).background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func monthText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: d)
    }

    private var totals: some View {
        let u = ledger.usage
        return HStack(spacing: 8) {
            total("✍️ GENERATED", u?.generated, gold)
            total("📖 USED", u?.prompt, lilac)
            total("Σ TOTAL", u?.total, .white)
        }
    }

    private func total(_ title: String, _ v: Double?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8.5, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
            Text(v.map(shortCount) ?? "--")
                .font(.system(size: 20, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundColor(color).lineLimit(1).minimumScaleFactor(0.7)
            Text(v.map(fullCount) ?? " ")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
        .textSelection(.enabled)
    }

    private let orange = Color(red: 1, green: 0.62, blue: 0.35)
    @AppStorage("kwhPrice") private var kwhPrice = 0.15

    // Energy for the period and what it cost, next to what the same tokens cost in the cloud.
    private var energy: some View {
        let u = ledger.usage
        let e = u?.energy
        let measured = (e?.measured_seconds ?? 0) > 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                tile("⚡ GPU ENERGY", measured ? e.map { energyText($0.gpu_j) } : nil,
                     measured ? "whole chip \(energyText(e?.soc_j ?? 0))" : "no power data yet", orange)
                tile("🤖 FOR TOKENS", measured ? e.map { energyText($0.ai_j) } : nil,
                     e?.j_per_token.map { String(format: "%.2f J / token", $0) } ?? " ", orange)
                tile("💡 ELECTRICITY", measured ? e.map { moneyText(($0.system_j.map { $0 / psuEfficiency } ?? $0.soc_j) / 3.6e6 * kwhPrice) } : nil,
                     (e?.system_j != nil ? "whole Mac" : "chip") + ", at $\(String(format: "%.2f", kwhPrice))/kWh", orange)
            }
            HStack(spacing: 4) {
                Text("Electricity price $").font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                TextField("", value: $kwhPrice, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.plain).font(.system(size: 9.5, weight: .bold, design: .rounded)).frame(width: 34)
                    .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
                Text("per kWh · the whole Mac at the wall uses more than the chip")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    @AppStorage("cost.region") private var region = "all"

    // What the same tokens would have cost on frontier cloud models, under adjustable assumptions.
    private var cloudCost: some View {
        let all = ledger.cloud?.models ?? []
        let rows = region == "all" ? all : all.filter { $0.region == region }
        let local = ledger.cloud?.local
        // Power supplies lose roughly 10% as heat, so the wall meter reads a bit more than the SMC.
        let chipCost = (local?.chip_j ?? 0) / 3.6e6 * kwhPrice
        let macCost = local?.system_j.map { $0 / psuEfficiency / 3.6e6 * kwhPrice }
        let localCost = macCost ?? chipCost
        let days = ledger.cloud?.days ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("☁️ IF THESE TOKENS RAN IN THE CLOUD").font(.system(size: 9.5, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("prices \(ledger.cloud?.as_of ?? "")").font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
                    .help("List prices per 1M tokens from:\n" + (ledger.cloud?.sources ?? []).joined(separator: "\n")
                          + "\n\nEdit them in ~/Library/Application Support/GPUBuddy/prices.json (copy daemon/prices.json there).")
            }
            costSlider("Prompt cache hits", value: $ledger.cacheHit, range: 0...0.9, text: "\(Int(ledger.cacheHit * 100))%",
                       help: "Share of prompt tokens the provider serves from its prompt cache (billed at ~5–10% of the input price). "
                           + "0% is the worst case. Repeated system prompts and long chats often cache 50–90%; one-off prompts and images don't cache.")
            costSlider("Hidden thinking", value: $ledger.thinking, range: 0...2, text: "+\(Int(ledger.thinking * 100))%",
                       help: "Extra output tokens a cloud reasoning model spends thinking before it answers, as a share of the visible output. "
                           + "Billed as output. 0% if your local count already includes reasoning or the task needs none.")
            costSlider("Tokenizer", value: $ledger.tokenizer, range: 0.8...1.4, text: String(format: "%.2f×", ledger.tokenizer),
                       help: "The same text is a different number of tokens on each model family. 1.00× uses your local model's counts; "
                           + "newer Claude tokenizers can count up to ~1.35× more.")
            Picker("", selection: $region) {
                Text("All models").tag("all")
                Text("🇺🇸 US").tag("us")
                Text("🇨🇳 China").tag("cn")
            }
            .pickerStyle(.segmented).labelsHidden()
            Toggle(isOn: $ledger.batch) {
                Text("Batch API (50% off, results within 24h: fine for work nobody waits on)")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.7))
            }
            #if os(macOS)
            .toggleStyle(.checkbox)
            #endif

            if rows.isEmpty {
                Text(ledger.online ? "No tokens in this period." : "gpud offline").font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                HStack {
                    Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
                    Text("THIS PERIOD").frame(width: 70, alignment: .trailing)
                    Text(days >= Double(MIN_PERIOD_DAYS) ? "PER DAY" : "≈ 30 DAYS").frame(width: 66, alignment: .trailing)
                }
                .font(.system(size: 8, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.45))
                ForEach(rows) { r in
                    HStack {
                        Text(r.provider).foregroundColor(.white.opacity(0.45)).lineLimit(1).frame(width: 60, alignment: .leading)
                        Text(r.model).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(moneyText(r.cost)).foregroundColor(gold).frame(width: 70, alignment: .trailing)
                        Text(moneyText(days >= Double(MIN_PERIOD_DAYS) ? r.per_day : r.per_month)).foregroundColor(.white.opacity(0.6))
                            .frame(width: 66, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                    .help(String(format: "%@ %@: $%g in · $%g cached in · $%g out per 1M tokens", r.provider, r.model, r.input, r.cache_read, r.output)
                          + (r.note.map { "\n\($0)" } ?? ""))
                }
                Divider().overlay(Color.white.opacity(0.1))
                localRow("🧠 \(ledger.machine) chip only", chipCost, days,
                         help: "Electricity for the M-series chip (CPU, GPU, Neural Engine, memory) from its energy counters.")
                if let macCost {
                    localRow("🖥 Whole \(ledger.machine) (at the wall)", macCost, days,
                             help: "The whole computer as its power controller (SMC) measures it, plus ~10% power-supply loss. "
                                 + (local?.system_overhead_w.map { String(format: "Fans, SSD, ports and network add about %.1f W on top of the chip. ", $0) } ?? "")
                                 + "A monitor or other devices plugged in elsewhere aren't included.")
                }
                if let l = local, l.measured_hours + 0.05 < l.period_hours {
                    Text(String(format: "⚡ Power measured for %.1f of these %.1f hours; the rest is filled in at the same average power.",
                                l.measured_hours, l.period_hours))
                        .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let mid = rows.first(where: { $0.model.contains("Sonnet") || $0.model.contains("DeepSeek V4 Pro") })
                    ?? rows.dropFirst(rows.count / 2).first {
                    Text("💰 Running locally saved about \(moneyText(max(0, mid.cost - localCost))) vs \(mid.model) in this period"
                         + (days < Double(MIN_PERIOD_DAYS) ? " (≈ \(moneyText(max(0, mid.per_month - localCost / days * 30))) a month at this pace)." : "."))
                        .font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Estimate: your prompt tokens priced as input and generated tokens as output, at list prices"
                     + (all.contains { $0.region == "cn" } ? " (Chinese providers at their international USD prices). " : ". ")
                     + "Long prompts (over 100K–272K tokens each) cost more on some models; yours are usually far below that. "
                     + "≈ 30 days projects the pace of this period.")
                    .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }

    private let psuEfficiency = 0.9

    private func localRow(_ title: String, _ cost: Double, _ days: Double, help: String) -> some View {
        HStack {
            Text(title).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity, alignment: .leading)
            Text(moneyText(cost)).foregroundColor(orange).frame(width: 70, alignment: .trailing)
            Text(moneyText(days >= Double(MIN_PERIOD_DAYS) ? cost / days : cost / days * 30)).foregroundColor(.white.opacity(0.6))
                .frame(width: 66, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
        .help(help)
    }

    private func costSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String, help: String) -> some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 100, alignment: .leading)
            Slider(value: value, in: range).controlSize(.mini)
            Text(text).monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.7))
        .help(help)
    }

    private func tile(_ title: String, _ value: String?, _ sub: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 8.5, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
            Text(value ?? "--").font(.system(size: 17, weight: .heavy, design: .rounded)).monospacedDigit()
                .foregroundColor(value == nil ? .white.opacity(0.5) : color).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.system(size: 8.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(.white.opacity(0.5)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.07)))
    }

    private var unit: Calendar.Component {
        switch ledger.usage?.group {
        case "hour": return .hour
        case "month": return .month
        case "year": return .year
        default: return .day
        }
    }

    private func label(_ b: Usage.Bucket) -> String {
        let f = DateFormatter()
        switch ledger.usage?.group {
        case "hour": f.dateFormat = "MMM d, h a"
        case "month": f.dateFormat = "MMMM yyyy"
        default: f.dateFormat = "EEE, MMM d"
        }
        return f.string(from: b.date)
    }

    private var chart: some View {
        let series = ledger.usage?.series ?? []
        let (start, end, _) = ledger.period
        let now = Date()
        let lo = ledger.preset == .total ? (series.first?.date ?? start) : start
        // Show the whole period (all of today, the whole week…) so bars keep a steady width.
        let hi: Date = {
            switch ledger.preset {
            case .today: return cal.date(byAdding: .day, value: 1, to: start)!
            case .week: return cal.dateInterval(of: .weekOfYear, for: now)!.end
            case .month: return cal.dateInterval(of: .month, for: now)!.end
            case .ytd, .total: return cal.dateInterval(of: unit, for: now)?.end ?? end
            case .custom: return end
            }
        }()
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(hover.map { b in show == "Energy"
                        ? "\(label(b)) · ⚡ \(energyText(b.gpu_j ?? 0)) · 🤖 \(energyText(b.ai_j ?? 0))"
                        : "\(label(b)) · ✍️ \(shortCount(b.generated)) · 📖 \(shortCount(b.prompt))" }
                     ?? "Hover a bar for details")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(hover == nil ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
                Spacer()
                Picker("", selection: $show) {
                    Text("Both").tag("Both"); Text("✍️").tag("Gen"); Text("📖").tag("Used"); Text("⚡").tag("Energy")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            if series.isEmpty {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05))
                    .overlay(Text("No tokens counted in this period 💤")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.5)))
                    .frame(height: 150)
            } else {
                Chart {
                    ForEach(series) { b in
                        if show == "Energy" {
                            BarMark(x: .value("Time", b.date, unit: unit), y: .value("Wh", (b.ai_j ?? 0) / 3600))
                                .foregroundStyle(by: .value("Kind", "For tokens"))
                            BarMark(x: .value("Time", b.date, unit: unit), y: .value("Wh", max(0, (b.gpu_j ?? 0) - (b.ai_j ?? 0)) / 3600))
                                .foregroundStyle(by: .value("Kind", "Other GPU"))
                        } else if show != "Used" {
                            BarMark(x: .value("Time", b.date, unit: unit), y: .value("Tokens", b.generated))
                                .foregroundStyle(by: .value("Kind", "Generated"))
                        }
                        if show != "Gen" && show != "Energy" {
                            BarMark(x: .value("Time", b.date, unit: unit), y: .value("Tokens", b.prompt))
                                .foregroundStyle(by: .value("Kind", "Used"))
                        }
                    }
                    if let hover {
                        RuleMark(x: .value("Time", hover.date, unit: unit)).foregroundStyle(.white.opacity(0.25))
                    }
                }
                .chartForegroundStyleScale(["Generated": gold, "Used": lilac, "For tokens": orange,
                                            "Other GPU": orange.opacity(0.35)])
                .chartLegend(.hidden)
                .chartXScale(domain: (cal.dateInterval(of: unit, for: lo)?.start ?? lo) ... max(hi, lo.addingTimeInterval(1)))
                .chartPlotStyle { $0.clipped() }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel {
                            let n = v.as(Double.self) ?? 0
                            Text(show == "Energy" ? String(format: n < 10 ? "%.1f Wh" : "%.0f Wh", n) : shortCount(n))
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(.white.opacity(0.05))
                        AxisValueLabel()
                    }
                }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let pick = { (x: CGFloat?) in
                            guard let x, let plot = proxy.plotFrame.map({ geo[$0] }),
                                  let d: Date = proxy.value(atX: x - plot.minX) else { hover = nil; return }
                            hover = series.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
                        }
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let p) = phase { pick(p.x) } else { pick(nil) }
                            }
                            #if os(iOS)
                            .gesture(DragGesture(minimumDistance: 0).onChanged { pick($0.location.x) })
                            #endif
                    }
                }
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .frame(height: 150)
            }
        }
    }

    private var cal: Calendar { Calendar.current }

    private var models: some View {
        let list = ledger.usage?.models ?? []
        let top = list.map { $0.generated + $0.prompt }.max() ?? 1
        return VStack(alignment: .leading, spacing: 5) {
            Text("BY MODEL").font(.system(size: 9.5, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
            if list.isEmpty {
                Text("Nothing yet. Tokens are counted from local LLM servers while gpud runs.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.5))
            }
            VStack(spacing: 6) {
                ForEach(list.prefix(5)) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("🤖 \(m.model)").font(.system(size: 11, weight: .bold, design: .rounded)).lineLimit(1)
                            Text(m.server).font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.5)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("✍️\(shortCount(m.generated))  📖\(shortCount(m.prompt))"
                                 + (m.j_per_token.map { String(format: "  🍃%.2f J/tok", $0) } ?? ""))
                                .font(.system(size: 10, weight: .heavy, design: .rounded)).monospacedDigit().fixedSize()
                        }
                        GeometryReader { g in
                            let w = g.size.width * (m.generated + m.prompt) / max(top, 1)
                            HStack(spacing: 0) {
                                Rectangle().fill(gold).frame(width: w * m.generated / max(m.generated + m.prompt, 1))
                                Rectangle().fill(lilac)
                            }
                            .frame(width: max(w, 2))
                            .clipShape(Capsule())
                        }
                        .frame(height: 5)
                    }
                    .help("\(m.server) · \(m.model)\n\(fullCount(m.generated)) generated · \(fullCount(m.prompt)) used")
                }
                if list.count > 5 {
                    Text("+ \(list.count - 5) more").font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.5)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}


#if os(macOS)
/// The router button's picture: a little Wi-Fi-style router with a face. Its eyes are the status lights: green when the
/// router is on, grey when off, and they blink in turn while apps are asking.
struct RouterGlyph: View {
    let on: Bool
    let busy: Bool
    let time: Double
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let body = CGRect(x: w * 0.2, y: h * 0.47, width: w * 0.6, height: h * 0.32)
            // antennas with round tips
            var ant = Path()
            ant.move(to: CGPoint(x: w * 0.33, y: body.minY)); ant.addLine(to: CGPoint(x: w * 0.27, y: h * 0.22))
            ant.move(to: CGPoint(x: w * 0.67, y: body.minY)); ant.addLine(to: CGPoint(x: w * 0.73, y: h * 0.22))
            ctx.stroke(ant, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            for x in [0.27, 0.73] {
                ctx.fill(Path(ellipseIn: CGRect(x: w * x - 1.3, y: h * 0.22 - 1.3, width: 2.6, height: 2.6)), with: .color(.white))
            }
            ctx.fill(Path(roundedRect: body, cornerRadius: 2.2), with: .color(.white))
            // eyes = status lights
            let lit = on ? Color(red: 0.2, green: 0.78, blue: 0.4) : Color(white: 0.55)
            for (k, x) in [0.39, 0.61].enumerated() {
                let blink = busy && Int(time * 4) % 2 == k
                let col = blink ? Color(red: 0.55, green: 1, blue: 0.65) : lit
                ctx.fill(Path(ellipseIn: CGRect(x: w * x - 1.25, y: body.minY + body.height * 0.22, width: 2.5, height: 2.5)), with: .color(col))
            }
            // smile
            var smile = Path()
            smile.move(to: CGPoint(x: w * 0.45, y: body.minY + body.height * 0.7))
            smile.addQuadCurve(to: CGPoint(x: w * 0.55, y: body.minY + body.height * 0.7),
                               control: CGPoint(x: w * 0.5, y: body.minY + body.height * 0.92))
            ctx.stroke(smile, with: .color(Color(red: 0.1, green: 0.09, blue: 0.15)), style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
        }
    }
}
#endif


/// A model name short enough to read: a folder path becomes its folder name
/// ("/Users/me/.local/share/qwen36-moe-mlx/model" -> "qwen36-moe-mlx").
func shortModelName(_ m: String) -> String {
    guard m.contains("/") else { return m }
    let parts = m.split(separator: "/").map(String.init).filter { !$0.isEmpty }
    let generic: Set<String> = ["model", "models", "snapshots", "main", "mlx", "weights"]
    return parts.last(where: { !generic.contains($0.lowercased()) && !$0.hasPrefix("sha256") }) ?? parts.last ?? m
}
