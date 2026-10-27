-- A read-only SQLite 3 reader for whole files in memory: the table b-trees, overflow
-- chains and the record format (sqlite.org/fileformat.html). Enough to read a plugin's
-- preset database without the sqlite library. Pure Lua 5.4. FORMATS.md, "SQLite".
local M = {}

M.MAGIC = "SQLite format 3\0"

function M.is_sqlite(bytes) return bytes:sub(1, 16) == M.MAGIC end

local function u16(b, i) return string.unpack(">I2", b, i) end
local function u32(b, i) return string.unpack(">I4", b, i) end

-- A big-endian varint at 1-based offset i: (value, next offset).
local function varint(b, i)
  local v = 0
  for k = 0, 7 do
    local c = b:byte(i + k)
    if not c then error("sqlite: truncated varint", 0) end
    v = (v << 7) | (c & 0x7F)
    if c < 0x80 then return v, i + k + 1 end
  end
  local c = b:byte(i + 8)
  if not c then error("sqlite: truncated varint", 0) end
  return (v << 8) | c, i + 9
end

-- The values of one record: header size, serial types, then the bodies.
local function record(p)
  local hsize, i = varint(p, 1)
  local types = {}
  while i <= hsize do
    types[#types + 1], i = varint(p, i)
  end
  local pos, out = hsize + 1, {}
  for n, t in ipairs(types) do
    local v
    if t == 0 then
      v = nil
    elseif t >= 1 and t <= 6 then
      local size = ({ 1, 2, 3, 4, 6, 8 })[t]
      if pos + size - 1 > #p then error("sqlite: record overruns its payload", 0) end
      v = string.unpack(">i" .. size, p, pos)
      pos = pos + size
    elseif t == 7 then
      if pos + 7 > #p then error("sqlite: record overruns its payload", 0) end
      v = string.unpack(">d", p, pos)
      pos = pos + 8
    elseif t == 8 or t == 9 then
      v = t - 8
    elseif t >= 12 then
      local size = (t - 12 - (t % 2)) // 2
      if pos + size - 1 > #p then error("sqlite: record overruns its payload", 0) end
      v = p:sub(pos, pos + size - 1)
      pos = pos + size
    else
      error("sqlite: reserved serial type " .. t, 0)
    end
    out[n] = v
  end
  out.n = #types
  return out
end

-- Open a database file's bytes. Raises when it is not a UTF-8 SQLite 3 file.
function M.open(bytes)
  if not M.is_sqlite(bytes) then error("not an SQLite 3 file", 0) end
  local size = u16(bytes, 17)
  if size == 1 then size = 65536 end
  if size < 512 or size & (size - 1) ~= 0 then error("sqlite: bad page size " .. size, 0) end
  local enc = u32(bytes, 57)
  if enc ~= 1 and enc ~= 0 then error("sqlite: text encoding " .. enc .. " (only UTF-8 is read)", 0) end
  local db = { bytes = bytes, page_size = size, usable = size - bytes:byte(21), pages = #bytes // size }
  return db
end

local function page(db, n)
  if n < 1 or n > db.pages then error("sqlite: page " .. n .. " out of range", 0) end
  return (n - 1) * db.page_size + 1
end

-- The payload of a table-leaf cell at absolute offset c.
local function payload(db, c)
  local b = db.bytes
  local size, i = varint(b, c)
  local _
  _, i = varint(b, i)
  local u = db.usable
  local x = u - 35
  if size <= x then return b:sub(i, i + size - 1) end
  local m = ((u - 12) * 32 // 255) - 23
  local k = m + ((size - m) % (u - 4))
  local here = k <= x and k or m
  local parts = { b:sub(i, i + here - 1) }
  local left = size - here
  local next_page = u32(b, i + here)
  local hops = 0
  while left > 0 do
    if next_page == 0 then error("sqlite: overflow chain ends early", 0) end
    hops = hops + 1
    if hops > db.pages then error("sqlite: overflow chain loops", 0) end
    local o = page(db, next_page)
    local take = math.min(left, u - 4)
    parts[#parts + 1] = b:sub(o + 4, o + 3 + take)
    left = left - take
    next_page = u32(b, o)
  end
  return table.concat(parts)
end

-- Every row of the table b-tree rooted at page `root`, in rowid order: {values...}.
function M.rows(db, root)
  local b, out, seen = db.bytes, {}, {}
  local function walk(n, depth)
    if depth > 64 or seen[n] then error("sqlite: b-tree loops", 0) end
    seen[n] = true
    local o = page(db, n)
    local h = n == 1 and o + 100 or o
    local kind = b:byte(h)
    local cells = u16(b, h + 3)
    if kind == 0x0D then
      for k = 0, cells - 1 do
        local c = o + u16(b, h + 8 + 2 * k)
        out[#out + 1] = record(payload(db, c))
      end
    elseif kind == 0x05 then
      for k = 0, cells - 1 do
        local c = o + u16(b, h + 12 + 2 * k)
        walk(u32(b, c), depth + 1)
      end
      walk(u32(b, h + 8), depth + 1)
    else
      error(("sqlite: page %d is not a table b-tree page (type %d)"):format(n, kind), 0)
    end
  end
  walk(root, 0)
  return out
end

-- The column names of a CREATE TABLE statement, in order.
function M.columns(sql)
  local body = sql:match("%((.*)%)")
  if not body then error("sqlite: no column list in " .. sql, 0) end
  local defs, depth, cur = {}, 0, {}
  for ch in body:gmatch(".") do
    if ch == "(" then depth = depth + 1 elseif ch == ")" then depth = depth - 1 end
    if ch == "," and depth == 0 then
      defs[#defs + 1] = table.concat(cur)
      cur = {}
    else
      cur[#cur + 1] = ch
    end
  end
  defs[#defs + 1] = table.concat(cur)
  local CONSTRAINT = { primary = true, foreign = true, unique = true, check = true, constraint = true }
  local cols = {}
  for _, d in ipairs(defs) do
    local name = d:match('^%s*"([^"]+)"') or d:match("^%s*`([^`]+)`") or d:match("^%s*%[([^%]]+)%]")
      or d:match("^%s*([%w_]+)")
    if name and not CONSTRAINT[name:lower()] then cols[#cols + 1] = name end
  end
  return cols
end

-- {name = {root, columns}} for every table in the schema.
function M.tables(db)
  local out = {}
  for _, r in ipairs(M.rows(db, 1)) do
    if r[1] == "table" and type(r[4]) == "number" and type(r[5]) == "string" then
      out[r[2]] = { root = r[4], columns = M.columns(r[5]) }
    end
  end
  return out
end

-- Every row of a named table as {column = value}; nil when there is no such table.
function M.select(db, name, tables)
  local t = (tables or M.tables(db))[name]
  if not t then return nil end
  local out = {}
  for _, r in ipairs(M.rows(db, t.root)) do
    local row = {}
    for i, c in ipairs(t.columns) do row[c] = r[i] end
    out[#out + 1] = row
  end
  return out
end

return M
