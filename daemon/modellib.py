"""Model library for the LLM Router: which models are on this Mac, which are on the NAS, which ollama.com offers,
and downloads into Ollama (from ollama.com, or copied from the NAS's Ollama store).

  GET  /api/v1/llm-proxy/models               -> everything below, plus running downloads
  POST /api/v1/llm-proxy/models {"pull": "qwen3:8b", "from": "ollama"|"nas"}   start a download
  POST /api/v1/llm-proxy/models {"cancel": "qwen3:8b"}                         stop one

Python 3.9 stdlib only, like gpud.
"""

import html
import json
import os
import re
import shutil
import threading
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434"
OLLAMA_STORE = os.environ.get("OLLAMA_MODELS") or os.path.expanduser("~/.ollama/models")
# Ollama model stores on a NAS (folders holding manifests/ and blobs/). GPUBUDDY_NAS_MODELS="/Volumes/x/ollama:/other"
NAS_STORES = [os.path.expanduser(p) for p in os.environ.get("GPUBUDDY_NAS_MODELS", "").split(":") if p] or \
    [os.path.expanduser("~/nas-share/LLM/ollama-models"), "/Volumes/share/LLM/ollama-models"]
KAPITSA_STORE = os.path.expanduser("~/.cache/kapitsa/models")
STATE_DIR = os.path.expanduser("~/Library/Application Support/GPUBuddy")
LIBRARY_CACHE = os.path.join(STATE_DIR, "ollama-library.json")
LIBRARY_MAX_AGE = 12 * 3600
KEEP_FREE = 20 * 1024 ** 3  # never fill the disk past this
REGISTRY = "registry.ollama.ai"
NAME_OK = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,120}(:[A-Za-z0-9._-]{1,80})?$")


