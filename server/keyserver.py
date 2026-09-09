#!/usr/bin/env python3
"""luahellper key server + web dashboard — reference implementation (stdlib only).

Gates delivery of an obfuscated Luau script behind a per-user key bound to a
HWID (the Luarmor model), and provides a password-protected browser dashboard
to obfuscate scripts and manage keys.

Storage: JSON file (server/keys.json).  Scripts: server/scripts/<name>.lua.

Subcommands:
  serve                     run the HTTP server (API + dashboard)
  addkey [--script NAME] [--days N] [--key K]
  listkeys | revoke KEY | rebind KEY
  setpass PASSWORD          set the dashboard admin password

Public API (for the loader):
  GET  /v1/health
  POST /v1/auth   {"key","hwid"} -> {"ok":true,"script":...} | {"ok":false,"reason":...}

Dashboard (browser):
  GET  /                    login page
  GET  /dashboard           obfuscate + key management (requires login)
  POST /admin/login   {"password"}                 -> sets session cookie
  POST /admin/logout
  POST /admin/obfuscate {"name","source","flags"}  -> runs luahellper, saves script
  GET  /admin/keys
  POST /admin/keys    {"script","days"}            -> create key
  POST /admin/revoke  {"key"}
  POST /admin/rebind  {"key"}
"""
import argparse, json, os, secrets, time, hmac, hashlib, sys, subprocess, shutil, tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.cookies import SimpleCookie

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CLI = os.path.join(ROOT, "luahellper.lua")
KEYS_PATH = os.path.join(HERE, "keys.json")
SCRIPTS_DIR = os.path.join(HERE, "scripts")
PASTES_DIR = os.path.join(HERE, "pastes")
SECRET_PATH = os.path.join(HERE, "secret")
ADMIN_PATH = os.path.join(HERE, "admin_pass")

SESSIONS = {}  # token -> expiry epoch
LUA_BIN = shutil.which("lua") or shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("luajit") or shutil.which("luau")


# ---- storage ----------------------------------------------------------
def load_store():
    if not os.path.exists(KEYS_PATH):
        return {"keys": {}}
    with open(KEYS_PATH) as f:
        return json.load(f)


def save_store(store):
    tmp = KEYS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(store, f, indent=2)
    os.replace(tmp, KEYS_PATH)


def get_secret():
    env = os.environ.get("LUAHELLPER_SECRET")
    if env:
        return env.encode()
    if os.path.exists(SECRET_PATH):
        return open(SECRET_PATH, "rb").read().strip()
    s = secrets.token_hex(32)
    open(SECRET_PATH, "w").write(s)
    print(f"[keyserver] generated new secret at {SECRET_PATH}", file=sys.stderr)
    return s.encode()


def sign(body: bytes) -> str:
    return hmac.new(get_secret(), body, hashlib.sha256).hexdigest()


def get_admin_hash():
    env = os.environ.get("LUAHELLPER_ADMIN")
    if env:
        return hashlib.sha256(env.encode()).hexdigest()
    if os.path.exists(ADMIN_PATH):
        return open(ADMIN_PATH).read().strip()
    # generate a random one and print it once
    pw = secrets.token_hex(6)
    open(ADMIN_PATH, "w").write(hashlib.sha256(pw.encode()).hexdigest())
    print(f"[keyserver] generated dashboard password: {pw}  (change with: keyserver.py setpass <pw>)", file=sys.stderr)
    return hashlib.sha256(pw.encode()).hexdigest()


def read_script(name):
    path = os.path.join(SCRIPTS_DIR, f"{name}.lua")
    if not os.path.exists(path):
        return None
    return open(path).read()


# ---- auth logic (loader) ---------------------------------------------
def authorize(key, hwid):
    store = load_store()
    rec = store["keys"].get(key)
    if not rec:
        return False, "invalid_key", None
    if not rec.get("active", True):
        return False, "revoked", None
    exp = rec.get("expires", 0)
    if exp and time.time() > exp:
        return False, "expired", None
    if not hwid:
        return False, "no_hwid", None
    bound = rec.get("hwid")
    if bound is None:
        rec["hwid"] = hwid; rec["bound_at"] = int(time.time()); save_store(store)
    elif bound != hwid:
        return False, "hwid_mismatch", None
    script = read_script(rec.get("script", "main"))
    if script is None:
        return False, "no_script", None
    return True, rec.get("script", "main"), script


