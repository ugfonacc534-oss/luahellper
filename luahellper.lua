#!/usr/bin/env lua
-- CLI: lua luahellper.lua <input.lua> [output.lua] [--seed N] [--no-junk]
--                        [--flatten] [--no-strings] [--no-numbers] [--no-rename]
local here = (arg[0]:match("^(.*)[/\\]") or ".")
package.path = here.."/src/?.lua;"..package.path
local Obf = require("obfuscator")

local input, output
local opts = {}
local i=1
while arg[i] do
  local a=arg[i]
  if a=="--seed" then i=i+1; opts.seed=tonumber(arg[i])
  elseif a=="--no-junk" then opts.junk=false
  elseif a=="--no-strings" then opts.strings=false
  elseif a=="--no-numbers" then opts.numbers=false
  elseif a=="--no-rename" then opts.rename=false
  elseif a=="--flatten" then opts.flatten=true
  elseif a=="--vm" then opts.vm=true
  elseif a=="--no-vm-protect" then opts.vmProtect=false
  elseif a=="--no-encrypt-code" then opts.encryptCode=false
  elseif a=="--no-anti-tamper" then opts.antiTamper=false
  elseif a=="--no-micro-ops" then opts.microOps=false
  elseif a=="--nest" then i=i+1; opts.nest=tonumber(arg[i])
  elseif a=="--watermark" then i=i+1; opts.watermark=arg[i]
  elseif a=="--key-url" then i=i+1; opts.keyUrl=arg[i]
  elseif a=="--max" then opts.vm=true; opts.nest=2
  elseif not input then input=a
  elseif not output then output=a end
  i=i+1
end

if not input then
  io.stderr:write("usage: lua luahellper.lua <input.lua> [output.lua] [flags]\n")
  os.exit(1)
end

local f=assert(io.open(input,"r")); local src=f:read("*a"); f:close()
local ok, result = pcall(Obf.obfuscate, src, opts)
if not ok then io.stderr:write("error: "..tostring(result).."\n"); os.exit(1) end
if opts.__deckey then
  io.stderr:write("\n[key-url] set this on your server so /key returns it:\n  LUAHELLPER_DECKEY="..opts.__deckey.."\n\n")
end

if output then
  local o=assert(io.open(output,"w")); o:write(result); o:close()
  io.stderr:write(("obfuscated %s -> %s (%d bytes)\n"):format(input, output, #result))
else
  io.write(result)
end
