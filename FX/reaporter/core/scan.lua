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
-- in byte order, then its subfolders in byte order. Returns (paths, unreadable folders).
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
    table.sort(dirs)
    for _, d in ipairs(dirs) do walk(dir .. "/" .. d) end
  end
  for _, root in ipairs(plugin.roots) do
    if fs.is_dir == nil or fs.is_dir(root) then walk(root) end
  end
  return out, unreadable
end

-- Entry names for preset paths: the file stem; a stem seen twice (ignoring case) gets
-- " (<folder>)", and a name still taken gets " 2", " 3", ... Returns {{name, path}, ...}.
function M.named(paths)
  local stems = {}
  for _, p in ipairs(paths) do
    local stem = text.splitext(text.basename(p))
    local k = text.lower(stem)
    stems[k] = (stems[k] or 0) + 1
  end
  local seen, out = {}, {}
  for _, p in ipairs(paths) do
    local stem = text.splitext(text.basename(p))
    local name = stem
    if stems[text.lower(stem)] > 1 then
      name = ("%s (%s)"):format(stem, text.basename(text.dirname(p)))
    end
    local n, k = name, 2
    while seen[text.lower(n)] do
      n, k = ("%s %d"):format(name, k), k + 1
    end
    seen[text.lower(n)] = true
    out[#out + 1] = { n, p }
  end
  return out
end

return M
