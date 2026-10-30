"""llmproxy: shows who is using your local LLM server, and what for. Part of gpud, off until turned on.

When on, gpud listens on the server's usual port (8080) and passes every request through, unchanged, to the
server, which moves to the next port (8081) and to this Mac only. Clients keep their settings. For each model
request it notes:

  who    - this Mac's program (from the connection's port: claude, node in Visual Studio Code…) or the device's address
  agent  - Claude Code, Cline, curl… recognized from the system prompt and request headers
  what   - optional: the first 100 characters of the last user message ("snippets", off by default)
  sizes  - model, prompt and answer tokens, time to first token, total time

Security:
  - Only this Mac and the addresses in the allow list can use the server. Optionally, other devices must also send
    an API key (Authorization: Bearer <key>, or x-api-key).
  - The log stays on this Mac (~/Library/Application Support/GPUBuddy/llm-requests.jsonl, readable by you only) and
    entries older than the retention period (7 days) are deleted. Request headers (keys, passwords) are never stored,
    and neither are whole prompts or answers.
  - Moving the server edits the one line of its start script or LaunchAgent that sets the port (and its host, so
    nobody can go around the proxy), after saving a backup; turning the log off puts it back.
"""

import collections
import hashlib
import hmac
import http.client
import json
import os
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = os.path.expanduser("~/Library/Application Support/GPUBuddy")
CONFIG = os.path.join(STATE_DIR, "llm-proxy.json")
LOG = os.path.join(STATE_DIR, "llm-requests.jsonl")
BACKUPS = os.path.join(STATE_DIR, "llm-proxy-backups")
LAUNCH_AGENTS = os.path.expanduser("~/Library/LaunchAgents")

DEFAULTS = {"enabled": False, "listen_port": 8080, "upstream_port": 8081, "allow": [], "api_key": "",
            "snippets": False, "retention_days": 7, "moved": None}

# Headers that belong to one connection, not to the request, so they aren't passed on.
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "trailers",
       "transfer-encoding", "upgrade", "host", "content-length"}
# Requests worth logging (model work). Everything else (/v1/models, /metrics…) just passes through.
MODEL_PATHS = ("completions", "/messages", "/responses", "/embeddings", "/generate", "/api/chat")
MAX_BODY = 256 * 2**20
SNIPPET = 100

# (pattern, agent, icon). Checked against headers and the start of the system prompt, first match wins.
AGENTS = [
    (r"You are Claude Code|Claude Agent SDK|claude-cli/|claude-code", "Claude Code", "✳️"),
    (r"You are Cline\b|cline\.bot|X-Title: Cline", "Cline", "🤖"),
    (r"You are Roo\b|Roo Code", "Roo Code", "🦘"),
    (r"You are Kilo Code|Kilo Code", "Kilo Code", "🪁"),
    (r"Codex CLI|You are Codex|codex_cli", "Codex", "📜"),
    (r"You are opencode|opencode", "opencode", "🔓"),
    (r"You are OpenHands|OpenHands", "OpenHands", "🙌"),
    (r"You are goose|\bgoose\b", "Goose", "🪿"),
    (r"\baider\b|Act as an expert software developer", "Aider", "🧑‍💻"),
    (r"Continue\.dev|continuedev|X-Title: Continue", "Continue", "▶️"),
    (r"operate exclusively in Cursor|Cursor/", "Cursor", "🖱️"),
    (r"GitHub Copilot", "GitHub Copilot", "🧑‍✈️"),
    (r"\bZed\b", "Zed", "⚡"),
    (r"Open WebUI|open-webui", "Open WebUI", "🌐"),
    (r"LibreChat", "LibreChat", "💬"),
    # Generic programs: only when nothing above matched the headers or the prompt.
    (r"^User-Agent: curl/", "curl", "🐚"),
    (r"^User-Agent: (Async)?OpenAI/Python|^User-Agent: python|aiohttp|httpx", "Python script", "🐍"),
    (r"^User-Agent: (OpenAI/JS|node|axios|undici)", "Node script", "🟩"),
    (r"^User-Agent: [Aa]nthropic", "Anthropic SDK", "🅰️"),
]
GENERIC = {"curl", "Python script", "Node script", "Anthropic SDK"}
AGENTS = [(re.compile(p, re.M), name, icon) for p, name, icon in AGENTS]
FIRST_TOKEN = re.compile(rb'"(content|reasoning_content|reasoning|text|partial_json|thinking|response)"\s*:\s*"[^"]')