# ---- obfuscation (dashboard) -----------------------------------------
def obfuscate_source(source, name, flags):
    if not LUA_BIN:
        return False, "no lua interpreter found on server (install lua5.4)"
    if not name or any(c in name for c in "/\\.. "):
        return False, "invalid script name"
    os.makedirs(SCRIPTS_DIR, exist_ok=True)
    outpath = os.path.join(SCRIPTS_DIR, f"{name}.lua")
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as tf:
        tf.write(source); inpath = tf.name
    try:
        allow = {"--vm", "--flatten", "--no-vm-protect", "--no-encrypt-code",
                 "--no-anti-tamper", "--no-micro-ops", "--no-rename",
                 "--no-strings", "--no-numbers", "--no-junk"}
        safe = [f for f in (flags or []) if f in allow]
        cmd = [LUA_BIN, CLI, inpath, outpath] + safe
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            return False, (p.stderr or "obfuscation failed").strip()
        return True, os.path.getsize(outpath)
    except Exception as e:
        return False, str(e)
    finally:
        try: os.unlink(inpath)
        except OSError: pass


# ---- sessions ---------------------------------------------------------
def new_session():
    tok = secrets.token_hex(24)
    SESSIONS[tok] = time.time() + 8 * 3600
    return tok


def valid_session(handler):
    ck = SimpleCookie(handler.headers.get("Cookie", ""))
    tok = ck["lh_session"].value if "lh_session" in ck else None
    if tok and SESSIONS.get(tok, 0) > time.time():
        return True
    return False


# ---- HTTP handler -----------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        sys.stderr.write("[keyserver] " + (a[0] % a[1:]) + "\n")

    def _json(self, obj, code=200, sign_body=False, cookie=None):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        if sign_body:
            self.send_header("X-LH-Signature", sign(body))
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, html, code=200):
        body = html.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def _raw(self, text, code=200):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_GET(self):
        if self.path == "/v1/health":
            return self._json({"ok": True}, sign_body=True)
        # decryption key for --key-url builds (set LUAHELLPER_DECKEY on the server)
        if self.path == "/key":
            return self._raw(os.environ.get("LUAHELLPER_DECKEY", ""))
        # raw paste — this is what a Roblox loadstring(game:HttpGet(...)) fetches
        if self.path.startswith("/raw/"):
            pid = os.path.basename(self.path[5:])
            path = os.path.join(PASTES_DIR, pid + ".lua")
            if pid and os.path.exists(path):
                return self._raw(open(path, encoding="utf-8").read())
            return self._raw("-- paste not found", 404)
        if self.path == "/":
            # public obfuscator + paste-link page (served from web/landing.html)
            lp = os.path.join(ROOT, "web", "landing.html")
            if os.path.exists(lp):
                return self._html(open(lp, encoding="utf-8").read())
            return self._html(LOGIN_HTML)
        if self.path == "/login":
            return self._html(LOGIN_HTML)
        if self.path == "/dashboard":
            if not valid_session(self):
                return self._html(LOGIN_HTML)
            return self._html(DASH_HTML)
        if self.path == "/admin/keys":
            if not valid_session(self):
                return self._json({"ok": False, "reason": "unauth"}, 401)
            store = load_store(); now = time.time(); rows = []
            for k, r in store["keys"].items():
                exp = r.get("expires", 0)
                status = "revoked" if not r.get("active", True) else ("expired" if exp and now > exp else "active")
                rows.append({"key": k, "status": status, "script": r.get("script", "main"),
                             "hwid": r.get("hwid"), "expires": exp})
            return self._json({"ok": True, "keys": rows})
        return self._json({"ok": False, "reason": "not_found"}, 404)

    def do_POST(self):
        if self.path == "/v1/auth":
            d = self._body()
            ok, reason, script = authorize(str(d.get("key", "")), str(d.get("hwid", "")))
            return self._json({"ok": True, "script": script} if ok else {"ok": False, "reason": reason}, sign_body=True)

        if self.path == "/admin/login":
            d = self._body()
            given = hashlib.sha256(str(d.get("password", "")).encode()).hexdigest()
            if hmac.compare_digest(given, get_admin_hash()):
                tok = new_session()
                return self._json({"ok": True}, cookie=f"lh_session={tok}; HttpOnly; Path=/; SameSite=Strict")
            return self._json({"ok": False, "reason": "bad_password"}, 403)

        # create a paste (open, like a pastebin) -> returns id + raw path
        if self.path == "/api/paste":
            d = self._body()
            content = str(d.get("content", ""))
            if not content.strip():
                return self._json({"ok": False, "reason": "empty"}, 400)
            os.makedirs(PASTES_DIR, exist_ok=True)
            pid = secrets.token_urlsafe(6).replace("-", "a").replace("_", "b")
            open(os.path.join(PASTES_DIR, pid + ".lua"), "w", encoding="utf-8").write(content)
            resp = {"ok": True, "id": pid, "raw": "/raw/" + pid}
            body = json.dumps(resp).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # everything below requires a session
        if not valid_session(self):
            return self._json({"ok": False, "reason": "unauth"}, 401)

        if self.path == "/admin/logout":
            ck = SimpleCookie(self.headers.get("Cookie", ""))
            if "lh_session" in ck:
                SESSIONS.pop(ck["lh_session"].value, None)
            return self._json({"ok": True})

        if self.path == "/admin/obfuscate":
            d = self._body()
            name = str(d.get("name", "main"))
            ok, info = obfuscate_source(str(d.get("source", "")), name, d.get("flags", ["--vm"]))
            if not ok:
                return self._json({"ok": False, "reason": info})
            content = read_script(name) or ""
            return self._json({"ok": True, "bytes": info, "content": content})

        if self.path == "/admin/keys":
            d = self._body()
            store = load_store()
            key = "LH-" + secrets.token_hex(12)
            days = int(d.get("days", 0) or 0)
            store["keys"][key] = {"hwid": None, "expires": int(time.time() + days * 86400) if days else 0,
                                  "active": True, "script": str(d.get("script", "main"))}
            save_store(store)
            return self._json({"ok": True, "key": key})

        if self.path in ("/admin/revoke", "/admin/rebind"):
            d = self._body(); store = load_store(); k = str(d.get("key", ""))
            if k not in store["keys"]:
                return self._json({"ok": False, "reason": "no_such_key"}, 404)
            if self.path.endswith("revoke"):
                store["keys"][k]["active"] = False
            else:
                store["keys"][k]["hwid"] = None
            save_store(store)
            return self._json({"ok": True})

        return self._json({"ok": False, "reason": "not_found"}, 404)


