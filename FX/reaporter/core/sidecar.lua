-- The MixSurface folders-and-tags sidecar for converted presets. Pure Lua 5.4.
-- Format and merge rules: SIDECAR.md.
local json = require("reaporter.codec.json")
local text = require("reaporter.core.text")

local M = {}

M.MAX_TAG_CHARS = 40
M.MAX_TAGS = 32
-- A root's first level that only holds the library: not a folder of the vendor's browser.
M.LIBRARY_LEVELS = { ["presets"] = true, ["factory presets"] = true }

-- One tag per line, lowercase and singular. A word in a preset's name or folder matches
-- its tag, its plural (+s, +es) or an alias after ':' (comma-separated).
M.VOCABULARY = [[
# size
small: tiny
medium
large: big
huge

# space
room
hall
plate
chamber
church
spring
ambience
cathedral

# use
vocal: vox
drum
guitar
snare
piano

# character
dark
bright
long
short
lofi: lo-fi, lo fi
shimmer
modulated: modulation
]]

local function is_word_char(c)
  return c ~= "" and c:find("^[a-z0-9]$") ~= nil
end

local function is_sep(c)
  return c ~= "" and c:find("^[ \t\n\r\v\f_%-]$") ~= nil
end

-- A matcher for one vocabulary word: its parts (split at spaces and hyphens) joined by
-- any run of spaces, underscores or hyphens, an optional plural "s" / "es", whole words.
local function word_matcher(word)
  local parts = {}
  for p in word:gmatch("[^ %-]+") do parts[#parts + 1] = p end
  return function(s)
    local from = 1
    while true do
      local i = s:find(parts[1], from, true)
      if not i then return false end
      if not is_word_char(s:sub(i - 1, i - 1)) then
        local j = i + #parts[1]
        local ok = true
        for n = 2, #parts do
          while is_sep(s:sub(j, j)) do j = j + 1 end
          if s:sub(j, j + #parts[n] - 1) ~= parts[n] then
            ok = false
            break
          end
          j = j + #parts[n]
        end
        if ok then
          local ends = {}
          if s:sub(j, j + 1) == "es" then ends[#ends + 1] = j + 2 end
          if s:sub(j, j) == "s" then ends[#ends + 1] = j + 1 end
          ends[#ends + 1] = j
          for _, e in ipairs(ends) do
            if not is_word_char(s:sub(e, e)) then return true end
          end
        end
      end
      from = i + 1
    end
  end
end

-- {{tag, match(text) -> bool}, ...} from vocabulary text.
function M.load_vocab(src)
  local out = {}
  for line in ((src or M.VOCABULARY) .. "\n"):gmatch("(.-)\n") do
    line = text.strip(line:gsub("#.*$", ""))
    if line ~= "" then
      local tag, aliases = line:match("^([^:]*):?(.*)$")
      tag = text.strip(tag)
      local matchers = { word_matcher(tag) }
      for a in aliases:gmatch("[^,]+") do
        a = text.strip(a)
        if a ~= "" then matchers[#matchers + 1] = word_matcher(a) end
      end
      out[#out + 1] = { tag, function(s)
        for _, m in ipairs(matchers) do
          if m(s) then return true end
        end
        return false
      end }
    end
  end
  return out
end

-- Lowercase text with camelCase split: "SmallRoom" -> "small room".
local function words(s)
  return text.lower((s:gsub("([a-z])([A-Z])", "%1 %2")))
end

local function normalize(p)
  local abs = p:sub(1, 1) == "/"
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then parts[#parts] = nil end
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return (abs and "/" or "") .. table.concat(parts, "/"), parts
end

-- The folder segments of `path` under the first root that holds it, outermost first. A
-- file under a later root (the vendor's user folder) is filed under that root's name.
function M.folder_of(path, roots)
  local _, pparts = normalize((path:gsub("\\", "/")))
  for i, r in ipairs(roots) do
    local _, rparts = normalize((r:gsub("\\", "/")))
    local under = #pparts >= #rparts
    for k = 1, #rparts do
      if pparts[k] ~= rparts[k] then
        under = false
        break
      end
    end
    if under then
      local parts = {}
      for k = #rparts + 1, #pparts - 1 do parts[#parts + 1] = pparts[k] end
      if parts[1] and M.LIBRARY_LEVELS[text.lower(parts[1])] then table.remove(parts, 1) end
      if i > 1 then table.insert(parts, 1, rparts[#rparts]) end
      return parts
    end
  end
  return {}
end

-- Trimmed, empties and case-insensitive repeats dropped (first spelling wins), each cut
-- to MAX_TAG_CHARS code points, at most MAX_TAGS.
function M.clean_tags(tags)
  local out, seen = {}, {}
  for _, t in ipairs(tags) do
    t = text.prefix(text.strip(t), M.MAX_TAG_CHARS)
    local k = text.lower(t)
    if t ~= "" and not seen[k] then
      out[#out + 1] = t
      seen[k] = true
    end
    if #out == M.MAX_TAGS then break end
  end
  return out
end

local NUMBERING = "^%s*%d+%s*[%-%.%)]?%s+"

-- The tags for one preset, in order: the vendor's own fields, every folder segment (its
-- "01 - " numbering dropped), each vocabulary word in the name or folder. `canon` maps a
-- lowercase tag to the one spelling used across the plugin's library.
function M.auto_tags(name, folder, vendor_tags, vocab, canon)
  for _, v in ipairs(vocab) do
    if canon[v[1]] == nil then canon[v[1]] = v[1] end
  end
  local segments = {}
  for _, s in ipairs(folder) do segments[#segments + 1] = text.strip((s:gsub(NUMBERING, ""))) end
  local pieces = { words(name) }
  for _, s in ipairs(segments) do pieces[#pieces + 1] = words(s) end
  local hay = table.concat(pieces, " ")
  local raw = {}
  for _, t in ipairs(vendor_tags) do raw[#raw + 1] = t end
  for _, s in ipairs(segments) do raw[#raw + 1] = s end
  for _, v in ipairs(vocab) do
    if v[2](hay) then raw[#raw + 1] = v[1] end
  end
  local spelled = {}
  for _, t in ipairs(raw) do
    local st = text.strip(t)
    if st ~= "" then
      local k = text.lower(st)
      if canon[k] == nil then canon[k] = st end
      spelled[#spelled + 1] = canon[k]
    end
  end
  return M.clean_tags(spelled)
end

local function copy(t)
  local out = json.object()
  for k, v in pairs(t or {}) do out[k] = v end
  return out
end

local function lower_set(list)
  local s = {}
  for _, t in ipairs(list or {}) do s[text.lower(t)] = true end
  return s
end

-- The record after an import, or nil when the record is the user's (a source that is
-- not "factory:...").
function M.merge_record(existing, folder, auto, source)
  local record = copy(existing)
  local src = record.source
  if type(src) == "string" and src ~= "" and not text.starts_with(src, "factory:") then return nil end
  local old_auto = lower_set(record.autoTags)
  local user = {}
  for _, t in ipairs(record.tags or {}) do
    if not old_auto[text.lower(t)] then user[#user + 1] = t end
  end
  local user_lower = lower_set(user)
  local fresh = {}
  for _, t in ipairs(auto) do
    if not user_lower[text.lower(t)] then fresh[#fresh + 1] = t end
  end
  local all = {}
  for _, t in ipairs(user) do all[#all + 1] = t end
  for _, t in ipairs(fresh) do all[#all + 1] = t end
  record.tags = M.clean_tags(all)
  local in_tags = {}
  for _, t in ipairs(record.tags) do in_tags[t] = true end
  local auto_kept = {}
  for _, t in ipairs(fresh) do
    if in_tags[t] then auto_kept[#auto_kept + 1] = t end
  end
  record.autoTags = auto_kept
  record.folder = folder
  record.source = source
  for _, key in ipairs({ "tags", "autoTags", "folder" }) do
    if #record[key] == 0 then record[key] = nil end
  end
  return record
end

-- The sidecar for one preset file and what was done. ini_names: the names the REAPER
-- file lists; presets: {{name, path}, ...} as the converter names them; existing: the
-- sidecar now on disk (a decoded table, or nil); source_key: "factory:<key>";
-- vendor_tags(path) -> {tag, ...} when the vendor's files carry category fields. A pack
-- member's entry carries its own folder and tags.
function M.build(ini_names, presets, roots, existing, source_key, vendor_tags, vocab)
  vocab = vocab or M.load_vocab()
  local out = json.object({ presets = copy(existing and existing.presets) })
  local listed = {}
  for _, n in ipairs(ini_names) do listed[n] = true end
  local canon = {}
  local vocab_tags = {}
  for _, v in ipairs(vocab) do vocab_tags[v[1]] = true end
  local stats = { imported = 0, user = 0, folder = 0, tagged = 0, vocab = 0 }
  for _, pr in ipairs(presets) do
    local name, path = text.strip(pr[1]), pr[2]
    if listed[name] then
      local folder = pr.folder or M.folder_of(path, roots)
      local own = pr.tags or (vendor_tags and vendor_tags(path)) or {}
      local tags = M.auto_tags(name, folder, own, vocab, canon)
      local record = M.merge_record(out.presets[name], folder, tags, source_key)
      if record == nil then
        stats.user = stats.user + 1
      else
        out.presets[name] = record
        stats.imported = stats.imported + 1
        if #folder > 0 then stats.folder = stats.folder + 1 end
        if #tags > 0 then stats.tagged = stats.tagged + 1 end
        for _, t in ipairs(tags) do
          if vocab_tags[t] then
            stats.vocab = stats.vocab + 1
            break
          end
        end
      end
    end
  end
  return out, stats
end

-- Decode a sidecar file's bytes ({} for nil). Raises on malformed JSON.
function M.decode(bytes)
  if bytes == nil then return json.object() end
  local v = json.decode(bytes)
  if not json.is_object(v) then error("sidecar is not a JSON object", 0) end
  return v
end

-- A sidecar's bytes: sorted keys, one-space indent, a final newline.
function M.encode(sidecar)
  return json.encode(sidecar) .. "\n"
end

return M
