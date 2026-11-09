# GPU Buddy for the Mac App Store

A sandboxed edition of the Mac app, built from the same shared views (`../GPUBuddy.swift`, `../mac/Router.swift`)
with `APPSTORE` set, plus a native Mac shell (`GPUBuddyStoreApp.swift`): sidebar of Macs, toolbar, Settings
window, menu commands, empty states and a first-run Getting Started guide. The DMG app (`../build.sh`) and the
iPhone/iPad app are unchanged.

It uses the iPhone/iPad app's bundle ID, `com.miulabs.gpubuddy`, so it ships on the same App Store listing
(universal purchase) and replaces "Designed for iPad" on Macs.

## What the sandbox allows

| | DMG app | App Store edition |
|---|---|---|
| Install / remove gpud (LaunchAgent, Python) | yes | no: the user runs `install.sh --service-only` (shown in the app) |
| This Mac with gpud running (loopback `127.0.0.1:8765`) | yes | yes: everything (power, apps, tokens, ledger, router, request log) |
| This Mac without gpud | nothing | GPU load + GPU memory + chip, from the GPU's IORegistry entry (`NativeFeed.swift`) |
| GPU power (IOReport), temperature (SMC), per-app GPU use | via gpud | via gpud only (sandbox denies IOReport subscriptions, SMC and other processes) |
| Paired Macs over TLS, Bonjour discovery | yes | yes (`network.client`, local network prompt) |
| Demo Mac | yes | yes (for App Review and first-time users) |
| Photo characters | yes | yes (Open panel, `files.user-selected.read-only`) |
| "Show the request log in Finder" | yes | hidden (the file is outside the container) |

Entitlements: `app-sandbox`, `network.client`, `files.user-selected.read-only`. Hardened runtime.

## Build

```
app/appstore/build-sandbox-test.sh     # "GPU Buddy Sandbox Test.app" in dist/appstore-mac-test/ (Developer ID, not notarized,
                                       # bundle ID com.miulabs.gpubuddy.sandboxtest so it never mixes with the real app)
app/appstore/testflight.sh 1 upload    # archive + upload to App Store Connect (needs the macOS platform on the app record)
```

Launch options for screenshots: `-tutorialDone YES`, `-tutorialStep 0…3`, `-startTab overview|live|ledger`,
`-showPairing YES`, `-showSettings YES`, `-appearance light|dark`, `-demoMac on -selectedHost demo`;
`GPUD_PORT=8799` (env) simulates a Mac without gpud.