# ---- HTML (inline, no external deps) ---------------------------------
LOGIN_HTML = """<!doctype html><meta charset=utf-8><title>luahellper</title>
<style>body{background:#140a22;color:#f4e9ff;font:15px system-ui;display:flex;height:100vh;margin:0;align-items:center;justify-content:center}
form{background:#1e1236;padding:32px;border:1px solid #3a2360;border-radius:12px;width:300px}
h1{margin:0 0 4px;font-size:20px}p{color:#bda6dc;margin:0 0 20px;font-size:13px}
input{width:100%;padding:10px;margin:6px 0;background:#140a22;border:1px solid #3a2360;border-radius:8px;color:#f4e9ff;box-sizing:border-box}
button{width:100%;padding:10px;margin-top:10px;background:#d6249f;border:0;border-radius:8px;color:#fff;font-weight:600;cursor:pointer}
.err{color:#f85149;font-size:13px;min-height:18px}</style>
<form onsubmit="return login(event)"><h1>luahellper</h1><p>admin dashboard</p>
<input id=pw type=password placeholder="admin password" autofocus>
<div class=err id=err></div><button>Sign in</button></form>
<script>async function login(e){e.preventDefault();
let r=await fetch('/admin/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:pw.value})});
let d=await r.json(); if(d.ok){location='/dashboard'}else{err.textContent='wrong password'} return false}</script>"""

