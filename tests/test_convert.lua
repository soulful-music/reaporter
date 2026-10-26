local A = require("assert")
local F = require("fixtures")
local convert = require("reaporter.core.convert")
local ini = require("reaporter.core.ini")
local plugin_list = require("reaporter.core.plugin_list")

local T = {}

local LIST = table.concat({
  "[vstcache]",
  "Cinematic_Rooms_Professional.vst3=0011,-123{56535443525031636E656D6174696300,Cinematic Rooms Professional (LiquidSonics)",
  "Blackhole.vst3=80741FD50C9CDA01,1332365903{565354484F4C45626C61636B686F6C65,Blackhole (Eventide)",
  "Blackhole_Immersive.vst3=006E,505373633{5653544248496D626C61636B686F6C65,Blackhole Immersive (Eventide) (16ch)",
  "Blackhole.vst=009CC0E2ACF2D801,1213156421,Blackhole (Eventide)",
  "Kit.vst3=00,7{00000000000000000000000000000000,Kit (Drums)!!!VSTi\r",
}, "\n")

T["plugin list: VST3 lines with uid, VST2 id and name"] = function()
  local l = plugin_list.parse(LIST)
  A.eq(l.Blackhole.uid, 1332365903)
  A.eq(l.Blackhole.fx_id, "HOLE")
  A.eq(l.Cinematic_Rooms_Professional.uid, (-123) & 0xFFFFFFFF)
  A.eq(l.Cinematic_Rooms_Professional.fx_name, "VST3: Cinematic Rooms Professional (LiquidSonics)")
  A.eq(l.Kit.fx_name, "VST3i: Kit (Drums)")
  A.eq(l.Kit.fx_id, nil)
  A.eq(plugin_list.lookup(l, "Cinematic Rooms Professional").uid, (-123) & 0xFFFFFFFF)
end

local function env_for(tree)
  return {
    os = "macOS-arm64",
    dirs = { common = "/lib", user = "/home/Library", music = "/home/Music", shared = "/shared" },
    fs = F.memfs("", tree),
    vst3 = plugin_list.parse(LIST),
  }
end

local CRP = "Cinematic Rooms Professional"

local function crp_tree(files)
  return { lib = { LiquidSonics = { [CRP] = { ["Factory Presets"] = files } } } }
end

T["discover: matched, missing and renamed plugins"] = function()
  local env = env_for({ home = { Music = { Eventide = { Blackhole = {}, ["Blackhole Immersive"] = {}, Nope = {} } } } })
  local groups = convert.discover(require("reaporter.adapters"), env)
  local by = {}
  for _, g in ipairs(groups) do
    for _, p in ipairs(g.plugins) do by[p.fx_name] = p end
  end
  A.eq(by["VST3: Blackhole (Eventide)"].problem, nil)
  A.eq(by["VST3: Blackhole (Eventide)"].listing.uid, 1332365903)
  A.eq(by["VST3: Blackhole (Eventide)"].ini_name, "vst3-Blackhole.ini")
  A.eq(by["VST3: Blackhole (Eventide)"].pins, { 2, 2 })
  A.eq(by["VST3: Nope (Eventide)"].problem, "not installed in REAPER (VST3)")
  A.truthy(by["VST3: Blackhole Immersive (Eventide)"].problem:find("16ch", 1, true))
  A.eq(by["VST3: Cinematic Rooms Professional (LiquidSonics)"].pins, { 4, 2 })
end

T["dry run counts new and existing names, ignoring case"] = function()
  local existing = ini.ini_bytes({ { "hall", "\1" } })
  A.eq(convert.dry_run({ { "Hall", "/a" }, { "Room", "/b" } }, existing), { found = 2, new = 1, exist = 1 })
  A.eq(convert.dry_run({ { "Hall", "/a" } }, nil), { found = 1, new = 1, exist = 0 })
  local bad = convert.dry_run({ { "Hall", "/a" } }, "[Preset0]\nName=x\n")
  A.truthy(bad.error:find("NbPresets", 1, true))
end

