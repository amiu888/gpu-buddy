// GPU Buddy for macOS: the window, menus, Dock icon, and the bundled gpud service.
// The views and everything that talks to gpud live in ../GPUBuddy.swift, shared with iOS.

import AppKit
import SwiftUI

// MARK: - Background service (gpud) bundled inside the app

/// Installs, updates and removes gpud as a LaunchAgent, from the copy bundled in the app.
/// The files are copied to Application Support so the service keeps working wherever the app moves.
@MainActor
enum Service {
    static let label = "local.gpubuddy.gpud"
    static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/GPUBuddy")
    static let installed = support.appendingPathComponent("daemon")
    static let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static var bundled: URL? { Bundle.main.resourceURL?.appendingPathComponent("daemon") }

    /// gpud is set up by some means (this app, or ./install.sh from the repo).
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    /// Set up by this app (as opposed to ./install.sh), so the app may update and remove it.
    static var isOurs: Bool {
        guard let d = NSDictionary(contentsOf: plist), let args = d["ProgramArguments"] as? [String] else { return false }
        return args.contains { $0.hasPrefix(installed.path) }
    }

    static func version(at dir: URL) -> String? {
        guard let src = try? String(contentsOf: dir.appendingPathComponent("gpud.py"), encoding: .utf8),
              let line = src.split(separator: "\n").first(where: { $0.hasPrefix("VERSION = ") }) else { return nil }
        return line.split(separator: "\"").dropFirst().first.map(String.init)
    }

