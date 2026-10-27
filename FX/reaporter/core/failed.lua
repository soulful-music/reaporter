-- The presets known not to convert, remembered between runs so the dry run counts them
-- apart from the new ones. A failure is known by the plugin (its fx_name), the file's path,
-- size and Adler-32: a changed file is tried again, and so is every file after a ReaPorter
-- update. Only failures that come from the file's contents are remembered; one that
-- depends on REAPER or the plugin list is raised with `failed.environment` and tried
-- again on the next Convert. Pure Lua 5.4.
local json = require("reaporter.codec.json")
local version = require("reaporter.version")
local zlib = require("reaporter.codec.zlib")

local M = {}

-- The file under <resource>/presets.
M.FILE = "ReaPorter-failed.json"

-- (size, adler32) of a preset file's bytes.
function M.fingerprint(bytes) return #bytes, zlib.adler32(bytes) end

-- Raise an adapter error that depends on REAPER or plugin-list state, not on the preset
-- file: it is shown, but not remembered.
function M.environment(msg)
  error(setmetatable({ environment = true, message = msg }, { __tostring = function(e) return e.message end }), 0)
end

function M.is_environment(err) return type(err) == "table" and err.environment == true end

-- `s` with every byte that is not valid UTF-8 written as \xNN, so JSON can carry it.
local function printable(s)
  local out, i = {}, 1
  while true do
    local bad = select(2, utf8.len(s, i))
    if not bad then
      out[#out + 1] = s:sub(i)
      return table.concat(out)
    end
    out[#out + 1] = s:sub(i, bad - 1)
    out[#out + 1] = ("\\x%02x"):format(s:byte(bad))
    i = bad + 1
  end
end
M.printable = printable

-- The store from its file's bytes; an empty one when there is none, it does not parse,
-- or another ReaPorter version wrote it. store.files[fx_name][path] = {size, adler32, reason}.
function M.decode(bytes)
  local store = { files = {} }
  if not bytes or bytes == "" then return store end
  local ok, doc = pcall(json.decode, bytes)
  if not ok or not json.is_object(doc) or doc.reaporter ~= version or not json.is_object(doc.failed) then
    return store
  end
  for fx_name, paths in pairs(doc.failed) do
    if json.is_object(paths) then
      for path, e in pairs(paths) do
        if json.is_object(e) and math.type(e.size) == "integer" and math.type(e.adler32) == "integer"
          and type(e.reason) == "string" then
          store.files[fx_name] = store.files[fx_name] or {}
          store.files[fx_name][path] = { size = e.size, adler32 = e.adler32, reason = e.reason }
        end
      end
    end
  end
  return store
end

function M.encode(store)
  local failed = json.object()
  for fx_name, paths in pairs(store.files) do
    local group = json.object()
    for path, e in pairs(paths) do
      group[printable(path)] = json.object({ size = e.size, adler32 = e.adler32, reason = printable(e.reason) })
    end
    if next(group) then failed[printable(fx_name)] = group end
  end
  return json.encode(json.object({ reaporter = version, failed = failed })) .. "\n"
end

-- known(path, entry) -> the reason the file failed for plugin `fx_name`, or nil when it is
-- not known to fail as it is now. Reads only the files the store names; a pack member's
-- bytes come from its entry. read(path) -> bytes or nil.
function M.checker(store, read, fx_name)
  return function(path, entry)
    local e = store.files[fx_name] and store.files[fx_name][path]
    if not e then return nil end
    local bytes = entry and entry.bytes or read(path)
    if not bytes then return nil end
    local size, sum = M.fingerprint(bytes)
    if size == e.size and sum == e.adler32 then return e.reason end
    return nil
  end
end

-- Take in a finished job: its failures with a fingerprint are remembered under the job's
-- plugin, its converted files forgotten. Returns true when the store changed.
function M.record(store, job)
  local changed = false
  local fx = job.plugin.fx_name
  local mine = store.files[fx]
  for _, e in ipairs(job.ok) do
    if mine and mine[e[2]] then
      mine[e[2]] = nil
      changed = true
    end
  end
  for _, f in ipairs(job.failed) do
    if f[3] then
      mine = store.files[fx] or {}
      store.files[fx] = mine
      local old = mine[f[1]]
      if not old or old.size ~= f[3][1] or old.adler32 ~= f[3][2] or old.reason ~= f[2] then
        mine[f[1]] = { size = f[3][1], adler32 = f[3][2], reason = f[2] }
        changed = true
      end
    end
  end
  return changed
end

-- The reasons of a dry run's known failures, most frequent first: "387 x reason; ...".
function M.summary(reasons)
  local list = {}
  for r, n in pairs(reasons or {}) do list[#list + 1] = { r, n } end
  table.sort(list, function(a, b)
    if a[2] ~= b[2] then return a[2] > b[2] end
    return a[1] < b[1]
  end)
  local out = {}
  for i, e in ipairs(list) do
    if i > 5 then
      out[#out + 1] = ("%d more reasons"):format(#list - 5)
      break
    end
    out[#out + 1] = ("%d x %s"):format(e[2], e[1])
  end
  return table.concat(out, "\n")
end

return M
