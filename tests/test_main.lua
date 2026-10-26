-- main.lua itself, through a stub reaper: scan, tick, Convert, results, close.
local A = require("assert")
local F = require("fixtures")
local R = require("reaper_stub")
local ini = require("reaporter.core.ini")

local T = {}

local LIST = "[vstcache]\n"
  .. "Blackhole.vst3=80741FD50C9CDA01,1332365903{565354484F4C45626C61636B686F6C65,Blackhole (Eventide)\n"
  .. "Spring.vst3=0011,77{56535453707267737072696E67000000,Spring (Eventide)\n"
  .. "Blackhole_Immersive.vst3=006E,505373633{5653544248496D626C61636B686F6C65,Blackhole Immersive (Eventide) (16ch)\n"
  .. "Nopins.vst3=0012,88{56535450696E7370696E730000000000,Nopins (Eventide)\n"

local BH = "VST3: Blackhole (Eventide)"
local BHI = "VST3: Blackhole Immersive (Eventide)"
local NOPINS = "VST3: Nopins (Eventide)"
local FX = {
  ["VST3: Blackhole Immersive (Eventide) (16ch)"] = { 2, 2, "vst3-Blackhole Immersive.ini" },
  [NOPINS] = { 6, 4, "vst3-Nopins.ini" },
}

local function tide(n) return F.tide({ { "pluginID", '"ABCD"' }, { "pluginVer", '"1.0.' .. n .. '"' } }) end

-- A resource folder and a home with Eventide presets: files = {[plugin folder] = {name...}}.
local function setup(files, mixsurface)
  local top = R.tempdir()
  local res, home = top .. "/res", top .. "/home"
  R.write(res .. "/reaper-vstplugins_arm64.ini", LIST)
  if mixsurface then R.sh("mkdir -p '" .. res .. "/MixSurface'") end
  for folder, names in pairs(files) do
    for i, n in ipairs(names) do R.write(("%s/Music/Eventide/%s/%s.tide"):format(home, folder, n), tide(i)) end
  end
  return top, res, home
end

local function run(res, home, plugins, extra)
  local opts = { resource = res, root = res:match("^(.*)/[^/]*$"), fx = FX }
  for k, v in pairs(extra or {}) do opts[k] = v end
  local stub = R.reaper(opts)
  if extra and extra.ext then for k, v in pairs(extra.ext) do stub.ext[k] = v end end
  local report = R.run_main(stub, { plugins = plugins, report = res .. "/qa.txt", close = true, sidecar = true }, home)
  return report, stub
end

T["main.lua converts through its window and a re-run adds nothing"] = function()
  local top, res, home = setup({ Blackhole = { "Alpha", "Beta" } })
  local report, stub = run(res, home, { BH })
  A.truthy(report:find("RESULT\t" .. BH .. "\twritten 2\t", 1, true), report)
  A.truthy(report:find("DONE\n", 1, true))
  local file = assert(R.read(res .. "/presets/vst3-Blackhole.ini"))
  A.eq(ini.listed_names(file), { "Alpha", "Beta" })
  A.eq(stub.calls.InsertTrackAtIndex, nil, "no scratch track for a plugin with known pins")
  local again = run(res, home, { BH })
  A.truthy(again:find("RESULT\t" .. BH .. "\twritten 0\t", 1, true), again)
  A.eq(R.read(res .. "/presets/vst3-Blackhole.ini"), file)
  A.eq(R.tree(res .. "/presets"), { "vst3-Blackhole.ini" })
  R.sh("rm -rf '" .. top .. "'")
end

T["main.lua refuses a preset file it cannot read and leaves it alone"] = function()
  local top, res, home = setup({ Blackhole = { "Alpha" } })
  local path = res .. "/presets/vst3-Blackhole.ini"
  local mine = ini.ini_bytes({ { "Mine", "\1" } })
  R.write(path, mine)
  R.sh("chmod 000 '" .. path .. "'")
  local report = run(res, home, { BH })
  R.sh("chmod 644 '" .. path .. "'")
  local row = report:match("ROW\tVST3: Blackhole %(Eventide%)\t([^\n]*)")
  A.truthy(row and row:find("^vst3%-Blackhole%.ini\tfound 1\tnew nil\texist nil\t.*exists but cannot be read"), report)
  A.truthy(not report:find("RESULT", 1, true), report)
  A.eq(R.read(path), mine)
  A.eq(R.tree(res .. "/presets"), { "vst3-Blackhole.ini" })
  R.sh("rm -rf '" .. top .. "'")
