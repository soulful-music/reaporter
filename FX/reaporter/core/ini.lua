-- REAPER's user-preset file for a plugin (<resource>/presets/vst3-<name>.ini): entry bytes,
-- writing, reading names and an append-only merge. Pure Lua 5.4. Layout in FORMATS.md,
-- "REAPER user-preset file".
local text = require("reaporter.core.text")

local M = {}

M.DATA_PART = 16 * 1024
M.MAGIC = 0xFEED5EEE
local BOM = "\239\187\191"

local function masks(n)
  local out = {}
  for i = 0, n - 1 do out[#out + 1] = string.pack("<I8", 1 << i) end
  return table.concat(out)
end

-- The bytes of one [PresetK] entry: `chunk` is the raw vst_chunk, nin / nout the pins.
function M.entry_data(uid, chunk, name, nin, nout)
  nin, nout = nin or 2, nout or 2
  return string.pack("<I4<I4<i4", uid, M.MAGIC, nin) .. masks(nin) .. string.pack("<i4", nout)
    .. masks(nout) .. string.pack("<I4<I4<I4", #chunk, 1, 0x0010FFFF)
    .. chunk .. "\0" .. name .. "\0" .. string.pack("<I4", 0x10)
end

-- (uid, nin, nout, chunk, name) of an entry's bytes.
function M.parse_entry(data)
  local uid, magic, nin = string.unpack("<I4<I4<i4", data)
  assert(magic == M.MAGIC or magic == M.MAGIC + 1, "not a preset entry")
  local o = 13 + 8 * nin
  local nout = string.unpack("<i4", data, o)
  o = o + 4 + 8 * nout
  local clen = string.unpack("<I4", data, o)
  o = o + 12
  local chunk = data:sub(o, o + clen - 1)
  local name = data:sub(o + clen + 1):match("^[^\0]*")
  return uid, nin, nout, chunk, name
end

local HEX = {}
for i = 0, 255 do HEX[string.char(i)] = ("%02X"):format(i) end

local function hex(s) return (s:gsub(".", HEX)) end

local function checksum(s)
  local sum = 0
  for i = 1, #s do sum = sum + s:byte(i) end
  return sum % 256
end

-- The Data= / Data_N= lines of one entry's bytes: 16 KiB parts, hex with a checksum byte.
function M.data_lines(data)
  local out = {}
  local i = 0
  repeat
    local part = data:sub(i + 1, i + M.DATA_PART)
    local key = i == 0 and "Data" or ("Data_%d"):format(i // M.DATA_PART)
    out[#out + 1] = key .. "=" .. hex(part .. string.char(checksum(part)))
    i = i + M.DATA_PART
  until i >= math.max(#data, 1)
  return out
end

-- The [PresetK] sections for {{name, data, data lines or nil}, ...}, K from `start`, each
-- ending blank.
function M.entry_lines(entries, start)
  local out = {}
  for n, e in ipairs(entries) do
    local name, data = e[1], e[2]
    out[#out + 1] = ("[Preset%d]"):format((start or 0) + n - 1)
    for _, l in ipairs(e[3] or M.data_lines(data)) do out[#out + 1] = l end
    out[#out + 1] = ("Len=%d"):format(#data)
    out[#out + 1] = "Name=" .. name
    out[#out + 1] = ""
  end
  return out
end

-- A whole preset file from {{name, data}, ...}, in REAPER's key order and CRLF lines.
function M.ini_bytes(entries, eol)
  eol = eol or "\r\n"
  local lines = { "[General]", ("NbPresets=%d"):format(#entries), "" }
  for _, l in ipairs(M.entry_lines(entries, 0)) do lines[#lines + 1] = l end
  return table.concat(lines, eol) .. eol
end

-- Split bytes into lines at \n, \r\n or \r, each keeping its terminator.
local function split_keepends(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local j = s:find("[\r\n]", i)
    if not j then
      out[#out + 1] = s:sub(i)
      break
    end
    if s:sub(j, j + 1) == "\r\n" then j = j + 1 end
    out[#out + 1] = s:sub(i, j)
    i = j + 1
  end
  return out
end

local function strip_eol(l) return (l:gsub("[\r\n]+$", "")) end

-- The names REAPER lists from a preset file: entries [Preset0] .. [Preset{NbPresets-1}],
-- the first section of each number, its first Name=; none without a readable NbPresets.
function M.listed_names(data)
  local body = text.starts_with(data, BOM) and data:sub(4) or data
  local section, nb, names, seen_general = nil, nil, {}, false
  local start = 1
  while start <= #body + 1 do
    local nl = body:find("\n", start, true)
    local raw = body:sub(start, (nl or #body + 1) - 1)
    start = (nl or #body + 1) + 1
    local line = text.strip_ascii(raw)
    if line:sub(1, 1) == "[" and line:find("]", 1, true) then
      local name = text.strip_ascii(line:sub(2, line:find("]", 1, true) - 1))
      local num = name:lower():match("^preset(%d+)$")
      if name:lower() == "general" and not seen_general then
        section, seen_general = "general", true
      elseif num and names[tonumber(num)] == nil then
        section = tonumber(num)
        names[section] = false
      else
        section = nil
      end
    elseif line:find("=", 1, true) then
      local key, value = line:match("^(.-)=(.*)$")
      key = text.strip_ascii(key):lower()
      if section == "general" and key == "nbpresets" and nb == nil then
        local v = text.strip_ascii(value)
        nb = v:match("^%d+$") and tonumber(v) or -1
      elseif math.type(section) == "integer" and key == "name" and names[section] == false then
        names[section] = text.strip_ascii(value)
      end
    end
    if not nl then break end
  end
  if nb == nil or nb < 0 then return {} end
  local out = {}
  for k = 0, nb - 1 do
    if names[k] and names[k] ~= "" then out[#out + 1] = names[k] end
  end
  return out
end

-- Read a preset file: {{name, data}, ...} in NbPresets order, checksums verified.
function M.read_ini(bytes)
  local secs, cur = {}, nil
  for line in (bytes:gsub("\r\n?", "\n") .. "\n"):gmatch("(.-)\n") do
    local s = line:match("^%[(.+)%]%s*$")
    if s then
      secs[s] = secs[s] or {}
      cur = secs[s]
    elseif cur and line:find("=", 1, true) then
      local k, v = line:match("^(.-)=(.*)$")
      cur[k] = v
    end
  end
  local out = {}
  local nb = tonumber((secs.General or {}).NbPresets or 0)
  for k = 0, nb - 1 do
    local s = assert(secs["Preset" .. k], "missing Preset" .. k)
    local keys = {}
    for key in pairs(s) do
      if key == "Data" or key:match("^Data_%d+$") then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b)
      return (a == "Data" and 0 or tonumber(a:sub(6))) < (b == "Data" and 0 or tonumber(b:sub(6)))
    end)
    local data = {}
    for _, key in ipairs(keys) do
      local b = s[key]:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
      if checksum(b:sub(1, -2)) ~= b:byte(-1) then error(("checksum Preset%d %s"):format(k, key)) end
      data[#data + 1] = b:sub(1, -2)
    end
    data = table.concat(data)
    if #data ~= tonumber(s.Len) then error(("Len Preset%d"):format(k)) end
    out[#out + 1] = { s.Name, data }
  end
  return out
end

-- The file REAPER uses for a VST3's user presets: "VST3: Tai Chi (Reverb Foundry)" ->
-- "vst3-Tai Chi.ini".
function M.preset_file_name(fx_name)
  local name = fx_name:gsub("^VST3i?: ", "")
  name = name:gsub(" %([^()]*%)$", "")
  return "vst3-" .. name .. ".ini"
end

-- Scan an existing file for what a merge needs. Returns {lines, nb_at, nb, taken} or
-- raises for a file the merge must not touch: [PresetK] without a readable NbPresets,
-- or an entry past it. `taken` holds every entry name, lowercased.
function M.inspect(existing)
  local body = text.starts_with(existing, BOM) and existing:sub(4) or existing
  local lines = split_keepends(body)
  local section, nb_at, nb, presets, names = nil, nil, nil, {}, {}
  for i, raw in ipairs(lines) do
    local line = strip_eol(raw)
    local s = line:match("^%[(.+)%]%s*$")
    if s then
      section = s
      local k = s:match("^Preset(%d+)$")
      if k then presets[#presets + 1] = tonumber(k) end
    elseif line:find("=", 1, true) then
      local key, value = line:match("^(.-)=(.*)$")
      local lkey = text.strip_ascii(key):lower()
      if section == "General" and lkey == "nbpresets" and nb_at == nil then
        nb_at, nb = i, text.parse_int(value)
      elseif section and text.starts_with(section, "Preset") and lkey == "name" then
        names[section] = text.strip(value)
      end
    end
  end
  if nb == nil then error("no readable NbPresets", 0) end
  local past = {}
  table.sort(presets)
  for _, k in ipairs(presets) do
    if k >= nb and past[#past] ~= k then past[#past + 1] = k end
  end
  if #past > 0 then
    error(("entries past NbPresets=%d: %s"):format(nb, table.concat(past, ", ")), 0)
  end
  local taken = {}
  for k = 0, nb - 1 do
    local n = names["Preset" .. k]
    if n then taken[text.lower(n)] = true end
  end
  return { body = body, bom = body ~= existing, lines = lines, nb_at = nb_at, nb = nb, taken = taken }
end

-- Append {{name, data}, ...} to a preset file's bytes, keeping every existing byte except
-- the NbPresets digits. A name the file has (ignoring case) is skipped. Returns
-- (bytes, added names, skipped names); raises for a file it must not touch (inspect).
function M.merge(existing, entries)
  if not existing or existing == "" then
    local added = {}
    for _, e in ipairs(entries) do added[#added + 1] = e[1] end
    return M.ini_bytes(entries), added, {}
  end
  local f = M.inspect(existing)
  local eol = (f.body:find("\r\n", 1, true) or not f.body:find("\n", 1, true)) and "\r\n" or "\n"
  local add, added, skipped = {}, {}, {}
  for _, e in ipairs(entries) do
    local key = text.lower(e[1])
    if f.taken[key] then
      skipped[#skipped + 1] = e[1]
    else
      f.taken[key] = true
      add[#add + 1] = e
      added[#added + 1] = e[1]
    end
  end
  if #add == 0 then return existing, {}, skipped end
  local lines = f.lines
  local old = lines[f.nb_at]
  local bare = strip_eol(old)
  local term = old:sub(#bare + 1)
  local a, b = bare:find("%d+")
  lines[f.nb_at] = bare:sub(1, a - 1) .. tostring(f.nb + #add) .. bare:sub(b + 1) .. term
  local out = table.concat(lines)
  if out ~= "" and out:sub(-1) ~= "\n" then out = out .. eol end
  if #lines > 0 and text.strip_ascii(lines[#lines]) ~= "" then out = out .. eol end
  local tail = table.concat(M.entry_lines(add, f.nb), eol) .. eol
  return (f.bom and BOM or "") .. out .. tail, added, skipped
end

return M
