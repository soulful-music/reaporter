-- JSON reader and writer. Pure Lua 5.4.
--
-- Objects decode to tables marked with json.OBJECT (so an empty object stays an object);
-- arrays to plain sequences. Integers stay Lua integers, numbers with a fraction or an
-- exponent become floats. NaN / Infinity / -Infinity are accepted. The writer emits
-- sorted keys, one-space indent, raw UTF-8 and the shortest float repr that round-trips,
-- the layout the MixSurface sidecar uses (SIDECAR.md).
local M = {}

M.OBJECT = setmetatable({}, { __name = "json.object" })
local OBJ_MT = { __json = "object" }
M.null = setmetatable({}, { __name = "json.null", __tostring = function() return "null" end })

function M.object(t)
  return setmetatable(t or {}, OBJ_MT)
end

function M.is_object(t)
  return type(t) == "table" and getmetatable(t) == OBJ_MT
end

local function fail(msg, pos)
  error(("JSON: %s at byte %d"):format(msg, pos), 0)
end

local WS = { [32] = true, [9] = true, [10] = true, [13] = true }

local function skip(s, i)
  while WS[s:byte(i)] do i = i + 1 end
  return i
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function parse_string(s, i)
  -- s:sub(i, i) == '"'
  local out, j = {}, i + 1
  while true do
    local k = s:find('["\\\0-\31]', j)
    if not k then fail("unterminated string", i) end
    local c = s:sub(k, k)
    out[#out + 1] = s:sub(j, k - 1)
    if c == '"' then return table.concat(out), k + 1 end
    if c ~= "\\" then fail("invalid control character", k) end
    local e = s:sub(k + 1, k + 1)
    if ESC[e] then
      out[#out + 1] = ESC[e]
      j = k + 2
    elseif e == "u" then
      local hex = s:sub(k + 2, k + 5)
      if not hex:match("^%x%x%x%x$") then fail("invalid \\u escape", k) end
      local cp = tonumber(hex, 16)
      j = k + 6
      if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
        local lo = s:sub(j + 2, j + 5)
        if lo:match("^%x%x%x%x$") then
          local lv = tonumber(lo, 16)
          if lv >= 0xDC00 and lv <= 0xDFFF then
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lv - 0xDC00)
            j = j + 6
          end
        end
      end
      out[#out + 1] = utf8.char(cp)
    else
      fail("invalid escape", k)
    end
  end
end

local parse_value

local function parse_number(s, i)
  local int = s:match("^-?0()", i) or s:match("^-?[1-9]%d*()", i)
  if not int then fail("expecting value", i) end
  local j = int
  local is_float = false
  if s:sub(j, j) == "." then
    local f = s:match("^%.%d+()", j)
    if not f then fail("expecting digits after '.'", j) end
    j, is_float = f, true
  end
  if s:find("^[eE]", j) then
    local e = s:match("^[eE][+-]?%d+()", j)
    if e then j, is_float = e, true end
  end
  local text = s:sub(i, j - 1)
  local v
  if is_float then
    v = tonumber(text) + 0.0
  else
    v = math.tointeger(tonumber(text)) or tonumber(text)
  end
  return v, j
end

local function parse_object(s, i)
  local obj = M.object()
  i = skip(s, i + 1)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then fail("expecting property name", i) end
    local key
    key, i = parse_string(s, i)
    i = skip(s, i)
    if s:sub(i, i) ~= ":" then fail("expecting ':'", i) end
    local v
    v, i = parse_value(s, skip(s, i + 1))
    obj[key] = v
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "}" then return obj, i + 1 end
    if c ~= "," then fail("expecting ',' or '}'", i) end
    i = skip(s, i + 1)
  end
end

local function parse_array(s, i)
  local arr = {}
  i = skip(s, i + 1)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v
    v, i = parse_value(s, i)
    arr[#arr + 1] = v
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "]" then return arr, i + 1 end
    if c ~= "," then fail("expecting ',' or ']'", i) end
    i = skip(s, i + 1)
  end
end

parse_value = function(s, i)
  local c = s:sub(i, i)
  if c == "{" then return parse_object(s, i) end
  if c == "[" then return parse_array(s, i) end
  if c == '"' then return parse_string(s, i) end
  if s:find("^true", i) then return true, i + 4 end
  if s:find("^false", i) then return false, i + 5 end
  if s:find("^null", i) then return M.null, i + 4 end
  if s:find("^NaN", i) then return 0.0 / 0.0, i + 3 end
  if s:find("^Infinity", i) then return math.huge, i + 8 end
  if s:find("^%-Infinity", i) then return -math.huge, i + 9 end
  return parse_number(s, i)
end

-- Decode a JSON document (UTF-8, an optional BOM). Errors on malformed input or
-- trailing data.
function M.decode(s)
  if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
  if not utf8.len(s) then error("JSON: not valid UTF-8", 0) end
  local v, i = parse_value(s, skip(s, 1))
  i = skip(s, i)
  if i <= #s then fail("extra data", i) end
  return v
end

-- Shortest repr of a float that reads back the same: fixed notation for decimal
-- exponents -4..15, scientific otherwise ("1e-05", "1e+16"); integral floats get ".0".
function M.float_repr(x)
  if x ~= x then return "NaN" end
  if x == math.huge then return "Infinity" end
  if x == -math.huge then return "-Infinity" end
  if x == 0 then return (1 / x < 0) and "-0.0" or "0.0" end
  local e_str
  for p = 1, 17 do
    e_str = ("%." .. (p - 1) .. "e"):format(x)
    if tonumber(e_str) == x then break end
  end
  local sign, d1, rest, exp = e_str:match("^(%-?)(%d)%.?(%d*)e([+-]%d+)$")
  local digits = (d1 .. rest):gsub("0+$", "")
  if digits == "" then digits = "0" end
  local e = tonumber(exp)
  if e >= -5 + 1 and e < 16 then
    if e >= 0 then
      if #digits <= e + 1 then
        return sign .. digits .. ("0"):rep(e + 1 - #digits) .. ".0"
      end
      return sign .. digits:sub(1, e + 1) .. "." .. digits:sub(e + 2)
    end
    return sign .. "0." .. ("0"):rep(-e - 1) .. digits
  end
  local mant = digits:sub(1, 1)
  if #digits > 1 then mant = mant .. "." .. digits:sub(2) end
  return ("%s%se%s%02d"):format(sign, mant, e < 0 and "-" or "+", math.abs(e))
end

local function escape_string(s)
  return '"' .. s:gsub('[\0-\31"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    if c == "\b" then return "\\b" end
    if c == "\f" then return "\\f" end
    return ("\\u%04x"):format(c:byte())
  end) .. '"'
end

local function encode(v, depth, out)
  local t = type(v)
  if v == M.null or v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    out[#out + 1] = math.type(v) == "integer" and ("%d"):format(v) or M.float_repr(v)
  elseif t == "string" then
    out[#out + 1] = escape_string(v)
  elseif t == "table" then
    local pad = "\n" .. (" "):rep(depth + 1)
    if M.is_object(v) then
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      if #keys == 0 then
        out[#out + 1] = "{}"
        return
      end
      table.sort(keys)
      out[#out + 1] = "{"
      for n, k in ipairs(keys) do
        out[#out + 1] = (n > 1 and "," or "") .. pad .. escape_string(k) .. ": "
        encode(v[k], depth + 1, out)
      end
      out[#out + 1] = "\n" .. (" "):rep(depth) .. "}"
    else
      if #v == 0 then
        out[#out + 1] = "[]"
        return
      end
      out[#out + 1] = "["
      for n, x in ipairs(v) do
        out[#out + 1] = (n > 1 and "," or "") .. pad
        encode(x, depth + 1, out)
      end
      out[#out + 1] = "\n" .. (" "):rep(depth) .. "]"
    end
  else
    error("JSON: cannot encode a " .. t, 0)
  end
end

-- Encode with sorted keys and a one-space indent (no trailing newline).
function M.encode(v)
  local out = {}
  encode(v, 0, out)
  return table.concat(out)
end

return M
