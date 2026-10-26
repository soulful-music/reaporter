-- Soundtoys 5: a .toy is CR-separated text whose archive the plugin loads as is; the
-- state is that text, wrapped VST2-style (FORMATS.md, "Soundtoys").
local juce = require("reaporter.codec.juce")
local failed = require("reaporter.core.failed")
local text = require("reaporter.core.text")

local M = { vendor = "Soundtoys", key = "soundtoys" }

-- Pin counts (in, out) per plugin name as REAPER reports them on a stereo track (REAPER
-- 7.82, macOS); a plugin missing here is measured once in REAPER before its first conversion.
local PINS = {
  EchoBoy = { 2, 2 }, ["EchoBoy Jr"] = { 2, 2 }, Decapitator = { 2, 2 }, ["Little Plate"] = { 2, 2 },
  SuperPlate = { 2, 2 }, Crystallizer = { 2, 2 }, MicroShift = { 2, 2 }, PrimalTap = { 2, 2 },
  Radiator = { 2, 2 },
}

local function key(name)
  return (name:lower():gsub("[^%w]", ""))
end

function M.state_text(bytes)
  if not text.starts_with(bytes, "WIDGET = ")
    or not (bytes:find("PRESET =", 1, true) or bytes:find("ARCHIVE =", 1, true)) then
    error("not a Soundtoys preset with an archive", 0)
  end
  return bytes
end

-- Every preset folder that names an installed Soundtoys VST3, matched ignoring case and
-- punctuation (Devil-Loc -> Devil_Loc); fx_id is the class id's 4cc.
function M.plugins(env)
  local root = env.dirs.shared .. "/Soundtoys/Soundtoys 5"
  local installed = {}
  local bundles = {}
  for b, rec in pairs(env.vst3 or {}) do
    if text.ends_with(rec.fx_name, "(Soundtoys)") then bundles[#bundles + 1] = b end
  end
  table.sort(bundles, function(a, b) return env.vst3[a].line < env.vst3[b].line end)
  for _, b in ipairs(bundles) do installed[key(b)] = b end
  local folders = env.fs.list(root)
  local out = {}
  if not folders then return out end
  table.sort(folders)
  for _, f in ipairs(folders) do
    local b = installed[key(f)]
    if b then
      local rec = env.vst3[b]
      out[#out + 1] = {
        fx_name = rec.fx_name,
        bundle = b,
        roots = { root .. "/" .. f },
        exts = { ".toy" },
        fx_id = rec.fx_id,
        pins = PINS[rec.fx_name:match("^VST3i?: (.*) %(Soundtoys%)$")],
      }
    end
  end
  return out
end

function M.to_state(bytes, _, plugin)
  if not plugin.fx_id then failed.environment("REAPER lists no VST2 id for this plugin") end
  return juce.build_vst2_wrapped(plugin.fx_id, 1, 1, M.state_text(bytes))
end

return M
