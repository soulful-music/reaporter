-- FabFilter: an .ffp preset holds the plugin's parameters as floats, in the order of its
-- VST3 parameters; the plugin state holds the same floats in one of two containers
-- (FORMATS.md, "FabFilter"). Only the layouts measured to load as they are convert.
local text = require("reaporter.core.text")

local M = { vendor = "FabFilter", key = "fabfilter" }

-- folder, container, magic, accepted "version/count" layouts, instance name (FFBS), pins
-- (in, out on a stereo track, REAPER 7.82 macOS), instrument. Accepted, each measured: the
-- plugin's own layout (its Default Setting file, a fresh instance's count) and older counts
-- a fresh instance loads as the same floats plus defaults. Timeless 2 version 4 is not
-- accepted: only 14 of 19 of FabFilter's own version 5 re-saves keep its floats.
local PLUGINS = {
  { "Micro", "FabF", "FMic", { "1/8" }, nil, { 2, 2 } },
  { "Pro-C 2", "FabF", "FC2p", { "2/46" }, nil, { 4, 2 } },
  { "Pro-DS", "FabF", "FPSr", { "2/20" }, nil, { 4, 2 } },
  { "Pro-G", "FabF", "FPGr", { "2/34" }, nil, { 4, 2 } },
  { "Pro-L", "FabF", "FPLr", { "3/19" }, nil, { 4, 2 } },
  { "Pro-L 2", "FabF", "FL2p", { "2/31", "2/32" }, nil, { 4, 2 } },
  { "Pro-MB", "FabF", "FPMb", { "3/150", "3/151" }, nil, { 4, 2 } },
  { "Pro-Q 2", "FabF", "FQ2p", { "2/189", "2/190" }, nil, { 4, 2 } },
  { "Pro-Q 3", "FFBS", "FQ3p", { "4/334", "4/358" }, "Pro-Q", { 4, 2 } },
  { "Pro-Q 4", "FFBS", "FQ4p", { "4/576" }, "Pro-Q", { 4, 2 } },
  { "Pro-R", "FabF", "FPRr", { "4/85" }, nil, { 2, 2 } },
  { "Pro-R 2", "FFBS", "FR2p", { "6/136" }, "", { 2, 2 } },
  { "Saturn", "FabF", "FSat", { "4/893", "4/899" }, nil, { 4, 2 } },
  { "Saturn 2", "FFBS", "FS2a", { "4/951" }, "", { 4, 2 } },
  { "Simplon", "FabF", "FSim", { "1/17", "1/18" }, nil, { 2, 2 } },
  { "Timeless 2", "FabF", "FTms", { "5/705" }, nil, { 4, 2 } },
  { "Timeless 3", "FFBS", "F3Ts", { "10/1007" }, "", { 4, 2 } },
  { "Twin 2", "FabF", "FT2i", { "8/883" }, nil, { 2, 2 }, true },
  { "Twin 3", "FFBS", "FT3i", { "18/1288" }, "", { 2, 2 }, true },
  { "Volcano 2", "FabF", "FV2l", { "2/709" }, nil, { 4, 2 } },
  { "Volcano 3", "FFBS", "FV3l", { "5/896" }, "", { 4, 2 } },
}

-- Layouts known to load differently in the plugin than the file's floats, with the reason.
local NOT_CONVERTED = {
  ["Timeless 2 4/705"] = "FabFilter's own re-saves to version 5 change some floats, so the converted preset could sound different",
}

local EMPTY_CUSV = "CuSV" .. string.pack("<I4<I4", 1, 0)

local function u32(b, o)
  if o + 4 > #b then error("truncated", 0) end
  return (string.unpack("<I4", b, o + 1))
end