T["a failing preset is reported and the rest convert"] = function()
  local tree = crp_tree({ ["A.crp_preset"] = F.partial_state("CRP_PartialStateVT", { 1 }), ["B.crp_preset"] = "junk",
    Sub = { ["C.crp_preset"] = F.partial_state("CRP_PartialStateVT", { 2 }) } })
  local env = env_for(tree)
  local liquid = require("reaporter.adapters.liquidsonics")
  local plugin = convert.discover({ liquid }, env)[1].plugins[1]
  local named = convert.presets(plugin, env.fs)
  A.eq(#named, 3)
  local job = convert.new_job(liquid, plugin, named)
  local calls = 0
  local done = convert.step(job, env.fs.read, function() calls = calls + 1; return calls < 2 end)
  A.eq(done, false)
  A.eq(convert.step(job, env.fs.read), true)
  A.eq(#job.ok, 2)
  A.eq(#job.failed, 1)
  A.truthy(job.failed[1][1]:find("B.crp_preset", 1, true))
  local bytes, added = convert.merged(job, nil, plugin.listing.uid, 4, 2)
  A.eq(added, { "A", "C" })
  local entries = ini.read_ini(bytes)
  local uid, nin, nout, _, name = ini.parse_entry(entries[2][2])
  A.eq({ uid, nin, nout, name }, { plugin.listing.uid, 4, 2, "C" })
end

T["entries are built a few per frame and merge as when built at once"] = function()
  local job = { ok = { { "A", "/a", "S1" }, { "B", "/b", "S2" }, { "C", "/c", "S3" } }, named = {}, failed = {} }
  local calls = 0
  A.eq(convert.encode(job, 5, 2, 2, function() calls = calls + 1; return calls < 2 end), false)
  A.eq(#job.entries, 2)
  A.eq(convert.encode(job, 5, 2, 2), true)
  local whole = { ok = job.ok, named = {}, failed = {} }
  A.eq(convert.merged(job, nil), convert.merged(whole, nil, 5, 2, 2))
  A.eq(job.entries[3], { "C", ini.entry_data(5, "S3", "C", 2, 2), ini.data_lines(ini.entry_data(5, "S3", "C", 2, 2)) })
end

T["a re-run adds nothing and keeps the file"] = function()
  local tree = crp_tree({ ["A.crp_preset"] = F.partial_state("CRP_PartialStateVT", { 1 }) })
  local env = env_for(tree)
  local liquid = require("reaporter.adapters.liquidsonics")
  local plugin = convert.discover({ liquid }, env)[1].plugins[1]
  local named = convert.presets(plugin, env.fs)
  local job = convert.new_job(liquid, plugin, named)
  convert.step(job, env.fs.read)
  local first = convert.merged(job, nil, 1, 4, 2)
  local again, added, skipped = convert.merged(job, first, 1, 4, 2)
  A.eq(again, first)
  A.eq(added, {})
  A.eq(skipped, { "A" })
end

T["the sidecar names the folder and keeps user records"] = function()
  local tree = crp_tree({ Rooms = { ["Booth.crp_preset"] = "x" } })
  local env = env_for(tree)
  local liquid = require("reaporter.adapters.liquidsonics")
  local plugin = convert.discover({ liquid }, env)[1].plugins[1]
  local named = convert.presets(plugin, env.fs)
  local file = ini.ini_bytes({ { "Booth", "\1" }, { "Mine", "\2" } })
  local existing = '{"presets": {"Mine": {"source": "captured", "tags": ["x"]}}}'
  local bytes, stats = convert.sidecar(liquid, plugin, named, file, existing, env.fs.read)
  A.eq(stats.imported, 1)
  A.truthy(bytes:find('"Booth": {\n   "autoTags": [\n    "Rooms",\n    "room"\n   ],\n   "folder": [\n    "Rooms"\n   ],\n   "source": "factory:liquidsonics"', 1, true))
  A.truthy(bytes:find('"Mine": {\n   "source": "captured"', 1, true))
end

T["preset folders per OS"] = function()
  local env = { USERPROFILE = "C:\\Users\\me", APPDATA = "C:\\Users\\me\\AppData\\Roaming", ProgramData = "C:\\ProgramData" }
  local w = convert.dirs("Win64", "C:\\Users\\me", function(k) return env[k] end)
  A.eq(w, { common = "C:/ProgramData", user = "C:/Users/me/AppData/Roaming", music = "C:/Users/me/Music", shared = "C:/Users/Public" })
  local m = convert.dirs("macOS-arm64", "/Users/me")
  A.eq(m.user, "/Users/me/Library/Application Support")
end

return T
