-- The write sequence for one plugin's preset file and sidecar, shared by the REAPER window
-- and the CLI so both follow the same safety rules. Pure Lua 5.4: fs is injected, with
-- exists(path), read(path), write_atomic(path, bytes), write_new(path, bytes) and
-- mkdir(dir); the writers raise on failure (fileio.lua).
local convert = require("reaporter.core.convert")
local ini = require("reaporter.core.ini")

local M = {}

-- A file that may be missing: its bytes, or nil when there is none. Raises when the file
-- exists but cannot be read, so it is never taken for missing and replaced.
function M.read_existing(fs, path)
  local bytes, err = fs.read(path)
  if bytes then return bytes end
  if fs.exists(path) then
    error(("%s exists but cannot be read (%s); it is left as it is"):format(path, tostring(err)), 0)
  end
  return nil
end

-- The dry run against the preset file at `path`: convert.dry_run's counts, or {found,
-- error} when the file cannot be read or merged. known: as convert.dry_run.
function M.dry_run(fs, path, named, known)
  local ok, existing = pcall(M.read_existing, fs, path)
  if not ok then return { found = #named, error = tostring(existing) } end
  return convert.dry_run(named, existing, known)
end

-- The named presets the file at `path` does not hold yet (the merge would skip the
-- others) and that are not known to fail (known(path) -> reason or nil), and how many
-- were left out as known failures. Raises as read_existing; a file the merge refuses
-- keeps every name, and the merge reports why.
function M.fresh(fs, path, named, known)
  local existing = M.read_existing(fs, path)
  local taken = {}
  if existing and existing ~= "" then
    local ok, f = pcall(ini.inspect, existing)
    if ok then taken = f.taken end
  end
  local out, nknown = {}, 0
  for _, e in ipairs(named) do
    local k = ini.name_key(e[1])
    if not taken[k] then
      if known and known(e[2], e) then
        nknown = nknown + 1
      else
        out[#out + 1] = e
      end
    end
  end
  return out, nknown
end

-- A backup path no file has: <dir>/<stem>.<stamp>.ini, else <stem>.<stamp>-2.ini, ...
function M.backup_path(fs, dir, ini_name, stamp)
  local stem = ini_name:gsub("%.ini$", "")
  local path = ("%s/%s.%s.ini"):format(dir, stem, stamp)
  local n = 2
  while fs.exists(path) do
    path = ("%s/%s.%s-%d.ini"):format(dir, stem, stamp, n)
    n = n + 1
  end
  return path
end

-- Merge a finished job into the preset file and write it. o = {fs, job, found (presets
-- found for the plugin), known (of those, left out as known failures; default 0), ini_in
-- (the file merged into), ini_out (the file written; the same in REAPER), backup_dir,
-- stamp}. The job's entries are built (convert.encode) when
-- it has any. Returns (record, merged bytes or nil): record = {written, skipped, failed,
-- backup, error}. Order: read (refusing an unreadable file), merge, then only when the
-- merge adds entries: the backup, read back, before the atomic write.
function M.write_ini(o)
  local fs, job = o.fs, o.job
  local known = o.known or 0
  local r = { written = 0, skipped = o.found - #job.named - known, failed = job.failed, known = known }
  local merged
  local ok, err = pcall(function()
    local existing = M.read_existing(fs, o.ini_in)
    local bytes, added, skipped = ini.merge(existing, job.entries or {})
    r.skipped = r.skipped + #skipped
    if #added > 0 then
      fs.mkdir(o.ini_out:match("^(.*)/[^/]*$"))
      if existing then
        fs.mkdir(o.backup_dir)
        local path = M.backup_path(fs, o.backup_dir, o.ini_out:match("([^/]+)$"), o.stamp)
        fs.write_new(path, existing)
        r.backup = path
      end
      local wok, werr = pcall(fs.write_atomic, o.ini_out, bytes)
      if not wok then
        error(tostring(werr) .. (r.backup and ("; the old file is backed up at " .. r.backup) or ""), 0)
      end
      r.written = #added
    end
    merged = bytes
  end)
  if not ok then r.error = tostring(err) end
  return r, merged
end

-- The sidecar for a preset file just merged: written only when it changes, and only when
-- one exists already or this run imports a preset. o = {fs, adapter, plugin, named,
-- side_in, side_out}. Sets record.sidecar (stats), sidecar_written or sidecar_error.
function M.write_sidecar(o, r, merged)
  if r.error or not merged then
    r.sidecar_error = "not written: the preset file was not written"
    return r
  end
  local fs = o.fs
  local ok, err = pcall(function()
    local old = M.read_existing(fs, o.side_in)
    local bytes, stats = convert.sidecar(o.adapter, o.plugin, o.named, merged, old, fs.read)
    r.sidecar = stats
    if bytes ~= old and (old or stats.imported > 0) then
      fs.mkdir(o.side_out:match("^(.*)/[^/]*$"))
      fs.write_atomic(o.side_out, bytes)
      r.sidecar_written = true
    end
  end)
  if not ok then r.sidecar_error = tostring(err) end
  return r
end

-- write_ini, then write_sidecar when o.side_in is set.
function M.write(o)
  local r, merged = M.write_ini(o)
  if o.side_in then M.write_sidecar(o, r, merged) end
  return r
end

return M
