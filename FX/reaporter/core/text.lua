-- Text helpers with fixed, documented semantics (case folding, trimming, number parsing),
-- so every module compares and parses names the same way. Pure Lua 5.4.
local M = {}

local ASCII_WS = " \t\n\r\v\f"

-- Trim ASCII whitespace (space, tab, LF, CR, VT, FF): the trim of byte-oriented INI parsing.
function M.strip_ascii(s)
  return (s:gsub("^[ \t\n\r\v\f]+", ""):gsub("[ \t\n\r\v\f]+$", ""))
end

function M.rstrip_ascii(s)
  return (s:gsub("[ \t\n\r\v\f]+$", ""))
end

-- Unicode whitespace beyond ASCII, as UTF-8: U+001C..U+001F, U+0085, U+00A0, U+1680,
-- U+2000..U+200A, U+2028, U+2029, U+202F, U+205F, U+3000.
local UNI_WS = {}
for c = 0x1C, 0x1F do UNI_WS[utf8.char(c)] = true end
for _, c in ipairs({ 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 }) do
  UNI_WS[utf8.char(c)] = true
end
for c = 0x2000, 0x200A do UNI_WS[utf8.char(c)] = true end

local function ws_at_start(s, i)
  local b = s:byte(i)
  if not b then return nil end
  if ASCII_WS:find(string.char(b), 1, true) then return 1 end
  for n = 1, 3 do
    if UNI_WS[s:sub(i, i + n - 1)] then return n end
  end
  return nil
end

local function ws_at_end(s, j)
  local b = s:byte(j)
  if not b then return nil end
  if ASCII_WS:find(string.char(b), 1, true) then return 1 end
  for n = 1, 3 do
    if j - n + 1 >= 1 and UNI_WS[s:sub(j - n + 1, j)] then return n end
  end
  return nil
end

-- Trim Unicode whitespace from a UTF-8 string (a display name or a tag).
function M.strip(s)
  local i, j = 1, #s
  while i <= j do
    local n = ws_at_start(s, i)
    if not n then break end
    i = i + n
  end
  while j >= i do
    local n = ws_at_end(s, j)
    if not n then break end
    j = j - n
  end
  return s:sub(i, j)
end

-- Lowercase a UTF-8 string: ASCII, Latin-1 Supplement, Latin Extended-A, Greek and
-- Cyrillic capitals. Other code points (and invalid bytes) pass through unchanged.
local function lower_cp(c)
  if c >= 0x41 and c <= 0x5A then return c + 32 end
  if c < 0xC0 then return c end
  if c <= 0xDE then return c == 0xD7 and c or c + 32 end
  if c >= 0x100 and c <= 0x137 and c ~= 0x130 then return c % 2 == 0 and c + 1 or c end
  if c >= 0x139 and c <= 0x148 then return c % 2 == 1 and c + 1 or c end
  if c >= 0x14A and c <= 0x177 then return c % 2 == 0 and c + 1 or c end
  if c == 0x178 then return 0xFF end
  if c >= 0x179 and c <= 0x17E then return c % 2 == 1 and c + 1 or c end
  if c >= 0x391 and c <= 0x3AB and c ~= 0x3A2 then return c + 32 end
  if c >= 0x410 and c <= 0x42F then return c + 32 end
  if c >= 0x400 and c <= 0x40F then return c + 80 end
  return c
end

