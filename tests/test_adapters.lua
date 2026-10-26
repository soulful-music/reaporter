local A = require("assert")
local F = require("fixtures")
local juce = require("reaporter.codec.juce")
local registry = require("reaporter.adapters")

local dmgaudio = require("reaporter.adapters.dmgaudio")
local eventide = require("reaporter.adapters.eventide")
local json = require("reaporter.codec.json")
local zlib = require("reaporter.codec.zlib")
local liquidsonics = require("reaporter.adapters.liquidsonics")
local relab = require("reaporter.adapters.relab")
local reverb_foundry = require("reaporter.adapters.reverb_foundry")
local soundtoys = require("reaporter.adapters.soundtoys")
local valhalla = require("reaporter.adapters.valhalla")

local T = {}

-- (fx_id, fx_version, num_programs, inner chunk) of a VstW-wrapped vst_chunk.
local function unwrap(chunk)
  local comp = chunk:sub(9, 8 + string.unpack("<I4", chunk))
  assert(comp:sub(1, 4) == "VstW" and comp:sub(25, 28) == "FBCh")
  local ver, progs = string.unpack(">I4>I4", comp, 37)
  return comp:sub(33, 36), ver, progs, comp:sub(177, 176 + string.unpack(">I4", comp, 173))
end

-- The plugin state inside a JUCE chunk and its private-data tree.
local function juce_state(inner)
  local plen = string.unpack("<i8", inner, #inner - 15 - 8 + 1)
  local stop = #inner - 15 - 8
  return inner:sub(1, stop - plen), inner:sub(stop - plen + 1, stop)
end

T["registry: every adapter honours the contract"] = function()
  local env = {
    dirs = { common = "/c", user = "/u", music = "/m", shared = "/s" },
    fs = F.memfs("/", {}),
    vst3 = {},
  }
  A.eq(#registry, 7)
  local keys = {}
  for _, a in ipairs(registry) do
    A.truthy(type(a.vendor) == "string" and type(a.key) == "string", "vendor and key")
    A.truthy(type(a.plugins) == "function" and type(a.to_state) == "function", a.vendor)
    A.truthy(not keys[a.key], "unique key " .. a.key)
    keys[a.key] = true
    for _, p in ipairs(a.plugins(env)) do
      A.truthy(p.fx_name:find("^VST3: ") and p.bundle and #p.roots > 0 and #p.exts > 0, p.fx_name)
      A.truthy(p.pins == nil or (#p.pins == 2 and math.type(p.pins[1]) == "integer"
        and math.type(p.pins[2]) == "integer"), "pins of " .. p.fx_name)
    end
  end
end

T["core code names no vendor: vendor data lives in the adapters"] = function()
  local here = arg[0]:match("^(.*)/[^/]*$") or "."
  local p = io.popen("cat '" .. here .. "/../FX/reaporter/core/'*.lua")
  local core = p:read("a"):gsub("%-%-[^\n]*", "")
  p:close()
  for _, a in ipairs(registry) do
    A.truthy(not core:find(a.vendor, 1, true), a.vendor .. " named in core/")
  end
  A.truthy(not core:find("Valhalla", 1, true) and not core:find("Relab", 1, true))
end

T["liquidsonics: the file bytes are the plugin state"] = function()
  local file = F.partial_state("CRP_PartialStateVT", { 1.0, 2.5 })
  local plugin = liquidsonics.plugins({ dirs = { common = "/c", user = "/u" } })[1]
  local fx_id, ver, progs, inner = unwrap(liquidsonics.to_state(file, "x.crp_preset", plugin))
  A.eq({ fx_id, ver, progs }, { "CRP1", 0x010303, 0 })
  local state, private = juce_state(inner)
  A.eq(state, file)
  A.eq(private, juce.private_bypass_tree(false))
end

T["liquidsonics: a tree of another kind fails"] = function()
  local plugin = liquidsonics.plugins({ dirs = { common = "/c", user = "/u" } })[1]
  A.raises(function() liquidsonics.to_state(F.partial_state("CR_FullState", {}), "x", plugin) end, "root")
  A.raises(function() liquidsonics.to_state("garbage", "x", plugin) end, "ValueTree")
end

T["reverb foundry: same recipe, its own id"] = function()
  local plugin = reverb_foundry.plugins({ dirs = { common = "/c", user = "/u" } })[1]
  local file = F.partial_state("TaiChi_PartialStateVT", { 3.0 })
  local fx_id, _, _, inner = unwrap(reverb_foundry.to_state(file, "x.taichi_preset", plugin))
  A.eq(fx_id, "TCR1")
  A.eq((juce_state(inner)), file)
end

T["eventide .tide: JSON text, 8 NULs, at least 1008 bytes"] = function()
  local file = F.tide({ { "pluginID", '"ABCD"' }, { "pluginVer", '"3.8.21"' }, { "mmix", "41.25" } })
  local fx_id, ver, progs, inner = unwrap(eventide.to_state(file .. "  \r\n", "/m/Eventide/X/a.tide"))
  A.eq({ fx_id, ver, progs }, { "ABCD", 0x030815, 0 })
  local state = juce_state(inner)
  A.eq(#state, 1008)
  A.eq(state:sub(1, #file - 2), file:sub(1, -3))
  A.eq(state:sub(#file - 1), ("\0"):rep(1008 - #file + 2))
  local long = F.tide({ { "k", ('"' .. ("x"):rep(1100) .. '"') } })
  local _, _, _, inner2 = unwrap(eventide.to_state(long, "a.tide"))
  A.eq(#juce_state(inner2), #long - 2 + 8)
end

T["eventide .tide: without pluginID the id is zero"] = function()
  local fx_id, ver = unwrap(eventide.to_state(F.tide({ { "mmix", "1" } }), "a.tide"))
  A.eq({ fx_id, ver }, { "\0\0\0\0", 0 })
  A.raises(function() eventide.to_state("{not json", "a.tide") end, "JSON")
  A.raises(function() eventide.to_state('{"pluginVer": 3}', "a.tide") end, "pluginVer")
end

T["eventide .tidex: XML as a typed ValueTree, 8 NULs, no private data"] = function()
  local fx_id, ver, progs, inner = unwrap(eventide.to_state(F.tidex(), "/m/Eventide/X/a.TIDEX"))
  A.eq({ fx_id, ver, progs }, { string.pack(">I4", 1413829460), 0x010203, 1 })
  local state, private = juce_state(inner)
  A.eq(private, "")
  A.eq(state:sub(-8), ("\0"):rep(8))
  local tree = juce.read_tree(state)
  A.eq(tree.type, "STATE")
  A.eq(tree.props[1][1], "plugId")
  A.eq(tree.props[1][2], { kind = juce.INT, value = 1413829460 })
  A.eq(tree.props[2][2], { kind = juce.STRING, value = "1.2.3" })
  local p = tree.children[1].children
  A.eq(p[1].props[2][2], { kind = juce.DOUBLE, value = 0.25 })
  A.eq(p[2].props[2][2], { kind = juce.DOUBLE, value = -3.0 })
  local prop = tree.children[2].children[1].props
  A.eq(prop[2][2], { kind = juce.INT, value = 0 })
  A.eq(prop[4][2], { kind = juce.FALSE })
  A.eq(prop[5][2], { kind = juce.TRUE })
  A.eq(tree.children[2].children[2].props[2][2], { kind = juce.STRING, value = "Room & Hall" })
end

T["eventide .tidex: a non-numeric PARAM value fails"] = function()
  local bad = F.tidex():gsub('value="0.25"', 'value="not-a-number"')
  A.raises(function() eventide.to_state(bad, "a.tidex") end, "float")
end

T["eventide: one plugin per folder, snapshots skipped"] = function()
  local fs = F.memfs("/m", { Eventide = { Blackhole = {}, ["SP2016 Reverb"] = {} } })
  local ps = eventide.plugins({ dirs = { music = "/m" }, fs = fs })
  A.eq(ps[2].fx_name, "VST3: SP2016 Reverb (Eventide)")
  A.eq(ps[1].roots, { "/m/Eventide/Blackhole" })
  A.truthy(ps[1].skip("/m/Eventide/Blackhole/Snapshots/01.tide"))
  A.truthy(not ps[1].skip("/m/Eventide/Blackhole/Presets/01.tide"))
end

T["valhalla: copyXmlToBinary of the one-line XML"] = function()
  local file = F.vpreset("ValhallaVintageVerb", { { "pluginVersion", "9.8.7" }, { "presetName", "A &quot;Q&quot; &amp; B" }, { "Mix", "0.5" } })
  local fs = F.memfs("/c", { ["Valhalla DSP, LLC"] = { ValhallaVintageVerb = { Presets = {} }, Other = {} } })
  local plugin = valhalla.plugins({ dirs = { common = "/c" }, fs = fs })
  A.eq(#plugin, 1)
  local fx_id, ver, progs, inner = unwrap(valhalla.to_state(file, "x.vpreset", plugin[1]))
  A.eq({ fx_id, ver, progs }, { "vee3", 0, 0 })
  local state = juce_state(inner)
  local x = '<?xml version="1.0" encoding="UTF-8"?> <ValhallaVintageVerb pluginVersion="9.8.7" presetName=\'A "Q" &amp; B\' Mix="0.5"/>'
  A.eq(state, "VC2!" .. string.pack("<I4", #x) .. x .. ("\0"):rep(9))
end

T["valhalla: attribute quoting"] = function()
  A.eq(valhalla.quote_attr("a<b>\n"), '"a&lt;b&gt;&#10;"')
  A.eq(valhalla.quote_attr([[it's "x"]]), [["it's &quot;x&quot;"]])
end

T["relab: a v4 preset fills the tagged float blocks"] = function()
  local file = F.lx480()
  local path = "/c/Relab Development/LX480/Presets/Hall/A.lx480"
  local chunk = relab.to_state(file, path)
  local n, one = string.unpack("<I4<I4", chunk)
  A.eq(one, 1)
  local comp = chunk:sub(9, 8 + n)
  A.eq(chunk:sub(9 + n), ("\0"):rep(8))
  A.eq(comp:sub(1, 16), "PHXF\1\0\0\0pwen\0\0\0\0")
  local o, blocks = 17, {}
  for _, tag in ipairs({ "tsrp", "srpn", "IUG_", "2srp", "lsrp" }) do
    A.eq(comp:sub(o, o + 3), tag)
    local size, zero, count = string.unpack("<I4<I4<I4", comp, o + 4)
    A.eq({ size, zero }, { 8 + 4 * count, 0 })
    blocks[tag] = { string.unpack(("<" .. ("f"):rep(count)), comp, o + 16) }
    o = o + 8 + size
  end
  A.eq(blocks.tsrp[4], 1.0)
  A.eq(blocks["2srp"][96], 24.0)
  A.eq({ blocks.srpn[2], blocks.srpn[10], blocks.srpn[11], blocks.srpn[25] }, { 3.5, 3.5, 5.0, 3.5 })
  A.eq({ blocks.IUG_[9], blocks.IUG_[10] }, { 1.0, 120.0 })
  local name = ":Macintosh HD:c:Relab Development:LX480:Presets:Hall:A.lx480"
  A.eq(comp:sub(o), "MNSP" .. string.pack("<I4", #name) .. name .. ("\0"):rep(16) .. "JUCEPrivateData")
end

T["relab: the legacy layout and wrong counts fail"] = function()
  A.raises(function() relab.to_state(F.legacy_lx480(), "/a.lx480") end, "legacy")
  A.raises(function() relab.to_state(F.lx480({ engine_count = 95 }), "/a.lx480") end, "95 values")
  A.raises(function() relab.to_state(F.lx480({ session = { "Nope" } }), "/a.lx480") end, "Nope")
  A.raises(function() relab.to_state(F.lx480({ value = "1e39" }), "/a.lx480") end, "too large")
end

T["soundtoys: the text wrapped VST2-style, id from REAPER's list"] = function()
  local fs = F.memfs("/s", { Soundtoys = { ["Soundtoys 5"] = { ["Devil-Loc"] = {}, Rhythms = {} } } })
  local vst3 = {
    Devil_Loc = { uid = 1, fx_id = "StDL", fx_name = "VST3: Devil-Loc (Soundtoys)", line = 1 },
    Other = { uid = 2, fx_id = "OOOO", fx_name = "VST3: Other (Elsewhere)", line = 2 },
  }
  local ps = soundtoys.plugins({ dirs = { shared = "/s" }, fs = fs, vst3 = vst3 })
  A.eq(#ps, 1)
  A.eq({ ps[1].fx_name, ps[1].bundle, ps[1].fx_id }, { "VST3: Devil-Loc (Soundtoys)", "Devil_Loc", "StDL" })
  local file = F.toy("DevilLoc")
  local chunk = soundtoys.to_state(file, "x.toy", ps[1])
  local fx_id, ver, progs, inner = unwrap(chunk)
  A.eq({ fx_id, ver, progs, inner }, { "StDL", 1, 1, file })
  A.raises(function() soundtoys.to_state("WIDGET = X;\r", "x.toy", ps[1]) end, "archive")
end

-- The state document inside a DMGAudio vst_chunk, and its JSON text.
local function dmg_state(chunk)
  local n = string.unpack("<I4", chunk)
  A.eq(string.unpack("<I4", chunk, 5), 1)
  A.eq(chunk:sub(9 + n), ("\0"):rep(8))
  local comp = chunk:sub(9, 8 + n)
  A.eq(comp:sub(1, 4), "ZIP ")
  local text = zlib.inflate(comp:sub(5))
  A.eq(text:sub(-1), "\0")
  return json.decode(text:sub(1, -2)), text:sub(1, -2)
end

local function dmg_plugin(name)
  for _, p in ipairs(dmgaudio.plugins({ dirs = { common = "/c" } })) do
    if p.bundle == name then return p end
  end
end

T["dmgaudio: every plugin ships its fresh state and pins"] = function()
  local ps = dmgaudio.plugins({ dirs = { common = "/c" } })
  A.eq(#ps, 3)
  for _, p in ipairs(ps) do
    A.truthy(json.is_object(dmgaudio.read_json(p.fresh)), p.bundle)
    A.eq(p.pins, { 4, 2 })
    A.eq(p.roots, { "/c/DMGAudio/" .. p.bundle .. "/Presets" })
  end
end

T["dmgaudio: a full-state preset's keys replace the fresh state's, the rest stays"] = function()
  local plugin = { fresh = F.DMG_FRESH }
  local file = F.dmg('{"presets": [{"parameters": {"kOne": 0.25}, "name": "P"}], "settings": {"currentAB": 1}, "extra": 2}')
  local doc, text = dmg_state(dmgaudio.to_state(file, "x.exp", plugin))
  A.eq(json.keys(doc), { "presets", "ab", "settings", "uiprefs", "v101", "extra" })
  A.eq(doc.presets[1].parameters.kOne, 0.25)
  A.eq(doc.settings.currentAB, 1)
  A.eq(doc.settings.zoomLevel, nil)
  A.eq(doc.v101, true)
  A.eq(text:sub(1, 16), '{\n\t"presets": [\n')
end

T["dmgaudio: a top-level preset goes into presets and the current A/B slot, v101 dropped"] = function()
  local plugin = { fresh = F.DMG_FRESH }
  local file = F.dmg('{"parameters": {"kB1": 0.5, "kB2": 1}, "name": "Synthetic Top", "settings": {"currentAB": 2}}', true)
  local doc = dmg_state(dmgaudio.to_state(file, "x.multiplicitypreset", plugin))
  A.eq(json.keys(doc), { "presets", "ab", "settings", "uiprefs" })
  A.eq(json.keys(doc.presets[1]), { "parameters", "name" })
  A.eq(doc.presets[1].name, "Synthetic Top")
  A.eq(#doc.ab, 8)
  for i, slot in ipairs(doc.ab) do
    if i == 3 then A.eq(json.keys(slot.parameters), { "kB1", "kB2" }) else A.eq(slot.parameters, "default") end
  end
  A.eq(doc.v101, nil)
  local kept = dmg_state(dmgaudio.to_state(F.dmg('{"parameters": {}, "v101": true}'), "x", plugin))
  A.eq(json.keys(kept), { "presets", "ab", "settings", "uiprefs", "v101" })
  A.eq(kept.presets[1].name, "")
  A.eq(kept.ab[1].parameters, json.decode("{}"))
end

T["dmgaudio: files that are not a preset fail"] = function()
  local plugin = { fresh = F.DMG_FRESH }
  A.raises(function() dmgaudio.to_state(F.dmg('{"presets": []}'), "x", plugin) end, "empty presets")
  A.raises(function() dmgaudio.to_state(F.dmg('{"name": "x"}'), "x", plugin) end, "no presets list")
  A.raises(function() dmgaudio.to_state(F.dmg("[1]"), "x", plugin) end, "not a JSON object")
  A.raises(function() dmgaudio.to_state("ZIP garbage", "x", plugin) end, "zlib")
  A.raises(function() dmgaudio.to_state(F.dmg("{}"), "x", {}) end, "fresh")
end

return T
