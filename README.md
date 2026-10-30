# GPU Buddy

Meet **Chippy**, a kitty-eared chip who runs as hard as your GPU does.

- `daemon/gpud.py`: a daemon that reads Apple Silicon GPU stats from the IORegistry (no sudo needed) and serves them on `http://127.0.0.1:8765`. It uses only the Python standard library.
- `app/GPUBuddy.swift`: a small native SwiftUI window that animates those stats. The Dock icon shows the live %.

## Download

Get the DMG from [Releases](https://github.com/amiu888/gpu-buddy/releases/latest), drag GPU Buddy into Applications, and open it. It offers to install its background service. The build isn't notarized, so the first time use **System Settings → Privacy & Security → Open Anyway**. Requires an Apple Silicon Mac with macOS 14 or later.

To make a DMG yourself, run `./release.sh`. It writes `dist/GPU-Buddy-<version>.dmg`.

## iPhone and iPad

GPU Buddy also runs on iPhone and iPad (iOS 17+), as a viewer for your Macs. A phone can't run gpud, so it pairs with Macs that do, over the same encrypted connection. It has three tabs: **Live** (Chippy, GPU, tokens, power, processes, timeline), **Ledger** (token usage, energy and cloud cost) and **Macs** (find and pair Macs). Characters work too, including new ones from your photo library.

To install on your own device (needs Xcode and a free or paid Apple developer account signed in to Xcode):

```bash
./app/build-ios.sh device      # builds, signs with your Apple Development certificate, installs on a connected iPhone/iPad
./app/build-ios.sh sim         # or try it in the iOS Simulator
```

Unlock the device and connect it by USB or the same Wi-Fi first, with Developer Mode on (Settings → Privacy & Security). On first launch, allow **Local Network** access, then pair a Mac in the **Macs** tab with its pairing code. The phone needs to be on the same network as the Mac.

The views are shared: `app/GPUBuddy.swift` is used by both apps, `app/mac/main.swift` is the Mac shell, and `app/ios/GPUBuddyApp.swift` is the iOS shell.

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
| `GET /api/v1/cost?preset=today&cache_hit=0.5&batch=1` | what the period's tokens would cost on frontier cloud models |
| `GET /api/v1/explain?pid=N` | what a busy script is doing, in plain English, with the evidence used |
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

**Time to first token** = how long the model took to start answering, which is mostly the time spent reading the prompt. The app shows it next to the model name (`⏱ 1st token 2.4 s · avg 1.8 s`): the latest request, and the average over the server's recent requests. It comes from `ttft_s` in an MLX server's `/metrics`, or the `time_to_first_token_seconds` histogram for vLLM and SGLang (average only). In the API it's `tokens.ttft_s`, `tokens.ttft_avg_s` and `tokens.ttft_model`, plus `ttft_s` / `ttft_avg_s` on each source.

**Who's asking** (Settings → Who's Using My LLM, off by default): GPU Buddy sits in front of your LLM server on its usual port (8080) and shows each request live: the agent (Claude Code, Cline, Codex, curl…), which program or device sent it, prompt and answer tokens, and time to first token. Optionally it keeps the first 100 characters of the user's message. Your server moves to the next port (8081) for this Mac only; GPU Buddy edits the one line of its start script or LaunchAgent that sets the port, keeps a backup, and puts it back when you turn this off or remove the service. Only this Mac and the addresses you allow can use the server, and you can require an API key from other devices. The log stays on this Mac (`~/Library/Application Support/GPUBuddy/llm-requests.jsonl`, readable by you only) for 7 days and never holds request headers, whole prompts or answers. Snippets aren't sent to paired Macs or web pages. The proxy lives in `daemon/llmproxy.py`; the API is `GET/POST /api/v1/llm-proxy` (this Mac only).

**LLM Router** (menu → LLM Router…, ⌘E): a diagram of who connects, through which entry port, to which LLM server.
- **Servers:** GPU Buddy finds the LLM servers on this Mac every 15 seconds (Kapitsa, Ollama, LM Studio, llama.cpp, MLX, vLLM, SGLang…) with their models. You can add others by address.
- **Entry ports:** each port GPU Buddy listens on is open to the whole network or to this Mac only. It either always uses one server, or sends each request to the server that has the model it names, falling back to a default server.
- **Model list:** `GET /v1/models` on such a port lists every server's models.
- **Client keys:** make one per app or device, for all entry ports or only some. The panel shows ready-to-paste settings (base URL, key, model) and when the key was last used.
- **Access:** devices on the allow list get in without a key, unless "every other device also needs a client key" is on. This Mac is always allowed.
- **Warnings:** a server that also listens on the network by itself is flagged, since devices could skip GPU Buddy.
- **Copy buttons:** every address, model name and client setup can be copied with one click.
- **Models…:** what's in use (which clients, requests in the last 24 hours, tokens per second), what's on this Mac, what's on the NAS (copy it to this Mac), and Ollama's whole library from ollama.com (download any size into Ollama, with progress). The API is `GET/POST /api/v1/llm-proxy/models` (this Mac only; see `daemon/modellib.py`).
- Open it from the little router with antennas in the main window's top-right corner. Its eyes are green when the router is on and blink while apps are asking.

