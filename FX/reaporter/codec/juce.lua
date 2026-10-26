-- JUCE binary ValueTree codec and the REAPER VST3 `vst_chunk` containers. Pure Lua 5.4.
-- FORMATS.md, "JUCE ValueTree" and "REAPER vst_chunk", documents every layout here.
local M = {}

-- var stream markers (juce_Variant.cpp)
M.INT, M.TRUE, M.FALSE, M.DOUBLE, M.STRING, M.INT64, M.ARRAY, M.BINARY, M.UNDEF =
  1, 2, 3, 4, 5, 6, 7, 8, 9

-- Byte strings are read with 0-based offsets and slice rules that clamp to the string
-- (a slice past the end is shorter, a negative bound counts from the end), so a
-- malformed file fails the way a clamping reader fails rather than by a Lua index error.
local function norm(n, len)
  if n < 0 then
    n = n + len
    if n < 0 then n = 0 end
  elseif n > len then
    n = len
  end
  return n
end

local function slice(b, a, c)
  local len = #b
  a, c = norm(a, len), norm(c, len)
  if c <= a then return "" end
  return b:sub(a + 1, c)
end

local function byte_at(b, i)
  local len = #b
  if i < 0 then i = i + len end
  if i < 0 or i >= len then error("ValueTree: index out of range", 0) end
  return b:byte(i + 1)
end

local function utf8_strict(s)
  if not utf8.len(s) then error("ValueTree: invalid UTF-8", 0) end
  return s
end

local function le_uint(s)
  local v = 0
  for k = #s, 1, -1 do v = (v << 8) | s:byte(k) end
  return v
end

-- compressed int: one byte n (bit 7 = negative), then n little-endian bytes
function M.read_cint(b, i)
  local n = byte_at(b, i)
  local neg = n & 0x80 ~= 0
  n = n & 0x7F
  local raw = slice(b, i + 1, i + 1 + n)
  if #raw > 8 or (#raw == 8 and raw:byte(8) >= 0x80) then
    error("ValueTree: compressed int out of range", 0)
  end
  local v = le_uint(raw)
  return neg and -v or v, i + 1 + n
end

