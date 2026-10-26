-- A small, strict XML reader for preset files. Pure Lua 5.4.
--
-- Returns the root element as {tag = name, attrs = {{name, value}, ...} (document order),
-- children = {element, ...}}. Text, comments, processing instructions and the doctype are
-- read and dropped. Well-formedness errors raise: a mismatched or unclosed tag, a
-- duplicate attribute, an undefined entity, '<' in an attribute value, a declaration not
-- at the start, content after the root element, invalid UTF-8 or a control character.
-- Attribute values are normalised as XML requires (each literal tab / newline becomes a
-- space; a character reference keeps its character).
local M = {}

local function fail(msg, pos)
  error(("XML: %s at byte %d"):format(msg, pos), 0)
end

local NAME_START = "[A-Za-z_:\128-\255]"
local NAME_CHARS = "[A-Za-z0-9_:%.%-\128-\255]*"
local NAME = "^" .. NAME_START .. NAME_CHARS

local PREDEFINED = { lt = "<", gt = ">", amp = "&", apos = "'", quot = '"' }

local function valid_char(cp)
  return cp == 0x9 or cp == 0xA or cp == 0xD or (cp >= 0x20 and cp <= 0xD7FF)
    or (cp >= 0xE000 and cp <= 0xFFFD) or (cp >= 0x10000 and cp <= 0x10FFFF)
end

