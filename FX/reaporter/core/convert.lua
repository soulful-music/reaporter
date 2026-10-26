-- Scan, dry run and conversion of vendor presets into REAPER preset files: everything
-- between the adapters and the REAPER glue. Pure Lua 5.4; file access is injected.
local ini = require("reaporter.core.ini")
local pins = require("reaporter.core.pins")
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
      shared = slashes(getenv("PUBLIC")) or "C:/Users/Public",
    }
  elseif os_name:find("OSX") or os_name:find("mac") then
    return {
      common = "/Library/Application Support",
      user = home .. "/Library/Application Support",
      music = home .. "/Music",
      shared = "/Users/Shared",
    }
  end
  return {
    common = "/opt",
    user = home .. "/.config",
    music = home .. "/Music",
    shared = "/usr/share",
  }
end

-- Every adapter's plugins, matched against REAPER's VST3 list. Returns
-- {{adapter, plugins = {plugin...}}, ...}; each plugin gains `listing` (REAPER's uid,
-- fx_id, name), `ini_name` and `problem` (why it cannot convert, or nil).
-- env = {os, dirs, fs, vst3}
function M.discover(adapters, env)
  local out = {}
  for _, adapter in ipairs(adapters) do
    local ok, list = pcall(adapter.plugins, env)
    local group = { adapter = adapter, plugins = {}, error = not ok and tostring(list) or nil }
    for _, plugin in ipairs(ok and list or {}) do
      plugin.vendor = adapter.vendor
      plugin.ini_name = ini.preset_file_name(plugin.fx_name)
      plugin.listing = plugin_list.lookup(env.vst3 or {}, plugin.bundle)
      if not plugin.listing then
        plugin.problem = "not installed in REAPER (VST3)"
      elseif plugin.listing.fx_name ~= plugin.fx_name then
        plugin.problem = "REAPER lists it as " .. plugin.listing.fx_name
      end
      plugin.pins = pins[plugin.fx_name]
      group.plugins[#group.plugins + 1] = plugin
    end
    out[#out + 1] = group
  end
  return out
end

-- The plugin's presets as named entries: (named {{name, path}...}, unreadable folders).
function M.presets(plugin, fs)
  local paths, unreadable = scan.files(plugin, fs)
  return scan.named(paths), unreadable
end

-- Dry-run counts against the plugin's preset file now on disk (nil when there is none):
-- {found, new, exist} or {found, error} when the file cannot be merged.
function M.dry_run(named, existing)
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
    local k = text.lower(e[1])
    if taken[k] then
      counts.exist = counts.exist + 1
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
-- read(path) -> bytes or nil, reason. A preset that fails is recorded with its reason and
-- the rest carry on.
function M.step(job, read, more)
  while job.next <= #job.named do
    local name, path = job.named[job.next][1], job.named[job.next][2]
    job.next = job.next + 1
    local bytes, why = read(path)
    if not bytes then
      job.failed[#job.failed + 1] = { path, "unreadable: " .. tostring(why) }
    else
      local ok, chunk = pcall(job.adapter.to_state, bytes, path, job.plugin)
      if ok and type(chunk) == "string" then
        job.ok[#job.ok + 1] = { name, path, chunk }
      else
        job.failed[#job.failed + 1] = { path, ok and "adapter returned no state" or tostring(chunk) }
      end
    end
    if more and not more() then break end
  end
  return job.next > #job.named
end

-- The converted entries merged into the plugin's preset file: (bytes, added, skipped).
-- Raises for a file the merge must not touch.
function M.merged(job, existing, uid, nin, nout)
  local entries = {}
  for _, e in ipairs(job.ok) do
    entries[#entries + 1] = { e[1], ini.entry_data(uid, e[3], e[1], nin, nout) }
  end
  return ini.merge(existing, entries)
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
