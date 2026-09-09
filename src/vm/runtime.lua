-- runtime.lua : the VM interpreter, expressed as reusable source fragments so
-- the opcode dispatch numbers can be generated per build (see serialize.lua).
--
-- Proto layout (array): {K, code, protos, numparams, isVararg}
-- Instruction (array):  {op, a, b}   (op is a per-build randomized number)
--   for CLOSURE, b = list of upvalue descriptors {mode(0=parent local,1=parent upval), idx}
-- run(P, U, ENV, ...) executes proto P with upvalue cell array U and env ENV.
-- A local "cell" is a 1-field table; closures capture cells by reference.

local M = {}

M.PREAMBLE = [[
local unpack = table.unpack or unpack
local pack = table.pack or function(...) return {n=select("#",...), ...} end
local function run(P, U, ENV, ...)
  local K, code, protos = P[1], P[2], P[3]
  local S, sp = {}, 0
  local L = {}
  local marks, mp = {}, 0
  local va = {...}
  local van = select("#", ...)
  local np = P[4] or 0
  local pc = 1
  while true do
    local ins = code[pc]; pc = pc + 1
    local op = ins[1]
]]

M.POSTAMBLE = [[
    else error("bad op "..tostring(op)) end
  end
end
return run
]]

-- opcode name -> handler body (executed when op matches that opcode's number)
M.HANDLERS = {
  PUSHK     = "local v=K[ins[2]]; if type(v)=='string' then v=DS(v) end; sp=sp+1; S[sp]=v",
  PUSHNIL   = "sp=sp+1; S[sp]=nil",
  PUSHTRUE  = "sp=sp+1; S[sp]=true",
  PUSHFALSE = "sp=sp+1; S[sp]=false",
  PUSHVARARG= "if ins[2]==1 then for i=np+1,van do sp=sp+1; S[sp]=va[i] end else sp=sp+1; S[sp]=va[np+1] end",
  POP       = "for _=1,ins[2] do S[sp]=nil; sp=sp-1 end",
  DUP       = "sp=sp+1; S[sp]=S[sp-1]",
  NEWLOCAL  = "L[ins[2]]={}",
  GETLOCAL  = "sp=sp+1; S[sp]=L[ins[2]][1]",
  SETLOCAL  = "L[ins[2]][1]=S[sp]; S[sp]=nil; sp=sp-1",
  GETUPVAL  = "sp=sp+1; S[sp]=U[ins[2]][1]",
  SETUPVAL  = "U[ins[2]][1]=S[sp]; S[sp]=nil; sp=sp-1",
  GETGLOBAL = "local k=K[ins[2]]; if type(k)=='string' then k=DS(k) end; sp=sp+1; S[sp]=ENV[k]",
  SETGLOBAL = "local k=K[ins[2]]; if type(k)=='string' then k=DS(k) end; ENV[k]=S[sp]; S[sp]=nil; sp=sp-1",
  NEWTABLE  = "sp=sp+1; S[sp]={}",
  GETINDEX  = "local k=S[sp]; local t=S[sp-1]; S[sp]=nil; sp=sp-1; S[sp]=t[k]",
  SETINDEX  = "local v=S[sp]; local k=S[sp-1]; local t=S[sp-2]; S[sp]=nil;S[sp-1]=nil;S[sp-2]=nil; sp=sp-3; t[k]=v",
  ADD       = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]+b",
  SUB       = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]-b",
  MUL       = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]*b",
  DIV       = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]/b",
  MOD       = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]%b",
  POW       = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]^b",
  IDIV      = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]//b",
  CONCAT    = "local b=S[sp]; sp=sp-1; S[sp]=S[sp]..b",
  EQ        = "local b=S[sp]; sp=sp-1; S[sp]=(S[sp]==b)",
  NE        = "local b=S[sp]; sp=sp-1; S[sp]=(S[sp]~=b)",
  LT        = "local b=S[sp]; sp=sp-1; S[sp]=(S[sp]<b)",
  LE        = "local b=S[sp]; sp=sp-1; S[sp]=(S[sp]<=b)",
  GT        = "local b=S[sp]; sp=sp-1; S[sp]=(S[sp]>b)",
  GE        = "local b=S[sp]; sp=sp-1; S[sp]=(S[sp]>=b)",
  NOT       = "S[sp]=not S[sp]",
  NEG       = "S[sp]=-S[sp]",
  LEN       = "S[sp]=#S[sp]",
  JMP       = "pc=ins[2]",
  JMPIF     = "local v=S[sp]; S[sp]=nil; sp=sp-1; if v then pc=ins[2] end",
  JMPIFNOT  = "local v=S[sp]; S[sp]=nil; sp=sp-1; if not v then pc=ins[2] end",
  MARK      = "mp=mp+1; marks[mp]=sp",
  CALL      = [==[
      local base=marks[mp]; mp=mp-1
      local f=S[base+1]
      local an=sp-(base+1)
      local args={}
      for i=1,an do args[i]=S[base+1+i] end
      for i=base+1,sp do S[i]=nil end
      sp=base
      local r=pack(f(unpack(args,1,an)))
      if ins[2]==-1 then for i=1,r.n do sp=sp+1; S[sp]=r[i] end
      else for i=1,ins[2] do sp=sp+1; S[sp]=r[i] end end]==],
  ADJUST    = [==[
      local base=marks[mp]; mp=mp-1
      local target=base+ins[2]
      while sp>target do S[sp]=nil; sp=sp-1 end
      while sp<target do sp=sp+1; S[sp]=nil end]==],
  RET       = [==[
      local base=marks[mp]; mp=mp-1
      local rn=sp-base
      local r={}
      for i=1,rn do r[i]=S[base+i] end
      return unpack(r,1,rn)]==],
  CLOSURE   = [==[
      local cp=protos[ins[2]]
      local desc=ins[3]
      local cu={}
      for i=1,#desc do
        local d=desc[i]
        if d[1]==0 then cu[i]=L[d[2]] else cu[i]=U[d[2]] end
      end
      sp=sp+1
      S[sp]=function(...) return run(cp, cu, ENV, ...) end]==],
  SELF      = "local a=S[sp]; local k=K[ins[2]]; if type(k)=='string' then k=DS(k) end; S[sp]=a[k]; sp=sp+1; S[sp]=a",
  SETLIST   = [==[
      local base=marks[mp]; mp=mp-1
      local t=S[base]
      local n=sp-base
      for i=1,n do t[ins[2]+i-1]=S[base+i]; S[base+i]=nil end
      S[base]=nil; sp=base-1]==],
  GETVARARG = "sp=sp+1; S[sp]=va[ins[2]]",
  -- micro-ops: dynamic global access by a key that is on the stack
  KENV      = "S[sp]=ENV[S[sp]]",
  KENVSET   = "local k=S[sp]; local v=S[sp-1]; S[sp]=nil; S[sp-1]=nil; sp=sp-2; ENV[k]=v",
}

return M