def _now():
    return time.time()


def _clean_ip(ip):
    return ip[7:] if ip.startswith("::ffff:") else ip


def _text(content):
    """Plain text of a message's content (a string, or a list of parts)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(p.get("text", "") if isinstance(p, dict) else str(p) for p in content
                        if not isinstance(p, dict) or p.get("type") in (None, "text", "input_text"))
    return ""


def _clean(text):
    text = re.sub(r"<(system-reminder|environment_details|context|env)>.*?</\1>", " ", text, flags=re.S)
    text = re.sub(r"<[^>]{1,40}>", " ", text)
    return " ".join(text.split())


def _snippet(body):
    """The first SNIPPET characters of the last thing the user typed, without the reminders agents add to it."""
    msgs = body.get("messages") or body.get("input") or []
    if isinstance(msgs, str):
        text = msgs
    else:
        text = ""
        for m in reversed(msgs):
            if isinstance(m, dict) and m.get("role") == "user":
                text = _clean(_text(m.get("content")))
                if text:
                    break
    if not text and isinstance(body.get("prompt"), str):
        text = body["prompt"]
    text = _clean(text)
    return text[:SNIPPET] + ("…" if len(text) > SNIPPET else "")


def recognize(headers, body):
    """(agent, icon): which agent or program sent the request."""
    hs = "\n".join(f"{k}: {v}" for k, v in headers.items() if k.lower() in ("user-agent", "x-title", "http-referer",
                                                                            "x-stainless-package-version", "anthropic-beta"))
    system = _text(body.get("system")) if body.get("system") else ""
    for m in (body.get("messages") or [])[:2]:
        if isinstance(m, dict) and m.get("role") in ("system", "developer"):
            system += " " + _text(m.get("content"))
    prompt = system[:6000] + "\n" + str(body.get("instructions") or "")[:3000]
    # An agent's own headers beat a mention of another agent in its prompt; a generic user agent (curl, an SDK) comes last.
    for hay, generic in ((hs, False), (prompt, False), (hs, True)):
        for pat, name, icon in AGENTS:
            if (name in GENERIC) == generic and pat.search(hay):
                return name, icon
    ua = headers.get("User-Agent", "")
    return (ua.split("/")[0][:30] or "unknown"), "❔"


def _usage(head, tail, streamed):
    """(prompt tokens, answer tokens) from an OpenAI or Anthropic style answer, or (None, None)."""
    prompt = out = None
    blobs = []
    if streamed:
        for part in (head, tail):
            blobs += [line[5:].strip() for line in part.split(b"\n") if line.startswith(b"data:")]
    else:
        blobs = [head]
    for b in blobs:
        if b"usage" not in b and b"eval_count" not in b:
            continue
        try:
            d = json.loads(b)
        except ValueError:
            continue
        u = d.get("usage") or (d.get("message") or {}).get("usage") or d
        prompt = u.get("prompt_tokens") or u.get("input_tokens") or u.get("prompt_eval_count") or prompt
        out = u.get("completion_tokens") or u.get("output_tokens") or u.get("eval_count") or out
    return prompt, out


class _Lookup:
    """Names for the other end of a connection: this Mac's program, or the device's network name."""
    names = {}  # ip -> (name, time)

    @staticmethod
    def local_addresses():
        out = {"127.0.0.1", "::1"}
        try:
            for line in subprocess.run(["ifconfig"], capture_output=True, timeout=2).stdout.decode().splitlines():
                parts = line.split()
                if len(parts) > 1 and parts[0] in ("inet", "inet6"):
                    out.add(parts[1].split("%")[0])
        except Exception:
            pass
        return out

    @staticmethod
    def process(port):
        """(program, app) on this Mac that owns the client end of the connection from `port`."""
        try:
            raw = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:ESTABLISHED", "-Fpn"],
                                 capture_output=True, timeout=3).stdout.decode()
        except Exception:
            return None, None
        pid = None
        for line in raw.splitlines():
            if line.startswith("p"):
                pid = int(line[1:])
            elif line.startswith("n") and pid and pid != os.getpid() and line[1:].split("->")[0].endswith(f":{port}"):
                break
        else:
            return None, None
        try:
            ps = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, timeout=3).stdout.decode()
        except Exception:
            return None, None
        table = {}
        for line in ps.splitlines():
            a = line.split(None, 2)
            if len(a) == 3 and a[0].isdigit():
                table[int(a[0])] = (int(a[1]), a[2])
        name = os.path.basename(table.get(pid, (0, "?"))[1].strip("()")) or None
        app, p = None, pid
        for _ in range(12):  # the app it runs in: the nearest parent inside a .app bundle
            if p not in table or p <= 1:
                break
            m = re.search(r"/([^/]+)\.app/", table[p][1])
            if m:
                app = m.group(1)
                if " Helper" not in app:
                    break
            p = table[p][0]
        return name, app

    @classmethod
    def device(cls, ip):
        hit = cls.names.get(ip)
        if hit and _now() - hit[1] < 600:
            return hit[0]
        name = None
        try:
            name = socket.gethostbyaddr(ip)[0].rstrip(".")
            name = name[:-6] if name.endswith(".local") else name
        except Exception:
            pass
        cls.names[ip] = (name, _now())
        return name


class LLMProxy:
    def __init__(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        self.lock = threading.RLock()
        self.cfg = dict(DEFAULTS)
        try:
            with open(CONFIG) as f:
                self.cfg.update(json.load(f))
        except (OSError, ValueError):
            pass
        self.server = None
        self.state, self.message = "off", None
        self.active = {}  # id -> request in progress
        self.recent = collections.deque(maxlen=200)
        self.local_ips = _Lookup.local_addresses()
        self._busy = threading.Lock()  # one turn on / off at a time
        self._load_recent()
        if self.cfg["enabled"]:
            threading.Thread(target=self._start, daemon=True).start()
        threading.Thread(target=self._housekeeping, daemon=True).start()

    # ---- settings

    def _save(self):
        tmp = CONFIG + ".tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # holds the API key: owner only
        with os.fdopen(fd, "w") as f:
            json.dump(self.cfg, f, indent=1)
        os.replace(tmp, CONFIG)

    def status(self, local=True):
        with self.lock:
            c = self.cfg
            out = {"enabled": c["enabled"], "state": self.state, "message": self.message,
                   "listen_port": c["listen_port"], "upstream_port": c["upstream_port"], "allow": c["allow"],
                   "key_required": bool(c["api_key"]), "snippets": c["snippets"], "retention_days": c["retention_days"],
                   "moved": c["moved"] and {"file": c["moved"]["file"], "backup": c["moved"]["backup"]},
                   "log_file": LOG,
                   "addresses": _addresses(self.local_ips)}
            if local:
                out["api_key"] = c["api_key"]
            return out

    def configure(self, change):
        """Apply settings from the app. Turning on or off can take a few seconds (the LLM server restarts)."""
        with self.lock:
            if "snippets" in change:
                self.cfg["snippets"] = bool(change["snippets"])
            if "allow" in change:
                allow = [a.strip() for a in change["allow"] if isinstance(a, str) and a.strip()]
                bad = [a for a in allow if not re.fullmatch(r"[0-9a-fA-F:.]+(/\d{1,3})?|\*", a)]
                if bad:
                    raise ValueError(f"not an IP address: {', '.join(bad)}")
                self.cfg["allow"] = allow
            if change.get("new_api_key"):
                self.cfg["api_key"] = "gb-" + secrets.token_urlsafe(24)
            if change.get("remove_api_key"):
                self.cfg["api_key"] = ""
            if "retention_days" in change:
                self.cfg["retention_days"] = max(1, min(365, int(change["retention_days"])))
            self._save()
        if "enabled" in change and bool(change["enabled"]) != self.cfg["enabled"]:
            if change["enabled"]:  # can take a while (the server restarts and loads), so the app polls status
                with self.lock:
                    self.state, self.message = "starting", None
                threading.Thread(target=self._start, daemon=True).start()
            else:  # waits until the server is back on its port, so uninstalling can rely on it
                self._stop()
        return self.status()

    # ---- turning on and off

    def _start(self):
        with self._busy:
            c = self.cfg
            with self.lock:
                c["enabled"] = True
                self._save()
                self.state, self.message = "starting", None
            port, up = c["listen_port"], c["upstream_port"]
            if _port_open(port) and not c["moved"]:
                job = find_server_job(port)
                if job is None:
                    return self._fail(f"Port {port} is in use by a program GPU Buddy doesn't know how to move. Start your "
                                      f"LLM server on port {up}, for this Mac only (host 127.0.0.1), then try again.")
                try:
                    self.message = f"Moving your LLM server to port {up}…"
                    moved = move_server(job, port, up)
                except Exception as e:
                    return self._fail(f"Couldn't move the LLM server: {e}")
                with self.lock:
                    c["moved"] = moved
                    self._save()
            for _ in range(240):  # the old server lets go of the port as it restarts
                try:
                    srv = _DualStack(("::", port), self._handler())
                    break
                except OSError:
                    if not c["enabled"]:
                        return
                    time.sleep(0.5)
            else:
                return self._fail(f"Port {port} stayed busy, so the request log couldn't start.")
            self.server = srv
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            with self.lock:
                self.state = "on"
                self.message = None if _wait_port(up, 1) else f"Waiting for the LLM server on port {up}…"
            print(f"gpud: LLM request log on :{port} -> 127.0.0.1:{up}", flush=True)

    def _fail(self, msg):
        with self.lock:
            self.cfg["enabled"] = False
            self._save()
            self.state, self.message = "error", msg
        print(f"gpud: LLM request log: {msg}", flush=True)

    def _stop(self):
        with self._busy:
            with self.lock:
                self.cfg["enabled"] = False
                self._save()
                self.state, self.message = "stopping", None
            if self.server:
                self.server.shutdown()
                self.server.server_close()
                self.server = None
            msg = None
            if self.cfg["moved"]:
                try:
                    msg = restore_server(self.cfg["moved"])
                except Exception as e:
                    msg = f"Couldn't put the LLM server back on port {self.cfg['listen_port']}: {e}"
                with self.lock:
                    self.cfg["moved"] = None
                    self._save()
            with self.lock:
                self.state, self.message = "off", msg

    # ---- the log

    def _load_recent(self):
        try:
            with open(LOG) as f:
                lines = f.readlines()[-200:]
            for line in lines:
                try:
                    self.recent.append(json.loads(line))
                except ValueError:
                    pass
        except OSError:
            pass

    def _write(self, entry):
        with self.lock:
            self.recent.append(entry)
            try:
                fd = os.open(LOG, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
                with os.fdopen(fd, "a") as f:
                    f.write(json.dumps(entry) + "\n")
            except OSError:
                pass

    def _housekeeping(self):
        while True:
            self.local_ips = _Lookup.local_addresses()
            cutoff = _now() - self.cfg["retention_days"] * 86400
            with self.lock:
                try:
                    with open(LOG) as f:
                        lines = f.readlines()
                    keep = [l for l in lines if (json.loads(l).get("started") or 0) >= cutoff]
                    if len(keep) != len(lines):
                        with open(LOG + ".tmp", "w") as f:
                            f.writelines(keep)
                        os.chmod(LOG + ".tmp", 0o600)
                        os.replace(LOG + ".tmp", LOG)
                except (OSError, ValueError):
                    pass
            time.sleep(3600)

    def history(self, limit=2000):
        """The log, newest first: every request kept (the last `retention_days`)."""
        with self.lock:
            try:
                with open(LOG) as f:
                    lines = collections.deque(f, maxlen=limit)
            except OSError:
                return []
        out = []
        for line in reversed(lines):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    def now_doing(self):
        """What the LLM server is doing, for the "what's happening" box: a short headline and a few facts about the
        oldest request running, or the one that just finished. None when it's idle (or the log is off)."""
        with self.lock:
            act = sorted(self.active.values(), key=lambda r: r["started"])
            last = self.recent[-1] if self.recent else None
        now = _now()
        if act:
            r = act[0]
            caller = _caller(r)
            facts = [caller] if caller else []
            if r["state"] == "answering":
                head = f"Answering {r['agent']}"
                facts.append(f"⏱ 1st token {_secs(r['ttft'])}" if r.get("ttft") else f"{_secs(now - r['started'])}")
            else:
                head = f"Reading {r['agent']}'s prompt"
                if r.get("est_tokens"):
                    facts.append(f"~{_count(r['est_tokens'])} tokens")
                facts.append(f"⏳ {_secs(now - r['started'])}")
            if len(act) > 1:
                facts.append(f"+{len(act) - 1} waiting")
            return {"headline": head, "facts": facts[:3], "icon": r["icon"], "quote": r.get("snippet")}
        if last and last.get("state") == "done" and now - (last["started"] + (last.get("seconds") or 0)) < 20:
            facts = [c for c in [_caller(last)] if c]
            if last.get("output_tokens"):
                facts.append(f"✍️ {_count(last['output_tokens'])} tokens in {_secs(last.get('seconds') or 0)}")
            if last.get("ttft"):
                facts.append(f"⏱ 1st token {_secs(last['ttft'])}")
            return {"headline": f"Just answered {last['agent']}", "facts": facts[:3], "icon": last["icon"],
                    "quote": last.get("snippet")}
        return None

    def summary(self, recent=8):
        """For the app's live view: requests running now and the last few."""
        with self.lock:
            return {"on": self.state == "on",
                    "active": [{k: v for k, v in r.items() if not k.startswith("_")} for r in self.active.values()],
                    "recent": list(self.recent)[-recent:][::-1]}

    # ---- the proxy

    def _allowed(self, ip, headers):
        """None if this caller may use the server, else why not."""
        if ip in self.local_ips:
            return None
        allow = self.cfg["allow"]
        if "*" not in allow and not any(_ip_match(ip, a) for a in allow):
            return f"{ip} isn't on GPU Buddy's allow list for this LLM server"
        key = self.cfg["api_key"]
        if key:
            sent = headers.get("Authorization", "")
            sent = sent[7:] if sent.startswith("Bearer ") else headers.get("x-api-key", "")
            if not hmac.compare_digest(sent.encode(), key.encode()):
                return "this LLM server needs GPU Buddy's API key"
        return None

    def _handler(self):
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            server_version = "gpud-llm-proxy"
            timeout = 900

            def log_message(self, *args):
                pass

            def _error(self, code, msg):
                body = json.dumps({"error": {"message": msg, "type": "gpu_buddy_proxy"}}).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _read_body(self):
                if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
                    data = b""
                    while True:
                        size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                        if size == 0:
                            self.rfile.readline()
                            return data
                        data += self.rfile.read(size)
                        self.rfile.readline()
                        if len(data) > MAX_BODY:
                            raise ValueError("request too large")
                n = int(self.headers.get("Content-Length") or 0)
                if n > MAX_BODY:
                    raise ValueError("request too large")
                return self.rfile.read(n) if n else b""

            def _go(self):
                ip, port = _clean_ip(self.client_address[0]), self.client_address[1]
                logged = self.command == "POST" and any(p in self.path for p in MODEL_PATHS)
                try:
                    body = self._read_body()
                except ValueError as e:
                    self.close_connection = True
                    return self._error(413, str(e))
                entry = None
                if logged:
                    entry = proxy._begin(ip, port, self.path, self.headers, body)
                why = proxy._allowed(ip, self.headers)
                if why:
                    if entry:
                        proxy._finish(entry, 403, state="blocked")
                    elif self.command != "OPTIONS":
                        proxy._write({"id": secrets.token_hex(4), "started": _now(), "ip": ip, "path": self.path,
                                      "agent": "Unknown device", "icon": "⛔", "who": _Lookup.device(ip) or ip, "state": "blocked",
                                      "status": 403})
                    return self._error(403, why)
                try:
                    self._forward(body, entry)
                except (BrokenPipeError, ConnectionResetError):
                    if entry:
                        proxy._finish(entry, 499, state="cancelled")
                except Exception as e:
                    if entry:
                        proxy._finish(entry, 502, state="error")
                    try:
                        self._error(502, f"GPU Buddy couldn't reach the LLM server on port {proxy.cfg['upstream_port']}: {e}")
                    except Exception:
                        pass

            def _forward(self, body, entry):
                up = http.client.HTTPConnection("127.0.0.1", proxy.cfg["upstream_port"], timeout=900)
                headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
                headers["Host"] = f"127.0.0.1:{proxy.cfg['upstream_port']}"
                headers["X-Forwarded-For"] = _clean_ip(self.client_address[0])
                if body or self.command in ("POST", "PUT", "PATCH"):
                    headers["Content-Length"] = str(len(body))
                try:
                    self._relay(up, body, headers, entry)
                finally:
                    up.close()  # if the client hung up, this tells the server to stop generating

            def _relay(self, up, body, headers, entry):
                up.request(self.command, self.path, body=body or None, headers=headers)
                resp = up.getresponse()
                if entry:
                    entry["state"] = "waiting"
                self.send_response_only(resp.status, resp.reason)
                length = resp.getheader("Content-Length")
                for k, v in resp.getheaders():
                    if k.lower() not in HOP:
                        self.send_header(k, v)
                if length is not None and self.command != "HEAD":
                    self.send_header("Content-Length", length)
                else:
                    self.send_header("Connection", "close")  # streamed: the body ends when the connection closes
                    self.close_connection = True
                self.end_headers()
                streamed = "event-stream" in (resp.getheader("Content-Type") or "") or length is None
                head, tail, pieces, partial = b"", b"", 0, b""
                while True:
                    chunk = resp.read1(65536) if self.command != "HEAD" else b""
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    if entry:
                        if entry["state"] == "waiting" and (not streamed or FIRST_TOKEN.search(chunk)):
                            entry["state"] = "answering"
                            if streamed:  # a whole answer at once has no separate first token
                                entry["ttft"] = round(_now() - entry["started"], 3)
                        if len(head) < (4 << 20 if not streamed else 32768):
                            head += chunk
                        tail = (tail + chunk)[-32768:]
                        if streamed:  # one streamed piece is about one token: a count for clients that don't ask for usage
                            lines = (partial + chunk).split(b"\n")
                            partial = lines.pop()
                            pieces += sum(1 for l in lines if l.startswith(b"data:") and FIRST_TOKEN.search(l))
                if entry:
                    entry["prompt_tokens"], entry["output_tokens"] = _usage(head, tail, streamed)
                    if entry["output_tokens"] is None and pieces:
                        entry["output_tokens"], entry["output_estimated"] = pieces, True
                    proxy._finish(entry, resp.status)

            do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _go

        return Handler

    def _begin(self, ip, port, path, headers, raw):
        try:
            body = json.loads(raw) if raw else {}
            if not isinstance(body, dict):
                body = {}
        except ValueError:
            body = {}
        agent, icon = recognize(headers, body)
        entry = {"id": secrets.token_hex(4), "started": _now(), "ip": ip, "path": path.split("?")[0], "agent": agent,
                 "icon": icon, "who": None, "app": None, "local": ip in self.local_ips,
                 "model": str(body.get("model") or "")[-60:].split("/")[-1] or None, "stream": bool(body.get("stream")),
                 "messages": len(body.get("messages") or []), "prompt_tokens": None, "output_tokens": None,
                 "est_tokens": round(len(raw) / 3.6) if raw else None,  # until the answer says the real count
                 "ttft": None, "seconds": None, "status": None, "state": "sending"}
        if body.get("model") and "/" in str(body["model"]):
            parts = [p for p in str(body["model"]).split("/") if p]
            entry["model"] = parts[-2] if parts and parts[-1] == "model" and len(parts) > 1 else parts[-1]
        if self.cfg["snippets"]:
            entry["snippet"] = _snippet(body) or None
        with self.lock:
            self.active[entry["id"]] = entry

        def who():  # can take ~0.1 s, so it runs beside the request
            if entry["local"]:
                entry["who"], entry["app"] = _Lookup.process(port)
                entry["who"] = entry["who"] or "this Mac"
            else:
                entry["who"] = _Lookup.device(ip) or ip
        t = threading.Thread(target=who, daemon=True)
        t.start()
        entry["_who"] = t
        return entry

    def _finish(self, entry, status, state="done"):
        t = entry.pop("_who", None)
        if t:
            t.join(3)
        entry.update(status=status, state=state if status < 400 or state != "done" else "error",
                     seconds=round(_now() - entry["started"], 3))
        with self.lock:
            self.active.pop(entry["id"], None)
        self._write(entry)


