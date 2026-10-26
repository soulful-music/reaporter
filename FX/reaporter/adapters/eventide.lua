-- Eventide: .tide (JSON) and .tidex (JUCE XML) presets in the user's Music/Eventide folder,
-- one folder per plugin (FORMATS.md, "Eventide"). Every plugin folder is registered;
-- its Snapshots/ folder holds the plugin's snapshot slots, not presets.
local json = require("reaporter.codec.json")
local juce = require("reaporter.codec.juce")
local xml = require("reaporter.codec.xml")
local text = require("reaporter.core.text")

local M = { vendor = "Eventide", key = "eventide" }

-- Pin counts (in, out) as REAPER reports them on a stereo track, measured in REAPER 7.82 on
-- macOS: a preset entry carries pin masks REAPER applies on load. A plugin missing here is
-- measured once in REAPER before its first conversion.
local PINS = {
  Blackhole = { 2, 2 }, ["Blackhole Immersive"] = { 2, 2 }, CrushStation = { 2, 2 }, Crystals = { 2, 2 },
  EChannel = { 4, 2 }, EQ45 = { 2, 2 }, EQ65 = { 2, 2 }, ["H3000 Band Delays"] = { 2, 2 },
  ["H3000 Band Delays Mk II"] = { 2, 2 }, ["H3000 Factory"] = { 4, 2 }, ["H3000 Factory Mk II"] = { 4, 2 },
  ["H910 Harmonizer"] = { 2, 2 }, ["H949 Harmonizer"] = { 2, 2 }, ["Instant Flanger Mk II"] = { 4, 2 },
  ["Instant Phaser Mk II"] = { 4, 2 }, MangledVerb = { 2, 2 }, MicroPitch = { 2, 2 }, Octavox = { 2, 2 },
  Omnipressor = { 4, 2 }, ["Physion Mk II"] = { 4, 2 }, ["Precision Time Align"] = { 2, 2 },
  Quadravox = { 2, 2 }, ["Rotary Mod"] = { 2, 2 }, ["SP2016 Reverb"] = { 2, 2 }, ShimmerVerb = { 2, 2 },
  SplitEQ = { 2, 2 }, Spring = { 2, 2 }, ["Temperance Lite"] = { 2, 2 }, TriceraChorus = { 2, 2 },
  Tverb = { 2, 2 }, UltraChannel = { 4, 2 }, UltraReverb = { 4, 2 }, UltraTap = { 2, 2 }, Undulator = { 2, 2 },
}

-- The plugin writes its .tide state as the JSON text, then at least 8 NULs, at least
-- 1008 bytes in all; fewer than 8 trailing NULs is ignored silently by the plugin.
local TIDE_TRAILER, TIDE_MIN_STATE = 8, 1008

function M.tide_state(bytes)
  local body = text.rstrip_ascii(bytes)
  local doc = json.decode(body)
  if not json.is_object(doc) then error("not a JSON object", 0) end
  local id = doc.pluginID
  if id == nil then id = "\0\0\0\0" end
  if type(id) ~= "string" or id:find("[\128-\255]") then error("pluginID is not ASCII text", 0) end
  local ver = doc.pluginVer
  if ver == nil then ver = "0" end
  if type(ver) ~= "string" then error("pluginVer is not text", 0) end
  local state = body .. ("\0"):rep(TIDE_TRAILER)
  if #state < TIDE_MIN_STATE then state = state .. ("\0"):rep(TIDE_MIN_STATE - #state) end
  return juce.build_reaper_vst3({
    fx_id = id,
    fx_version = juce.version_int(ver),
    num_programs = 0,
    plugin_state = state,
    private = juce.private_bypass_tree(false),
  })
end

local BOOL_ATTRS = { undoable = true, canAB = true }

-- JUCE ValueTree::fromXml with the var types the plugin itself writes: PARAM value
-- double, undoable / canAB bool, other integers int, the rest string.
local function xml_tree(el)
  local t = { type = el.tag, props = {}, children = {} }
  for _, a in ipairs(el.attrs) do
    local k, v = a[1], a[2]
    local var
    if el.tag == "PARAM" and k == "value" then
      var = { kind = juce.DOUBLE, value = text.parse_float(v) }
    elseif BOOL_ATTRS[k] and (v == "0" or v == "1") then
      var = { kind = v == "1" and juce.TRUE or juce.FALSE }
    elseif v:match("^%-?%d+\n?$") then
      var = { kind = juce.INT, value = text.parse_int(v) }
    else
      var = { kind = juce.STRING, value = v }
    end
    t.props[#t.props + 1] = { k, var }
  end
  for _, c in ipairs(el.children) do t.children[#t.children + 1] = xml_tree(c) end
  return t
end

function M.tidex_state(bytes)
  local root = xml.parse(bytes)
  local tree = xml_tree(root)
  local plug_id = xml.get(root, "plugId")
  local ver = xml.get(root, "plugVer")
  if not plug_id then error("no plugId", 0) end
  if not ver then error("no plugVer", 0) end
  return juce.build_reaper_vst3({
    fx_id = string.pack(">I4", text.parse_int(plug_id)),
    fx_version = juce.version_int(ver),
    num_programs = 1,
    plugin_state = juce.encode_tree(tree) .. ("\0"):rep(8),
    private = "",
  })
end

local function in_snapshots(path)
  return path:find("/Snapshots/", 1, true) ~= nil or path:find("\\Snapshots\\", 1, true) ~= nil
end

function M.plugins(env)
  local root = env.dirs.music .. "/Eventide"
  local dirs = env.fs.list(root)
  local out = {}
  if not dirs then return out end
  table.sort(dirs)
  for _, f in ipairs(dirs) do
    out[#out + 1] = {
      fx_name = "VST3: " .. f .. " (Eventide)",
      bundle = f,
      roots = { root .. "/" .. f },
      exts = { ".tide", ".tidex" },
      skip = in_snapshots,
      pins = PINS[f],
    }
  end
  return out
end

function M.to_state(bytes, path)
  if path:lower():find("%.tidex$") then return M.tidex_state(bytes) end
  return M.tide_state(bytes)
end

return M
