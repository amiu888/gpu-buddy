# GPU Buddy

Meet **Chippy**, a kitty-eared chip who runs as hard as your GPU does.

- `daemon/gpud.py`: a daemon that reads Apple Silicon GPU stats from the IORegistry (no sudo needed) and serves them on `http://127.0.0.1:8765`. It uses only the Python standard library.
- `app/GPUBuddy.swift`: a small native SwiftUI window that animates those stats. The Dock icon shows the live %.

## Download

Get the DMG from [Releases](https://github.com/amiu888/gpu-buddy/releases/latest), drag GPU Buddy into Applications, and open it. It offers to install its background service. The build isn't notarized, so the first time use **System Settings → Privacy & Security → Open Anyway**. Requires an Apple Silicon Mac with macOS 14 or later.

To make a DMG yourself, run `./release.sh`. It writes `dist/GPU-Buddy-<version>.dmg`.

## Install from source

```bash
./install.sh                      # installs gpud as a launchd agent and builds the app
open "app/GPU Buddy.app"
./uninstall.sh                    # removes the daemon
```

## API

| Endpoint | What you get |
|---|---|
| `GET /health` | `{"ok": true}` |
| `GET /api/v1/status` | utilization, mood, memory, top 5 GPU processes, fun stats |
| `GET /api/v1/processes` | every process that used the GPU in the last second |
| `GET /api/v1/history?seconds=86400&points=300` | bucketed timeline (avg/max util, memory, AI activity) |
| `GET /api/v1/at?t=<unix time>` | what the GPU was doing at that moment (same shape as `/status`) |
| `GET /api/v1/tokens` | local LLM servers found, tokens generated / used (prompt), live tok/s |
| `GET /api/v1/usage?preset=today\|week\|month\|ytd\|total` | token usage for a period: totals, a series and a per-model breakdown |
| `GET /api/v1/usage?from=<unix>&to=<unix>&group=hour\|day\|month` | the same for any date range |
| `GET /api/v1/usage/summary` | token totals for today, this week, this month, YTD and all time |
| `GET /api/v1/power` | chip power right now (GPU, CPU, Neural Engine, memory) and joules per token |
| `GET /api/v1/stream` | Server-Sent Events, one snapshot per second |
| `GET /api/v1/pairing` | this Mac's pairing code (only from this Mac, over 127.0.0.1) |

Each process comes with its full `command`, its working directory (`cwd`) and a readable `activity`, for example `mlx_vlm.server · Qwen3-VL-8B-Instruct-4bit`, `train.py --epochs 10`, or `Running llama3.2:3b` for Ollama.

## Tokens

gpud finds local LLM servers by looking for AI-looking processes that listen on a port, then reads their counters every second:

| Server | How |
|---|---|
| MLX servers with a JSON `/metrics` summary (e.g. `mlx_vlm.server`) | `summary.prompt_tokens_total` / `completion_tokens_total` |
| llama.cpp `llama-server --metrics`, vLLM, SGLang | Prometheus `/metrics` |
| Ollama | detected, but Ollama doesn't report token counts |
| anything else | set `GPUD_TOKEN_URLS=http://127.0.0.1:9000,...` in the launchd plist |

**Generated** = output tokens written by the model. **Used** = prompt tokens it read. Both are counted while gpud is running.

Token usage is kept **forever**, per hour and per model, so the Token Ledger can show any period. Weeks start on the day your Mac's calendar uses (`week_start=1` for Sunday, `2` for Monday in the API).

## Power

gpud reads the chip's own energy counters (IOReport, the same source as `powermetrics`) through a tiny helper, `daemon/gpupower.c`. gpud compiles it with `clang` on first run, and no sudo is needed. You get:

| Metric | Meaning |
|---|---|
| GPU / CPU / Neural Engine / memory / rest-of-chip watts | live, every second, also in the 24h timeline (orange line) |
| GPU peak | highest GPU watts since gpud started |
| AI watts | the GPU+ANE power used by local LLM servers: their share of GPU time while they work |
| J per token (live) | AI watts ÷ decode speed, while a model is generating |
| tokens per Wh | the same, upside down |
| J per token (average) | AI energy ÷ generated tokens, prompt reading included |
| energy per model | GPU energy is assigned to the models that produced the tokens, kept forever per hour |

The Token Ledger shows GPU and whole-chip energy for any period, the energy that went into tokens, what the chip's electricity cost (set your price per kWh), and what the same tokens would cost on the Claude API at list prices. The whole Mac at the wall uses more than the chip: fans, SSD, display and power-supply losses aren't included.

## Watching other Macs

Install gpud on every Mac you want to watch (`./install.sh`), then open GPU Buddy on any of them:

1. On the Mac to be watched, open GPU Buddy → **Macs (⌘K)** and copy the pairing code under **Share this Mac** (or run `python3 daemon/gpud.py --pairing-code`).
2. On the watching Mac, open **Macs (⌘K)**. Macs running gpud on your network show up by themselves (Bonjour). Click **Pair…** and paste the code, or add one by address (`Studio.local` or an IP).
3. Each Mac gets a chip under Chippy with its live %. Click one, or press ⌘] / ⌘[, to switch. The Token Ledger follows the selected Mac.

Every Mac reports who it is: its name, model (e.g. Mac Studio, Mac16,9), chip, GPU and CPU cores, memory, macOS version, network name (`Studio.local`) and the IP address of each active interface (Ethernet, Wi-Fi…). The Macs window shows this with the connection's encryption and latency, and hovering a Mac's chip shows all of it. If a Mac is renamed, the new name shows up on its own. The same info is in `/health`, in every `/status` snapshot (`host`), and in the Bonjour record, so Macs on the network are identified before you pair.

How it's protected:

- Other Macs reach gpud over **TLS** on port 8766. The plain-HTTP API on 8765 only listens on 127.0.0.1.
- The pairing code is a random access token plus the fingerprint of that Mac's certificate. The app checks the fingerprint before sending anything, so another machine can't pretend to be your Mac. Every request without the right token gets a 401.
- The certificate, private key and token live in `~/Library/Application Support/GPUBuddy/` and only you can read them. Paired Macs are saved, readable only by you, in `viewer-hosts.json` in the same folder.
- `python3 daemon/gpud.py --new-pairing-code` makes a new code (every paired Mac has to pair again). Start gpud with `--remote-port 0` to turn remote viewing off.
- If the macOS firewall blocks incoming connections, allow Python when asked, or add it under System Settings → Network → Firewall.
- The first time GPU Buddy looks for Macs, macOS asks for Local Network access. Allow it.

GPU history is kept for 24 hours in `~/Library/Application Support/GPUBuddy/history.db` (SQLite) and survives restarts.

Memory is what the GPU has allocated out of unified memory, similar to "VRAM used". The TFLOPS and "ops crunched" numbers are estimates: cores × 128 ALUs × 2 × ~1.5 GHz.

## What Chippy does

| GPU load | Mood | Animation |
|---|---|---|
| < 5% | napping | eyes closed, Zzz, slow breathing |
| 5–30% | chilling | strolls, blinks |
| 30–70% | working | runs, propeller spins, tail wags, hearts float up |
| 70–90% | hustling | sprints, sweats, grins |
| 90%+ | turbo | rocket flames, `> <` eyes, everything glows red |

When an AI/ML process (ollama, mlx, python, LM Studio, ComfyUI…) is using the GPU, the hearts turn into math glyphs (λ ∑ π ∂) and an "AI at work" badge appears.

## Using the window

- **Timeline:** hover the HISTORY strip (1h / 6h / 24h) to peek at what was running at that moment. Drag to rewind: Chippy, the cores, memory and process list all replay that moment. Click **LIVE** to come back.
  - The colored band under the chart shows which process was doing the work. The legend lists the busiest ones; click one to jump to when it was last running.
- **Moving the window:** drag Chippy's scene or the title bar. The rest of the window doesn't move, so the timeline can be dragged.
- **Processes:** hover a row to see the full command and folder. Right-click to copy the command.
- **Tokens:** the GENERATED / USED cards show 24h totals and live tok/s. Hover them to see each server and its lifetime totals. Gold marks on the timeline show when tokens were being generated.
- **Token Ledger (⌘L, or click the token cards):** all-time token usage with filters for Today, Week, Month, YTD and All time, plus Custom: a single day, a month, or a from–to range. It shows generated / used / total, a bar chart (hover for details) and a per-model breakdown.
- **Compact mode:** click the ⇕ button or press ⌘1 for a tiny strip with mini Chippy, the %, memory and the top process.

The animation pauses when the window is minimized or hidden, so it costs nothing in the background. ⌘T keeps the window on top and ⌘M minimizes it to the Dock.

## License

MIT, see [LICENSE](LICENSE).
