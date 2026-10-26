-- zlib streams (RFC 1950 / 1951) in pure Lua 5.4: inflate for reading, and stored
-- (uncompressed) blocks for writing, which every inflater accepts and which encode the same
-- bytes on every platform.
local M = {}

function M.adler32(s)
  local a, b = 1, 0
  for i = 1, #s, 4096 do
    local stop = math.min(i + 4095, #s)
    for k = i, stop do
      a = a + s:byte(k)
      b = b + a
    end
    a, b = a % 65521, b % 65521
  end
  return (b << 16) | a
end

-- A zlib stream of `data` in stored blocks (at most 65535 bytes each).
function M.store(data)
  local out = { "\x78\x01" }
  local n = #data
  local i = 1
  repeat
    local len = math.min(65535, n - i + 1)
    local final = i + len > n and 1 or 0
    out[#out + 1] = string.pack("<B<I2<I2", final, len, len ~ 0xFFFF)
    out[#out + 1] = data:sub(i, i + len - 1)
    i = i + len
  until i > n
  out[#out + 1] = string.pack(">I4", M.adler32(data))
  return table.concat(out)
end

local function fail(msg) error("zlib: " .. msg, 0) end

-- Bit reader over a byte string, least significant bit first.
local function reader(s, pos)
  local r = { s = s, pos = pos, bitbuf = 0, bitcnt = 0 }
  function r.bits(n)
    while r.bitcnt < n do
      local b = s:byte(r.pos)
      if not b then fail("unexpected end of data") end
      r.pos = r.pos + 1
      r.bitbuf = r.bitbuf | (b << r.bitcnt)
      r.bitcnt = r.bitcnt + 8
    end
    local v = r.bitbuf & ((1 << n) - 1)
    r.bitbuf = r.bitbuf >> n
    r.bitcnt = r.bitcnt - n
    return v
  end
  function r.align()
    r.bitbuf, r.bitcnt = 0, 0
  end
  return r
end

-- Canonical Huffman table from code lengths: {counts, symbols} (puff.c's layout).
local function huffman(lengths, n)
  local counts, offs, symbols = {}, {}, {}
  for l = 0, 15 do counts[l] = 0 end
  for s = 0, n - 1 do counts[lengths[s]] = counts[lengths[s]] + 1 end
  local left = 1
  for l = 1, 15 do
    left = (left << 1) - counts[l]
    if left < 0 then fail("over-subscribed code") end
  end
  offs[1] = 0
  for l = 1, 14 do offs[l + 1] = offs[l] + counts[l] end
  for s = 0, n - 1 do
    local l = lengths[s]
    if l ~= 0 then
      symbols[offs[l]] = s
      offs[l] = offs[l] + 1
    end
  end
  return { counts = counts, symbols = symbols }
end

local function decode(r, h)
  local code, first, index = 0, 0, 0
  for l = 1, 15 do
    code = code | r.bits(1)
    local count = h.counts[l]
    if code - count < first then return h.symbols[index + (code - first)] end
    index = index + count
    first = (first + count) << 1
    code = code << 1
  end
  fail("invalid Huffman code")
end

local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
  4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local FIXED_L, FIXED_D
local function fixed()
  if not FIXED_L then
    local l = {}
    for s = 0, 143 do l[s] = 8 end
    for s = 144, 255 do l[s] = 9 end
    for s = 256, 279 do l[s] = 7 end
    for s = 280, 287 do l[s] = 8 end
    FIXED_L = huffman(l, 288)
    local d = {}
    for s = 0, 29 do d[s] = 5 end
    FIXED_D = huffman(d, 30)
  end
  return FIXED_L, FIXED_D
end

local function dynamic(r)
  local nlen, ndist, ncode = r.bits(5) + 257, r.bits(5) + 1, r.bits(4) + 4
  if nlen > 286 or ndist > 30 then fail("bad counts") end
  local lengths = {}
  for i = 0, 18 do lengths[i] = 0 end
  for i = 1, ncode do lengths[ORDER[i]] = r.bits(3) end
  local lencode = huffman(lengths, 19)
  local all, i = {}, 0
  while i < nlen + ndist do
    local sym = decode(r, lencode)
    if sym < 16 then
      all[i] = sym
      i = i + 1
    else
      local len, rep = 0, 0
      if sym == 16 then
        if i == 0 then fail("repeat with no first length") end
        len, rep = all[i - 1], 3 + r.bits(2)
      elseif sym == 17 then
        rep = 3 + r.bits(3)
      else
        rep = 11 + r.bits(7)
      end
      if i + rep > nlen + ndist then fail("too many lengths") end
      for _ = 1, rep do
        all[i] = len
        i = i + 1
      end
    end
  end
  local ll, dl = {}, {}
  for s = 0, nlen - 1 do ll[s] = all[s] end
  for s = nlen, 287 do ll[s] = 0 end
  for s = 0, ndist - 1 do dl[s] = all[nlen + s] end
  for s = ndist, 29 do dl[s] = 0 end
  return huffman(ll, 288), huffman(dl, 30)
end

-- Decompress a zlib stream; bytes after its end are ignored, as zlib's one-shot
-- uncompress does. Raises on a bad header, corrupt data, a wrong checksum, or output past
-- `limit` bytes (default M.MAX_OUTPUT: a few KB can inflate to gigabytes).
M.MAX_OUTPUT = 64 * 1024 * 1024

function M.inflate(s, limit)
  limit = limit or M.MAX_OUTPUT
  if #s < 2 then fail("truncated header") end
  local cmf, flg = s:byte(1, 2)
  if cmf & 0x0F ~= 8 or (cmf * 256 + flg) % 31 ~= 0 or cmf >> 4 > 7 then fail("incorrect header check") end
  if flg & 0x20 ~= 0 then fail("preset dictionary not supported") end
  local r = reader(s, 3)
  local out, n = {}, 0 -- out[1..n]: one byte (number) each
  repeat
    local last = r.bits(1)
    local kind = r.bits(2)
    if kind == 0 then
      r.align()
      if r.pos + 3 > #s then fail("unexpected end of data") end
      local len, nlen = string.unpack("<I2<I2", s, r.pos)
      if len ~= nlen ~ 0xFFFF then fail("stored block length mismatch") end
      if r.pos + 4 + len - 1 > #s then fail("unexpected end of data") end
      if n + len > limit then fail("output larger than " .. limit .. " bytes") end
      for k = r.pos + 4, r.pos + 3 + len do
        n = n + 1
        out[n] = s:byte(k)
      end
      r.pos = r.pos + 4 + len
    elseif kind == 1 or kind == 2 then
      local lc, dc
      if kind == 1 then lc, dc = fixed() else lc, dc = dynamic(r) end
      while true do
        local sym = decode(r, lc)
        if sym < 256 then
          if n >= limit then fail("output larger than " .. limit .. " bytes") end
          n = n + 1
          out[n] = sym
        elseif sym == 256 then
          break
        else
          sym = sym - 256
          if sym > 29 then fail("bad length symbol") end
          local len = LBASE[sym] + r.bits(LEXT[sym])
          local ds = decode(r, dc)
          if ds > 29 then fail("bad distance symbol") end
          local dist = DBASE[ds + 1] + r.bits(DEXT[ds + 1])
          if dist > n then fail("distance too far back") end
          if n + len > limit then fail("output larger than " .. limit .. " bytes") end
          for _ = 1, len do
            n = n + 1
            out[n] = out[n - dist]
          end
        end
      end
    else
      fail("invalid block type")
    end
  until last == 1
  local parts = {}
  for i = 1, n, 4096 do parts[#parts + 1] = string.char(table.unpack(out, i, math.min(i + 4095, n))) end
  local data = table.concat(parts)
  r.align()
  if r.pos + 3 > #s then fail("missing checksum") end
  if string.unpack(">I4", s, r.pos) ~= M.adler32(data) then fail("incorrect data check") end
  return data
end

return M
