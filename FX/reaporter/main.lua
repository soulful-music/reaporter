-- ReaPorter inside REAPER: file access, REAPER's plugin list, writing presets, and the
-- ReaImGui window. Everything that converts lives in the pure modules.
local adapters = require("reaporter.adapters")
local convert = require("reaporter.core.convert")
local ini = require("reaporter.core.ini")
local plugin_list = require("reaporter.core.plugin_list")
local text = require("reaporter.core.text")

local IMGUI_API = "0.9"
local EXT = "ReaPorter"
local FRAME_BUDGET = 0.025 -- seconds of conversion work per UI frame
-- Set by an automated live test before loading: {plugins = {fx name...}, sidecar, report
-- = path, close, search, hold}. It ticks those plugins, converts, writes a report and
-- closes; with `hold` it only types `search` and leaves the list open.
local QA = rawget(_G, "REAPORTER_QA")

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaPorter needs the ReaImGui extension (0.9 or newer).\n\n"
    .. "Install it from ReaPack (Extensions > ReaPack > Browse packages: ReaImGui), "
    .. "then restart REAPER.", "ReaPorter", 0)
  if reaper.ReaPack_BrowsePackages then reaper.ReaPack_BrowsePackages("ReaImGui") end
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require("imgui")(IMGUI_API)

local SEP = package.config:sub(1, 1)
local RESOURCE = reaper.GetResourcePath():gsub("\\", "/")
local PRESETS = RESOURCE .. "/presets"
local SIDECARS = RESOURCE .. "/MixSurface/fx-presets"

---------------------------------------------------------------------------------------
-- files

local fs = {}

-- REAPER caches folder listings; index -1 drops the cache (measured: without it a file
-- added after the first listing stays invisible).
local function fresh(dir)
  reaper.EnumerateFiles(dir, -1)
  reaper.EnumerateSubdirectories(dir, -1)
end

