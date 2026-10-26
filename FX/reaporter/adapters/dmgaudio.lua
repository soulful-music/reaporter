-- DMGAudio: a preset file is "ZIP " + zlib(JSON) (or the JSON as is); so is the plugin
-- state. The preset's keys are laid over the state of a fresh instance (FORMATS.md,
-- "DMGAudio"; the fresh states are in dmgaudio_fresh.lua).
local fresh_states = require("reaporter.adapters.dmgaudio_fresh")
local json = require("reaporter.codec.json")
local failed = require("reaporter.core.failed")
local zlib = require("reaporter.codec.zlib")

local M = { vendor = "DMGAudio", key = "dmgaudio" }

local ZIP = "ZIP "
local AB_SLOTS = 8

-- folder (and bundle), preset extension. Pins (in, out) on a stereo track, REAPER 7.82
-- macOS: main plus sidechain.
local PLUGINS = {
  { "Multiplicity", ".multiplicitypreset" },
  { "Expurgate", ".exp" },
  { "Essence", ".ess" },
}
local PINS = { 4, 2 }

-- The JSON document of a preset file or a plugin state: zipped or plain, trailing NULs
-- dropped.
function M.read_json(bytes)
  if bytes:sub(1, 4) == ZIP then bytes = zlib.inflate(bytes:sub(5)) end
  local body = bytes:gsub("%z+$", "")
  if body:sub(1, 3) == "\239\187\191" then error("JSON starts with a byte order mark", 0) end
  return json.decode(body)
end

-- Python-style truth: null, false, 0, "" and empty containers are false.
local function truthy(v)
  if v == nil or v == json.null or v == false or v == 0 or v == "" then return false end
  if type(v) == "table" then return next(v) ~= nil end
  return true
end

local function has(obj, k) return obj[k] ~= nil end

-- int(x) as Python takes it for the current A/B slot.
local function to_int(v)
  if math.type(v) == "integer" then return v end
  if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
    return math.tointeger(v >= 0 and math.floor(v) or math.ceil(v))
  end
  if type(v) == "boolean" then return v and 1 or 0 end
  if type(v) == "string" then
    local n = v:match("^%s*([+-]?%d+)%s*$")
    if n then return math.tointeger(tonumber(n)) end
  end
  error("currentAB is not an integer", 0)
end

-- The plugin state document for a preset: the fresh state, the file's top-level keys over it.
function M.state_doc(bytes, fresh)
  local doc = M.read_json(bytes)
  if not json.is_object(doc) then error("not a JSON object", 0) end
  local state = M.read_json(fresh)
  if not json.is_object(state) then failed.environment("the fresh state is not a JSON object") end
  if not has(doc, "presets") then
    -- Multiplicity: one preset's parameters and name at the top level. It goes into
    -- presets[1] and the A/B slot the file's settings make current, as the plugin writes
    -- its own state.
    if not json.is_object(doc.parameters) then error("no presets list and no top-level parameters", 0) end
    local params = json.remove(doc, "parameters")
    local name = json.remove(doc, "name")
    if name == nil then name = "" end
    local preset = json.object()
    json.set(preset, "parameters", params)
    json.set(preset, "name", name)
    json.set(doc, "presets", { preset })
    local settings = truthy(doc.settings) and doc.settings or json.object()
    if not json.is_object(settings) then error("settings is not an object", 0) end
    local cur = settings.currentAB
    cur = cur == nil and 0 or to_int(cur)
    local ab = {}
    for i = 0, AB_SLOTS - 1 do
      local slot = json.object()
      json.set(slot, "parameters", i == cur and params or "default")
      ab[#ab + 1] = slot
    end
    json.set(doc, "ab", ab)
    -- v101 marks the plugin's current parameter layout; a file without it is older, and
    -- the plugin migrates it only when the state lacks it too.
    json.remove(state, "v101")
  end
  if not truthy(doc.presets) then error("empty presets list", 0) end
  for _, k in ipairs(json.keys(doc)) do json.set(state, k, doc[k]) end
  return state
end

function M.plugins(env)
  local root = env.dirs.common .. "/DMGAudio"
  local out = {}
  for _, p in ipairs(PLUGINS) do
    out[#out + 1] = {
      fx_name = "VST3: " .. p[1] .. " (DMGAudio)",
      bundle = p[1],
      roots = { root .. "/" .. p[1] .. "/Presets" },
      exts = { p[2] },
      pins = PINS,
      fresh = fresh_states[p[1]],
    }
  end
  return out
end

-- plugin.fresh: a fresh instance's plugin state.
function M.to_state(bytes, _, plugin)
  if not plugin.fresh then failed.environment("no fresh plugin state to start from") end
  local text = json.encode_python(M.state_doc(bytes, plugin.fresh), "\t") .. "\0"
  local comp = ZIP .. zlib.store(text)
  return string.pack("<I4<I4", #comp, 1) .. comp .. ("\0"):rep(8)
end

return M
