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

VERSION = "1.6.0"
RETENTION_SECONDS = 24 * 3600
STATE_DIR = os.path.expanduser("~/Library/Application Support/GPUBuddy")
DEFAULT_DB = os.path.join(STATE_DIR, "history.db")
BONJOUR_TYPE = "_gpubuddy._tcp"
POWER_KEYS = ("gpu", "cpu", "ane", "dram", "other")

# Process names that are almost certainly doing AI / ML work on the GPU.
AI_HINTS = (
    "ollama", "llama", "mlx", "lm studio", "lmstudio", "python", "comfy", "diffusion",
    "whisper", "torch", "vllm", "gpt4all", "kobold", "jan", "draw things", "exo",
    "mlc", "msty", "invoke", "fooocus", "claude", "chatgpt",
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


LLM_HINTS = ("mlx", "llama", "ollama", "vllm", "lm studio", "lmstudio", "lms ", "exo", "kobold", "gpt4all", "jan", "sglang", "tabby")
PROM_PROMPT = ("llamacpp:prompt_tokens_total", "vllm:prompt_tokens_total", "sglang:prompt_tokens_total")
PROM_GEN = ("llamacpp:tokens_predicted_total", "vllm:generation_tokens_total", "sglang:generation_tokens_total")
PROM_RUNNING = ("llamacpp:requests_processing", "vllm:num_requests_running", "sglang:num_running_reqs")


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
        return None

    def _read(self, src):
        """(prompt_total, generated_total, in_flight, speed tok/s, model) or None."""
        if src["kind"] == "mlx-json":
            d = json.loads(http_get(src["url"] + "/metrics"))
            sm, latest, srv = d.get("summary", {}), d.get("latest") or {}, d.get("server") or {}
            model = os.path.basename(str(srv.get("loaded_model") or latest.get("model") or "").rstrip("/"))
            if model == "model":  # ".../qwen36-moe-mlx/model" -> "qwen36-moe-mlx"
                model = os.path.basename(os.path.dirname(str(srv.get("loaded_model") or latest.get("model")).rstrip("/")))
            return (sm.get("prompt_tokens_total", 0), sm.get("completion_tokens_total", 0),
                    sm.get("in_flight", 0), latest.get("decode_tok_s", 0) or 0, model)
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
            return pick(PROM_PROMPT), pick(PROM_GEN), pick(PROM_RUNNING), None, ""
        if src["kind"] == "ollama":
            return None  # Ollama exposes no token counters
        return None

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
                                              "gen_rate": 0.0, "prompt_rate": 0.0, "last_ts": now}
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
                prompt, gen, in_flight, speed, model = r
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
                src.update(prompt=prompt, gen=gen, in_flight=in_flight, model=model,
                           gen_rate=d_gen / dt, prompt_rate=d_prompt / dt, last_ts=now,
                           speed=(speed if speed is not None else d_gen / dt) if (in_flight or d_gen) else 0.0)

    def take(self):
        """Tokens counted since the last call, per (server, model), plus a public view of each source."""
        with self.lock:
            gen, prompt, by = self._pending_gen, self._pending_prompt, self._pending_by
            self._pending_gen = self._pending_prompt = 0
            self._pending_by = {}
            view = [{"name": s["name"], "url": s["url"], "kind": s["kind"], "pid": s["pid"], "model": s["model"],
                     "in_flight": s["in_flight"], "tok_s": round(s["speed"], 1),
                     "generated_total": s["gen"], "prompt_total": s["prompt"]}
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
        self._energy = dict.fromkeys(POWER_KEYS, 0.0)  # joules since the last take()
        self._proc = None
        atexit.register(lambda: self._proc and self._proc.terminate())

    @staticmethod
    def _binary():
        """Path to gpupower, compiled from gpupower.c next to this file when missing or stale."""
        src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gpupower.c")
        out = os.path.join(STATE_DIR, "gpupower")
        if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
            os.makedirs(STATE_DIR, exist_ok=True)
            subprocess.run(["clang", "-O2", "-o", out, src, "-framework", "CoreFoundation", "-lIOReport"],
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
                        for k in POWER_KEYS:
                            self._energy[k] += d[k + "_w"] * d["dt"]
                self.error = (self._proc.stderr.read().strip() or "gpupower stopped")[:200]
            except Exception as e:
                self.error = str(e)[:200]
            print(f"gpud: power readings unavailable: {self.error}", file=sys.stderr, flush=True)
            with self.lock:
                self.latest = None
            time.sleep(30)

    def take(self):
        """(latest watts or None, joules per block since the last call)."""
        with self.lock:
            energy, self._energy = self._energy, dict.fromkeys(POWER_KEYS, 0.0)
            return self.latest, energy


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
            self.conn.execute("""INSERT INTO token_usage
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
        self.conn.commit()
        self._pending = 0

    def add(self, snap, by_model=None, energy=None, model_energy=None):
        keys = ("pid", "name", "gpu_percent", "is_ai", "activity", "command", "cwd", "tok_s")
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
                    """INSERT INTO power_hourly VALUES (?,?,?,?,?,?,?,?) ON CONFLICT (hour) DO UPDATE SET
                       gpu_j = gpu_j + excluded.gpu_j, cpu_j = cpu_j + excluded.cpu_j, ane_j = ane_j + excluded.ane_j,
                       dram_j = dram_j + excluded.dram_j, other_j = other_j + excluded.other_j,
                       ai_j = ai_j + excluded.ai_j, seconds = seconds + excluded.seconds""",
                    (hour, *(energy.get(k, 0.0) for k in POWER_KEYS), energy.get("ai", 0.0), energy.get("seconds", 0.0)))
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
                           COALESCE(SUM(seconds), 0)
                    FROM power_hourly WHERE {where}""", (start, end)).fetchone()
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
                           "speed_tok_s": 0, "in_flight": 0, "sources": []}}


