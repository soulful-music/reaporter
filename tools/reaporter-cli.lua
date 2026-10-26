-- ReaPorter without REAPER, for checking conversions from a shell (macOS / Linux).
--
--   lua5.4 tools/reaporter-cli.lua list   --resource DIR
--   lua5.4 tools/reaporter-cli.lua export --resource DIR --out DIR [--presets DIR]
--          [--sidecars DIR] [--only FX_NAME] [--default-pins]
--
-- list prints every vendor plugin with its status and dry-run counts. export writes, per
-- plugin REAPER lists, into --out: <ini name> (the merge into --presets' file of that
-- name, or a new file), <ini name>.entries (name TAB path TAB entry hex, one per
-- converted preset), <ini name>.failed (path TAB reason) and <ini name>.json (the
-- sidecar, merged into --sidecars' file). It never writes anywhere but --out.
-- --default-pins uses 2 in / 2 out for a plugin whose pin count is not measured.
local here = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = here .. "/../FX/?.lua;" .. here .. "/../FX/?/init.lua;" .. here .. "/?.lua;" .. package.path

local adapters = require("reaporter.adapters")
local convert = require("reaporter.core.convert")
local plugin_list = require("reaporter.core.plugin_list")
local fs = require("plainfs")

local function opt(name)
  for i = 1, #arg do
    if arg[i] == name then return arg[i + 1] end
  end
end

local function flag(name)
  for i = 1, #arg do
    if arg[i] == name then return true end
  end
  return false
end

local cmd = arg[1]
local resource = opt("--resource")
if not resource or (cmd ~= "list" and cmd ~= "export") then
  io.stderr:write("usage: reaporter-cli.lua list|export --resource DIR [--out DIR ...]\n")
  os.exit(2)
end
local presets_dir = opt("--presets") or (resource .. "/presets")
local sidecars = opt("--sidecars") or (resource .. "/MixSurface/fx-presets")
local only = opt("--only")

local os_name = io.popen("uname -sm"):read("l")
os_name = os_name:find("Darwin") and (os_name:find("arm64") and "macOS-arm64" or "OSX64") or "Linux-x86_64"
local vst3 = {}
for _, n in ipairs(plugin_list.file_names(os_name)) do
  local data = fs.read(resource .. "/" .. n)
  if data then
    vst3 = plugin_list.parse(data)
    break
  end
end

local env = { os = os_name, dirs = convert.dirs(os_name, os.getenv("HOME")), fs = fs, vst3 = vst3 }
local groups = convert.discover(adapters, env)

local function hex(s) return (s:gsub(".", function(c) return ("%02X"):format(c:byte()) end)) end

local status = 0
for _, g in ipairs(groups) do
  if g.error then print(g.adapter.vendor .. ": adapter error: " .. g.error) end
  for _, p in ipairs(g.plugins) do
    if not only or p.fx_name == only then
      local named, unreadable = convert.presets(p, fs)
      local existing = fs.read(presets_dir .. "/" .. p.ini_name)
      if cmd == "list" then
        local c = convert.dry_run(named, existing)
        print(("%s\t%s\tfound %d\tnew %d\texist %d%s"):format(g.adapter.vendor, p.fx_name, c.found,
          c.new or 0, c.exist or 0, (p.problem and "\t" .. p.problem or "") .. (c.error and "\t" .. c.error or "")))
      elseif p.listing and not p.problem then
        local nin, nout = 2, 2
        if p.pins then
          nin, nout = p.pins[1], p.pins[2]
        elseif not flag("--default-pins") then
          print("SKIP (no pin count)", p.fx_name)
          goto continue
        end
        do
          local job = convert.new_job(g.adapter, p, named)
          convert.step(job, fs.read)
          local out = opt("--out")
          local ef = assert(io.open(out .. "/" .. p.ini_name .. ".entries", "wb"))
          local ini = require("reaporter.core.ini")
          for _, e in ipairs(job.ok) do
            ef:write(e[1], "\t", e[2], "\t", hex(ini.entry_data(p.listing.uid, e[3], e[1], nin, nout)), "\n")
          end
          ef:close()
          local ff = assert(io.open(out .. "/" .. p.ini_name .. ".failed", "wb"))
          for _, f in ipairs(job.failed) do ff:write(f[1], "\t", f[2], "\n") end
          ff:close()
          local ok, merged, added, skipped = pcall(convert.merged, job, existing, p.listing.uid, nin, nout)
          if not ok then
            print("MERGE REFUSED", p.fx_name, merged)
            status = 1
          else
            if #added > 0 then fs.write(out .. "/" .. p.ini_name, merged) end
            local side = convert.sidecar(g.adapter, p, named, merged, fs.read(sidecars .. "/" .. p.ini_name .. ".json"), fs.read)
            fs.write(out .. "/" .. p.ini_name .. ".json", side)
            print(("SUMMARY\t%s\t%s\tadded %d\tskipped %d\tfailed %d\tunreadable %d"):format(p.fx_name, p.ini_name,
              #added, #skipped, #job.failed, #unreadable))
          end
        end
      end
    end
    ::continue::
  end
end
os.exit(status)
