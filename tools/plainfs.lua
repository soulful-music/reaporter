-- File access for running ReaPorter's pure modules outside REAPER (tests, the CLI):
-- POSIX shell `find` for listing, io for reading and writing.
local M = {}

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function entries(dir, type_test)
  local p = io.popen(("find %s -mindepth 1 -maxdepth 1 %s -print0 2>/dev/null"):format(quote(dir), type_test))
  local all = p:read("a")
  p:close()
  local out = {}
  for e in all:gmatch("([^%z]+)%z") do out[#out + 1] = e:match("([^/]+)$") end
  return out
end

function M.is_dir(path)
  local p = io.popen(("test -d %s && echo y"):format(quote(path)))
  local r = p:read("a")
  p:close()
  return r:find("y") ~= nil
end

-- (subdir names, file names), or nil when the folder cannot be listed.
function M.list(dir)
  if not M.is_dir(dir) then return nil, "not a folder" end
  local p = io.popen(("test -r %s -a -x %s && echo y"):format(quote(dir), quote(dir)))
  local ok = p:read("a"):find("y")
  p:close()
  if not ok then return nil, "unreadable" end
  return entries(dir, "-type d"), entries(dir, "! -type d")
end

function M.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local b = f:read("a")
  f:close()
  return b
end

function M.write(path, bytes)
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
end

return M
