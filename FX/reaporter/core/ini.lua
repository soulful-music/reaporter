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

-- The one reading of a preset file's sections and keys, shared by listed_names and the
-- merge so both see the same entries. Lines end at LF (a CR before it is trimmed);
-- leading and trailing ASCII whitespace is trimmed; a line starting "[" with a "]" is a
-- section, named by what lies between them; section and key names ignore case. Of
-- [General] and of each [PresetK], the first counts, and of their keys the first. Data
-- values are never copied, so a 200 MB file reads in a few hundredths of a second. Returns
-- {nb_value, nb_eq and nb_to (where the NbPresets value lies), names = {[K] = first Name=
-- or false}, numbers (every K seen, in order), dups (repeated section names)}.
local function read(body)
  local r = { names = {}, numbers = {}, dups = {} }
  local section, seen_general = nil, false
  local start, n = 1, #body
  while start <= n do
    local nl = body:find("\n", start, true)
    local stop = (nl or n + 1) - 1
    local c = body:find("[^ \t\r\v\f]", start)
    if c and c <= stop then
      local close = body:byte(c) == 91 and body:find("]", c, true)
      if close and close <= stop then
        local name = text.strip_ascii(body:sub(c + 1, close - 1)):lower()
        local num = name:match("^preset(%d+)$")
        if name == "general" then
          if seen_general then r.dups[#r.dups + 1] = "[General]" end
          section = not seen_general and "general" or nil
          seen_general = true
        elseif num then
          local k = tonumber(num)
          r.numbers[#r.numbers + 1] = k
          if r.names[k] == nil then
            section = k
            r.names[k] = false
          else
            r.dups[#r.dups + 1] = "[Preset" .. num .. "]"
            section = nil
          end
        else
          section = nil
        end
      elseif section ~= nil then
        local eq = body:find("=", c, true)
        if eq and eq <= stop then
          local key = text.strip_ascii(body:sub(c, eq - 1)):lower()
          if section == "general" and key == "nbpresets" and r.nb_value == nil then
            r.nb_value, r.nb_eq, r.nb_to = body:sub(eq + 1, stop), eq, stop
          elseif math.type(section) == "integer" and key == "name" and r.names[section] == false then
            r.names[section] = text.strip_ascii(body:sub(eq + 1, stop))
          end
        end
      end
    end
    if not nl then break end
    start = nl + 1
  end
  return r
end

local function body_of(data)
  return text.starts_with(data, BOM) and data:sub(4) or data
end

-- The names REAPER lists from a preset file: entries [Preset0] .. [Preset{NbPresets-1}],
-- as `read` sees them; none without a readable NbPresets.
function M.listed_names(data)
  local r = read(body_of(data))
  local nb = r.nb_value and text.strip_ascii(r.nb_value):match("^%d+$") and tonumber(r.nb_value)
  if not nb then return {} end
  local out = {}
  for k = 0, nb - 1 do
    if r.names[k] and r.names[k] ~= "" then out[#out + 1] = r.names[k] end
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
-- "vst3-Tai Chi.ini". REAPER's channel-count suffix goes first: "VST3: Blackhole
-- Immersive (Eventide) (16ch)" -> "vst3-Blackhole Immersive.ini" (measured).
function M.preset_file_name(fx_name)
  local name = fx_name:gsub("^VST3i?: ", "")
  name = name:gsub(" %(%d+ch%)$", "")
  name = name:gsub(" %([^()]*%)$", "")
  return "vst3-" .. name .. ".ini"
end

-- Scan an existing file for what a merge needs. Returns {body, bom, nb, nb_eq, nb_to, taken} or
-- raises for a file the merge must not touch, where a guess could lose an entry: a CR
-- not followed by LF, no NbPresets or one that is not a whole number, a repeated
-- section, or an entry past NbPresets. `taken` holds every entry name, lowercased.
function M.inspect(existing)
  local body = body_of(existing)
  local cr = body:find("\r", 1, true)
  while cr do
    if body:byte(cr + 1) ~= 10 then
      error("a line ends in CR alone; REAPER's own files end lines in CRLF or LF", 0)
    end
    cr = body:find("\r", cr + 2, true)
  end
  local r = read(body)
  if r.nb_value == nil then error("no readable NbPresets", 0) end
  if not r.nb_value:find("^%s*%d+%s*$") then
    error(("NbPresets=%s is not a whole number"):format(r.nb_value), 0)
  end
  local nb = math.tointeger(tonumber(r.nb_value))
  if not nb then error(("NbPresets=%s is out of range"):format(r.nb_value), 0) end
  if #r.dups > 0 then error("repeated sections: " .. table.concat(r.dups, ", "), 0) end
  local past = {}
  for _, k in ipairs(r.numbers) do
    if k >= nb then past[#past + 1] = k end
  end
  table.sort(past)
  if #past > 0 then
    error(("entries past NbPresets=%d: %s"):format(nb, table.concat(past, ", ")), 0)
  end
  local taken = {}
  for k = 0, nb - 1 do
    local name = r.names[k]
    if name then taken[text.lower(name)] = true end
  end
  return { body = body, bom = body ~= existing, nb = nb, nb_eq = r.nb_eq, nb_to = r.nb_to, taken = taken }
end

-- The last line of `s` with its terminator.
local function last_line(s)
  local i = #s
  if s:byte(i) == 10 then i = i - 1 end
  while i > 0 and s:byte(i) ~= 10 do i = i - 1 end
  return s:sub(i + 1)
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
  local value = f.body:sub(f.nb_eq + 1, f.nb_to)
  local a, b = value:find("%d+")
  local out = f.body:sub(1, f.nb_eq) .. value:sub(1, a - 1) .. tostring(f.nb + #add) .. value:sub(b + 1)
    .. f.body:sub(f.nb_to + 1)
  if out:sub(-1) ~= "\n" then out = out .. eol end
  if text.strip_ascii(last_line(f.body)) ~= "" then out = out .. eol end
  local tail = table.concat(M.entry_lines(add, f.nb), eol) .. eol
  return (f.bom and BOM or "") .. out .. tail, added, skipped
end

return M