end

local function row(report, fx_name)
  return report:match("ROW\t" .. fx_name:gsub("%p", "%%%0") .. "\t([^\n]*)")
end

local function result(report, fx_name)
  return report:match("RESULT\t" .. fx_name:gsub("%p", "%%%0") .. "\t([^\n]*)")
end

local function settled(stub)
  A.eq({ stub.tracks(), stub.state.refresh, stub.state.undo }, { 0, 0, 0 }, "tracks, refresh, undo depth")
end

T["the scan creates no scratch track; a renamed plugin is resolved on Convert"] = function()
  local top, res, home = setup({ ["Blackhole Immersive"] = { "Wide", "Tall" } })
  local report, stub = run(res, home, {})
  A.eq(stub.calls.InsertTrackAtIndex, nil)
  A.truthy(row(report, BHI):find("found 2\tnew nil\texist nil\tresolved on Convert", 1, true), report)
  report, stub = run(res, home, { BHI })
  A.eq(stub.calls.InsertTrackAtIndex, 1)
  settled(stub)
  A.truthy(result(report, BHI):find("^written 2\t"), report)
  A.eq(ini.listed_names(R.read(res .. "/presets/vst3-Blackhole Immersive.ini")), { "Tall", "Wide" })
  R.sh("rm -rf '" .. top .. "'")
end

T["Convert reads pins only for a plugin that gets new entries"] = function()
  local top, res, home = setup({ Nopins = { "One" } })
  R.write(res .. "/presets/vst3-Nopins.ini", ini.ini_bytes({ { "one", "\1" } }))
  local report, stub = run(res, home, { NOPINS })
  A.eq(stub.calls.InsertTrackAtIndex, nil, "nothing new: no scratch track")
  A.truthy(result(report, NOPINS):find("^written 0\tskipped 1\t"), report)
  R.write(home .. "/Music/Eventide/Nopins/Two.tide", tide(2))
  report, stub = run(res, home, { NOPINS })
  A.eq(stub.calls.InsertTrackAtIndex, 1)
  settled(stub)
  A.truthy(result(report, NOPINS):find("^written 1\tskipped 1\tfailed 0\tpins 6/4\t"), report)
  R.sh("rm -rf '" .. top .. "'")
end

T["a failing probe still removes its track and restores refresh and undo"] = function()
  local top, res, home = setup({ ["Blackhole Immersive"] = { "Wide" } })
  local report, stub = run(res, home, { BHI }, { probe_error = "plugin crashed" })
  settled(stub)
  A.eq(stub.calls.DeleteTrack, 1)
  A.truthy(result(report, BHI):find("error [^\t]*plugin crashed"), report)
  A.eq(R.tree(res), { "qa.txt", "reaper-vstplugins_arm64.ini" })
  R.sh("rm -rf '" .. top .. "'")
end

T["ticks and open vendors are saved when they change, before any Convert"] = function()
  local top, res, home = setup({ Blackhole = { "Alpha" }, Spring = { "Boing" } })
  local stub = R.reaper({ resource = res, root = top, fx = FX })
  R.run_main(stub, nil, home, { { "Eventide  (", true }, { "Blackhole##", false } }, 40)
  A.eq(stub.ext["ReaPorter/ticked"], "VST3: Spring (Eventide)")
  local known = "\n" .. stub.ext["ReaPorter/known"] .. "\n"
  A.truthy(known:find("\n" .. BH .. "\n", 1, true) and known:find("\nVST3: Spring (Eventide)\n", 1, true), known)
  A.eq(stub.ext["ReaPorter/open"], "Eventide")
  A.eq(R.tree(res), { "reaper-vstplugins_arm64.ini" })
  local again = R.reaper({ resource = res, root = top, fx = FX })
  for k, v in pairs(stub.ext) do again.ext[k] = v end
  R.run_main(again, nil, home, { { "Eventide  (", false } }, 40)
  A.eq(again.ext["ReaPorter/open"], "")
  A.eq(again.ext["ReaPorter/ticked"], "VST3: Spring (Eventide)")
  R.sh("rm -rf '" .. top .. "'")
end

return T