class _DualStack(ThreadingHTTPServer):
    """All interfaces, IPv4 and IPv6, so other devices on the network can reach it."""
    address_family = socket.AF_INET6
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

    def handle_error(self, request, client_address):
        pass  # clients that hang up mid-answer


def _addresses(local_ips):
    """This Mac's IPv4 addresses, the one other devices most likely reach it on (default route) first."""
    main = None
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # no packet is sent; it just picks the outgoing interface
            main = s.getsockname()[0]
    except OSError:
        pass
    ips = sorted(ip for ip in local_ips if "." in ip and not ip.startswith(("127.", "169.254.")))
    return sorted(ips, key=lambda ip: ip != main)


def _caller(r):
    """'curl in iTerm', 'MacBook-Pro'…"""
    who = r.get("who")
    if r.get("local"):
        app = r.get("app")
        return f"{who} in {app}" if who and app and app.lower() != who.lower() else who or "this Mac"
    return who or r.get("ip")


def _secs(s):
    s = s or 0
    return f"{s:.2f} s" if s < 1 else f"{s:.1f} s" if s < 10 else f"{s:.0f} s" if s < 60 else f"{int(s // 60)}m {int(s % 60):02d}s"


def _count(n):
    return f"{n / 1000:.1f}k" if n >= 1000 else str(int(n))


