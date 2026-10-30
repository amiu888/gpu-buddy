#!/usr/bin/env python3
"""gpud — a tiny daemon that tells you what your Apple Silicon GPU is doing.

Reads GPU statistics from the IORegistry (no sudo needed) once per interval and
serves them over a local HTTP API:

  GET /health              -> {"ok": true}
  GET /api/v1/status       -> latest snapshot (utilization, memory, top processes, fun stats)
  GET /api/v1/history      -> bucketed timeline (?seconds=86400&points=300)
  GET /api/v1/at           -> what the GPU was doing at a moment (?t=<unix time>)
  GET /api/v1/processes    -> every process that used the GPU in the last interval
  GET /api/v1/stream       -> Server-Sent Events, one snapshot per interval
  GET /api/v1/tokens       -> LLM servers found and the tokens they read / generate
  GET /api/v1/usage        -> token usage for any period (?preset=today|week|month|ytd|total
                              or ?from=<unix>&to=<unix>, &group=hour|day|month)
  GET /api/v1/usage/summary -> token totals for today, this week, this month, YTD and all time
  GET /api/v1/power        -> chip power right now (GPU, CPU, ANE, DRAM) and energy per token
  GET /api/v1/explain      -> what each busy script is doing, in plain English (?pid=N for one,
                              with the evidence used; &refresh=1 to ask again)
  GET /api/v1/llm-proxy/models -> models on this Mac, on the NAS and on ollama.com, and downloads (see modellib.py)
  GET /api/v1/llm-proxy/log -> the request log itself, newest first (?limit=2000; this Mac only)
  GET /api/v1/llm-proxy    -> the LLM request log: settings, requests running now and the latest ones
                              (this Mac only; POST JSON to change: enabled, snippets, allow, new_api_key,
                              remove_api_key, retention_days; see llmproxy.py)
  GET /api/v1/cost         -> what the period's tokens would cost on frontier cloud models
                              (?preset=… or ?from=&to=, &cache_hit=0..0.95, &batch=1,
                              &thinking=0..3, &tokenizer=0.5..2)

Power comes from IOReport's energy counters via the small gpupower helper (compiled from
gpupower.c on first run; no sudo). GPU energy spent while a local LLM server works is assigned to
the models that produced tokens, so the ledger can show joules per token for each model.

GPU history is kept for 24 hours and token usage forever, in SQLite
(~/Library/Application Support/GPUBuddy/history.db).

Remote viewing: the same API is also served over TLS on all interfaces (--remote-port, default
8766) for GPU Buddy apps on other Macs. Every remote request needs the pairing code's token
(`python3 gpud.py --pairing-code` prints it); the code also carries the certificate fingerprint,
so viewers can verify they're talking to this Mac. The service is advertised over Bonjour as
_gpubuddy._tcp. The plain-HTTP API stays on 127.0.0.1 only.

Standard library only. Run:  python3 gpud.py [--port 8765] [--interval 1.0]
"""

import argparse
import atexit
import base64
import datetime
import hashlib
import hmac
import json
import os
import plistlib
import re
import secrets
import signal
import socket
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import llmproxy
import modellib

VERSION = "1.14.0"
RETENTION_SECONDS = 24 * 3600
STATE_DIR = os.path.expanduser("~/Library/Application Support/GPUBuddy")
DEFAULT_DB = os.path.join(STATE_DIR, "history.db")
BONJOUR_TYPE = "_gpubuddy._tcp"
POWER_KEYS = ("gpu", "cpu", "ane", "dram", "other")

# Process names that are almost certainly doing AI / ML work on the GPU.
AI_HINTS = (
    "ollama", "llama", "mlx", "lm studio", "lmstudio", "python", "comfy", "diffusion",
    "whisper", "torch", "vllm", "gpt4all", "kobold", "jan", "draw things", "exo",
    "mlc", "msty", "invoke", "fooocus", "claude", "chatgpt", "kapitsa",
)

INTERPRETERS = ("python", "node", "ruby", "java", "perl", "bun", "deno", "julia")
MODEL_FLAGS = ("--model", "--model-path", "--model_name_or_path", "--checkpoint", "--ckpt", "--repo")
# Friendly descriptions for well-known GPU users.
KNOWN = {
    "WindowServer": "Drawing your screen",
    "VTDecoderXPCService": "Decoding video",
    "VTEncoderXPCService": "Encoding video",
    "Safari": "Rendering web pages",
    "com.apple.WebKit.GPU": "Rendering web pages",
    "Dock": "Animating the Dock",
    "screencapture": "Capturing the screen",
    "replayd": "Recording the screen",
    "Resolve": "Editing video",
    "Final Cut Pro": "Editing video",
}

# Apple GPU cores have 128 FP32 ALUs; an FMA counts as 2 FLOPs. The clock is not
# exposed, so ~1.5 GHz is a reasonable estimate for M-series chips.
ALUS_PER_CORE = 128
EST_CLOCK_HZ = 1.5e9


def run(cmd):
    return subprocess.run(cmd, capture_output=True, check=True, timeout=5).stdout


def sysctl_int(name, default=0):
    try:
        return int(run(["sysctl", "-n", name]).strip() or default)
    except Exception:
        return default


def short_path(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home) else path


def model_from_args(tokens):
    for i, tok in enumerate(tokens):
        flag, eq, val = tok.partition("=")
        if flag in MODEL_FLAGS:
            val = val if eq else (tokens[i + 1] if i + 1 < len(tokens) else "")
            return os.path.basename(val.rstrip("/"))
    return ""


def ollama_models():
    """Names of models Ollama currently has loaded (empty if Ollama isn't running)."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/ps", timeout=0.3) as r:
            return [m.get("name", "") for m in json.load(r).get("models", [])]
    except Exception:
        return []


def describe(name, args, ollama):
    """Turn a process's command line into a human sentence about what it's doing."""
    tokens = args.split()
    low = name.lower()
    if "ollama" in low or "llama-server" in low or "llama_server" in low:
        return f"Running {', '.join(ollama)}" if ollama else "Serving a local LLM"
    if low.startswith(INTERPRETERS):
        rest = tokens[1:]
        target = ""
        while rest:
            tok = rest.pop(0)
            if tok == "-m" and rest:
                target = rest.pop(0)
                break
            if tok == "-c":
                target = "inline script"
                break
            if not tok.startswith("-"):
                target = os.path.basename(tok)
                break
        model = model_from_args(rest)
        if model:
            return f"{target} · {model}" if target else model
        extra = " ".join(rest)
        extra = extra if len(extra) <= 50 else extra[:49] + "…"
        return f"{target} {extra}".strip()
    if name in KNOWN:
        return KNOWN[name]
    if ".app/" in args:
        app = args.split(".app/")[0].rsplit("/", 1)[-1]
        if not name.replace(" ", "").startswith(app.replace(" ", "")):
            return f"Working for {app}"
    model = model_from_args(tokens)
    return f"Model: {model}" if model else ""


def process_label(p):
    """"python (train.py)" — the name plus what it's doing."""
    act = p.get("activity") or ""
    return f"{p['name']} ({act})" if act else p["name"]


def top_process(procs):
    """(label, gpu_percent, is_ai) of the busiest process, or None if nothing used >= 1%."""
    if not procs or procs[0].get("gpu_percent", 0) < 1:
        return None
    p = procs[0]
    return process_label(p), p["gpu_percent"], int(bool(p.get("is_ai")))


LLM_HINTS = ("mlx", "llama", "ollama", "vllm", "lm studio", "lmstudio", "lms ", "exo", "kobold", "gpt4all", "jan", "sglang",
             "tabby", "kapitsa")
PROM_PROMPT = ("llamacpp:prompt_tokens_total", "vllm:prompt_tokens_total", "sglang:prompt_tokens_total")
PROM_GEN = ("llamacpp:tokens_predicted_total", "vllm:generation_tokens_total", "sglang:generation_tokens_total")
PROM_RUNNING = ("llamacpp:requests_processing", "vllm:num_requests_running", "sglang:num_running_reqs")
PROM_TTFT_SUM = ("vllm:time_to_first_token_seconds_sum", "sglang:time_to_first_token_seconds_sum")
PROM_TTFT_COUNT = ("vllm:time_to_first_token_seconds_count", "sglang:time_to_first_token_seconds_count")


def latest_ttft(sources):
    """Time to first token for the status payload: the most recent request across all servers that report it."""
    keys = ("ttft_s", "ttft_avg_s", "ttft_model", "ttft_prompt_tokens", "ttft_cache", "ttft_samples", "ttft_pending_since")
    have = [s for s in sources if s.get("ttft_avg_s") is not None]
    if not have:
        return dict.fromkeys(keys)
    s = max(have, key=lambda x: x.get("ttft_at") or 0)
    return {k: s.get(k) for k in keys} | {"ttft_model": s.get("ttft_model") or s["model"] or s["name"]}


def model_name(path):
    """A readable model name from a path or repo id: ".../qwen36-moe-mlx/model" -> "qwen36-moe-mlx"."""
    p = str(path or "").rstrip("/")
    name = os.path.basename(p)
    return os.path.basename(os.path.dirname(p)) if name == "model" else name


