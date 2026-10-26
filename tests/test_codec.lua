local A = require("assert")
local json = require("reaporter.codec.json")
local juce = require("reaporter.codec.juce")
local text = require("reaporter.core.text")
local xml = require("reaporter.codec.xml")

local T = {}

T["text: float literals"] = function()
  A.eq(text.parse_float(" 1.5 "), 1.5)
  A.eq(text.parse_float("1e5"), 100000.0)
  A.eq(text.parse_float("1_000.5"), 1000.5)
  A.eq(text.parse_float("-inf"), -math.huge)
  A.eq(math.type(text.parse_float("7")), "float")
  A.truthy(text.parse_float("nan") ~= text.parse_float("nan"))
  A.raises(function() text.parse_float("0x10") end, "float")
  A.raises(function() text.parse_float("") end, "float")
  A.raises(function() text.parse_float("1__0") end, "float")
end

T["text: integer literals"] = function()
  A.eq(text.parse_int(" -12 "), -12)
  A.eq(text.parse_int("007"), 7)
  A.raises(function() text.parse_int("1.0") end, "integer")
end

T["text: case folding and trimming"] = function()
  A.eq(text.lower("ÉCLAT Hall"), "éclat hall")
  A.eq(text.lower("ŁÓDŹ"), "łódź")
  A.eq(text.strip("\194\160 Warm \t"), "Warm")
  A.eq(text.prefix("ééé", 2), "éé")
end

T["text: splitext keeps leading dots in the stem"] = function()
  A.eq({ text.splitext("Hall.tide") }, { "Hall", ".tide" })
  A.eq({ text.splitext(".tide") }, { ".tide", "" })
  A.eq({ text.splitext("a.b.c") }, { "a.b", ".c" })
end

T["json: decode keeps integers, floats and empty objects apart"] = function()
  local v = json.decode('{"a": 1, "b": 1.0, "c": {}, "d": [], "e": "x\\u00e9\\n", "f": true}')
  A.eq(math.type(v.a), "integer")
  A.eq(math.type(v.b), "float")
  A.truthy(json.is_object(v.c))
  A.truthy(not json.is_object(v.d))
  A.eq(v.e, "xé\n")
  A.eq(v.f, true)
end

T["json: malformed input raises"] = function()
  A.raises(function() json.decode('{"a": 1,}') end, "JSON")
  A.raises(function() json.decode('{"a": 1} x') end, "extra data")
  A.raises(function() json.decode('{"a": "\1"}') end, "control")
  A.raises(function() json.decode("[01]") end, "JSON")
end

T["json: shortest float repr"] = function()
  local cases = {
    [0.1] = "0.1", [1.0] = "1.0", [1e-05] = "1e-05", [0.0001] = "0.0001", [1e16] = "1e+16",
    [123456789012345.0] = "123456789012345.0", [1.5e300] = "1.5e+300", [5e-324] = "5e-324",
    [-2.5] = "-2.5", [1 / 3] = "0.3333333333333333",
  }
  for v, want in pairs(cases) do A.eq(json.float_repr(v), want) end
end

T["json: encode sorts keys with a one-space indent"] = function()
  local v = json.object({ b = { 1, 2 }, a = json.object(), c = {}, d = "é\"" })
  A.eq(json.encode(v), '{\n "a": {},\n "b": [\n  1,\n  2\n ],\n "c": [],\n "d": "é\\""\n}')
end

