# GPU Buddy

Meet **Chippy**, a kitty-eared chip who runs as hard as your GPU does.

- `daemon/gpud.py`: a daemon that reads Apple Silicon GPU stats from the IORegistry (no sudo needed) and serves them on `http://127.0.0.1:8765`. It uses only the Python standard library.
- `app/GPUBuddy.swift`: a small native SwiftUI window that animates those stats. The Dock icon shows the live %.

## Install

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
| `GET /api/v1/stream` | Server-Sent Events, one snapshot per second |

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