def _get_json(url, timeout=10, method="GET", body=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Content-Type": "application/json", "User-Agent": "GPU-Buddy"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"null")


def full_name(name):
    """qwen3 -> qwen3:latest, so names compare the way Ollama lists them."""
    return name if ":" in name.rsplit("/", 1)[-1] else name + ":latest"


def is_cloud(name, row=None):
    """Ollama cloud models run on ollama.com, not on this Mac."""
    tag = name.rsplit(":", 1)[-1] if ":" in name else ""
    return bool((row or {}).get("remote_host")) or tag == "cloud" or tag.endswith("-cloud")


def _dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


class ModelLibrary:
    def __init__(self):
        self.lock = threading.Lock()
        self.jobs = {}  # name -> {state, source, done, total, error, started, stop}
        self.library = None
        self.library_time = 0
        self.library_error = None
        self._library_loading = False
        self._kapitsa_sizes = {}
        self.nas_error = None
        try:
            with open(LIBRARY_CACHE) as f:
                d = json.load(f)
            self.library, self.library_time = d["models"], d["time"]
        except (OSError, ValueError, KeyError):
            pass

    # ---- what's where -------------------------------------------------------------------------------------------

    def ollama_models(self):
        """Ollama's own list (None if Ollama isn't running), with what's loaded in memory right now."""
        try:
            rows = _get_json(OLLAMA + "/api/tags", timeout=5).get("models") or []
        except Exception:
            return None
        try:
            loaded = {m.get("name") for m in _get_json(OLLAMA + "/api/ps", timeout=3).get("models") or []}
        except Exception:
            loaded = set()
        out = []
        for m in rows:
            name = m.get("name") or m.get("model")
            d = m.get("details") or {}
            out.append({"name": name, "server": "Ollama", "size": m.get("size") or 0, "cloud": is_cloud(name, m),
                        "params": d.get("parameter_size") or "", "quant": d.get("quantization_level") or "",
                        "loaded": name in loaded, "modified": m.get("modified_at")})
        return sorted(out, key=lambda r: r["name"])

    def kapitsa_models(self):
        """Kapitsa's downloaded models (it serves one at a time)."""
        out = []
        try:
            names = sorted(os.listdir(KAPITSA_STORE))
        except OSError:
            return out
        for n in names:
            p = os.path.join(KAPITSA_STORE, n)
            if not os.path.isdir(p) or n.startswith("."):
                continue
            if n not in self._kapitsa_sizes:
                self._kapitsa_sizes[n] = _dir_size(p)
            out.append({"name": n, "server": "Kapitsa", "size": self._kapitsa_sizes[n], "cloud": False,
                        "params": "", "quant": "", "loaded": False})
        return out

    @staticmethod
    def nas_store():
        for d in NAS_STORES:
            if os.path.isdir(os.path.join(d, "manifests")):
                return d
        return None

    def nas_models(self, store):
        """Models in the NAS's Ollama store, with their size from the manifest."""
        out, errors = [], []
        base = os.path.join(store, "manifests")
        for root, _, files in os.walk(base, onerror=errors.append):
            for tag in files:
                if tag.startswith("."):
                    continue
                path = os.path.join(root, tag)
                parts = os.path.relpath(path, base).split(os.sep)
                if len(parts) < 4:
                    continue
                ns, model = parts[-3], parts[-2]
                name = (f"{model}:{tag}" if ns == "library" else f"{ns}/{model}:{tag}")
                try:
                    with open(path) as f:
                        man = json.load(f)
                    size = sum(l.get("size") or 0 for l in man.get("layers") or []) + ((man.get("config") or {}).get("size") or 0)
                except (OSError, ValueError, TypeError, AttributeError):
                    size = 0
                out.append({"name": name, "size": size, "cloud": is_cloud(name) or size < 10 * 1024 ** 2,
                            "manifest": path})
        if errors and not out:
            self.nas_error = ("GPU Buddy's background service isn't allowed to read the NAS. In System Settings → "
                              "Privacy & Security → Files & Folders, turn on Network Volumes for python3."
                              if any(getattr(e, "errno", 0) in (1, 13) for e in errors) else f"Couldn't read the NAS: {errors[0]}")
        else:
            self.nas_error = None
        return sorted(out, key=lambda r: r["name"])

    # ---- ollama.com ---------------------------------------------------------------------------------------------

    def _fetch_library(self):
        try:
            req = urllib.request.Request("https://ollama.com/library", headers={"User-Agent": "GPU-Buddy"})
            with urllib.request.urlopen(req, timeout=30) as r:
                page = r.read().decode("utf-8", "replace")
            models = []
            for block in re.split(r'<a href="/library/', page)[1:]:
                name = block.split('"', 1)[0]
                if not re.match(r"^[a-z0-9][a-z0-9._-]*$", name):
                    continue
                desc = re.search(r"<p\s+class=\"max-w-lg[^>]*>(.*?)</p>", block, re.S)
                chips = [html.unescape(c).strip() for c in re.findall(r"<span\s+class=\"inline-flex items-center rounded-md[^>]*>([^<]*)</span>", block)]
                pulls = re.search(r"<span[^>]*>([\d.,]+[KMB]?)</span>\s*<span\s+class=\"hidden sm:flex\">&nbsp;Pull", block)
                sizes = [c for c in chips if re.match(r"^[\d.]+[xX]?[\d.]*[mMbBkK]$|^e\d+b$", c)]
                caps = [c for c in chips if c not in sizes]
                models.append({"name": name, "desc": html.unescape(re.sub(r"\s+", " ", desc.group(1))).strip() if desc else "",
                               "sizes": sizes, "caps": caps, "pulls": pulls.group(1) if pulls else ""})
            if not models:
                raise ValueError("ollama.com's page looked different than expected")
            with self.lock:
                self.library, self.library_time, self.library_error = models, time.time(), None
            try:
                tmp = LIBRARY_CACHE + ".tmp"
                with open(tmp, "w") as f:
                    json.dump({"time": self.library_time, "models": models}, f)
                os.replace(tmp, LIBRARY_CACHE)
            except OSError:
                pass
        except Exception as e:
            with self.lock:
                self.library_error = f"Couldn't read ollama.com: {e}"
        finally:
            self._library_loading = False

    def library_list(self, refresh=False):
        if (refresh or not self.library or time.time() - self.library_time > LIBRARY_MAX_AGE) and not self._library_loading:
            self._library_loading = True
            threading.Thread(target=self._fetch_library, daemon=True).start()
        return self.library or []

    # ---- everything, for the app --------------------------------------------------------------------------------

    def status(self, refresh=False):
        ollama = self.ollama_models()
        store = self.nas_store()
        nas = self.nas_models(store) if store else []
        on_mac = {r["name"] for r in ollama or []}
        for r in nas:
            r["on_mac"] = r["name"] in on_mac
            r.pop("manifest", None)
        try:
            free = shutil.disk_usage(OLLAMA_STORE if os.path.isdir(OLLAMA_STORE) else os.path.expanduser("~")).free
        except OSError:
            free = 0
        with self.lock:
            jobs = {n: {k: v for k, v in j.items() if k != "stop"} for n, j in self.jobs.items()}
        return {"ollama_running": ollama is not None, "installed": (ollama or []) + self.kapitsa_models(),
                "nas": nas, "nas_path": store, "nas_error": self.nas_error, "nas_looked": NAS_STORES, "library": self.library_list(refresh),
                "library_time": self.library_time or None, "library_loading": self._library_loading,
                "library_error": self.library_error, "jobs": jobs, "free": free, "keep_free": KEEP_FREE}

    def change(self, c):
        if "pull" in c:
            name = str(c["pull"]).strip()
            if not NAME_OK.match(name):
                raise ValueError("that isn't a model name")
            src = c.get("from", "ollama")
            if src not in ("ollama", "nas"):
                raise ValueError("from must be ollama or nas")
            return self.pull(full_name(name) if src == "nas" else name, src)
        if "cancel" in c:
            with self.lock:
                j = self.jobs.get(str(c["cancel"]))
                if j and j["state"] == "running":
                    j["stop"].set()
            return {"ok": True}
        if "clear" in c:
            with self.lock:
                self.jobs = {n: j for n, j in self.jobs.items() if j["state"] == "running"}
            return {"ok": True}
        raise ValueError("nothing to do")

    # ---- downloads ----------------------------------------------------------------------------------------------

    def pull(self, name, src):
        with self.lock:
            if self.jobs.get(name, {}).get("state") == "running":
                return {"ok": True, "already": True}
            job = {"state": "running", "source": src, "done": 0, "total": 0, "error": None,
                   "started": time.time(), "stop": threading.Event(), "step": "Starting…"}
            self.jobs[name] = job
        target = self._pull_ollama if src == "ollama" else self._copy_nas
        threading.Thread(target=self._run, args=(target, name, job), daemon=True).start()
        return {"ok": True}

    def _run(self, fn, name, job):
        try:
            fn(name, job)
            if job["stop"].is_set():
                job.update(state="cancelled", step="Stopped")
            else:
                job.update(state="done", step="Ready to use", done=job["total"] or job["done"])
        except Exception as e:
            job.update(state="error", error=str(e) or e.__class__.__name__, step="Failed")
        job["ended"] = time.time()

    def _pull_ollama(self, name, job):
        """Ollama downloads it from ollama.com; its progress comes as one JSON line per update."""
        if self.ollama_models() is None:
            raise RuntimeError("Ollama isn't running. Start it (open the Ollama app, or run: ollama serve).")
        req = urllib.request.Request(OLLAMA + "/api/pull", method="POST",
                                     data=json.dumps({"model": name, "stream": True}).encode(),
                                     headers={"Content-Type": "application/json"})
        parts = {}
        with urllib.request.urlopen(req, timeout=60) as r:
            for line in r:
                if job["stop"].is_set():
                    return  # closing the connection stops Ollama's download
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                if d.get("error"):
                    raise RuntimeError(d["error"])
                if d.get("digest") and d.get("total"):
                    parts[d["digest"]] = (d.get("completed") or 0, d["total"])
                    job["done"] = sum(p[0] for p in parts.values())
                    job["total"] = sum(p[1] for p in parts.values())
                job["step"] = {"pulling manifest": "Asking ollama.com…", "verifying sha256 digest": "Checking the files…",
                               "writing manifest": "Finishing…"}.get(d.get("status"), "Downloading…" if d.get("digest") else d.get("status", "…"))
                if d.get("status") == "success":
                    return

    def _copy_nas(self, name, job):
        """Copy the model's files from the NAS's Ollama store into this Mac's, blobs first and the manifest last,
        so Ollama never sees half a model."""
        store = self.nas_store()
        if not store:
            raise RuntimeError("The NAS isn't mounted (looked in " + ", ".join(NAS_STORES) + ").")
        model, tag = name.rsplit(":", 1)
        ns, model = model.split("/", 1) if "/" in model else ("library", model)
        man_path = os.path.join(store, "manifests", REGISTRY, ns, model, tag)
        if not os.path.isfile(man_path):
            raise RuntimeError(f"{name} isn't on the NAS.")
        with open(man_path) as f:
            man = json.load(f)
        layers = (man.get("layers") or []) + ([man["config"]] if man.get("config") else [])
        if sum(l.get("size") or 0 for l in layers) < 10 * 1024 ** 2:
            raise RuntimeError(f"{name} is a cloud model: it runs on ollama.com, so there's nothing to copy.")
        need = []
        for l in layers:
            blob = l["digest"].replace(":", "-")
            dst = os.path.join(OLLAMA_STORE, "blobs", blob)
            if not (os.path.isfile(dst) and os.path.getsize(dst) == l.get("size")):
                need.append((os.path.join(store, "blobs", blob), dst, l.get("size", 0)))
        job["total"] = sum(n[2] for n in need)
        free = shutil.disk_usage(OLLAMA_STORE).free
        if free - job["total"] < KEEP_FREE:
            raise RuntimeError(f"Not enough space: needs {job['total'] / 1e9:.1f} GB and keeps 20 GB free "
                               f"({free / 1e9:.0f} GB free now).")
        os.makedirs(os.path.join(OLLAMA_STORE, "blobs"), exist_ok=True)
        job["step"] = "Copying from the NAS…"
        for src, dst, _ in need:
            tmp = dst + ".gpubuddy-partial"
            try:
                with open(src, "rb") as fi, open(tmp, "wb") as fo:
                    while True:
                        if job["stop"].is_set():
                            raise InterruptedError
                        chunk = fi.read(16 * 1024 * 1024)
                        if not chunk:
                            break
                        fo.write(chunk)
                        job["done"] += len(chunk)
                os.replace(tmp, dst)
            except InterruptedError:
                os.unlink(tmp)
                return
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        job["step"] = "Finishing…"
        dst_man = os.path.join(OLLAMA_STORE, "manifests", REGISTRY, ns, model, tag)
        os.makedirs(os.path.dirname(dst_man), exist_ok=True)
        shutil.copyfile(man_path, dst_man + ".tmp")
        os.replace(dst_man + ".tmp", dst_man)


# ---- which models clients use, and how fast ---------------------------------------------------------------------

def speed(e, now=None):
    """Output tokens per second while writing (after the first token when we know it), or None."""
    out = e.get("output_tokens") or 0
    secs = (e.get("seconds") if now is None else now - e.get("started", now)) or 0
    gen = secs - (e.get("ttft") or 0) if e.get("ttft") and secs - e["ttft"] > 0.2 else secs
    return round(out / gen, 1) if out >= 5 and gen > 0.05 else None


def client_name(e):
    if e.get("client"):
        return e["client"]
    who = e.get("app") or e.get("who") or e.get("ip") or "?"
    agent = e.get("agent") or ""
    return f"{agent} · {who}" if agent and agent not in ("Unknown device", who) else who


def usage(entries, active, hours=24):
    """Per server and model name: requests (last `hours`), clients, last use, tokens/s (last request and median of
    the last 20), and requests running right now."""
    now = time.time()
    rows = {}

    def row(e):
        k = (e.get("server") or "?", e.get("model") or "(no model name)")
        return rows.setdefault(k, {"server": k[0], "model": k[1], "server_port": e.get("server_port"), "requests": 0,
                                   "errors": 0, "clients": {}, "last": 0, "speeds": [], "out_tokens": 0, "now": 0,
                                   "now_tps": None})

    for e in entries:  # newest first
        if e.get("state") == "blocked" or not e.get("server"):
            continue
        r = row(e)
        r["last"] = max(r["last"], e.get("started") or 0)
        if now - (e.get("started") or 0) <= hours * 3600:
            r["requests"] += 1
            if (e.get("status") or 0) >= 400 or e.get("state") == "error":
                r["errors"] += 1
            r["out_tokens"] += e.get("output_tokens") or 0
            c = client_name(e)
            r["clients"][c] = r["clients"].get(c, 0) + 1
        s = speed(e)
        if s and len(r["speeds"]) < 20:
            r["speeds"].append(s)
    for e in active:
        if not e.get("server"):
            continue
        r = row(e)
        r["now"] += 1
        r["last"] = now
        c = client_name(e)
        r["clients"].setdefault(c, 0)
        r["now_tps"] = speed(e, now) or r["now_tps"]
    out = []
    for r in rows.values():
        sp = sorted(r["speeds"])
        r["tps_last"] = r["speeds"][0] if r["speeds"] else None
        r["tps"] = sp[len(sp) // 2] if sp else None
        r["clients"] = [{"name": n, "requests": c} for n, c in sorted(r["clients"].items(), key=lambda x: -x[1])]
        del r["speeds"]
        out.append(r)
    return sorted(out, key=lambda r: (-r["now"], -r["last"]))