DASH_HTML = """<!doctype html><meta charset=utf-8><title>luahellper dashboard</title>
<style>body{background:#140a22;color:#f4e9ff;font:14px system-ui;margin:0}
header{display:flex;justify-content:space-between;align-items:center;padding:14px 24px;border-bottom:1px solid #3a2360}
header h1{font-size:18px;margin:0}.wrap{max-width:900px;margin:0 auto;padding:24px}
.card{background:#1e1236;border:1px solid #3a2360;border-radius:12px;padding:20px;margin-bottom:22px}
h2{font-size:15px;margin:0 0 14px}label{font-size:12px;color:#bda6dc}
textarea,input,select{width:100%;box-sizing:border-box;background:#140a22;border:1px solid #3a2360;border-radius:8px;color:#f4e9ff;padding:9px;margin:4px 0 12px;font-family:ui-monospace,monospace}
textarea{min-height:150px;resize:vertical}
button{background:#d6249f;border:0;border-radius:8px;color:#fff;font-weight:600;padding:9px 16px;cursor:pointer}
button.sec{background:#251545;border:1px solid #3a2360}
.row{display:flex;gap:10px;align-items:end}.row>div{flex:1}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:8px;border-bottom:1px solid #251545}
.tag{padding:2px 8px;border-radius:20px;font-size:11px}.active{background:#1a7f37}.revoked{background:#5c1a1a}.expired{background:#5c4a1a}
code{background:#140a22;padding:2px 6px;border-radius:5px;font-size:12px}.msg{font-size:13px;color:#bda6dc;min-height:18px}
a{color:#ff5cc8;cursor:pointer}</style>
<header><h1>luahellper</h1><a onclick="fetch('/admin/logout',{method:'POST'}).then(()=>location='/')">Sign out</a></header>
<div class=wrap>
<div class=card><h2>1 · Obfuscate a script</h2>
<label>Script name (served as this name)</label><input id=name value=main>
<label>Paste your Luau source</label><textarea id=src placeholder="-- your script here"></textarea>
<label><input type=checkbox id=vm checked style=width:auto> VM virtualization (max protection)</label>
<div style=margin-top:12px><button onclick=obf()>Obfuscate &amp; save</button> <span class=msg id=omsg></span></div></div>

<div class=card><h2>2 · Create a key</h2>
<div class=row><div><label>Script</label><input id=kscript value=main></div>
<div><label>Expires (days, 0 = never)</label><input id=kdays type=number value=30></div>
<div style=flex:0><button onclick=mkkey()>Create key</button></div></div>
<div class=msg id=kmsg></div></div>

<div class=card><h2>3 · Keys</h2><table id=tbl><thead><tr><th>Key</th><th>Status</th><th>Script</th><th>HWID</th><th></th></tr></thead><tbody></tbody></table></div>

<div class=card><h2>Paste host → loadstring link</h2>
<p class=msg>Obfuscates the script above, hosts it on this server, and gives you a one-line <code>loadstring(game:HttpGet(...))</code> to hand out. No key check — anyone with the link can run it.</p>
<div style=margin-top:10px><button onclick=paste()>Obfuscate &amp; make loadstring</button> <span class=msg id=pmsg></span></div>
<textarea id=pout readonly style=min-height:70px;margin-top:10px placeholder="loadstring(game:HttpGet(\"...\"))()"></textarea></div>

<div class=card><h2>Key-gated loader snippet</h2><p class=msg>For the HWID/key flow instead: fill in your server URL + a key.</p>
<textarea id=loader readonly style=min-height:120px></textarea></div>
</div>
<script>
const J=(u,b)=>fetch(u,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b||{})}).then(r=>r.json());
async function obf(){omsg.textContent='working…';let flags=vm.checked?['--vm']:[];
 let d=await J('/admin/obfuscate',{name:name.value,source:src.value,flags:flags});
 omsg.textContent=d.ok?('saved '+d.bytes+' bytes as '+name.value):('error: '+d.reason)}
async function paste(){pmsg.textContent='working…';pout.value='';
 let d=await J('/admin/obfuscate',{name:name.value,source:src.value,flags:vm.checked?['--vm']:[]});
 if(!d.ok){pmsg.textContent='error: '+d.reason;return}
 let p=await J('/api/paste',{content:d.content});
 if(!p.ok){pmsg.textContent='paste error: '+p.reason;return}
 pout.value='loadstring(game:HttpGet("'+location.origin+p.raw+'"))()';
 pmsg.textContent='hosted at '+location.origin+p.raw; pout.select();}
async function mkkey(){let d=await J('/admin/keys',{script:kscript.value,days:parseInt(kdays.value)||0});
 kmsg.textContent=d.ok?('created '+d.key):('error: '+d.reason); load()}
async function load(){let d=await(await fetch('/admin/keys')).json();let tb=document.querySelector('#tbl tbody');tb.innerHTML='';
 (d.keys||[]).forEach(k=>{let tr=document.createElement('tr');
 tr.innerHTML=`<td><code>${k.key}</code></td><td><span class="tag ${k.status}">${k.status}</span></td><td>${k.script}</td><td>${k.hwid||'—'}</td>
 <td><a onclick="rev('${k.key}')">revoke</a> · <a onclick="reb('${k.key}')">rebind</a></td>`;tb.appendChild(tr)})}
async function rev(k){await J('/admin/revoke',{key:k});load()}
async function reb(k){await J('/admin/rebind',{key:k});load()}
loader.value='-- luahellper loader\\nlocal SERVER="'+location.origin+'/v1/auth"\\nlocal KEY="PASTE-KEY"\\n'+
'local H=game:GetService("HttpService")\\nlocal function hwid() local ok,i=pcall(function() return gethwid and gethwid() or game:GetService("RbxAnalyticsService"):GetClientId() end) return ok and i or "unknown" end\\n'+
'local req=(syn and syn.request) or http_request or request\\nlocal r=req({Url=SERVER,Method="POST",Headers={["Content-Type"]="application/json"},Body=H:JSONEncode({key=KEY,hwid=hwid()})})\\n'+
'local d=H:JSONDecode(r.Body) assert(d.ok,d.reason) loadstring(d.script)()';
load();
</script>"""


