-- rename.lua : give every local/param a confusing unique identifier.
-- Relies on scope records (record.refs) + declaration sites carrying records.
local M={}

-- rewrite declaration string arrays from records
local walkStat, walkBlock, walkExpr
walkExpr=function(e)
  local k=e.kind
  if k=="Name" then
    if e.binding and e.binding.newName then e.name=e.binding.newName end
  elseif k=="Dot" then walkExpr(e.obj)
  elseif k=="Index" then walkExpr(e.obj); walkExpr(e.key)
  elseif k=="Call" then walkExpr(e.func); for _,a in ipairs(e.args) do walkExpr(a) end
  elseif k=="MethodCall" then walkExpr(e.obj); for _,a in ipairs(e.args) do walkExpr(a) end
  elseif k=="Binop" then walkExpr(e.lhs); walkExpr(e.rhs)
  elseif k=="Unop" then walkExpr(e.expr)
  elseif k=="Paren" then walkExpr(e.expr)
  elseif k=="Table" then
    for _,f in ipairs(e.fields) do if f.type=="expr" then walkExpr(f.key) end; walkExpr(f.value) end
  elseif k=="Interp" then for _,p in ipairs(e.parts) do if p.expr then walkExpr(p.expr) end end
  elseif k=="Function" then
    if e.paramRecords then for i,r in ipairs(e.paramRecords) do if r.newName then e.params[i]=r.newName end end end
    walkBlock(e.body)
  end
end

walkStat=function(s)
  local k=s.kind
  if k=="LocalAssign" then
    for _,v in ipairs(s.values or {}) do walkExpr(v) end
    if s.records then for i,r in ipairs(s.records) do if r.newName then s.names[i]=r.newName end end end
  elseif k=="LocalFunction" then
    if s.record and s.record.newName then s.name=s.record.newName end
    if s.func.paramRecords then for i,r in ipairs(s.func.paramRecords) do if r.newName then s.func.params[i]=r.newName end end end
    walkBlock(s.func.body)
  elseif k=="FunctionDecl" then
    walkExpr(s.target)
    if s.func.paramRecords then for i,r in ipairs(s.func.paramRecords) do if r.newName then s.func.params[i]=r.newName end end end
    walkBlock(s.func.body)
  elseif k=="Assign" then
    for _,t in ipairs(s.targets) do walkExpr(t) end
    for _,v in ipairs(s.values) do walkExpr(v) end
  elseif k=="CompoundAssign" then walkExpr(s.target); walkExpr(s.value)
  elseif k=="CallStat" then walkExpr(s.expr)
  elseif k=="Do" then walkBlock(s.body)
  elseif k=="While" then walkExpr(s.cond); walkBlock(s.body)
  elseif k=="Repeat" then walkBlock(s.body); walkExpr(s.cond)
  elseif k=="If" then
    for _,c in ipairs(s.clauses) do walkExpr(c.cond); walkBlock(c.body) end
    if s.elsebody then walkBlock(s.elsebody) end
  elseif k=="NumericFor" then
    walkExpr(s.start); walkExpr(s.limit); if s.step then walkExpr(s.step) end
    if s.varRecord and s.varRecord.newName then s.var=s.varRecord.newName end
    walkBlock(s.body)
  elseif k=="GenericFor" then
    for _,e in ipairs(s.exprs) do walkExpr(e) end
    if s.records then for i,r in ipairs(s.records) do if r.newName then s.names[i]=r.newName end end end
    walkBlock(s.body)
  elseif k=="Return" then for _,e in ipairs(s.exprs or {}) do walkExpr(e) end
  end
end
walkBlock=function(b) for _,s in ipairs(b) do walkStat(s) end end

function M.apply(ast, records, nextName)
  for _,r in ipairs(records) do r.newName=nextName() end
  walkBlock(ast.body)
end
return M
