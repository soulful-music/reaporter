-- LiquidSonics: the preset file's bytes are the JUCE plugin state (FORMATS.md, "LiquidSonics").
-- Illusion and Seventh Heaven encrypt their presets and are not covered.
local juce = require("reaporter.codec.juce")
local text = require("reaporter.core.text")

local M = { vendor = "LiquidSonics", key = "liquidsonics" }

-- A JUCE partial-state preset (LiquidSonics and Reverb Foundry share the format).
function M.partial_state(bytes, plugin)
  local tree = juce.read_tree(bytes)
  if not (text.ends_with(tree.type, "PartialStateVT") or text.ends_with(tree.type, "PartialState")) then
    error("root " .. tree.type, 0)
  end
  return juce.build_reaper_vst3({
    fx_id = plugin.fx_id,
    fx_version = plugin.fx_version,
    num_programs = 0,
    plugin_state = bytes,
    private = juce.private_bypass_tree(false),
  })
end

local PLUGINS = {
  -- name, preset extension, fx_id, fx_version (header fields JUCE ignores on load)
  { "Cinematic Rooms Professional", ".crp_preset", "CRP1", 0x010303 },
  { "Lustrous Plates Surround", ".lp_preset", "LPS1", 0x010200 },
}

function M.plugins(env)
  local out = {}
  for _, p in ipairs(PLUGINS) do
    out[#out + 1] = {
      fx_name = "VST3: " .. p[1] .. " (LiquidSonics)",
      bundle = p[1],
      roots = {
        env.dirs.common .. "/LiquidSonics/" .. p[1] .. "/Factory Presets",
        env.dirs.user .. "/LiquidSonics/" .. p[1] .. "/User Presets",
      },
      exts = { p[2] },
      fx_id = p[3],
      fx_version = p[4],
    }
  end
  return out
end

function M.to_state(bytes, _, plugin)
  return M.partial_state(bytes, plugin)
end

return M
