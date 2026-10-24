// GPU Buddy — a tiny, animated window that shows what your GPU is doing.
// Talks to the gpud daemon (http://127.0.0.1:8765). Build with ./build.sh.

import AppKit
import Charts
import SwiftUI

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
        }
        let generated_per_s: Double
        let prompt_per_s: Double
        let generated_24h: Double
        let prompt_24h: Double
        let speed_tok_s: Double
        let sources: [Source]
    }
    let fun: Fun
    let tokens: Tokens?
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

    struct TokenTotals: Decodable {
        let generated: Double
        let prompt: Double
    }
}

@MainActor
final class GPUStore: ObservableObject {
    @Published var snap: Snapshot?
    @Published var online = false
    @Published var history: [Double] = []
    @Published var visible = true
    @Published var compact = UserDefaults.standard.bool(forKey: "compact") {
        didSet {
            UserDefaults.standard.set(compact, forKey: "compact")
            if compact { scrub(to: nil) }
            onCompactChange?(compact)
        }
    }
    var onCompactChange: ((Bool) -> Void)?
    @Published var timeline: Timeline?
    @Published var range: Double = 3600 {
        didSet { Task { await fetchTimeline() } }
    }
    /// The moment being replayed; nil means live.
    @Published private(set) var scrubTime: Double?
    @Published private(set) var replay: Snapshot?
    var onUpdate: ((GPUStore) -> Void)?
    var onOpenLedger: (() -> Void)?

    private let base: String
    private var timer: Timer?
    private var ticks = 0
    private var replayTask: Task<Void, Never>?

