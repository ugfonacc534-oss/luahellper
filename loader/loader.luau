--!nocheck
-- luahellper loader (Roblox executor edition)
-- Fetches your obfuscated script from the key server, gated by key + HWID.
-- Distribute THIS (short) loader to users; the real script never ships with it.
--
--   loadstring(game:HttpGet("https://yourhost/loader.luau"))()
--
-- ...or paste it directly. Edit SERVER and KEY (or have users paste their KEY).

local SERVER = "http://127.0.0.1:8080/v1/auth"   -- your key server /v1/auth URL
local KEY    = "PASTE-YOUR-KEY-HERE"             -- the user's key

local HttpService = game:GetService("HttpService")

-- best-effort stable per-device id
local function getHWID()
	local ok, id = pcall(function()
		if gethwid then return gethwid() end                       -- most executors
		return game:GetService("RbxAnalyticsService"):GetClientId() -- fallback
	end)
	return (ok and id) or "unknown"
end

-- find an HTTP POST function across executors
local httpRequest =
	(syn and syn.request)
	or (http and http.request)
	or http_request
	or request
	or (fluxus and fluxus.request)
assert(httpRequest, "[luahellper] no HTTP request function in this executor")

local res = httpRequest({
	Url = SERVER,
	Method = "POST",
	Headers = { ["Content-Type"] = "application/json" },
	Body = HttpService:JSONEncode({ key = KEY, hwid = getHWID() }),
})
assert(res and res.StatusCode == 200, "[luahellper] server unreachable")

local data = HttpService:JSONDecode(res.Body)
if not data.ok then
	error("[luahellper] auth failed: " .. tostring(data.reason))
end

local fn = loadstring(data.script)
assert(fn, "[luahellper] could not load returned script")
return fn()
