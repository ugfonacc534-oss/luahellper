-- obfuscator.lua : full pipeline. src(string) -> obfuscated src(string)
local Parser  = require("parser")
local Emitter = require("emitter")
local Scope   = require("scope")
local Rename  = require("transforms.rename")
local Numbers = require("transforms.numbers")
local Strings = require("transforms.strings")
local Flatten = require("transforms.flatten")
local Junk    = require("transforms.junk")
local Names   = require("names")

local M={}

local function makeRng(seed)
  local s = seed or os.time()
  -- simple LCG so builds are reproducible given a seed, no dependency on math.random state
  return function(a,b)
    s = (1103515245*s + 12345) % 2147483648
    local r = s / 2147483648
    return a + math.floor(r*(b-a+1))
  end
end

-- name that will NOT collide with rename output (rename uses only I l i o O 0 1)
local function bootName(rng, tag)
  local pool="abcdefghkmnpqrstuvwxyz"
  local s=""
  for _=1,6 do local k=rng(1,#pool); s=s..pool:sub(k,k) end
  return "_"..tag..s
end

-- opts: { seed=, rename=true, numbers=true, strings=true, flatten=false, junk=true }
function M.obfuscate(src, opts)
  opts = opts or {}
  local rng = makeRng(opts.seed)
  local nextName = Names.new()          -- one factory shared by all passes

  local ast = Parser.parse(src)

  -- VM virtualization: compile to bytecode + embedded interpreter, then
  -- (by default) obfuscate the emitted loader itself for a second layer.
  if opts.vm then
    local Compiler  = require("vm.compiler")
    local Serialize = require("vm.serialize")
    local Opcodes   = require("vm.opcodes")
    -- one virtualization pass: source AST -> bytecode + interpreter
    local function virtualize(chunkAst)
      local opmap = Opcodes.randomize(rng)        -- fresh instruction set per pass
      local proto = Compiler.compile(chunkAst, opmap, rng, { microOps = opts.microOps ~= false })
      return Serialize.serialize(proto, {
        key = rng(1,255), names = nextName, opmap = opmap, rng = rng,
        encryptCode = opts.encryptCode ~= false,
        antiTamper  = opts.antiTamper  ~= false,
      })
    end
    local code = virtualize(ast)
    -- nested virtualization: run the emitted VM loader through the VM again, so
    -- the interpreter itself becomes bytecode under an outer interpreter.
    local nest = tonumber(opts.nest) or 1
    for _=2, nest do code = virtualize(Parser.parse(code)) end
    if opts.vmProtect ~= false then
      local ok, protectedCode = pcall(M.obfuscate, code, {
        seed=opts.seed, rename=true, junk=true,
        strings=false, numbers=false, flatten=false, quiet=true,
      })
      if ok then code = protectedCode end
    end
    -- server-fetched key: ship the payload encrypted; it only decrypts with a
    -- key fetched live from your key server, so the file is useless offline and
    -- you can rotate/revoke it. Outermost layer.
    if opts.keyUrl and opts.keyUrl ~= "" then
      local kchars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
      local ks = {}
      for _=1,24 do local n=rng(1,#kchars); ks[#ks+1]=kchars:sub(n,n) end
      local keyStr = table.concat(ks)
      local enc = {}
      for p=1,#code do
        local kb = keyStr:byte((p-1)%#keyStr+1)
        enc[p] = (code:byte(p) + kb + p*7) % 256
      end
      local q = {}
      for _,b in ipairs(enc) do
        if b<32 or b>126 or b==34 or b==92 then q[#q+1]=("\\%03d"):format(b)
        else q[#q+1]=string.char(b) end
      end
      local blob = table.concat(q)
      code = ("local K=game:HttpGet(\"%s\");local B=\"%s\";local o={};for p=1,#B do local kb=K:byte((p-1)%%#K+1);o[p]=string.char((B:byte(p)-kb-p*7)%%256) end;loadstring(table.concat(o))()")
        :format(opts.keyUrl, blob)
      opts.__deckey = keyStr   -- surfaced to the CLI so you can set it on the server
    end
    -- watermark: traceable marker, applied last so it survives every pass
    if opts.watermark and opts.watermark ~= "" then
      code = "--[[lh:"..tostring(opts.watermark).."]]\n"..code
    end
    return code
  end

  if opts.rename ~= false then
    local recs = Scope.resolve(ast)
    Rename.apply(ast, recs, nextName)
  end

  if opts.flatten then
    Flatten.apply(ast, rng, nextName)
  end

  if opts.junk ~= false then
    Junk.apply(ast, rng, nextName)
  end

  if opts.numbers ~= false then
    Numbers.apply(ast, rng)
  end

  local strInfo
  if opts.strings ~= false then
    local poolName = bootName(rng, "s")
    strInfo = Strings.apply(ast, poolName, rng)
  end

  local body = Emitter.emit(ast)

  local out = {}
  if strInfo and strInfo.count > 0 then
    out[#out+1] = Strings.runtime(strInfo, Emitter.quote)
  end
  out[#out+1] = body
  local final = table.concat(out, ";")

  -- sanity self-check when a Lua loader is available (build-time only).
  -- Non-fatal: Luau-only syntax (continue, etc.) won't load under host Lua,
  -- so a failure here is a warning, not necessarily a real bug.
  if load then
    local ok, err = load(final, "=obf")
    if not ok and not opts.quiet then
      io.stderr:write("[warn] host-Lua load check failed (expected for Luau-only syntax): "..tostring(err).."\n")
    end
  end
  return final
end

return M
