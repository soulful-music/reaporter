-- The shared write sequence (core/plan.lua) on a fake file system, and the io layer
-- (fileio.lua) on a real temp folder with failures injected.
local A = require("assert")
local R = require("reaper_stub")
local convert = require("reaporter.core.convert")
local fileio = require("reaporter.fileio")
local ini = require("reaporter.core.ini")
local plan = require("reaporter.core.plan")

local T = {}

-- files = {[path] = bytes}; unreadable / fail = {[path] = true}. fs.log lists every write.
local function fakefs(files)
  local fs = { files = files, unreadable = {}, fail_new = {}, fail_atomic = {}, log = {} }
  function fs.exists(p) return fs.files[p] ~= nil end
  function fs.read(p)
    if fs.unreadable[p] then return nil, "Permission denied" end
    local b = fs.files[p]
    if not b then return nil, "No such file" end
    return b
  end
  function fs.mkdir(d) fs.log[#fs.log + 1] = "mkdir " .. d end
  function fs.write_new(p, b)
    fs.log[#fs.log + 1] = "new " .. p
    if fs.files[p] then error(p .. " already exists", 0) end
    if fs.fail_new[p] or fs.fail_new.all then error("disk full", 0) end
    fs.files[p] = b
  end
  function fs.write_atomic(p, b)
    fs.log[#fs.log + 1] = "atomic " .. p
    if fs.fail_atomic[p] then error("cannot replace " .. p .. ": rename failed", 0) end
    fs.files[p] = b
  end
  return fs
end

local INI = "/res/presets/vst3-X.ini"
local SIDE = "/res/MixSurface/fx-presets/vst3-X.ini.json"
local BACKUPS = "/res/presets/ReaPorter-backup"
local NAMED = { { "Alpha", "/v/Alpha.x" }, { "Beta", "/v/Beta.x" } }

-- A finished, encoded job for the fresh names of NAMED against `fs`.
local function job_for(fs)
  local named = plan.fresh(fs, INI, NAMED)
  local job = { named = named, ok = {}, failed = {} }
  for _, e in ipairs(named) do job.ok[#job.ok + 1] = { e[1], e[2], "STATE-" .. e[1] } end
  convert.encode(job, 7, 2, 2)
  return job
end

local function opts(fs, job, sidecar)
  return {
    fs = fs, job = job, found = #NAMED, adapter = { key = "x" }, plugin = { roots = { "/v" } },
    named = NAMED, ini_in = INI, ini_out = INI, backup_dir = BACKUPS, stamp = "20260101-000000",
    side_in = sidecar and SIDE or nil, side_out = sidecar and SIDE or nil,
  }
end

local function writes(fs)
  local out = {}
  for _, l in ipairs(fs.log) do
    if not l:find("^mkdir") then out[#out + 1] = l end
  end
  return out
end

local USER_FILE = ini.ini_bytes({ { "Mine", "\1" } })

T["plan: an existing file that cannot be read is refused, never replaced"] = function()
  local fs = fakefs({ [INI] = USER_FILE })
  fs.unreadable[INI] = true
  local counts = plan.dry_run(fs, INI, NAMED)
  A.eq(counts.found, 2)
  A.truthy(counts.error:find("exists but cannot be read", 1, true), counts.error)
  A.raises(function() plan.fresh(fs, INI, NAMED) end, "exists but cannot be read")
  local job = { named = NAMED, ok = { { "Alpha", "/v/Alpha.x", "S" } }, failed = {} }
  convert.encode(job, 7, 2, 2)
  local r = plan.write(opts(fs, job, true))
  A.truthy(r.error:find("cannot be read", 1, true), r.error)
  A.eq(r.written, 0)
  A.eq(writes(fs), {})
  A.eq(fs.files[INI], USER_FILE)
  A.truthy(r.sidecar_error:find("preset file was not written", 1, true))
end

T["plan: an unreadable sidecar is refused and the ini result still stands"] = function()
  local fs = fakefs({ [SIDE] = "{}\n" })
  fs.unreadable[SIDE] = true
  local r = plan.write(opts(fs, job_for(fs), true))
  A.eq(r.written, 2)
  A.eq(r.error, nil)
  A.truthy(r.sidecar_error:find("cannot be read", 1, true), r.sidecar_error)
  A.eq(fs.files[SIDE], "{}\n")
end

T["plan: a failed backup write stops before the preset file is written"] = function()
  local fs = fakefs({ [INI] = USER_FILE })
  fs.fail_new.all = true
  local r = plan.write(opts(fs, job_for(fs), false))
  A.truthy(r.error:find("disk full", 1, true), r.error)
  A.eq(r.written, 0)
  A.eq(r.backup, nil)
  A.eq(writes(fs), { "new " .. BACKUPS .. "/vst3-X.20260101-000000.ini" })
  A.eq(fs.files[INI], USER_FILE)
end

T["plan: a failed replace keeps the original and names the backup"] = function()
  local fs = fakefs({ [INI] = USER_FILE })
  fs.fail_atomic[INI] = true
  local r = plan.write(opts(fs, job_for(fs), true))
  A.eq(r.written, 0)
  A.truthy(r.error:find("rename failed", 1, true), r.error)
  A.truthy(r.error:find("backed up at " .. BACKUPS .. "/vst3-X.20260101-000000.ini", 1, true), r.error)
  A.eq(fs.files[INI], USER_FILE)
  A.eq(fs.files[r.backup], USER_FILE)
  A.eq(fs.files[SIDE], nil)
end

T["plan: backup first, then the file; a re-run is a no-op"] = function()
  local fs = fakefs({ [INI] = USER_FILE })
  local r = plan.write(opts(fs, job_for(fs), true))
  A.eq({ r.written, r.skipped, r.error, r.sidecar_error, r.sidecar_written }, { 2, 0, nil, nil, true })
  A.eq(writes(fs), { "new " .. r.backup, "atomic " .. INI, "atomic " .. SIDE })
  A.eq(fs.files[r.backup], USER_FILE)
  A.eq(ini.listed_names(fs.files[INI]), { "Mine", "Alpha", "Beta" })
  local before = #fs.log
  local again = plan.write(opts(fs, job_for(fs), true))
  A.eq({ again.written, again.skipped, again.backup, again.sidecar_written }, { 0, 2, nil, nil })
  A.eq(again.sidecar.imported, 2)
  A.eq(writes({ log = { table.unpack(fs.log, before + 1) } }), {})
end

T["plan: the sidecar is written only when it changes and imports something"] = function()
  local fs = fakefs({})
  local job = { named = {}, ok = {}, failed = {} }
  local r = plan.write(opts(fs, job, true))
  A.eq({ r.written, r.sidecar_written, r.sidecar.imported }, { 0, nil, 0 })
  A.eq(writes(fs), {})
end

T["plan: backups never overwrite one another"] = function()
  local fs = fakefs({ [BACKUPS .. "/vst3-X.S.ini"] = "old", [BACKUPS .. "/vst3-X.S-2.ini"] = "older" })
  A.eq(plan.backup_path(fs, BACKUPS, "vst3-X.ini", "S"), BACKUPS .. "/vst3-X.S-3.ini")
  A.eq(plan.backup_path(fs, BACKUPS, "vst3-Y.ini", "S"), BACKUPS .. "/vst3-Y.S.ini")
  -- two plugins sharing a preset file in one run, the stamp unchanged
  local files = { [INI] = USER_FILE }
  local fs2 = fakefs(files)
  local first = plan.write(opts(fs2, job_for(fs2), false))
  files[INI] = USER_FILE
  local second = plan.write(opts(fs2, job_for(fs2), false))
  A.truthy(first.backup ~= second.backup, "distinct backups")
  A.eq({ fs2.files[first.backup], fs2.files[second.backup] }, { USER_FILE, USER_FILE })
end

T["plan: a merge the ini refuses writes nothing"] = function()
  local bad = "[Preset0]\nName=A\n"
  local fs = fakefs({ [INI] = bad })
  local job = { named = NAMED, ok = { { "Alpha", "/v/Alpha.x", "S" } }, failed = {} }
  convert.encode(job, 7, 2, 2)
  local r = plan.write(opts(fs, job, false))
  A.truthy(r.error:find("NbPresets", 1, true), r.error)
  A.eq(writes(fs), {})
end

-- fileio on a real folder

local function real(dir, o)
  o = o or {}
  o.exists = function(p) return R.read(p) ~= nil end
  return fileio.new(o)
end

T["fileio: a failed rename leaves the original and no temp file"] = function()
  local dir = R.tempdir()
  local path = dir .. "/a.ini"
  R.write(path, "original")
  local fs = real(dir, { rename = function() return nil, "busy" end })
  A.raises(function() fs.write_atomic(path, "new") end, "cannot replace")
  A.eq(R.read(path), "original")
  A.eq(R.tree(dir), { "a.ini" })
  R.sh("rm -rf '" .. dir .. "'")
end

T["fileio: on Windows a rename failing after the remove keeps the temp file and names it"] = function()
  local dir = R.tempdir()
  local path = dir .. "/a.ini"
  R.write(path, "original")
  local fs = real(dir, { windows = true, rename = function() return nil, "denied" end })
  local ok, err = pcall(fs.write_atomic, path, "new")
  A.eq(ok, false)
  A.truthy(err:find(path .. ".reaporter-tmp", 1, true), err)
  A.eq(R.read(path .. ".reaporter-tmp"), "new")
  A.raises(function() fs.write_atomic(path, "newer") end, "left from an earlier run")
  A.eq(R.read(path .. ".reaporter-tmp"), "new")
  R.sh("rm -rf '" .. dir .. "'")
end

T["fileio: write_new refuses a file that exists; write_atomic replaces"] = function()
  local dir = R.tempdir()
  local fs = real(dir)
  fs.write_new(dir .. "/b.ini", "one")
  A.raises(function() fs.write_new(dir .. "/b.ini", "two") end, "already exists")
  A.eq(R.read(dir .. "/b.ini"), "one")
  fs.write_atomic(dir .. "/b.ini", "two")
  A.eq(R.read(dir .. "/b.ini"), "two")
  A.eq(R.tree(dir), { "b.ini" })
  R.sh("rm -rf '" .. dir .. "'")
end

return T
