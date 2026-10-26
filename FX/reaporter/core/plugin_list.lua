-- REAPER's VST plugin list (reaper-vstplugins*.ini in the resource folder). Pure Lua 5.4.
local text = require("reaporter.core.text")

local M = {}

-- The plugin-list file for REAPER's GetOS() string, most likely first.
function M.file_names(os_name)
  os_name = os_name or ""
  if os_name:find("arm64") and os_name:find("mac") then
    return { "reaper-vstplugins_arm64.ini", "reaper-vstplugins64.ini" }
  elseif os_name:find("OSX") or os_name:find("mac") then
    return { "reaper-vstplugins64.ini", "reaper-vstplugins_arm64.ini" }
  elseif os_name:find("Win64") then
    return { "reaper-vstplugins64.ini" }
  elseif os_name:find("Win32") then
    return { "reaper-vstplugins.ini" }
  elseif os_name:find("aarch64") then
    return { "reaper-vstplugins_aarch64.ini", "reaper-vstplugins_arm64.ini" }
  end
  return { "reaper-vstplugins_x86_64.ini", "reaper-vstplugins64.ini" }
end

-- {[bundle] = {uid, fx_id (4 bytes or nil), fx_name, line}} for every VST3 line:
-- "<bundle>.vst3=<hex>,<uid>{<32 hex class id>,<name>". The bundle keeps REAPER's
-- spelling (spaces as underscores). fx_id is bytes 3..6 of a class id that starts
-- "VST" (JUCE and Soundtoys put their VST2 id there). A later line for a bundle wins;
-- `line` is its line number, for callers that need the file's order.
function M.parse(data)
  local out, n = {}, 0
  for line in (data .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    local bundle, uid, cid, name = line:match("^(.+)%.vst3=[0-9A-F]+,(%-?%d+){([0-9A-F]+),(.*)$")
    if bundle and #cid == 32 then
      local raw = cid:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
      name = text.strip(name)
      local instrument = name:find("!!!VSTi$") ~= nil
      if instrument then name = name:sub(1, -8) end
      out[bundle] = {
        uid = math.tointeger(tonumber(uid)) & 0xFFFFFFFF,
        fx_id = raw:sub(1, 3) == "VST" and raw:sub(4, 7) or nil,
        fx_name = (instrument and "VST3i: " or "VST3: ") .. name,
        line = n,
      }
    end
  end
  return out
end

-- The listing for a bundle name as a vendor spells it ("Tai Chi" -> "Tai_Chi").
function M.lookup(list, bundle)
  return list[(bundle:gsub(" ", "_"))]
end

return M