function fs.list(dir)
  fresh(dir)
  local dirs, files = {}, {}
  local i = 0
  while true do
    local d = reaper.EnumerateSubdirectories(dir, i)
    if not d then break end
    dirs[#dirs + 1] = d
    i = i + 1
  end
  i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    files[#files + 1] = f
    i = i + 1
  end
  return dirs, files
end

function fs.is_dir(path)
  fresh(path)
  return reaper.EnumerateFiles(path, 0) ~= nil or reaper.EnumerateSubdirectories(path, 0) ~= nil
end

function fs.read(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local b = f:read("a")
  f:close()
  return b
end

local function native(path) return SEP == "\\" and path:gsub("/", "\\") or path end

-- Write bytes to a temp file beside `path`, read them back, then rename over `path`.
-- A failure leaves `path` as it was.
local function write_atomic(path, bytes)
  local tmp = path .. ".reaporter-tmp"
  local f, err = io.open(tmp, "wb")
  if not f then error("cannot write " .. tmp .. ": " .. tostring(err), 0) end
  local ok, werr = f:write(bytes)
  f:close()
  if not ok or fs.read(tmp) ~= bytes then
    os.remove(tmp)
    error("writing " .. tmp .. " failed: " .. tostring(werr or "read-back differs"), 0)
  end
  local renamed, rerr = os.rename(tmp, path)
  if not renamed and SEP == "\\" and reaper.file_exists(path) then
    -- Windows will not rename over a file; the caller holds a backup of it.
    os.remove(path)
    renamed, rerr = os.rename(tmp, path)
  end
  if not renamed then
    os.remove(tmp)
    error("cannot replace " .. path .. ": " .. tostring(rerr), 0)
  end
end

local function backup(ini_name, bytes, stamp)
  local dir = PRESETS .. "/ReaPorter-backup"
  reaper.RecursiveCreateDirectory(native(dir), 0)
  local path = ("%s/%s.%s.ini"):format(dir, ini_name:gsub("%.ini$", ""), stamp)
  local f, err = io.open(path, "wb")
  if not f then error("cannot write the backup " .. path .. ": " .. tostring(err), 0) end
  f:write(bytes)
  f:close()
  if fs.read(path) ~= bytes then error("the backup " .. path .. " does not read back", 0) end
  return path
end

---------------------------------------------------------------------------------------
-- REAPER

local function read_plugin_list()
  for _, n in ipairs(plugin_list.file_names(reaper.GetOS())) do
    local data = fs.read(RESOURCE .. "/" .. n)
    if data then return plugin_list.parse(data) end
  end
  return {}
end

-- Instantiate an FX on a scratch track at the end of the project and read its pin counts
-- and REAPER's preset file name; the track is deleted again.
local function probe_fx(fx_name)
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  local out
  local fx = reaper.TrackFX_AddByName(tr, fx_name, false, -1)
  if fx >= 0 then
    local _, nin, nout = reaper.TrackFX_GetIOSize(tr, fx)
    local file = reaper.TrackFX_GetUserPresetFilename(tr, fx, "")
    out = { nin = nin, nout = nout, ini_name = file and file:match("([^/\\]+)$") }
  end
  reaper.DeleteTrack(tr)
  reaper.Undo_EndBlock("ReaPorter: read plugin pins", -1)
  reaper.PreventUIRefresh(-1)
  return out
end

local function home()
  return os.getenv("HOME") or os.getenv("USERPROFILE") or ""
end

---------------------------------------------------------------------------------------
-- state

local S = {
  phase = "scan", -- scan | ready | converting | done
  groups = {},
  rows = {}, -- every plugin, in display order
  scan_next = 1,
  ticked = {},
  known = {},
  sidecar = reaper.GetExtState(EXT, "sidecar") ~= "0",
  mixsurface = false,
  results = {},
  search = "",
  open = {}, -- vendor -> expanded
  open_saved = false,
}

local function load_set(key)
  local set = {}
  for name in (reaper.GetExtState(EXT, key) .. "\n"):gmatch("([^\n]*)\n") do
    if name ~= "" then set[name] = true end
  end
  return set
end

local function save_set(key, set)
  local names = {}
  for name in pairs(set) do names[#names + 1] = name end
  table.sort(names)
  reaper.SetExtState(EXT, key, table.concat(names, "\n"), true)
end

local function available(p)
  return not p.problem and p.counts and not p.counts.error and p.counts.found > 0
end

local function start_scan()
  local env = {
    os = reaper.GetOS(),
    dirs = convert.dirs(reaper.GetOS(), home()),
    fs = fs,
    vst3 = read_plugin_list(),
  }
  S.groups = convert.discover(adapters, env)
  S.rows = {}
  for _, g in ipairs(S.groups) do
    for _, p in ipairs(g.plugins) do
      p.group = g
      S.rows[#S.rows + 1] = p
    end
  end
  S.ticked, S.known = load_set("ticked"), load_set("known")
  S.open, S.open_saved = load_set("open"), reaper.HasExtState(EXT, "open")
  S.mixsurface = fs.is_dir(RESOURCE .. "/MixSurface")
  S.scan_next = 1
  S.phase = "scan"
end

-- Scan one plugin: its presets on disk and the dry run against REAPER's file.
local function scan_one(p)
  if p.problem and p.listing and p.problem:find("^REAPER lists it as") then
    -- REAPER names this plugin differently from the vendor folder: ask REAPER itself.
    local probed = probe_fx(p.listing.fx_name)
    if probed and probed.ini_name then
      p.ini_name, p.problem = probed.ini_name, nil
      p.pins = p.pins or { probed.nin, probed.nout }
    end
  end
  p.named = convert.presets(p, fs)
  p.counts = convert.dry_run(p.named, fs.read(PRESETS .. "/" .. p.ini_name))
  if not S.known[p.fx_name] then
    S.known[p.fx_name] = true
    if available(p) and p.counts.new > 0 then S.ticked[p.fx_name] = true end
  end
end

local function to_convert()
  local list, total = {}, 0
  for _, p in ipairs(S.rows) do
    if available(p) and S.ticked[p.fx_name] then
      list[#list + 1] = p
      total = total + p.counts.new
    end
  end
  return list, total
end

local function start_convert()
  local list = to_convert()
  S.queue, S.results, S.current = list, {}, nil
  S.stamp = os.date("%Y%m%d-%H%M%S")
  S.total, S.done_count = 0, 0
  for _, p in ipairs(list) do S.total = S.total + p.counts.new end
  save_set("ticked", S.ticked)
  save_set("known", S.known)
  save_open()
  reaper.SetExtState(EXT, "sidecar", S.sidecar and "1" or "0", true)
  S.phase = "converting"
end

-- Write one plugin's merged file (backup first) and its sidecar.
local function finish_plugin(p, job)
  local r = { plugin = p, written = 0, skipped = 0, failed = job.failed }
  local target = PRESETS .. "/" .. p.ini_name
  local ok, err = pcall(function()
    local pins = p.pins
    if not pins then
      local probed = probe_fx(p.listing.fx_name)
      if not probed then error("REAPER could not load the plugin to read its pin count", 0) end
      pins = { probed.nin, probed.nout }
      p.pins = pins
    end
    local existing = fs.read(target)
    local merged, added, skipped = convert.merged(job, existing, p.listing.uid, pins[1], pins[2])
    r.skipped = (#p.named - #job.named) + #skipped
    if #added > 0 then
      reaper.RecursiveCreateDirectory(native(PRESETS), 0)
      if existing then r.backup = backup(p.ini_name, existing, S.stamp) end
      write_atomic(target, merged)
      r.written = #added
    end
    if S.sidecar and S.mixsurface then
      local side_path = SIDECARS .. "/" .. p.ini_name .. ".json"
      local old = fs.read(side_path)
      local bytes, stats = convert.sidecar(p.group.adapter, p, p.named, merged, old, fs.read)
      if bytes ~= old and (old or stats.imported > 0) then
        reaper.RecursiveCreateDirectory(native(SIDECARS), 0)
        write_atomic(side_path, bytes)
      end
      r.sidecar = stats
    end
  end)
  if not ok then r.error = tostring(err) end
  S.results[#S.results + 1] = r
end

-- One frame of conversion work.
local function convert_tick()
  local deadline = reaper.time_precise() + FRAME_BUDGET
  local function more() return reaper.time_precise() < deadline end
  while more() do
    if not S.current then
      local p = table.remove(S.queue, 1)
      if not p then
        S.phase = "done"
        return
      end
      -- Only names the file does not hold yet: the merge would skip the others.
      local fresh = {}
      local taken = {}
      local existing = fs.read(PRESETS .. "/" .. p.ini_name)
      if existing then
        local okf, f = pcall(ini.inspect, existing)
        if okf then taken = f.taken end
      end
      for _, e in ipairs(p.named) do
        if not taken[text.lower(e[1])] then fresh[#fresh + 1] = e end
      end
      S.current = { plugin = p, job = convert.new_job(p.group.adapter, p, fresh) }
    end
    local c = S.current
    local before = c.job.next
    local done = convert.step(c.job, fs.read, more)
    S.done_count = S.done_count + (c.job.next - before)
    if done then
      finish_plugin(c.plugin, c.job)
      S.current = nil
    end
  end
end

---------------------------------------------------------------------------------------
-- UI

local ctx = ImGui.CreateContext("ReaPorter")
local GREY = 0x9A9A9AFF
local RED = 0xE06C6CFF
local GREEN = 0x7CC47CFF

local function plugin_label(p)
  return (p.fx_name:gsub("^VST3i?: ", ""):gsub(" %([^()]*%)$", ""))
end

-- Does a plugin pass the search? Case-insensitive, on the plugin's name or its vendor's.
local function matches(g, p)
  if S.search == "" then return true end
  local q = text.lower(S.search)
  return text.lower(plugin_label(p)):find(q, 1, true) ~= nil
    or text.lower(g.adapter.vendor):find(q, 1, true) ~= nil
end

local function save_open()
  local set = {}
  for v, o in pairs(S.open) do
    if o then set[v] = true end
  end
  save_set("open", set)
  S.open_saved = true
end

local function set_all_open(o)
  for _, g in ipairs(S.groups) do S.open[g.adapter.vendor] = o end
  save_open()
end

local function draw_search()
  ImGui.SetNextItemWidth(ctx, -190)
  local changed, v = ImGui.InputTextWithHint(ctx, "##search", "Search plugins or vendors", S.search)
  if changed then S.search = v end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Expand all") then set_all_open(true) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "Collapse all") then set_all_open(false) end
end

local function count_cells(found, new, exist)
  ImGui.TableNextColumn(ctx)
  ImGui.Text(ctx, tostring(found))
  ImGui.TableNextColumn(ctx)
  if new > 0 then ImGui.Text(ctx, tostring(new)) else ImGui.TextDisabled(ctx, "0") end
  ImGui.TableNextColumn(ctx)
  if exist > 0 then ImGui.TextDisabled(ctx, tostring(exist)) end
end

local function draw_plugin(p)
  ImGui.TableNextRow(ctx)
  ImGui.TableNextColumn(ctx)
  local ok = available(p)
  ImGui.BeginDisabled(ctx, not ok or S.phase ~= "ready")
  local ch, tv = ImGui.Checkbox(ctx, plugin_label(p) .. "##" .. p.fx_name, ok and S.ticked[p.fx_name] or false)
  ImGui.EndDisabled(ctx)
  if ch then S.ticked[p.fx_name] = tv or nil end
  if p.problem then
    ImGui.TableNextColumn(ctx)
    ImGui.TextDisabled(ctx, p.problem)
  elseif not p.counts then
    ImGui.TableNextColumn(ctx)
    ImGui.TextDisabled(ctx, "scanning...")
  elseif p.counts.error then
    ImGui.TableNextColumn(ctx)
    ImGui.TextColored(ctx, RED, "can't merge")
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, p.counts.error) end
  else
    count_cells(p.counts.found, p.counts.new, p.counts.exist)
  end
end

local function draw_list()
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_ScrollY | ImGui.TableFlags_SizingStretchProp
  local _, avail_h = ImGui.GetContentRegionAvail(ctx)
  local footer = ImGui.GetFrameHeightWithSpacing(ctx) * (S.mixsurface and 3 or 2) + 4
  if not ImGui.BeginTable(ctx, "plugins", 4, flags, 0, math.max(120, avail_h - footer)) then return end
  ImGui.TableSetupScrollFreeze(ctx, 0, 1)
  ImGui.TableSetupColumn(ctx, "Plugin", ImGui.TableColumnFlags_WidthStretch, 3)
  ImGui.TableSetupColumn(ctx, "Found", ImGui.TableColumnFlags_WidthStretch, 1)
  ImGui.TableSetupColumn(ctx, "New", ImGui.TableColumnFlags_WidthStretch, 1)
  ImGui.TableSetupColumn(ctx, "Already in REAPER", ImGui.TableColumnFlags_WidthStretch, 1.4)
  ImGui.TableHeadersRow(ctx)
  local searching = S.search ~= ""
  for _, g in ipairs(S.groups) do
    local vendor = g.adapter.vendor
    local shown = {}
    local avail, ticked, found, new, exist = 0, 0, 0, 0, 0
    for _, p in ipairs(g.plugins) do
      if matches(g, p) then shown[#shown + 1] = p end
      if available(p) then
        avail = avail + 1
        if S.ticked[p.fx_name] then
          ticked = ticked + 1
          found, new, exist = found + p.counts.found, new + p.counts.new, exist + p.counts.exist
        end
      end
    end
    if not searching or #shown > 0 then
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.BeginDisabled(ctx, avail == 0 or S.phase ~= "ready")
      local changed, v = ImGui.Checkbox(ctx, "##vendor" .. vendor, avail > 0 and ticked == avail)
      ImGui.EndDisabled(ctx)
      if changed then
        for _, p in ipairs(g.plugins) do
          if available(p) then S.ticked[p.fx_name] = v or nil end
        end
      end
      ImGui.SameLine(ctx)
      if S.open[vendor] == nil then S.open[vendor] = not S.open_saved and #S.groups <= 3 end
      ImGui.SetNextItemOpen(ctx, searching or S.open[vendor])
      local label = ("%s  (%d of %d ticked)"):format(vendor, ticked, avail)
      local open = ImGui.TreeNodeEx(ctx, "vendor" .. vendor, label, ImGui.TreeNodeFlags_SpanAvailWidth)
      if not searching and open ~= S.open[vendor] then
        S.open[vendor] = open
        save_open()
      end
      if g.error then
        ImGui.TableNextColumn(ctx)
        ImGui.TextColored(ctx, RED, "adapter error: " .. g.error)
      elseif #g.plugins == 0 then
        ImGui.TableNextColumn(ctx)
        ImGui.TextDisabled(ctx, "no presets found")
      elseif ticked > 0 then
        count_cells(found, new, exist)
      end
      if open then
        for _, p in ipairs(shown) do draw_plugin(p) end
        ImGui.TreePop(ctx)
      end
    end
  end
  ImGui.EndTable(ctx)
end

-- (ticked plugins the search hides) for the line under the list.
local function hidden_ticked()
  local n = 0
  for _, g in ipairs(S.groups) do
    for _, p in ipairs(g.plugins) do
      if available(p) and S.ticked[p.fx_name] and not matches(g, p) then n = n + 1 end
    end
  end
  return n
end

local function draw_results()
  local _, avail_h = ImGui.GetContentRegionAvail(ctx)
  if not ImGui.BeginChild(ctx, "results", 0, avail_h - ImGui.GetFrameHeightWithSpacing(ctx) - 8) then return end
  local written, skipped, failed = 0, 0, 0
  for _, r in ipairs(S.results) do
    written, skipped, failed = written + r.written, skipped + r.skipped, failed + #r.failed
  end
  ImGui.Text(ctx, ("Written %d, skipped %d (name exists), failed %d."):format(written, skipped, failed))
  ImGui.Spacing(ctx)
  for _, r in ipairs(S.results) do
    local p = r.plugin
    local head = ("%s: %d written, %d skipped, %d failed"):format(plugin_label(p), r.written, r.skipped, #r.failed)
    if r.error then
      ImGui.TextColored(ctx, RED, plugin_label(p) .. ": not written: " .. r.error)
    elseif #r.failed > 0 then
      if ImGui.TreeNode(ctx, head .. "##" .. p.fx_name) then
        for _, f in ipairs(r.failed) do
          ImGui.TextWrapped(ctx, f[1]:match("([^/\\]+)$") .. ": " .. f[2])
        end
        ImGui.TreePop(ctx)
      end
    else
      ImGui.TextColored(ctx, r.written > 0 and GREEN or GREY, head)
    end
    if r.backup then
      ImGui.Indent(ctx, 18)
      ImGui.TextDisabled(ctx, "backup: " .. native(r.backup))
      ImGui.Unindent(ctx, 18)
    end
  end
  ImGui.Spacing(ctx)
  ImGui.TextWrapped(ctx, "REAPER lists the new presets in each plugin's preset menu. "
    .. "An FX window that was open during the conversion shows them after it is closed and reopened.")
  ImGui.EndChild(ctx)
end

local function draw()
  if S.phase == "scan" then
    local deadline = reaper.time_precise() + FRAME_BUDGET
    while S.scan_next <= #S.rows and reaper.time_precise() < deadline do
      local ok, err = pcall(scan_one, S.rows[S.scan_next])
      if not ok then S.rows[S.scan_next].problem = "scan failed: " .. tostring(err) end
      S.scan_next = S.scan_next + 1
    end
    if S.scan_next > #S.rows then S.phase = "ready" end
  elseif S.phase == "converting" then
    convert_tick()
  end

  local avail_w = ImGui.GetContentRegionAvail(ctx)
  if S.phase == "scan" then
    ImGui.Text(ctx, ("Scanning %d of %d plugins..."):format(math.min(S.scan_next, #S.rows), #S.rows))
  elseif S.phase == "converting" then
    ImGui.Text(ctx, "Converting...")
  elseif S.phase == "done" then
    ImGui.Text(ctx, "Done.")
  else
    ImGui.Text(ctx, "Vendor presets found on this computer:")
  end
  ImGui.SameLine(ctx, avail_w - 70)
  ImGui.BeginDisabled(ctx, S.phase == "converting" or S.phase == "scan")
  if ImGui.Button(ctx, "Rescan", 70) then start_scan() end
  ImGui.EndDisabled(ctx)

  if S.phase == "done" then
    draw_results()
    if ImGui.Button(ctx, "Back to the list") then start_scan() end
    return
  end

  draw_search()
  draw_list()

  if S.mixsurface then
    ImGui.BeginDisabled(ctx, S.phase ~= "ready")
    local ch, v = ImGui.Checkbox(ctx, "Write MixSurface folders and tags", S.sidecar)
    if ch then S.sidecar = v end
    ImGui.EndDisabled(ctx)
  end

  if S.phase == "converting" then
    local frac = S.total > 0 and S.done_count / S.total or 1
    local label = S.current and plugin_label(S.current.plugin) or ""
    ImGui.ProgressBar(ctx, frac, -1, 0, ("%s  %d / %d"):format(label, S.done_count, S.total))
  else
    local list, total = to_convert()
    local can = S.phase == "ready" and #list > 0 and (total > 0 or (S.sidecar and S.mixsurface))
    local hidden = hidden_ticked()
    local label = ("Convert %d presets from %d ticked plugins"):format(total, #list)
    if hidden > 0 then label = label .. (" (%d hidden by search)"):format(hidden) end
    ImGui.BeginDisabled(ctx, not can)
    if ImGui.Button(ctx, label .. "##convert", -1) then start_convert() end
    ImGui.EndDisabled(ctx)
  end
end

local function qa_step()
  if QA.hold then
    S.search = QA.search or ""
    return
  end
  if S.phase == "ready" and not QA.started then
    QA.started = true
    S.ticked = {}
    for _, n in ipairs(QA.plugins) do S.ticked[n] = true end
    if QA.sidecar ~= nil then S.sidecar = QA.sidecar end
    start_convert()
  elseif S.phase == "done" and not QA.reported then
    QA.reported = true
    local f = assert(io.open(QA.report, "w"))
    for _, p in ipairs(S.rows) do
      local c = p.counts or {}
      f:write(("ROW\t%s\t%s\tfound %s\tnew %s\texist %s\t%s\n"):format(p.fx_name, p.ini_name,
        tostring(c.found), tostring(c.new), tostring(c.exist), p.problem or c.error or ""))
    end
    for _, r in ipairs(S.results) do
      local sc = r.sidecar
      f:write(("RESULT\t%s\twritten %d\tskipped %d\tfailed %d\tpins %s\tbackup %s\tsidecar %s\terror %s\n"):format(
        r.plugin.fx_name, r.written, r.skipped, #r.failed,
        r.plugin.pins and (r.plugin.pins[1] .. "/" .. r.plugin.pins[2]) or "-", r.backup or "-",
        sc and ("imported " .. sc.imported .. " folder " .. sc.folder) or "-", r.error or "-"))
      for k = 1, math.min(3, #r.failed) do f:write("  FAIL\t", r.failed[k][1], "\t", r.failed[k][2], "\n") end
    end
    f:write("DONE\n")
    f:close()
  end
end

local function loop()
  ImGui.SetNextWindowSize(ctx, 700, 520, ImGui.Cond_FirstUseEver)
  local visible, open = ImGui.Begin(ctx, "ReaPorter", true)
  if visible then
    local ok, err = xpcall(draw, debug.traceback)
    ImGui.End(ctx)
    if not ok then
      reaper.ShowConsoleMsg("ReaPorter: " .. tostring(err) .. "\n")
      return
    end
  end
  if QA then
    qa_step()
    if QA.reported and QA.close then open = false end
  end
  if open then reaper.defer(loop) end
end

start_scan()
reaper.defer(loop)
