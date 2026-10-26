-- Every shipped file, compiled with luac: no global read or write outside the allowlist.
-- A local function used above its declaration compiles to a global read, so this is
-- the check that catches it before REAPER does.
local A = require("assert")

local T = {}

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local root = here .. "/../FX"

local ALLOWED = {}
for name in ([[
  reaper
  assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs pcall
  print rawequal rawget rawlen rawset require select setmetatable tonumber tostring type
  xpcall _G _VERSION
  coroutine debug io math os package string table utf8
]]):gmatch("%S+") do ALLOWED[name] = true end

local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- luac beside the interpreter running the tests, else on PATH.
local function find_luac()
  local interp = arg[-1] or ""
  local dir = interp:match("^(.*)/[^/]*$")
  local candidates = {}
  if dir then
    candidates[#candidates + 1] = dir .. "/luac"
    candidates[#candidates + 1] = dir .. "/luac5.4"
  end
  candidates[#candidates + 1] = "luac5.4"
  candidates[#candidates + 1] = "luac"
  for _, c in ipairs(candidates) do
    local p = io.popen(sh_quote(c) .. " -v 2>&1")
    local out = p:read("a")
    p:close()
    if out:find("Lua 5%.4") then return c end
  end
  return nil
end

-- {"file:line name (GET|SET)", ...} for every global access outside the allowlist.
local function offences(luac, file)
  local p = io.popen(sh_quote(luac) .. " -p -l -l " .. sh_quote(file) .. " 2>&1")
  local out = p:read("a")
  local ok = p:close()
  if not ok then error("luac failed on " .. file .. ": " .. out, 0) end
  local found = {}
  for line in out:gmatch("[^\n]+") do
    local at, op, name = line:match("%[(%d+)%]%s+([GS]ETTABUP)%s.-;%s+_ENV%s+\"([^\"]*)\"")
    if op and not ALLOWED[name] then
      found[#found + 1] = ("%s:%s %s (%s)"):format(file:match("FX/(.*)$") or file, at, name, op:sub(1, 3))
    end
  end
  return found
end

T["no shipped file reads or writes a global outside the allowlist"] = function()
  local luac = find_luac()
  A.truthy(luac, "no Lua 5.4 luac found beside the interpreter or on PATH")
  local p = io.popen("find " .. sh_quote(root) .. " -name '*.lua'")
  local files, bad = 0, {}
  for f in p:lines() do
    files = files + 1
    for _, o in ipairs(offences(luac, f)) do bad[#bad + 1] = o end
  end
  p:close()
  A.truthy(files > 10, "found the shipped files")
  A.eq(bad, {})
end

return T
