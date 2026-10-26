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

return M