The **TOKENS** section lists every loaded LLM (Kapitsa's model, and each model Ollama holds in memory) with its tokens per second on the right. The speed of the last answer stays until the next request, and the row goes when the model is unloaded. Below each name are the tokens it read and generated in the last 24 hours. Each **Who's asking** item shows the LLM on one line and its tokens on the next: read, written, tokens per second and time to first token.

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

The whole Mac is measured too, from its power controller (the SMC's total system power, also without sudo). On a Mac Studio the fans, SSD, ports and network add about 9 W on top of the chip. The ledger shows two electricity rows next to the cloud prices:

- **Chip only**
- **Whole Mac (at the wall)**: the SMC reading plus ~10% power-supply loss

If power was measured for only part of a period (for example, before the update that added it), the rest is filled in at the measured average power, and the ledger says so.

The Token Ledger shows GPU and whole-chip energy for any period, the energy that went into tokens, what the chip's electricity cost (set your price per kWh), and what the same tokens would cost on the Claude API at list prices. The whole Mac at the wall uses more than the chip: fans, SSD, display and power-supply losses aren't included.

## What is that script doing?

Activity Monitor says "python". GPU Buddy tells you, in plain English, what each busy script is doing, for example:

> It's currently analyzing images from your media folder, having processed about 800 of 131,000 so far, with about 36 hours left to finish.

How it works:

- gpud gathers evidence about the process:
  - the command and folder
  - the script's own description (the start of its code)
  - data files it has open, and the end of its log
  - which servers it talks to (local AI model servers are named with their model)
  - helper programs it started (ffmpeg, exiftool…)
- A **local** AI model server that already has a model loaded writes one or two sentences from that evidence. gpud never makes a server load a model for this, and nothing leaves your Mac.
- With no model loaded, a simpler sentence is built from the same evidence.
- Explanations are refreshed only when the progress changes, at most every 10 minutes per process. Each one costs a few hundred tokens of your local model, counted in the ledger like any other request.

The main window shows it in the **🗣 What's happening** card and under each script in the process list. `GET /api/v1/explain?pid=N` returns the explanation and the evidence it was based on. Set `GPUD_EXPLAIN=0` to turn it off, or `GPUD_EXPLAIN_URL=http://127.0.0.1:PORT` to choose the server.

## What would the cloud cost?

The Token Ledger estimates what the same tokens would have cost on frontier cloud models:

- **US providers:** Claude (Fable 5.1, Opus 5.5, Sonnet 5.5, Haiku 5.5), OpenAI (GPT-6 Astra, GPT-5.5, GPT-6.1 Sol, GPT-6 Luna) and Google (Gemini 4 Argon, 3.1 Pro, 3.8 Flash).
- **Chinese providers**, at their international USD prices: DeepSeek (V4 Pro, V4.1 Flash), Alibaba Qwen (3.8 Max, 3.7 Plus, 3.8 Flash), Moonshot Kimi K3, Zhipu GLM-5.3 and MiniMax M3.

Use the **All / US / China** switch to narrow the table. It shows the cost for the period, a 30-day projection at that pace, and how much running locally saved compared with your chip's electricity.

How it estimates:

- **Prompt tokens are priced as input** and **generated tokens as output**, at each model's list price.
- **Prompt cache hits** (default 0%, the worst case): this share of prompt tokens is billed at the much cheaper cached-input price. One in ten of those first pays the cache-write price.
- **Hidden thinking**: extra output tokens a cloud reasoning model spends before answering.
- **Tokenizer**: scales all counts, because each model family turns the same text into a different number of tokens.
- **Batch API**: 50% off, for work nobody waits on.

Prices are in `daemon/prices.json` with their date and sources. To change them, copy that file to `~/Library/Application Support/GPUBuddy/prices.json` and edit the copy. The API is `GET /api/v1/cost?preset=month&cache_hit=0.5&batch=1`.

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

## Characters

Click the 🎭 button on the scene, or press ⌘J to cycle through characters:

- **🐱 Chippy:** the kitty-eared chip.
- **🐰 Witch Bunny:** a chunky crocheted bunny in a witch hat, drawn stitch by stitch. She hops harder as the GPU works, her ears flap and her hat lags behind each hop. She naps with her hat drooping, sweats when hustling, and in turbo she hops on her broom and flies.
- **📷 Your photo:** use **Add Character from Photo…** to pick a photo of a toy, a pet, anything with a clear subject. Apple's Vision framework cuts it out of the background on your Mac, and it then hops, squashes and stretches with the GPU. Photo characters stay on your Mac in `~/Library/Application Support/GPUBuddy/characters`.

Every character gets the same moods, sparkles, sweat and Zzz.

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
