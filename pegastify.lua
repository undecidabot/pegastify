local parser = require "lua-parser.parser"
local pp = require "lua-parser.pp"

local file = assert(io.open(arg[1], "r"))
local code = file:read("*all")
file:close()

local ast, error_msg = parser.parse(code, "code.lua")
if not ast then
  print(error_msg)
  os.exit(1)
end

function pegastify(lua_ast)
  local grammar = {}
  pegastify_stmt(lua_ast, grammar)
  return grammar
end

function pegastify_stmt(lua_ast, grammar)
  local tag = lua_ast.tag

  if tag == "Block" or tag == "Do" then
    for _, stmt in ipairs(lua_ast) do
      pegastify_stmt(stmt, grammar)
    end
  elseif tag == "Set" or tag == "Local" then
    if not lua_ast[2] or #lua_ast[1] ~= 1 or lua_ast[1][1].tag ~= "Id" then
      return
    end
    local var_name = lua_ast[1][1][1]
    local patt = pegastify_exp(lua_ast[2][1])
    if patt[1] == "G" then
      grammar[#grammar+1] = { "Rule", var_name, patt[2] }
      for i, rule in ipairs(patt[3]) do
        grammar[#grammar+1] = rule
      end
    else
      grammar[#grammar+1] = { "Rule", var_name, patt }
    end
  elseif tag == "Localrec" then
    -- TODO: recognize the functions on patterns (based on the return)
  end
end

function pegastify_exp(lua_ast)
  local tag = lua_ast.tag

  if tag == "True" then
    return { "Success" }
  elseif tag == "Number" then
    local num = lua_ast[1]
    local neg = num < 0
    if neg then num = -num end
    local patt = { "AnyChar" }
    if num ~= 1 then patt = { "Repetition", patt, "exact", num } end
    if neg then patt = { "Negation", patt } end
    return patt
  elseif tag == "String" then
    return { "Literal", lua_ast[1] }
  elseif tag == "Op" then
    local op = lua_ast[1]
    if op == "add" then
      local left = pegastify_exp(lua_ast[2])
      local right = pegastify_exp(lua_ast[3])
      return { "Choice", left, right }
    elseif op == "sub" then
      local left = pegastify_exp(lua_ast[2])
      local right = pegastify_exp(lua_ast[3])
      return { "Sequence", { "Negation", right }, left }
    elseif op == "mul" then
      local left = pegastify_exp(lua_ast[2])
      local right = pegastify_exp(lua_ast[3])
      return { "Sequence", left, right }
    elseif op == "div" then
      local patt = pegastify_exp(lua_ast[2])
      return patt
    elseif op == "pow" then
      local neg_num = lua_ast[3].tag == "Op" and lua_ast[3][1] == "unm" and lua_ast[3][2].tag == "Number"
      if lua_ast[3].tag ~= "Number" and not neg_num then
        return { "Failure" }
      end
      local patt = pegastify_exp(lua_ast[2])
      local type, num
      num = neg_num and lua_ast[3][2][1] or lua_ast[3][1]
      type = neg_num and "max" or "min"
      return { "Repetition", patt, type, num }
    elseif op == "unm" then
      local patt = pegastify_exp(lua_ast[2])
      return { "Negation", patt }
    elseif op == "len" then
      local patt = pegastify_exp(lua_ast[2])
      return { "LookAhead", patt }
    else
      -- op == concat, idiv, mod, eq, lt, le, and, or, not, bitwise ops
      return { "Failure" }
    end
  elseif tag == "Paren" then
    local patt = pegastify_exp(lua_ast[1])
    return patt
  elseif tag == "Call" then
    local func = lua_ast[1]
    if func.tag == "Id" then
      func = func[1]
    elseif func.tag == "Index" and func[2].tag == "String" then
      func = func[2][1]
    else
      return { "Failure" }
    end

    if func == "P" then
      if lua_ast[2].tag == "Table" then -- grammar
        local t = lua_ast[2]
        local rules = {}
        for i = 2, #t do
          rules[#rules + 1] = { "Rule", t[i][1][1], pegastify_exp(t[i][2]) }
        end
        local init = t[1].tag == "String" and { "Variable", t[1][1] } or pegastify_exp(t[1])
        return { "G", init, rules }
      else
        local patt = pegastify_exp(lua_ast[2])
        return patt
      end
    elseif func == "S" then
      local chars = lua_ast[2][1] -- assumed to be string literal
      local char_set = {}
      for i = 1,#chars do
        char_set[i] = { "Character", chars:sub(i, i) }
      end
      return { "CharClass", char_set }
    elseif func == "R" then
      local ranges = {}
      for i = 2,#lua_ast do
        local arg = lua_ast[i][1] -- assumed to be string literals of length 2
        local start, fin = arg:sub(1,1), arg:sub(2,2)
        ranges[#ranges+1] = { "Range", start, fin }
      end
      return { "CharClass", ranges }
    elseif func == "B" then
      local patt = pegastify_exp(lua_ast[2])
      return { "LookBehind", patt }
    elseif func == "V" then
      return { "Variable", lua_ast[2][1] }
    elseif
      func == "C" or func == "Cf" or func == "Cg" or
      func == "Cs" or func == "Ct" or func == "Cmt"
    then
      local patt = pegastify_exp(lua_ast[2])
      return patt
    elseif
      func == "Carg" or func == "Cb" or
      func == "Cc" or func == "Cp"
    then
      return { "Success" }
    else
      local args = {}
      for i = 2,#lua_ast do
        local patt = pegastify_exp(lua_ast[i])
        args[#args+1] = patt
      end
      return { "Application", func, args }
    end
  elseif tag == "Id" then
    return { "Variable", lua_ast[1] }
  elseif tag == "Index" and lua_ast[1].tag == "Id" and lua_ast[2].tag == "String" then
    return { "Variable", "<" .. lua_ast[1][1] .. "." .. lua_ast[2][1] .. ">" }
  else
    -- tag == Dots, False, Function, Table, Invoke, Index
    return { "Failure" }
  end
end

function pprint(peg_ast)
  local out = ""
  for _, rule in ipairs(peg_ast) do
    out = out .. rule[2] .. " <- " .. pprint_patt(rule[3]) .. "\n"
  end
  return out
end

local precedence = {
  Success = 99;
  Failure = 99;
  AnyChar = 99;
  Literal = 99;
  CharClass = 99;
  Variable = 99;
  Application = 99;

  Repetition = 4;
  LookAhead = 3;
  LookBehind = 3;
  Negation = 3;
  Sequence = 2;
  Choice = 1;
}

function escape(char)
  if char == "\n" then return "\\n"
  elseif char == "\t" then return "\\t"
  else return char end
end

function pprint_patt(patt_ast)
  local tag = patt_ast[1]
  if tag == "Literal" then
    return "'" .. escape(patt_ast[2]) .. "'"
  elseif tag == "AnyChar" then
    return "."
  elseif tag == "CharClass" then
    local chars = ""
    for _, item in ipairs(patt_ast[2]) do
      if item[1] == "Character" then
        chars = chars .. escape(item[2])
      elseif item[1] == "Range" then
        chars = chars .. escape(item[2]) .. "-" .. escape(item[3])
      end
    end
    return "[" .. chars .. "]"
  elseif tag == "Choice" then
    local left = pprint_patt(patt_ast[2])
    local right = pprint_patt(patt_ast[3])
    local p, p_left, p_right = precedence[tag], precedence[patt_ast[2][1]], precedence[patt_ast[3][1]]
    if p_left < p then left = "(" .. left .. ")" end
    if p_right < p then right = "(" .. right .. ")" end
    return left .. " / " .. right
  elseif tag == "Sequence" then
    local left = pprint_patt(patt_ast[2])
    local right = pprint_patt(patt_ast[3])
    local p, p_left, p_right = precedence[tag], precedence[patt_ast[2][1]], precedence[patt_ast[3][1]]
    if p_left < p then left = "(" .. left .. ")" end
    if p_right < p then right = "(" .. right .. ")" end
    return left .. " " .. right
  elseif tag == "Repetition" then
    local patt = pprint_patt(patt_ast[2])
    local p, p_patt = precedence[tag], precedence[patt_ast[2][1]]
    if p_patt < p then patt = "(" .. patt .. ")" end
    local type, num = patt_ast[3], patt_ast[4]
    if type == "min" then
      if num == 0 then return patt .. "*"
      elseif num == 1 then return patt .. "+"
      else return patt .. "^+" .. num
      end
    elseif type == "max" then
      if num == 1 then return patt .. "?"
      else return patt .. "^-" .. num
      end
    else -- == exact
      return patt .. "^" .. num
    end
  elseif tag == "Negation" then
    local patt = pprint_patt(patt_ast[2])
    local p, p_patt = precedence[tag], precedence[patt_ast[2][1]]
    if p_patt < p then patt = "(" .. patt .. ")" end
    return "!" .. patt
  elseif tag == "LookAhead" then
    local patt = pprint_patt(patt_ast[2])
    local p, p_patt = precedence[tag], precedence[patt_ast[2][1]]
    if p_patt < p then patt = "(" .. patt .. ")" end
    return "&" .. patt
  elseif tag == "LookBehind" then
    local patt = pprint_patt(patt_ast[2])
    local p, p_patt = precedence[tag], precedence[patt_ast[2][1]]
    if p_patt < p then patt = "(" .. patt .. ")" end
    return "B" .. patt
  elseif tag == "Variable" then
    return patt_ast[2]
  elseif tag == "Success" then
    return "''"
  elseif tag == "Failure" then
    return "FAIL"
  elseif tag == "Application" then
    local args = {}
    for _, patt in ipairs(patt_ast[3]) do
      args[#args+1] = pprint_patt(patt)
    end
    return "@" .. patt_ast[2] .. "(" .. table.concat(args, ", ") .. ")"
  else
    return "<Unknown Tag: " .. tag .. ">"
  end
end

print(pprint(pegastify(ast)))