# ---- CLI --------------------------------------------------------------
def cmd_serve(args):
    os.makedirs(SCRIPTS_DIR, exist_ok=True)
    get_secret(); get_admin_hash()
    if not LUA_BIN:
        print("[keyserver] warning: no lua interpreter found; web obfuscation disabled", file=sys.stderr)
    # cloud hosts (Render/Railway/etc.) inject the port via $PORT
    port = int(os.environ.get("PORT", args.port))
    srv = ThreadingHTTPServer((args.host, port), Handler)
    print(f"[keyserver] dashboard: http://{args.host}:{port}/   api: /v1/auth", file=sys.stderr)
    srv.serve_forever()


def cmd_addkey(args):
    store = load_store()
    key = args.key or ("LH-" + secrets.token_hex(12))
    store["keys"][key] = {"hwid": None, "expires": int(time.time() + args.days * 86400) if args.days else 0,
                          "active": True, "script": args.script}
    save_store(store); print(key)


def cmd_listkeys(args):
    store = load_store(); now = time.time()
    for k, r in store["keys"].items():
        exp = r.get("expires", 0)
        status = "revoked" if not r.get("active", True) else ("expired" if exp and now > exp else "active")
        left = f"{int((exp-now)/86400)}d" if exp else "never"
        print(f"{k}  [{status}] script={r.get('script','main')} hwid={r.get('hwid')} expires={left}")


def cmd_revoke(args):
    store = load_store()
    if args.key not in store["keys"]:
        print("no such key", file=sys.stderr); sys.exit(1)
    store["keys"][args.key]["active"] = False; save_store(store); print("revoked "+args.key)


def cmd_rebind(args):
    store = load_store()
    if args.key not in store["keys"]:
        print("no such key", file=sys.stderr); sys.exit(1)
    store["keys"][args.key]["hwid"] = None; save_store(store); print("rebound "+args.key)


def cmd_setpass(args):
    open(ADMIN_PATH, "w").write(hashlib.sha256(args.password.encode()).hexdigest())
    print("dashboard password updated")


def main():
    p = argparse.ArgumentParser(description="luahellper key server + dashboard")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve"); s.add_argument("--host", default="127.0.0.1"); s.add_argument("--port", type=int, default=8080); s.set_defaults(fn=cmd_serve)
    a = sub.add_parser("addkey"); a.add_argument("--script", default="main"); a.add_argument("--days", type=int, default=0); a.add_argument("--key", default=None); a.set_defaults(fn=cmd_addkey)
    sub.add_parser("listkeys").set_defaults(fn=cmd_listkeys)
    r = sub.add_parser("revoke"); r.add_argument("key"); r.set_defaults(fn=cmd_revoke)
    b = sub.add_parser("rebind"); b.add_argument("key"); b.set_defaults(fn=cmd_rebind)
    sp = sub.add_parser("setpass"); sp.add_argument("password"); sp.set_defaults(fn=cmd_setpass)
    args = p.parse_args(); args.fn(args)


if __name__ == "__main__":
    main()
