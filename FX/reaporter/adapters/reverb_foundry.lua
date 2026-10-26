-- Reverb Foundry: built on the LiquidSonics engine, same partial-state preset files
-- (FORMATS.md, "Reverb Foundry"). HD Cart encrypts its presets and is not covered.
local liquidsonics = require("reaporter.adapters.liquidsonics")

local M = { vendor = "Reverb Foundry", key = "reverbfoundry" }

function M.plugins(env)
  return {
    {
      fx_name = "VST3: Tai Chi (Reverb Foundry)",
      bundle = "Tai Chi",
      roots = {
        env.dirs.common .. "/Reverb Foundry/Tai Chi/Factory Presets",
        env.dirs.user .. "/Reverb Foundry/Tai Chi/User Presets",
      },
      exts = { ".taichi_preset" },
      fx_id = "TCR1",
      fx_version = 0x010000,
    },
  }
end

function M.to_state(bytes, _, plugin)
  return liquidsonics.partial_state(bytes, plugin)
end

return M
