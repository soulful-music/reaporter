-- Relab LX480 (FORMATS.md, "Relab"), two plugins:
-- * LX480 v4: .lx480 XML presets; the plugin state is a tagged binary of float blocks. Only
--   the v4 file layout (EngineA / EngineB / Session) converts; the legacy layout needs the
--   plugin's own migration and is reported as a failure.
-- * LX480 Dual Engine (4.1): its preset browser's SQLite database and its .lx480pack
--   exports, many presets per file; the state is JUCE copyXmlToBinary of <LX480> with one
--   PARAM per parameter in plain units, the values the browser stores.
local json = require("reaporter.codec.json")
local juce = require("reaporter.codec.juce")
local sqlite = require("reaporter.codec.sqlite")
local xml = require("reaporter.codec.xml")
local text = require("reaporter.core.text")

local M = { vendor = "Relab", key = "relab" }

M.ENGINE_FLOATS = 96
-- XML Session field -> 0-based slot of the session block, measured one slot at a time.
-- Slot 0 is Bypass, 16 / 17 Input / Output Link (not in preset files).
M.SESSION_SLOTS = {
  EngineMode = 1, IOType = 2, IONoise = 3, Resonance = 4, AB = 5, Mode = 6,
  GainInputLeft = 9, GainInputRight = 10, GainOutputLeft = 11, GainOutputRight = 12,
  Truncation = 13, ModulationTruncation = 14, DSPSaturation = 15,
  TempoSyncEnableReverb = 22, TempoSyncEnablePredelay = 23, TempoSyncEnableTwinDelay = 24,
}
-- A fresh instance's values for the session slots and the GUI block; every other float
-- of a fresh state is 0. (0-based slot = value)
local SESSION_DEFAULTS = { [9] = 5.0, [10] = 5.0, [11] = 8.8, [12] = 8.8, [13] = 1.0, [14] = 1.0, [15] = 1.0 }
local GUI_DEFAULTS = { [8] = 1.0, [9] = 120.0 }
local SESSION_FLOATS, GUI_FLOATS = 25, 22

-- One float32, refusing a finite value too large for it.
local function f32(v)
  if v == v and v ~= math.huge and v ~= -math.huge then
    local r = string.unpack("<f", string.pack("<f", v))
    if r == math.huge or r == -math.huge then
      error("float too large to pack", 0)
    end
  end
  return string.pack("<f", v)
end