def _ip_match(ip, rule):
    if "/" not in rule:
        return ip == rule
    import ipaddress
    try:
        return ipaddress.ip_address(ip) in ipaddress.ip_network(rule, strict=False)
    except ValueError:
        return False


def _port_open(port):
    for fam, addr in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            with socket.socket(fam, socket.SOCK_STREAM) as s:
                s.settimeout(0.5)
                if s.connect_ex((addr, port)) == 0:
                    return True
        except OSError:
            pass
    return False


def _wait_port(port, seconds):
    end = _now() + seconds
    while _now() < end:
        if _port_open(port):
            return True
        time.sleep(0.5)
    return _port_open(port)


# ---- moving the LLM server to the upstream port

def _port_re(port):
    return re.compile(r"(--port(?:\s+|=)['\"]?)%d\b" % port)


def find_server_job(port):
    """The user LaunchAgent that starts the server on `port`: its plist, label, and the file that sets the port
    (the plist itself, or the script it runs). None if there isn't exactly one."""
    pat, found = _port_re(port), []
    try:
        names = sorted(os.listdir(LAUNCH_AGENTS))
    except OSError:
        return None
    for name in names:
        if not name.endswith(".plist") or name.startswith("local.gpubuddy"):
            continue
        path = os.path.join(LAUNCH_AGENTS, name)
        try:
            with open(path, "rb") as f:
                job = plistlib.load(f)
        except Exception:
            continue
        args = [str(a) for a in job.get("ProgramArguments") or ([job["Program"]] if job.get("Program") else [])]
        if pat.search(" ".join(args)):
            found.append({"plist": path, "label": job.get("Label"), "file": path, "kind": "plist"})
            continue
        for a in args:
            if os.path.isfile(a) and os.path.getsize(a) < 1_000_000:
                try:
                    with open(a, encoding="utf-8") as f:
                        text = f.read()
                except (OSError, UnicodeDecodeError):
                    continue
                if pat.search(text):
                    found.append({"plist": path, "label": job.get("Label"), "file": a, "kind": "script"})
                    break
    return found[0] if len(found) == 1 and found[0]["label"] else None


