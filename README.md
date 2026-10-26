# ReaPorter

ReaPorter is a free REAPER script that turns the preset files plugin vendors install on your
computer into REAPER user presets. Each one becomes an entry in the plugin's own REAPER preset
menu, so anything that switches REAPER presets by name can use it: the FX window, actions,
SWS, OSC and control surfaces.

It reads only what is already on your machine and ships no presets.

## Install

ReaPorter needs [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) (0.9 or newer),
which ReaPack installs from its default repository.

1. In REAPER: **Extensions > ReaPack > Import repositories...**, paste

   ```
   https://raw.githubusercontent.com/<github-user>/reaporter/main/index.xml
   ```

2. **Extensions > ReaPack > Browse packages**, find **ReaPorter**, install it. Install
   **ReaImGui** the same way if you don't have it, then restart REAPER.
3. Run **Script: ReaPorter.lua** from the Actions list.

## Use

ReaPorter scans for each vendor's preset folders and matches every plugin to REAPER's plugin
list. For each plugin it shows how many presets it found, how many are new and how many
REAPER already has under the same name. That is a dry run: nothing is written or created
yet. A plugin REAPER lists under another name shows "resolved on Convert": Convert loads it
once on a temporary track at the end of the project to ask REAPER for its preset file, and
removes the track again.

Vendors fold open to show their plugins, and the search box filters by plugin or vendor
name; Convert still acts on everything ticked, and says how many ticked plugins the search
hides. Untick what you don't want and press **Convert**. It converts in the background, a few presets
per frame, so REAPER stays responsive, then lists what it wrote, what it skipped and what
failed, with the reason.

What it guarantees:

- **A backup first.** Before it changes a preset file it copies it to
  `<resource>/presets/ReaPorter-backup/<file>.<date-time>.ini` (`-2`, `-3`, ... when that
  name is taken; a backup is never overwritten).
- **A file it cannot read is left alone.** A preset file or MixSurface file that exists but
  cannot be read is reported and never replaced.
- **Existing presets are never altered.** New entries are appended; every byte already in the
  file stays as it is, except the preset count.
- **No duplicates.** A name the file already has (ignoring case) is skipped and reported.
  Running ReaPorter again only adds presets that are new since the last run.
- **All or nothing per file.** It writes a temporary file, reads it back, then replaces the
  old one. A failure leaves the old file intact.
- **One bad preset doesn't stop the rest.** A file that fails to convert is listed with the
  reason; the other presets of that plugin and the other plugins carry on.

Preset names are the file names. When two files share a name, the folder is added:
`Big Hall (Vocals)`.

A plugin that is already open can load the new presets without being reopened: by name, by
index and with next preset. (Measured with an FX open while its preset file was rewritten
three times.) Whether the FX window's preset menu lists them before the plugin is reopened
has not been checked.

### MixSurface folders and tags

When the [MixSurface](https://mixsurface.app) control surface is installed
(`<resource>/MixSurface/` exists), ReaPorter can also write its folders-and-tags file, so the
vendor's folders and a few tags (hall, plate, vocal, ...) show in its preset browser. The
option is shown only then. The format is open: [SIDECAR.md](SIDECAR.md).

## Supported plugins

VST3 builds. Converting needs the plugin installed in REAPER, since the preset carries
REAPER's id for it.

| Vendor | Plugins | Preset files |
|---|---|---|
| Eventide | every plugin with a folder in `~/Music/Eventide` (Blackhole, H3000, SP2016, UltraReverb, ...) | `.tide`, `.tidex` |
| LiquidSonics | Cinematic Rooms Professional, Lustrous Plates Surround | `.crp_preset`, `.lp_preset` |
| Relab | LX480 v4 (v4 presets; the legacy layout is listed as failed) | `.lx480` |
| Reverb Foundry | Tai Chi | `.taichi_preset` |
| Soundtoys | every Soundtoys 5 plugin with a preset folder | `.toy` |
| Valhalla DSP | every plugin with a `Presets` folder (VintageVerb, Supermassive, Delay, Plate, ...) | `.vpreset` |

Not covered: encrypted presets (LiquidSonics Illusion and Seventh Heaven, Reverb Foundry HD
Cart), Eventide presets with non-numeric parameters (some Physion Mk II), AU and VST2.

How each format converts: [FORMATS.md](FORMATS.md).

## Platforms

- **macOS**: verified.
- **Windows, Linux**: please report. The vendor folders there follow the usual conventions
  (`C:\ProgramData`, `%APPDATA%`, `Documents`/`Music`, `C:\Users\Public`) but have not been
  checked. If ReaPorter finds nothing, or finds the wrong thing, open an issue with the folder
  your vendor installs presets into.

## Adding a vendor

A vendor is one file in `FX/reaporter/adapters/` and one line in `adapters/init.lua`:

```lua
local M = { vendor = "Vendor", key = "vendor" }   -- key: the sidecar's "factory:<key>"

function M.plugins(env)          -- env.dirs (common, user, music, shared), env.fs, env.vst3
  return { {
    fx_name = "VST3: Plugin (Vendor)",   -- REAPER's FX name
    bundle = "Plugin",                    -- the .vst3 bundle name
    roots = { env.dirs.common .. "/Vendor/Plugin/Presets" },
    exts = { ".preset" },
  } }
end

function M.to_state(bytes, path, plugin)   -- one preset file -> the plugin's vst_chunk
  ...
end

return M
```

Optional: `plugin.pins = { inputs, outputs }`, the plugin's pin counts as REAPER reports
them on a stereo track (a preset carries them; without them ReaPorter asks REAPER once,
on Convert), `plugin.skip(path)` to leave files out, `M.tags(bytes)` for the vendor's own
category fields. Shared codecs live in `codec/` (JUCE ValueTree and VST3 containers, XML,
JSON). An adapter makes no `reaper.*` calls. Add a synthetic fixture to `tests/` (never a
real vendor file) and a section to FORMATS.md.

## Development

The conversion modules are plain Lua 5.4 and run outside REAPER:

```
lua5.4 tests/run.lua                                   # tests, synthetic fixtures only
lua5.4 tools/reaporter-cli.lua list --resource <REAPER resource folder>
lua5.4 tools/reaporter-cli.lua export --resource <dir> --out <dir>
```

`export` writes the converted preset files to `--out` and never touches the resource folder.

A release is: bump `@version` in `FX/ReaPorter.lua`, add its `@changelog`, push. The GitHub
Action runs the tests and updates `index.xml`.

## License

MIT, see [LICENSE](LICENSE).