T["xml: elements, attribute order, references and normalisation"] = function()
  local root = xml.parse('<?xml version="1.0"?>\n<!-- c --><R b="1" a="x &amp; &#65;&#x42;\n\ty"><K v="2"/><![CDATA[<no>]]>t<K/></R>\n')
  A.eq(root.tag, "R")
  A.eq(root.attrs, { { "b", "1" }, { "a", "x & AB  y" } })
  A.eq(#root.children, 2)
  A.eq(xml.get(xml.find(root, "K"), "v"), "2")
end

T["xml: malformed documents raise"] = function()
  A.raises(function() xml.parse("<a><b></a>") end, "mismatched")
  A.raises(function() xml.parse('<a x="1" x="2"/>') end, "duplicate")
  A.raises(function() xml.parse("<a/><b/>") end, "junk")
  A.raises(function() xml.parse("<a>&nope;</a>") end, "undefined entity")
  A.raises(function() xml.parse('<a x="<"/>') end, "attribute")
  A.raises(function() xml.parse(' <?xml version="1.0"?><a/>') end, "declaration")
  A.raises(function() xml.parse("<a>\255</a>") end, "UTF-8")
  A.raises(function() xml.parse('<a x="1"y="2"/>') end, "whitespace")
end

T["juce: compressed ints round-trip"] = function()
  for _, v in ipairs({ 0, 1, 255, 256, -1, -70000, 1 << 40 }) do
    local enc = juce.write_cint(v)
    local got, nxt = juce.read_cint(enc, 0)
    A.eq(got, v)
    A.eq(nxt, #enc)
  end
  A.eq(juce.write_cint(0), "\0")
  A.eq(juce.write_cint(-2), "\129\2")
end

T["juce: a ValueTree round-trips byte for byte"] = function()
  local tree = {
    type = "ROOT",
    props = {
      { "i", { kind = juce.INT, value = -5 } }, { "d", { kind = juce.DOUBLE, value = 0.5 } },
      { "s", { kind = juce.STRING, value = "é" } }, { "t", { kind = juce.TRUE } },
      { "q", { kind = juce.INT64, value = 1 << 40 } }, { "b", { kind = juce.BINARY, value = "\0\1" } },
      { "a", { kind = juce.ARRAY, value = { { kind = juce.INT, value = 1 }, { kind = juce.FALSE } } } },
    },
    children = { { type = "KID", props = {}, children = {} } },
  }
  local bytes = juce.encode_tree(tree)
  local back, n = juce.read_tree(bytes)
  A.eq(n, #bytes)
  A.eq(juce.encode_tree(back), bytes)
  A.eq(back.props[3][2].value, "é")
end

T["juce: truncated trees raise"] = function()
  local bytes = juce.encode_tree({ type = "R", props = { { "i", { kind = juce.INT, value = 1 } } }, children = {} })
  A.raises(function() juce.read_tree(bytes:sub(1, 6)) end, "ValueTree")
  A.raises(function() juce.read_tree("R") end, "NUL")
end

T["juce: the VST3 container layout"] = function()
  local chunk = juce.build_reaper_vst3({
    fx_id = "ABCD", fx_version = 0x010203, num_programs = 0, plugin_state = "STATE",
    private = juce.private_bypass_tree(false),
  })
  local comp_len, one = string.unpack("<I4<I4", chunk)
  A.eq(one, 1)
  A.eq(#chunk, 8 + comp_len + 8)
  local comp = chunk:sub(9, 8 + comp_len)
  A.eq(comp:sub(1, 4), "VstW")
  A.eq({ string.unpack(">I4>I4>I4", comp, 5) }, { 8, 1, 0, 17 })
  A.eq(comp:sub(17, 20), "CcnK")
  A.eq(comp:sub(25, 28), "FBCh")
  A.eq(comp:sub(33, 36), "ABCD")
  A.eq(string.unpack(">I4", comp, 37), 0x010203)
  local clen = string.unpack(">I4", comp, 173)
  local inner = comp:sub(177, 176 + clen)
  A.eq(inner:sub(1, 5), "STATE")
  A.eq(inner:sub(-15), "JUCEPrivateData")
  local plen = string.unpack("<i8", inner, #inner - 15 - 8 + 1)
  A.eq(inner:sub(6, 5 + plen), juce.private_bypass_tree(false))
  A.eq(chunk:sub(-8), ("\0"):rep(8))
end

T["juce: version codes"] = function()
  A.eq(juce.version_int("3.8.21"), 0x030815)
  A.eq(juce.version_int("0"), 0)
  A.eq(juce.version_int("1.2.3.4"), 0x010203)
  A.raises(function() juce.version_int("1.x") end, "integer")
end

return T