def _rewrite_text(text, old, new):
    text = _port_re(old).sub(r"\g<1>%d" % new, text)
    text = re.sub(r"\b(127\.0\.0\.1|localhost|0\.0\.0\.0):%d\b" % old, r"\g<1>:%d" % new, text)
    return re.sub(r"(--host(?:\s+|=)['\"]?)(0\.0\.0\.0|::)(?=['\"\s]|$)", r"\g<1>127.0.0.1", text, flags=re.M)


def _rewrite_args(args, old, new):
    out = []
    for i, a in enumerate(args):
        prev = args[i - 1] if i else ""
        if prev == "--port" and a == str(old):
            a = str(new)
        elif prev == "--host" and a in ("0.0.0.0", "::"):
            a = "127.0.0.1"
        out.append(_rewrite_text(a, old, new) if a.startswith("--") else a)
    return out


def _sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def _restart(job, reload_plist):
    uid = os.getuid()
    if reload_plist:
        subprocess.run(["launchctl", "bootout", f"gui/{uid}/{job['label']}"], capture_output=True, timeout=30)
        subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", job["plist"]], capture_output=True, timeout=30)
    else:
        subprocess.run(["launchctl", "kickstart", "-k", f"gui/{uid}/{job['label']}"], capture_output=True, timeout=30)