class GPUSampler:
    def __init__(self, interval, db, tokens, power):
        self.interval = interval
        self.db = db
        self.tokens = tokens
        self.power = power
        self.gpu_peak_w = 0.0
        self._ai_pool = 0.0  # LLM energy (J) not yet matched to the tokens it produced
        self._ai_pool_t = time.time()
        self._e24 = list(db.energy_totals(time.time() - RETENTION_SECONDS))
        self._tok24 = list(db.token_totals(time.time() - RETENTION_SECONDS))
        self._tok24_refreshed = time.time()
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
            self._tok24_refreshed = now
        self._tok24[0] += gen_d
        self._tok24[1] += prompt_d
        speed = {s["pid"]: s for s in sources if s["pid"]}
        for p in active:
            if p["pid"] in speed:
                p["tok_s"] = speed[p["pid"]]["tok_s"]
                p["is_ai"] = True
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
            power.update({
                "soc_w": round(soc, 2),
                "ai_w": round(ai_w, 2),
                "gpu_peak_w": round(self.gpu_peak_w, 1),
                "j_per_token": round(jpt, 3) if jpt else None,       # right now, while decoding
                "tokens_per_wh": round(3600 / jpt) if jpt else None,
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
                "sources": sources,
            },
            "power": power,
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


class DualStackServer(ThreadingHTTPServer):
    """Listens on IPv6 and IPv4, so "Studio.local" works whichever address it resolves to."""
    address_family = socket.AF_INET6
    daemon_threads = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (ssl.SSLError, ConnectionError, socket.timeout)):
            return  # plain-HTTP probes, port scans, viewers that went away
        super().handle_error(request, client_address)


def make_handler(sampler, identity=None, remote=False):
    """remote=True: the TLS listener for other Macs, where every request needs the token."""
    class Handler(BaseHTTPRequestHandler):
        server_version = f"gpud/{VERSION}"
        protocol_version = "HTTP/1.1"  # keep-alive, so viewers polling every second reuse one TLS session
        timeout = 120

        def log_message(self, *args):
            pass

        def _json(self, obj, code=200):
            body = json.dumps(obj).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if not remote:
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
                return self._json({"ok": True, "version": VERSION, "id": identity.id if identity else None,
                                   "name": computer_name(), "model": sampler._static["model"]})
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
                return self._json(top)
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
            if url.path == "/api/v1/stream":
                return self._stream()
            return self._json({"error": "not found"}, 404)

        def _stream(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            if not remote:
                self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.close_connection = True
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
                        self.wfile.write(b"data: " + json.dumps(snap).encode() + b"\n\n")
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    return Handler


def advertise(identity, port, model):
    """Announce this Mac over Bonjour so viewers on the network can find it."""
    txt = {"id": identity.id, "host": local_hostname(), "port": port, "model": model, "ver": VERSION}
    proc = subprocess.Popen(["dns-sd", "-R", computer_name(), BONJOUR_TYPE, "local", str(port)]
                            + [f"{k}={v}" for k, v in txt.items()],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    atexit.register(proc.terminate)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))  # runs atexit, so the ad goes away with us


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

    tokens = TokenWatcher(args.interval)
    threading.Thread(target=tokens.loop, daemon=True).start()
    power = PowerWatcher(args.interval)
    threading.Thread(target=power.loop, daemon=True).start()
    sampler = GPUSampler(args.interval, HistoryDB(args.db), tokens, power)
    sampler.remote_port = args.remote_port
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
            advertise(identity, args.remote_port, sampler._static["model"])
            print(f"gpud: remote viewing on https://{local_hostname()}:{args.remote_port} "
                  f"(pairing code: python3 gpud.py --pairing-code)", flush=True)
        except Exception as e:
            identity = None
            print(f"gpud: remote viewing off: {e}", file=sys.stderr, flush=True)

    server = ThreadingHTTPServer((args.host, args.port), make_handler(sampler, identity))
    server.daemon_threads = True
    print(f"gpud {VERSION}: {sampler._static['model']} ({sampler._static['cores']} cores) "
          f"on http://{args.host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
