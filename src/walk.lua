-- walk.lua : generic AST traversal. Calls visit(node) on every expression
-- node (pre-order). In-place mutation of a node's fields is supported.
local M={}
local walkExpr, walkBlock, walkStat

function M.exprs(ast, visit)
  local function E(e) if e then visit(e); walkExpr(e,visit) end end
  local function L(l) if l then for _,e in ipairs(l) do E(e) end end end
  walkExpr=function(e,visit)
    local k=e.kind
    if k=="Dot" then E(e.obj)
    elseif k=="Index" then E(e.obj); E(e.key)
    elseif k=="Call" then E(e.func); L(e.args)
    elseif k=="MethodCall" then E(e.obj); L(e.args)
    elseif k=="Binop" then E(e.lhs); E(e.rhs)
    elseif k=="Unop" then E(e.expr)
    elseif k=="Paren" then E(e.expr)
    elseif k=="Table" then
      for _,f in ipairs(e.fields) do if f.type=="expr" then E(f.key) end; E(f.value) end
    elseif k=="Interp" then for _,p in ipairs(e.parts) do if p.expr then E(p.expr) end end
    elseif k=="Function" then walkBlock(e.body,visit)
    end
  end
  walkStat=function(s,visit)
    local k=s.kind
    if k=="LocalAssign" then L(s.values)
    elseif k=="LocalFunction" then walkBlock(s.func.body,visit)
    elseif k=="FunctionDecl" then E(s.target); walkBlock(s.func.body,visit)
    elseif k=="Assign" then L(s.targets); L(s.values)
    elseif k=="CompoundAssign" then E(s.target); E(s.value)
    elseif k=="CallStat" then E(s.expr)
    elseif k=="Do" then walkBlock(s.body,visit)
    elseif k=="While" then E(s.cond); walkBlock(s.body,visit)
    elseif k=="Repeat" then walkBlock(s.body,visit); E(s.cond)
    elseif k=="If" then
      for _,c in ipairs(s.clauses) do E(c.cond); walkBlock(c.body,visit) end
      if s.elsebody then walkBlock(s.elsebody,visit) end
    elseif k=="NumericFor" then E(s.start); E(s.limit); if s.step then E(s.step) end; walkBlock(s.body,visit)
    elseif k=="GenericFor" then L(s.exprs); walkBlock(s.body,visit)
    elseif k=="Return" then L(s.exprs)
    end
  end
  walkBlock=function(b,visit) for _,s in ipairs(b) do walkStat(s,visit) end end
  walkBlock(ast.body, visit)
end
return M