    static func install() throws {
        guard let bundled else { throw NSError(domain: "GPUBuddy", code: 1, userInfo: [NSLocalizedDescriptionKey: "This copy of GPU Buddy has no bundled gpud."]) }
        let fm = FileManager.default
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: bundled.path) {
            let dst = installed.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: bundled.appendingPathComponent(name), to: dst)
        }
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/python3", installed.appendingPathComponent("gpud.py").path, "--port", "8765"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardOutPath": logs.appendingPathComponent("gpud.log").path,
            "StandardErrorPath": logs.appendingPathComponent("gpud.log").path,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try data.write(to: plist)
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        launchctl(["bootstrap", "gui/\(getuid())", plist.path])
    }

    /// When the app carries a newer gpud than the one it installed, swap it in and restart it.
    static func updateIfNeeded() {
        guard isOurs, let bundled, let new = version(at: bundled), new != version(at: installed) else { return }
        try? install()
    }

    static func uninstall() {
        turnOffRequestLog()
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    /// If gpud's LLM request log moved the LLM server to another port, put it back before gpud goes away
    /// (apps would otherwise lose the server). Waits up to a minute for the server to restart.
    static func turnOffRequestLog() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8765/api/v1/llm-proxy")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"enabled": false}"#.utf8)
        req.timeoutInterval = 60
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 60)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// /usr/bin/python3 needs Apple's Command Line Tools; without them macOS offers to install them.
    static var hasCommandLineTools: Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    var fleet: Fleet!
    let characters = Characters()
    var aboutWindow: NSWindow?
    var settingsWindow: NSWindow?
    var ledgerWindow: NSWindow?
    var requestLogWindow: NSWindow?
    var routerWindow: NSWindow?
    var macsWindow: NSWindow?
    private var port = 8765
    private var lastIcon = -2

    func applicationDidFinishLaunching(_ note: Notification) {
        port = Int(ProcessInfo.processInfo.environment["GPUD_PORT"] ?? "") ?? 8765
        fleet = Fleet(localPort: port)
        fleet.onUpdate = { [weak self] s in self?.updateDockIcon(s) }
        fleet.onOpenLedger = { [weak self] in self?.openLedger() }
        NotificationCenter.default.addObserver(forName: .openRouter, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openRouter() }
        }
        NotificationCenter.default.addObserver(forName: .openRequestLog, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openRequestLog() }
        }
        if CommandLine.arguments.contains("--router") {  // `open "GPU Buddy.app" --args --router`
            DispatchQueue.main.async { [weak self] in self?.openRouter() }
        }
        // For checking the layout: `--snapshot-router out.png` saves a picture of the router window after 6 s.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-router"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.async { [weak self] in self?.openRouter() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let v = self?.routerWindow?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
        // Same for the main window: `--snapshot-main out.png`.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-main"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let v = self?.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
        fleet.onOpenMacs = { [weak self] in self?.openMacs() }
        fleet.onSelect = { [weak self] in self?.hostChanged() }
        fleet.onCompactChange = { [weak self] in
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
        window.contentView = NSHostingView(rootView: RootView(fleet: fleet, characters: characters, anim: Anim()))
        // Keep the window after it's closed: the Dock icon, menus, and observers below all reopen or
        // message it, and a released window made the Dock click crash (EXC_BAD_ACCESS).
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("GPUBuddyWindow")
        let restored = window.setFrameUsingName("GPUBuddyWindow")
        fitWindow(animate: false)
        if !restored { window.center() }
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let visible = self.window.occlusionState.contains(.visible)
                self.fleet.stores.forEach { $0.visible = visible }
            }
        }

        NSApp.mainMenu = makeMenu()
        NSApp.activate(ignoringOtherApps: true)
        Service.updateIfNeeded()
        fleet.start()
        if !Service.isInstalled && Service.bundled != nil && !UserDefaults.standard.bool(forKey: "skipServiceSetup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.offerService(firstRun: true) }
        }
    }

    /// Asks before installing gpud: it runs in the background and starts at login.
    @objc func offerService(firstRun: Bool = false) {
        let alert = NSAlert()
        alert.messageText = "Install the GPU Buddy service?"
        alert.informativeText = """
            GPU Buddy reads your GPU through a small background service, gpud. It starts at login, uses about 1% CPU, \
            and keeps 24 hours of GPU history plus your token and energy ledger on this Mac.

            Other Macs can watch this one only with its pairing code, over an encrypted connection.
            \(Service.hasCommandLineTools ? "" : "\nmacOS will ask to install the Command Line Developer Tools (for Python). Click Install; gpud starts by itself when they're ready.\n")
            Only want to watch other Macs? Choose Not Now.
            """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            if firstRun { UserDefaults.standard.set(true, forKey: "skipServiceSetup") }
            return
        }
        do {
            try Service.install()
            if !Service.hasCommandLineTools {
                // Running python3 once makes macOS show its "install the tools" dialog.
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                p.arguments = ["--version"]
                try? p.run()
            }
        } catch {
            let fail = NSAlert(error: error)
            fail.runModal()
        }
    }

    @objc func removeService() {
        let alert = NSAlert()
        alert.messageText = "Remove the GPU Buddy service?"
        alert.informativeText = "gpud stops and won't start at login. Your history and ledger stay in ~/Library/Application Support/GPUBuddy."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Service.uninstall() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(offerService(firstRun:)): return Service.bundled != nil && !Service.isInstalled
        case #selector(removeService): return Service.isOurs
        default: return true
        }
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
        let requests = NSMenuItem(title: "Request Log…", action: #selector(openRequestLog), keyEquivalent: "r")
        requests.target = self
        appMenu.addItem(requests)
        let router = NSMenuItem(title: "LLM Router…", action: #selector(openRouter), keyEquivalent: "e")
        router.target = self
        appMenu.addItem(router)
        appMenu.addItem(.separator())
        for (title, action, key) in [("Macs…", #selector(openMacs), "k"), ("Next Mac", #selector(nextMac), "]"),
                                     ("Previous Mac", #selector(previousMac), "["), ("Next Character", #selector(nextCharacter), "j"),
                                     ("Add Character from Photo…", #selector(addCharacter), "")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            appMenu.addItem(item)
        }
        let about = NSMenuItem(title: "About GPU Buddy…", action: #selector(openAbout), keyEquivalent: "?")
        about.target = self
        appMenu.addItem(about)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "s")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        appMenu.addItem(.separator())
        for (title, action) in [("Install Background Service…", #selector(offerService(firstRun:))),
                                ("Remove Background Service…", #selector(removeService))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            appMenu.addItem(item)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit GPU Buddy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        return main
    }

    @objc func openLedger() {
        if ledgerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Token Ledger"
            w.contentMinSize = NSSize(width: 380, height: 420)
            w.contentMaxSize = NSSize(width: 380, height: 4000)
            w.isReleasedWhenClosed = false
            w.backgroundColor = window.backgroundColor
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = ledgerContent()
            w.setFrameAutosaveName("GPUBuddyLedger2")
            if !w.setFrameUsingName("GPUBuddyLedger2") {
                w.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX + 12, y: window.frame.maxY))
            }
            ledgerWindow = w
        }
        ledgerWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openRequestLog() {
        if requestLogWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Request Log"
            w.contentMinSize = NSSize(width: 700, height: 300)
            w.isReleasedWhenClosed = false
            w.backgroundColor = window.backgroundColor
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: RequestLogView())
            w.setFrameAutosaveName("GPUBuddyRequestLog")
            if !w.setFrameUsingName("GPUBuddyRequestLog") { w.center() }
            requestLogWindow = w
        }
        requestLogWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openRouter() {
        if routerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "LLM Router"
            w.contentMinSize = NSSize(width: 900, height: 480)
            w.isReleasedWhenClosed = false
            w.backgroundColor = window.backgroundColor
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: RouterView())
            w.setFrameAutosaveName("GPUBuddyRouter")
            if !w.setFrameUsingName("GPUBuddyRouter") { w.center() }
            routerWindow = w
        }
        routerWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleCompact() {
        fleet.compact.toggle()
    }

    private func ledgerContent() -> NSView {
        let ledger = Ledger(client: fleet.current.client, hostName: fleet.current.host.title,
                            machine: fleet.current.snap?.host?.model_name ?? "Mac")
        return NSHostingView(rootView: LedgerView(ledger: ledger))
    }

    /// Another Mac was picked: the ledger and Dock icon follow it.
    private func hostChanged() {
        lastIcon = -2
        if let w = ledgerWindow { w.contentView = ledgerContent() }
    }

    @objc func openMacs() {
        if macsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Macs"
            w.isReleasedWhenClosed = false
            w.backgroundColor = window.backgroundColor
            w.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: MacsView(fleet: fleet))
            host.sizingOptions = [.preferredContentSize]
            w.contentView = host
            w.center()
            macsWindow = w
        }
        macsWindow?.makeKeyAndOrderFront(nil)
        Task { await fleet.refreshThisMac() }  // show this Mac's code right away if gpud just came up
    }

    @objc func openAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 480),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "About GPU Buddy"
            w.isReleasedWhenClosed = false
            w.backgroundColor = window.backgroundColor
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: AboutView(daemonVersion: fleet.current.snap?.host?.gpud_version))
            w.center()
            aboutWindow = w
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 720),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Settings"
            w.isReleasedWhenClosed = false
            w.backgroundColor = window.backgroundColor
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func nextMac() { fleet.step(1) }
    @objc func nextCharacter() { characters.next() }
    @objc func addCharacter() { characters.addFromPanel() }
    @objc func previousMac() { fleet.step(-1) }

    /// Resize to the SwiftUI content, keeping the window's top edge in place.
    private func fitWindow(animate: Bool) {
        let size = window.contentView!.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: animate)
        // The traffic lights would sit on top of mini Chippy; ⌘M still minimizes.
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(b)?.isHidden = fleet.compact
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
        guard let window else { return true }  // not built yet (still launching)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

MainActor.assumeIsolated {
    // Used by build.sh: `GPUBuddy --render-icon out.png` draws the app icon and exits.
    if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
        let r = ImageRenderer(content: AppIcon())
        r.scale = 1
        if let img = r.nsImage, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t),
           let png = b.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
