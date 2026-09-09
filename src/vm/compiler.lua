-- compiler.lua : scope-resolved AST -> VM proto tree.
-- Requires scope.resolve() to have run (Name nodes carry .binding / .global,
-- declaration sites carry their records).
local DEFAULT = require("vm.opcodes")
local Scope = require("scope")

local M={}

-- opcode map + arithmetic map for the current compile (set in M.compile).
-- Injectable so the caller can pass a per-build randomized opcode numbering.
local OP, ARITH, MICRO

-- ---- number literal -> Lua number -------------------------------------
local function parseNumber(raw)
  raw = raw:gsub("_", "")
  if raw:match("^0[bB]") then
    local n=0
    for i=3,#raw do n = n*2 + (raw:byte(i)-48) end
    return n
  end
  return tonumber(raw)
end

-- ---- FuncState ---------------------------------------------------------
local FS={}; FS.__index=FS
local function newFS(parent)
  return setmetatable({
    parent=parent, code={}, k={}, kmap={}, protos={},
    localSlot={}, nslots=0, upvalMap={}, upvals={},
    loop={}, numparams=0, isVararg=false, jumps={},
  }, FS)
end
function FS:emit(op,a,b) local ins={op,a,b}; self.code[#self.code+1]=ins; return ins end
-- emit a jump (a=label table); recorded so finalize can backpatch it even
-- though opcode numbers are aliased/randomized and not statically known.
function FS:emitJmp(name, label)
  local ins=self:emit(OP[name], label)
  self.jumps[#self.jumps+1]=ins
  return ins
end
function FS:kIndex(v)
  local key = type(v)=="string" and ("s"..v) or ("n"..tostring(v))
  local i=self.kmap[key]
  if i then return i end
  self.k[#self.k+1]=v; i=#self.k; self.kmap[key]=i; return i
end
function FS:label() return {} end
function FS:place(lbl) lbl.pc=#self.code+1 end
function FS:allocSlot() self.nslots=self.nslots+1; return self.nslots end
function FS:declareSlot(record) local s=self:allocSlot(); self.localSlot[record]=s; return s end

local function resolve(fs, record)
  if fs.localSlot[record] then return "local", fs.localSlot[record] end
  if fs.upvalMap[record] then return "upval", fs.upvalMap[record] end
  if fs.parent then
    local m, idx = resolve(fs.parent, record)
    if not m then return nil end
    fs.upvals[#fs.upvals+1] = { m=="local" and 0 or 1, idx }
    local ui=#fs.upvals
    fs.upvalMap[record]=ui
    return "upval", ui
  end
  return nil
end

-- forward decls
local compileExpr, compileBlock, compileStat, compileFunction

-- op-string -> opcode NAME (resolved to an alias number at emit time)
local function buildArith()
  return { ["+"]="ADD", ["-"]="SUB", ["*"]="MUL", ["/"]="DIV",
    ["%"]="MOD", ["^"]="POW", ["//"]="IDIV", [".."]="CONCAT",
    ["=="]="EQ", ["~="]="NE", ["<"]="LT", ["<="]="LE", [">"]="GT", [">="]="GE" }
end

local function compileOpen(fs, e)  -- push all values e can produce
  if e.kind=="Call" then compileExpr(fs, e, -1)
  elseif e.kind=="MethodCall" then compileExpr(fs, e, -1)
  elseif e.kind=="Vararg" then fs:emit(OP.PUSHVARARG, 1)
  else compileExpr(fs, e, 1) end
end

-- push exactly n values from an expression list
local function compileListFixed(fs, list, n)
  if #list==0 then for _=1,n do fs:emit(OP.PUSHNIL) end return end
  fs:emit(OP.MARK)
  for i=1,#list-1 do compileExpr(fs, list[i], 1) end
  compileOpen(fs, list[#list])
  fs:emit(OP.ADJUST, n)
end

local function compileArgs(fs, args)
  for i=1,#args-1 do compileExpr(fs, args[i], 1) end
  if #args>0 then compileOpen(fs, args[#args]) end
end

-- nres: -1 all, 0 none (statement), 1 single
compileExpr=function(fs, e, nres)
  local k=e.kind
  if k=="Nil" then fs:emit(OP.PUSHNIL)
  elseif k=="True" then fs:emit(OP.PUSHTRUE)
  elseif k=="False" then fs:emit(OP.PUSHFALSE)
  elseif k=="Number" then fs:emit(OP.PUSHK, fs:kIndex(parseNumber(e.value)))
  elseif k=="String" then fs:emit(OP.PUSHK, fs:kIndex(e.value))
  elseif k=="Vararg" then fs:emit(OP.PUSHVARARG, nres==-1 and 1 or 0)
  elseif k=="Paren" then compileExpr(fs, e.expr, 1)
  elseif k=="Name" then
    if e.global then
      if MICRO then fs:emit(OP.PUSHK, fs:kIndex(e.name)); fs:emit(OP.KENV)
      else fs:emit(OP.GETGLOBAL, fs:kIndex(e.name)) end
    else
      local m, idx = resolve(fs, e.binding)
      if not m then error("compiler: unresolved local "..tostring(e.name)) end
      fs:emit(m=="local" and OP.GETLOCAL or OP.GETUPVAL, idx)
    end
  elseif k=="Dot" then
    compileExpr(fs, e.obj, 1); fs:emit(OP.PUSHK, fs:kIndex(e.name)); fs:emit(OP.GETINDEX)
  elseif k=="Index" then
    compileExpr(fs, e.obj, 1); compileExpr(fs, e.key, 1); fs:emit(OP.GETINDEX)
  elseif k=="Call" then
    fs:emit(OP.MARK); compileExpr(fs, e.func, 1); compileArgs(fs, e.args)
    fs:emit(OP.CALL, nres)
  elseif k=="MethodCall" then
    fs:emit(OP.MARK); compileExpr(fs, e.obj, 1); fs:emit(OP.SELF, fs:kIndex(e.method))
    compileArgs(fs, e.args); fs:emit(OP.CALL, nres)
  elseif k=="Function" then
    local pi = compileFunction(fs, e)
    fs:emit(OP.CLOSURE, pi.index, pi.upvals)
  elseif k=="Table" then
    fs:emit(OP.NEWTABLE)
    local ai=1
    local nf=#e.fields
    for fi, f in ipairs(e.fields) do
      if f.type=="named" then
        fs:emit(OP.DUP); fs:emit(OP.PUSHK, fs:kIndex(f.key)); compileExpr(fs, f.value, 1); fs:emit(OP.SETINDEX)
      elseif f.type=="expr" then
        fs:emit(OP.DUP); compileExpr(fs, f.key, 1); compileExpr(fs, f.value, 1); fs:emit(OP.SETINDEX)
      else -- item
        local last = (fi==nf)
        local v=f.value
        if last and (v.kind=="Call" or v.kind=="MethodCall" or v.kind=="Vararg") then
          fs:emit(OP.DUP); fs:emit(OP.MARK); compileOpen(fs, v); fs:emit(OP.SETLIST, ai)
        else
          fs:emit(OP.DUP); fs:emit(OP.PUSHK, fs:kIndex(ai)); compileExpr(fs, v, 1); fs:emit(OP.SETINDEX)
          ai=ai+1
        end
      end
    end
  elseif k=="Binop" then
    local op=e.op
    if op=="and" then
      compileExpr(fs, e.lhs, 1); fs:emit(OP.DUP)
      local L=fs:label(); local j=fs:emitJmp('JMPIFNOT', L)
      fs:emit(OP.POP, 1); compileExpr(fs, e.rhs, 1); fs:place(L); j[2]=L
    elseif op=="or" then
      compileExpr(fs, e.lhs, 1); fs:emit(OP.DUP)
      local L=fs:label(); local j=fs:emitJmp('JMPIF', L)
      fs:emit(OP.POP, 1); compileExpr(fs, e.rhs, 1); fs:place(L); j[2]=L
    else
      local vname=ARITH[op]
      if not vname then error("compiler: unsupported binary op '"..op.."' (bitwise ops are not supported for Luau targets)") end
      compileExpr(fs, e.lhs, 1); compileExpr(fs, e.rhs, 1); fs:emit(OP[vname])
    end
  elseif k=="Interp" then
    -- lower `a{x}b` to  a .. tostring(x) .. b
    local emitted=false
    local function push(part)
      if part.str~=nil then
        if part.str=="" then return end
        fs:emit(OP.PUSHK, fs:kIndex(part.str))
      else
        fs:emit(OP.MARK); fs:emit(OP.GETGLOBAL, fs:kIndex("tostring"))
        compileExpr(fs, part.expr, 1); fs:emit(OP.CALL, 1)
      end
      if emitted then fs:emit(OP.CONCAT) else emitted=true end
    end
    for _, part in ipairs(e.parts) do push(part) end
    if not emitted then fs:emit(OP.PUSHK, fs:kIndex("")) end
  elseif k=="Unop" then
    compileExpr(fs, e.expr, 1)
    if e.op=="-" then fs:emit(OP.NEG)
    elseif e.op=="not" then fs:emit(OP.NOT)
    elseif e.op=="#" then fs:emit(OP.LEN)
    else error("compiler: unsupported unary op '"..e.op.."'") end
  else error("compiler: cannot compile expr kind "..tostring(k)) end
  -- adjust single-value contexts for multi-producers handled by caller via nres
end

-- store `value already produced by producer()` into a target expr
local function storeTarget(fs, target, producer)
  if target.kind=="Name" then
    if target.global then
      producer()
      if MICRO then fs:emit(OP.PUSHK, fs:kIndex(target.name)); fs:emit(OP.KENVSET)
      else fs:emit(OP.SETGLOBAL, fs:kIndex(target.name)) end
    else
      local m, idx = resolve(fs, target.binding)
      producer()
      fs:emit(m=="local" and OP.SETLOCAL or OP.SETUPVAL, idx)
    end
  elseif target.kind=="Dot" then
    compileExpr(fs, target.obj, 1); fs:emit(OP.PUSHK, fs:kIndex(target.name)); producer(); fs:emit(OP.SETINDEX)
  elseif target.kind=="Index" then
    compileExpr(fs, target.obj, 1); compileExpr(fs, target.key, 1); producer(); fs:emit(OP.SETINDEX)
  else error("compiler: bad assignment target "..tostring(target.kind)) end
end

compileStat=function(fs, s)
  local k=s.kind
  if k=="LocalAssign" then
    local n=#s.names
    compileListFixed(fs, s.values or {}, n)
    for i=n,1,-1 do
      local slot=fs:declareSlot(s.records[i])
      fs:emit(OP.NEWLOCAL, slot); fs:emit(OP.SETLOCAL, slot)
    end
  elseif k=="LocalFunction" then
    local slot=fs:declareSlot(s.record)
    fs:emit(OP.NEWLOCAL, slot)
    local pi=compileFunction(fs, s.func)
    fs:emit(OP.CLOSURE, pi.index, pi.upvals)
    fs:emit(OP.SETLOCAL, slot)
  elseif k=="FunctionDecl" then
    storeTarget(fs, s.target, function()
      local pi=compileFunction(fs, s.func)
      fs:emit(OP.CLOSURE, pi.index, pi.upvals)
    end)
  elseif k=="Assign" then
    local n=#s.targets
    compileListFixed(fs, s.values, n)
    -- stash values into temp cells (top is value n)
    local temps={}
    for i=n,1,-1 do local t=fs:allocSlot(); temps[i]=t; fs:emit(OP.NEWLOCAL, t); fs:emit(OP.SETLOCAL, t) end
    for i=1,n do
      storeTarget(fs, s.targets[i], function() fs:emit(OP.GETLOCAL, temps[i]) end)
    end
  elseif k=="CompoundAssign" then
    local opname=ARITH[s.op:sub(1,#s.op-1)]
    if not opname then error("compiler: bad compound op "..s.op) end
    local t=s.target
    if t.kind=="Name" then
      storeTarget(fs, t, function()
        compileExpr(fs, t, 1); compileExpr(fs, s.value, 1); fs:emit(OP[opname])
      end)
    else
      local ho=fs:allocSlot(); fs:emit(OP.NEWLOCAL, ho)
      local hk=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hk)
      compileExpr(fs, t.obj, 1); fs:emit(OP.SETLOCAL, ho)
      if t.kind=="Dot" then fs:emit(OP.PUSHK, fs:kIndex(t.name)) else compileExpr(fs, t.key, 1) end
      fs:emit(OP.SETLOCAL, hk)
      local hv=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hv)
      fs:emit(OP.GETLOCAL, ho); fs:emit(OP.GETLOCAL, hk); fs:emit(OP.GETINDEX)
      compileExpr(fs, s.value, 1); fs:emit(OP[opname]); fs:emit(OP.SETLOCAL, hv)
      fs:emit(OP.GETLOCAL, ho); fs:emit(OP.GETLOCAL, hk); fs:emit(OP.GETLOCAL, hv); fs:emit(OP.SETINDEX)
    end
  elseif k=="CallStat" then
    local e=s.expr
    if e.kind=="Call" then
      fs:emit(OP.MARK); compileExpr(fs, e.func, 1); compileArgs(fs, e.args); fs:emit(OP.CALL, 0)
    else -- MethodCall
      fs:emit(OP.MARK); compileExpr(fs, e.obj, 1); fs:emit(OP.SELF, fs:kIndex(e.method))
      compileArgs(fs, e.args); fs:emit(OP.CALL, 0)
    end
  elseif k=="Do" then compileBlock(fs, s.body)
  elseif k=="While" then
    local top=fs:label(); local done=fs:label()
    fs:place(top)
    compileExpr(fs, s.cond, 1); local j=fs:emitJmp('JMPIFNOT', done)
    fs.loop[#fs.loop+1]={brk=done, cont=top}
    compileBlock(fs, s.body)
    fs.loop[#fs.loop]=nil
    fs:emitJmp('JMP', top); fs:place(done); j[2]=done
  elseif k=="Repeat" then
    local top=fs:label(); local done=fs:label(); local cont=fs:label()
    fs:place(top)
    fs.loop[#fs.loop+1]={brk=done, cont=cont}
    compileBlock(fs, s.body)
    fs.loop[#fs.loop]=nil
    fs:place(cont)
    compileExpr(fs, s.cond, 1); fs:emitJmp('JMPIFNOT', top)  -- loop while cond false
    fs:place(done)
  elseif k=="If" then
    local done=fs:label()
    for _, c in ipairs(s.clauses) do
      local nextc=fs:label()
      compileExpr(fs, c.cond, 1); local j=fs:emitJmp('JMPIFNOT', nextc)
      compileBlock(fs, c.body)
      fs:emitJmp('JMP', done)
      fs:place(nextc); j[2]=nextc
    end
    if s.elsebody then compileBlock(fs, s.elsebody) end
    fs:place(done)
  elseif k=="NumericFor" then
    local hi=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hi)
    local hl=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hl)
    local hs=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hs)
    compileExpr(fs, s.start, 1); fs:emit(OP.SETLOCAL, hi)
    compileExpr(fs, s.limit, 1); fs:emit(OP.SETLOCAL, hl)
    if s.step then compileExpr(fs, s.step, 1) else fs:emit(OP.PUSHK, fs:kIndex(1)) end
    fs:emit(OP.SETLOCAL, hs)
    local slot=fs:declareSlot(s.varRecord)
    local top=fs:label(); local done=fs:label(); local cont=fs:label()
    local body=fs:label(); local negc=fs:label()
    fs:place(top)
    -- direction check
    fs:emit(OP.GETLOCAL, hs); fs:emit(OP.PUSHK, fs:kIndex(0)); fs:emit(OP.GE)
    local jd=fs:emitJmp('JMPIFNOT', negc)
    fs:emit(OP.GETLOCAL, hi); fs:emit(OP.GETLOCAL, hl); fs:emit(OP.GT); local je1=fs:emitJmp('JMPIF', done)
    fs:emitJmp('JMP', body)
    fs:place(negc); jd[2]=negc
    fs:emit(OP.GETLOCAL, hi); fs:emit(OP.GETLOCAL, hl); fs:emit(OP.LT); local je2=fs:emitJmp('JMPIF', done)
    fs:place(body)
    fs:emit(OP.NEWLOCAL, slot); fs:emit(OP.GETLOCAL, hi); fs:emit(OP.SETLOCAL, slot)
    fs.loop[#fs.loop+1]={brk=done, cont=cont}
    compileBlock(fs, s.body)
    fs.loop[#fs.loop]=nil
    fs:place(cont)
    fs:emit(OP.GETLOCAL, hi); fs:emit(OP.GETLOCAL, hs); fs:emit(OP.ADD); fs:emit(OP.SETLOCAL, hi)
    fs:emitJmp('JMP', top)
    fs:place(done); je1[2]=done; je2[2]=done
  elseif k=="GenericFor" then
    local hf=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hf)
    local hs=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hs)
    local hc=fs:allocSlot(); fs:emit(OP.NEWLOCAL, hc)
    compileListFixed(fs, s.exprs, 3)
    fs:emit(OP.SETLOCAL, hc); fs:emit(OP.SETLOCAL, hs); fs:emit(OP.SETLOCAL, hf) -- top is 3rd
    local nv=#s.names
    local slots={}
    for i=1,nv do slots[i]=fs:declareSlot(s.records[i]) end
    local top=fs:label(); local done=fs:label(); local cont=fs:label()
    fs:place(top)
    fs:emit(OP.MARK); fs:emit(OP.GETLOCAL, hf); fs:emit(OP.GETLOCAL, hs); fs:emit(OP.GETLOCAL, hc)
    fs:emit(OP.CALL, nv)
    for i=nv,1,-1 do fs:emit(OP.NEWLOCAL, slots[i]); fs:emit(OP.SETLOCAL, slots[i]) end
    -- if first var == nil -> break
    fs:emit(OP.GETLOCAL, slots[1]); fs:emit(OP.PUSHNIL); fs:emit(OP.EQ); local je=fs:emitJmp('JMPIF', done)
    fs:emit(OP.GETLOCAL, slots[1]); fs:emit(OP.SETLOCAL, hc)
    fs.loop[#fs.loop+1]={brk=done, cont=cont}
    compileBlock(fs, s.body)
    fs.loop[#fs.loop]=nil
    fs:place(cont)
    fs:emitJmp('JMP', top)
    fs:place(done); je[2]=done
  elseif k=="Return" then
    fs:emit(OP.MARK)
    local list=s.exprs or {}
    for i=1,#list-1 do compileExpr(fs, list[i], 1) end
    if #list>0 then compileOpen(fs, list[#list]) end
    fs:emit(OP.RET)
  elseif k=="Break" then
    local l=fs.loop[#fs.loop]; if not l then error("compiler: break outside loop") end
    fs:emitJmp('JMP', l.brk)
  elseif k=="Continue" then
    local l=fs.loop[#fs.loop]; if not l then error("compiler: continue outside loop") end
    fs:emitJmp('JMP', l.cont)
  else error("compiler: cannot compile stat kind "..tostring(k)) end
end

compileBlock=function(fs, body)
  for _, s in ipairs(body) do compileStat(fs, s) end
end

-- compile a Function AST node as a child proto of `parent`. returns {index, upvals}
compileFunction=function(parentFS, fnNode)
  local fs=newFS(parentFS)
  fs.numparams=#fnNode.params
  fs.isVararg=fnNode.isVararg and true or false
  -- bind params from varargs
  for i, rec in ipairs(fnNode.paramRecords) do
    local slot=fs:declareSlot(rec)
    fs:emit(OP.NEWLOCAL, slot); fs:emit(OP.GETVARARG, i); fs:emit(OP.SETLOCAL, slot)
  end
  compileBlock(fs, fnNode.body)
  fs:emit(OP.MARK); fs:emit(OP.RET)  -- implicit return
  local proto=fs:finalize()
  parentFS.protos[#parentFS.protos+1]=proto
  return { index=#parentFS.protos, upvals=fs.upvals }
end

-- resolve labels -> pc and produce serializable proto array
function FS:finalize()
  for _, ins in ipairs(self.jumps) do
    local lbl=ins[2]
    if type(lbl)=="table" then ins[2]=lbl.pc end
  end
  return { self.k, self.code, self.protos, self.numparams, self.isVararg and 1 or 0 }
end

-- compile whole chunk -> top proto (a vararg function)
-- opAliases: optional per-build opcode aliasing (name->{numbers}); defaults to
--   the canonical single-number-per-op map. rng picks which alias to emit.
function M.compile(ast, opAliases, rng, opts)
  MICRO = not (opts and opts.microOps == false)
  -- normalize to name->{numbers}
  local lists = {}
  local src = opAliases or DEFAULT
  for _, name in ipairs(DEFAULT.NAMES) do
    local v = src[name]
    lists[name] = (type(v)=="table") and v or { v }
  end
  local pickIdx = rng or function() return 1 end
  OP = setmetatable({}, { __index = function(_, name)
    local l = lists[name]
    return l[ #l==1 and 1 or pickIdx(1, #l) ]
  end })
  ARITH = buildArith()
  Scope.resolve(ast)
  local fs=newFS(nil)
  fs.isVararg=true
  compileBlock(fs, ast.body)
  fs:emit(OP.MARK); fs:emit(OP.RET)
  return fs:finalize()
end

M.parseNumber=parseNumber
return M
