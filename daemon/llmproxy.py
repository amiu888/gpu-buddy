"""llmproxy: shows who is using your local LLM server, and what for. Part of gpud, off until turned on.

When on, gpud listens on the server's usual port (8080) and passes every request through, unchanged, to the
server, which moves to the next port (8081) and to this Mac only. Clients keep their settings. For each model
request it notes:

  who    - this Mac's program (from the connection's port: claude, node in Visual Studio Code…) or the device's address
  agent  - Claude Code, Cline, curl… recognized from the system prompt and request headers
  what   - optional: the first 100 characters of the last user message ("snippets", off by default)
  sizes  - model, prompt and answer tokens, time to first token, total time

Routing (the LLM Router):
  - GPU Buddy finds the LLM servers on this Mac (Kapitsa, Ollama, LM Studio, llama.cpp, MLX, vLLM…) and the models each
    one has, every 15 seconds.
  - Entry ports: each port GPU Buddy listens on (8080 by default) sends its requests either to one chosen server, or
    to whichever server has the model the request names ("auto"), else to its default server.

Security:
  - This Mac can always use the servers. Other devices need to be on the allow list, or to send a client key
    (Authorization: Bearer <key>, or x-api-key) made for that entry port. With "require_key", the allow list alone
    isn't enough. Keys are stored on this Mac only (readable by you only) and are not passed on to the servers.
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
            "snippets": False, "retention_days": 7, "moved": None,
            "routes": None,          # entry ports, see _default_routes
            "keys": [],              # client keys: {"id", "name", "key", "routes": ["*"] or route ids, "created", "last_used"}
            "require_key": False,    # other devices need a key even when on the allow list
            "server_names": {},      # server id -> the name the user gave it
            "manual_servers": []}    # servers GPU Buddy can't find by itself: {"host", "port", "name"}

# Ports LLM servers often use, checked even when the program's name gives nothing away.
KNOWN_PORTS = (8000, 8001, 8080, 8081, 8082, 8083, 1234, 11434, 11435, 5000, 5001, 1337, 4891, 30000, 52415, 8888, 9000)
# (words in the process or the /v1/models answer, kind, name, icon), first match wins.
KINDS = [
    (("kapitsa", '"nace"'), "kapitsa", "Kapitsa", "⚡"),
    (("ollama", '"library"'), "ollama", "Ollama", "🦙"),
    (("lm studio", "lmstudio", "lms ", "organization_owner"), "lmstudio", "LM Studio", "🧪"),
    (("mlx",), "mlx", "MLX", "🍎"),
    (("llama-server", "llama.cpp", "llamacpp", "llama_cpp"), "llamacpp", "llama.cpp", "🦙"),
    (("vllm",), "vllm", "vLLM", "🚀"),
    (("sglang",), "sglang", "SGLang", "🧵"),
    (("exo",), "exo", "exo", "🕸️"),
    (("kobold",), "kobold", "KoboldCpp", "🐲"),
    (("gpt4all",), "gpt4all", "GPT4All", "🌍"),
    (("jan",), "jan", "Jan", "👋"),
    (("tabby",), "tabby", "Tabby", "🐱"),
]
LLM_WORDS = tuple(w for words, *_ in KINDS for w in words if not w.startswith('"') and w != "organization_owner")
RESERVED_PORTS = {8765}  # gpud's own API; gpud adds its remote port

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
        self._migrate()
        self.listeners = {}  # route id -> {"srv", "port", "network"}
        self.route_state = {}  # route id -> (state, message)
        self.servers = {}  # server id ("127.0.0.1:8081") -> what discovery found
        self.state, self.message = "off", None
        self.active = {}  # id -> request in progress
        self.recent = collections.deque(maxlen=200)
        self.totals = {}  # server port -> {"prompt", "gen", "gen_seen"}: tokens since gpud started, for counters()
        self.local_ips = _Lookup.local_addresses()
        self._busy = threading.Lock()  # one turn on / off at a time
        self._load_recent()
        threading.Thread(target=self._discover_loop, daemon=True).start()
        if self.cfg["enabled"]:
            threading.Thread(target=self._start, daemon=True).start()
        threading.Thread(target=self._housekeeping, daemon=True).start()

    def _migrate(self):
        """Settings from before the router: one entry port, and one shared API key."""
        c = self.cfg
        if not c.get("routes"):
            c["routes"] = [{"id": "main", "name": "Main", "port": c["listen_port"], "target": "auto",
                            "default": f"127.0.0.1:{c['upstream_port']}", "network": True}]
        if c.get("api_key"):
            c["keys"] = list(c.get("keys") or []) + [{"id": secrets.token_hex(4), "name": "Shared key", "key": c["api_key"],
                                                      "routes": ["*"], "created": _now(), "last_used": None}]
            c["require_key"] = True
            c["api_key"] = ""

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
            addrs = _addresses(self.local_ips)
            routes = []
            for r in c["routes"]:
                st, msg = self.route_state.get(r["id"], ("off", None))
                hosts = (addrs if r["network"] else []) + ["127.0.0.1"]
                routes.append(dict(r, state=st, message=msg, urls=[f"http://{h}:{r['port']}/v1" for h in hosts]))
            keys = [{"id": k["id"], "name": k["name"], "routes": k["routes"], "created": k.get("created"),
                     "last_used": k.get("last_used"), "hint": k["key"][:5] + "…" + k["key"][-4:],
                     **({"key": k["key"]} if local else {})} for k in c["keys"]]
            main = c["routes"][0] if c["routes"] else {"port": c["listen_port"]}
            return {"enabled": c["enabled"], "state": self.state, "message": self.message,
                    "listen_port": main["port"], "upstream_port": c["upstream_port"], "allow": c["allow"],
                    "key_required": c["require_key"], "require_key": c["require_key"], "snippets": c["snippets"],
                    "retention_days": c["retention_days"],
                    "moved": c["moved"] and {"file": c["moved"]["file"], "backup": c["moved"]["backup"]},
                    "log_file": LOG, "addresses": addrs, "routes": routes, "keys": keys,
                    "servers": sorted(self.servers.values(), key=lambda s: (not s["up"], s["port"])),
                    "clients": self._clients()}

    def configure(self, change):
        """Apply settings from the app. Turning on or off can take a few seconds (the LLM server restarts)."""
        routes_changed = False
        with self.lock:
            c = self.cfg
            if "snippets" in change:
                c["snippets"] = bool(change["snippets"])
            if "allow" in change:
                allow = [a.strip() for a in change["allow"] if isinstance(a, str) and a.strip()]
                bad = [a for a in allow if not re.fullmatch(r"[0-9a-fA-F:.]+(/\d{1,3})?|\*", a)]
                if bad:
                    raise ValueError(f"not an IP address: {', '.join(bad)}")
                c["allow"] = allow
            if "require_key" in change:
                c["require_key"] = bool(change["require_key"])
            if "retention_days" in change:
                c["retention_days"] = max(1, min(365, int(change["retention_days"])))
            if "routes" in change:
                c["routes"] = self._valid_routes(change["routes"])
                ids = {r["id"] for r in c["routes"]}
                for k in c["keys"]:  # a key for a deleted entry port loses it
                    if k["routes"] != ["*"]:
                        k["routes"] = [r for r in k["routes"] if r in ids]
                routes_changed = True
            if "new_key" in change:
                nk = change["new_key"] or {}
                name = str(nk.get("name") or "").strip()[:40]
                if not name:
                    raise ValueError("give the key a name, like “Cline on MacBook”")
                if any(k["name"].lower() == name.lower() for k in c["keys"]):
                    raise ValueError(f"there's already a key called “{name}”")
                c["keys"].append({"id": secrets.token_hex(4), "name": name, "key": "gb-" + secrets.token_urlsafe(24),
                                  "routes": self._valid_key_routes(nk.get("routes")), "created": _now(), "last_used": None})
            if "key_routes" in change:
                k = self._key(change["key_routes"].get("id"))
                k["routes"] = self._valid_key_routes(change["key_routes"].get("routes"))
            if "rename_key" in change:
                k = self._key(change["rename_key"].get("id"))
                name = str(change["rename_key"].get("name") or "").strip()[:40]
                if name:
                    k["name"] = name
            if "remove_key" in change:
                c["keys"] = [k for k in c["keys"] if k["id"] != change["remove_key"]]
            if "server_name" in change:
                sid, name = str(change["server_name"].get("id")), str(change["server_name"].get("name") or "").strip()[:40]
                if name:
                    c["server_names"][sid] = name
                else:
                    c["server_names"].pop(sid, None)
                if sid in self.servers:
                    self.servers[sid]["name"] = name or self.servers[sid]["kind_name"]
            if "add_server" in change:
                a = change["add_server"]
                port = int(a.get("port") or 0)
                host = str(a.get("host") or "127.0.0.1").strip()
                if not 1 <= port <= 65535 or not re.fullmatch(r"[A-Za-z0-9.:-]{1,253}", host):
                    raise ValueError("give a host and a port, like 127.0.0.1 and 8000")
                c["manual_servers"] = [m for m in c["manual_servers"] if (m["host"], m["port"]) != (host, port)] + \
                    [{"host": host, "port": port, "name": str(a.get("name") or "").strip()[:40]}]
            if "remove_server" in change:
                sid = str(change["remove_server"])
                c["manual_servers"] = [m for m in c["manual_servers"] if f"{m['host']}:{m['port']}" != sid]
                self.servers.pop(sid, None)
            self._save()
        if "add_server" in change:
            threading.Thread(target=self.discover, daemon=True).start()
        if routes_changed and self.state == "on":
            threading.Thread(target=self.apply_routes, daemon=True).start()
        if "enabled" in change and bool(change["enabled"]) != self.cfg["enabled"]:
            if change["enabled"]:  # can take a while (the server restarts and loads), so the app polls status
                with self.lock:
                    self.state, self.message = "starting", None
                threading.Thread(target=self._start, daemon=True).start()
            else:  # waits until the server is back on its port, so uninstalling can rely on it
                self._stop()
        return self.status()

    def _key(self, kid):
        for k in self.cfg["keys"]:
            if k["id"] == kid:
                return k
        raise ValueError("that key doesn't exist any more")

    def _valid_key_routes(self, routes):
        if not routes or routes == ["*"] or routes == "*":
            return ["*"]
        ids = {r["id"] for r in self.cfg["routes"]}
        out = [r for r in routes if r in ids]
        if not out:
            raise ValueError("pick at least one entry port for this key")
        return out

    def _valid_routes(self, routes):
        """Check the entry ports the app sends; raises ValueError with a sentence the app can show."""
        if not isinstance(routes, list) or not routes:
            raise ValueError("keep at least one entry port")
        out, ports = [], set()
        server_ports = {s["port"] for s in self.servers.values() if s["host"] in ("127.0.0.1", "localhost")}
        mine = {r["port"] for r in self.cfg["routes"]}
        for r in routes:
            try:
                port = int(r.get("port"))
            except (TypeError, ValueError):
                raise ValueError("each entry port needs a port number")
            name = str(r.get("name") or "").strip()[:40] or f"Port {port}"
            if not 1024 <= port <= 65535:
                raise ValueError(f"{name}: use a port from 1024 to 65535")
            if port in ports:
                raise ValueError(f"port {port} is used twice")
            if port in RESERVED_PORTS:
                raise ValueError(f"port {port} is GPU Buddy's own")
            if port in server_ports and port not in mine:
                raise ValueError(f"port {port} is an LLM server's own port; pick a free one")
            target = str(r.get("target") or "auto")
            default = r.get("default") or None
            for sid in [target] if target != "auto" else []:
                if not re.fullmatch(r"[A-Za-z0-9.:-]+:\d+", sid):
                    raise ValueError(f"{name}: pick a server to send to")
            ports.add(port)
            rid = str(r.get("id") or "") or secrets.token_hex(3)
            if not re.fullmatch(r"[a-z0-9-]{1,20}", rid):
                rid = secrets.token_hex(3)
            out.append({"id": rid, "name": name, "port": port, "target": target, "default": default,
                        "network": bool(r.get("network", True))})
        return out

    def _route(self, rid):
        for r in self.cfg["routes"]:
            if r["id"] == rid:
                return r
        return None

    # ---- turning on and off

    def _start(self):
        with self._busy:
            c = self.cfg
            with self.lock:
                c["enabled"] = True
                self._save()
                self.state, self.message = "starting", None
            # The first entry port may be where an LLM server already listens (8080): that server moves to 8081.
            port, up = c["routes"][0]["port"], c["upstream_port"]
            if _port_open(port) and not c["moved"] and not self.listeners:
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
            self.apply_routes(wait=120)
            with self.lock:
                if not self.listeners:
                    bad = [m for st, m in self.route_state.values() if m]
                    return self._fail(bad[0] if bad else "No entry port could start.")
                self.state = "on"
                self.message = None if _wait_port(up, 1) or not c["moved"] else f"Waiting for the LLM server on port {up}…"
            threading.Thread(target=self.discover, daemon=True).start()

    def apply_routes(self, wait=0):
        """Start, move or stop entry ports so they match the settings. wait: seconds to wait for a busy port (only
        right after moving the LLM server off it)."""
        with self.lock:
            routes = {r["id"]: r for r in self.cfg["routes"]}
        for rid, l in list(self.listeners.items()):
            r = routes.get(rid)
            if not r or r["port"] != l["port"] or r["network"] != l["network"]:
                l["srv"].shutdown()
                l["srv"].server_close()
                del self.listeners[rid]
                self.route_state.pop(rid, None)
        for rid, r in routes.items():
            if rid in self.listeners:
                continue
            end = _now() + wait
            while True:
                try:
                    srv = (_DualStack(("::", r["port"]), self._handler(rid)) if r["network"]
                           else _LocalOnly(("127.0.0.1", r["port"]), self._handler(rid)))
                    break
                except OSError:
                    if _now() >= end or not self.cfg["enabled"]:
                        srv = None
                        break
                    time.sleep(0.5)
            if srv is None:
                self.route_state[rid] = ("error", f"Port {r['port']} is in use by another program.")
                continue
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            self.listeners[rid] = {"srv": srv, "port": r["port"], "network": r["network"]}
            self.route_state[rid] = ("on", None)
            print(f"gpud: LLM router: {r['name']} on {'*' if r['network'] else '127.0.0.1'}:{r['port']}", flush=True)

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
            for rid, l in list(self.listeners.items()):
                l["srv"].shutdown()
                l["srv"].server_close()
            self.listeners.clear()
            self.route_state.clear()
            msg = None
            if self.cfg["moved"]:
                try:
                    msg = restore_server(self.cfg["moved"])
                except Exception as e:
                    msg = f"Couldn't put the LLM server back on port {self.cfg['moved'].get('old_port')}: {e}"
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

    def now_doing(self, port=None):
        """What an LLM server (the one on `port`, or any) is doing, for the "what's happening" box: a short headline
        and a few facts about the oldest request running, or the one that just finished. None when it's idle."""
        mine = (lambda r: True) if port is None else (lambda r: self._server_port(r) == port)
        with self.lock:
            act = sorted((r for r in self.active.values() if mine(r)), key=lambda r: r["started"])
            done = [r for r in self.recent if mine(r)]
            last = done[-1] if done else None
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

    def _server_port(self, r):
        """The port of the server that handled a log entry (entries from before the router: the moved server's)."""
        return r.get("server_port") or (self.cfg["upstream_port"] if r.get("status") != 403 else None)

    def _clients(self):
        """Who used the router in the last day, newest first: one row per key, or per device and agent."""
        cutoff, rows = _now() - 86400, {}
        with self.lock:
            entries = [r for r in self.recent if (r.get("started") or 0) >= cutoff]
        for r in entries:
            k = ("key", r["client"]) if r.get("client") else ("dev", r.get("ip"), r.get("agent"))
            row = rows.setdefault(k, {"name": r.get("client") or r.get("agent") or "?", "key": bool(r.get("client")),
                                      "who": _caller(r), "ip": r.get("ip"), "local": bool(r.get("local")),
                                      "agent": r.get("agent"), "icon": r.get("icon"), "count": 0})
            row.update(last=r.get("started"), route=r.get("route"), server=r.get("server"),
                       blocked=r.get("state") == "blocked", who=_caller(r) or row["who"])
            row["count"] += 1
        return sorted(rows.values(), key=lambda x: -(x.get("last") or 0))[:16]

    def served_model(self, port):
        """The one model a server like Kapitsa runs (it answers any model name), or None."""
        with self.lock:
            for sv in self.servers.values():
                if sv["port"] == port and sv.get("any_model") and sv.get("models"):
                    return sv["models"][0]
        return None

    def last_finished(self, port, model=None):
        """(tok/s, finished at, model) of the newest finished request on this server that wrote something, or None.
        Speed counts only the writing, after the first token when that's known."""
        with self.lock:
            done = [r for r in self.recent if self._server_port(r) == port and (r.get("status") or 0) < 400
                    and (r.get("output_tokens") or 0) >= 5 and r.get("seconds")
                    and (model is None or r.get("model") == model)]
        for r in reversed(done):
            gen = r["seconds"] - (r.get("ttft") or 0) if r.get("ttft") and r["seconds"] - r["ttft"] > 0.2 else r["seconds"]
            if gen > 0.05:
                return round(r["output_tokens"] / gen, 1), r["started"] + r["seconds"], r.get("model") or ""
        return None

    def summary(self, recent=8):
        """For the app's live view: requests running now (with the tokens written so far) and the last few."""
        with self.lock:
            return {"on": self.state == "on",
                    "active": [dict({k: v for k, v in r.items() if not k.startswith("_")}, live_tokens=r.get("_pieces"))
                               for r in self.active.values()],
                    "recent": list(self.recent)[-recent:][::-1]}

    # ---- finding the LLM servers on this Mac

    def _discover_loop(self):
        while True:
            try:
                self.discover()
            except Exception as e:
                print(f"gpud: LLM router: looking for servers failed: {e}", flush=True)
            time.sleep(15)

    def discover(self):
        """Find the LLM servers on this Mac: programs that look like one, ports they often use, and servers the user
        added. A server counts when it answers /v1/models. Servers that stop answering stay listed (as down) while
        an entry port points at them, or for a day."""
        listening = _listeners()
        own = {l["port"] for l in self.listeners.values()} | RESERVED_PORTS
        cands = {}
        for port, (pid, args, addrs) in listening.items():
            if port in own or pid == os.getpid() or "gpud.py" in args:  # GPU Buddy itself
                continue
            if "/.ollama/models/blobs/" in args or "Ollama.app/Contents/Resources/" in args and "llama-server" in args:
                continue  # Ollama's own helper for a loaded model (random port): reached through Ollama, not directly
                continue
            low = args.lower()
            if port in KNOWN_PORTS or any(w in low for w in LLM_WORDS):
                cands[f"127.0.0.1:{port}"] = ("127.0.0.1", port, pid, args, addrs)
        for m in self.cfg["manual_servers"]:
            sid = f"{m['host']}:{m['port']}"
            pid, args, addrs = listening.get(m["port"], (None, "", [])) if m["host"] in ("127.0.0.1", "localhost") \
                else (None, "", [])
            cands[sid] = (m["host"], m["port"], pid, args, addrs)
        found = {}
        threads = [threading.Thread(target=lambda sid=sid, c=c: found.__setitem__(sid, _probe_server(*c)), daemon=True)
                   for sid, c in cands.items()]
        for t in threads:
            t.start()
        for t in threads:
            t.join(25)
        now = _now()
        manual = {f"{m['host']}:{m['port']}": m for m in self.cfg["manual_servers"]}
        targets = {r["target"] for r in self.cfg["routes"]} | {r.get("default") for r in self.cfg["routes"]}
        with self.lock:
            for sid, rec in found.items():
                if not rec:
                    continue
                rec["id"] = sid
                rec["manual"] = sid in manual
                rec["name"] = self.cfg["server_names"].get(sid) or (manual.get(sid) or {}).get("name") or rec["kind_name"]
                rec["seen"] = now
                self.servers[sid] = rec
            for sid, s in list(self.servers.items()):
                if not found.get(sid):
                    s["up"] = False
                    if sid not in targets and sid not in manual and now - s.get("seen", 0) > 86400:
                        del self.servers[sid]
            for sid in targets | set(manual):  # what entry ports point at, even if it never answered
                if sid and sid != "auto" and sid not in self.servers and re.fullmatch(r".+:\d+", sid):
                    host, port = sid.rsplit(":", 1)
                    self.servers[sid] = {"id": sid, "host": host, "port": int(port), "kind": "unknown",
                                         "kind_name": "LLM server", "icon": "❔", "process": None, "pid": None,
                                         "models": [], "any_model": False, "up": False, "network": False,
                                         "manual": sid in manual, "seen": 0,
                                         "name": self.cfg["server_names"].get(sid) or (manual.get(sid) or {}).get("name")
                                         or f"Port {port}"}

    # ---- the proxy

    def _client_key(self, headers, route):
        """The client key this request carries for this entry port, or None. Keys for other ports don't count."""
        sent = headers.get("Authorization", "")
        sent = sent[7:].strip() if sent.startswith("Bearer ") else headers.get("x-api-key", "").strip()
        if not sent.startswith("gb-"):
            return None
        for k in self.cfg["keys"]:
            if hmac.compare_digest(sent.encode(), k["key"].encode()):
                return k if k["routes"] == ["*"] or route["id"] in k["routes"] else None
        return None

    def _allowed(self, ip, headers, route):
        """(why not, or None; the client key's name, or None) for a caller on an entry port."""
        key = self._client_key(headers, route)
        if key:
            key["last_used"] = _now()
            return None, key["name"]
        if ip in self.local_ips:
            return None, None
        if not route["network"]:
            return "this entry port is for this Mac only", None
        allow = self.cfg["allow"]
        listed = "*" in allow or any(_ip_match(ip, a) for a in allow)
        if listed and not self.cfg["require_key"]:
            return None, None
        if listed:
            return "this LLM router needs a client key from GPU Buddy (put it in your app's API Key field)", None
        return (f"{ip} isn't on GPU Buddy's allow list for this LLM server, and sent no client key for this entry "
                f"port"), None

    def _pick(self, route, model):
        """(server, how) for a request on an entry port: its chosen server, or the one that has the model."""
        with self.lock:
            servers = dict(self.servers)
        if route["target"] != "auto":
            return servers.get(route["target"]), "fixed"
        up = [s for s in servers.values() if s["up"]]
        if model:
            want = str(model)
            short = _short_model(want)
            for test in (lambda s: want in s["models"],
                         lambda s: any(_short_model(m) == short for m in s["models"]),
                         lambda s: ":" not in want and any(m == want + ":latest" for m in s["models"])):
                hit = [s for s in up if test(s)]
                if hit:
                    return sorted(hit, key=lambda s: s["any_model"])[0], "model"
        default = servers.get(route.get("default") or "")
        if default and default["up"]:
            return default, "default"
        for s in sorted(up, key=lambda s: (not s["any_model"], s["port"])):
            return s, "default"
        return default, "default"

    def models_list(self, route):
        """/v1/models for an "auto" entry port: every model of every running server, so apps can pick from all."""
        with self.lock:
            servers = [s for s in self.servers.values() if s["up"]]
        if route["target"] != "auto":
            servers = [s for s in servers if s["id"] == route["target"]]
        data, seen = [], set()
        for s in sorted(servers, key=lambda s: s["port"]):
            for m in s["models"]:
                if m not in seen:
                    seen.add(m)
                    data.append({"id": m, "object": "model", "created": 0, "owned_by": s["name"]})
        return {"object": "list", "data": data}

    def _lists_models(self, route):
        """GPU Buddy answers /v1/models itself (always a list, never null) unless the port's server is unknown or down."""
        if route["target"] == "auto":
            return True
        with self.lock:
            s = self.servers.get(route["target"])
            return bool(s and s["up"])

    def _handler(self, route_id):
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
                route = proxy._route(route_id)
                if route is None:
                    return self._error(503, "this entry port was removed in GPU Buddy")
                entry = None
                if logged:
                    entry = proxy._begin(ip, port, self.path, self.headers, body)
                    entry["route"] = route["name"]
                why, client = proxy._allowed(ip, self.headers, route)
                if why:
                    if entry:
                        proxy._finish(entry, 403, state="blocked")
                    elif self.command != "OPTIONS":
                        proxy._write({"id": secrets.token_hex(4), "started": _now(), "ip": ip, "path": self.path,
                                      "agent": "Unknown device", "icon": "⛔", "who": _Lookup.device(ip) or ip, "state": "blocked",
                                      "status": 403, "route": route["name"]})
                    return self._error(403, why)
                if entry and client:
                    entry["client"] = client
                path = self.path.split("?")[0].rstrip("/")
                if self.command == "GET" and path in ("/v1/models", "/models") and proxy._lists_models(route):
                    data = json.dumps(proxy.models_list(route)).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    return self.wfile.write(data)
                model = None
                if body[:1] == b"{":
                    try:
                        model = json.loads(body).get("model")
                    except (ValueError, AttributeError):
                        pass
                server, how = proxy._pick(route, model)
                if server is None or not server["up"]:
                    name = server["name"] if server else "an LLM server"
                    if entry:
                        proxy._finish(entry, 503, state="error")
                    return self._error(503, f"{name} isn't running, so GPU Buddy has nowhere to send this "
                                            f"(entry port “{route['name']}”). Start it, or change the routing in "
                                            f"GPU Buddy's LLM Router.")
                if entry:
                    entry.update(server=server["name"], server_port=server["port"], routed_by=how)
                try:
                    self._forward(body, entry, server, client)
                except (BrokenPipeError, ConnectionResetError):
                    if entry:
                        proxy._finish(entry, 499, state="cancelled")
                except Exception as e:
                    if entry:
                        proxy._finish(entry, 502, state="error")
                    try:
                        self._error(502, f"GPU Buddy couldn't reach {server['name']} on port {server['port']}: {e}")
                    except Exception:
                        pass

            def _forward(self, body, entry, server, client):
                up = http.client.HTTPConnection(server["host"], server["port"], timeout=900)
                headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
                if client:  # GPU Buddy's own key: the server doesn't need to see it
                    headers = {k: v for k, v in headers.items() if k.lower() not in ("authorization", "x-api-key")}
                headers["Host"] = f"{server['host']}:{server['port']}"
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
                            entry["_pieces"] = pieces
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
        entry.pop("_pieces", None)
        with self.lock:
            self.active.pop(entry["id"], None)
            if status < 400 and entry.get("server_port"):
                t = self.totals.setdefault(entry["server_port"], {"prompt": 0, "gen": 0, "gen_seen": 0})
                t["prompt"] += entry.get("prompt_tokens") or 0
                t["gen"] += entry.get("output_tokens") or 0
        self._write(entry)

    def serves(self, port):
        """Whether the router passes requests to an LLM server on this port (so counters(port) means something)."""
        return self.state == "on" and any(s["port"] == port and s["host"] in ("127.0.0.1", "localhost")
                                          for s in self.servers.values())

    def counters(self, port=None):
        """Token counters for an LLM server the router sends to, for servers that publish none of their own
        (Kapitsa, Ollama): (prompt total, generated total, in flight, tok/s now, model, time to first token) as
        TokenWatcher reads them. Generated tokens count up live from the streamed pieces, and never go down."""
        now = _now()
        port = port or self.cfg["upstream_port"]
        with self.lock:
            act = [r for r in self.active.values() if r.get("server_port") == port]
            done = [r for r in self.recent if r.get("status") and r["status"] < 400 and self._server_port(r) == port]
            t = self.totals.setdefault(port, {"prompt": 0, "gen": 0, "gen_seen": 0})
            gen = t["gen"] + sum(r.get("_pieces") or 0 for r in act)
            gen = t["gen_seen"] = max(gen, t["gen_seen"])
            prompt = t["prompt"]
        speeds = [r["_pieces"] / (now - r["started"] - r["ttft"]) for r in act
                  if r.get("_pieces") and r.get("ttft") and now - r["started"] - r["ttft"] > 0.2]
        timed = [r for r in done if r.get("ttft")]
        model = (act[-1] if act else done[-1] if done else {}).get("model") or ""
        ttft = None
        if timed:
            last = timed[-1]
            same = [r["ttft"] for r in timed[-20:] if r.get("model") == last.get("model")]
            ttft = {"last": last["ttft"], "avg": sum(same) / len(same), "at": last["started"] + last["ttft"],
                    "model": last.get("model") or "", "prompt": last.get("prompt_tokens"), "cache": None,
                    "n": len(same)}
            waiting = [r["started"] for r in act if r.get("state") in ("sending", "waiting")]
            if waiting:
                ttft["pending_since"] = min(waiting)
        return prompt, gen, len(act), sum(speeds), model, ttft


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


