-- Plain Lua 5.4 test runner: lua5.4 tests/run.lua [pattern]
-- Runs every tests/test_*.lua; each returns {["test name"] = function() ... end}.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../FX/?.lua;" .. here .. "/../FX/?/init.lua;" .. here .. "/?.lua;"
  .. here .. "/../tools/?.lua;" .. package.path

local filter = arg[1]
local p = io.popen("ls " .. here .. "/test_*.lua")
local files = {}
for f in p:lines() do files[#files + 1] = f end
p:close()

local passed, failed = 0, {}
for _, file in ipairs(files) do
  local suite = dofile(file)
  local names = {}
  for name in pairs(suite) do names[#names + 1] = name end
  table.sort(names)
  local short = file:match("([^/]+)%.lua$")
  for _, name in ipairs(names) do
    local full = short .. ": " .. name
    if not filter or full:find(filter, 1, true) then
      local ok, err = xpcall(suite[name], debug.traceback)
      if ok then
        passed = passed + 1
      else
        failed[#failed + 1] = full .. "\n    " .. tostring(err):gsub("\n", "\n    ")
      end
    end
  end
end

for _, f in ipairs(failed) do print("FAIL " .. f) end
print(("%d passed, %d failed (%s)"):format(passed, #failed, _VERSION))
os.exit(#failed == 0 and 0 or 1)