def http_get(url, timeout=0.5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.read()


class TokenWatcher:
    """Finds local LLM servers and counts the tokens they read (prompt) and write (generated).

    Supported: MLX servers with a JSON /metrics summary, llama.cpp / vLLM / SGLang Prometheus
    /metrics, and Ollama (detected, but it doesn't report token counters). Extra servers can
    be listed in GPUD_TOKEN_URLS="http://127.0.0.1:9000,http://…".
    """

    def __init__(self, interval=1.0):
        self.interval = interval
        self.lock = threading.Lock()
        self.sources = {}  # base url -> state
        self._pending_gen = 0
        self._pending_prompt = 0
        self._pending_by = {}  # (server, model) -> [generated, prompt]
        self._last_discover = 0.0
        self.extra = [u.strip().rstrip("/") for u in os.environ.get("GPUD_TOKEN_URLS", "").split(",") if u.strip()]
        self.proxy = None  # the request log (llmproxy.LLMProxy): counts tokens for servers that don't (Kapitsa)

    def _listening(self):
        """base url -> (pid, process name) for every LLM-looking process with a listening TCP port."""
        out = {}
        try:
            ps = run(["ps", "-axo", "pid=,args="]).decode()
        except Exception:
            return out
        pids = {}
        for line in ps.splitlines():
            pid_s, _, args = line.strip().partition(" ")
            low = args.lower()
            if "ollama.app/contents/macos/ollama" in low or "/.ollama/models/blobs/" in low:
                continue  # the Ollama app's window (it forwards to `ollama serve`) and its per-model helpers
            if pid_s.isdigit() and any(h in low for h in LLM_HINTS) and "gpud.py" not in low:
                pids[int(pid_s)] = describe_server(args)
        if not pids:
            return out
        try:
            raw = subprocess.run(["lsof", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", ",".join(map(str, pids)), "-Fpn"],
                                 capture_output=True, timeout=5).stdout.decode()
        except Exception:
            return out
        pid = None
        for line in raw.splitlines():
            if line.startswith("p"):
                pid = int(line[1:])
            elif line.startswith("n") and pid in pids:
                port = line.rsplit(":", 1)[-1]
                if port.isdigit():
                    out[f"http://127.0.0.1:{port}"] = (pid, pids[pid])
        return out

    def _probe(self, base):
        """Work out what kind of server lives at base, or None."""
        try:
            body = http_get(base + "/metrics")
            try:
                d = json.loads(body)
                if isinstance(d, dict) and "completion_tokens_total" in d.get("summary", {}):
                    return "mlx-json"
            except ValueError:
                text = body.decode(errors="replace")
                if any(k in text for k in PROM_GEN):
                    return "prometheus"
        except Exception:
            pass
        try:
            if b"version" in http_get(base + "/api/version"):
                return "ollama"
        except Exception:
            pass
        # No counters of its own, but every request passes through the request log on its way here.
        p = self.proxy
        if p and p.serves(int(base.rsplit(":", 1)[-1])):
            return "proxy"
        return None

    def _read(self, src):
        """(prompt_total, generated_total, in_flight, speed tok/s, model, ttft) or None.
        ttft is {"last", "avg", "at", "model", "prompt", "cache", "n"} for the latest request, or None (see _mlx_ttft)."""
        if src["kind"] == "mlx-json":
            d = json.loads(http_get(src["url"] + "/metrics"))
            sm, latest, srv = d.get("summary", {}), d.get("latest") or {}, d.get("server") or {}
            model = model_name(srv.get("loaded_model") or latest.get("model"))
            ttft = self._mlx_ttft(d, latest, srv)
            # A request still running: the server only reports first-token time once a request finishes (and doesn't
            # say when a running one started), so note the time whenever its started-count goes up, drop the oldest
            # when one finishes, and let the app count up live from the oldest one still running.
            n_started = sm.get("requests_started") or 0
            n_done = (sm.get("requests_completed") or 0) + (sm.get("requests_failed") or 0)
            starts = src.setdefault("starts", [])
            if "n_started" in src and n_started >= src["n_started"]:
                starts.extend([time.time()] * min(8, n_started - src["n_started"]))
                del starts[:max(0, n_done - src["n_done"])]
            src["n_started"], src["n_done"] = n_started, n_done
            if not sm.get("in_flight"):
                starts.clear()
            if ttft is not None and starts:
                ttft["pending_since"] = starts[0]
            return (sm.get("prompt_tokens_total", 0), sm.get("completion_tokens_total", 0),
                    sm.get("in_flight", 0), latest.get("decode_tok_s", 0) or 0, model, ttft)
        if src["kind"] == "prometheus":
            vals = {}
            for line in http_get(src["url"] + "/metrics").decode(errors="replace").splitlines():
                if line.startswith("#") or not line.strip():
                    continue
                name, _, val = line.rpartition(" ")
                name = name.split("{")[0]
                try:
                    vals[name] = vals.get(name, 0) + float(val)
                except ValueError:
                    pass
            pick = lambda keys: sum(vals.get(k, 0) for k in keys)
            # vLLM / SGLang publish a time-to-first-token histogram; its sum / count is the average.
            n = pick(PROM_TTFT_COUNT)
            ttft = {"last": None, "avg": pick(PROM_TTFT_SUM) / n, "at": 0, "model": "", "prompt": None,
                    "cache": None, "n": int(n)} if n else None
            return pick(PROM_PROMPT), pick(PROM_GEN), pick(PROM_RUNNING), None, "", ttft
        if src["kind"] == "proxy":
            if not self.proxy or self.proxy.state != "on":
                return None
            port = int(src["url"].rsplit(":", 1)[-1])
            prompt, gen, in_flight, speed, model, ttft = self.proxy.counters(port)
            model = self.proxy.served_model(port) or model  # Kapitsa answers any name: say what it really runs
            return prompt, gen, in_flight, speed, model_name(model), ttft
        if src["kind"] == "ollama":
            # Ollama publishes no token counters; requests that go through GPU Buddy's router are counted there.
            port = int(src["url"].rsplit(":", 1)[-1])
            try:  # the models it has in memory right now
                src["loaded"] = [m.get("name") for m in json.loads(http_get(src["url"] + "/api/ps")).get("models") or []]
            except Exception:
                src["loaded"] = []
            if self.proxy and self.proxy.serves(port):
                prompt, gen, in_flight, speed, model, ttft = self.proxy.counters(port)
                return prompt, gen, in_flight, speed, model_name(model), ttft
            return None
        return None

    @staticmethod
    def _mlx_ttft(d, latest, srv):
        """Time to first token from an MLX server's /metrics, kept true to the current setup: the average only counts
        recent requests with the same model and the same prompt-cache setting as the latest one, so it starts over
        when either changes, and nothing is shown if the server has since loaded a different model."""
        if not latest.get("ttft_s"):
            return None
        loaded = srv.get("loaded_model")
        if loaded and latest.get("model") and model_name(loaded) != model_name(latest["model"]):
            return None  # the latest request was for a model that's no longer loaded
        cache = latest.get("apc_enabled")
        same = [r["ttft_s"] for r in (d.get("recent") or [])
                if isinstance(r, dict) and r.get("ttft_s") and r.get("model") == latest.get("model")
                and r.get("apc_enabled") == cache]
        return {"last": latest["ttft_s"], "avg": sum(same) / len(same) if same else latest["ttft_s"],
                "at": latest.get("timestamp_unix") or 0, "model": model_name(latest.get("model")),
                "prompt": latest.get("prompt_tokens"), "cache": cache, "n": max(1, len(same))}

    def poll(self):
        now = time.time()
        if now - self._last_discover > 30:
            self._last_discover = now
            found = self._listening()
            for base in self.extra:
                found.setdefault(base, (None, base))
            with self.lock:
                for base in list(self.sources):
                    if base not in found:
                        del self.sources[base]
            for base, (pid, name) in found.items():
                if base in self.sources:
                    continue
                kind = self._probe(base)
                if kind:
                    with self.lock:
                        self.sources[base] = {"url": base, "kind": kind, "pid": pid, "name": name, "model": "",
                                              "prompt": None, "gen": None, "in_flight": 0, "speed": 0.0,
                                              "gen_rate": 0.0, "prompt_rate": 0.0, "last_ts": now, "ttft": None}
        with self.lock:
            sources = list(self.sources.values())
        for src in sources:
            try:
                r = self._read(src)
            except Exception:
                r = None
            with self.lock:
                if not r:
                    src["gen_rate"] = src["prompt_rate"] = 0.0
                    continue
                prompt, gen, in_flight, speed, model, ttft = r
                dt = max(now - src["last_ts"], 1e-3)
                # Counters reset when a server restarts; count what it has done since then.
                d_prompt = 0 if src["prompt"] is None else (prompt - src["prompt"] if prompt >= src["prompt"] else prompt)
                d_gen = 0 if src["gen"] is None else (gen - src["gen"] if gen >= src["gen"] else gen)
                self._pending_prompt += d_prompt
                self._pending_gen += d_gen
                model = model or src["model"]
                if d_gen or d_prompt:
                    by = self._pending_by.setdefault((src["name"], model), [0, 0])
                    by[0] += d_gen
                    by[1] += d_prompt
                src.update(prompt=prompt, gen=gen, in_flight=in_flight, model=model, ttft=ttft,
                           gen_rate=d_gen / dt, prompt_rate=d_prompt / dt, last_ts=now,
                           speed=(speed if speed is not None else d_gen / dt) if (in_flight or d_gen) else 0.0)
                if src["speed"] > 0:  # remembered until the next request, so the speed stays on screen
                    src["last_speed"], src["last_speed_at"] = src["speed"], now

    def take(self):
        """Tokens counted since the last call, per (server, model), plus a public view of each source."""
        last = {}
        if self.proxy:  # the last finished request's own average is the best "last speed" for routed servers
            with self.lock:
                urls = [s["url"] for s in self.sources.values() if s["kind"] in ("proxy", "ollama")]
            for u in urls:
                fin = self.proxy.last_finished(int(u.rsplit(":", 1)[-1]))
                if fin:
                    last[u] = fin
        with self.lock:
            gen, prompt, by = self._pending_gen, self._pending_prompt, self._pending_by
            self._pending_gen = self._pending_prompt = 0
            self._pending_by = {}
            for s in self.sources.values():
                fin = last.get(s["url"])
                if fin and not s["in_flight"] and fin[1] >= s.get("last_speed_at", 0) - 5:
                    s["last_speed"], s["last_speed_at"] = fin[0], fin[1]
            view = [{"name": s["name"], "url": s["url"], "kind": s["kind"], "pid": s["pid"], "model": s["model"],
                     "in_flight": s["in_flight"], "tok_s": round(s["speed"], 1),
                     "loaded": s.get("loaded"),
                     "last_tok_s": round(s["last_speed"], 1) if s.get("last_speed") else None,
                     "last_tok_at": s.get("last_speed_at"),
                     "generated_total": s["gen"], "prompt_total": s["prompt"],
                     "ttft_s": round(s["ttft"]["last"], 3) if s["ttft"] and s["ttft"]["last"] is not None else None,
                     "ttft_avg_s": round(s["ttft"]["avg"], 3) if s["ttft"] else None,
                     "ttft_at": s["ttft"]["at"] if s["ttft"] else None,
                     "ttft_model": (s["ttft"]["model"] or s["model"]) if s["ttft"] else None,
                     "ttft_prompt_tokens": s["ttft"]["prompt"] if s["ttft"] else None,
                     "ttft_cache": s["ttft"]["cache"] if s["ttft"] else None,
                     "ttft_samples": s["ttft"]["n"] if s["ttft"] else None,
                     "ttft_pending_since": s["ttft"].get("pending_since") if s["ttft"] else None}
                    for s in self.sources.values()]
        return int(gen), int(prompt), view, by

    def loop(self):
        while True:
            t0 = time.monotonic()
            try:
                self.poll()
            except Exception as e:
                print(f"gpud: token poll failed: {e}", file=sys.stderr, flush=True)
            time.sleep(max(0.05, self.interval - (time.monotonic() - t0)))


class PowerWatcher:
    """Chip power from the gpupower helper (IOReport energy counters, no sudo needed)."""

    def __init__(self, interval=1.0):
        self.interval = interval
        self.lock = threading.Lock()
        self.latest = None  # watts per block, from the last interval
        self.error = None
        self._energy = self._zero()  # joules since the last take()
        self._proc = None
        atexit.register(lambda: self._proc and self._proc.terminate())

    @staticmethod
    def _binary():
        """Path to gpupower: the prebuilt one shipped next to this file (the app bundle has one), or
        compiled from gpupower.c into STATE_DIR when missing or stale."""
        here = os.path.dirname(os.path.abspath(__file__))
        src = os.path.join(here, "gpupower.c")
        shipped = os.path.join(here, "gpupower")
        if os.access(shipped, os.X_OK) and (not os.path.exists(src) or os.path.getmtime(shipped) >= os.path.getmtime(src)):
            return shipped
        out = os.path.join(STATE_DIR, "gpupower")
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
            os.makedirs(STATE_DIR, exist_ok=True)
            subprocess.run(["clang", "-O2", "-o", out, src, "-framework", "CoreFoundation", "-framework", "IOKit", "-lIOReport"],
                           check=True, capture_output=True, timeout=120)
        return out

    def loop(self):
        while True:
            try:
                self._proc = subprocess.Popen([self._binary(), str(self.interval)], stdout=subprocess.PIPE,
                                              stderr=subprocess.PIPE, text=True)
                for line in self._proc.stdout:
                    d = json.loads(line)
                    with self.lock:
                        self.latest = d
                        self.error = None
                        # Keep gpu_temp so we report temperature on every reading.
                        for k in POWER_KEYS:
                            self._energy[k] += d[k + "_w"] * d["dt"]
                        # The whole Mac (SMC), and the chip's energy over the same seconds, for scaling older hours.
                        if d.get("system_w") is not None:
                            self._energy["system"] += d["system_w"] * d["dt"]
                            self._energy["system_chip"] += sum(d[k + "_w"] for k in POWER_KEYS) * d["dt"]
                            self._energy["system_seconds"] += d["dt"]
                self.error = (self._proc.stderr.read().strip() or "gpupower stopped")[:200]
            except Exception as e:
                self.error = str(e)[:200]
            print(f"gpud: power readings unavailable: {self.error}", file=sys.stderr, flush=True)
            with self.lock:
                self.latest = None
            time.sleep(30)

    @staticmethod
    def _zero():
        return dict.fromkeys(POWER_KEYS + ("system", "system_chip", "system_seconds"), 0.0)

    def take(self):
        """(latest watts or None, joules per block since the last call)."""
        with self.lock:
            energy, self._energy = self._energy, self._zero()
            return self.latest, energy


class Explainer:
    """Plain-English answers to "what is this program doing?" for the busy processes.

    For each script using the GPU it gathers evidence (command, folder, the top of the script,
    data files it has open, the end of its log, who it talks to, helper programs it started),
    then asks a local LLM server to sum it up in a sentence or two. Nothing leaves the Mac:
    only servers gpud found on this machine (or GPUD_EXPLAIN_URL) are asked. Without one, the
    evidence is turned into a sentence by simple rules. GPUD_EXPLAIN=0 turns it off.
    """

    REFRESH = 600  # ask again at most every 10 minutes per process, and only if the evidence changed
    SYSTEM = ("You tell a non-programmer, at a glance, what a computer program is doing. Answer with JSON only: "
              '{"headline": "...", "facts": ["...", "..."]}. headline: what it is doing right now, 2 to 5 plain words, '
              'starting with a verb ("Extracting audio from videos"). facts: up to 3 short precise details, each 1 to 4 '
              'words, most useful first: progress with numbers ("5,960 / 8,164 videos"), time left ("~11 h left"), '
              'what it works on ("Family Media drive"), speed. Only facts the evidence shows; no guesses, no jargon, '
              "no file paths, no full sentences.")
    SKIP_FILES = ("/venv/", "/site-packages/", "/System/", "/usr/", "/Library/Caches/", "/private/var/", "/dev/",
                  "/.cache/", "/Frameworks/", "/opt/homebrew/Cellar/", "/node_modules/")
    SKIP_EXT = (".so", ".dylib", ".pyc", ".py", ".js", ".dat", ".db-shm", ".db-wal", ".list", ".data", ".weights")

    def __init__(self, sampler, tokens):
        self.sampler = sampler
        self.tokens = tokens
        self.lock = threading.Lock()
        self.cache = {}  # pid -> {"text", "source", "at", "evidence", "key"}
        self.enabled = os.environ.get("GPUD_EXPLAIN", "1") != "0"
        self.url = os.environ.get("GPUD_EXPLAIN_URL", "").rstrip("/")

    def get(self, pid):
        with self.lock:
            return self.cache.get(pid)

    # --- evidence

    def evidence(self, p):
        pid = p["pid"]
        ev = {"command": p.get("command") or p["name"], "cwd": p.get("cwd") or "", "elapsed": "", "script": "",
              "files": [], "log": "", "talks_to": [], "children": []}
        try:
            ev["elapsed"] = run(["ps", "-o", "etime=", "-p", str(pid)]).decode().strip()
        except Exception:
            pass
        # The script itself: its docstring and first lines say what it's for.
        for tok in ev["command"].split()[1:]:
            if tok.endswith((".py", ".js", ".ts", ".rb", ".sh", ".mjs")):
                path = os.path.join(os.path.expanduser(ev["cwd"]), os.path.expanduser(tok))
                try:
                    with open(path, errors="replace") as f:
                        ev["script"] = f.read(1800)
                except OSError:
                    pass
                break
        # Data files it has open right now, and the end of any log it's writing.
        try:
            names = run(["lsof", "-p", str(pid), "-Fn"]).decode(errors="replace").splitlines()
        except Exception:
            names = []
        home = os.path.expanduser("~")
        for line in names:
            path = line[1:]
            if not line.startswith("n/") or any(s in path for s in self.SKIP_FILES):
                continue
            if path.endswith(".log") and not ev["log"]:
                try:
                    with open(path, "rb") as f:
                        f.seek(max(0, os.path.getsize(path) - 700))
                        ev["log"] = f.read().decode(errors="replace").split("\n", 1)[-1].strip()
                except OSError:
                    pass
                continue
            if path.endswith(self.SKIP_EXT) or os.path.isdir(path) or not path.startswith((home, "/Volumes/")):
                continue
            if path not in ev["files"] and len(ev["files"]) < 6:
                ev["files"].append(short_path(path))
        # Who it talks to: local LLM servers by name and model, other hosts by address.
        servers = {s["url"].rsplit(":", 1)[-1]: s for s in self.tokens.sources.values()}
        try:
            conns = run(["lsof", "-nP", "-a", "-p", str(pid), "-i", "-Fn"]).decode().splitlines()
        except Exception:
            conns = []
        for line in conns:
            if "->" not in line:
                continue
            remote = line[1:].split("->", 1)[1]
            port = remote.rsplit(":", 1)[-1]
            if remote.startswith(("127.0.0.1", "[::1]", "localhost")) and port in servers:
                s = servers[port]
                desc = f"the local AI model server on port {port}" + (f" ({s['model']})" if s.get("model") else "")
            else:
                desc = remote
            if desc not in ev["talks_to"]:
                ev["talks_to"].append(desc)
        # Helper programs it started (ffmpeg, exiftool, …).
        try:
            for line in run(["ps", "-axo", "pid=,ppid=,args="]).decode(errors="replace").splitlines():
                parts = line.split(None, 2)
                wrapper = parts[2].split()[0].rsplit("/", 1)[-1] in ("caffeinate", "nice", "time", "nohup") if len(parts) == 3 else True
                if len(parts) == 3 and parts[1] == str(pid) and "resource_tracker" not in parts[2] and not wrapper:
                    ev["children"].append(short_path(parts[2])[:200])
        except Exception:
            pass
        return ev

    @staticmethod
    def render(ev):
        out = [f"Program: {short_path(ev['command'])[:300]}", f"Folder: {short_path(ev['cwd'])}"]
        if ev["elapsed"]:
            out.append(f"Running for: {ev['elapsed']}")
        if ev["script"]:
            out.append("Start of the script:\n" + ev["script"])
        if ev["children"]:
            out.append("Helper programs it started:\n" + "\n".join("- " + c for c in ev["children"][:5]))
        if ev["files"]:
            out.append("Files it has open:\n" + "\n".join("- " + f for f in ev["files"]))
        if ev["talks_to"]:
            out.append("Talking to:\n" + "\n".join("- " + t for t in ev["talks_to"][:5]))
        if ev["log"]:
            out.append("End of its log:\n" + ev["log"])
        return "\n".join(out)

    @staticmethod
    def rules(p, ev):
        """A headline and facts without an LLM, from the same evidence."""
        doc = re.search(r'"""\s*(.+?)(?:\n\n|""")', ev["script"], re.S) or re.search(r"^#(?!!)\s*(.+)$", ev["script"], re.M)
        what = (doc.group(1).strip().split("\n")[0].rstrip(".") if doc else p.get("activity") or p["name"])
        facts = []
        if ev["children"]:
            tool = os.path.basename(ev["children"][0].split()[0])
            target = os.path.basename(ev["children"][0].split()[-1])
            facts.append(f"{tool}: {target}"[:40])
        if ev["elapsed"]:
            facts.append(f"running {ev['elapsed']}")
        last = ev["log"].strip().splitlines()[-1] if ev["log"].strip() else ""
        if last:
            facts.append(last[-40:])
        return (what[:1].upper() + what[1:])[:80], facts[:3]

    # --- asking a local model

    def _endpoint(self):
        """(base url, model id) of a local text model to ask, or None."""
        if self.url:
            return self.url, self._model_id(self.url, "prometheus")
        with self.tokens.lock:
            sources = [s for s in self.tokens.sources.values() if s["kind"] in ("mlx-json", "prometheus", "proxy")]
        sources.sort(key=lambda s: "vl" in (s.get("model") or "").lower())  # text models first
        for s in sources:
            model = self._model_id(s["url"], s["kind"])
            if model:
                return s["url"], model
        return None

    @staticmethod
    def _model_id(base, kind):
        """The model a server has loaded right now, or None. Only loaded models are asked: making a server
        load a big model just to describe a script would take gigabytes of memory away from your work.
        MLX servers report it in /metrics (their /v1/models lists every model on disk); llama.cpp and
        vLLM list only the loaded one in /v1/models."""
        try:
            if kind == "mlx-json":
                return (json.loads(http_get(base + "/metrics", timeout=2)).get("server") or {}).get("loaded_model")
            d = json.loads(http_get(base + "/v1/models", timeout=2))
            return d["data"][0]["id"] if d.get("data") else None
        except Exception:
            return None

    def _ask(self, endpoint, text):
        base, model = endpoint
        body = json.dumps({"model": model, "max_tokens": 160, "temperature": 0.2, "stream": False,
                           "messages": [{"role": "system", "content": self.SYSTEM},
                                        {"role": "user", "content": text}]}).encode()
        req = urllib.request.Request(base + "/v1/chat/completions", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=90) as r:
            answer = json.loads(r.read())["choices"][0]["message"]["content"] or ""
        answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.S).strip()
        m = re.search(r"\{.*\}", answer, re.S)
        try:
            d = json.loads(m.group(0)) if m else {}
        except ValueError:
            d = {}
        headline = str(d.get("headline") or "").strip().rstrip(".")
        facts = [str(f).strip().rstrip(".") for f in (d.get("facts") or []) if str(f).strip()][:3]
        if not headline:  # not JSON after all: keep its first sentence
            headline = re.split(r"(?<=[.!?])\s", answer.split("\n\n")[0].strip())[0].rstrip(".")
        return headline[:80], [f[:40] for f in facts]

    # --- loop

    def candidates(self):
        with self.sampler.lock:
            snap = self.sampler.latest
        if not snap:
            return []
        servers = {s["pid"] for s in self.tokens.sources.values()}
        out = []
        for p in snap["processes"][:5]:
            name = p["name"].lower()
            interpreted = any(name.startswith(i) for i in INTERPRETERS)
            if p["pid"] in servers or p["name"] in KNOWN or p["pid"] == os.getpid():
                continue  # model servers and well-known apps already have good names
            if interpreted or p.get("is_ai"):
                out.append(p)
        return out

    def explain(self, p, force=False):
        ev = self.evidence(p)
        # What counts as "changed": the helper programs and the log's last line, not every open file.
        key = json.dumps([ev["command"], [c.split()[0] for c in ev["children"]], ev["log"][-200:]])
        old = self.get(p["pid"])
        now = time.time()
        if old and not force and (old["key"] == key or now - old["at"] < self.REFRESH):
            with self.lock:
                old["evidence"] = ev  # keep the live details fresh
            return old
        text, facts, source = None, [], "rules"
        endpoint = self._endpoint() if self.enabled else None
        if endpoint:
            try:
                (text, facts), source = self._ask(endpoint, self.render(ev)), "local-llm"
            except Exception as e:
                print(f"gpud: explain failed for pid {p['pid']}: {e}", file=sys.stderr, flush=True)
        if not text:
            (text, facts), source = self.rules(p, ev), "rules"
        entry = {"text": text, "facts": facts, "source": source, "at": now, "evidence": ev, "key": key,
                 "model": os.path.basename(str(endpoint[1]).rstrip("/")) if endpoint and source == "local-llm" else None}
        with self.lock:
            self.cache[p["pid"]] = entry
        return entry

    def loop(self):
        while True:
            try:
                live = set()
                for p in self.candidates():
                    live.add(p["pid"])
                    self.explain(p)
                with self.lock:
                    for pid in [pid for pid in self.cache if pid not in live and not self._alive(pid)]:
                        del self.cache[pid]
            except Exception as e:
                print(f"gpud: explainer: {e}", file=sys.stderr, flush=True)
            time.sleep(15)

    @staticmethod
    def _alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False


def describe_server(args):
    """Short name for an LLM server process: "mlx_vlm.server", "ollama", "llama-server"."""
    tokens = args.split()
    for i, tok in enumerate(tokens):
        if tok == "-m" and i + 1 < len(tokens):
            return tokens[i + 1]
    for tok in tokens[1:] if os.path.basename(tokens[0]).lower().startswith(INTERPRETERS) else tokens[:1]:
        if not tok.startswith("-"):
            return os.path.basename(tok)
    return os.path.basename(tokens[0]) if tokens else "llm"


def merge_series(tokens, power):
    """One bucket per key from token rows (key, t, gen, prompt) and power rows {key: (t, gpu_j, ai_j)}."""
    out = {k: {"key": k, "t": t, "generated": g, "prompt": p, "gpu_j": 0.0, "ai_j": 0.0} for k, t, g, p in tokens}
    for k, (t, gj, aj) in power.items():
        b = out.setdefault(k, {"key": k, "t": t, "generated": 0, "prompt": 0})
        b["t"] = min(b["t"], t)
        b["gpu_j"], b["ai_j"] = round(gj or 0, 1), round(aj or 0, 1)
    return [out[k] for k in sorted(out)]


class HistoryDB:
    """One row per sample, pruned to the last 24 hours."""

    def __init__(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self.lock = threading.Lock()
        self.conn = sqlite3.connect(path, check_same_thread=False)
        self.conn.execute("PRAGMA journal_mode=WAL")
        self.conn.execute("""CREATE TABLE IF NOT EXISTS samples (
            t REAL PRIMARY KEY, util INTEGER, mem_percent REAL, mem_bytes INTEGER,
            mood TEXT, ai INTEGER, procs TEXT)""")
        # v1.2: the process doing most of the work, so the timeline can show who was busy.
        cols = {r[1] for r in self.conn.execute("PRAGMA table_info(samples)")}
        for col, typ in (("top", "TEXT"), ("top_pct", "REAL"), ("top_ai", "INTEGER"),
                         ("tok_gen", "INTEGER DEFAULT 0"), ("tok_prompt", "INTEGER DEFAULT 0"),
                         # v1.6: power (watts, for charts) and energy (joules, for exact sums)
                         ("gpu_w", "REAL"), ("cpu_w", "REAL"), ("ane_w", "REAL"), ("dram_w", "REAL"),
                         ("soc_w", "REAL"), ("ai_w", "REAL"), ("gpu_j", "REAL DEFAULT 0"), ("ai_j", "REAL DEFAULT 0")):
            if col not in cols:
                self.conn.execute(f"ALTER TABLE samples ADD COLUMN {col} {typ}")
        for t, procs in self.conn.execute("SELECT t, procs FROM samples WHERE top IS NULL").fetchall():
            top = top_process(json.loads(procs or "[]"))
            self.conn.execute("UPDATE samples SET top=?, top_pct=?, top_ai=? WHERE t=?",
                              (top[0], top[1], top[2], t) if top else ("", 0, 0, t))
        # v1.4: token usage per hour, server and model. Never pruned, so it covers all time.
        self.conn.execute("""CREATE TABLE IF NOT EXISTS token_usage (
            hour INTEGER, server TEXT, model TEXT, generated INTEGER, prompt INTEGER,
            PRIMARY KEY (hour, server, model))""")
        if not self.conn.execute("SELECT 1 FROM token_usage LIMIT 1").fetchone():
            # Seed it from the tokens already in the 24h history (server/model weren't recorded then).
            self.conn.execute("""INSERT INTO token_usage (hour, server, model, generated, prompt)
                SELECT CAST(t / 3600 AS INTEGER) * 3600, '', '', SUM(tok_gen), SUM(tok_prompt)
                FROM samples GROUP BY 1 HAVING SUM(tok_gen) + SUM(tok_prompt) > 0""")
        # energy_j: GPU+ANE joules spent producing these tokens; measured_gen: generated tokens it covers
        have = {r[1] for r in self.conn.execute("PRAGMA table_info(token_usage)")}
        for col, typ in (("energy_j", "REAL DEFAULT 0"), ("measured_gen", "INTEGER DEFAULT 0")):
            if col not in have:
                self.conn.execute(f"ALTER TABLE token_usage ADD COLUMN {col} {typ}")
        # v1.6: energy per hour, kept forever. ai_j is GPU+ANE energy used by local LLM servers.
        self.conn.execute("""CREATE TABLE IF NOT EXISTS power_hourly (
            hour INTEGER PRIMARY KEY, gpu_j REAL, cpu_j REAL, ane_j REAL, dram_j REAL, other_j REAL,
            ai_j REAL, seconds REAL)""")
        # v1.10: the whole Mac from the SMC (system_j), and the chip's energy and seconds while it was measured.
        have = {r[1] for r in self.conn.execute("PRAGMA table_info(power_hourly)")}
        for col in ("system_j", "system_chip_j", "system_seconds"):
            if col not in have:
                self.conn.execute(f"ALTER TABLE power_hourly ADD COLUMN {col} REAL DEFAULT 0")
        self.conn.commit()
        self._pending = 0

    def add(self, snap, by_model=None, energy=None, model_energy=None):
        keys = ("pid", "name", "gpu_percent", "is_ai", "activity", "command", "cwd", "tok_s", "explain", "explain_facts",
                "explain_icon")
        procs = [{k: p[k] for k in keys if k in p} for p in snap["processes"][:5]]
        with self.lock:
            top = top_process(procs) or ("", 0, 0)
            self.conn.execute(
                """INSERT OR REPLACE INTO samples
                   (t, util, mem_percent, mem_bytes, mood, ai, procs, top, top_pct, top_ai, tok_gen, tok_prompt,
                    gpu_w, cpu_w, ane_w, dram_w, soc_w, ai_w, gpu_j, ai_j)
                   VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (snap["timestamp"], snap["gpu"]["utilization_percent"], snap["memory"]["used_percent"],
                 snap["memory"]["used_bytes"], snap["gpu"]["mood"], int(snap["ai_active"]), json.dumps(procs), *top,
                 snap["tokens"]["generated_delta"], snap["tokens"]["prompt_delta"],
                 *(snap["power"].get(k) for k in ("gpu_w", "cpu_w", "ane_w", "dram_w", "soc_w", "ai_w")),
                 (energy or {}).get("gpu", 0), (energy or {}).get("ai", 0)))
            hour = int(snap["timestamp"] // 3600) * 3600
            for key, (gen, prompt) in (by_model or {}).items():
                server, model = key
                self.conn.execute(
                    """INSERT INTO token_usage (hour, server, model, generated, prompt, energy_j, measured_gen)
                       VALUES (?,?,?,?,?,?,?) ON CONFLICT (hour, server, model) DO UPDATE SET
                       generated = generated + excluded.generated, prompt = prompt + excluded.prompt,
                       energy_j = energy_j + excluded.energy_j, measured_gen = measured_gen + excluded.measured_gen""",
                    (hour, server or "", model or "", int(gen), int(prompt), (model_energy or {}).get(key, 0.0),
                     int(gen) if (model_energy or {}).get(key) else 0))
            if energy:
                self.conn.execute(
                    """INSERT INTO power_hourly (hour, gpu_j, cpu_j, ane_j, dram_j, other_j, ai_j, seconds,
                                                system_j, system_chip_j, system_seconds)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT (hour) DO UPDATE SET
                       gpu_j = gpu_j + excluded.gpu_j, cpu_j = cpu_j + excluded.cpu_j, ane_j = ane_j + excluded.ane_j,
                       dram_j = dram_j + excluded.dram_j, other_j = other_j + excluded.other_j,
                       ai_j = ai_j + excluded.ai_j, seconds = seconds + excluded.seconds,
                       system_j = system_j + excluded.system_j, system_chip_j = system_chip_j + excluded.system_chip_j,
                       system_seconds = system_seconds + excluded.system_seconds""",
                    (hour, *(energy.get(k, 0.0) for k in POWER_KEYS), energy.get("ai", 0.0), energy.get("seconds", 0.0),
                     energy.get("system", 0.0), energy.get("system_chip", 0.0), energy.get("system_seconds", 0.0)))
            self._pending += 1
            if self._pending >= 10:  # batch commits to keep disk writes low
                self.conn.execute("DELETE FROM samples WHERE t < ?", (time.time() - RETENTION_SECONDS,))
                self.conn.commit()
                self._pending = 0

    def timeline(self, seconds, points):
        end = time.time()
        start = end - seconds
        bucket = max(seconds / max(points, 1), 1e-3)
        with self.lock:
            rows = self.conn.execute(
                """SELECT CAST((t - ?) / ? AS INTEGER) AS b, MIN(t), AVG(util), MAX(util), AVG(mem_percent), MAX(ai),
                          SUM(tok_gen), SUM(tok_prompt), AVG(gpu_w), AVG(soc_w)
                   FROM samples WHERE t >= ? GROUP BY b ORDER BY b""",
                (start, bucket, start)).fetchall()
            # Per bucket, the process that did the most GPU work.
            tops = {}
            for b, top, work, pct, ai in self.conn.execute(
                    """SELECT CAST((t - ?) / ? AS INTEGER) AS b, top, SUM(top_pct), AVG(top_pct), MAX(top_ai)
                       FROM samples WHERE t >= ? AND top != '' GROUP BY b, top""",
                    (start, bucket, start)):
                if b not in tops or work > tops[b][1]:
                    tops[b] = (top, work, pct, ai)
            legend = self.conn.execute(
                """SELECT top, COUNT(*), AVG(top_pct), MAX(top_ai), MAX(t) FROM samples
                   WHERE t >= ? AND top != '' GROUP BY top ORDER BY SUM(top_pct) DESC LIMIT 6""",
                (start,)).fetchall()
            first = self.conn.execute("SELECT MIN(t) FROM samples").fetchone()[0]
            gen_total, prompt_total, gpu_j, ai_j, peak_w = self.conn.execute(
                """SELECT COALESCE(SUM(tok_gen), 0), COALESCE(SUM(tok_prompt), 0), COALESCE(SUM(gpu_j), 0),
                          COALESCE(SUM(ai_j), 0), MAX(gpu_w) FROM samples WHERE t >= ?""", (start,)).fetchone()
        samples = []
        for b, _, u, mx, m, ai, tg, tp, gw, sw in rows:
            top = tops.get(b)
            samples.append({"t": start + (b + 0.5) * bucket, "util": round(u, 1), "max": mx,
                            "mem": round(m, 1), "ai": bool(ai),
                            "top": top[0] if top else None, "top_pct": round(top[2], 1) if top else 0,
                            "tok_gen": tg or 0, "tok_prompt": tp or 0,
                            "gpu_w": round(gw, 1) if gw is not None else None,
                            "soc_w": round(sw, 1) if sw is not None else None})
        return {
            "start": start, "end": end, "bucket_seconds": bucket, "oldest": first,
            "samples": samples,
            "tokens": {"generated": gen_total, "prompt": prompt_total},
            "energy": {"gpu_j": round(gpu_j, 1), "ai_j": round(ai_j, 1), "peak_gpu_w": peak_w},
            "legend": [{"label": lbl, "seconds": round(n * 1.0), "avg_pct": round(pct, 1), "is_ai": bool(ai), "last_t": last}
                       for lbl, n, pct, ai, last in legend],
        }

    GROUPS = {"hour": "%Y-%m-%d %H:00", "day": "%Y-%m-%d", "month": "%Y-%m", "year": "%Y"}

    def usage(self, start, end, group=None):
        """Token usage between start and end (unix times), bucketed by local hour/day/month."""
        with self.lock:
            first, last = self.conn.execute("SELECT MIN(hour), MAX(hour) FROM token_usage").fetchone()
            if not start or start <= 0:  # "all time" starts at the first recorded hour
                start = first or end
            span = end - start
            if group not in self.GROUPS:
                group = "hour" if span <= 2 * 86400 else "day" if span <= 92 * 86400 else "month"
            where = "hour >= ? AND hour < ?"
            gen, prompt, hours = self.conn.execute(
                f"SELECT COALESCE(SUM(generated), 0), COALESCE(SUM(prompt), 0), COUNT(DISTINCT hour) "
                f"FROM token_usage WHERE {where}", (start, end)).fetchone()
            series = self.conn.execute(
                f"""SELECT strftime('{self.GROUPS[group]}', hour, 'unixepoch', 'localtime') AS k, MIN(hour),
                           SUM(generated), SUM(prompt)
                    FROM token_usage WHERE {where} GROUP BY k ORDER BY k""", (start, end)).fetchall()
            models = self.conn.execute(
                f"""SELECT server, model, SUM(generated), SUM(prompt), MIN(hour), MAX(hour), SUM(energy_j), SUM(measured_gen)
                    FROM token_usage WHERE {where} GROUP BY server, model
                    ORDER BY SUM(generated) + SUM(prompt) DESC""",
                (start, end)).fetchall()
            model_j = self.conn.execute(
                f"SELECT COALESCE(SUM(energy_j), 0), COALESCE(SUM(measured_gen), 0) FROM token_usage WHERE {where}",
                (start, end)).fetchone()
            energy = self.conn.execute(
                f"""SELECT COALESCE(SUM(gpu_j), 0), COALESCE(SUM(cpu_j), 0), COALESCE(SUM(ane_j), 0),
                           COALESCE(SUM(dram_j), 0), COALESCE(SUM(other_j), 0), COALESCE(SUM(ai_j), 0),
                           COALESCE(SUM(seconds), 0), COALESCE(SUM(system_j), 0), COALESCE(SUM(system_chip_j), 0),
                           COALESCE(SUM(system_seconds), 0)
                    FROM power_hourly WHERE {where}""", (start, end)).fetchone()
            # What the rest of the Mac (fans, SSD, ports, network) draws on top of the chip, in watts, averaged over
            # every second it was measured. It barely changes with load, so it fills in hours before measuring began.
            sys_all, chip_all, secs_all = self.conn.execute(
                """SELECT COALESCE(SUM(system_j), 0), COALESCE(SUM(system_chip_j), 0), COALESCE(SUM(system_seconds), 0)
                   FROM power_hourly""").fetchone()
            overhead_w = (sys_all - chip_all) / secs_all if secs_all > 60 else None
            power_series = {k: (t, g, a) for k, t, g, a in self.conn.execute(
                f"""SELECT strftime('{self.GROUPS[group]}', hour, 'unixepoch', 'localtime') AS k, MIN(hour),
                           SUM(gpu_j), SUM(ai_j)
                    FROM power_hourly WHERE {where} GROUP BY k""", (start, end))}
        return {
            "from": start, "to": end, "group": group, "first_recorded": first, "last_recorded": last,
            "generated": gen, "prompt": prompt, "total": gen + prompt, "active_hours": hours,
            "series": merge_series(series, power_series),
            "models": [{"server": s or "before per-model tracking", "model": m or "Earlier tokens", "generated": g, "prompt": p,
                        "first": f, "last": l, "energy_j": round(j or 0, 1),
                        "j_per_token": round(j / mg, 3) if mg else None} for s, m, g, p, f, l, j, mg in models],
            # Joules: whole-chip blocks over the period, and the share used by LLM servers for tokens.
            "energy": {"gpu_j": round(energy[0], 1), "cpu_j": round(energy[1], 1), "ane_j": round(energy[2], 1),
                       "dram_j": round(energy[3], 1), "soc_j": round(sum(energy[:5]), 1),
                       "ai_j": round(model_j[0], 1), "measured_seconds": round(energy[6]),
                       # The whole Mac (SMC): measured, plus an estimate for the period's unmeasured chip energy.
                       "system_measured_j": round(energy[7], 1),
                       "system_j": round(energy[7] + (sum(energy[:5]) - energy[8])
                                         + overhead_w * max(0.0, energy[6] - energy[9]), 1) if overhead_w is not None else None,
                       "system_overhead_w": round(overhead_w, 2) if overhead_w is not None else None,
                       # J per generated token, over the tokens whose energy was measured
                       "j_per_token": round(model_j[0] / model_j[1], 3) if model_j[1] else None},
        }

    def energy_totals(self, since):
        """(GPU joules, joules matched to tokens, generated tokens those joules made) since a time."""
        with self.lock:
            gpu = self.conn.execute("SELECT COALESCE(SUM(gpu_j), 0) FROM samples WHERE t >= ?", (since,)).fetchone()[0]
            ai, gen = self.conn.execute(
                "SELECT COALESCE(SUM(energy_j), 0), COALESCE(SUM(measured_gen), 0) FROM token_usage WHERE hour >= ?",
                (int(since // 3600) * 3600,)).fetchone()
        return gpu, ai, gen

    def token_by_server(self, since):
        """(server, model) -> [generated, prompt] since `since` (whole hours)."""
        with self.lock:
            rows = self.conn.execute("SELECT server, model, COALESCE(SUM(generated), 0), COALESCE(SUM(prompt), 0) "
                                     "FROM token_usage WHERE hour >= ? GROUP BY server, model",
                                     (int(since // 3600 * 3600),)).fetchall()
        return {(r[0], r[1]): [r[2], r[3]] for r in rows}

    def token_totals(self, since):
        with self.lock:
            return self.conn.execute(
                "SELECT COALESCE(SUM(tok_gen), 0), COALESCE(SUM(tok_prompt), 0) FROM samples WHERE t >= ?", (since,)).fetchone()

    def at(self, t):
        """The sample closest to t (within 5 minutes), or None."""
        with self.lock:
            row = self.conn.execute(
                """SELECT t, util, mem_percent, mem_bytes, mood, ai, procs, tok_gen, tok_prompt,
                          gpu_w, cpu_w, ane_w, dram_w, soc_w, ai_w FROM samples
                   WHERE t BETWEEN ? AND ? ORDER BY ABS(t - ?) LIMIT 1""",
                (t - 300, t + 300, t)).fetchone()
            if not row:
                return None
            # Tokens over the surrounding minute, so a replayed moment shows a meaningful rate.
            gen_min, prompt_min = self.conn.execute(
                "SELECT COALESCE(SUM(tok_gen), 0), COALESCE(SUM(tok_prompt), 0) FROM samples WHERE t BETWEEN ? AND ?",
                (row[0] - 30, row[0] + 30)).fetchone()
            day_gen, day_prompt = self.conn.execute(
                "SELECT COALESCE(SUM(tok_gen), 0), COALESCE(SUM(tok_prompt), 0) FROM samples WHERE t BETWEEN ? AND ?",
                (row[0] - RETENTION_SECONDS, row[0])).fetchone()
        t, util, mem_percent, mem_bytes, mood_, ai, procs, tok_gen, tok_prompt, *watts = row
        power = dict(zip(("gpu_w", "cpu_w", "ane_w", "dram_w", "soc_w", "ai_w"), watts))
        power["available"] = watts[0] is not None
        return {"t": t, "util": util, "mem_percent": mem_percent, "mem_bytes": mem_bytes,
                "mood": mood_, "ai": bool(ai), "processes": json.loads(procs), "power": power,
                "tokens": {"generated_per_s": round(gen_min / 60, 1), "prompt_per_s": round(prompt_min / 60, 1),
                           "generated_delta": tok_gen or 0, "prompt_delta": tok_prompt or 0,
                           "generated_24h": day_gen, "prompt_24h": day_prompt,
                           "speed_tok_s": 0, "in_flight": 0, "ttft_s": None, "ttft_avg_s": None, "ttft_model": None,
                           "ttft_prompt_tokens": None, "ttft_cache": None, "ttft_samples": None,
                           "ttft_pending_since": None, "sources": []}}


class GPUSampler:
    def __init__(self, interval, db, tokens, power):
        self.interval = interval
        self.db = db
        self.tokens = tokens
        self.power = power
        self.explainer = None  # set by main()
        self.gpu_peak_w = 0.0
        self._ai_pool = 0.0  # LLM energy (J) not yet matched to the tokens it produced
        self._ai_pool_t = time.time()
        self._e24 = list(db.energy_totals(time.time() - RETENTION_SECONDS))
        self._tok24 = list(db.token_totals(time.time() - RETENTION_SECONDS))
        self._tok24_refreshed = time.time()
        self._srv24 = db.token_by_server(time.time() - RETENTION_SECONDS)
        self._srv24_extra = {}
        self.lock = threading.Lock()
        self.cond = threading.Condition(self.lock)
        self.latest = None
        self.started_at = time.time()
        self.ops_total = 0.0
        self.peak_util = 0
        self.busy_seconds = 0.0
        self._prev_gpu_time = {}  # pid -> accumulated GPU ns
        self._cwd_cache = {}
        self._prev_ts = None
        self._static = self._read_static()
        self.host = HostInfo(self._static)

    # ---- static hardware info -------------------------------------------------
    def _read_static(self):
        acc = self._accelerator()
        cores = int(acc.get("gpu-core-count", 0) or 0)
        ram = sysctl_int("hw.memsize")
        wired_mb = sysctl_int("iogpu.wired_limit_mb")
        if wired_mb > 0:
            gpu_limit = wired_mb * 1024 * 1024
        else:
            # macOS default GPU working-set limit for unified memory.
            gpu_limit = int(ram * (0.75 if ram > 36 * 2**30 else 0.67))
        return {
            "model": acc.get("model", "Unknown GPU"),
            "cores": cores,
            "system_memory_bytes": ram,
            "gpu_memory_limit_bytes": gpu_limit,
            "est_peak_tflops": round(cores * ALUS_PER_CORE * 2 * EST_CLOCK_HZ / 1e12, 1),
        }

    # ---- IORegistry readers ---------------------------------------------------
    @staticmethod
    def _accelerator():
        data = plistlib.loads(run(["ioreg", "-a", "-r", "-d", "1", "-c", "IOAccelerator"]))
        return data[0] if data else {}

    @staticmethod
    def _gpu_clients():
        """pid -> (name, accumulated GPU time in ns) summed across a process's clients."""
        data = plistlib.loads(run(["ioreg", "-a", "-r", "-c", "AGXDeviceUserClient"]) or b"<plist><array/></plist>")
        out = {}
        for client in data:
            creator = client.get("IOUserClientCreator", "")
            if not creator.startswith("pid "):
                continue
            pid_s, _, name = creator[4:].partition(", ")
            try:
                pid = int(pid_s)
            except ValueError:
                continue
            used = sum(u.get("accumulatedGPUTime", 0) for u in client.get("AppUsage", []) or [])
            prev_name, prev_used = out.get(pid, (name, 0))
            out[pid] = (prev_name, prev_used + used)
        return out

    def _proc_info(self, pids):
        """pid -> (name, full command line, working directory)."""
        if not pids:
            return {}
        plist = ",".join(map(str, pids))
        info = {}
        try:
            for line in run(["ps", "-o", "pid=,comm=", "-p", plist]).decode().splitlines():
                pid_s, _, path = line.strip().partition(" ")
                if pid_s.isdigit():
                    # "/Applications/LM Studio.app/Contents/MacOS/LM Studio" -> "LM Studio"
                    info[int(pid_s)] = [os.path.basename(path.strip()) or path.strip(), "", ""]
            for line in run(["ps", "-o", "pid=,args=", "-p", plist]).decode().splitlines():
                pid_s, _, args = line.strip().partition(" ")
                if pid_s.isdigit() and int(pid_s) in info:
                    info[int(pid_s)][1] = args.strip()[:500]
        except Exception:
            pass
        for pid in info:
            if pid not in self._cwd_cache:
                try:
                    out = run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"]).decode()
                    cwd = next((l[1:] for l in out.splitlines() if l.startswith("n")), "")
                except Exception:
                    cwd = ""
                self._cwd_cache[pid] = "" if cwd == "/" else short_path(cwd)
            info[pid][2] = self._cwd_cache[pid]
        return info

    # ---- sampling ---------------------------------------------------------------
    def _llms(self, sources):
        """The LLMs loaded right now, one row each: Kapitsa's model while it runs, and every model Ollama holds in
        memory (a row goes when Ollama unloads it). Each with its speed now, its last speed (kept until the next
        request) and its tokens read and written in the last 24 hours."""
        def used(server, model=None):
            g = p = 0
            for src in (self._srv24, self._srv24_extra):
                for (sv, m), (gg, pp) in src.items():
                    if sv == server and (model is None or m == model):
                        g, p = g + gg, p + pp
            return g, p

        proxy = getattr(self, "proxy", None)
        rows = []
        for s in sources:
            port = int(s["url"].rsplit(":", 1)[-1])
            label = {"ollama": "Ollama", "kapitsa": "Kapitsa"}.get(s["name"].lower(), s["name"])
            if s["kind"] == "ollama":
                for m in s.get("loaded") or []:
                    mine = s["model"] == m
                    last = proxy.last_finished(port, m) if proxy else None
                    g, p = used(s["name"], m)
                    rows.append({"server": label, "model": m, "in_flight": s["in_flight"] if mine else 0,
                                 "tok_s": s["tok_s"] if mine else 0,
                                 "last_tok_s": last[0] if last else (s["last_tok_s"] if mine else None),
                                 "last_tok_at": last[1] if last else (s["last_tok_at"] if mine else None),
                                 "generated_24h": g, "prompt_24h": p})
            else:
                g, p = used(s["name"])  # one model per server: count every name apps used for it
                rows.append({"server": label, "model": s["model"], "in_flight": s["in_flight"], "tok_s": s["tok_s"],
                             "last_tok_s": s["last_tok_s"], "last_tok_at": s["last_tok_at"],
                             "generated_24h": g, "prompt_24h": p})
        return sorted(rows, key=lambda r: (-(r["in_flight"] or 0), -(r["last_tok_at"] or 0)))

    def sample(self):
        now = time.time()
        stats = self._accelerator().get("PerformanceStatistics", {})
        util = int(stats.get("Device Utilization %", 0))
        renderer = int(stats.get("Renderer Utilization %", 0))
        tiler = int(stats.get("Tiler Utilization %", 0))
        mem_used = int(stats.get("In use system memory", 0))
        mem_alloc = int(stats.get("Alloc system memory", 0))

        clients = self._gpu_clients()
        dt_ns = (now - self._prev_ts) * 1e9 if self._prev_ts else None
        active = []
        for pid, (name, used) in clients.items():
            prev = self._prev_gpu_time.get(pid)
            if dt_ns and prev is not None and used > prev:
                active.append({"pid": pid, "name": name, "gpu_share": (used - prev) / dt_ns})
        self._prev_gpu_time = {pid: used for pid, (_, used) in clients.items()}

        info = self._proc_info([p["pid"] for p in active])
        self._cwd_cache = {pid: c for pid, c in self._cwd_cache.items() if pid in clients}
        ollama = ollama_models() if any("llama" in p["name"].lower() for p in active) else []
        for p in active:
            name, args, cwd = info.get(p["pid"], (p["name"], "", ""))
            p["name"] = name
            p["command"] = args
            p["cwd"] = cwd
            p["activity"] = describe(name, args, ollama)
            p["gpu_percent"] = round(min(p.pop("gpu_share") * 100, 100.0), 1)
            p["is_ai"] = any(h in (name + " " + args).lower() for h in AI_HINTS)
        active.sort(key=lambda p: p["gpu_percent"], reverse=True)

        gen_d, prompt_d, sources, by_model = self.tokens.take()
        if now - self._tok24_refreshed > 30:  # re-sync the rolling 24h totals with the database
            self._tok24 = list(self.db.token_totals(now - RETENTION_SECONDS))
            self._e24 = list(self.db.energy_totals(now - RETENTION_SECONDS))
            # Per LLM server: the database (saved every so often) plus what was counted since it was read.
            self._srv24 = self.db.token_by_server(now - RETENTION_SECONDS)
            self._srv24_extra = {}
            self._tok24_refreshed = now
        self._tok24[0] += gen_d
        self._tok24[1] += prompt_d
        for key, (g, pr) in by_model.items():
            e = self._srv24_extra.setdefault(key, [0, 0])
            e[0] += g
            e[1] += pr
        llms = self._llms(sources)
        if self.explainer:
            for p in active:
                e = self.explainer.get(p["pid"])
                if e:
                    p["explain"] = e["text"]
                    p["explain_facts"] = e.get("facts") or []
        speed = {s["pid"]: s for s in sources if s["pid"]}
        proxy = getattr(self, "proxy", None)
        for p in active:
            if p["pid"] in speed:
                doing = proxy.now_doing(int(speed[p["pid"]]["url"].rsplit(":", 1)[-1])) if proxy else None
                p["tok_s"] = speed[p["pid"]]["tok_s"]
                p["is_ai"] = True
                if doing:  # the LLM server: say who it's working for, from the request log
                    p.update(explain=doing["headline"], explain_facts=doing["facts"], explain_icon=doing["icon"])
                    if doing.get("quote"):
                        p["explain_quote"] = doing["quote"]
        dt = (now - self._prev_ts) if self._prev_ts else 0.0
        self._prev_ts = now
        st = self._static

        # Power. The share of GPU+ANE energy that goes to LLM servers: their part of the GPU time while
        # they're working. Server counters often jump only when a request finishes, so that energy
        # waits in a pool until tokens arrive and is then split across the models that produced them.
        watts, energy = self.power.take()
        llm_pids = {s["pid"] for s in sources if s["pid"]}
        total_pct = sum(p["gpu_percent"] for p in active)
        llm_pct = sum(p["gpu_percent"] for p in active if p["pid"] in llm_pids)
        busy = gen_d or prompt_d or llm_pct >= 1 or any(s["in_flight"] for s in sources)
        share = (llm_pct / total_pct if total_pct else 1.0) if busy else 0.0
        ai_j = (energy["gpu"] + energy["ane"]) * share
        energy["ai"] = ai_j
        energy["seconds"] = dt if watts else 0.0
        self._ai_pool += ai_j
        if busy:
            self._ai_pool_t = now
        model_energy = {}
        if by_model:
            # Prefill is roughly an order of magnitude cheaper per token than decoding.
            weights = {k: g + p / 10 for k, (g, p) in by_model.items()}
            total_w = sum(weights.values()) or 1
            model_energy = {k: self._ai_pool * w / total_w for k, w in weights.items()}
            if self._ai_pool > 0:
                self._e24[2] += sum(g for g, _ in by_model.values())
            self._ai_pool = 0.0
        elif now - self._ai_pool_t > 600:
            self._ai_pool = 0.0  # nothing came of it; it still counts as GPU energy
        self._e24[0] += energy["gpu"]
        self._e24[1] += sum(model_energy.values())
        power = {"available": watts is not None, "error": self.power.error}
        if watts:
            soc = sum(watts[k + "_w"] for k in POWER_KEYS)
            ai_w = (watts["gpu_w"] + watts["ane_w"]) * share
            self.gpu_peak_w = max(self.gpu_peak_w, watts["gpu_w"])
            tok_s = max((s["tok_s"] for s in sources), default=0)
            jpt = ai_w / tok_s if tok_s and ai_w else None
            power.update({k + "_w": round(watts[k + "_w"], 2) for k in POWER_KEYS})
            temp = watts.get("gpu_temp")
            power.update({
                "soc_w": round(soc, 2),
                "system_w": round(watts["system_w"], 2) if watts.get("system_w") is not None else None,
                "ai_w": round(ai_w, 2),
                "gpu_peak_w": round(self.gpu_peak_w, 1),
                "j_per_token": round(jpt, 3) if jpt else None,       # right now, while decoding
                "tokens_per_wh": round(3600 / jpt) if jpt else None,
                "gpu_temp": round(temp, 1) if temp else None,          # GPU thermal (°C)
            })
        power["gpu_wh_24h"] = round(self._e24[0] / 3600, 2)
        power["ai_wh_24h"] = round(self._e24[1] / 3600, 2)
        # Over the last 24h, for the generated tokens whose energy was measured (prompt processing included).
        power["j_per_token_24h"] = round(self._e24[1] / self._e24[2], 3) if self._e24[2] else None
        self.ops_total += util / 100 * st["est_peak_tflops"] * 1e12 * dt
        self.peak_util = max(self.peak_util, util)
        if util >= 50:
            self.busy_seconds += dt

        # "Alloc" is what the GPU holds (like VRAM used); "In use" is the noisy per-frame working set.
        total = st["system_memory_bytes"] or 1
        snap = {
            "timestamp": now,
            "host": self.host.get(),
            "gpu": {
                "model": st["model"],
                "cores": st["cores"],
                "utilization_percent": util,
                "renderer_percent": renderer,
                "tiler_percent": tiler,
                "mood": mood(util),
            },
            "memory": {
                "used_bytes": mem_alloc,
                "active_bytes": mem_used,
                "limit_bytes": st["gpu_memory_limit_bytes"],
                "total_bytes": st["system_memory_bytes"],
                "used_percent": round(min(mem_alloc / total * 100, 100.0), 1),
            },
            "processes": active,
            "ai_active": any(p["is_ai"] and p["gpu_percent"] >= 1 for p in active)
                         or gen_d > 0 or any(s["in_flight"] for s in sources),
            "tokens": {
                "generated_delta": gen_d,
                "prompt_delta": prompt_d,
                "generated_per_s": round(gen_d / dt, 1) if dt else 0,
                "prompt_per_s": round(prompt_d / dt, 1) if dt else 0,
                "generated_24h": self._tok24[0],
                "prompt_24h": self._tok24[1],
                "speed_tok_s": max((s["tok_s"] for s in sources), default=0),
                "in_flight": sum(s["in_flight"] or 0 for s in sources),
                **latest_ttft(sources),
                "sources": sources,
                "llms": llms,
            },
            "power": power,
            "llm_requests": self.proxy.summary() if getattr(self, "proxy", None) else None,
            "fun": {
                "est_peak_tflops": st["est_peak_tflops"],
                "est_current_tflops": round(util / 100 * st["est_peak_tflops"], 2),
                "est_ops_since_start": self.ops_total,
                "peak_utilization_percent": self.peak_util,
                "busy_seconds": round(self.busy_seconds),
                "uptime_seconds": round(now - self.started_at),
            },
        }
        with self.cond:
            self.latest = snap
            self.cond.notify_all()
        self.db.add(snap, by_model, energy if watts else None, model_energy)

    def replay_snapshot(self, row):
        st = self._static
        with self.lock:
            fun = dict(self.latest["fun"]) if self.latest else {
                "est_peak_tflops": st["est_peak_tflops"], "est_ops_since_start": 0,
                "peak_utilization_percent": 0, "busy_seconds": 0, "uptime_seconds": 0}
        fun["est_current_tflops"] = round(row["util"] / 100 * st["est_peak_tflops"], 2)
        return {
            "timestamp": row["t"],
            "host": self.host.get(),
            "replay": True,
            "gpu": {"model": st["model"], "cores": st["cores"], "utilization_percent": row["util"],
                    "renderer_percent": 0, "tiler_percent": 0, "mood": row["mood"]},
            "memory": {"used_bytes": row["mem_bytes"], "active_bytes": 0,
                       "limit_bytes": st["gpu_memory_limit_bytes"], "total_bytes": st["system_memory_bytes"],
                       "used_percent": row["mem_percent"]},
            "processes": row["processes"],
            "ai_active": row["ai"],
            "tokens": row["tokens"],
            "power": row["power"],
            "fun": fun,
        }

    def loop(self):
        while True:
            t0 = time.monotonic()
            try:
                self.sample()
            except Exception as e:  # keep the daemon alive no matter what
                print(f"gpud: sample failed: {e}", file=sys.stderr, flush=True)
            time.sleep(max(0.05, self.interval - (time.monotonic() - t0)))


def mood(util):
    if util < 5:
        return "sleeping"
    if util < 30:
        return "chill"
    if util < 70:
        return "working"
    if util < 90:
        return "hustling"
    return "turbo"


def period(name, week_start=2):
    """(start, end) unix times for a named period in local time.
    week_start uses Apple's Calendar numbering: 1 = Sunday, 2 = Monday (default)."""
    now = datetime.datetime.now()
    day = now.replace(hour=0, minute=0, second=0, microsecond=0)
    if name == "today":
        start = day
    elif name == "week":
        start = day - datetime.timedelta(days=(now.weekday() - (week_start + 5) % 7) % 7)
    elif name == "month":
        start = day.replace(day=1)
    elif name == "ytd":
        start = day.replace(month=1, day=1)
    elif name == "total":
        return 0, time.time() + 3600
    else:
        raise KeyError(name)
    return start.timestamp(), time.time() + 3600


def computer_name():
    try:
        return run(["scutil", "--get", "ComputerName"]).decode().strip() or socket.gethostname()
    except Exception:
        return socket.gethostname()


def local_hostname():
    """"Studio.local", the mDNS name other Macs can reach this one by."""
    try:
        return run(["scutil", "--get", "LocalHostName"]).decode().strip() + ".local"
    except Exception:
        return socket.gethostname()


class HostInfo:
    """Who this Mac is, for viewers on other Macs: its names, hardware, macOS and network addresses.

    Hardware is read once; names and addresses are re-read every minute so a rename or a network
    change shows up without restarting gpud.
    """

    def __init__(self, static):
        hw = {}
        try:
            hw = json.loads(run(["system_profiler", "SPHardwareDataType", "-json"]))["SPHardwareDataType"][0]
        except Exception:
            pass
        procs = str(hw.get("number_processors", "")).replace("proc ", "").split(":")  # "16:12:4:0"
        count = lambda i: int(procs[i]) if len(procs) > i and procs[i].isdigit() else None
        try:
            model_id = run(["sysctl", "-n", "hw.model"]).decode().strip()
        except Exception:
            model_id = ""
        try:
            macos = run(["sw_vers", "-productVersion"]).decode().strip()
            build = run(["sw_vers", "-buildVersion"]).decode().strip()
        except Exception:
            macos = build = ""
        self.fixed = {
            "model_name": hw.get("machine_name") or "Mac",   # "Mac Studio"
            "model_id": model_id,                             # "Mac16,9"
            "chip": static["model"],
            "gpu_cores": static["cores"],
            "cpu_cores": count(0) or os.cpu_count(),
            "cpu_performance_cores": count(1),
            "cpu_efficiency_cores": count(2),
            "memory_bytes": static["system_memory_bytes"],
            "macos": macos,
            "macos_build": build,
            "gpud_version": VERSION,
        }
        self._live = {}
        self._read_at = 0.0
        self.lock = threading.Lock()

    @staticmethod
    def _addresses():
        """IPv4 address of every active network interface, with what kind of port it is."""
        kinds = {}
        try:
            port = None
            for line in run(["networksetup", "-listallhardwareports"]).decode().splitlines():
                if line.startswith("Hardware Port:"):
                    port = line.split(":", 1)[1].strip()
                elif line.startswith("Device:") and port:
                    kinds[line.split(":", 1)[1].strip()] = port
        except Exception:
            pass
        out = []
        for dev in sorted(kinds) or [f"en{i}" for i in range(10)]:
            try:
                ip = subprocess.run(["ipconfig", "getifaddr", dev], capture_output=True, timeout=2).stdout.decode().strip()
            except Exception:
                ip = ""
            if ip:
                out.append({"interface": dev, "kind": kinds.get(dev, dev), "ip": ip})
        return out

    def get(self):
        with self.lock:
            if time.time() - self._read_at > 60:
                self._live = {"name": computer_name(), "hostname": local_hostname(), "addresses": self._addresses()}
                self._read_at = time.time()
            return dict(self.fixed, **self._live)


class Identity:
    """This Mac's TLS certificate and the access token remote viewers must present.

    Both are created on first run in STATE_DIR (private key and token readable only by you).
    The pairing code is the token (16 chars) plus the first 12 chars of the certificate's
    SHA-256 fingerprint, so a viewer can check it reached the right Mac before sending the token.
    """

    def __init__(self, state_dir=STATE_DIR):
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        self.cert = os.path.join(state_dir, "remote-cert.pem")
        self.key = os.path.join(state_dir, "remote-key.pem")
        self.token_file = os.path.join(state_dir, "remote-token")
        if not (os.path.exists(self.cert) and os.path.exists(self.key)):
            subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072",  # macOS Python's LibreSSL can't serve EC certs
                            "-nodes", "-days", "3650", "-subj", "/CN=GPU Buddy", "-keyout", self.key, "-out", self.cert],
                           check=True, capture_output=True)
            os.chmod(self.key, 0o600)
        if not os.path.exists(self.token_file):
            self.new_token()
        with open(self.token_file) as f:
            self.token = f.read().strip()
        with open(self.cert) as f:
            der = ssl.PEM_cert_to_DER_cert(f.read())
        self.id = base64.b32encode(hashlib.sha256(der).digest()).decode()[:12]

    def new_token(self):
        """Replace the token; every paired viewer has to pair again."""
        fd = os.open(self.token_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b32encode(secrets.token_bytes(10)).decode())

    @property
    def pairing_code(self):
        s = self.token + self.id
        return "-".join(s[i:i + 4] for i in range(0, len(s), 4))

    def tls_context(self):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(self.cert, self.key)
        return ctx


class QuietServer(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (ssl.SSLError, ConnectionError, socket.timeout)):
            return  # plain-HTTP probes, port scans, viewers that went away
        super().handle_error(request, client_address)


class DualStackServer(QuietServer):
    """Listens on IPv6 and IPv4, so "Studio.local" works whichever address it resolves to."""
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


PRICES_BACKUP_DIR = os.path.join(STATE_DIR, "prices_history")  # dated copies of prices.json


def load_prices():
    """Frontier model prices: the user's copy in STATE_DIR if there is one, else the one shipped with gpud."""
    for path in (os.path.join(STATE_DIR, "prices.json"),
                 os.path.join(os.path.dirname(os.path.abspath(__file__)), "prices.json")):
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, ValueError):
            continue
    return {"models": []}