class _LocalOnly(ThreadingHTTPServer):
    """An entry port for this Mac only."""
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        pass


def _short_model(m):
    """'/Users/me/.local/share/qwen36-moe-mlx/model' -> 'qwen36-moe-mlx'; 'mlx-community/Qwen3-8B' -> 'qwen3-8b'."""
    parts = [p for p in str(m).split("/") if p]
    if not parts:
        return ""
    return (parts[-2] if parts[-1] == "model" and len(parts) > 1 else parts[-1]).lower()


def _listeners():
    """port -> (pid, the program's command line, addresses it listens on) for this user's listening TCP ports."""
    try:
        raw = subprocess.run(["lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"], capture_output=True, timeout=8).stdout.decode()
    except Exception:
        return {}
    ports, pid = {}, None
    for line in raw.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and pid:
            addr, _, port = line[1:].rpartition(":")
            if port.isdigit():
                p = ports.setdefault(int(port), [pid, set()])
                p[1].add(addr.strip("[]"))
    args = {}
    pids = {p for p, _ in ports.values()}
    if pids:
        try:
            out = subprocess.run(["ps", "-o", "pid=,args=", "-p", ",".join(map(str, pids))], capture_output=True,
                                 timeout=5).stdout.decode()
            for line in out.splitlines():
                pid_s, _, a = line.strip().partition(" ")
                if pid_s.isdigit():
                    args[int(pid_s)] = a.strip()
        except Exception:
            pass
    return {port: (pid, args.get(pid, ""), sorted(addrs)) for port, (pid, addrs) in ports.items()}