-- Decode the references in `raw` (attribute value or text) starting at document byte `at`.
local function decode_refs(raw, at, is_attr)
  if is_attr then raw = raw:gsub("[\t\n]", " ") end
  if not raw:find("&", 1, true) then return raw end
  local out, i = {}, 1
  while true do
    local amp = raw:find("&", i, true)
    if not amp then
      out[#out + 1] = raw:sub(i)
      break
    end
    out[#out + 1] = raw:sub(i, amp - 1)
    local semi = raw:find(";", amp, true)
    if not semi then fail("unterminated reference", at + amp - 1) end
    local ref = raw:sub(amp + 1, semi - 1)
    local cp
    if ref:match("^#x%x+$") then
      cp = tonumber(ref:sub(3), 16)
    elseif ref:match("^#%d+$") then
      cp = tonumber(ref:sub(2))
    end
    if cp then
      if not valid_char(cp) then fail("reference to invalid character", at + amp - 1) end
      out[#out + 1] = utf8.char(cp)
    elseif PREDEFINED[ref] then
      out[#out + 1] = PREDEFINED[ref]
    else
      fail("undefined entity &" .. ref .. ";", at + amp - 1)
    end
    i = semi + 1
  end
  return table.concat(out)
end

local function skip_ws(s, i)
  return s:match("^[ \t\n]*()", i)
end

-- Comment, PI or doctype at i ("<!--", "<?", "<!DOCTYPE"); returns the index after it.
local function skip_misc(s, i, allow_doctype)
  if s:sub(i, i + 3) == "<!--" then
    local e = s:find("-->", i + 4, true)
    if not e then fail("unterminated comment", i) end
    if s:sub(i + 4, e - 1):find("--", 1, true) then fail("'--' inside a comment", i) end
    return e + 3
  end
  if s:sub(i, i + 1) == "<?" then
    local target = s:match("^<%?(" .. NAME_START .. NAME_CHARS .. ")", i)
    if not target then fail("invalid processing instruction", i) end
    if target:lower() == "xml" then fail("XML declaration not at the start", i) end
    local e = s:find("?>", i + 2, true)
    if not e then fail("unterminated processing instruction", i) end
    return e + 2
  end
  if allow_doctype and s:sub(i, i + 8) == "<!DOCTYPE" then
    local j, depth, q = i + 9, 0, nil
    while j <= #s do
      local c = s:sub(j, j)
      if q then
        if c == q then q = nil end
      elseif c == '"' or c == "'" then
        q = c
      elseif c == "[" then
        depth = depth + 1
      elseif c == "]" then
        depth = depth - 1
      elseif c == ">" and depth == 0 then
        return j + 1
      end
      j = j + 1
    end
    fail("unterminated doctype", i)
  end
  return nil
end

local function parse_element(s, i)
  local tag_end = s:match(NAME .. "()", i + 1)
  if not tag_end then fail("invalid element name", i) end
  local el = { tag = s:sub(i + 1, tag_end - 1), attrs = {}, children = {} }
  local seen = {}
  local j = tag_end
  while true do
    local after_ws = skip_ws(s, j)
    local c = s:sub(after_ws, after_ws)
    if c == ">" then
      j = after_ws + 1
      break
    elseif c == "/" then
      if s:sub(after_ws + 1, after_ws + 1) ~= ">" then fail("expected '>'", after_ws) end
      return el, after_ws + 2
    end
    if after_ws == j then fail("expected whitespace before an attribute", j) end
    local name_end = s:match(NAME .. "()", after_ws)
    if not name_end then fail("invalid attribute", after_ws) end
    local name = s:sub(after_ws, name_end - 1)
    local k = skip_ws(s, name_end)
    if s:sub(k, k) ~= "=" then fail("expected '='", k) end
    k = skip_ws(s, k + 1)
    local q = s:sub(k, k)
    if q ~= '"' and q ~= "'" then fail("expected a quoted value", k) end
    local close = s:find(q, k + 1, true)
    if not close then fail("unterminated attribute value", k) end
    local raw = s:sub(k + 1, close - 1)
    if raw:find("<", 1, true) then fail("'<' in an attribute value", k) end
    if seen[name] then fail("duplicate attribute " .. name, after_ws) end
    seen[name] = true
    el.attrs[#el.attrs + 1] = { name, decode_refs(raw, k + 1, true) }
    j = close + 1
  end
  -- content
  while true do
    local lt = s:find("<", j, true)
    if not lt then fail("unclosed element <" .. el.tag .. ">", i) end
    local text = s:sub(j, lt - 1)
    if text:find("]]>", 1, true) then fail("']]>' in content", j) end
    decode_refs(text, j, false)
    if s:sub(lt, lt + 1) == "</" then
      local name_end = s:match(NAME .. "()", lt + 2)
      if not name_end or s:sub(lt + 2, name_end - 1) ~= el.tag then
        fail("mismatched tag, expected </" .. el.tag .. ">", lt)
      end
      local k = skip_ws(s, name_end)
      if s:sub(k, k) ~= ">" then fail("expected '>'", k) end
      return el, k + 1
    elseif s:sub(lt, lt + 8) == "<![CDATA[" then
      local e = s:find("]]>", lt + 9, true)
      if not e then fail("unterminated CDATA section", lt) end
      j = e + 3
    else
      local after = skip_misc(s, lt, false)
      if after then
        j = after
      else
        local child
        child, j = parse_element(s, lt)
        el.children[#el.children + 1] = child
      end
    end
  end
end

-- Parse a document's bytes; returns the root element.
function M.parse(s)
  if s:sub(1, 3) == "\239\187\191" then s = s:sub(4) end
  if not utf8.len(s) then error("XML: not well-formed (invalid UTF-8)", 0) end
  if s:find("[\0-\8\11\12\14-\31]") then
    error("XML: not well-formed (invalid character)", 0)
  end
  s = s:gsub("\r\n?", "\n")
  local i = 1
  if s:sub(1, 5) == "<?xml" and s:find("^[ \t\n?]", 6) then
    local e = s:find("?>", 6, true)
    if not e then fail("unterminated XML declaration", 1) end
    local decl = s:sub(6, e - 1)
    local enc = decl:match("encoding%s*=%s*[\"']([^\"']*)[\"']")
    if enc and enc:lower() ~= "utf-8" and enc:lower() ~= "us-ascii" then
      fail("unsupported encoding " .. enc, 1)
    end
    i = e + 2
  end
  local root
  local doctype_ok = true
  while true do
    i = skip_ws(s, i)
    if i > #s then break end
    if s:sub(i, i) ~= "<" then fail("not well-formed (text outside the root element)", i) end
    local after = skip_misc(s, i, doctype_ok and root == nil)
    if after then
      if s:sub(i, i + 8) == "<!DOCTYPE" then doctype_ok = false end
      i = after
    else
      if root then fail("junk after document element", i) end
      root, i = parse_element(s, i)
    end
  end
  if not root then fail("no element found", #s + 1) end
  return root
end

-- The first direct child element named `tag`, or nil.
function M.find(el, tag)
  for _, c in ipairs(el.children) do
    if c.tag == tag then return c end
  end
  return nil
end

-- The value of attribute `name`, or nil.
function M.get(el, name)
  for _, a in ipairs(el.attrs) do
    if a[1] == name then return a[2] end
  end
  return nil
end

return M
