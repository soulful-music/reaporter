-- Reading and writing files with Lua's io and os, for the REAPER window and the CLI alike:
-- the atomic replace and the backup write. The caller injects exists(path) (REAPER's own
-- check, or a shell test outside REAPER); tests also inject open, rename and remove.
local M = {}

-- o = {exists, windows, open, rename, remove} -> {exists, read, write_atomic, write_new}
function M.new(o)
  local exists = assert(o.exists, "exists")
  local open = o.open or io.open
  local rename = o.rename or os.rename
  local remove = o.remove or os.remove
  local fs = { exists = exists }

  function fs.read(path)
    local f, err = open(path, "rb")
    if not f then return nil, err end
    local b, rerr = f:read("a")
    f:close()
    if not b then return nil, rerr end
    return b
  end

  -- Write a file, flush and close it, then read it back. Raises on any failure.
  local function write_checked(path, bytes)
    local f, err = open(path, "wb")
    if not f then error(("cannot write %s: %s"):format(path, tostring(err)), 0) end
    local ok, werr = f:write(bytes)
    if ok then ok, werr = f:flush() end
    local closed, cerr = f:close()
    if not ok or not closed then
      error(("writing %s failed: %s"):format(path, tostring(werr or cerr)), 0)
    end
    if fs.read(path) ~= bytes then error(("%s does not read back"):format(path), 0) end
  end

  -- A new file that must not exist yet (a backup): never replaces anything.
  function fs.write_new(path, bytes)
    if exists(path) then error(("%s already exists"):format(path), 0) end
    local ok, err = pcall(write_checked, path, bytes)
    if not ok then
      remove(path)
      error(err, 0)
    end
  end

  -- Replace `path` with `bytes` through a temp file beside it. Any failure before the
  -- rename leaves `path` as it was.
  function fs.write_atomic(path, bytes)
    local tmp = path .. ".reaporter-tmp"
    if exists(tmp) then
      error(("%s is left from an earlier run; move it away first"):format(tmp), 0)
    end
    local ok, err = pcall(write_checked, tmp, bytes)
    if not ok then
      remove(tmp)
      error(err, 0)
    end
    local renamed, rerr = rename(tmp, path)
    if not renamed and o.windows and exists(path) then
      -- Windows does not rename over a file: remove it first.
      local removed, merr = remove(path)
      if not removed then
        remove(tmp)
        error(("cannot replace %s: %s"):format(path, tostring(merr)), 0)
      end
      renamed, rerr = rename(tmp, path)
      if not renamed then
        error(("%s was removed but the new file could not take its place (%s); the new file is %s")
          :format(path, tostring(rerr), tmp), 0)
      end
    end
    if not renamed then
      remove(tmp)
      error(("cannot replace %s: %s"):format(path, tostring(rerr)), 0)
    end
  end

  return fs
end

return M
