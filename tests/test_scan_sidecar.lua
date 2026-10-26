local A = require("assert")
local F = require("fixtures")
local scan = require("reaporter.core.scan")
local sidecar = require("reaporter.core.sidecar")

local T = {}

local VOCAB = sidecar.load_vocab()
local CRP = "/Library/Application Support/LiquidSonics/Cinematic Rooms Professional/"
local ROOTS = { CRP .. "Factory Presets", "/Users/u/Library/Application Support/LiquidSonics/CRP/User Presets" }

T["scan: files in byte order, folders after files, roots in order"] = function()
  local fs = F.memfs("/r", {
    A = { b = { ["x.tide"] = "1" }, ["z.tide"] = "1", ["a.TIDE"] = "1", ["n.txt"] = "1" },
    ["top.tide"] = "1",
    Snap = { ["s.tide"] = "1" },
  })
  local plugin = { roots = { "/r", "/missing" }, exts = { ".tide" }, skip = function(p) return p:find("/Snap/", 1, true) end }
  local paths = scan.files(plugin, fs)
  A.eq(paths, { "/r/top.tide", "/r/A/a.TIDE", "/r/A/z.tide", "/r/A/b/x.tide" })
end

T["scan: an unreadable folder is reported and skipped"] = function()
  local fs = F.memfs("/r", { ok = { ["a.tide"] = "1" }, locked = { __unreadable = true } })
  local paths, unreadable = scan.files({ roots = { "/r" }, exts = { ".tide" } }, fs)
  A.eq(paths, { "/r/ok/a.tide" })
  A.eq(unreadable, { "/r/locked" })
end

T["naming: a repeated stem gets its folder, then a number"] = function()
  A.eq(scan.named({ "/r/A/Hall.tide", "/r/B/hall.tide", "/r/Room.tide", "/r/A/x/Hall.tide" }), {
    { "Hall (A)", "/r/A/Hall.tide" }, { "hall (B)", "/r/B/hall.tide" }, { "Room", "/r/Room.tide" },
    { "Hall (x)", "/r/A/x/Hall.tide" },
  })
  A.eq(scan.named({ "/r/A/Hall.tide", "/q/A/Hall.tidex" }), {
    { "Hall (A)", "/r/A/Hall.tide" }, { "Hall (A) 2", "/q/A/Hall.tidex" },
  })
end

T["sidecar: folder relative to the factory root"] = function()
  A.eq(sidecar.folder_of(CRP .. "Factory Presets/Post/Small Rooms/Booth.crp_preset", ROOTS), { "Post", "Small Rooms" })
  A.eq(sidecar.folder_of(CRP .. "Factory Presets/Amethyst Hall.crp_preset", ROOTS), {})
end

T["sidecar: a user root is filed under its own name"] = function()
  A.eq(sidecar.folder_of(ROOTS[2] .. "/Mine/A.crp_preset", ROOTS), { "User Presets", "Mine" })
end

T["sidecar: a library level is not a folder"] = function()
  local root = "/x/Eventide/Physion Mk II"
  A.eq(sidecar.folder_of(root .. "/Factory Presets/01 - Signature/A.tidex", { root }), { "01 - Signature" })
  A.eq(sidecar.folder_of(root .. "/User Presets/A.tidex", { root }), { "User Presets" })
end

T["sidecar: folder segments, then vocabulary words from name and folder"] = function()
  A.eq(sidecar.auto_tags("Vox Booth", { "Post", "Small Rooms" }, {}, VOCAB, {}), { "Post", "Small Rooms", "small", "room", "vocal" })
end

T["sidecar: vendor fields first, numbering dropped"] = function()
  A.eq(sidecar.auto_tags("Lo-Fi Plate", { "03 Vocal" }, { "Reverb" }, VOCAB, {}), { "Reverb", "vocal", "plate", "lofi" })
end

T["sidecar: one spelling per tag across the library"] = function()
  local canon = {}
  sidecar.auto_tags("A", { "Halls" }, {}, VOCAB, canon)
  A.eq(sidecar.auto_tags("B", { "HALLS" }, {}, VOCAB, canon), { "Halls", "hall" })
end

T["sidecar: whole words only"] = function()
  A.eq(sidecar.auto_tags("Hallway Darkness Smallish", {}, {}, VOCAB, {}), {})
  A.eq(sidecar.auto_tags("SmallRoom Drums", {}, {}, VOCAB, {}), { "small", "room", "drum" })
  A.eq(sidecar.auto_tags("lo_fi Churches", {}, {}, VOCAB, {}), { "church", "lofi" })
end

T["sidecar: tags are cut to 40 characters, 32 at most"] = function()
  local many = {}
  for i = 1, 40 do many[i] = "t" .. i end
  A.eq(#sidecar.clean_tags(many), 32)
  A.eq(sidecar.clean_tags({ ("é"):rep(45), " a ", "A", "" }), { ("é"):rep(40), "a" })
end

T["sidecar: a re-import keeps the user's tags and favourite"] = function()
  local old = { tags = { "Post", "Mine", "room" }, autoTags = { "Post", "room" }, favorite = true, source = "factory:liquidsonics" }
  local new = sidecar.merge_record(old, { "Post", "Small Rooms" }, { "Post", "Small Rooms", "small" }, "factory:liquidsonics")
  A.eq(new.tags, { "Mine", "Post", "Small Rooms", "small" })
  A.eq(new.autoTags, { "Post", "Small Rooms", "small" })
  A.eq(new.favorite, true)
end

T["sidecar: a user tag equal to an auto tag stays the user's"] = function()
  local new = sidecar.merge_record({ tags = { "small" }, source = "factory:x" }, {}, { "small", "room" }, "factory:x")
  A.eq({ new.tags, new.autoTags }, { { "small", "room" }, { "room" } })
  A.eq(new.folder, nil)
end

T["sidecar: a record saved by the user is never touched"] = function()
  A.eq(sidecar.merge_record({ source = "captured" }, { "A" }, { "a" }, "factory:x"), nil)
end

T["sidecar: only listed names are written; other records kept"] = function()
  local existing = sidecar.decode('{"presets": {"Kept": {"tags": ["Bus"], "createdAt": 1729000000000}}, "x": 1}')
  local out, stats = sidecar.build({ "Booth" }, {
    { "Booth", CRP .. "Factory Presets/Rooms/Booth.crp_preset" },
    { "Not installed", CRP .. "Factory Presets/X.crp_preset" },
  }, ROOTS, existing, "factory:liquidsonics", nil, VOCAB)
  A.eq(stats.imported, 1)
  A.eq(sidecar.encode(out), table.concat({
    '{', ' "presets": {', '  "Booth": {', '   "autoTags": [', '    "Rooms",', '    "room"', '   ],',
    '   "folder": [', '    "Rooms"', '   ],', '   "source": "factory:liquidsonics",', '   "tags": [',
    '    "Rooms",', '    "room"', '   ]', '  },', '  "Kept": {', '   "createdAt": 1729000000000,',
    '   "tags": [', '    "Bus"', '   ]', '  }', ' }', '}', '' }, "\n"))
end

return T
