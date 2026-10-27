-- Scan, dry run and conversion of vendor presets into REAPER preset files: everything
-- between the adapters and the REAPER glue. Pure Lua 5.4; file access is injected.
local failed = require("reaporter.core.failed")
local ini = require("reaporter.core.ini")
local plugin_list = require("reaporter.core.plugin_list")
local scan = require("reaporter.core.scan")
local sidecar = require("reaporter.core.sidecar")
local text = require("reaporter.core.text")

local M = {}

local function slashes(p) return p and (p:gsub("\\", "/"):gsub("/+$", "")) end

-- The folders vendors install presets under, per OS. macOS is measured; the Windows and
-- Linux folders follow JUCE's special-location conventions and are unverified.
-- getenv(name) -> value or nil.
function M.dirs(os_name, home, getenv)
  getenv = getenv or os.getenv
  home = slashes(home)
  if os_name:find("^Win") then
    local profile = slashes(getenv("USERPROFILE")) or home
    return {
      common = slashes(getenv("ProgramData")) or "C:/ProgramData",
      user = slashes(getenv("APPDATA")) or (profile .. "/AppData/Roaming"),
      music = profile .. "/Music",
      documents = profile .. "/Documents",
      shared = slashes(getenv("PUBLIC")) or "C:/Users/Public",
    }
  elseif os_name:find("OSX") or os_name:find("mac") then
    return {
      common = "/Library/Application Support",
      user = home .. "/Library/Application Support",
      music = home .. "/Music",
      documents = home .. "/Documents",
      shared = "/Users/Shared",
    }
  end
  return {
    common = "/opt",
    user = home .. "/.config",
    music = home .. "/Music",
    documents = home .. "/Documents",
    shared = "/usr/share",
  }
end

