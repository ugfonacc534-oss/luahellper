-- opcodes.lua : canonical opcode names + per-build randomization.
-- The numeric value of each opcode is NOT fixed across builds: `randomize`
-- produces a fresh name->number permutation so every obfuscated output uses a
-- different instruction set (a static VM-lifter written for one build is
-- useless against the next).
local NAMES = {
  "PUSHK","PUSHNIL","PUSHTRUE","PUSHFALSE","PUSHVARARG",
  "POP","DUP",
  "NEWLOCAL","GETLOCAL","SETLOCAL",
  "GETUPVAL","SETUPVAL",
  "GETGLOBAL","SETGLOBAL",
  "NEWTABLE","GETINDEX","SETINDEX",
  "ADD","SUB","MUL","DIV","MOD","POW","IDIV","CONCAT",
  "EQ","NE","LT","LE","GT","GE",
  "NOT","NEG","LEN",
  "JMP","JMPIF","JMPIFNOT",
  "MARK","CALL","ADJUST","RET",
  "CLOSURE","SELF","SETLIST","GETVARARG",
  -- micro-ops (composite global access split into primitive stack steps)
  "KENV","KENVSET",
}

local M = { NAMES = NAMES }

-- canonical map (name -> stable index), used for in-repo defaults/tests
for i, n in ipairs(NAMES) do M[n] = i end

-- produce a randomized alias map name->{numbers}. Each opcode gets 1..maxDup
-- distinct random numbers; all aliases of one opcode run the same handler, so
-- the compiler can emit any of them interchangeably. This defeats frequency
-- analysis of the bytecode and bloats the dispatch with decoys.
function M.randomize(rng, maxDup)
  maxDup = maxDup or 3
  local map = {}
  local used = {}
  local function fresh()
    local v
    repeat v = rng(1, 60000) until not used[v]
    used[v] = true
    return v
  end
  for _, n in ipairs(NAMES) do
    local dup = rng(1, maxDup)
    local l = {}
    for _=1,dup do l[#l+1]=fresh() end
    map[n]=l
  end
  return map
end

return M
