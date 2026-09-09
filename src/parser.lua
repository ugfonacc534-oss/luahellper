-- parser.lua : token stream -> AST (Luau). Type annotations are stripped.
local Lexer = require("lexer")

local Parser = {}
Parser.__index = Parser

-- ---- string escape decoding: raw source token -> actual bytes ----------
local ESC = { a="\a", b="\b", f="\f", n="\n", r="\r", t="\t", v="\v",
              ["\\"]="\\", ["\""]="\"", ["'"]="'", ["\n"]="\n" }
local function decodeString(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i,i)
    if c == "\\" then
      local d = s:sub(i+1,i+1)
      if ESC[d] then out[#out+1]=ESC[d]; i=i+2
      elseif d == "z" then
        i=i+2; while i<=n and s:sub(i,i):match("%s") do i=i+1 end
      elseif d == "x" then
        out[#out+1]=string.char(tonumber(s:sub(i+2,i+3),16) or 0); i=i+4
      elseif d:match("%d") then
        local num=s:sub(i+1):match("^%d%d?%d?"); out[#out+1]=string.char(tonumber(num)%256); i=i+1+#num
      elseif d == "u" then
        local hex = s:sub(i+3):match("^[0-9a-fA-F]+")
        local cp = tonumber(hex,16) or 0
        -- utf8 encode
        if utf8 and utf8.char then out[#out+1]=utf8.char(cp) else out[#out+1]="?" end
        i = i + 3 + #hex + 1 -- \u{...}
      else out[#out+1]=d; i=i+2 end
    else out[#out+1]=c; i=i+1 end
  end
  return table.concat(out)
end

function Parser.new(toks)
  return setmetatable({ toks=toks, i=1 }, Parser)
end

function Parser:cur() return self.toks[self.i] end
function Parser:nxt() return self.toks[self.i+1] end
function Parser:err(m)
  local t=self:cur(); error(("parser:%d: %s (got %s '%s')"):format(t.line, m, t.type, t.value),0)
end
function Parser:adv() local t=self.toks[self.i]; self.i=self.i+1; return t end
function Parser:is(ty,val)
  local t=self:cur()
  if t.type~=ty then return false end
  if val~=nil and t.value~=val then return false end
  return true
end
function Parser:isKw(v) return self:is("keyword",v) end
function Parser:isSym(v) return self:is("symbol",v) end
function Parser:accept(ty,val) if self:is(ty,val) then return self:adv() end end
function Parser:expect(ty,val)
  if not self:is(ty,val) then self:err("expected "..ty.." "..(val or "")) end
  return self:adv()
end
-- a "name" including contextual keywords used as identifiers
function Parser:expectName()
  local t=self:cur()
  if t.type=="name" then return self:adv().value end
  self:err("expected name")
end

-- =========================================================================
-- TYPE SKIPPING
-- =========================================================================
-- consume a balanced bracket group starting at the current ( { or [ token.
function Parser:skipBalanced()
  local depth=0
  repeat
    local t=self:cur()
    if t.type=="eof" then self:err("unterminated type bracket") end
    if t.type=="symbol" then
      local v=t.value
      if v=="(" or v=="{" or v=="[" then depth=depth+1
      elseif v==")" or v=="}" or v=="]" then depth=depth-1 end
    end
    self:adv()
  until depth==0
end

-- consume exactly one type atom (before |, &, ?, -> post-operators)
function Parser:skipTypeAtom()
  local t=self:cur()
  if t.type=="symbol" then
    local v=t.value
    if v=="(" or v=="{" or v=="[" then self:skipBalanced(); return end
    if v=="..." then self:adv(); return end
    return -- nothing recognizable; let caller stop
  elseif t.type=="string" or t.type=="number" then
    self:adv(); return
  elseif t.type=="keyword" then
    if t.value=="nil" or t.value=="true" or t.value=="false" then self:adv(); return end
    if t.value=="function" then self:adv(); return end
    return
  elseif t.type=="name" then
    self:adv()
    -- typeof(...) or any name directly followed by a call-like group
    if self:isSym("(") then self:skipBalanced() end
    while self:isSym(".") do self:adv(); if self:cur().type=="name" then self:adv() end end
    if self:isSym("<") then self:skipGenerics() end
    return
  end
end

-- skip a full type expression: atom { (?|&|->) ... }
function Parser:skipType()
  self:skipTypeAtom()
  while true do
    if self:isSym("?") then self:adv()
    elseif self:isSym("|") or self:isSym("&") then self:adv(); self:skipTypeAtom()
    elseif self:isSym("->") then self:adv(); self:skipType(); return
    else break end
  end
end

-- optional ": type"
function Parser:skipTypeAnnot()
  if self:isSym(":") then self:adv(); self:skipType() end
end
-- optional generic "<...>" after a name in decl positions
function Parser:skipGenerics()
  if self:isSym("<") then
    self:adv()
    local depth=1
    while depth>0 do
      local t=self:cur()
      if t.type=="eof" then self:err("unterminated generics") end
      if t.type=="symbol" then
        if t.value=="<" then depth=depth+1
        elseif t.value==">" then depth=depth-1
        elseif t.value==">>" then depth=depth-2
        elseif t.value==">=" then depth=depth-1 end
      end
      self:adv()
    end
  end
end

-- =========================================================================
-- STATEMENTS
-- =========================================================================
function Parser:parseChunk()
  local body=self:parseBlock()
  self:expect("eof")
  return { kind="Block", body=body }
end

local BLOCK_END = { ["end"]=true, ["else"]=true, ["elseif"]=true, ["until"]=true }

function Parser:parseBlock()
  local body={}
  while true do
    local t=self:cur()
    if t.type=="eof" then break end
    if t.type=="keyword" and BLOCK_END[t.value] then break end
    if t.type=="keyword" and t.value=="return" then
      body[#body+1]=self:parseReturn(); break
    end
    local st=self:parseStatement()
    if st then body[#body+1]=st end
  end
  return body
end

function Parser:parseReturn()
  self:adv() -- return
  local exprs={}
  local t=self:cur()
  local stop = (t.type=="eof") or (t.type=="keyword" and BLOCK_END[t.value]) or self:isSym(";")
  if not stop then exprs=self:parseExprList() end
  self:accept("symbol",";")
  return { kind="Return", exprs=exprs }
end

function Parser:parseStatement()
  local t=self:cur()
  if t.type=="symbol" and t.value==";" then self:adv(); return nil end
  if t.type=="keyword" then
    local v=t.value
    if v=="local" then return self:parseLocal() end
    if v=="if" then return self:parseIf() end
    if v=="while" then return self:parseWhile() end
    if v=="for" then return self:parseFor() end
    if v=="repeat" then return self:parseRepeat() end
    if v=="do" then self:adv(); local b=self:parseBlock(); self:expect("keyword","end"); return {kind="Do",body=b} end
    if v=="function" then return self:parseFunctionStat() end
    if v=="break" then self:adv(); return {kind="Break"} end
  end
  -- contextual: continue / type / export type
  if t.type=="name" then
    if t.value=="continue" then
      -- only a statement if next token ends the statement context
      local n=self:nxt()
      if n and (n.type=="eof" or (n.type=="keyword" and BLOCK_END[n.value]) or (n.type=="symbol" and n.value==";")) then
        self:adv(); return {kind="Continue"}
      end
    elseif t.value=="type" and self:nxt() and self:nxt().type=="name" then
      return self:parseTypeAlias(false)
    elseif t.value=="export" and self:nxt() and self:nxt().type=="name" and self:nxt().value=="type" then
      self:adv(); return self:parseTypeAlias(true)
    end
  end
  return self:parseExprStatement()
end

function Parser:parseTypeAlias()
  self:adv()               -- 'type'
  self:expectName()        -- alias name
  self:skipGenerics()
  self:expect("symbol","=")
  self:skipType()
  return nil               -- drop type aliases entirely
end

function Parser:parseLocal()
  self:adv() -- local
  if self:isKw("function") then
    self:adv()
    local name=self:expectName()
    local fn=self:parseFuncBody(false)
    return { kind="LocalFunction", name=name, func=fn }
  end
  local names={}
  repeat
    local nm=self:expectName()
    if self:isSym("<") then self:skipGenerics() end -- attribute <const>/<close> or generic; skip
    self:skipTypeAnnot()
    names[#names+1]=nm
  until not self:accept("symbol",",")
  local values={}
  if self:accept("symbol","=") then values=self:parseExprList() end
  return { kind="LocalAssign", names=names, values=values }
end

function Parser:parseIf()
  self:adv()
  local clauses={}
  local cond=self:parseExpr(); self:expect("keyword","then")
  clauses[1]={cond=cond, body=self:parseBlock()}
  while self:isKw("elseif") do
    self:adv()
    local c=self:parseExpr(); self:expect("keyword","then")
    clauses[#clauses+1]={cond=c, body=self:parseBlock()}
  end
  local elsebody=nil
  if self:isKw("else") then self:adv(); elsebody=self:parseBlock() end
  self:expect("keyword","end")
  return { kind="If", clauses=clauses, elsebody=elsebody }
end

function Parser:parseWhile()
  self:adv()
  local cond=self:parseExpr(); self:expect("keyword","do")
  local b=self:parseBlock(); self:expect("keyword","end")
  return { kind="While", cond=cond, body=b }
end

function Parser:parseRepeat()
  self:adv()
  local b=self:parseBlock(); self:expect("keyword","until")
  local cond=self:parseExpr()
  return { kind="Repeat", body=b, cond=cond }
end

function Parser:parseFor()
  self:adv()
  local first=self:expectName()
  self:skipTypeAnnot()
  if self:isSym("=") then
    self:adv()
    local a=self:parseExpr(); self:expect("symbol",",")
    local b=self:parseExpr()
    local c=nil
    if self:accept("symbol",",") then c=self:parseExpr() end
    self:expect("keyword","do"); local body=self:parseBlock(); self:expect("keyword","end")
    return { kind="NumericFor", var=first, start=a, limit=b, step=c, body=body }
  end
  local names={first}
  while self:accept("symbol",",") do
    names[#names+1]=self:expectName(); self:skipTypeAnnot()
  end
  self:expect("keyword","in")
  local exprs=self:parseExprList()
  self:expect("keyword","do"); local body=self:parseBlock(); self:expect("keyword","end")
  return { kind="GenericFor", names=names, exprs=exprs, body=body }
end

function Parser:parseFunctionStat()
  self:adv() -- function
  -- name path: Name {.Name} [:Name]
  local base={ kind="Name", name=self:expectName() }
  local isMethod=false
  while self:isSym(".") do
    self:adv(); base={ kind="Dot", obj=base, name=self:expectName() }
  end
  if self:isSym(":") then
    self:adv(); base={ kind="Dot", obj=base, name=self:expectName() }; isMethod=true
  end
  local fn=self:parseFuncBody(isMethod)
  return { kind="FunctionDecl", target=base, func=fn }
end

-- parse "(params) ... body end"  -> Function expr node
function Parser:parseFuncBody(isMethod)
  self:skipGenerics()
  self:expect("symbol","(")
  local params={}
  local isVararg=false
  if isMethod then params[1]="self" end
  if not self:isSym(")") then
    repeat
      if self:isSym("...") then self:adv(); self:skipTypeAnnot(); isVararg=true; break end
      params[#params+1]=self:expectName()
      self:skipTypeAnnot()
    until not self:accept("symbol",",")
  end
  self:expect("symbol",")")
  self:skipTypeAnnot()  -- return type
  local body=self:parseBlock()
  self:expect("keyword","end")
  return { kind="Function", params=params, isVararg=isVararg, body=body, isMethod=isMethod }
end

-- expression statement: assignment or call
function Parser:parseExprStatement()
  local e=self:parseSuffixed()
  if self:isSym("=") or self:isSym(",") then
    local targets={e}
    while self:accept("symbol",",") do targets[#targets+1]=self:parseSuffixed() end
    self:expect("symbol","=")
    local values=self:parseExprList()
    return { kind="Assign", targets=targets, values=values }
  end
  -- compound assignment
  local t=self:cur()
  if t.type=="symbol" and (t.value=="+=" or t.value=="-=" or t.value=="*=" or t.value=="/=" or t.value=="//=" or t.value=="%=" or t.value=="^=" or t.value=="..=") then
    self:adv()
    local rhs=self:parseExpr()
    return { kind="CompoundAssign", op=t.value, target=e, value=rhs }
  end
  if e.kind~="Call" and e.kind~="MethodCall" then self:err("syntax: unexpected expression statement") end
  return { kind="CallStat", expr=e }
end

function Parser:parseExprList()
  local l={ self:parseExpr() }
  while self:accept("symbol",",") do l[#l+1]=self:parseExpr() end
  return l
end

-- =========================================================================
-- EXPRESSIONS (precedence climbing)
-- =========================================================================
local BINPRI = {
  ["or"]={1,1}, ["and"]={2,2},
  ["<"]={3,3},[">"]={3,3},["<="]={3,3},[">="]={3,3},["~="]={3,3},["=="]={3,3},
  ["|"]={4,4}, ["~"]={5,5}, ["&"]={6,6}, ["<<"]={7,7}, [">>"]={7,7},
  [".."]={9,8},  -- right assoc
  ["+"]={10,10}, ["-"]={10,10},
  ["*"]={11,11}, ["/"]={11,11}, ["//"]={11,11}, ["%"]={11,11},
  ["^"]={14,13}, -- right assoc, above unary
}
local UNARY_PRI = 12

function Parser:parseExpr(limit)
  limit = limit or 0
  local left
  local t=self:cur()
  if (t.type=="keyword" and t.value=="not") or (t.type=="symbol" and (t.value=="-" or t.value=="#" or t.value=="~")) then
    local op=t.value; self:adv()
    local operand=self:parseExpr(UNARY_PRI)
    left={ kind="Unop", op=op, expr=operand }
  else
    left=self:parseSimple()
  end
  while true do
    local o=self:cur()
    local opv
    if o.type=="symbol" then opv=o.value
    elseif o.type=="keyword" and (o.value=="and" or o.value=="or") then opv=o.value end
    local pri=opv and BINPRI[opv]
    if not pri or pri[1]<=limit then break end
    self:adv()
    local right=self:parseExpr(pri[2])
    left={ kind="Binop", op=opv, lhs=left, rhs=right }
  end
  return left
end

function Parser:parseSimple()
  local t=self:cur()
  if t.type=="number" then self:adv(); return { kind="Number", value=t.value }
  elseif t.type=="string" then self:adv(); return { kind="String", value= t.longstr and t.value or decodeString(t.value) }
  elseif t.type=="interp" then self:adv(); return self:parseInterp(t.value)
  elseif t.type=="keyword" then
    if t.value=="nil" then self:adv(); return {kind="Nil"} end
    if t.value=="true" then self:adv(); return {kind="True"} end
    if t.value=="false" then self:adv(); return {kind="False"} end
    if t.value=="function" then self:adv(); return self:parseFuncBody(false) end
  elseif t.type=="symbol" then
    if t.value=="..." then self:adv(); return {kind="Vararg"} end
    if t.value=="{" then return self:parseTable() end
  end
  return self:parseSuffixed()
end

function Parser:parsePrimary()
  local t=self:cur()
  if t.type=="symbol" and t.value=="(" then
    self:adv(); local e=self:parseExpr(); self:expect("symbol",")")
    return { kind="Paren", expr=e }
  end
  if t.type=="name" then self:adv(); return { kind="Name", name=t.value } end
  self:err("unexpected symbol in expression")
end

function Parser:parseSuffixed()
  local e=self:parsePrimary()
  while true do
    local t=self:cur()
    if t.type=="symbol" and t.value=="." then
      self:adv(); e={ kind="Dot", obj=e, name=self:expectName() }
    elseif t.type=="symbol" and t.value=="[" then
      self:adv(); local k=self:parseExpr(); self:expect("symbol","]")
      e={ kind="Index", obj=e, key=k }
    elseif t.type=="symbol" and t.value==":" then
      self:adv(); local m=self:expectName()
      local args=self:parseArgs()
      e={ kind="MethodCall", obj=e, method=m, args=args }
    elseif (t.type=="symbol" and (t.value=="(" or t.value=="{")) or t.type=="string" or t.type=="interp" then
      local args=self:parseArgs()
      e={ kind="Call", func=e, args=args }
    else break end
  end
  return e
end

function Parser:parseArgs()
  local t=self:cur()
  if t.type=="string" then self:adv(); return { { kind="String", value= t.longstr and t.value or decodeString(t.value) } } end
  if t.type=="interp" then self:adv(); return { self:parseInterp(t.value) } end
  if t.type=="symbol" and t.value=="{" then return { self:parseTable() } end
  self:expect("symbol","(")
  local args={}
  if not self:isSym(")") then args=self:parseExprList() end
  self:expect("symbol",")")
  return args
end

function Parser:parseTable()
  self:expect("symbol","{")
  local fields={}
  while not self:isSym("}") do
    local t=self:cur()
    if t.type=="symbol" and t.value=="[" then
      self:adv(); local k=self:parseExpr(); self:expect("symbol","]"); self:expect("symbol","=")
      fields[#fields+1]={ type="expr", key=k, value=self:parseExpr() }
    elseif t.type=="name" and self:nxt() and self:nxt().type=="symbol" and self:nxt().value=="=" then
      local key=self:adv().value; self:adv()
      fields[#fields+1]={ type="named", key=key, value=self:parseExpr() }
    else
      fields[#fields+1]={ type="item", value=self:parseExpr() }
    end
    if not (self:accept("symbol",",") or self:accept("symbol",";")) then break end
  end
  self:expect("symbol","}")
  return { kind="Table", fields=fields }
end

-- parse a backtick interpolation raw body into parts
function Parser:parseInterp(raw)
  local parts={}  -- each: {str=<literal>} or {expr=<ast>}
  local i,n=1,#raw
  local lit={}
  while i<=n do
    local c=raw:sub(i,i)
    if c=="\\" then lit[#lit+1]=raw:sub(i,i+1); i=i+2
    elseif c=="{" then
      parts[#parts+1]={ str=decodeString(table.concat(lit)) }; lit={}
      -- find matching }
      local depth,j=1,i+1
      while j<=n and depth>0 do
        local d=raw:sub(j,j)
        if d=="{" then depth=depth+1 elseif d=="}" then depth=depth-1 end
        if depth>0 then j=j+1 end
      end
      local inner=raw:sub(i+1,j-1)
      local toks=Lexer.new(inner):tokenize()
      local sub=Parser.new(toks)
      parts[#parts+1]={ expr=sub:parseExpr() }
      i=j+1
    else lit[#lit+1]=c; i=i+1 end
  end
  parts[#parts+1]={ str=decodeString(table.concat(lit)) }
  return { kind="Interp", parts=parts }
end

local M={}
function M.parse(src)
  local toks=Lexer.new(src):tokenize()
  return Parser.new(toks):parseChunk()
end
M.decodeString=decodeString
return M
