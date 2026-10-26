-- Relab LX480 v4: .lx480 XML presets; the plugin state is a tagged binary of float blocks
-- (FORMATS.md, "Relab"). Only the v4 file layout (EngineA / EngineB / Session) converts;
-- the legacy layout needs the plugin's own migration and is reported as a failure.
local juce = require("reaporter.codec.juce")
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

function M.to_state(bytes, path)
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

function M.plugins(env)
  return {
    {
      fx_name = "VST3: LX480 v4 (Relab Development)",
      bundle = "LX480_v4",
      roots = { env.dirs.common .. "/Relab Development/LX480/Presets" },
      exts = { ".lx480" },
    },
  }
end

return M
