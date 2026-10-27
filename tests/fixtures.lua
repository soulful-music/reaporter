-- Synthetic preset files, built by hand for each format (no vendor file is used or copied),
-- and an in-memory file system for the scan.
local juce = require("reaporter.codec.juce")

local M = {}

-- A JUCE partial-state preset as LiquidSonics / Reverb Foundry write them: the tree, then
-- opaque trailing bytes.
function M.partial_state(root_type, params)
  local kids = {}
  for i, v in ipairs(params) do
    kids[#kids + 1] = {
      type = "PARAM",
      props = { { "id", { kind = juce.STRING, value = tostring(i - 1) } }, { "value", { kind = juce.DOUBLE, value = v } } },
      children = {},
    }
  end
  local tree = {
    type = root_type,
    props = { { "written_by_version__string", { kind = juce.STRING, value = "9.9.9" } } },
    children = { { type = "Test_StateVT", props = {}, children = kids } },
  }
  return juce.encode_tree(tree) .. "\1\2\3\4"
end

function M.tide(fields)
  local parts = {}
  for _, kv in ipairs(fields) do parts[#parts + 1] = ('  "%s": %s'):format(kv[1], kv[2]) end
  return "{\r\n" .. table.concat(parts, ",\r\n") .. "\r\n}\r\n"
end

function M.tidex()
  return [[<?xml version="1.0" encoding="UTF-8"?>

<STATE plugId="1413829460" plugVer="1.2.3">
  <PARAMETERS>
    <PARAM id="mix" value="0.25"/>
    <PARAM id="size" value="-3"/>
  </PARAMETERS>
  <DATAPARAMS>
    <PROPERTY name="abSl" value="0" persist="1" undoable="0" canAB="1"/>
    <PROPERTY name="label" value="Room &amp; Hall"/>
  </DATAPARAMS>
</STATE>
]]
end

function M.vpreset(tag, attrs)
  local parts = {}
  for _, kv in ipairs(attrs) do parts[#parts + 1] = ('%s="%s"'):format(kv[1], kv[2]) end
  return '<?xml version="1.0" encoding="UTF-8"?>\n\n<' .. tag .. " " .. table.concat(parts, "\n    ") .. "/>\n"
end

-- An LX480 v4 preset: 96 EngineA / EngineB values, the session fields, Info.
function M.lx480(opts)
  opts = opts or {}
  local lines = { '<?xml version="1.0" ?>', "<Preset>" }
  for _, sec in ipairs({ "EngineA", "EngineB" }) do
    lines[#lines + 1] = "    <" .. sec .. ">"
    for i = 1, opts.engine_count or 96 do
      lines[#lines + 1] = ('        <P%d Value="%s" />'):format(i, opts.value or (i / 4))
    end
    lines[#lines + 1] = "    </" .. sec .. ">"
  end
  lines[#lines + 1] = "    <Session>"
  for _, f in ipairs(opts.session or { "EngineMode", "GainInputLeft", "TempoSyncEnableTwinDelay" }) do
    lines[#lines + 1] = ('        <%s Value="3.5" />'):format(f)
  end
  lines[#lines + 1] = "    </Session>"
  lines[#lines + 1] = '    <Info><Version Value="2" /></Info>'
  lines[#lines + 1] = "</Preset>"
  return table.concat(lines, "\n") .. "\n"
end

function M.legacy_lx480()
  return '<?xml version="1.0" ?>\n<Preset>\n    <Preset>\n        <Spread Value="0.123" />\n    </Preset>\n</Preset>\n'
end

function M.toy(widget)
  return "WIDGET = " .. widget .. ";\rVERSION = 4;\rPRESET =ReaPorter synthetic archive;\r"
end

-- An in-memory file system: tree = {name = bytes | subtree}. fs.list / fs.is_dir / fs.read
-- take "/"-joined paths under `root`.
function M.memfs(root, tree)
  local function node(path)
    if path == root then return tree end
    if path:sub(1, #root + 1) ~= root .. "/" then return nil end
    local n = tree
    for seg in path:sub(#root + 2):gmatch("[^/]+") do
      if type(n) ~= "table" then return nil end
      n = n[seg]
    end
    return n
  end
  local fs = {}
  function fs.list(path)
    local n = node(path)
    if type(n) ~= "table" or n.__unreadable then return nil, "unreadable" end
    local dirs, files = {}, {}
    for k, v in pairs(n) do
      if k ~= "__unreadable" then
        if type(v) == "table" then dirs[#dirs + 1] = k else files[#files + 1] = k end
      end
    end
    return dirs, files
  end
  function fs.is_dir(path) return type(node(path)) == "table" end
  function fs.read(path)
    local n = node(path)
    if type(n) ~= "string" then return nil, "no such file" end
    return n
  end
  return fs
end

-- A DMGAudio-style preset or state: JSON text, zipped ("ZIP " + zlib) unless plain.
function M.dmg(text, plain)
  if plain then return text end
  return "ZIP " .. require("reaporter.codec.zlib").store(text .. "\0")
end

-- A synthetic fresh state in the DMGAudio layout.
M.DMG_FRESH = '{"presets": [{"parameters": "default", "name": "None"}], '
  .. '"ab": [{"parameters": "default"}, {"parameters": "default"}], '
  .. '"settings": {"currentAB": 0, "zoomLevel": 3}, "uiprefs": {"w": 100}, "v101": true}'

-- A FabFilter-style binary preset: magic, version, count, floats, then `tail` (a CuSV block).
function M.ffp(magic, version, floats, tail)
  local parts = { magic, string.pack("<I4<I4", version, #floats) }
  for _, v in ipairs(floats) do parts[#parts + 1] = string.pack("<f", v) end
  return table.concat(parts) .. (tail or "")
end

-- A CuSV block: {{key, value}, ...}.
function M.cusv(items)
  local parts = { "CuSV", string.pack("<I4<I4", 1, #items) }
  for _, kv in ipairs(items) do
    parts[#parts + 1] = string.pack("<I4", #kv[1]) .. kv[1] .. string.pack("<I4", #kv[2]) .. kv[2]
  end
  return table.concat(parts)
end

-- A FabFilter-style text preset: [Preset] head lines, then [Parameters] P1..Pn = values.
function M.ffp_text(head, values)
  local lines = { "[Preset]" }
  for _, kv in ipairs(head) do lines[#lines + 1] = kv[1] .. "=" .. kv[2] end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[Parameters]"
  for i, v in ipairs(values) do lines[#lines + 1] = ("Synthetic %d=%s"):format(i, v) end
  return table.concat(lines, "\n") .. "\n"
end

-- A minimal SQLite 3 file (sqlite.org/fileformat.html): tables = {{name, sql, rows}}, each
-- row a list of values (string = TEXT, integer, nil). Small pages, so long rows overflow and
-- a table with many rows gets an interior root page.
function M.sqlite(tables, page_size)
  page_size = page_size or 512
  local pages = {}
  local function varint(v)
    local out = {}
    repeat
      table.insert(out, 1, v & 0x7F)
      v = v >> 7
    until v == 0
    for i = 1, #out - 1 do out[i] = out[i] | 0x80 end
    return string.char(table.unpack(out))
  end
  local function record(values, n)
    local types, bodies = {}, {}
    for i = 1, n do
      local v = values[i]
      if v == nil then
        types[#types + 1] = varint(0)
      elseif math.type(v) == "integer" then
        types[#types + 1] = varint(6)
        bodies[#bodies + 1] = string.pack(">i8", v)
      else
        types[#types + 1] = varint(13 + 2 * #v)
        bodies[#bodies + 1] = v
      end
    end
    local head = table.concat(types)
    local hsize = #head + 1
    if hsize > 127 then hsize = #head + 2 end
    return varint(hsize) .. head .. table.concat(bodies)
  end
  local u = page_size
  -- a leaf cell, spilling into overflow pages as SQLite does
  local function leaf_cell(rowid, payload)
    local p = #payload
    local x, m = u - 35, ((u - 12) * 32 // 255) - 23
    local head = varint(p) .. varint(rowid)
    if p <= x then return head .. payload end
    local k = m + ((p - m) % (u - 4))
    local here = k <= x and k or m
    local rest = payload:sub(here + 1)
    local first = #pages + 1
    local n = 0
    while #rest > 0 do
      n = n + 1
      local take = rest:sub(1, u - 4)
      rest = rest:sub(u - 3)
      local next_page = #rest > 0 and first + n or 0
      pages[first + n - 1] = string.pack(">I4", next_page) .. take .. ("\0"):rep(u - 4 - #take)
    end
    return head .. payload:sub(1, here) .. string.pack(">I4", first)
  end
  local function page(kind, cells, right, header_at)
    header_at = header_at or 0
    local hsize = kind == 0x05 and 12 or 8
    local body, ptrs, top = {}, {}, u
    for i, c in ipairs(cells) do
      top = top - #c
      body[#body + 1] = c
      ptrs[i] = top
    end
    local head = string.char(kind) .. string.pack(">I2>I2>I2", 0, #cells, top) .. "\0"
    if kind == 0x05 then head = head .. string.pack(">I4", right) end
    for _, p in ipairs(ptrs) do head = head .. string.pack(">I2", p) end
    local content = {}
    for i = #body, 1, -1 do content[#content + 1] = body[i] end
    local gap = top - header_at - #head
    assert(gap >= 0, ("fixture page overflows (%d cells, gap %d, header at %d)"):format(#cells, gap, header_at))
    return head .. ("\0"):rep(gap) .. table.concat(content), hsize
  end
  pages[1] = false
  local master = {}
  for _, t in ipairs(tables) do
    local leaves, cur, size, rowid = {}, {}, 0, 0
    for _, row in ipairs(t.rows) do
      rowid = rowid + 1
      local cell = leaf_cell(rowid, record(row, #row))
      if size + #cell + 2 > u - 8 - 16 and #cur > 0 then
        leaves[#leaves + 1] = { cells = cur, last = rowid - 1 }
        cur, size = {}, 0
      end
      cur[#cur + 1] = cell
      size = size + #cell + 2
    end
    leaves[#leaves + 1] = { cells = cur, last = rowid }
    local nums = {}
    for i, l in ipairs(leaves) do
      pages[#pages + 1] = page(0x0D, l.cells)
      nums[i] = #pages
    end
    local root = nums[1]
    if #leaves > 1 then
      local cells = {}
      for i = 1, #leaves - 1 do cells[i] = string.pack(">I4", nums[i]) .. varint(leaves[i].last) end
      pages[#pages + 1] = page(0x05, cells, nums[#nums])
      root = #pages
    end
    master[#master + 1] = record({ "table", t.name, t.name, root, t.sql }, 5)
  end
  local cells = {}
  for i, r in ipairs(master) do cells[i] = varint(#r) .. varint(i) .. r end
  local p1 = page(0x0D, cells, nil, 100)
  local header = "SQLite format 3\0" .. string.pack(">I2", page_size) .. "\1\1\0\64\32\32"
    .. string.pack(">I4>I4", 1, #pages) .. ("\0"):rep(24) .. string.pack(">I4", 1) .. ("\0"):rep(40)
  assert(#header == 100)
  pages[1] = header .. p1
  for i, p in ipairs(pages) do assert(#p == page_size, "page " .. i .. " is " .. #p .. " bytes") end
  return table.concat(pages)
end

-- An LX480 Dual Engine preset's `data` JSON: every parameter id with a synthetic value.
-- opts: version, drop (an id to leave out), extra ({id, value}), value_of(id, i) -> string.
function M.lx480_data(ids, opts)
  opts = opts or {}
  local parts = {}
  for i, id in ipairs(ids) do
    if id ~= opts.drop then
      local v = opts.value_of and opts.value_of(id, i) or ("%d.5"):format(i)
      parts[#parts + 1] = ('    {\n      "id": "%s",\n      "value": "%s"\n    }'):format(id, v)
    end
  end
  if opts.extra then parts[#parts + 1] = ('    {"id": "%s", "value": "%s"}'):format(opts.extra[1], opts.extra[2]) end
  return ('{\n  "version": "%s",\n  "applicationSettings": {\n    "faderMappings": {\n'
    .. '      "engine1": {\n        "fader1option": "3",\n        "fader0category": "2"\n      },\n'
    .. '      "engine2": {}\n    }\n  },\n  "parameters": [\n%s\n  ],\n  "applicationTag": "%s"\n}')
    :format(opts.version or "4.1.0", table.concat(parts, ",\n"), opts.tag or "LX480")
end

-- A .lx480pack export: UTF-16 LE with a BOM and CRLF. presets = {{id, name, data, tags =
-- {tag id...}, packs = {pack id...}}}, tags = {{id, name}}, packs = {{id, name}}.
function M.lx480pack(o)
  local function q(s) return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n") .. '"' end
  local function ids(list)
    local t = {}
    for _, x in ipairs(list or {}) do t[#t + 1] = q(x) end
    return "[" .. table.concat(t, ", ") .. "]"
  end
  local tags, packs, presets = {}, {}, {}
  for _, t in ipairs(o.tags or {}) do
    tags[#tags + 1] = ('{"id": %s, "name": %s, "category": "User", "colour": "0", "readonly": 1}'):format(q(t[1]), q(t[2]))
  end
  for _, p in ipairs(o.packs or {}) do
    packs[#packs + 1] = ('{"pack": {"id": %s, "name": %s, "creator": "Synthetic", "notes": ""}, "image": {}}'):format(q(p[1]), q(p[2]))
  end
  for _, p in ipairs(o.presets or {}) do
    presets[#presets + 1] = ('{"preset": {"id": %s, "name": %s, "data": %s, "creator": "", "notes": "", "version": "4.1.0", "metadata": ""}, "associatedTagIds": %s, "associatedPackIds": %s}')
      :format(q(p.id), q(p.name), q(p.data), ids(p.tags), ids(p.packs))
  end
  local doc = ('{\n  "applicationId": 1,\n  "databaseVersion": 2,\n  "jsonModelVersion": 1,\n  "tags": [%s],\n  "packs": [%s],\n  "presets": [%s]\n}')
    :format(table.concat(tags, ", "), table.concat(packs, ", "), table.concat(presets, ",\n"))
  doc = doc:gsub("\n", "\r\n")
  local out = { "\255\254" }
  for _, c in utf8.codes(doc) do
    if c >= 0x10000 then
      c = c - 0x10000
      out[#out + 1] = string.pack("<I2<I2", 0xD800 + (c >> 10), 0xDC00 + (c & 0x3FF))
    else
      out[#out + 1] = string.pack("<I2", c)
    end
  end
  return table.concat(out)
end

return M
