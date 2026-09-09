-- strings.lua : move every string literal into an encrypted runtime pool.
-- Replaces each `"literal"` with `POOL[idx]`. Reversible modular cipher
-- (no bit library needed -> runs on Luau and standalone Lua alike).
local Walk=require("walk")
local M={}

-- mask(i,j,key) must match the runtime decoder below exactly.
local function mask(i,j,key) return (key + i*31 + j*17) % 256 end

function M.apply(ast, poolName, rng)
  local key = rng and rng(0,255) or 137
  local list={}          -- ordered unique decoded strings
  local index={}         -- value -> idx
  local function intern(v)
    local idx=index[v]
    if not idx then list[#list+1]=v; idx=#list; index[v]=idx end
    return idx
  end
  Walk.exprs(ast, function(e)
    if e.kind=="String" then
      -- mutate in place -> POOL[idx]
      local idx=intern(e.value)
      e.kind="Index"
      e.obj={ kind="Name", name=poolName }
      e.key={ kind="Number", value=tostring(idx) }
      e.value=nil
    elseif e.kind=="Interp" then
      -- encrypt literal segments of `...{}...` strings too
      for _,p in ipairs(e.parts) do
        if p.str~=nil and p.str~="" then
          local idx=intern(p.str)
          p.expr={ kind="Index", obj={kind="Name",name=poolName}, key={kind="Number",value=tostring(idx)} }
          p.str=nil
        end
      end
    end
  end)

  -- build encoded blob + lengths
  local bytes={}
  local lens={}
  for i,s in ipairs(list) do
    lens[i]=#s
    for j=1,#s do
      bytes[#bytes+1]= (s:byte(j) + mask(i,j,key)) % 256
    end
  end
  return { poolName=poolName, key=key, bytes=bytes, lens=lens, count=#list }
end

-- returns the runtime decoder source (a Lua statement defining `poolName`)
function M.runtime(info, quote)
  local blob={}
  for _,b in ipairs(info.bytes) do blob[#blob+1]=string.char(b) end
  blob=table.concat(blob)
  local L={}
  for _,n in ipairs(info.lens) do L[#L+1]=tostring(n) end
  return ("local %s=(function()local b=%s;local L={%s};local K=%d;local o={};local p=1;for i=1,#L do local n=L[i];local c={};for j=1,n do c[j]=string.char((b:byte(p)-((K+i*31+j*17)%%256))%%256);p=p+1 end;o[i]=table.concat(c) end;return o end)()")
    :format(info.poolName, quote(blob), table.concat(L,","), info.key)
end

return M
