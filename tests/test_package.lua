local A = require("assert")

local T = {}

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/../FX"

T["the ReaPack header provides every module"] = function()
  local header = assert(io.open(root .. "/ReaPorter.lua")):read("a")
  local provided = {}
  for f in header:gmatch("%-%-%s+%[nomain%]%s+(%S+)") do provided[f] = true end
  local p = io.popen("cd '" .. root .. "' && find reaporter -name '*.lua'")
  local n = 0
  for f in p:lines() do
    n = n + 1
    A.truthy(provided[f], f .. " is not in @provides")
  end
  p:close()
  A.truthy(n > 10)
  for _, tag in ipairs({ "@description", "@version", "@author", "@about", "@changelog", "@provides" }) do
    A.truthy(header:find(tag, 1, true), tag)
  end
end

T["the pure modules make no reaper.* calls"] = function()
  local p = io.popen("cd '" .. root .. "' && grep -rlE 'reaper[.][A-Za-z_]' reaporter/codec reaporter/core reaporter/adapters; true")
  local hits = p:read("a")
  p:close()
  A.eq(hits, "")
end

T["version.lua matches @version"] = function()
  local header = assert(io.open(root .. "/ReaPorter.lua")):read("a")
  A.eq(require("reaporter.version"), header:match("@version%s+(%S+)"))
end

return T
