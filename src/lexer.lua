-- lexer.lua : Luau tokenizer
-- Emits a flat token stream consumed by parser.lua
-- Token = { type=<kind>, value=<string>, line=<n> }
-- kinds: "name","number","string","keyword","symbol","eof"

local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {}
for _, k in ipairs({
  "and","break","do","else","elseif","end","false","for","function","if","in",
  "local","nil","not","or","repeat","return","then","true","until","while",
}) do KEYWORDS[k] = true end
-- NOTE: "continue", "type", "export" are contextual in Luau -> lexed as names.

-- multi-char symbols, longest first
local SYMBOLS = {
  "...", "..=", "//=", "<<=", ">>=",
  "==","~=","<=",">=","..","::","->","+=","-=","*=","/=","%=","^=","//","<<",">>",
  "+","-","*","/","%","^","#","&","~","|","<",">","=","(",")","{","}","[","]",
  ";",":",",",".","?",
}
table.sort(SYMBOLS, function(a,b) return #a > #b end)

local function isDigit(c) return c >= "0" and c <= "9" end
local function isHex(c) return isDigit(c) or (c>="a" and c<="f") or (c>="A" and c<="F") end
local function isAlpha(c) return c=="_" or (c>="a" and c<="z") or (c>="A" and c<="Z") end
local function isAlnum(c) return isAlpha(c) or isDigit(c) end

function Lexer.new(src)
  return setmetatable({ src=src, pos=1, len=#src, line=1, toks={} }, Lexer)
end

function Lexer:err(msg)
  error(("lexer:%d: %s"):format(self.line, msg), 0)
end

function Lexer:peek(o) return self.src:sub(self.pos+(o or 0), self.pos+(o or 0)) end

function Lexer:adv(n)
  n = n or 1
  for _=1,n do
    if self:peek() == "\n" then self.line = self.line + 1 end
    self.pos = self.pos + 1
  end
end

-- returns level count if a long bracket opener [[ [=[ ... starts here, else nil
function Lexer:longOpen()
  if self:peek() ~= "[" then return nil end
  local i = self.pos + 1
  local eq = 0
  while self.src:sub(i,i) == "=" do eq = eq + 1; i = i + 1 end
  if self.src:sub(i,i) == "[" then return eq end
  return nil
end

function Lexer:readLong(level)
  -- assumes cursor at first '['; consume opener
  self:adv(2 + level)
  -- skip immediate newline right after opener (Lua semantics)
  if self:peek() == "\r" then self:adv() end
  if self:peek() == "\n" then self:adv() end
  local start = self.pos
  local close = "]" .. string.rep("=", level) .. "]"
  local idx = self.src:find(close, self.pos, true)
  if not idx then self:err("unterminated long bracket") end
  local body = self.src:sub(start, idx-1)
  -- advance past body + closer, keeping line count
  while self.pos < idx do self:adv() end
  self:adv(#close)
  return body
end

function Lexer:skipTrivia()
  while self.pos <= self.len do
    local c = self:peek()
    if c==" " or c=="\t" or c=="\r" or c=="\n" then
      self:adv()
    elseif c=="-" and self:peek(1)=="-" then
      self:adv(2)
      local lvl = self:longOpen()
      if lvl then
        self:readLong(lvl)             -- block comment
      else
        while self.pos<=self.len and self:peek()~="\n" do self:adv() end
      end
    else
      break
    end
  end
end

function Lexer:readString(q)
  local line = self.line
  self:adv() -- opening quote
  local buf = {}
  while true do
    if self.pos > self.len then self:err("unterminated string") end
    local c = self:peek()
    if c == q then self:adv(); break end
    if c == "\n" then self:err("unterminated string") end
    if c == "\\" then
      buf[#buf+1] = c; self:adv()
      buf[#buf+1] = self:peek(); self:adv()   -- keep escape as-is; parser decodes
    else
      buf[#buf+1] = c; self:adv()
    end
  end
  return { type="string", value=table.concat(buf), quote=q, line=line }
end

-- backtick interpolated string -> we lex whole thing raw incl. braces, parser handles
function Lexer:readInterp()
  local line = self.line
  self:adv() -- `
  local buf = {}
  local depth = 0
  while true do
    if self.pos > self.len then self:err("unterminated interpolated string") end
    local c = self:peek()
    if c == "\\" then buf[#buf+1]=c; self:adv(); buf[#buf+1]=self:peek(); self:adv()
    elseif c == "{" then depth=depth+1; buf[#buf+1]=c; self:adv()
    elseif c == "}" then depth=depth-1; buf[#buf+1]=c; self:adv()
    elseif c == "`" and depth<=0 then self:adv(); break
    else buf[#buf+1]=c; self:adv() end
  end
  return { type="interp", value=table.concat(buf), line=line }
end

function Lexer:readNumber()
  local line = self.line
  local start = self.pos
  if self:peek()=="0" and (self:peek(1)=="x" or self:peek(1)=="X") then
    self:adv(2)
    while self.pos<=self.len and (isHex(self:peek()) or self:peek()=="_" or self:peek()==".") do self:adv() end
    if self:peek()=="p" or self:peek()=="P" then
      self:adv(); if self:peek()=="+" or self:peek()=="-" then self:adv() end
      while isDigit(self:peek()) or self:peek()=="_" do self:adv() end
    end
  elseif self:peek()=="0" and (self:peek(1)=="b" or self:peek(1)=="B") then
    self:adv(2)
    while self:peek()=="0" or self:peek()=="1" or self:peek()=="_" do self:adv() end
  else
    while isDigit(self:peek()) or self:peek()=="_" do self:adv() end
    if self:peek()=="." then self:adv(); while isDigit(self:peek()) or self:peek()=="_" do self:adv() end end
    if self:peek()=="e" or self:peek()=="E" then
      self:adv(); if self:peek()=="+" or self:peek()=="-" then self:adv() end
      while isDigit(self:peek()) or self:peek()=="_" do self:adv() end
    end
  end
  return { type="number", value=self.src:sub(start, self.pos-1), line=line }
end

function Lexer:readName()
  local line = self.line
  local start = self.pos
  while self.pos<=self.len and isAlnum(self:peek()) do self:adv() end
  local v = self.src:sub(start, self.pos-1)
  return { type = KEYWORDS[v] and "keyword" or "name", value=v, line=line }
end

function Lexer:readSymbol()
  for _, s in ipairs(SYMBOLS) do
    if self.src:sub(self.pos, self.pos+#s-1) == s then
      local line = self.line
      self:adv(#s)
      return { type="symbol", value=s, line=line }
    end
  end
  self:err("unexpected char '"..self:peek().."'")
end

function Lexer:tokenize()
  local toks = self.toks
  while true do
    self:skipTrivia()
    if self.pos > self.len then break end
    local c = self:peek()
    local t
    if c=="\"" or c=="'" then t = self:readString(c)
    elseif c=="`" then t = self:readInterp()
    elseif self:longOpen() and c=="[" then
      local lvl = self:longOpen(); local line=self.line
      t = { type="string", value=self:readLong(lvl), longstr=true, line=line }
    elseif isDigit(c) or (c=="." and isDigit(self:peek(1))) then t = self:readNumber()
    elseif isAlpha(c) then t = self:readName()
    else t = self:readSymbol() end
    toks[#toks+1] = t
  end
  toks[#toks+1] = { type="eof", value="<eof>", line=self.line }
  return toks
end

return Lexer