def move_server(job, old, new):
    """Point the server's LaunchAgent at port `new` on this Mac only, keeping a backup, and restart it."""
    os.makedirs(BACKUPS, exist_ok=True)
    os.chmod(BACKUPS, 0o700)
    backup = os.path.join(BACKUPS, f"{os.path.basename(job['file'])}.{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(job["file"], backup)
    if job["kind"] == "plist":
        with open(job["file"], "rb") as f:
            d = plistlib.load(f)
        d["ProgramArguments"] = _rewrite_args([str(a) for a in d.get("ProgramArguments", [])], old, new)
        with open(job["file"], "wb") as f:
            plistlib.dump(d, f)
    else:
        with open(job["file"], encoding="utf-8") as f:
            text = f.read()
        with open(job["file"], "w", encoding="utf-8") as f:
            f.write(_rewrite_text(text, old, new))
    _restart(job, job["kind"] == "plist")
    return dict(job, backup=backup, sha=_sha(job["file"]), old_port=old, new_port=new)


def restore_server(moved):
    """Undo move_server and restart the server. Returns a note for the user, or None."""
    note = None
    if os.path.exists(moved["backup"]) and _sha(moved["file"]) == moved["sha"]:
        shutil.copy2(moved["backup"], moved["file"])
    else:  # changed since: only put the port back
        old, new = moved["old_port"], moved["new_port"]
        if moved["kind"] == "plist":
            with open(moved["file"], "rb") as f:
                d = plistlib.load(f)
            args = [str(a) for a in d.get("ProgramArguments", [])]
            d["ProgramArguments"] = [str(old) if i and args[i - 1] == "--port" and a == str(new) else a
                                     for i, a in enumerate(args)]
            with open(moved["file"], "wb") as f:
                plistlib.dump(d, f)
        else:
            with open(moved["file"], encoding="utf-8") as f:
                text = f.read()
            text = _port_re(new).sub(r"\g<1>%d" % old, text)
            text = re.sub(r"\b(127\.0\.0\.1|localhost):%d\b" % new, r"\g<1>:%d" % old, text)
            with open(moved["file"], "w", encoding="utf-8") as f:
                f.write(text)
        note = (f"{moved['file']} had changed since GPU Buddy edited it, so only its port was put back "
                f"(the original is saved at {moved['backup']}).")
    _restart(moved, moved["kind"] == "plist")
    return note