local function block(tag, floats)
  local body = {}
  for i = 1, #floats do body[i] = f32(floats[i]) end
  return tag .. string.pack("<I4<I4<I4", 8 + 4 * #floats, 0, #floats) .. table.concat(body)
end

local function filled(n, defaults)
  local t = {}
  for i = 1, n do t[i] = defaults[i - 1] or 0.0 end
  return t
end

-- {EngineA = {{tag, value}...}, EngineB = ..., Session = ...} of a v4 preset.
function M.preset_fields(bytes)
  local root = xml.parse(bytes)
  if not xml.find(root, "EngineA") then error("legacy LX480 preset layout (no EngineA)", 0) end
  local out = {}
  for _, sec in ipairs({ "EngineA", "EngineB", "Session" }) do
    local el = xml.find(root, sec)
    if not el then error("no " .. sec, 0) end
    local fields = {}
    for _, k in ipairs(el.children) do
      local v = xml.get(k, "Value")
      if v == nil then error(sec .. "." .. k.tag .. " has no Value", 0) end
      fields[#fields + 1] = { k.tag, text.parse_float(v) }
    end
    out[sec] = fields
  end
  return out
end

-- The plugin's path field: the classic Mac path of the preset (":Macintosh HD:Library:...").
local function preset_path(path)
  if path:sub(1, 1) == "/" then return ":Macintosh HD" .. path:gsub("/", ":") end
  return path
end

function M.v4_state(bytes, path)
  local f = M.preset_fields(bytes)
  local engines = {}
  for _, sec in ipairs({ "EngineA", "EngineB" }) do
    local vals = {}
    for _, kv in ipairs(f[sec]) do vals[#vals + 1] = kv[2] end
    if #vals ~= M.ENGINE_FLOATS then
      error(("%s: %d values for a block of %d"):format(sec, #vals, M.ENGINE_FLOATS), 0)
    end
    engines[sec] = vals
  end
  local session = filled(SESSION_FLOATS, SESSION_DEFAULTS)
  for _, kv in ipairs(f.Session) do
    local slot = M.SESSION_SLOTS[kv[1]]
    if not slot then error("unknown Session field " .. kv[1], 0) end
    session[slot + 1] = kv[2]
  end
  local name = preset_path(path)
  local comp = "PHXF" .. string.pack("<I4", 1) .. "pwen" .. string.pack("<I4", 0)
    .. block("tsrp", engines.EngineA)
    .. block("srpn", session)
    .. block("IUG_", filled(GUI_FLOATS, GUI_DEFAULTS))
    .. block("2srp", engines.EngineB)
    .. block("lsrp", filled(M.ENGINE_FLOATS, {}))
    .. "MNSP" .. string.pack("<I4", #name) .. name
    .. ("\0"):rep(16) .. juce.PRIVATE_MAGIC
  return juce.build_vst3_component(comp)
end

---------------------------------------------------------------------------------------
-- LX480 Dual Engine

-- The plugin's parameter ids in its own order (lockedParameters of a fresh 4.1.1 state).
M.PARAM_IDS = {}
for id in ([[
bypass ioMode ioNoise inputLink inputGainLeft inputGainRight outputLink outputGainLeft outputGainRight
routingConfig truncation saturation error modTruncation syncReverbTime syncPreDelay syncTwinDelay
]] .. (function()
  local per = [[
algorithm reverbTimeMid shape spread size outHighFreq predelay revBassMultiply revBassCrossover
revHighMultiply revHighCrossover revFilterType width outLowFreq outLowShelf outHighShelf outFilterType
chorusType chorusRate chorusDepth diffusion channelOptimization decayOptimization reverbLevel mix time1
time2 time3 time4 time5 time6 level1 level2 level3 level4 level5 level6 inputDelay lateReverbLevel spin
wander mixERRev mode masterMultiplier freqLeft shelfLeft freqRight shelfRight dryLevelLeft dryLevelRight
panLeft panRight fineLeft fineRight feedback1 feedback2 feedback3 feedback4 twinTime1 twinTime2 twinTime3
twinTime4 leftLevel rightLevel effect speakerAngle lrBoost
]]
  local sync = "syncRateReverbTime syncRatePredelay syncRateTime1 syncRateTime2 syncRateTime3 syncRateTime4"
  local function engine(n, list) return (list:gsub("(%S+)", "e" .. n .. "_%1")) end
  return engine(1, per) .. " " .. engine(2, per) .. " engine " .. engine(1, sync) .. " " .. engine(2, sync)
end)()):gmatch("%S+") do M.PARAM_IDS[#M.PARAM_IDS + 1] = id end

local KNOWN_ID = {}
for _, id in ipairs(M.PARAM_IDS) do KNOWN_ID[id] = true end

-- A fresh instance's GUI state, kept as it is: which preset the browser shows, panels.
local TRANSIENT = '<transient currentSlot="0" presetId="77429f7f81cf463f9202e237f7c4c9e2"'
  .. ' packAssociatedWithPresetId="" packId="" guiMode="1" accentHue="0" mode="1" panel="0"'
  .. ' setupPanelTab="0" advancedPanelTab="0" hardwarePage="0" advancedPage="0"/>'

local function locked_parameters()
  local parts = {}
  for _, id in ipairs(M.PARAM_IDS) do parts[#parts + 1] = id .. '="0"' end
  parts[#parts + 1] = 'applicationSettings.faderMappings.engine1="0"'
  parts[#parts + 1] = 'applicationSettings.faderMappings.engine2="0"'
  return "<lockedParameters " .. table.concat(parts, " ") .. "/>"
end
local LOCKED = locked_parameters()

local function attr(v)
  return (v:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
    :gsub("\n", "&#10;"):gsub("\r", "&#13;"):gsub("\t", "&#9;"))
end

local function scalar(v, what)
  if type(v) == "string" then return v end
  if math.type(v) == "integer" then return tostring(v) end
  if math.type(v) == "float" then return json.float_repr(v) end
  error(what .. " is not a string or a number", 0)
end

-- <engineN a="..." .../> of one fader-mapping object, keys in the preset's order.
local function mapping(tag, obj)
  if obj == nil then return "<" .. tag .. "/>" end
  if not json.is_object(obj) then error("faderMappings." .. tag .. " is not an object", 0) end
  local parts = { "<" .. tag }
  for _, k in ipairs(json.keys(obj)) do
    if not k:match("^[%a_][%w_]*$") then error("faderMappings." .. tag .. ": bad key " .. k, 0) end
    parts[#parts + 1] = (' %s="%s"'):format(k, attr(scalar(obj[k], "faderMappings." .. tag .. "." .. k)))
  end
  return table.concat(parts) .. "/>"
end

-- The plugin's state XML for one preset's `data` JSON (as the browser stores it).
function M.dual_xml(data)
  local ok, doc = pcall(json.decode, data)
  if not ok or not json.is_object(doc) then error("preset data is not a JSON object", 0) end
  if doc.applicationTag ~= "LX480" then error("preset data is not an LX480 preset", 0) end
  local version = doc.version
  if type(version) ~= "string" or not version:match("^4%.%d+%.%d+$") then
    error("preset version " .. tostring(version) .. " (only 4.x is measured)", 0)
  end
  local params = doc.parameters
  if type(params) ~= "table" or json.is_object(params) then error("preset has no parameter list", 0) end
  local values, n = {}, 0
  for _, p in ipairs(params) do
    if not json.is_object(p) or type(p.id) ~= "string" then error("parameter without an id", 0) end
    if not KNOWN_ID[p.id] then error("unknown parameter " .. p.id, 0) end
    if values[p.id] then error("parameter " .. p.id .. " twice", 0) end
    local v = scalar(p.value, "parameter " .. p.id)
    text.parse_float(v)
    values[p.id] = v
    n = n + 1
  end
  if n ~= #M.PARAM_IDS then
    error(("%d parameters, the plugin has %d"):format(n, #M.PARAM_IDS), 0)
  end
  local fm = json.is_object(doc.applicationSettings) and doc.applicationSettings.faderMappings or nil
  if fm ~= nil and not json.is_object(fm) then error("faderMappings is not an object", 0) end
  local ids = {}
  for id in pairs(values) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = { ('<?xml version="1.0" encoding="UTF-8"?> <LX480 version="%s">'):format(version),
    "<applicationSettings><faderMappings>", mapping("engine1", fm and fm.engine1),
    mapping("engine2", fm and fm.engine2), "</faderMappings></applicationSettings>" }
  for _, id in ipairs(ids) do out[#out + 1] = ('<PARAM id="%s" value="%s"/>'):format(id, attr(values[id])) end
  out[#out + 1] = TRANSIENT
  out[#out + 1] = LOCKED
  out[#out + 1] = "</LX480>"
  return table.concat(out)
end

-- copyXmlToBinary ("VC2!", u32 length, the XML, a NUL), then JUCE's empty private data.
function M.dual_state(data)
  local x = M.dual_xml(data)
  local comp = "VC2!" .. string.pack("<I4", #x) .. x .. "\0" .. ("\0"):rep(16) .. juce.PRIVATE_MAGIC
  return juce.build_vst3_component(comp)
end

local function by_id(rows, field)
  local out = {}
  for _, r in ipairs(rows or {}) do
    if type(r.id) == "string" then out[r.id] = r[field] end
  end
  return out
end

-- The members of the preset browser's database (sqlite): one per preset row, filed under
-- its first pack, with its tags; by pack, then name (the rows are in no useful order).
function M.db_members(bytes)
  local db = sqlite.open(bytes)
  local tables = sqlite.tables(db)
  local presets = sqlite.select(db, "preset", tables)
  if not presets then error("no preset table", 0) end
  local pack_name = by_id(sqlite.select(db, "pack", tables), "name")
  local tag_name = by_id(sqlite.select(db, "tag", tables), "name")
  local packs, tags = {}, {}
  for _, r in ipairs(sqlite.select(db, "preset_pack", tables) or {}) do
    if pack_name[r.pack_id] and not packs[r.preset_id] then packs[r.preset_id] = pack_name[r.pack_id] end
  end
  for _, r in ipairs(sqlite.select(db, "preset_tag", tables) or {}) do
    local name = tag_name[r.tag_id]
    if name and r.preset_id then
      tags[r.preset_id] = tags[r.preset_id] or {}
      table.insert(tags[r.preset_id], name)
    end
  end
  local out = {}
  for _, r in ipairs(presets) do
    if type(r.id) == "string" and type(r.name) == "string" then
      out[#out + 1] = { key = r.id, name = r.name, folder = { packs[r.id] }, tags = tags[r.id] or {},
        bytes = type(r.data) == "string" and r.data or "" }
    end
  end
  local function key(m) return text.lower(m.folder[1] or "") .. "\0" .. text.lower(m.name) .. "\0" .. m.key end
  table.sort(out, function(x, y) return key(x) < key(y) end)
  return out
end

-- The members of a .lx480pack export: UTF-16 (or UTF-8) JSON of tags, packs and presets.
function M.pack_members(bytes)
  local body
  if bytes:sub(1, 2) == "\255\254" then
    body = text.utf16le_to_utf8(bytes:sub(3))
  else
    body = bytes:gsub("^\239\187\191", "")
  end
  local doc = json.decode(body)
  if not json.is_object(doc) or type(doc.presets) ~= "table" then error("not an LX480 pack", 0) end
  local tag_name, pack_name = {}, {}
  for _, t in ipairs(doc.tags or {}) do
    if json.is_object(t) and type(t.id) == "string" then tag_name[t.id] = t.name end
  end
  for _, p in ipairs(doc.packs or {}) do
    local pk = json.is_object(p) and p.pack
    if json.is_object(pk) and type(pk.id) == "string" then pack_name[pk.id] = pk.name end
  end
  local out = {}
  for _, e in ipairs(doc.presets) do
    local pr = json.is_object(e) and e.preset
    if json.is_object(pr) and type(pr.id) == "string" and type(pr.name) == "string" then
      local folder, tags = {}, {}
      for _, id in ipairs(e.associatedPackIds or {}) do
        if type(pack_name[id]) == "string" then
          folder[1] = pack_name[id]
          break
        end
      end
      for _, id in ipairs(e.associatedTagIds or {}) do
        if type(tag_name[id]) == "string" then tags[#tags + 1] = tag_name[id] end
      end
      out[#out + 1] = { key = pr.id, name = pr.name, folder = folder, tags = tags,
        bytes = type(pr.data) == "string" and pr.data or "" }
    end
  end
  return out
end

-- plugin.members: the browser database or a pack export.
function M.members(path, read)
  local bytes, why = read(path)
  if not bytes then error("unreadable: " .. tostring(why), 0) end
  if sqlite.is_sqlite(bytes) then return M.db_members(bytes) end
  return M.pack_members(bytes)
end

-- The folder the plugin's browser exports packs to (LX480.settings), or nil.
function M.export_dir(env)
  local bytes = env.fs.read(env.dirs.common .. "/Relab Development/LX480.settings")
  if not bytes then return nil end
  local ok, root = pcall(xml.parse, bytes)
  if not ok then return nil end
  for _, el in ipairs(root.children or {}) do
    if el.tag == "VALUE" and xml.get(el, "name") == "exportDirectory" then
      local dir = xml.get(el, "val")
      if dir and dir ~= "" then return (dir:gsub("\\", "/"):gsub("/+$", "")) end
    end
  end
  return nil
end

-- A pack member's bytes are its preset data; a whole file only gets here when its members
-- could not be read, and fails with the reason.
function M.to_state(bytes, path, plugin)
  if not (plugin and plugin.dual) then return M.v4_state(bytes, path) end
  local ok, state = pcall(M.dual_state, bytes)
  if ok then return state end
  if bytes:find("^%s*{") then error(state, 0) end
  local mok, list = pcall(plugin.members, path, function() return bytes end)
  if mok then error(("the file holds %d presets"):format(#list), 0) end
  error(list, 0)
end

function M.plugins(env)
  local dual_roots = { env.dirs.shared .. "/Relab Development/LX480/Presets" }
  local export = M.export_dir(env)
  if export then dual_roots[#dual_roots + 1] = export end
  return {
    {
      fx_name = "VST3: LX480 v4 (Relab Development)",
      bundle = "LX480_v4",
      roots = { env.dirs.common .. "/Relab Development/LX480/Presets" },
      exts = { ".lx480" },
      pins = { 2, 2 }, -- in, out on a stereo track (REAPER 7.82, macOS)
    },
    {
      fx_name = "VST3: Relab LX480 Dual Engine Reverb (Relab Development)",
      bundle = "LX480",
      ini_name = "vst3-LX480.ini", -- REAPER names it after the bundle
      roots = dual_roots,
      exts = { ".lx480", ".lx480pack" },
      flat = true,
      dual = true,
      members = M.members,
      pins = { 2, 2 },
    },
  }
end

return M
