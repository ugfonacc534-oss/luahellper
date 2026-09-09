# luahellper key server

A dependency-free reference server (Python 3 stdlib only) that gates delivery of
your obfuscated Luau script behind a **key bound to a HWID** — the Luarmor model.

## Flow

```
 user's executor                         your server
 ───────────────                         ───────────
 loader.luau  ──POST {key, hwid}──▶  /v1/auth
                                          │  validate key: active? expired?
                                          │  bind/check HWID
              ◀──{ok:true, script}────────┘  returns obfuscated script only if OK
 loadstring(script)()
```

The obfuscated script is only handed to an authorized client, and you can
expire / revoke / rebind keys at any time.

## Web dashboard (the "website")

The server also serves a password-protected browser dashboard — obfuscate a
pasted script, create/revoke/rebind keys, and copy a ready-made loader, all in
the browser. No extra installs (needs `lua`/`lua5.4` on the box for the
obfuscate button).

```sh
python3 server/keyserver.py setpass MyPassword        # set the dashboard login
python3 server/keyserver.py serve --host 0.0.0.0 --port 8080
# open http://<server>:8080/  in a browser and sign in
```

Pages: `/` (login) → `/dashboard`. It drives the same `/admin/*` + `/v1/auth`
endpoints under the hood. Put it behind HTTPS and keep the port private.

## Quick start (CLI, no dashboard)

```sh
# 1. obfuscate your script and drop it where the server serves it
lua luahellper.lua myscript.lua server/scripts/main.lua --vm

# 2. create a key (30-day, bound to script "main")
python3 server/keyserver.py addkey --script main --days 30
#   -> prints e.g. LH-46cdad2e6e23d1dd7cfbfc1a

# 3. run the server
python3 server/keyserver.py serve --host 0.0.0.0 --port 8080

# 4. give the user loader/loader.luau with SERVER + KEY filled in
```

Manage keys:

```sh
python3 server/keyserver.py listkeys
python3 server/keyserver.py revoke  LH-xxxx     # kill switch
python3 server/keyserver.py rebind  LH-xxxx     # clear HWID (user changed device)
```

## API

| method | path         | body                      | response |
|--------|--------------|---------------------------|----------|
| GET    | `/v1/health` | —                         | `{"ok":true}` |
| POST   | `/v1/auth`   | `{"key":"…","hwid":"…"}`  | `{"ok":true,"script":"…"}` or `{"ok":false,"reason":"…"}` |

`reason` ∈ `invalid_key | revoked | expired | hwid_mismatch | no_hwid | no_script`.

Every response is HMAC-SHA256 signed in `X-LH-Signature` (secret in
`server/secret` or env `LUAHELLPER_SECRET`).

## Production notes

- **Put it behind HTTPS** (a reverse proxy such as nginx/Caddy). Executors and
  Roblox `HttpService` should talk to the server over TLS.
- `server/secret` and `server/keys.json` are git-ignored — keep them private and
  back up `keys.json`.
- This is a reference implementation: single JSON store, no auth on the admin
  CLI (run it on the server box only), no built-in rate limiting. Add those for
  real deployments, or port the `authorize()` logic to your existing backend.

## Honest limits

A key/HWID system controls **who receives** the script; it cannot stop an
authorized user from capturing the script their own client downloaded. Its value
is: gating distribution, per-user kill switches, and forcing attackers through
your server (where you can rate-limit, log, and revoke). Combine it with `--vm`
obfuscation so a captured script is still expensive to reverse or modify.

## Paste host (loadstring links)

The server doubles as your own pastebin. In the dashboard, **Paste host →
loadstring link** obfuscates the script and hosts it, handing you a one-liner:

```lua
loadstring(game:HttpGet("https://your-server.com:8080/raw/<id>"))()
```

Endpoints: `POST /api/paste {"content"}` → `{id, raw}`; `GET /raw/<id>` serves the
raw script as `text/plain` (CORS-open) — which is exactly what Roblox
`game:HttpGet` fetches. Pastes are stored under `server/pastes/` (git-ignored).
No key check on these links — anyone with the URL can run it; use the key/HWID
loader instead when you need per-user control.

## Server-fetched decryption key (`--key-url`)

Build with `--key-url https://luahellper.onrender.com/key`. The CLI prints a
`LUAHELLPER_DECKEY=...`; set that env var on the server. The server serves it at
`GET /key`, and the obfuscated payload only decrypts when it can fetch it live —
so a leaked file is useless offline, and rotating the env var kills every build
that used it.