    init(port: Int) {
        base = "http://127.0.0.1:\(port)"
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
            guard !Task.isCancelled, let s: Snapshot = await get("/api/v1/at?t=\(t)"), !Task.isCancelled else { return }
            replay = s
        }
    }

    func fetchTimeline() async {
        if let tl: Timeline = await get("/api/v1/history?seconds=\(Int(range))&points=300") { timeline = tl }
    }

    private func get<T: Decodable>(_ path: String) async -> T? {
        var req = URLRequest(url: URL(string: base + path)!)
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        Task { await poll() }
    }

    private func poll() async {
        if let s: Snapshot = await get("/api/v1/status") {
            snap = s
            online = true
            history.append(Double(s.gpu.utilization_percent))
            if history.count > 60 { history.removeFirst(history.count - 60) }
        } else {
            online = false
        }
        if online && (timeline == nil || ticks % 10 == 0) { await fetchTimeline() }
        ticks += 1
        onUpdate?(self)
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
        scroll += dt * util * 260
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

// MARK: - The scene: Chippy, the kitty chip who runs as hard as your GPU

/// Chippy is drawn in a 150pt-tall design space and scaled to fit, so the same
/// drawing serves the full window and the compact strip.
let sceneDesignHeight = 150.0

struct SceneCanvas: View {
    let anim: Anim
    let mood: String
    var badge: String? = nil

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
        let cx = w * 0.5

        // Rolling grassy hill + treadmill dashes.
        ctx.fill(Path(roundedRect: CGRect(x: -20, y: groundY, width: w + 40, height: 60), cornerRadius: 24),
                 with: .color(Color(hue: (a.hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: 0.25, brightness: 0.3).opacity(0.7)))
        let dash = 22.0
        var x = -a.scroll.truncatingRemainder(dividingBy: dash)
        while x < w {
            ctx.fill(Path(roundedRect: CGRect(x: x, y: groundY + 7, width: 8, height: 3), cornerRadius: 1.5), with: .color(.white.opacity(0.22)))
            x += dash
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
                ctx.stroke(p, with: .color(.white.opacity(0.5 * (1 - travel / 120))), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }

        let bob = sleeping ? sin(t * 1.6) * 1.5 : abs(sin(a.runPhase * .pi * 2)) * (2 + 5 * u)
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 30 + bob, y: groundY - 3, width: 60 - bob * 2, height: 7)), with: .color(.black.opacity(0.25)))

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
                ctx.draw(txt, at: CGPoint(x: body.maxX + 6 + p * 18 + sin(p * 6) * 3, y: body.minY - p * 34))
            }
        }

        // Hearts and stars (or AI glyphs) floating off the work.
        for p in a.particles {
            let o = max(0, p.life / p.maxLife)
            let pos = CGPoint(x: cx + p.x, y: body.minY - 8 + p.y)
            let col = Color(hue: p.hue, saturation: 0.45, brightness: 1).opacity(o)
            if let g = p.glyph {
                ctx.draw(Text(g).font(.system(size: 6 + p.size * 1.5, weight: .bold, design: .rounded)).foregroundColor(col), at: pos)
            } else {
                ctx.fill(heart(pos, p.size * 0.8), with: .color(col))
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
        HStack(spacing: 8) {
            stat("✍️ GENERATED · 24h", tokens?.generated_24h, live: tokens.flatMap { $0.speed_tok_s > 0 ? "⚡\(Int($0.speed_tok_s)) tok/s" : nil })
            stat("📖 USED · 24h", tokens?.prompt_24h, live: tokens.flatMap { $0.prompt_per_s > 0 ? "+\(shortCount($0.prompt_per_s))/s" : nil })
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .help(sourcesHelp + "\n\nClick for the Token Ledger (⌘L): today, this week, month, YTD, all time.")
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
            return line
        }.joined(separator: "\n")
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
            if !p.detail.isEmpty {
                Text(p.detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
            }
        }
        .contentShape(Rectangle())
        .help([p.command, p.cwd.map { "in \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
        .contextMenu {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p.command ?? p.name, forType: .string)
            }
            Text("PID \(p.pid)")
        }
    }
}

/// Drag here to move the window. The rest of the window no longer moves on drag,
/// so the timeline can be scrubbed.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

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
                    Text("\(Int(pt?.util ?? 0))%").monospacedDigit()
                } else {
                    Text(pt == nil ? "no data" : "idle 😴").foregroundColor(.white.opacity(0.5))
                    Spacer()
                }
            } else {
                Text("-\(ranges.first { $0.0 == store.range }?.1 ?? "")")
                Spacer()
                if let tk = store.timeline?.tokens, tk.generated + tk.prompt > 0 {
                    Text("✍️ \(shortCount(tk.generated)) gen · 📖 \(shortCount(tk.prompt)) used")
                        .foregroundColor(Color(red: 1, green: 0.85, blue: 0.5))
                } else {
                    Text("hover to peek · drag to rewind")
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

/// 1234 -> "1.2K", 3_400_000 -> "3.4M"
func shortCount(_ v: Double) -> String {
    for (scale, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where v >= scale {
        return String(format: v / scale >= 100 ? "%.0f%@" : "%.1f%@", v / scale, suffix)
    }
    return String(format: "%.0f", v)
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
        return "I can't reach gpud. Run ./install.sh to wake me up 🔌"
    }
    let top = s.processes.first?.label ?? "something"
    if let t = store.scrubTime {
        let ago = agoText(t)
        if s.gpu.mood == "sleeping" { return "⏪ \(ago): I was napping 😴" }
        return "⏪ \(ago): \(top) had me at \(s.gpu.utilization_percent)%"
    }
    let cores = s.gpu.cores
    let ops = bigNumber(s.fun.est_ops_since_start)
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

struct ContentView: View {
    @ObservedObject var store: GPUStore
    var anim = Anim()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !store.visible)) { tl in
            let s = store.shown
            let _ = anim.step(tl.date, util: store.util, mem: store.online ? (s?.memory.used_percent ?? 0) / 100 : 0,
                              ai: s?.ai_active ?? false, tokS: store.online ? (s?.tokens?.speed_tok_s ?? 0) : 0)
            Group {
                if store.compact { compact(s) } else { full(s) }
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

    private func modeButton(_ symbol: String) -> some View {
        Button { store.compact.toggle() } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(.white.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .help(store.compact ? "Full view (⌘1)" : "Compact view (⌘1)")
    }

    // Full window: Chippy, stats, processes, hype and the 24h timeline.
    private func full(_ s: Snapshot?) -> some View {
        VStack(spacing: 8) {
            SceneCanvas(anim: anim, mood: store.mood, badge: badge)
                .frame(height: 150)
                .clipped()
                .overlay(WindowDragArea())
                .overlay(alignment: .topTrailing) { modeButton("rectangle.compress.vertical").padding(8) }

            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(store.online ? "\(s?.gpu.utilization_percent ?? 0)%" : "--")
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .monospacedDigit().lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(moodLabel[store.mood] ?? "")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundColor(moodColor)
                        Text(store.scrubTime.map { "⏪ \(agoText($0))" }
                             ?? s.map { "\($0.gpu.model.replacingOccurrences(of: "Apple ", with: "")) · \($0.gpu.cores) cores" }
                             ?? "waiting for gpud")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 4)
                    Sparkline(values: store.history).frame(width: 56, height: 26)
                }

                CoreGrid(anim: anim, cores: s?.gpu.cores ?? 16).frame(height: 17)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("MEMORY").font(.system(size: 9.5, weight: .black, design: .rounded)).foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text(memText(s)).font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    MemoryTank(anim: anim).frame(height: 13)
                }

                TokenCard(tokens: store.online ? s?.tokens : nil, time: anim.time) { store.onOpenLedger?() }

                VStack(spacing: 4) {
                    ForEach(topProcesses(s, 3)) { ProcessRow(p: $0) }
                }
                .frame(height: 84, alignment: .top)

                Text(hype(store, tick: Int(anim.time / 5)))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(moodColor.opacity(0.14)))

                TimelineBar(store: store)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(width: 264)
    }

    // Compact strip: mini Chippy + the essentials.
    private func compact(_ s: Snapshot?) -> some View {
        HStack(spacing: 10) {
            SceneCanvas(anim: anim, mood: store.mood)
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
                        .lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    modeButton("rectangle.expand.vertical")
                }
                MemoryTank(anim: anim).frame(height: 7)
                Text("mem " + memText(s))
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.6))
                if let tk = store.online ? s?.tokens : nil {
                    Text("✍️\(shortCount(tk.generated_24h)) 📖\(shortCount(tk.prompt_24h))\(tk.speed_tok_s > 0 ? " ⚡\(Int(tk.speed_tok_s))/s" : " tokens")")
                        .font(.system(size: 9, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundColor(Color(red: 1, green: 0.85, blue: 0.5))
                        .lineLimit(1)
                        .onTapGesture { store.onOpenLedger?() }
                        .help("Click for the Token Ledger (⌘L)")
                }
                Text(topProcesses(s, 1).first.map { "\($0.is_ai ? "🤖 " : "")\($0.label)" } ?? (store.online ? "😴 nothing running" : "gpud offline"))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .lineLimit(1).truncationMode(.middle)
                    .help(topProcesses(s, 1).first?.command ?? "")
            }
        }
        .padding(8)
        .frame(width: 250)
    }

    private func memText(_ s: Snapshot?) -> String {
        guard let s, store.online else { return "--" }
        return String(format: "%.1f / %.0f GB · %.0f%%", s.memory.used_bytes / 1_073_741_824, s.memory.total_bytes / 1_073_741_824, s.memory.used_percent)
    }

    private func topProcesses(_ s: Snapshot?, _ n: Int) -> [Snapshot.Proc] {
        guard store.online, let s else { return [] }
        return Array(s.processes.filter { $0.gpu_percent >= 0.5 }.prefix(n))
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

// MARK: - Token Ledger (all-time token usage with period filters)

struct Usage: Decodable {
    struct Bucket: Decodable, Identifiable {
        let key: String
        let t: Double
        let generated: Double
        let prompt: Double
        var id: String { key }
        var date: Date { Date(timeIntervalSince1970: t) }
    }
    struct Model: Decodable, Identifiable {
        let server: String
        let model: String
        let generated: Double
        let prompt: Double
        var id: String { server + "|" + model }
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
    @Published private(set) var usage: Usage?
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var online = true

    private let base: String
    private let cal = Calendar.current
    private var timer: Timer?
    private var task: Task<Void, Never>?

    init(port: Int) {
        base = "http://127.0.0.1:\(port)"
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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

    func refresh() {
        let (start, end, group) = period
        var path = "/api/v1/usage?from=\(Int(start.timeIntervalSince1970))&to=\(Int(end.timeIntervalSince1970))"
        if let group { path += "&group=\(group)" }
        task?.cancel()
        task = Task { [path] in
            async let u: Usage? = get(path)
            async let s: UsageSummary? = get("/api/v1/usage/summary?week_start=\(cal.firstWeekday)")
            let (usage, summary) = await (u, s)
            guard !Task.isCancelled else { return }
            online = usage != nil
            if let usage { self.usage = usage }
            if let summary { self.summary = summary }
        }
    }

    private func get<T: Decodable>(_ path: String) async -> T? {
        var req = URLRequest(url: URL(string: base + path)!)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("📒 Token Ledger").font(.system(size: 17, weight: .heavy, design: .rounded))
                Spacer()
                Text(ledger.online ? "" : "gpud offline").font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.orange)
            }
            .padding(.top, 22)  // clears the traffic lights
            .background(WindowDragArea())

            presets
            if ledger.preset == .custom { customControls }

            Text(ledger.title)
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.6))

            totals
            chart
            models
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 380)
        .frame(minHeight: 560, alignment: .top)
        .foregroundColor(.white)
        .background(ground)
        .ignoresSafeArea()
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
                Text(hover.map { "\(label($0)) · ✍️ \(shortCount($0.generated)) · 📖 \(shortCount($0.prompt))" }
                     ?? "Hover a bar for details")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(hover == nil ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
                Spacer()
                Picker("", selection: $show) {
                    Text("Both").tag("Both"); Text("✍️").tag("Gen"); Text("📖").tag("Used")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
            if series.isEmpty {
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05))
                    .overlay(Text("No tokens counted in this period 💤")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.5)))
                    .frame(height: 150)
            } else {
                Chart {
                    ForEach(series) { b in
                        if show != "Used" {
                            BarMark(x: .value("Time", b.date, unit: unit), y: .value("Tokens", b.generated))
                                .foregroundStyle(by: .value("Kind", "Generated"))
                        }
                        if show != "Gen" {
                            BarMark(x: .value("Time", b.date, unit: unit), y: .value("Tokens", b.prompt))
                                .foregroundStyle(by: .value("Kind", "Used"))
                        }
                    }
                    if let hover {
                        RuleMark(x: .value("Time", hover.date, unit: unit)).foregroundStyle(.white.opacity(0.25))
                    }
                }
                .chartForegroundStyleScale(["Generated": gold, "Used": lilac])
                .chartLegend(.hidden)
                .chartXScale(domain: (cal.dateInterval(of: unit, for: lo)?.start ?? lo) ... max(hi, lo.addingTimeInterval(1)))
                .chartPlotStyle { $0.clipped() }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(.white.opacity(0.08))
                        AxisValueLabel { Text(shortCount(v.as(Double.self) ?? 0)) }
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
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard case .active(let p) = phase,
                                      let plot = proxy.plotFrame.map({ geo[$0] }),
                                      let d: Date = proxy.value(atX: p.x - plot.minX) else { hover = nil; return }
                                hover = series.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
                            }
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
                            Text("✍️\(shortCount(m.generated))  📖\(shortCount(m.prompt))")
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

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var store: GPUStore!
    var ledgerWindow: NSWindow?
    private var port = 8765
    private var lastIcon = -2

    func applicationDidFinishLaunching(_ note: Notification) {
        port = Int(ProcessInfo.processInfo.environment["GPUD_PORT"] ?? "") ?? 8765
        store = GPUStore(port: port)
        store.onUpdate = { [weak self] s in self?.updateDockIcon(s) }
        store.onOpenLedger = { [weak self] in self?.openLedger() }
        store.onCompactChange = { [weak self] _ in
            DispatchQueue.main.async { self?.fitWindow(animate: true) }
        }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "GPU Buddy"
        window.isMovableByWindowBackground = false  // drag via Chippy's scene; lets the timeline scrub
        window.backgroundColor = NSColor(red: 0.1, green: 0.09, blue: 0.15, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ContentView(store: store))
        window.delegate = self
        window.setFrameAutosaveName("GPUBuddyWindow")
        let restored = window.setFrameUsingName("GPUBuddyWindow")
        fitWindow(animate: false)
        if !restored { window.center() }
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.store.visible = self.window.occlusionState.contains(.visible)
            }
        }

        NSApp.mainMenu = makeMenu()
        NSApp.activate(ignoringOtherApps: true)
        store.start()
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let pin = NSMenuItem(title: "Keep on Top", action: #selector(toggleOnTop(_:)), keyEquivalent: "t")
        pin.target = self
        appMenu.addItem(pin)
        let compact = NSMenuItem(title: "Compact View", action: #selector(toggleCompact), keyEquivalent: "1")
        compact.target = self
        appMenu.addItem(compact)
        let ledger = NSMenuItem(title: "Token Ledger…", action: #selector(openLedger), keyEquivalent: "l")
        ledger.target = self
        appMenu.addItem(ledger)
        appMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit GPU Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        return main
    }

    @objc func openLedger() {
        if ledgerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Token Ledger"
            w.isReleasedWhenClosed = false
            w.backgroundColor = window.backgroundColor
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: LedgerView(ledger: Ledger(port: self.port)))
            w.setFrameAutosaveName("GPUBuddyLedger")
            if !w.setFrameUsingName("GPUBuddyLedger") {
                w.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX + 12, y: window.frame.maxY))
            }
            ledgerWindow = w
        }
        ledgerWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleCompact() {
        store.compact.toggle()
    }

    /// Resize to the SwiftUI content, keeping the window's top edge in place.
    private func fitWindow(animate: Bool) {
        let size = window.contentView!.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate)
        // The traffic lights would sit on top of mini Chippy; ⌘M still minimizes.
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = store.compact
        }
    }

    @objc func toggleOnTop(_ item: NSMenuItem) {
        window.level = window.level == .floating ? .normal : .floating
        item.state = window.level == .floating ? .on : .off
    }

    private func updateDockIcon(_ s: GPUStore) {
        let pct = s.online ? Int(s.liveUtil * 100) : -1
        guard pct != lastIcon else { return }
        lastIcon = pct
        let renderer = ImageRenderer(content: DockIcon(util: s.liveUtil, online: s.online))
        renderer.scale = 1
        if let img = renderer.nsImage { NSApp.applicationIconImage = img }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
