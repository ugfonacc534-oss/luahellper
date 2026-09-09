-- flatten.lua : control-flow flattening (conservative & correctness-first).
-- A run of consecutive "simple" statements (no control flow / return) inside
-- a block is replaced by a dispatcher: a while loop driven by a state var that
-- executes the original statements in a scrambled case order. Semantics are
-- preserved because only straight-line code is reordered behind the dispatcher.
local M={}

-- NOTE: LocalAssign is intentionally excluded: wrapping a `local` in a
-- dispatcher if-block would scope it to that block, hiding it from later steps.
local SIMPLE={ Assign=true, CallStat=true, CompoundAssign=true }

local processBlock

-- turn a list of simple statements into one flattened While dispatcher
local function buildDispatcher(seq, rng, nextName)
  local n=#seq
  -- assign a random distinct label to each step, preserving execution order
  local order={}                    -- order[step] = label
  do
    local labels={}
    for i=1,n do labels[i]=i end
    -- shuffle labels
    for i=n,2,-1 do local j=rng(1,i); labels[i],labels[j]=labels[j],labels[i] end
    for i=1,n do order[i]=labels[i] end
  end
  local sv=nextName()
  -- next-label lookup: after executing step i, go to order[i+1] (or 0 to stop)
  local clauses={}
  for step=1,n do
    local label=order[step]
    local nextLabel = step<n and order[step+1] or 0
    local body={}
    for _,st in ipairs(seq[step]==nil and {} or {seq[step]}) do body[#body+1]=st end
    -- set state to next
    body[#body+1]={ kind="Assign",
      targets={ {kind="Name", name=sv} },
      values ={ {kind="Number", value=tostring(nextLabel)} } }
    clauses[#clauses+1]={
      cond={ kind="Binop", op="==", lhs={kind="Name",name=sv}, rhs={kind="Number",value=tostring(label)} },
      body=body }
  end
  local whileStat={
    kind="While",
    cond={ kind="Binop", op="~=", lhs={kind="Name",name=sv}, rhs={kind="Number",value="0"} },
    body={ { kind="If", clauses=clauses, elsebody={ {kind="Break"} } } },
  }
  local init={ kind="LocalAssign", names={sv}, values={ {kind="Number", value=tostring(order[1])} } }
  return { init, whileStat }
end

processBlock=function(body, rng, nextName)
  -- recurse into nested blocks first
  for _,s in ipairs(body) do
    local k=s.kind
    if k=="LocalFunction" or k=="FunctionDecl" then processBlock(s.func.body,rng,nextName)
    elseif k=="Do" or k=="While" or k=="NumericFor" or k=="GenericFor" or k=="Repeat" then processBlock(s.body,rng,nextName)
    elseif k=="If" then
      for _,c in ipairs(s.clauses) do processBlock(c.body,rng,nextName) end
      if s.elsebody then processBlock(s.elsebody,rng,nextName) end
    end
    if s.kind=="Function" then processBlock(s.body,rng,nextName) end
  end
  -- collect maximal simple runs and flatten those of length>=3
  local out={}
  local i=1
  while i<=#body do
    if SIMPLE[body[i].kind] then
      local run={}
      while i<=#body and SIMPLE[body[i].kind] do run[#run+1]=body[i]; i=i+1 end
      if #run>=3 then
        for _,st in ipairs(buildDispatcher(run,rng,nextName)) do out[#out+1]=st end
      else
        for _,st in ipairs(run) do out[#out+1]=st end
      end
    else
      out[#out+1]=body[i]; i=i+1
    end
  end
  for j=1,#out do body[j]=out[j] end
  for j=#out+1,#body do body[j]=nil end
end

function M.apply(ast, rng, nextName)
  processBlock(ast.body, rng, nextName)
end
return M
