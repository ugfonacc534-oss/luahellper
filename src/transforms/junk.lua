-- junk.lua : sprinkle harmless dead locals with confusing names between
-- statements. Inserted vars are never referenced, so semantics are preserved.
local M={}

local function junkExpr(rng)
  local a,b=rng(0,9999), rng(1,9999)
  local kind=rng(1,2)
  if kind==1 then
    return { kind="Binop", op="+", lhs={kind="Number",value=tostring(a)}, rhs={kind="Number",value=tostring(b)} }
  else
    return { kind="Binop", op="*", lhs={kind="Number",value=tostring(a)}, rhs={kind="Number",value=tostring(b)} }
  end
end

local processBlock

local function processStat(s, rng, nextName)
  local k=s.kind
  if k=="LocalFunction" or k=="FunctionDecl" then processBlock(s.func.body,rng,nextName)
  elseif k=="Function" then processBlock(s.body,rng,nextName)
  elseif k=="Do" or k=="While" or k=="NumericFor" or k=="GenericFor" then processBlock(s.body,rng,nextName)
  elseif k=="Repeat" then processBlock(s.body,rng,nextName)
  elseif k=="If" then
    for _,c in ipairs(s.clauses) do processBlock(c.body,rng,nextName) end
    if s.elsebody then processBlock(s.elsebody,rng,nextName) end
  end
end

processBlock=function(body, rng, nextName)
  -- recurse first
  for _,s in ipairs(body) do processStat(s,rng,nextName) end
  -- splice junk (build new list)
  local out={}
  for _,s in ipairs(body) do
    if rng(1,100) <= 35 then
      out[#out+1]={ kind="LocalAssign", names={nextName()}, values={ junkExpr(rng) } }
    end
    out[#out+1]=s
  end
  for i=1,#out do body[i]=out[i] end
  for i=#out+1,#body do body[i]=nil end
end

function M.apply(ast, rng, nextName)
  processBlock(ast.body, rng, nextName)
end
return M
