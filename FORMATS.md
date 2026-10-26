# Preset formats

Interoperability notes for the preset files ReaPorter reads and the REAPER files it writes.
Everything here was measured on macOS (REAPER 7.82, arm64) with the VST3 builds of each
plugin: a preset converted this way and loaded by name through REAPER gives the plugin the
values the file holds. AU and VST2 containers differ and are not covered.

All integers are little-endian unless marked "BE". Offsets are in bytes.

- [REAPER user-preset file](#reaper-user-preset-file)
- [REAPER `vst_chunk` for a VST3](#reaper-vst_chunk-for-a-vst3)
- [JUCE ValueTree (binary)](#juce-valuetree-binary)
- [LiquidSonics](#liquidsonics) · [Reverb Foundry](#reverb-foundry) · [Eventide](#eventide) ·
  [Relab](#relab) · [Soundtoys](#soundtoys) · [Valhalla DSP](#valhalla-dsp)
- [Not covered](#not-covered)

## REAPER user-preset file

REAPER keeps a plugin's user presets in `<resource>/presets/vst3-<name>.ini`, the file
`TrackFX_GetUserPresetFilename` names. `<name>` is the FX name without the `VST3: ` prefix
and without its last ` (<vendor>)` group: `VST3: Tai Chi (Reverb Foundry)` uses
`vst3-Tai Chi.ini`.

```
[General]
NbPresets=2

[Preset0]
Data=<hex>
Data_1=<hex>          (only when the entry is over 16 KiB)
Len=<entry length>
Name=<name>

[Preset1]
...
```

- Lines end in CRLF in the files REAPER writes; it reads LF too.
- `Data`, `Data_1`, ... each hold at most 16384 bytes of the entry as uppercase hex, plus one
  checksum byte: the sum of those bytes modulo 256.
- REAPER lists entries `[Preset0]` .. `[Preset{NbPresets-1}]`; the first section of each
  number counts, and its first `Name=`. Without a readable `NbPresets` it lists none. Names
  are matched ignoring case when loading by name, so names must be unique ignoring case.
- `TrackFX_SetPreset` reads the file again on every call.

### The entry

The bytes of an entry are the FX state REAPER stores in a project, decoded:

```
u32  uid               REAPER's number for the plugin (below)
u32  0xFEED5EEE
i32  nin               input pin count, then nin x u64 pin mask (1 << pin)
i32  nout              output pin count, then nout x u64 pin mask
u32  chunk length
u32  1
u32  0x0010FFFF        (REAPER writes another low half when a program is selected)
     chunk             the plugin's vst_chunk (below)
u8   0
     program name, then u8 0
u32  0x10
```

**The pin masks are applied on load.** An entry with two input masks loaded into a plugin with
four inputs (stereo plus sidechain) leaves inputs 3 and 4 unmapped, so an entry must carry the
plugin's own pin count. Loading any preset resets custom pin routing to this mapping, as REAPER's
own presets do.

`uid` comes from REAPER's plugin list, `<resource>/reaper-vstplugins_arm64.ini` on Apple
silicon (`reaper-vstplugins64.ini` on 64-bit Windows and Intel Macs):

```
Blackhole.vst3=80741FD50C9CDA01,1332365903{565354484F4C45626C61636B686F6C65,Blackhole (Eventide)
<bundle>.vst3 =<file time>      ,<uid>     {<VST3 class id, 32 hex>          ,<name>
```

A negative uid is stored as its unsigned 32-bit value. Spaces in the bundle name become
underscores. Plugins built with JUCE (and Soundtoys) put `VST` and their VST2 4-character id in
the class id: `VST HOLE blackhole` above, so `HOLE` is the id.

## REAPER `vst_chunk` for a VST3

```
u32  component length
u32  1
     component         the plugin's IComponent state
     controller state  8 zero bytes for every plugin measured
```

Two component layouts occur here.

**VST2-compatible wrapper** (JUCE plugins, Soundtoys), all fields BE:

```
"VstW"  u32 8 (header size)  u32 1 (version)  u32 bypass
"CcnK"  u32 bank length
  "FBCh"  u32 2 (fxb version)  fx id (4 bytes)  u32 fx version  u32 program count
  128 zero bytes
  u32 chunk length, chunk
```

For a JUCE plugin the chunk is the plugin's own state followed by JUCE's private-data trailer:

```
plugin state
ValueTree "JUCEPrivateData" {Bypass = false}   (absent in some builds: zero length)
i64 length of that tree
"JUCEPrivateData"                              (15 bytes, no NUL)
```

JUCE ignores `fx id` and `fx version` on load; ReaPorter still writes the real ones.

**Plain component** (Relab): the component is the plugin's state as is.

## JUCE ValueTree (binary)

`ValueTree::writeToStream`:

```
type name, UTF-8, NUL
compressed int: property count
  per property: name (UTF-8, NUL), var
compressed int: child count, children
```

A compressed int is one byte `n` (bit 7 set = negative), then `n` little-endian bytes. A `var`
is a compressed-int byte count, a type byte, then the payload: `1` int32, `2` true, `3` false,
`4` double, `5` UTF-8 string with a NUL, `6` int64, `7` array (compressed-int count, then
vars), `8` binary.

## LiquidSonics

Cinematic Rooms Professional (`.crp_preset`), Lustrous Plates Surround (`.lp_preset`).
Factory presets in `/Library/Application Support/LiquidSonics/<plugin>/Factory Presets`, user
presets in `~/Library/Application Support/LiquidSonics/<plugin>/User Presets`.

A preset file is a binary ValueTree, then opaque trailing bytes:

```
CRP_PartialStateVT  written_by_version__string, written_by_version__int, written_by_plugin__code
  CRP_StateVT  preset_name, ...
    PARAM id value        one per parameter; id is the VST3 parameter index, value in plain units
```

**The file's bytes, unchanged, are the plugin state.** The plugin's state loader accepts its
partial-state tree, migrates presets written by older versions, resets every parameter the
preset lacks to its default and ignores the trailing bytes. Wrap them in the JUCE container:
fx id `CRP1` / `LPS1`, program count 0, `JUCEPrivateData{Bypass=false}`. Use the file name as
the preset name: the `preset_name` inside the file can differ.

Cinematic Rooms Professional has 4 inputs (stereo plus sidechain), 2 outputs.

## Reverb Foundry

Tai Chi (`.taichi_preset`): the LiquidSonics engine and file format (`TaiChi_PartialStateVT`).
Same recipe, fx id `TCR1`, 4 inputs, 2 outputs. Factory presets in
`/Library/Application Support/Reverb Foundry/Tai Chi/Factory Presets`, user presets under
`~/Library/Application Support/Reverb Foundry/Tai Chi/User Presets`.

One factory folder ships readable by root only; it is reported and skipped.

## Eventide

Presets in `~/Music/Eventide/<plugin>/`, one folder per plugin. `Snapshots/` holds the
plugin's snapshot slots, not presets.

**`.tide`**: a UTF-8 JSON object of parameter keys and values. The plugin state is the JSON
text, then **at least 8 NUL bytes**, padded to at least 1008 bytes; the plugin itself writes
`max(1008, len(json) + 8)`. With fewer than 8 trailing NULs the plugin ignores the state
silently (REAPER still reports success). JSON formatting is free. Container: fx id from
`pluginID` (4 zero bytes when the file has none), fx version from `pluginVer` (`"3.8.21"` is
`0x030815`, one byte per component), program count 0, `JUCEPrivateData{Bypass=false}`.

**`.tidex`**: JUCE `AudioProcessorValueTreeState` XML:

```xml
<STATE plugId="..." plugVer="...">
  <PARAMETERS><PARAM id="..." value="..."/>...</PARAMETERS>
  <DATAPARAMS><PROPERTY name="..." value="..." persist="0" undoable="0" canAB="1"/>...</DATAPARAMS>
</STATE>
```

The plugin state is the XML re-encoded as a binary ValueTree with the types the plugin writes
itself (not `ValueTree::fromXml`, which makes everything a string): `PARAM value` double,
`undoable` / `canAB` bool when `0` or `1`, any other integer-looking attribute int32, the rest
string. Then 8 NUL bytes. Container: fx id is `plugId` as a BE u32, program count 1, and **no**
private-data tree (an empty trailer). Files whose `PARAM value` is not a number do not
convert.

The plugins migrate older values themselves. Tempo-synced values are rewritten by the plugin
from the host tempo.

## Relab

LX480 v4 (`.lx480`) in `/Library/Application Support/Relab Development/LX480/Presets`. Plain
XML; two layouts:

- **v4**: `<Preset>` with `<EngineA>` and `<EngineB>` (96 elements each, `Value` attribute,
  identical tag order in every file), `<Session>` (16 fields), `<Info>`.
- **legacy**: `<Preset><Preset>` with 133 fields in other units. The plugin's own browser
  migrates these; they are not converted.

The plugin state is a plain component (no VST2 wrapper): a tagged binary whose block tags are
byte-reversed four-character codes.

```
"PHXF" u32 1   "pwen" u32 0
blocks: tag (4 bytes)  u32 size (8 + 4 x count)  u32 0  u32 count  count x f32
  "tsrp"  96   EngineA, in the file's element order
  "srpn"  25   session (slots below)
  "IUG_"  22   GUI
  "2srp"  96   EngineB
  "lsrp"  96   zeros
"MNSP" u32 length, the preset's path as a classic Mac path (":Macintosh HD:Library:...")
16 zero bytes, "JUCEPrivateData"
```

Session slots, measured one at a time: 1 EngineMode, 2 IOType, 3 IONoise, 4 Resonance, 5 AB,
6 Mode, 9-12 input / output gains (left, right), 13 Truncation, 14 ModulationTruncation,
15 DSPSaturation, 22-24 tempo sync (reverb, pre-delay, twin delay). Slot 0 is bypass, 16 / 17
input / output link (not in preset files); 7, 8 and 18-21 change nothing. A fresh instance
has 5.0 in slots 9-10, 8.8 in 11-12 and 1.0 in 13-15, 1.0 and 120.0 in GUI slots 8 and 9, and
zero everywhere else; ReaPorter starts from those values and writes the preset's.

## Soundtoys

Soundtoys 5 presets in `/Users/Shared/Soundtoys/Soundtoys 5/<plugin>/` (`.toy`). A preset is
CR-separated text:

```
WIDGET = EchoBoy;
VERSION = 4;
SAVED_BY_VERSION = 5.0.1;      (optional)
BUILDNUM = 16762;              (optional)
PRESET =<archive>;             (or ARCHIVE = in older files)
```

The archive is opaque and does not need decoding: **the plugin state is the `.toy` text
unchanged**, in the VST2-compatible wrapper with fx id from the VST3 class id, fx version 1,
program count 1, and no JUCE trailer. A folder belongs to the installed plugin whose bundle
name matches it ignoring case and punctuation (`Devil-Loc` and `Devil_Loc`); folders such as
`Rhythms` or `WaveShapes` are not plugins.

## Valhalla DSP

Presets in `/Library/Application Support/Valhalla DSP, LLC/<plugin>/Presets/` (`.vpreset`):
the plugin's state XML, one element named after the plugin whose attributes are the
normalised parameter values.

The plugin state is JUCE `copyXmlToBinary` of that XML:

```
"VC2!"  u32 XML length
<?xml version="1.0" encoding="UTF-8"?> <ValhallaVintageVerb a="..." b="..."/>    (one line)
9 NUL bytes
```

then the JUCE container with `JUCEPrivateData{Bypass=false}`, fx id the class id's
four-character code (`vee3` for VintageVerb), fx version 0, program count 0. Attributes keep
their order and are quoted as XML writers do (`&`, `<`, `>` escaped; tab, CR and LF as
character references; single quotes around a value that holds a double quote).

## Not covered

- **Encrypted presets**: LiquidSonics Illusion and Seventh Heaven, Reverb Foundry HD Cart.
  Their plugin state is encrypted too, with a fresh IV per save.
- **Eventide `.tidex` with non-numeric parameter values** (Physion Mk II, some presets).
- **Relab LX480 legacy layout**, REV6000 and Sonsig Rev-A (same family, block map not measured).
- **LiquidSonics Reverberate `.fxb`** banks: the container is understood, the program layout
  is not.
