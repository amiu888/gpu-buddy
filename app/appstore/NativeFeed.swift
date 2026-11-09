// App Store edition only (compiled with APPSTORE): this Mac's GPU, read in the App Sandbox.
//
// The sandbox can't install or run gpud, can't read other processes, the SMC (temperature) or IOReport
// (power). What it can read is the GPU's own IORegistry entry, the same "PerformanceStatistics" gpud uses
// for GPU load and GPU memory. So until gpud answers on 127.0.0.1:8765, APIClient falls back to this feed
// for "This Mac": GPU load, GPU memory, the chip and a short in-memory history. Everything else (power,
// processes, tokens, the ledger, the LLM router) needs gpud.

import Foundation
import IOKit
import SystemConfiguration

final class NativeFeed: @unchecked Sendable {
    static let shared = NativeFeed()

    private struct Sample { let t: Double; let util: Double; let mem: Double }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var peak = 0
    /// Read once, up front (not lazily: polls arrive on several threads at once).
    private let hostInfo: [String: Any] = NativeFeed.readHost()

    /// The same answer gpud would give for this path, as JSON (nil: needs gpud).
    func response(_ path: String) -> Data? {
        guard let url = URLComponents(string: "native://mac" + path) else { return nil }
        var q: [String: String] = [:]
        for i in url.queryItems ?? [] { q[i.name] = i.value ?? "" }
        let now = Date().timeIntervalSince1970
        let obj: Any?
        switch url.path {
        case "/health": obj = ["ok": true, "id": "local", "name": hostInfo["name"] ?? "This Mac", "model": hostInfo["chip"] ?? "", "host": hostInfo]
        case "/api/v1/status", "/api/v1/at": obj = snapshot(now)
        case "/api/v1/history": obj = history(seconds: Double(q["seconds"] ?? "") ?? 3600, points: Int(q["points"] ?? "") ?? 300, now: now)
        default: obj = nil
        }
        return obj.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    /// GPU load (0–100) and GPU memory in use (bytes) from the GPU's IORegistry entry.
    static func readGPU() -> (util: Int, memBytes: Double, cores: Int, model: String)? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any],
                  let ps = d["PerformanceStatistics"] as? [String: Any] else { continue }
            let util = (ps["Device Utilization %"] as? NSNumber)?.intValue ?? 0
            let mem = (ps["Alloc system memory"] as? NSNumber)?.doubleValue ?? (ps["In use system memory"] as? NSNumber)?.doubleValue ?? 0
            let cores = (d["gpu-core-count"] as? NSNumber)?.intValue ?? 0
            return (util, mem, cores, sysctlString("machdep.cpu.brand_string") ?? "Apple GPU")
        }
        return nil
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }

    /// "Mac Studio" etc. from the device tree (readable in the sandbox), else the model id.
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let cf = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let data = cf as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        // "Mac Studio (2025)" -> "Mac Studio"
        return name.replacingOccurrences(of: #"\s*\(.*\)$"#, with: "", options: .regularExpression)
    }

    private static func readHost() -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let gpu = readGPU()
        let modelID = sysctlString("hw.model")
        return [
            // Not Host.current() or ProcessInfo.hostName: they resolve names over the network and can hang.
            "name": (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "This Mac",
            "hostname": (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? "localhost",
            "model_name": productName() ?? modelID ?? "Mac",
            "model_id": (modelID.map { $0 as Any } ?? NSNull()),
            "chip": gpu?.model ?? "Apple silicon",
            "gpu_cores": gpu?.cores ?? 0,
            "cpu_cores": (sysctlInt("hw.ncpu").map { $0 as Any } ?? NSNull()),
            "cpu_performance_cores": (sysctlInt("hw.perflevel0.physicalcpu").map { $0 as Any } ?? NSNull()),
            "cpu_efficiency_cores": (sysctlInt("hw.perflevel1.physicalcpu").map { $0 as Any } ?? NSNull()),
            "memory_bytes": Double(sysctlInt("hw.memsize") ?? 0),
            "macos": "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            "addresses": [[String: Any]](),
        ]
    }

    private func mood(_ u: Int) -> String {
        u < 5 ? "sleeping" : u < 30 ? "chill" : u < 70 ? "working" : u < 90 ? "hustling" : "turbo"
    }

    private func snapshot(_ now: Double) -> [String: Any] {
        let g = Self.readGPU() ?? (0, 0, 0, "Apple GPU")
        let total = (hostInfo["memory_bytes"] as? Double) ?? 1
        let memPct = (min(g.memBytes / max(total, 1) * 100, 100) * 10).rounded() / 10
        lock.withLock {
            samples.append(Sample(t: now, util: Double(g.util), mem: memPct))
            if samples.count > 86_400 { samples.removeFirst(samples.count - 86_400) }  // a day at one a second
            peak = max(peak, g.util)
        }
        return [
            "timestamp": now, "host": hostInfo,
            "gpu": ["model": g.model, "cores": g.cores, "utilization_percent": g.util, "mood": mood(g.util)],
            "memory": ["used_bytes": g.memBytes, "total_bytes": total, "used_percent": memPct],
            "processes": [[String: Any]](), "ai_active": false,
            "fun": ["est_peak_tflops": 0.0, "est_current_tflops": 0.0, "est_ops_since_start": 0.0,
                    "peak_utilization_percent": lock.withLock { peak }],
        ]
    }

    /// GPU load since the app started (the sandbox keeps no history between launches; gpud keeps 24 h).
    private func history(seconds: Double, points: Int, now: Double) -> [String: Any] {
        let span = max(60, seconds), n = max(10, min(points, 600)), bucket = span / Double(n)
        let start = now - span
        let recent = lock.withLock { samples.filter { $0.t >= start } }
        var out: [[String: Any]] = []
        var i = 0
        for b in 0..<n {
            let end = start + Double(b + 1) * bucket
            var u = 0.0, m = 0.0, mx = 0.0, c = 0.0
            while i < recent.count && recent[i].t < end {
                u += recent[i].util; m += recent[i].mem; mx = max(mx, recent[i].util); c += 1; i += 1
            }
            guard c > 0 else { continue }
            out.append(["t": end, "util": (u / c * 10).rounded() / 10, "max": Int(mx), "mem": m / c, "ai": false])
        }
        return ["start": start, "end": now, "bucket_seconds": bucket, "samples": out]
    }
}