-- Every adapter's plugins, matched against REAPER's VST3 list. Returns
-- {{adapter, plugins = {plugin...}}, ...}; each plugin gains `listing` (REAPER's uid,
-- fx_id, name), `ini_name` (the adapter's when it sets one) and `problem` (why it cannot
-- convert, or nil). `pins` is the adapter's own.
-- env = {os, dirs, fs, vst3}
function M.discover(adapters, env)
  local out = {}
  for _, adapter in ipairs(adapters) do
    local ok, list = pcall(adapter.plugins, env)
    local group = { adapter = adapter, plugins = {}, error = not ok and tostring(list) or nil }
    for _, plugin in ipairs(ok and list or {}) do
      plugin.vendor = adapter.vendor
      plugin.ini_name = plugin.ini_name or ini.preset_file_name(plugin.fx_name)
      plugin.listing = plugin_list.lookup(env.vst3 or {}, plugin.bundle)
      if not plugin.listing then
        plugin.problem = "not installed in REAPER (VST3)"
      elseif plugin.listing.fx_name ~= plugin.fx_name then
        plugin.problem = "REAPER lists it as " .. plugin.listing.fx_name
      end
      group.plugins[#group.plugins + 1] = plugin
    end
    out[#out + 1] = group
  end
  return out
end

-- A file that holds several presets (a database or a pack) becomes one entry per member:
-- plugin.members(path, read) -> nil for a file that is one preset, else {{key, name,
-- folder, tags, bytes}...}. A member's path is "<file>#<key>"; it carries its bytes,
-- folder and tags on the entry, and a key seen in an earlier file is left out. A file
-- whose members cannot be read stays one entry, so the conversion reports why.
local function expand(plugin, paths, read)
  local out, seen = {}, {}
  for _, p in ipairs(paths) do
    local ok, list = pcall(plugin.members, p, read)
    if not ok or list == nil then
      out[#out + 1] = p
    else
      for _, m in ipairs(list) do
        if not seen[m.key] then
          seen[m.key] = true
          out[#out + 1] = {
            path = p .. "#" .. m.key, stem = m.name, parent = m.folder[#m.folder] or text.splitext(text.basename(p)),
            bytes = m.bytes, folder = m.folder, tags = m.tags,
          }
        end
      end
    end
  end
  return out
end

-- The plugin's presets as named entries: (named {{name, path}...}, unreadable folders).
function M.presets(plugin, fs)
  local paths, unreadable = scan.files(plugin, fs)
  if plugin.members then return scan.named(expand(plugin, paths, fs.read)), unreadable end
  return scan.named(paths), unreadable
end

-- Dry-run counts against the plugin's preset file now on disk (nil when there is none):
-- {found, new, exist} or {found, error} when the file cannot be merged. known(path) ->
-- reason for a file known not to convert (core/failed.lua; it is also given the entry): such files are counted in
-- `failed`, with reasons[reason] = count, not in `new` (both fields only when there are any).
function M.dry_run(named, existing, known)
  local counts = { found = #named, new = 0, exist = 0 }
  local taken = {}
  if existing and existing ~= "" then
    local ok, f = pcall(ini.inspect, existing)
    if not ok then
      counts.error = "REAPER's preset file cannot be merged: " .. tostring(f)
      return counts
    end
    taken = f.taken
  end
  for _, e in ipairs(named) do
    local k = ini.name_key(e[1])
    local why = not taken[k] and known and known(e[2], e)
    if taken[k] then
      counts.exist = counts.exist + 1
    elseif why then
      counts.failed = (counts.failed or 0) + 1
      counts.reasons = counts.reasons or {}
      counts.reasons[why] = (counts.reasons[why] or 0) + 1
    else
      taken[k] = true
      counts.new = counts.new + 1
    end
  end
  return counts
end

-- A conversion that can run a few presets at a time: new_job, then step until done.
function M.new_job(adapter, plugin, named)
  return { adapter = adapter, plugin = plugin, named = named, next = 1, ok = {}, failed = {} }
end

-- Convert presets until `more()` returns false or none are left; returns true when done.
-- read(path) -> bytes or nil, reason; a pack member carries its bytes. A preset that fails is recorded with its reason
-- (and the file's {size, adler32} when the file itself is why it failed, not REAPER or
-- plugin-list state: failed.environment) and the rest carry on. A pack member's failure
-- also carries its preset name (`member`).
function M.step(job, read, more)
  while job.next <= #job.named do
    local e = job.named[job.next]
    local name, path = e[1], e[2]
    job.next = job.next + 1
    local bytes, why = e.bytes, nil
    if not bytes then bytes, why = read(path) end
    if not bytes then
      job.failed[#job.failed + 1] = { path, "unreadable: " .. tostring(why), member = e.bytes ~= nil and name or nil }
    else
      local ok, chunk = pcall(job.adapter.to_state, bytes, path, job.plugin)
      if ok and type(chunk) == "string" then
        job.ok[#job.ok + 1] = { name, path, chunk }
      else
        local content = not ok and not failed.is_environment(chunk)
        job.failed[#job.failed + 1] = { path, ok and "adapter returned no state" or tostring(chunk),
          content and { failed.fingerprint(bytes) } or nil, member = e.bytes ~= nil and name or nil }
      end
    end
    if more and not more() then break end
  end
  return job.next > #job.named
end

-- Build the converted presets' entry bytes and their hex lines into job.entries until
-- `more()` returns false or all are built; returns true when done. The hex encoding is
-- most of a big library's merge time, so it runs a few entries per frame like `step`.
function M.encode(job, uid, nin, nout, more)
  job.entries = job.entries or {}
  while #job.entries < #job.ok do
    local e = job.ok[#job.entries + 1]
    local data = ini.entry_data(uid, e[3], e[1], nin, nout)
    job.entries[#job.entries + 1] = { e[1], data, ini.data_lines(data) }
    if more and not more() then break end
  end
  return #job.entries == #job.ok
end

-- The converted entries merged into the plugin's preset file: (bytes, added, skipped).
-- Encodes what `encode` has not yet. Raises for a file the merge must not touch.
function M.merged(job, existing, uid, nin, nout)
  if not job.entries or #job.entries < #job.ok then M.encode(job, uid, nin, nout) end
  return ini.merge(existing, job.entries)
end

-- The sidecar bytes for the names a preset file lists: (bytes, stats). existing is the
-- sidecar file's bytes or nil; read(path) feeds an adapter's optional tags(bytes).
function M.sidecar(adapter, plugin, named, ini_bytes, existing, read)
  local vendor_tags
  if adapter.tags then
    vendor_tags = function(path)
      local bytes = read(path)
      local ok, tags = pcall(adapter.tags, bytes or "")
      return ok and tags or {}
    end
  end
  local out, stats = sidecar.build(ini.listed_names(ini_bytes or ""), named, plugin.roots,
    sidecar.decode(existing), "factory:" .. adapter.key, vendor_tags)
  return sidecar.encode(out), stats
end

return M
