# Deploy luahellper (get a public URL like `luahellper.onrender.com`)

Your paste links and loaders point at whatever host you deploy to. Name the
service **luahellper** and the URL carries your name.

## Render (free, one click) — recommended

1. Push this repo to GitHub.
2. Go to https://render.com → **New → Blueprint**, pick this repo.
   Render reads `render.yaml` and builds the `Dockerfile` (includes `lua5.4`).
3. Name the service **luahellper** → your URL is `https://luahellper.onrender.com`.
4. Set env var `LUAHELLPER_ADMIN` to your dashboard password in the Render UI.
5. Open `https://luahellper.onrender.com/` → sign in → obfuscate → **Paste host →
   loadstring link** gives you:

   ```lua
   loadstring(game:HttpGet("https://luahellper.onrender.com/raw/<id>"))()
   ```

## Railway / Fly / any Docker host

The `Dockerfile` runs anywhere. The host sets `$PORT`; the server reads it.
Point a domain at it and your links become `https://<yourdomain>/raw/<id>`.

## Locally

```sh
python3 server/keyserver.py setpass MyPassword
python3 server/keyserver.py serve --port 8080
# http://localhost:8080/
```

## Notes
- Render's free tier sleeps when idle and its disk is ephemeral — fine for
  testing; for permanent paste storage use a paid tier or a host with a volume,
  or swap `server/pastes/` for a database.
- Always serve over HTTPS (Render/Railway give you HTTPS automatically); Roblox
  `game:HttpGet` needs `https://`.
