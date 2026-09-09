# Make raw links like Luarmor

luahellper's server IS a "create raw link" service: paste a script → it
obfuscates + hosts it → you get `loadstring(game:HttpGet("https://…/raw/ID"))()`.
You just need to run it on a public host once.

## Fastest: Render (free)

1. Have this repo on GitHub (already pushed).
2. Open **https://render.com** → sign in with GitHub.
3. **New → Web Service** → pick this repo → choose the branch that has
   `render.yaml` and `Dockerfile` → Render fills the rest in.
   (Or **New → Blueprint** to use `render.yaml` directly.)
4. Name the service **luahellper** → **Create**. Wait for the build.
5. You now have **https://luahellper.onrender.com**.

## Make a raw link

- Open `https://luahellper.onrender.com/`
- Paste your script → **Obfuscate** → **Get loadstring link**
- You get:
  ```lua
  loadstring(game:HttpGet("https://luahellper.onrender.com/raw/AbC123"))()
  ```
- Open that `/raw/AbC123` URL in a browser to see the raw script. It works in
  Roblox executors via `game:HttpGet`.

## Key-gated links (optional, more like Luarmor)

Sign in at `/login` (password = `LUAHELLPER_ADMIN` you set in Render's env vars),
go to the dashboard to make per-user **keys** (with expiry / revoke / HWID lock)
and hand out `loader/loader.luau` instead of a plain raw link.

## Notes
- Render's free tier sleeps when idle (first request wakes it, ~30s) and its
  disk is ephemeral — pastes can vanish on restart/redeploy. For permanent
  links use a paid tier with a disk, or any always-on host (Railway, a VPS).
- HTTPS is automatic on Render/Railway; Roblox `game:HttpGet` needs `https://`.