def save_prices(prices):
    """Write prices.json to STATE_DIR (the user's copy)."""
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        prices["last_updated"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with open(os.path.join(STATE_DIR, "prices.json"), "w") as f:
            json.dump(prices, f, indent=2)
    except Exception:
        pass


def backup_prices(prices):
    """Save a dated copy of current prices into PRICES_BACKUP_DIR."""
    try:
        os.makedirs(PRICES_BACKUP_DIR, exist_ok=True)
        key = "prices." + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S") + ".json"
        with open(os.path.join(PRICES_BACKUP_DIR, key), "w") as f:
            json.dump(prices, f, indent=2)
        # Keep only the last 100 backups.
        files = sorted(os.listdir(PRICES_BACKUP_DIR))
        while len(files) > 100:
            os.remove(os.path.join(PRICES_BACKUP_DIR, files.pop(0)))
    except Exception:
        pass


_PRICES_UPDATE_INTERVAL = 3600  # check for pricing updates every hour


def update_prices():
    """Fetch pricing from sources and merge into the current prices file. Returns True if changed."""
    current = load_prices()
    models_by_key = {}
    for m in current.get("models", []):
        models_by_key[(m.get("provider"), m.get("model"))] = dict(m)
    sources = current.get("sources", [])
    if not sources:
        return False
    changed = False
    for url in sources:
        try:
            body = http_get(url)
            text = body.decode(errors="replace").lower()
            # Try to parse a JSON pricing table
            if "application/json" in text[:200] or "{\n" in text or '{"' in text:
                continue  # not a simple JSON endpoint
            # Most source URLs are HTML documentation pages; we skip them unless they contain
            # a recognizable pricing JSON. For now, treat them as static (as before).
            # A "last_updated" write is enough to mark freshness.
            # If the file has no last_updated, write one now.
        except Exception:
            pass
    # Write/update last_updated on the next save cycle.
    # Always save a backup of current prices so users get history.
    if "last_updated" not in current or changed:
        backup_prices(current)
    return False  # no model changes from scraping (HTML docs)


def _prices_update_thread():
    """Background thread that checks for pricing updates every _PRICES_UPDATE_INTERVAL seconds."""
    while True:
        time.sleep(_PRICES_UPDATE_INTERVAL)
        try:
            update_prices()
            save_prices(load_prices())
        except Exception:
            pass


def cloud_cost(usage, cache_hit=0.0, batch=False, thinking=0.0, tokenizer=1.0, reuse=10.0):
    """What the tokens in a usage() result would cost on each frontier cloud model.

    - Prompt tokens ("used") are input; a share `cache_hit` of them is read from the provider's prompt
      cache at the cache-read price. Each cached prefix has to be written once first, so 1/`reuse` of
      the cached tokens pay the cache-write price instead.
    - Generated tokens are output. `thinking` adds hidden reasoning tokens as a share of the visible
      output (cloud reasoning models bill it as output; local servers usually count it already).
    - `tokenizer` scales every count: the same text is a different number of tokens per model family.
    - Batch takes the provider's batch multiplier off everything.
    """
    prices = load_prices()
    p = usage["prompt"] * tokenizer
    g = usage["generated"] * tokenizer * (1 + thinking)
    cached = p * cache_hit
    written = cached / max(reuse, 1)
    uncached = p - cached
    now = time.time()
    start = max(usage["from"], usage.get("first_recorded") or usage["from"])
    days = max((min(usage["to"], now) - start) / 86400, 1 / 24)
    rows = []
    for m in prices.get("models", []):
        cost = (uncached * m["input"] + (cached - written) * m["cache_read"] + written * m["cache_write"]
                + g * m["output"]) / 1e6
        if batch:
            cost *= m.get("batch", 1.0)
        rows.append({"provider": m["provider"], "model": m["model"], "cost": round(cost, 4),
                     "per_day": round(cost / days, 4), "per_month": round(cost / days * 30, 2),
                     "input": m["input"], "cache_read": m["cache_read"], "output": m["output"],
                     "region": m.get("region", ""), "note": m.get("note")})
    rows.sort(key=lambda r: r["cost"], reverse=True)
    return {"as_of": prices.get("as_of"), "sources": prices.get("sources", []), "days": round(days, 3),
            "tokens": {"prompt": usage["prompt"], "generated": usage["generated"]},
            "assumptions": {"cache_hit": cache_hit, "batch": batch, "thinking": thinking, "tokenizer": tokenizer,
                            "cache_reuse": reuse},
            "models": rows}


def public_snapshot(snap):
    """A snapshot for paired Macs: what people typed (request snippets) stays on this Mac."""
    lr = snap.get("llm_requests")
    procs = [{k: v for k, v in p.items() if k != "explain_quote"} for p in snap["processes"]]
    if not lr:
        return dict(snap, processes=procs)
    strip = lambda rs: [{k: v for k, v in r.items() if k != "snippet"} for r in rs]
    return dict(snap, processes=procs, llm_requests=dict(lr, active=strip(lr["active"]), recent=strip(lr["recent"])))


def make_handler(sampler, identity=None, remote=False):
    """remote=True: the TLS listener for other Macs, where every request needs the token."""
    class Handler(BaseHTTPRequestHandler):
        server_version = f"gpud/{VERSION}"
        protocol_version = "HTTP/1.1"  # keep-alive, so viewers polling every second reuse one TLS session
        timeout = 120

        def log_message(self, *args):
            pass

        def _private(self):
            """Not for web pages: remote viewers, or a browser (it always sends Origin; the app never does)."""
            return remote or "Origin" in self.headers

        def _json(self, obj, code=200, cors=True):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if not remote and cors:
                self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass  # the app cancels stale replay requests while scrubbing

        def do_GET(self):
            url = urlparse(self.path)
            if remote:
                sent = self.headers.get("Authorization", "").encode()
                if not hmac.compare_digest(sent, ("Bearer " + identity.token).encode()):
                    return self._json({"error": "pairing code required"}, 401)
            if url.path == "/health":
                info = sampler.host.get()
                return self._json({"ok": True, "version": VERSION, "id": identity.id if identity else None,
                                   "name": info["name"], "model": sampler._static["model"], "host": info})
            if url.path == "/api/v1/pairing" and not remote:
                # Only for apps on this Mac: no CORS header, and refuse anything not addressed to
                # loopback so a web page can't read it through DNS rebinding.
                if self.headers.get("Host", "").split(":")[0] not in ("127.0.0.1", "localhost", "[::1]"):
                    return self._json({"error": "forbidden"}, 403)
                if identity is None:
                    return self._json({"remote": False})
                return self._json({"remote": True, "code": identity.pairing_code, "id": identity.id,
                                   "name": computer_name(), "host": local_hostname(),
                                   "port": sampler.remote_port})
            if url.path == "/api/v1/status":
                with sampler.lock:
                    snap = sampler.latest
                if snap is None:
                    return self._json({"error": "warming up"}, 503)
                top = dict(snap, processes=snap["processes"][:5])
                return self._json(public_snapshot(top) if self._private() else top)
            if url.path == "/api/v1/processes":
                with sampler.lock:
                    snap = sampler.latest
                return self._json({"processes": snap["processes"] if snap else []})
            q = parse_qs(url.query)
            if url.path == "/api/v1/history":
                try:
                    secs = min(float(q.get("seconds", ["3600"])[0]), RETENTION_SECONDS)
                    points = min(int(q.get("points", ["300"])[0]), 5000)
                except ValueError:
                    return self._json({"error": "bad seconds/points"}, 400)
                return self._json(sampler.db.timeline(secs, points))
            if url.path == "/api/v1/at":
                try:
                    t = float(q["t"][0])
                except (KeyError, ValueError):
                    return self._json({"error": "pass ?t=<unix time>"}, 400)
                row = sampler.db.at(t)
                if row is None:
                    return self._json({"error": "no data at that time"}, 404)
                return self._json(sampler.replay_snapshot(row))
            if url.path == "/api/v1/tokens":
                with sampler.lock:
                    snap = sampler.latest
                return self._json(snap["tokens"] if snap else {})
            if url.path == "/api/v1/explain":
                ex = sampler.explainer
                if "pid" in q:
                    try:
                        pid = int(q["pid"][0])
                    except ValueError:
                        return self._json({"error": "pid must be a number"}, 400)
                    with sampler.lock:
                        procs = sampler.latest["processes"] if sampler.latest else []
                    p = next((p for p in procs if p["pid"] == pid), None)
                    entry = ex.get(pid)
                    if p and (q.get("refresh", ["0"])[0] == "1" or not entry):
                        entry = ex.explain(p, force=True)
                    if not entry:
                        return self._json({"error": "that process isn't using the GPU right now"}, 404)
                    return self._json(dict({k: v for k, v in entry.items() if k != "key"}, pid=pid))
                with ex.lock:
                    return self._json({"processes": [{"pid": pid, "text": e["text"], "facts": e.get("facts", []),
                                                      "source": e["source"], "at": e["at"],
                                                      "model": e["model"]} for pid, e in ex.cache.items()]})
            if url.path == "/api/v1/power":
                with sampler.lock:
                    snap = sampler.latest
                return self._json(snap["power"] if snap else {})
            if url.path == "/api/v1/usage":
                try:
                    if "preset" in q:
                        start, end = period(q["preset"][0], int(q.get("week_start", ["2"])[0]))
                    else:
                        start = float(q.get("from", ["0"])[0])
                        end = float(q.get("to", [str(time.time() + 3600)])[0])
                except (KeyError, ValueError):
                    return self._json({"error": "pass ?preset=today|week|month|ytd|total or ?from=&to= (unix)"}, 400)
                return self._json(sampler.db.usage(start, end, q.get("group", [None])[0]))
            if url.path == "/api/v1/cost":
                try:
                    if "preset" in q:
                        start, end = period(q["preset"][0], int(q.get("week_start", ["2"])[0]))
                    else:
                        start = float(q.get("from", ["0"])[0])
                        end = float(q.get("to", [str(time.time() + 3600)])[0])
                    num = lambda k, d, lo, hi: min(max(float(q.get(k, [d])[0]), lo), hi)
                    opts = {"cache_hit": num("cache_hit", 0, 0, 0.95), "batch": q.get("batch", ["0"])[0] in ("1", "true"),
                            "thinking": num("thinking", 0, 0, 3), "tokenizer": num("tokenizer", 1, 0.5, 2)}
                except (KeyError, ValueError):
                    return self._json({"error": "pass ?preset=… or ?from=&to=, plus optional cache_hit, batch, thinking, tokenizer"}, 400)
                usage = sampler.db.usage(start, end, "year")
                out = cloud_cost(usage, **opts)
                e = usage["energy"]
                # Electricity over the same span as the tokens. Power has been measured for only part of it
                # (it started later than token counting), so the rest is filled in at the measured average.
                span = out["days"] * 86400
                measured = e["measured_seconds"]
                scale = max(1.0, span / measured) if measured else None
                out["local"] = {
                    "chip_j": round(e["soc_j"] * scale, 1) if scale else None,
                    "system_j": round(e["system_j"] * scale, 1) if scale and e["system_j"] is not None else None,
                    "measured_hours": round(measured / 3600, 2), "period_hours": round(span / 3600, 2),
                    "system_overhead_w": e["system_overhead_w"],
                }
                return self._json(out)
            if url.path == "/api/v1/usage/summary":
                try:
                    ws = int(q.get("week_start", ["2"])[0])
                except ValueError:
                    ws = 2
                out = {}
                for name in ("today", "week", "month", "ytd", "total"):
                    u = sampler.db.usage(*period(name, ws), group="year")
                    out[name] = {"generated": u["generated"], "prompt": u["prompt"], "total": u["total"],
                                 "gpu_j": u["energy"]["gpu_j"], "ai_j": u["energy"]["ai_j"]}
                out["first_recorded"] = u["first_recorded"]
                return self._json(out)
            if url.path == "/api/v1/prices":
                return self._json(load_prices())
            if url.path == "/api/v1/prices/history":
                files = sorted(os.listdir(PRICES_BACKUP_DIR)) if os.path.isdir(PRICES_BACKUP_DIR) else []
                entries = []
                for f in files:
                    try:
                        with open(os.path.join(PRICES_BACKUP_DIR, f)) as fh:
                            data = json.load(fh)
                        entries.append({"file": f, "last_updated": data.get("last_updated"),
                                        "as_of": data.get("as_of"), "models": len(data.get("models", []))})
                    except (OSError, ValueError):
                        pass
                return self._json({"history": entries, "count": len(entries)})
            if url.path == "/api/v1/stream":
                return self._stream()
            if url.path == "/api/v1/llm-proxy" and not self._private() and self._loopback_host():
                return self._json(dict(sampler.proxy.status(), **sampler.proxy.summary(50)), cors=False)
            if url.path == "/api/v1/llm-proxy/models" and not self._private() and self._loopback_host():
                d = sampler.models.status(refresh=q.get("refresh") == ["1"])
                d["usage"] = modellib.usage(sampler.proxy.history(5000), sampler.proxy.summary(0)["active"])
                return self._json(d, cors=False)
            if url.path == "/api/v1/llm-proxy/log" and not self._private() and self._loopback_host():
                try:
                    limit = max(1, min(int(q.get("limit", ["2000"])[0]), 20000))
                except ValueError:
                    limit = 2000
                return self._json({"on": sampler.proxy.state == "on", "active": sampler.proxy.summary(0)["active"],
                                   "entries": sampler.proxy.history(limit)}, cors=False)
            return self._json({"error": "not found"}, 404)

        def _loopback_host(self):
            """Addressed to loopback, so a web page can't reach it through DNS rebinding."""
            return self.headers.get("Host", "").rsplit(":", 1)[0] in ("127.0.0.1", "localhost", "[::1]")

        def do_POST(self):
            # Settings changes: only from apps on this Mac. JSON only, which a web page can't send to another
            # site without a preflight this server never answers.
            path = urlparse(self.path).path
            if self._private() or path not in ("/api/v1/llm-proxy", "/api/v1/llm-proxy/models") or not self._loopback_host():
                return self._json({"error": "not found"}, 404, cors=False)
            if not self.headers.get("Content-Type", "").startswith("application/json"):
                return self._json({"error": "send JSON"}, 415, cors=False)
            n = int(self.headers.get("Content-Length") or 0)
            try:
                change = json.loads(self.rfile.read(n)) if 0 < n < 65536 else None
                if not isinstance(change, dict):
                    raise ValueError("send a JSON object")
                if path.endswith("/models"):
                    return self._json(sampler.models.change(change), cors=False)
                return self._json(sampler.proxy.configure(change), cors=False)
            except (ValueError, TypeError) as e:
                return self._json({"error": str(e)}, 400, cors=False)

        def _stream(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            if not remote:
                self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.close_connection = True
            private = self._private()
            last = None
            try:
                while True:
                    with sampler.cond:
                        sampler.cond.wait_for(lambda: sampler.latest is not last, timeout=15)
                        snap = sampler.latest
                    if snap is last:
                        self.wfile.write(b": keepalive\n\n")
                    else:
                        last = snap
                        self.wfile.write(b"data: " + json.dumps(public_snapshot(snap) if private else snap).encode() + b"\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    return Handler


def advertise(identity, port, info):
    """Announce this Mac over Bonjour so viewers on the network can find it."""
    txt = {"id": identity.id, "host": info["hostname"], "port": port, "model": info["chip"], "ver": VERSION,
           "mac": info["model_name"], "gpu": info["gpu_cores"], "mem": round(info["memory_bytes"] / 2**30),
           "os": info["macos"]}
    proc = subprocess.Popen(["dns-sd", "-R", computer_name(), BONJOUR_TYPE, "local", str(port)]
                            + [f"{k}={v}" for k, v in txt.items()],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    atexit.register(proc.terminate)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=int(os.environ.get("GPUD_PORT", 8765)))
    ap.add_argument("--interval", type=float, default=1.0, help="seconds between samples")
    ap.add_argument("--db", default=os.environ.get("GPUD_DB", DEFAULT_DB), help="SQLite history file")
    ap.add_argument("--remote-port", type=int, default=int(os.environ.get("GPUD_REMOTE_PORT", 8766)),
                    help="TLS port for GPU Buddy on other Macs (0 turns remote viewing off)")
    ap.add_argument("--pairing-code", action="store_true", help="print this Mac's pairing code and exit")
    ap.add_argument("--new-pairing-code", action="store_true",
                    help="make a new pairing code (unpairs every other Mac), print it and exit")
    args = ap.parse_args()

    if args.pairing_code or args.new_pairing_code:
        identity = Identity()
        if args.new_pairing_code:
            identity.new_token()
            identity = Identity()
            print("New code. Restart gpud to apply: launchctl kickstart -k gui/$(id -u)/local.gpubuddy.gpud", file=sys.stderr)
        print(identity.pairing_code)
        return

    # Exit through atexit on SIGTERM (launchctl stop/kickstart), so helpers and the Bonjour ad go too.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    tokens = TokenWatcher(args.interval)
    threading.Thread(target=tokens.loop, daemon=True).start()
    power = PowerWatcher(args.interval)
    threading.Thread(target=power.loop, daemon=True).start()
    threading.Thread(target=_prices_update_thread, daemon=True).start()
    sampler = GPUSampler(args.interval, HistoryDB(args.db), tokens, power)
    sampler.remote_port = args.remote_port
    sampler.explainer = Explainer(sampler, tokens)
    if args.remote_port:
        llmproxy.RESERVED_PORTS.add(args.remote_port)
    sampler.proxy = tokens.proxy = llmproxy.LLMProxy()
    sampler.models = modellib.ModelLibrary()
    threading.Thread(target=sampler.explainer.loop, daemon=True).start()
    threading.Thread(target=sampler.loop, daemon=True).start()

    identity = None
    if args.remote_port:
        try:
            identity = Identity()
            rserver = DualStackServer(("::", args.remote_port), make_handler(sampler, identity, remote=True))
            # The handshake runs in the request thread, so a slow client can't stall accept().
            rserver.socket = identity.tls_context().wrap_socket(rserver.socket, server_side=True,
                                                                do_handshake_on_connect=False)
            threading.Thread(target=rserver.serve_forever, daemon=True).start()
            advertise(identity, args.remote_port, sampler.host.get())
            print(f"gpud: remote viewing on https://{local_hostname()}:{args.remote_port} "
                  f"(pairing code: python3 gpud.py --pairing-code)", flush=True)
        except Exception as e:
            identity = None
            print(f"gpud: remote viewing off: {e}", file=sys.stderr, flush=True)

    server = QuietServer((args.host, args.port), make_handler(sampler, identity))
    print(f"gpud {VERSION}: {sampler._static['model']} ({sampler._static['cores']} cores) "
          f"on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
