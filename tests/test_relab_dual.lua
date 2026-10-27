-- LX480 Dual Engine: the SQLite reader, the browser database and .lx480pack members, the
-- state, and members through scan, dry run, conversion, known failures and the sidecar.
-- Synthetic fixtures only.
local A = require("assert")
local F = require("fixtures")
local convert = require("reaporter.core.convert")
local failed = require("reaporter.core.failed")
local ini = require("reaporter.core.ini")
local juce = require("reaporter.codec.juce")
local relab = require("reaporter.adapters.relab")
local scan = require("reaporter.core.scan")
local sidecar = require("reaporter.core.sidecar")
local sqlite = require("reaporter.codec.sqlite")
local text = require("reaporter.core.text")

local T = {}

local IDS = relab.PARAM_IDS
local SCHEMA = {
  preset = "CREATE TABLE preset (id TEXT NOT NULL,name TEXT NOT NULL,data TEXT NOT NULL,creator TEXT,"
    .. "notes TEXT,metadata TEXT,version TEXT,readonly INTEGER,created_at TEXT,modified_at TEXT,PRIMARY KEY (id))",
  pack = "CREATE TABLE pack(id TEXT NOT NULL,name TEXT NOT NULL,creator TEXT,notes TEXT,metadata TEXT,"
    .. "readonly INTEGER,created_at TEXT,modified_at TEXT,PRIMARY KEY (id))",
  tag = "CREATE TABLE tag(id TEXT NOT NULL,name TEXT NOT NULL,colour TEXT,category TEXT,readonly INTEGER,"
    .. "metadata TEXT,PRIMARY KEY (id))",
  preset_pack = "CREATE TABLE preset_pack(preset_id TEXT NOT NULL,pack_id TEXT NOT NULL,"
    .. "FOREIGN KEY (preset_id) REFERENCES preset (id),FOREIGN KEY (pack_id) REFERENCES pack (id))",
  preset_tag = "CREATE TABLE preset_tag(preset_id TEXT NOT NULL,tag_id TEXT NOT NULL,"
    .. "FOREIGN KEY (preset_id) REFERENCES preset (id),FOREIGN KEY (tag_id) REFERENCES tag (id))",
}

