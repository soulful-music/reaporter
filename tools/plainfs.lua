-- File access for running ReaPorter's pure modules outside REAPER (tests, the CLI):
-- POSIX shell `find` and `test` for listing and existence, fileio.lua for reading and
-- writing, so the CLI writes through the same atomic replace and backup as REAPER.
local fileio = require("reaporter.fileio")

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function test(flag, path)
  local p = io.popen(("test %s %s && echo y"):format(flag, quote(path)))
  local r = p:read("a")
  p:close()
  return r:find("y") ~= nil
end

local M = fileio.new({ exists = function(path) return test("-e", path) end })

local function entries(dir, type_test)
  local p = io.popen(("find %s -mindepth 1 -maxdepth 1 %s -print0 2>/dev/null"):format(quote(dir), type_test))
  local all = p:read("a")
  p:close()
  local out = {}
  for e in all:gmatch("([^%z]+)%z") do out[#out + 1] = e:match("([^/]+)$") end
  return out
end

function M.is_dir(path) return test("-d", path) end

-- (subdir names, file names), or nil when the folder cannot be listed.
function M.list(dir)
  if not M.is_dir(dir) then return nil, "not a folder" end
  local p = io.popen(("test -r %s -a -x %s && echo y"):format(quote(dir), quote(dir)))
  local ok = p:read("a"):find("y")
  p:close()
  if not ok then return nil, "unreadable" end
  return entries(dir, "-type d"), entries(dir, "! -type d")
end

function M.mkdir(dir)
  if not os.execute("mkdir -p " .. quote(dir)) then error("cannot create " .. dir, 0) end
end

-- A plain write, for the CLI's own report files in --out.
function M.write(path, bytes)
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
end

return M
