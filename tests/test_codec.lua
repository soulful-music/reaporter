local A = require("assert")
local json = require("reaporter.codec.json")
local juce = require("reaporter.codec.juce")
local text = require("reaporter.core.text")
local xml = require("reaporter.codec.xml")
local zlib = require("reaporter.codec.zlib")

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

local function unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

T["zlib: inflate fixed and dynamic Huffman blocks"] = function()
  A.eq(zlib.inflate(unhex("78da4b4c4a4e44421100340c0617")), "abcabcabcabcabcX")
  local dyn = zlib.inflate(unhex("78da8555cb4e03310cfc95a86784b870e16fb61051d416aaed82842cff3b224ee2f124854b36f22be3f163f7795bd265cdd7bca5d7e57c5ed2eeb87b4a0ff78f7769cdcbe563ddf29aaedfefdb216f6fcf49e0befff5553093f4b59c3ef3d4d182dbe952b3c7f066e11174b076807ed3e0a14314c6252de7e5743934585584296a351078ab9aa19182da9e2adccc698b58cdfc259f36a4bef150c29852ebb7880c95f9563c4ca543073fbb9a02991d2b50a3eea13fcc99a975d01844cdd30fa534666f1b2ee6c2f5fea85962fdfd8e39724b17281e0698a9392229a6e526b2c08174ec6dce6ec29dc41851087577d8260ce51e5e0888b81d39658dfd6fa71b11b25a400d4c49207db6356e35f57832e79c39d7805782790dcc0c0b6ad64a3a9bfb3f3ced458d63e2808dcaea0f3337eb77d38ca7c5182a4cf0705a7a0acc9450cd7005f210f12046df726f41a529b9d1da42c3c14049d8460e86271b796881814c5f2bb77f25d819b09351aca1c4dc7a949f479ec930d35092e906623fdc0eb706bb7e8621d5017857e83ca7de0c3206fd6faf87acb0b05c415c96126bd8846182dc1fea8c0b5efa3aeaf821112e63e760e02b7e5a23608e04051798f4069e3b2023bc54d1c362c8540b2dae65cb4a0858d43fbda16850"))
  A.eq(#dyn, 2487)
  A.eq(dyn:sub(1, 12), "beta preset ")
end

T["zlib: stored blocks round-trip, also past one block"] = function()
  for _, s in ipairs({ "", "x", ("0123456789"):rep(7000) }) do
    A.eq(zlib.inflate(zlib.store(s)), s)
  end
  A.eq(zlib.store("a"), "\x78\x01\x01\x01\x00\xfe\xff" .. "a" .. "\x00\x62\x00\x62")
  A.eq(#zlib.store(("x"):rep(70000)), 2 + 2 * 5 + 70000 + 4)
end

-- A fixed-Huffman stream: the literal "a", then `matches` x (length 258, distance 1).
local function bomb(matches)
  local bits, nb = {}, 0
  local function put(v, n, msb_first)
    for i = 0, n - 1 do
      nb = nb + 1
      bits[nb] = msb_first and (v >> (n - 1 - i)) & 1 or (v >> i) & 1
    end
  end
  put(1, 1); put(1, 2) -- last block, fixed codes
  put(0x30 + 97, 8, true)
  for _ = 1, matches do put(0xC0 + 5, 8, true); put(0, 5, true) end
  put(0, 7, true)
  local bytes = {}
  for i = 1, nb, 8 do
    local b = 0
    for k = 0, 7 do b = b | ((bits[i + k] or 0) << k) end
    bytes[#bytes + 1] = string.char(b)
  end
  return "\x78\x01" .. table.concat(bytes) .. "\0\0\0\0"
end

T["zlib: inflate stops at an output limit"] = function()
  local z = bomb(50) -- 12901 bytes from about 90
  A.truthy(#z < 120)
  A.raises(function() zlib.inflate(z, 1000) end, "output larger than 1000")
  A.raises(function() zlib.inflate(zlib.store(("x"):rep(500)), 100) end, "output larger than 100")
  A.raises(function() zlib.inflate(("\x78\x01\x01\x01\x00\xfe\xff" .. "a" .. "\0\0\0\0"), 0) end, "output larger")
  A.raises(function() zlib.inflate(z) end, "data check") -- under the default cap it inflates, then fails the checksum
end

T["zlib: bad streams raise"] = function()
  A.raises(function() zlib.inflate("\x78\x02") end, "header")
  local z = zlib.store("hello")
  A.raises(function() zlib.inflate(z:sub(1, -2) .. "\0") end, "data check")
  A.raises(function() zlib.inflate(z:sub(1, 6)) end, "end of data")
  A.eq(zlib.inflate(z .. "trailing"), "hello")
end

T["json: objects keep their key order; set and remove as a Python dict"] = function()
  local o = json.decode('{"b": 1, "a": 2, "b": 3}')
  A.eq(json.keys(o), { "b", "a" })
  A.eq(o.b, 3)
  json.set(o, "c", 4)
  json.set(o, "b", 5)
  json.remove(o, "a")
  json.set(o, "a", 6)
  A.eq(json.keys(o), { "b", "c", "a" })
end

T["json: integers past 64 bits are written back as they were"] = function()
  local text = '[9223372036854775807, 9223372036854775808, -9223372036854775809, 123456789012345678901234567890, 1.5e30]'
  local v = json.decode(text)
  A.eq(math.type(v[1]), "integer")
  A.truthy(json.is_bigint(v[2]) and json.is_bigint(v[4]))
  A.eq(tostring(v[3]), "-9223372036854775809")
  A.eq(json.encode_python(v, ""):gsub("%s+", ""), "[9223372036854775807,9223372036854775808,-9223372036854775809,123456789012345678901234567890,1.5e+30]")
  A.truthy(json.encode(v):find("123456789012345678901234567890,", 1, true))
end

T["json: a lone surrogate escape from a file is written back as an escape"] = function()
  local v = json.decode('{"s": "a\\ud800b\\udc00", "t": "\\ud83d\\ude00"}')
  A.eq(json.encode_python(v, ""), '{\n"s": "a\\ud800b\\udc00",\n"t": "\\ud83d\\ude00"\n}')
end

T["json: encode_python writes json.dumps(indent=...)"] = function()
  local o = json.decode('{"z": [], "y": {}, "s": "\\u00e9\\u007f\\u0001\\"\\\\/\\n\\ud83d\\ude00", '
    .. '"n": [1, 2.5, 1e-07, 1e16, -0.0, 0.1, null, true], "o": {"k": [{}]}}')
  A.eq(json.encode_python(o, "\t"), table.concat({
    "{",
    '\t"z": [],',
    '\t"y": {},',
    '\t"s": "\\u00e9\\u007f\\u0001\\"\\\\/\\n\\ud83d\\ude00",',
    '\t"n": [', "\t\t1,", "\t\t2.5,", "\t\t1e-07,", "\t\t1e+16,", "\t\t-0.0,", "\t\t0.1,", "\t\tnull,", "\t\ttrue", "\t],",
    '\t"o": {', '\t\t"k": [', "\t\t\t{}", "\t\t]", "\t}",
    "}",
  }, "\n"))
end

return T
