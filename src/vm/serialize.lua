-- serialize.lua : proto tree -> self-contained Lua source.
-- Emits: encrypted string-constant pool + decoder, the embedded interpreter
-- (per-build randomized + duplicated opcode dispatch), the proto data (with the
-- bytecode optionally encrypted as an opaque blob), optional anti-tamper /
-- anti-hook guards, and a bootstrap call.
local RT = require("vm.runtime")
local OPC = require("vm.opcodes")
local M={}

-- ---- interpreter dispatch (opcode aliasing + shuffle) ------------------
local function buildInterp(opmap, rng, dsName)
  local cases={}
  for _, name in ipairs(OPC.NAMES) do
    local v=opmap[name]
    if type(v)=="table" then for _, num in ipairs(v) do cases[#cases+1]={num, name} end
    else cases[#cases+1]={v, name} end
  end
  for i=#cases,2,-1 do local j=rng(1,i); cases[i],cases[j]=cases[j],cases[i] end
  local parts={ RT.PREAMBLE }
  for i, c in ipairs(cases) do
    parts[#parts+1]=("    %s op==%d then %s\n"):format(i==1 and "if" or "elseif", c[1], RT.HANDLERS[c[2]])
  end
  parts[#parts+1]=RT.POSTAMBLE
  -- handlers call the string decryptor as DS(...); bind it to the real name
  return (table.concat(parts):gsub("DS%(", dsName.."("))
end

local function fmtNumber(v)
  if v ~= v then return "(0/0)" end
  if v == math.huge then return "(1/0)" end
  if v == -math.huge then return "(-1/0)" end
  if math.type and math.type(v)=="integer" then return ("%d"):format(v) end
  local s = ("%.17g"):format(v)
  if not s:find("[%.eEnN]") then s = s..".0" end
  return s
end

local function mask(i,j,key) return (key + i*31 + j*17) % 256 end

-- quote a byte string into a Lua double-quoted literal (\ddd for unsafe bytes)
local function quoteBlob(bytes)
  local t={}
  for _,b in ipairs(bytes) do
    if b<32 or b>126 or b==34 or b==92 then t[#t+1]=("\\%03d"):format(b)
    else t[#t+1]=string.char(b) end
  end
  return table.concat(t)
end

-- ---- bytecode blob encoding (varint + zigzag) --------------------------
local function uvarint(n, out)
  n = math.floor(n)
  while true do
    local c = n % 128; n = math.floor(n/128)
    if n>0 then out[#out+1]=c+128 else out[#out+1]=c; break end
  end
end
local function zigzag(n) if n<0 then return -2*n-1 else return 2*n end end

-- encode one proto's code array to a byte array
local function encodeCode(code)
  local B={}
  uvarint(#code, B)
  for _, ins in ipairs(code) do
    uvarint(ins[1], B)
    if ins[3]~=nil then
      B[#B+1]=2
      uvarint(zigzag(ins[2]), B)
      uvarint(#ins[3], B)
      for _, d in ipairs(ins[3]) do uvarint(d[1],B); uvarint(d[2],B) end
    elseif ins[2]~=nil then
      B[#B+1]=1; uvarint(zigzag(ins[2]), B)
    else
      B[#B+1]=0
    end
  end
  return B
end

-- runtime code-blob decoder source (mirrors encodeCode + the position cipher)
local function cdecSource(name)
  return ([[local function %s(enc,key)
  local n=#enc local B={} for p=1,n do B[p]=(enc:byte(p)-((key+p*7)%%256))%%256 end
  local pos=1
  local function u() local sh=0 local val=0 while true do local c=B[pos] pos=pos+1 val=val+(c%%128)*(2^sh) if c<128 then break end sh=sh+7 end return val end
  local function z() local v=u() if v%%2==1 then return -((v+1)/2) else return v/2 end end
  local cnt=u() local code={}
  for i=1,cnt do
    local op=u() local tag=B[pos] pos=pos+1 local ins={op}
    if tag==1 then ins[2]=z()
    elseif tag==2 then ins[2]=z() local m=u() local d={} for j=1,m do local a=u() local b=u() d[j]={a,b} end ins[3]=d end
    code[i]=ins
  end
  return code
end]]):format(name)
end

function M.serialize(topProto, opts)
  opts = opts or {}
  local key = opts.key or 91
  local names = opts.names
  local opmap = opts.opmap or OPC
  local rng = opts.rng or function(a,b) return a end
  local encryptCode = opts.encryptCode ~= false
  local antiTamper  = opts.antiTamper  ~= false
  local function nm(tag) return names and names() or ("_"..tag) end

  local RUN, PROTO, DS, SK, ENV = nm("r"), nm("p"), nm("d"), nm("k"), nm("e")
  local CDEC, BL, CKEY = nm("c"), nm("b"), nm("y")

  -- collected code blobs (encrypted byte strings) when encryptCode is on
  local blobs={}
  local codeKey = rng(1,255)
  local strKey  = rng(1,255)
  local rawSum = 0     -- running sum of all emitted (encrypted) blob bytes

  local out={}
  local function emitValue(v)
    local t=type(v)
    if t=="number" then out[#out+1]=fmtNumber(v)
    elseif t=="string" then
      -- JIT constant encryption: strings are stored encrypted and decrypted at
      -- point of use (DS) so no plaintext table of strings sits in memory.
      local b={}
      for j=1,#v do b[j]=(v:byte(j)+(strKey+j*17)%256)%256 end
      out[#out+1]='"'..quoteBlob(b)..'"'
    elseif t=="boolean" then out[#out+1]=tostring(v)
    else error("serialize: bad const "..t) end
  end

  local function emitInstr(ins)
    out[#out+1]="{"..tostring(ins[1])
    if ins[3]~=nil then
      out[#out+1]=","..tostring(ins[2])..",{"
      for i,d in ipairs(ins[3]) do
        if i>1 then out[#out+1]="," end
        out[#out+1]="{"..tostring(d[1])..","..tostring(d[2]).."}"
      end
      out[#out+1]="}"
    elseif ins[2]~=nil then out[#out+1]=","..tostring(ins[2]) end
    out[#out+1]="}"
  end

  local function emitProto(p)
    local K, code, protos, np, va = p[1], p[2], p[3], p[4], p[5]
    out[#out+1]="{{"
    for i,c in ipairs(K) do if i>1 then out[#out+1]="," end emitValue(c) end
    out[#out+1]="},"
    if encryptCode then
      -- encode + encrypt code, store blob, reference it via CDEC at load
      local bytes = encodeCode(code)
      for p2=1,#bytes do
        bytes[p2] = (bytes[p2] + (codeKey + p2*7) % 256) % 256
        rawSum = rawSum + bytes[p2]
      end
      blobs[#blobs+1] = quoteBlob(bytes)
      out[#out+1]=("%s(%s[%d],%s)"):format(CDEC, BL, #blobs, CKEY)
    else
      out[#out+1]="{"
      for i,ins in ipairs(code) do if i>1 then out[#out+1]="," end emitInstr(ins) end
      out[#out+1]="}"
    end
    out[#out+1]=",{"
    for i,cp in ipairs(protos) do if i>1 then out[#out+1]="," end emitProto(cp) end
    out[#out+1]="},"..tostring(np)..","..tostring(va).."}"
  end

  -- build proto literal (fills string pool + code blobs)
  local protoChunk
  do
    local save=out; out={}
    emitProto(topProto)
    protoChunk=table.concat(out); out=save
  end

  -- anti-hook probe: evaluates to 0 iff core primitives behave normally; a hook
  -- that changes them shifts it, corrupting every key it is folded into.
  local PROBE = "((#string.char(0,0,0)-3)+(select(\"#\",1,1,1)-3)"
    .."+((((\"%d\"):format(7))==\"7\") and 0 or 1)"
    .."+(((\"abc\"):sub(2,2)==\"b\") and 0 or 1)"
    .."+((tostring(true)==\"true\") and 0 or 1))"

  -- ---- assemble ----
  local pieces={}
  -- string key (with anti-hook probe folded in) + per-use decryptor DS
  if antiTamper then
    pieces[#pieces+1]=("local %s=(function() return %d+%s end)()"):format(SK, strKey, PROBE)
  else
    pieces[#pieces+1]=("local %s=%d"):format(SK, strKey)
  end
  pieces[#pieces+1]=("local function %s(s) local o={} for p=1,#s do o[p]=string.char((s:byte(p)-((%s+p*17)%%256))%%256) end return table.concat(o) end")
    :format(DS, SK)
  -- interpreter (captures DS as an upvalue)
  pieces[#pieces+1]=("local %s=(function() %s end)()"):format(RUN, buildInterp(opmap, rng, DS))

  if encryptCode then
    pieces[#pieces+1]=cdecSource(CDEC)
    pieces[#pieces+1]=("local %s={%s}"):format(BL,
      (function() local t={} for _,b in ipairs(blobs) do t[#t+1]='"'..b..'"' end return table.concat(t,",") end)())
    if antiTamper then
      -- Integrity + anti-hook folded into the bytecode decode key: byte-sum of
      -- all blobs must match, and the probe must be 0. Any edit to the bytecode
      -- or a hook shifts CKEY -> bytecode decodes to garbage (nothing to patch).
      local EXPECTED = rawSum % 251
      pieces[#pieces+1]=("local %s=(function() local S=0 for i=1,#%s do local s=%s[i] for p=1,#s do S=S+s:byte(p) end end S=S%%251 return %d+(S-%d)+%s end)()")
        :format(CKEY, BL, BL, codeKey, EXPECTED, PROBE)
    else
      pieces[#pieces+1]=("local %s=%d"):format(CKEY, codeKey)
    end
  end

  pieces[#pieces+1]=("local %s=%s"):format(PROTO, protoChunk)
  pieces[#pieces+1]=("local %s=(getfenv and getfenv()) or _ENV or _G"):format(ENV)
  pieces[#pieces+1]=("return %s(%s,{},%s,...)"):format(RUN, PROTO, ENV)
  return table.concat(pieces, ";\n")
end

return M
