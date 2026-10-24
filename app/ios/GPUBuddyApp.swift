// GPU Buddy for iPhone and iPad: watch your Macs' GPUs, tokens and power.
// An iPhone can't run gpud, so it pairs with Macs that do. The views are shared with the Mac app (../GPUBuddy.swift).

import PhotosUI
import SwiftUI

@main
struct GPUBuddyMobile: App {
    @StateObject private var fleet = Fleet(localPort: 8765)
    @StateObject private var characters = Characters()
    private let anim = Anim()

    var body: some Scene {
        WindowGroup {
            PhoneRoot(fleet: fleet, characters: characters, anim: anim)
                .preferredColorScheme(.dark)
        }
    }
}

private let ground = Color(red: 0.1, green: 0.09, blue: 0.15)

struct PhoneRoot: View {
    @ObservedObject var fleet: Fleet
    @ObservedObject var characters: Characters
    let anim: Anim
    @State private var tab = UserDefaults.standard.integer(forKey: "startTab")  // `-startTab 1` opens the ledger
    @State private var photo: PhotosPickerItem?
    @State private var started = false
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $tab) {
            ScrollView {
                RootView(fleet: fleet, characters: characters, anim: anim)
            }
            .background(ground.ignoresSafeArea())
            .tabItem { Label("Live", systemImage: "gauge.with.dots.needle.67percent") }
            .tag(0)

            LedgerTab(store: fleet.current)
                .id(fleet.current.host.id)  // a fresh ledger for each Mac
                .background(ground.ignoresSafeArea())
                .tabItem { Label("Ledger", systemImage: "book.closed") }
                .tag(1)

            ScrollView {
                MacsView(fleet: fleet)
            }
            .background(ground.ignoresSafeArea())
            .tabItem { Label("Macs", systemImage: "desktopcomputer") }
            .tag(2)
        }
        .tint(Color(red: 1, green: 0.85, blue: 0.5))
        .onAppear {
            guard !started else { return }
            started = true
            fleet.onOpenLedger = { tab = 1 }
            fleet.onOpenMacs = { tab = 2 }
            fleet.start()
            if fleet.watched.isEmpty { tab = 2 }  // first launch: pair a Mac
        }
        .photosPicker(isPresented: $characters.pickingPhoto, selection: $photo, matching: .images)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    try? await characters.add(imageData: data, name: "Photo \(characters.photos.count + 1)")
                }
                photo = nil
            }
        }
        // Pause the animation and polling work that only matters on screen.
        .onChange(of: phase) { _, p in fleet.stores.forEach { $0.visible = p == .active } }
    }
}

/// The ledger for the selected Mac. Owns its Ledger so it's created once per Mac, not on every redraw.
struct LedgerTab: View {
    @StateObject private var ledger: Ledger

    init(store: GPUStore) {
        _ledger = StateObject(wrappedValue: Ledger(client: store.client, hostName: store.host.title,
                                                   machine: store.snap?.host?.model_name ?? "Mac"))
    }

    var body: some View { LedgerView(ledger: ledger) }
}
