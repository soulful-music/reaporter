-- Valhalla DSP: a .vpreset is the plugin's own state XML; the state is JUCE
-- copyXmlToBinary of it (FORMATS.md, "Valhalla DSP").
local juce = require("reaporter.codec.juce")
local xml = require("reaporter.codec.xml")

local M = { vendor = "Valhalla DSP", key = "valhalla" }

local STATE_MAGIC = "VC2!"

-- fx_id: the 4cc in the VST3 class id (VST<4cc>valhalla...); JUCE ignores it on load.
local FX_IDS = {
  ValhallaVintageVerb = "vee3", ValhallaRoom = "Ruum", ValhallaPlate = "plat",
  ValhallaDelay = "dLay", ValhallaSupermassive = "sMas", ValhallaFutureVerb = "Hero",
  ValhallaSpaceModulator = "SpMd", ValhallaFreqEcho = "FqEh",
}

-- An attribute value quoted as XML writers do: & < > escaped, tab / CR / LF as
-- character references, single quotes when the value holds a double quote only.
function M.quote_attr(v)
  v = v:gsub("&", "&amp;"):gsub(">", "&gt;"):gsub("<", "&lt;")
    :gsub("\n", "&#10;"):gsub("\r", "&#13;"):gsub("\t", "&#9;")
  if v:find('"', 1, true) then
    if v:find("'", 1, true) then return '"' .. v:gsub('"', "&quot;") .. '"' end
    return "'" .. v .. "'"
  end
  return '"' .. v .. '"'
end

-- The preset's XML as the plugin writes its state: declaration, one line.
function M.state_xml(bytes)
  local root = xml.parse(bytes)
  local attrs = {}
  for _, a in ipairs(root.attrs) do attrs[#attrs + 1] = a[1] .. "=" .. M.quote_attr(a[2]) end
  return ('<?xml version="1.0" encoding="UTF-8"?> <%s %s/>'):format(root.tag, table.concat(attrs, " "))
end

function M.plugins(env)
  local root = env.dirs.common .. "/Valhalla DSP, LLC"
  local names = env.fs.list(root)
  local out = {}
  if not names then return out end
  table.sort(names)
  for _, n in ipairs(names) do
    local presets = root .. "/" .. n .. "/Presets"
    if env.fs.is_dir(presets) then
      out[#out + 1] = {
        fx_name = "VST3: " .. n .. " (Valhalla DSP, LLC)",
        bundle = n,
        roots = { presets },
        exts = { ".vpreset" },
        fx_id = FX_IDS[n] or "\0\0\0\0",
      }
    end
  end
  return out
end

function M.to_state(bytes, _, plugin)
  local x = M.state_xml(bytes)
  return juce.build_reaper_vst3({
    fx_id = plugin.fx_id,
    fx_version = 0,
    num_programs = 0,
    plugin_state = STATE_MAGIC .. string.pack("<I4", #x) .. x .. ("\0"):rep(9),
    private = juce.private_bypass_tree(false),
  })
end

return M
