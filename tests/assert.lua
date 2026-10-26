-- Assertions for the tests.
local M = {}

local function show(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return tostring(v)
end

local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b or (a ~= a and b ~= b) end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function dump(v, depth)
  depth = depth or 0
  if type(v) ~= "table" then return show(v) end
  if depth > 4 then return "{...}" end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k], depth + 1) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.eq(got, want, msg)
  if not deep_eq(got, want) then
    error(("%sexpected %s, got %s"):format(msg and msg .. ": " or "", dump(want), dump(got)), 2)
  end
end

function M.truthy(v, msg)
  if not v then error(msg or "expected a true value", 2) end
end

-- f() must raise an error whose message contains `part`.
function M.raises(f, part)
  local ok, err = pcall(f)
  if ok then error("expected an error" .. (part and (" containing " .. show(part)) or ""), 2) end
  if part and not tostring(err):find(part, 1, true) then
    error(("error %s does not contain %s"):format(show(tostring(err)), show(part)), 2)
  end
end

return M
