local A = require("assert")
local ini = require("reaporter.core.ini")

local T = {}

T["entry bytes follow REAPER's layout"] = function()
  local data = ini.entry_data(0x11223344, "CHUNK", "Hall", 4, 2)
  local uid, magic, nin = string.unpack("<I4<I4<i4", data)
  A.eq({ uid, magic, nin }, { 0x11223344, 0xFEED5EEE, 4 })
  A.eq({ string.unpack("<I8<I8<I8<I8", data, 13) }, { 1, 2, 4, 8, 45 })
  A.eq(string.unpack("<i4", data, 45), 2)
  A.eq({ string.unpack("<I4<I4<I4", data, 65) }, { 5, 1, 0x0010FFFF, 77 })
  A.eq(data:sub(77), "CHUNK\0Hall\0" .. string.pack("<I4", 0x10))
  A.eq({ ini.parse_entry(data) }, { 0x11223344, 4, 2, "CHUNK", "Hall" })
end

T["a new file splits Data at 16 KiB with checksums"] = function()
  local big = ("\1"):rep(16 * 1024 + 3)
  local bytes = ini.ini_bytes({ { "A", "\255\1" }, { "B", big } })
  A.truthy(bytes:find("^%[General%]\r\nNbPresets=2\r\n\r\n%[Preset0%]\r\nData=FF0100\r\nLen=2\r\nName=A\r\n\r\n"))
  A.truthy(bytes:find("\r\nData_1=01010103\r\nLen=16387\r\nName=B\r\n\r\n$"))
  local back = ini.read_ini(bytes)
  A.eq(back, { { "A", "\255\1" }, { "B", big } })
end

T["file names follow REAPER's rule"] = function()
  A.eq(ini.preset_file_name("VST3: Tai Chi (Reverb Foundry)"), "vst3-Tai Chi.ini")
  A.eq(ini.preset_file_name("VST3i: Kit (Vendor)"), "vst3-Kit.ini")
  A.eq(ini.preset_file_name("VST3: Blackhole Immersive (Eventide) (16ch)"), "vst3-Blackhole Immersive.ini")
end

T["listed names: as REAPER's index reads them"] = function()
  local src = "\239\187\191junk\n[general]\nnbpresets = 4\n[preset0]\nData=00\n Name = Warm \n"
    .. "[Preset1]\nLen=1\n[Preset2]\nName=Bright\n[Preset2]\nName=Shadow\n"
    .. "[Preset3]\nName=Last\nName=Ignored\n[Preset4]\nName=Hidden"
  A.eq(ini.listed_names(src), { "Warm", "Bright", "Last" })
  A.eq(ini.listed_names("[Preset0]\nName=A\n"), {})
end

-- A file the user has edited by hand: LF lines, a BOM, a comment, odd spacing, an
-- unknown key, no blank line at the end.
local EDITED = "\239\187\191; my presets\n[General]\nNbPresets = 2 \nOther=1\n\n[Preset0]\nData=0000\nLen=1\nName=Warm Room\n"
  .. "[Preset1]\nData=0101\nLen=1\nName = Big Hall \nExtra=keep"

T["merge keeps every existing byte but the count"] = function()
  local out, added, skipped = ini.merge(EDITED, { { "big hall", "X" }, { "New One", "\1" }, { "new one", "\2" } })
  A.eq(added, { "New One" })
  A.eq(skipped, { "big hall", "new one" })
  local head = EDITED:gsub("NbPresets = 2 ", "NbPresets = 3 ")
  A.eq(out:sub(1, #head), head)
  A.eq(out:sub(#head + 1), "\n\n[Preset2]\nData=0101\nLen=1\nName=New One\n\n")
  A.eq(ini.listed_names(out), { "Warm Room", "Big Hall", "New One" })
end

T["merge with nothing new returns the file untouched"] = function()
  local out, added, skipped = ini.merge(EDITED, { { "WARM ROOM", "X" } })
  A.eq(out, EDITED)
  A.eq(added, {})
  A.eq(skipped, { "WARM ROOM" })
end

T["merge keeps CRLF files CRLF"] = function()
  local base = ini.ini_bytes({ { "A", "\1" } })
  local out = ini.merge(base, { { "B", "\2" } })
  A.eq(out, ini.ini_bytes({ { "A", "\1" }, { "B", "\2" } }))
end

T["merge refuses a file it must not touch"] = function()
  A.raises(function() ini.merge("[Preset0]\nName=A\n", { { "B", "x" } }) end, "NbPresets")
  A.raises(function()
    ini.merge("[General]\nNbPresets=1\n[Preset0]\nName=A\n[Preset3]\nName=Z\n", { { "B", "x" } })
  end, "past NbPresets")
end

-- After a merge, REAPER's index lists the old names, then the new ones: the merge and
-- listed_names read the file the same way.
local function agrees(file, new_names)
  local entries = {}
  for _, n in ipairs(new_names) do entries[#entries + 1] = { n, "\1" } end
  local out = ini.merge(file, entries)
  local want = ini.listed_names(file)
  for _, n in ipairs(new_names) do want[#want + 1] = n end
  A.eq(ini.listed_names(out), want)
end

T["merge and listed names: sections and keys ignore case alike"] = function()
  local file = "[general]\nnbpresets=1\n[preset0]\nNAME=Warm\n"
  A.eq(ini.inspect(file).taken, { warm = true })
  agrees(file, { "Cold" })
  A.eq(select(3, ini.merge(file, { { "WARM", "\1" } })), { "WARM" })
end

T["merge and listed names: the first Name= of an entry counts for both"] = function()
  local file = "[General]\nNbPresets=1\n[Preset0]\nName=First\nName=Second\n"
  A.eq(ini.listed_names(file), { "First" })
  A.eq(ini.inspect(file).taken, { first = true })
  agrees(file, { "Second" })
end

T["merge refuses a file where the readings could disagree"] = function()
  A.raises(function() ini.merge("[General]\nNbPresets=1\n[Preset0]\nName=A\n[Preset0]\nName=B\n", { { "C", "x" } }) end,
    "repeated sections: [Preset0]")
  A.raises(function() ini.merge("[General]\nNbPresets=1\n[Preset0]\nName=A\n[general]\nNbPresets=5\n", { { "C", "x" } }) end,
    "repeated sections: [General]")
  A.raises(function() ini.merge("[General]\nNbPresets=1\n[Preset0]\nName=A\n[preset1]\nName=Z\n", { { "C", "x" } }) end,
    "entries past NbPresets=1: 1")
end

T["merge refuses an NbPresets that is not a whole number"] = function()
  for _, v in ipairs({ "+1", "1_0", "1x", "", "-1", "1.0" }) do
    A.raises(function() ini.merge("[General]\nNbPresets=" .. v .. "\n[Preset0]\nName=A\n", { { "C", "x" } }) end,
      "NbPresets")
  end
  agrees("[General]\nNbPresets= 1 \t\n[Preset0]\nName=A\n", { "C" })
end

T["merge refuses CR-only line ends instead of mixing them"] = function()
  local cr = "[General]\rNbPresets=1\r[Preset0]\rName=A\r"
  A.eq(ini.listed_names(cr), {})
  A.raises(function() ini.merge(cr, { { "C", "x" } }) end, "CR alone")
  A.raises(function() ini.merge("[General]\r\nNbPresets=1\r\n[Preset0]\rName=A\r\n", { { "C", "x" } }) end, "CR alone")
  local lf = ini.merge("[General]\nNbPresets=1\n[Preset0]\nName=A\n", { { "C", "x" } })
  A.truthy(not lf:find("\r", 1, true), "an LF file stays LF")
end

return T