-- A browser database: presets {{id, name, data, pack, tags}}.
local function browser_db(presets, extra_rows)
  local rows = { preset = {}, pack = { { "pk1", "Halls" }, { "pk2", "Plates" } },
    tag = { { "t1", "Dark" }, { "t2", "Long Decay" } }, preset_pack = {}, preset_tag = {} }
  for _, p in ipairs(presets) do
    rows.preset[#rows.preset + 1] = { p[1], p[2], p[3], "Synthetic", "", "", "4.1.0", 1 }
    if p[4] then rows.preset_pack[#rows.preset_pack + 1] = { p[1], p[4] } end
    for _, t in ipairs(p[5] or {}) do rows.preset_tag[#rows.preset_tag + 1] = { p[1], t } end
  end
  for _, r in ipairs(extra_rows or {}) do rows.preset[#rows.preset + 1] = r end
  local tables = {}
  for _, name in ipairs({ "tag", "preset", "pack", "preset_pack", "preset_tag" }) do
    tables[#tables + 1] = { name = name, sql = SCHEMA[name], rows = rows[name] }
  end
  return F.sqlite(tables, 2048)
end

local function state_xml(chunk)
  local n = string.unpack("<I4", chunk)
  local comp = chunk:sub(9, 8 + n)
  A.eq(comp:sub(1, 4), "VC2!")
  local len = string.unpack("<I4", comp, 5)
  return comp:sub(9, 8 + len), comp:sub(9 + len), chunk:sub(9 + n)
end

local DUAL = { dual = true, members = relab.members }

T["sqlite: rows across leaf pages, an interior root and overflow chains"] = function()
  local long = ("x"):rep(3000) .. "end"
  local rows = {}
  for i = 1, 40 do rows[i] = { "id" .. i, i == 7 and long or ("row " .. i), i } end
  local db = sqlite.open(F.sqlite({
    { name = "t", sql = "CREATE TABLE t (id TEXT, \"body\" TEXT, n INTEGER, PRIMARY KEY (id))", rows = rows },
  }))
  local t = sqlite.tables(db)
  A.eq(t.t.columns, { "id", "body", "n" })
  local got = sqlite.select(db, "t")
  A.eq(#got, 40)
  A.eq({ got[1].id, got[40].body, got[40].n }, { "id1", "row 40", 40 })
  A.eq(got[7].body, long)
  A.eq(sqlite.select(db, "nope"), nil)
end

T["sqlite: not a database, or a UTF-16 one, is refused"] = function()
  A.raises(function() sqlite.open("SQLite format 2\0" .. ("\0"):rep(200)) end, "not an SQLite")
  local f = F.sqlite({ { name = "t", sql = "CREATE TABLE t (a TEXT)", rows = { { "x" } } } })
  A.raises(function() sqlite.open(f:sub(1, 56) .. string.pack(">I4", 2) .. f:sub(61)) end, "encoding 2")
end

T["text: UTF-16 LE with surrogate pairs"] = function()
  A.eq(text.utf16le_to_utf8("A\0\xE9\0=\xD8\x00\xDE"), "A\xC3\xA9\xF0\x9F\x98\x80")
  A.raises(function() text.utf16le_to_utf8("=\xD8A\0") end, "surrogate")
  A.raises(function() text.utf16le_to_utf8("A") end, "odd")
end

T["relab dual: the state is the browser's values as <LX480> XML, sorted PARAMs"] = function()
  local data = F.lx480_data(IDS)
  local x, tail, controller = state_xml(relab.to_state(data, "/s/db.lx480#p1", DUAL))
  A.eq(tail, "\0" .. ("\0"):rep(16) .. juce.PRIVATE_MAGIC)
  A.eq(controller, ("\0"):rep(8))
  A.truthy(text.starts_with(x, '<?xml version="1.0" encoding="UTF-8"?> <LX480 version="4.1.0">'
    .. '<applicationSettings><faderMappings><engine1 fader1option="3" fader0category="2"/><engine2/>'
    .. "</faderMappings></applicationSettings>"), x:sub(1, 300))
  local ids, prev = 0, ""
  for id, v in x:gmatch('<PARAM id="([^"]*)" value="([^"]*)"/>') do
    ids = ids + 1
    A.truthy(id > prev, "sorted at " .. id)
    prev = id
    local i
    for k, want in ipairs(IDS) do if want == id then i = k end end
    A.eq(v, ("%d.5"):format(i))
  end
  A.eq(ids, #IDS)
  A.truthy(x:find('<transient currentSlot="0" presetId="', 1, true))
  A.truthy(x:find('<lockedParameters bypass="0" ioMode="0"', 1, true))
  A.truthy(text.ends_with(x, 'applicationSettings.faderMappings.engine2="0"/></LX480>'))
end

T["relab dual: a preset the plugin layout does not match fails"] = function()
  local function fails(data, part) A.raises(function() relab.to_state(data, "/a#1", DUAL) end, part) end
  fails(F.lx480_data(IDS, { drop = "e2_width" }), "163 parameters")
  fails(F.lx480_data(IDS, { extra = { "e3_size", "1.0" } }), "unknown parameter e3_size")
  fails(F.lx480_data(IDS, { extra = { "bypass", "1.0" } }), "bypass twice")
  fails(F.lx480_data(IDS, { value_of = function(id) return id == "e1_size" and "big" or "1.0" end }), "float")
  fails(F.lx480_data(IDS, { version = "5.0.0" }), "only 4.x")
  fails(F.lx480_data(IDS, { tag = "Q82" }), "not an LX480 preset")
  fails("<Preset/>", "JSON")
end

T["relab dual: database members, filed by pack with their tags, by pack then name"] = function()
  local db = browser_db({
    { "p1", "Zeta Hall", F.lx480_data(IDS), "pk1", { "t2", "t1" } },
    { "p2", "Alpha Plate", F.lx480_data(IDS), "pk2" },
    { "p3", "Alpha Hall", ("{}"):rep(1500), "pk1", { "t1" } },
    { "p4", "Default Preset", "{}" },
  })
  local m = relab.members("/s/Presets.lx480", function() return db end)
  local got = {}
  for i, e in ipairs(m) do got[i] = { e.key, e.name, e.folder[1] or "-", table.concat(e.tags, ",") } end
  A.eq(got, {
    { "p4", "Default Preset", "-", "" },
    { "p3", "Alpha Hall", "Halls", "Dark" },
    { "p1", "Zeta Hall", "Halls", "Long Decay,Dark" },
    { "p2", "Alpha Plate", "Plates", "" },
  })
  A.eq(m[3].bytes, F.lx480_data(IDS))
  A.eq(m[2].bytes, ("{}"):rep(1500))
end

T["relab dual: pack export members (UTF-16, BOM, CRLF)"] = function()
  local pack = F.lx480pack({
    tags = { { "t1", "Halls" }, { "t2", "Bright \u{2014} Wide" } },
    packs = { { "pk", "Essentials" } },
    presets = {
      { id = "a", name = "Big \"Hall\"", data = F.lx480_data(IDS), tags = { "t2", "t1", "missing" }, packs = { "pk" } },
      { id = "b", name = "Loose", data = F.lx480_data(IDS) },
    },
  })
  A.eq(pack:sub(1, 2), "\255\254")
  local m = relab.members("/d/all.lx480pack", function() return pack end)
  A.eq(#m, 2)
  A.eq({ m[1].key, m[1].name, m[1].folder, m[1].tags }, { "a", 'Big "Hall"', { "Essentials" }, { "Bright \u{2014} Wide", "Halls" } })
  A.eq({ m[2].folder, m[2].tags }, { {}, {} })
  A.eq(m[1].bytes, F.lx480_data(IDS))
  A.raises(function() relab.members("/d/x.lx480pack", function() return "\255\254{\0}\0" end) end, "not an LX480 pack")
end

T["relab dual: plugin records, the browser's export folder, flat roots"] = function()
  local settings = '<?xml version="1.0" encoding="UTF-8"?>\n<PROPERTIES>\n  <VALUE name="guiMode" val="1"/>\n'
    .. '  <VALUE name="exportDirectory" val="/Users/me/Desktop/"/>\n</PROPERTIES>\n'
  local fs = F.memfs("/c", { ["Relab Development"] = { ["LX480.settings"] = settings } })
  local env = { dirs = { common = "/c", shared = "/s" }, fs = fs }
  local list = relab.plugins(env)
  A.eq(#list, 2)
  A.eq(list[1].fx_name, "VST3: LX480 v4 (Relab Development)")
  local d = list[2]
  A.eq({ d.fx_name, d.bundle, d.ini_name, d.flat, d.pins },
    { "VST3: Relab LX480 Dual Engine Reverb (Relab Development)", "LX480", "vst3-LX480.ini", true, { 2, 2 } })
  A.eq(d.roots, { "/s/Relab Development/LX480/Presets", "/Users/me/Desktop" })
  A.eq(relab.plugins({ dirs = { common = "/none", shared = "/s" }, fs = fs })[2].roots, { "/s/Relab Development/LX480/Presets" })
  local walked = scan.files({ roots = { "/r" }, exts = { ".lx480pack" }, flat = true },
    F.memfs("/r", { ["a.lx480pack"] = "x", sub = { ["b.lx480pack"] = "y" } }))
  A.eq(walked, { "/r/a.lx480pack" })
end

-- The database plus an export holding one preset already in it and one new one.
local function library()
  local data = F.lx480_data(IDS)
  local db = browser_db({
    { "p1", "Hall One", data, "pk1", { "t1" } },
    { "p2", "Plate", data, "pk2", { "t2" } },
    { "p3", "Broken", "{}", "pk1" },
  })
  local pack = F.lx480pack({
    tags = { { "x", "Imported" } }, packs = { { "q", "Halls" } },
    presets = {
      { id = "p1", name = "Hall One", data = data, packs = { "q" } },
      { id = "n1", name = "Plate", data = data, tags = { "x" }, packs = { "q" } },
    },
  })
  local fs = F.memfs("/r", {
    s = { ["Presets.lx480"] = db },
    d = { ["all.lx480pack"] = pack, ["bad.lx480pack"] = "\255\254x\0", ["notes.txt"] = "x" },
  })
  local plugin = { fx_name = "VST3: Dual (Test)", roots = { "/r/s", "/r/d" }, exts = { ".lx480", ".lx480pack" },
    flat = true, dual = true, members = relab.members, vendor = "Relab" }
  return plugin, fs
end

T["members: one entry per preset, repeats across files left out, a clash named by pack"] = function()
  local plugin, fs = library()
  local named = convert.presets(plugin, fs)
  local got = {}
  for i, e in ipairs(named) do got[i] = { e[1], e[2] } end
  A.eq(got, {
    { "Broken", "/r/s/Presets.lx480#p3" },
    { "Hall One", "/r/s/Presets.lx480#p1" },
    { "Plate (Plates)", "/r/s/Presets.lx480#p2" },
    { "Plate (Halls)", "/r/d/all.lx480pack#n1" },
    { "bad", "/r/d/bad.lx480pack" },
  })
  A.eq(named[2].folder, { "Halls" })
  A.eq(named[2].tags, { "Dark" })
  A.eq(named[3].bytes, F.lx480_data(IDS))
end

T["members: convert, record a bad member and a bad pack, and file the sidecar by pack"] = function()
  local plugin, fs = library()
  local named = convert.presets(plugin, fs)
  local job = convert.new_job(relab, plugin, named)
  local reads = {}
  A.truthy(convert.step(job, function(path)
    reads[#reads + 1] = path
    return fs.read(path)
  end))
  A.eq(reads, { "/r/d/bad.lx480pack" })
  A.eq(#job.ok, 3)
  A.eq(#job.failed, 2)
  local reasons, members = {}, {}
  for _, f in ipairs(job.failed) do reasons[f[1]], members[f[1]] = f[2], f.member or "-" end
  A.eq(members, { ["/r/s/Presets.lx480#p3"] = "Broken", ["/r/d/bad.lx480pack"] = "-" })
  A.truthy(reasons["/r/s/Presets.lx480#p3"]:find("not an LX480 preset"), reasons["/r/s/Presets.lx480#p3"])
  A.truthy(reasons["/r/d/bad.lx480pack"], "the pack that does not parse fails as a whole")
  -- known failures key on the member and check its own bytes
  local store = failed.decode(nil)
  failed.record(store, job)
  local known = failed.checker(store, function() return nil end, plugin.fx_name)
  A.truthy(known(named[1][2], named[1]), "the broken member is known")
  A.eq(known(named[2][2], named[2]), nil)
  local counts = convert.dry_run(named, nil, known)
  A.eq({ counts.found, counts.new, counts.failed }, { 5, 4, 1 })
  -- sidecar: folder is the pack, tags are the browser's
  convert.encode(job, 1, 2, 2)
  local bytes = ini.merge(nil, job.entries)
  local side = sidecar.decode(convert.sidecar(relab, plugin, named, bytes, nil, fs.read))
  local r = side.presets["Hall One"]
  A.eq({ r.folder, r.autoTags, r.source }, { { "Halls" }, { "dark", "Halls", "hall" }, "factory:relab" })
  A.eq(side.presets["Plate (Plates)"].folder, { "Plates" })
end

return T
