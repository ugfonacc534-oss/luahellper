-- emitter.lua : AST -> Luau source string.
-- Conservative: wraps binary/unary ops in parens so precedence is always safe.
local M={}

local function quote(s)
  -- produce a safe double-quoted Lua string literal from raw bytes
  local out={"\""}
  for i=1,#s do
    local b=s:byte(i)
    local c=s:sub(i,i)
    if c=="\"" then out[#out+1]="\\\""
    elseif c=="\\" then out[#out+1]="\\\\"
    elseif c=="\n" then out[#out+1]="\\n"
    elseif c=="\r" then out[#out+1]="\\r"
    elseif c=="\t" then out[#out+1]="\\t"
    elseif b<32 or b>126 then out[#out+1]=("\\%03d"):format(b)  -- 3 digits: unambiguous
    else out[#out+1]=c end
  end
  out[#out+1]="\""
  return table.concat(out)
end
M.quote=quote

local Emitter={}
Emitter.__index=Emitter
local function new() return setmetatable({buf={}},Emitter) end
function Emitter:w(s) self.buf[#self.buf+1]=s end

local KW_IDENT = "^[%a_][%w_]*$"
local RESERVED = {}
for _,k in ipairs({"and","break","do","else","elseif","end","false","for","function","if","in","local","nil","not","or","repeat","return","then","true","until","while"}) do RESERVED[k]=true end

local emitExpr, emitBlock, emitStat

function Emitter:exprList(list)
  for i,e in ipairs(list) do
    if i>1 then self:w(",") end
    emitExpr(self,e)
  end
end

emitExpr=function(self,e)
  local k=e.kind
  if k=="Nil" then self:w("nil")
  elseif k=="True" then self:w("true")
  elseif k=="False" then self:w("false")
  elseif k=="Vararg" then self:w("...")
  elseif k=="Number" then self:w(e.value)
  elseif k=="String" then self:w(quote(e.value))
  elseif k=="Name" then self:w(e.name)
  elseif k=="Paren" then self:w("("); emitExpr(self,e.expr); self:w(")")
  elseif k=="Dot" then emitExpr(self,e.obj); self:w("."); self:w(e.name)
  elseif k=="Index" then emitExpr(self,e.obj); self:w("["); emitExpr(self,e.key); self:w("]")
  elseif k=="Call" then
    emitExpr(self,e.func); self:w("("); self:exprList(e.args); self:w(")")
  elseif k=="MethodCall" then
    emitExpr(self,e.obj); self:w(":"); self:w(e.method); self:w("("); self:exprList(e.args); self:w(")")
  elseif k=="Binop" then
    self:w("("); emitExpr(self,e.lhs); self:w(" "..e.op.." "); emitExpr(self,e.rhs); self:w(")")
  elseif k=="Unop" then
    self:w("("); self:w(e.op=="not" and "not " or e.op); emitExpr(self,e.expr); self:w(")")
  elseif k=="Function" then
    self:w("function("); self:params(e); self:w(")"); emitBlock(self,e.body); self:w("end")
  elseif k=="Table" then
    self:w("{")
    for i,f in ipairs(e.fields) do
      if i>1 then self:w(",") end
      if f.type=="item" then emitExpr(self,f.value)
      elseif f.type=="named" then
        if f.key:match(KW_IDENT) and not RESERVED[f.key] then self:w(f.key)
        else self:w("["); self:w(quote(f.key)); self:w("]") end
        self:w("="); emitExpr(self,f.value)
      else self:w("["); emitExpr(self,f.key); self:w("]="); emitExpr(self,f.value) end
    end
    self:w("}")
  elseif k=="Interp" then
    -- rebuild as ("..."):format-free concat: (a)..(b) ; safe & preserves order
    -- Represent as string.__concat chain guarded by tostring
    self:w("(")
    local first=true
    for _,p in ipairs(e.parts) do
      if p.str~=nil then
        if p.str~="" then
          if not first then self:w("..") end
          self:w(quote(p.str)); first=false
        end
      else
        if not first then self:w("..") end
        self:w("tostring("); emitExpr(self,p.expr); self:w(")"); first=false
      end
    end
    if first then self:w("\"\"") end
    self:w(")")
  else error("emit: unknown expr kind "..tostring(k)) end
end

function Emitter:params(fn)
  for i,p in ipairs(fn.params) do
    if i>1 then self:w(",") end
    self:w(p)
  end
  if fn.isVararg then
    if #fn.params>0 then self:w(",") end
    self:w("...")
  end
end

emitStat=function(self,s)
  local k=s.kind
  if k=="LocalAssign" then
    self:w("local "); self:w(table.concat(s.names,","))
    if s.values and #s.values>0 then self:w("="); self:exprList(s.values) end
  elseif k=="LocalFunction" then
    self:w("local function "); self:w(s.name); self:w("(")
    self:params(s.func); self:w(")"); emitBlock(self,s.func.body); self:w("end")
  elseif k=="FunctionDecl" then
    self:w("function "); emitExpr(self,s.target); self:w("(")
    self:params(s.func); self:w(")"); emitBlock(self,s.func.body); self:w("end")
  elseif k=="Assign" then
    for i,t in ipairs(s.targets) do if i>1 then self:w(",") end; emitExpr(self,t) end
    self:w("="); self:exprList(s.values)
  elseif k=="CompoundAssign" then
    -- lower to plain assign: t = t <op> v   (op is +=,-=, etc.)
    local op=s.op:sub(1,#s.op-1)
    emitExpr(self,s.target); self:w("=(")
    emitExpr(self,s.target); self:w(op); emitExpr(self,s.value); self:w(")")
  elseif k=="CallStat" then emitExpr(self,s.expr)
  elseif k=="Do" then self:w("do "); emitBlock(self,s.body); self:w("end")
  elseif k=="While" then
    self:w("while "); emitExpr(self,s.cond); self:w(" do "); emitBlock(self,s.body); self:w("end")
  elseif k=="Repeat" then
    self:w("repeat "); emitBlock(self,s.body); self:w("until "); emitExpr(self,s.cond)
  elseif k=="If" then
    for i,c in ipairs(s.clauses) do
      self:w(i==1 and "if " or "elseif "); emitExpr(self,c.cond); self:w(" then "); emitBlock(self,c.body)
    end
    if s.elsebody then self:w("else "); emitBlock(self,s.elsebody) end
    self:w("end")
  elseif k=="NumericFor" then
    self:w("for "); self:w(s.var); self:w("="); emitExpr(self,s.start); self:w(",")
    emitExpr(self,s.limit)
    if s.step then self:w(","); emitExpr(self,s.step) end
    self:w(" do "); emitBlock(self,s.body); self:w("end")
  elseif k=="GenericFor" then
    self:w("for "); self:w(table.concat(s.names,",")); self:w(" in ")
    self:exprList(s.exprs); self:w(" do "); emitBlock(self,s.body); self:w("end")
  elseif k=="Return" then
    self:w("return")
    if s.exprs and #s.exprs>0 then self:w(" "); self:exprList(s.exprs) end
  elseif k=="Break" then self:w("break")
  elseif k=="Continue" then self:w("continue")
  else error("emit: unknown stat kind "..tostring(k)) end
end

emitBlock=function(self,body)
  for _,s in ipairs(body) do
    emitStat(self,s); self:w(";")
  end
end

function M.emit(ast)
  local e=new()
  emitBlock(e, ast.body)
  return table.concat(e.buf)
end
return M