local function str(s) return string.pack("<I4", #s) .. s end

-- The CuSV block at the start of `b`, without the bytes after its last string.
function M.cusv_block(b)
  if b:sub(1, 4) ~= "CuSV" then error("no CuSV block after the parameters", 0) end
  local o = 12
  for _ = 1, u32(b, 8) * 2 do
    local n = u32(b, o)
    if o + 4 + n > #b then error("truncated CuSV block", 0) end
    o = o + 4 + n
  end
  return b:sub(1, o)
end

-- The CuSV block the plugin builds from a text preset's Author / Description / Tags.
local function cusv_from_text(head)
  local items = {}
  for _, kv in ipairs({ { "Author", "AUTHOR" }, { "Description", "DESCRIPTION" }, { "Tags", "TAGS" } }) do
    local v = head[kv[1]]
    if v then
      if kv[1] == "Description" and #v >= 2 and v:sub(1, 1) == '"' and v:sub(-1) == '"' then
        v = v:sub(2, -2):gsub("\\n", "\n")
      end
      items[#items + 1] = str(kv[2]) .. str(v)
    end
  end
  return "CuSV" .. string.pack("<I4<I4", 1, #items) .. table.concat(items)
end

-- A decimal number as the text form writes them: -?digits[.digits][e[+-]digits].
local function is_number(v)
  local rest = v:match("^%-?%d+(.*)$")
  if not rest then return false end
  rest = rest:match("^%.%d+(.*)$") or rest
  rest = rest:match("^[eE][-+]?%d+(.*)$") or rest
  return rest == ""
end

local function f32(v)
  local packed = string.pack("<f", v)
  local r = string.unpack("<f", packed)
  if (r == math.huge or r == -math.huge) and v ~= r then error("value too large for a float", 0) end
  return packed
end

-- (signature, version, float bytes, CuSV block) of a text preset.
local function parse_text(data)
  if not utf8.len(data) then error("text preset is not UTF-8", 0) end
  local head, params, sec = {}, {}, nil
  for line in (data .. "\n"):gmatch("(.-)\n") do
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line:sub(1, 1) == "[" and line:sub(-1) == "]" then
      sec = line:sub(2, -2)
    else
      local k, v = line:match("^([^=]*)=(.*)$")
      if k then
        if sec == "Parameters" then
          if not is_number(v) then error(k .. " is not a number", 0) end
          params[#params + 1] = f32(tonumber(v))
        elseif sec == "Preset" then
          head[k] = v
        end
      end
    end
  end
  if not head.Signature or not (head.Version or ""):match("^%d+$") then
    error("no Signature / Version in [Preset]", 0)
  end
  return head.Signature, math.tointeger(tonumber(head.Version)), table.concat(params), cusv_from_text(head)
end

-- (magic, version, count, float bytes, CuSV block or nil) of a preset file.
function M.parse(data)
  if data:sub(1, 9) == "[Preset]\n" or data:sub(1, 10) == "[Preset]\r\n" then
    local sig, ver, floats, cusv = parse_text(data)
    return sig, ver, #floats // 4, floats, cusv
  end
  if #data < 12 then error("too short for a preset", 0) end
  local magic, ver, count = data:sub(1, 4), u32(data, 4), u32(data, 8)
  local stop = 12 + 4 * count
  if stop > #data then error(("%d values do not fit in %d bytes"):format(count, #data), 0) end
  local tail = data:sub(stop + 1)
  return magic, ver, count, data:sub(13, stop), tail ~= "" and M.cusv_block(tail) or nil
end

-- A file's 4-byte magic as text: itself when printable ASCII, else 0x and its hex.
local function show_magic(m)
  if m:match("^[%w _%-]+$") then return m end
  return "0x" .. m:gsub(".", function(c) return ("%02x"):format(c:byte()) end)
end

-- The vst_chunk for a preset file's bytes, named `name`; raises with the reason when the
-- layout does not convert.
function M.state(data, name, plugin)
  local magic, ver, count, floats, cusv = M.parse(data)
  if magic ~= plugin.magic then
    error(("another plugin's preset layout (%s), not %s's"):format(show_magic(magic), plugin.folder), 0)
  end
  if not plugin.accepted[ver .. "/" .. count] then
    error(("%s preset layout version %d with %d values: %s"):format(plugin.folder, ver, count, (NOT_CONVERTED[plugin.folder .. " " .. ver .. "/" .. count] or "the plugin migrates it itself")), 0)
  end
  local comp, ctrl
  if plugin.container == "FabF" then
    comp = "FabF" .. string.pack("<I4", 2) .. str(name) .. string.pack("<I4<I4", 0, count) .. floats
      .. string.pack("<I4<I4", 1, 1)
    ctrl = string.pack("<I4<I4", 12, 0) .. "FFed" .. string.pack("<I4<I4", 0, 0)
  else
    comp = "FFBS" .. string.pack("<I4<I4", 1, count) .. floats .. "FFpr" .. string.pack("<I4<I4", 1, 0)
    local body = magic .. string.pack("<I4", 3) .. str(name) .. string.pack("<i4<I4", -1, 1) .. str(plugin.instance)
      .. string.pack("<I4", 0) .. (cusv or EMPTY_CUSV) .. "FFed" .. string.pack("<I4<I4", 0, 0)
    ctrl = string.pack("<I4<I4", #body, 0) .. body
  end
  return string.pack("<I4<I4", #comp, 1) .. comp .. ctrl
end

function M.plugins(env)
  local out = {}
  for _, p in ipairs(PLUGINS) do
    local accepted = {}
    for _, k in ipairs(p[4]) do accepted[k] = true end
    out[#out + 1] = {
      fx_name = (p[7] and "VST3i: " or "VST3: ") .. p[1] .. " (FabFilter)",
      bundle = "FabFilter " .. p[1]:gsub("%-", " "),
      -- REAPER names the preset file after the VST3 class name, not the listed name.
      ini_name = "vst3-FabFilter " .. p[1] .. ".ini",
      roots = { env.dirs.documents .. "/FabFilter/Presets/" .. p[1] },
      exts = { ".ffp" },
      pins = p[6],
      folder = p[1], container = p[2], magic = p[3], accepted = accepted, instance = p[5],
    }
  end
  return out
end

function M.to_state(bytes, path, plugin)
  return M.state(bytes, (text.splitext(text.basename(path))), plugin)
end

return M