def _probe_server(host, port, pid, args, addrs):
    """What answers /v1/models on host:port, or None if it isn't an LLM server."""
    try:
        conn = http.client.HTTPConnection(host, port, timeout=20)  # an Ollama on the NAS can take a while to list
        conn.request("GET", "/v1/models", headers={"Authorization": "Bearer gpu-buddy"})
        resp = conn.getresponse()
        raw = resp.read(4 << 20)
        conn.close()
        d = json.loads(raw) if resp.status == 200 else None
    except Exception:
        return None
    if not isinstance(d, dict) or not (isinstance(d.get("data"), list) or d.get("object") == "list"):
        return None
    rows = [m for m in d.get("data") or [] if isinstance(m, dict) and m.get("id")]  # Ollama with no models: null
    active = [m["id"] for m in rows if m.get("active")]  # Kapitsa also lists catalog models it could download
    models = active or [m["id"] for m in rows]
    hay = (args + " " + raw[:4000].decode(errors="replace")).lower()
    kind, kind_name, icon = "openai", "LLM server", "🧠"
    for words, k, name, ic in KINDS:
        if any(w in hay for w in words):
            kind, kind_name, icon = k, name, ic
            break
    if kind == "ollama" and port != 11434:
        kind_name = f"Ollama :{port}"
    prog = os.path.basename(args.split()[0]) if args else None
    return {"host": host, "port": port, "kind": kind, "kind_name": kind_name, "icon": icon, "process": prog,
            "pid": pid, "models": models[:300], "any_model": kind == "kapitsa", "up": True,
            "network": any(a in ("*", "0.0.0.0", "::") for a in addrs)}


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
