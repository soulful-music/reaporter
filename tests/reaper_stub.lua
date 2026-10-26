-- A stub `reaper` and ReaImGui for loading main.lua outside REAPER, backed by a real temp
-- folder. Every reaper.* the script calls must be stubbed here: an unknown one raises, so a
-- typo or a nil call fails the test instead of passing silently.
local plainfs = require("plainfs")

local M = {}

local function sh_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

function M.sh(cmd)
  local ok = os.execute(cmd)
  assert(ok, "command failed: " .. cmd)
end

-- A fresh, empty folder.
function M.tempdir()
  local p = os.tmpname()
  os.remove(p)
  M.sh("mkdir -p " .. sh_quote(p))
  return p
end

function M.write(path, bytes)
  M.sh("mkdir -p " .. sh_quote(path:match("^(.*)/[^/]*$")))
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
end

function M.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local b = f:read("a")
  f:close()
  return b
end

-- Every file under `dir`, relative, sorted.
function M.tree(dir)
  local p = io.popen("cd " .. sh_quote(dir) .. " && find . -type f | sort")
  local out = {}
  for l in p:lines() do out[#out + 1] = l:sub(3) end
  p:close()
  return out
end

-- ReaImGui: constants are 0, calls return what keeps the window drawing every branch.
-- clicks = {{label part, value}, ...}: the first enabled Checkbox or TreeNodeEx whose label
-- holds the part takes the click and returns the value, as a user's click would.
local function imgui(clicks)
  clicks = clicks or {}
  local disabled = {} -- BeginDisabled's stack
  local next_open
  local function click(label)
    local c = clicks[1]
    for _, d in ipairs(disabled) do
      if d then return false end
    end
    if c and label:find(c[1], 1, true) then
      table.remove(clicks, 1)
      return true, c[2]
    end
    return false
  end
  local IMGUI_RETURNS = {
    Begin = { true, true },
    BeginTable = { true },
    BeginChild = { true },
    TreeNode = { true },
    GetContentRegionAvail = { 600, 400 },
    GetFrameHeightWithSpacing = { 20 },
    BeginDisabled = function(_, d) disabled[#disabled + 1] = d ~= false end,
    EndDisabled = function() disabled[#disabled] = nil end,
    Checkbox = function(_, label, v)
      local hit, nv = click(label)
      if hit then return true, nv end
      return false, v
    end,
    SetNextItemOpen = function(_, o) next_open = o end,
    TreeNodeEx = function(_, _, label)
      local o = next_open
      next_open = nil
      local hit, nv = click(label)
      if hit then return nv end
      if o == nil then return true end
      return o
    end,
    InputTextWithHint = function(_, _, _, v) return false, v end,
  }
  return setmetatable({}, {
    __index = function(t, k)
      if k:find("_") then
        rawset(t, k, 0)
        return 0
      end
      local r = IMGUI_RETURNS[k]
      local f
      if type(r) == "function" then
        f = r
      else
        f = function() return table.unpack(r or {}) end
      end
      rawset(t, k, f)
      return f
    end,
  })
end

-- opts: root (the only folder listings see: the vendor folders on this machine stay
-- out), resource (folder), os (GetOS string), fx = {[fx name] = {nin, nout, preset file}}
-- for the scratch-track probe. Returns the stub; stub.calls counts each reaper.* call and
-- stub.state holds the deferred function, console text, refresh and undo depth.
function M.reaper(opts)
  local r, ext, calls, tracks = {}, {}, {}, 0
  local st = { refresh = 0, undo = 0 }
  local cache = {}
  local function listing(dir)
    if dir:sub(1, #opts.root + 1) ~= opts.root .. "/" then return { dirs = {}, files = {} } end
    if not cache[dir] then
      local dirs, files = plainfs.list(dir)
      if not dirs then dirs, files = {}, {} end
      table.sort(dirs)
      table.sort(files)
      cache[dir] = { dirs = dirs, files = files }
    end
    return cache[dir]
  end
  local api = {
    ImGui_GetBuiltinPath = function() return opts.resource end,
    GetResourcePath = function() return opts.resource end,
    GetOS = function() return opts.os or "macOS-arm64" end,
    EnumerateFiles = function(dir, i)
      if i < 0 then cache[dir] = nil return nil end
      return listing(dir).files[i + 1]
    end,
    EnumerateSubdirectories = function(dir, i)
      if i < 0 then cache[dir] = nil return nil end
      return listing(dir).dirs[i + 1]
    end,
    file_exists = function(path)
      local p = io.popen("test -e " .. sh_quote(path) .. " && echo y")
      local y = p:read("a")
      p:close()
      return y:find("y") ~= nil
    end,
    RecursiveCreateDirectory = function(dir) M.sh("mkdir -p " .. sh_quote(dir)) return 1 end,
    GetExtState = function(s, k) return ext[s .. "/" .. k] or "" end,
    HasExtState = function(s, k) return ext[s .. "/" .. k] ~= nil end,
    SetExtState = function(s, k, v) ext[s .. "/" .. k] = v end,
    time_precise = os.clock,
    defer = function(f) st.deferred = f end,
    ShowConsoleMsg = function(m) st.console = (st.console or "") .. m end,
    MB = function() end,
    PreventUIRefresh = function(n) st.refresh = st.refresh + n end,
    Undo_BeginBlock = function() st.undo = st.undo + 1 end,
    Undo_EndBlock = function() st.undo = st.undo - 1 end,
    CountTracks = function() return tracks end,
    InsertTrackAtIndex = function() tracks = tracks + 1 end,
    GetTrack = function(_, i) return { index = i } end,
    DeleteTrack = function() tracks = tracks - 1 end,
    TrackFX_AddByName = function(tr, name)
      tr.fx = (opts.fx or {})[name]
      if opts.probe_error then error(opts.probe_error) end
      return tr.fx and 0 or -1
    end,
    TrackFX_GetIOSize = function(tr) return 0, tr.fx[1], tr.fx[2] end,
    TrackFX_GetUserPresetFilename = function(tr) return opts.resource .. "/presets/" .. tr.fx[3] end,
  }
  r.ext, r.calls, r.state = ext, calls, st
  r.tracks = function() return tracks end
  return setmetatable(r, {
    __index = function(_, k)
      local f = api[k]
      if not f then error("reaper." .. tostring(k) .. " is not stubbed", 2) end
      return function(...)
        calls[k] = (calls[k] or 0) + 1
        return f(...)
      end
    end,
  })
end

-- Run main.lua with the stub and the QA hook until its window closes, or for `frames`
-- frames when given. home: the folder os.getenv("HOME") returns meanwhile; clicks: as
-- for imgui. Returns the report's text.
function M.run_main(stub, qa, home, clicks, frames)
  local fx = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/../FX"
  local saved_getenv = os.getenv
  local saved_reaper, saved_qa = rawget(_G, "reaper"), rawget(_G, "REAPORTER_QA")
  local saved_imgui = package.preload.imgui
  for k in pairs(package.loaded) do
    if k:find("^reaporter%.main") then package.loaded[k] = nil end
  end
  package.preload.imgui = function() return function() return imgui(clicks) end end
  package.loaded.imgui = nil
  rawset(_G, "reaper", stub)
  rawset(_G, "REAPORTER_QA", qa)
  os.getenv = function(k) if k == "HOME" then return home end return saved_getenv(k) end
  local ok, err = pcall(function()
    dofile(fx .. "/reaporter/main.lua")
    local st = stub.state
    local n = 0
    while st.deferred and n < (frames or 5000) do
      local f = st.deferred
      st.deferred = nil
      f()
      n = n + 1
    end
    if st.deferred and not frames then error("the window never closed", 0) end
  end)
  os.getenv = saved_getenv
  rawset(_G, "reaper", saved_reaper)
  rawset(_G, "REAPORTER_QA", saved_qa)
  package.preload.imgui = saved_imgui
  package.loaded.imgui = nil
  if not ok then error(err, 0) end
  if stub.state.console then error("console: " .. stub.state.console, 0) end
  return qa and M.read(qa.report)
end

return M
