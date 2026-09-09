-- numbers.lua : rewrite integer literals as small arithmetic expressions.
-- Floats / hex / exponent literals are left untouched (precision safety).
local Walk=require("walk")
local M={}

local function num(v) return { kind="Number", value=tostring(v) } end

function M.apply(ast, rng)
  Walk.exprs(ast, function(e)
    if e.kind=="Number" and not e._done then
      local raw=e.value
      -- only plain base-10 integers
      if raw:match("^%d+$") then
        local n=tonumber(raw)
        if n and n<2^40 then
          local a=rng(0, math.max(1, n)+50)
          local variant=rng(1,3)
          local node
          if variant==1 then      -- (a)+(n-a)
            node={ kind="Binop", op="+", lhs=num(a), rhs=num(n-a) }
          elseif variant==2 then  -- (a)-(a-n)
            node={ kind="Binop", op="-", lhs=num(a), rhs=num(a-n) }
          else                    -- (n+a)-(a)
            node={ kind="Binop", op="-", lhs=num(n+a), rhs=num(a) }
          end
          node.lhs._done=true; node.rhs._done=true
          for k in pairs(e) do e[k]=nil end
          for k,v in pairs(node) do e[k]=v end
          e._done=true
        end
      end
    end
  end)
end
return M