function M.lower(s)
  if not s:find("[\128-\255]") then return s:lower() end
  if not utf8.len(s) then return s:lower() end
  local out = {}
  for _, c in utf8.codes(s) do out[#out + 1] = utf8.char(lower_cp(c)) end
  return table.concat(out)
end

-- The first `n` code points of a UTF-8 string.
function M.prefix(s, n)
  if not utf8.len(s) then return s:sub(1, n) end
  local stop = utf8.offset(s, n + 1)
  if not stop then return s end
  return s:sub(1, stop - 1)
end

function M.starts_with(s, p) return s:sub(1, #p) == p end

function M.ends_with(s, p) return p == "" or s:sub(-#p) == p end

-- A decimal integer literal: surrounding whitespace, optional sign, digits with single
-- underscores between them. Errors otherwise.
function M.parse_int(s)
  local t = M.strip(s)
  local sign, digits = t:match("^([+-]?)([0-9_]+)$")
  if not digits or digits:find("^_") or digits:find("_$") or digits:find("__") then
    error(("invalid integer literal: %q"):format(s), 0)
  end
  local v = math.tointeger(tonumber((digits:gsub("_", ""))))
  if not v then error(("integer out of range: %q"):format(s), 0) end
  return sign == "-" and -v or v
end

local function digit_run_ok(r)
  return r == "" or (r:match("^[0-9_]+$") and not r:find("^_") and not r:find("_$")
    and not r:find("__"))
end

local NAN = string.unpack("<d", "\0\0\0\0\0\0\248\127")
local NEG_NAN = string.unpack("<d", "\0\0\0\0\0\0\248\255")

-- A decimal float literal: whitespace, sign, digits / point / exponent (underscores
-- between digits allowed), or inf / infinity / nan in any case. Errors otherwise.
function M.parse_float(s)
  local t = M.strip(s)
  local sign, body = t:match("^([+-]?)(.*)$")
  local lb = body:lower()
  if lb == "inf" or lb == "infinity" then return sign == "-" and -math.huge or math.huge end
  if lb == "nan" then return sign == "-" and NEG_NAN or NAN end
  local int, frac, exp = body:match("^([0-9_]*)%.?([0-9_]*)([eE]?.*)$")
  local ok = int and (int ~= "" or frac ~= "") and digit_run_ok(int) and digit_run_ok(frac)
  if ok and body:find(".", 1, true) == nil and frac ~= "" then ok = false end
  if ok and exp ~= "" then
    local es, ed = exp:match("^[eE]([+-]?)([0-9_]+)$")
    ok = ed ~= nil and digit_run_ok(ed)
  end
  if not ok then error(("could not convert string to float: %q"):format(s), 0) end
  local v = tonumber((body:gsub("_", "")))
  if not v then error(("could not convert string to float: %q"):format(s), 0) end
  v = v + 0.0
  return sign == "-" and -v or v
end

-- UTF-16 LE text (no BOM) as UTF-8. Raises on an odd length or a lone surrogate.
function M.utf16le_to_utf8(s)
  if #s % 2 ~= 0 then error("UTF-16: odd byte count", 0) end
  local out, i, n = {}, 1, #s
  while i <= n do
    local u = string.unpack("<I2", s, i)
    i = i + 2
    if u >= 0xD800 and u <= 0xDBFF then
      local lo = i <= n and string.unpack("<I2", s, i)
      if not lo or lo < 0xDC00 or lo > 0xDFFF then error("UTF-16: lone surrogate", 0) end
      i = i + 2
      u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
    elseif u >= 0xDC00 and u <= 0xDFFF then
      error("UTF-16: lone surrogate", 0)
    end
    out[#out + 1] = utf8.char(u)
  end
  return table.concat(out)
end

-- Split a path at its last separator: (folder, file name).
function M.split_path(p)
  local d, b = p:match("^(.*)[/\\]([^/\\]*)$")
  if not d then return "", p end
  return d, b
end

function M.basename(p)
  local _, b = M.split_path(p)
  return b
end

function M.dirname(p)
  local d = M.split_path(p)
  return d
end

-- (stem, extension) of a file name; leading dots belong to the stem.
function M.splitext(name)
  local i = name:match("^.*()%.")
  if not i then return name, "" end
  if not name:sub(1, i - 1):find("[^.]") then return name, "" end
  return name:sub(1, i - 1), name:sub(i)
end

return M
