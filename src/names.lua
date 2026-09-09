-- names.lua : a single factory of globally-unique confusable identifiers.
-- Sharing one factory across rename/junk/flatten guarantees no generated
-- name ever collides with another (which would cause accidental shadowing).
local M={}
local ALPHA={"I","l","i","o","O"}          -- valid identifier start
local REST ={"I","l","i","o","O","0","1"}
function M.new()
  local n=0
  local seen={}
  return function()
    while true do
      n=n+1
      local x=n
      local s=ALPHA[(x % #ALPHA)+1]; x=math.floor(x/#ALPHA)
      while x>0 do s=s..REST[(x % #REST)+1]; x=math.floor(x/#REST) end
      if #s<4 then s=s..string.rep("l",4-#s) end
      if not seen[s] then seen[s]=true; return s end
    end
  end
end
return M
