-- scope.lua : resolve every Name node to its local declaration record, or
-- leave it as a global. Declaration sites get `.records` / `.record` attached.
-- A record = { orig=<name>, newName=nil, refs={<Name nodes>} }
local M={}

local function newRecord(name)
  return { orig=name, refs={} }
end

local Resolver={}
Resolver.__index=Resolver
local function new()
  return setmetatable({ frame={ vars={}, parent=nil }, records={} }, Resolver)
end
function Resolver:push() self.frame={ vars={}, parent=self.frame } end
function Resolver:pop() self.frame=self.frame.parent end
function Resolver:declare(name)
  local r=newRecord(name)
  self.frame.vars[name]=r
  self.records[#self.records+1]=r
  return r
end
function Resolver:lookup(name)
  local f=self.frame
  while f do local r=f.vars[name]; if r then return r end; f=f.parent end
  return nil
end

local visitExpr, visitStat, visitBlock

function Resolver:exprList(l) for _,e in ipairs(l) do visitExpr(self,e) end end

visitExpr=function(self,e)
  local k=e.kind
  if k=="Name" then
    local r=self:lookup(e.name)
    if r then e.binding=r; r.refs[#r.refs+1]=e else e.global=true end
  elseif k=="Dot" then visitExpr(self,e.obj) -- .name is a field, not a var
  elseif k=="Index" then visitExpr(self,e.obj); visitExpr(self,e.key)
  elseif k=="Call" then visitExpr(self,e.func); self:exprList(e.args)
  elseif k=="MethodCall" then visitExpr(self,e.obj); self:exprList(e.args)
  elseif k=="Binop" then visitExpr(self,e.lhs); visitExpr(self,e.rhs)
  elseif k=="Unop" then visitExpr(self,e.expr)
  elseif k=="Paren" then visitExpr(self,e.expr)
  elseif k=="Table" then
    for _,f in ipairs(e.fields) do
      if f.type=="expr" then visitExpr(self,f.key) end
      visitExpr(self,f.value)
    end
  elseif k=="Interp" then
    for _,p in ipairs(e.parts) do if p.expr then visitExpr(self,p.expr) end end
  elseif k=="Function" then
    self:push()
    e.paramRecords={}
    for i,p in ipairs(e.params) do e.paramRecords[i]=self:declare(p) end
    visitBlock(self,e.body)
    self:pop()
  end
  -- literals: nothing
end

visitStat=function(self,s)
  local k=s.kind
  if k=="LocalAssign" then
    self:exprList(s.values or {})            -- values see the OLD bindings
    s.records={}
    for i,n in ipairs(s.names) do s.records[i]=self:declare(n) end
  elseif k=="LocalFunction" then
    s.record=self:declare(s.name)            -- visible inside body (recursion)
    self:push()
    s.func.paramRecords={}
    for i,p in ipairs(s.func.params) do s.func.paramRecords[i]=self:declare(p) end
    visitBlock(self,s.func.body)
    self:pop()
  elseif k=="FunctionDecl" then
    visitExpr(self,s.target)                 -- resolves base Name (may be local or global)
    self:push()
    s.func.paramRecords={}
    for i,p in ipairs(s.func.params) do s.func.paramRecords[i]=self:declare(p) end
    visitBlock(self,s.func.body)
    self:pop()
  elseif k=="Assign" then
    for _,t in ipairs(s.targets) do visitExpr(self,t) end
    self:exprList(s.values)
  elseif k=="CompoundAssign" then visitExpr(self,s.target); visitExpr(self,s.value)
  elseif k=="CallStat" then visitExpr(self,s.expr)
  elseif k=="Do" then self:push(); visitBlock(self,s.body); self:pop()
  elseif k=="While" then visitExpr(self,s.cond); self:push(); visitBlock(self,s.body); self:pop()
  elseif k=="Repeat" then
    self:push(); visitBlock(self,s.body); visitExpr(self,s.cond); self:pop() -- until sees body locals
  elseif k=="If" then
    for _,c in ipairs(s.clauses) do
      visitExpr(self,c.cond); self:push(); visitBlock(self,c.body); self:pop()
    end
    if s.elsebody then self:push(); visitBlock(self,s.elsebody); self:pop() end
  elseif k=="NumericFor" then
    visitExpr(self,s.start); visitExpr(self,s.limit); if s.step then visitExpr(self,s.step) end
    self:push(); s.varRecord=self:declare(s.var); visitBlock(self,s.body); self:pop()
  elseif k=="GenericFor" then
    self:exprList(s.exprs)
    self:push(); s.records={}
    for i,n in ipairs(s.names) do s.records[i]=self:declare(n) end
    visitBlock(self,s.body); self:pop()
  elseif k=="Return" then self:exprList(s.exprs or {})
  end
end

visitBlock=function(self,body) for _,s in ipairs(body) do visitStat(self,s) end end

function M.resolve(ast)
  local r=new()
  visitBlock(r, ast.body)
  return r.records   -- flat list of all local declaration records
end
return M