function M.write_cint(v)
  local neg = v < 0
  if neg then v = -v end
  local raw = {}
  while v > 0 do
    raw[#raw + 1] = string.char(v & 0xFF)
    v = v >> 8
  end
  return string.char(#raw | (neg and 0x80 or 0)) .. table.concat(raw)
end

local function read_cstr(b, i)
  local p = i >= 0 and b:find("\0", i + 1, true) or nil
  if not p then error("ValueTree: missing NUL terminator", 0) end
  return utf8_strict(b:sub(i + 1, p - 1)), p
end

local function unpack_exact(fmt, size, body)
  if #body ~= size then error(("ValueTree: %d-byte value has %d bytes"):format(size, #body), 0) end
  return (string.unpack(fmt, body))
end

-- Read a var at offset i; returns ({kind = k, value = v}, next offset).
function M.read_var(b, i)
  local n
  n, i = M.read_cint(b, i)
  local stop = i + n
  if n == 0 then return { kind = M.UNDEF }, stop end
  local k = byte_at(b, i)
  local body = slice(b, i + 1, stop)
  local v
  if k == M.INT then
    v = unpack_exact("<i4", 4, body)
  elseif k == M.DOUBLE then
    v = unpack_exact("<d", 8, body)
  elseif k == M.STRING then
    v = utf8_strict((body:gsub("\0+$", "")))
  elseif k == M.INT64 then
    v = unpack_exact("<i8", 8, body)
  elseif k == M.BINARY then
    v = body
  elseif k == M.ARRAY then
    local cnt, j = M.read_cint(b, i + 1)
    v = {}
    for _ = 1, cnt do
      local x
      x, j = M.read_var(b, j)
      v[#v + 1] = x
    end
  end
  return { kind = k, value = v }, stop
end

-- Read a ValueTree at offset i (default 0); returns ({type, props = {{name, var}},
-- children}, next offset).
function M.read_tree(b, i)
  i = i or 0
  local t
  t, i = read_cstr(b, i)
  local tree = { type = t, props = {}, children = {} }
  local n
  n, i = M.read_cint(b, i)
  for _ = 1, n do
    local k, v
    k, i = read_cstr(b, i)
    v, i = M.read_var(b, i)
    tree.props[#tree.props + 1] = { k, v }
  end
  n, i = M.read_cint(b, i)
  for _ = 1, n do
    local c
    c, i = M.read_tree(b, i)
    tree.children[#tree.children + 1] = c
  end
  return tree, i
end

function M.encode_var(var)
  local k, v = var.kind, var.value
  local body
  if k == M.INT then
    body = string.pack("<i4", v)
  elseif k == M.TRUE or k == M.FALSE or k == M.UNDEF then
    body = ""
  elseif k == M.DOUBLE then
    body = string.pack("<d", v)
  elseif k == M.STRING then
    body = v .. "\0"
  elseif k == M.INT64 then
    body = string.pack("<i8", v)
  elseif k == M.BINARY then
    body = v
  elseif k == M.ARRAY then
    local parts = { M.write_cint(#v) }
    for _, x in ipairs(v) do parts[#parts + 1] = M.encode_var(x) end
    body = table.concat(parts)
  else
    error("ValueTree: cannot encode var kind " .. tostring(k), 0)
  end
  local out = string.char(k) .. body
  return M.write_cint(#out) .. out
end

function M.encode_tree(tree)
  local out = { tree.type, "\0", M.write_cint(#tree.props) }
  for _, p in ipairs(tree.props) do
    out[#out + 1] = p[1] .. "\0"
    out[#out + 1] = M.encode_var(p[2])
  end
  out[#out + 1] = M.write_cint(#tree.children)
  for _, c in ipairs(tree.children) do out[#out + 1] = M.encode_tree(c) end
  return table.concat(out)
end

M.PRIVATE_MAGIC = "JUCEPrivateData"

-- The JUCEPrivateData tree JUCE appends to a plugin state: {Bypass = false}.
function M.private_bypass_tree(bypass)
  return M.encode_tree({
    type = "JUCEPrivateData",
    props = { { "Bypass", { kind = bypass and M.TRUE or M.FALSE } } },
    children = {},
  })
end

local ZERO8 = ("\0"):rep(8)

-- REAPER vst_chunk of a VST3 that wraps a VST2 opaque chunk in VstW/CcnK/FBCh (raw bytes).
function M.build_vst2_wrapped(fx_id, fx_version, num_programs, chunk, bypass, controller)
  local bank = "FBCh" .. string.pack(">I4", 2) .. fx_id
    .. string.pack(">I4>I4", fx_version, num_programs) .. ("\0"):rep(128)
    .. string.pack(">I4", #chunk) .. chunk
  local comp = "VstW" .. string.pack(">I4>I4>I4", 8, 1, bypass or 0) .. "CcnK"
    .. string.pack(">I4", #bank) .. bank
  return string.pack("<I4<I4", #comp, 1) .. comp .. (controller or ZERO8)
end

-- REAPER vst_chunk of a JUCE VST3: the plugin state plus the private-data trailer, wrapped.
-- s = {fx_id, fx_version, num_programs, plugin_state, private, bypass?, controller?}
function M.build_reaper_vst3(s)
  local chunk = s.plugin_state .. s.private .. string.pack("<i8", #s.private) .. M.PRIVATE_MAGIC
  return M.build_vst2_wrapped(s.fx_id, s.fx_version, s.num_programs, chunk, s.bypass, s.controller)
end

-- A VST3 vst_chunk that is the plugin's component as is: u32 length, u32 1, component,
-- controller state (8 zero bytes).
function M.build_vst3_component(comp, controller)
  return string.pack("<I4<I4", #comp, 1) .. comp .. (controller or ZERO8)
end

-- "3.8.21" -> 0x030815: one byte per component, as JUCE's version code.
function M.version_int(text)
  local parts = {}
  local n = 0
  for p in (text .. "."):gmatch("(.-)%.") do
    n = n + 1
    if n > 3 then break end
    parts[n] = require("reaporter.core.text").parse_int(p)
  end
  for k = n + 1, 3 do parts[k] = 0 end
  return (parts[1] << 16) | (parts[2] << 8) | parts[3]
end

return M
