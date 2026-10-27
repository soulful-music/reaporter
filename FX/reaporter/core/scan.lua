-- Finding a plugin's preset files and naming its entries. Pure Lua 5.4: file access goes
-- through an injected `fs` with fs.list(dir) -> (subdir names, file names) or nil, reason.
local text = require("reaporter.core.text")

local M = {}

local function has_ext(name, exts)
  local lname = name:lower()
  for _, e in ipairs(exts) do
    if text.ends_with(lname, e:lower()) then return true end
  end
  return false
end

-- Every preset file of a plugin: each root in order, walked top-down; a folder's files
-- in byte order, then its subfolders in byte order (none when plugin.flat). Returns
-- (paths, unreadable folders).
function M.files(plugin, fs)
  local out, unreadable = {}, {}
  local function walk(dir)
    local dirs, files = fs.list(dir)
    if not dirs then
      unreadable[#unreadable + 1] = dir
      return
    end
    table.sort(files)
    for _, f in ipairs(files) do
      local p = dir .. "/" .. f
      if has_ext(f, plugin.exts) and not (plugin.skip and plugin.skip(p)) then out[#out + 1] = p end
    end
    if plugin.flat then return end
    table.sort(dirs)
    for _, d in ipairs(dirs) do walk(dir .. "/" .. d) end
  end
  for _, root in ipairs(plugin.roots) do
    if fs.is_dir == nil or fs.is_dir(root) then walk(root) end
  end
  return out, unreadable
end

-- Entry names for preset paths: the file stem; a stem seen twice (trimmed, ignoring case, as
-- REAPER compares names) gets " (<folder>)", and a name still taken gets " 2", " 3", ...
-- An item may also be a pack member, {path, stem, parent, ...}: its own name and folder
-- name, its other fields kept on the entry. Returns {{name, path, ...}, ...}.
function M.named(items)
  local function key(s) return text.lower(text.strip_ascii(s)) end
  local function stem_of(it)
    if type(it) == "table" then return it.stem end
    return (text.splitext(text.basename(it)))
  end
  local stems = {}
  for _, it in ipairs(items) do
    local k = key(stem_of(it))
    stems[k] = (stems[k] or 0) + 1
  end
  local seen, out = {}, {}
  for _, it in ipairs(items) do
    local member = type(it) == "table"
    local p = member and it.path or it
    local stem = stem_of(it)
    local name = stem
    if stems[key(stem)] > 1 then
      name = ("%s (%s)"):format(text.strip_ascii(stem), member and it.parent or text.basename(text.dirname(p)))
    end
    local n, k = name, 2
    while seen[key(n)] do
      n, k = ("%s %d"):format(name, k), k + 1
    end
    seen[key(n)] = true
    local e = { n, p }
    if member then
      for f, v in pairs(it) do
        if f ~= "path" and f ~= "stem" and f ~= "parent" then e[f] = v end
      end
    end
    out[#out + 1] = e
  end
  return out
end

return M
