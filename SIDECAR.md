# The folders-and-tags sidecar

REAPER's preset file holds names and states only. A preset browser that wants the vendor's
folders and some tags reads a sidecar file next to it. ReaPorter writes one per preset file
when `<resource>/MixSurface/` exists (the MixSurface control surface reads them), and only
when "Write MixSurface folders and tags" is ticked. The format is open: any tool may read or
write it by these rules.

## File

`<resource>/MixSurface/fx-presets/<preset file name>.json`, for example
`vst3-Tai Chi.ini.json`. UTF-8 JSON, keys sorted, one-space indent, a final newline. It is
replaced whole (written to a temporary file, then renamed).

```json
{
 "presets": {
  "Booth": {
   "autoTags": [
    "Post",
    "small",
    "room"
   ],
   "folder": [
    "Post",
    "Small Rooms"
   ],
   "source": "factory:liquidsonics",
   "tags": [
    "Mine",
    "Post",
    "small",
    "room"
   ]
  }
 }
}
```

One record per preset name, as the preset file lists it (trimmed). Fields:

| Field | Meaning |
|---|---|
| `folder` | the preset file's folder relative to the vendor's factory folder, outermost first |
| `autoTags` | the members of `tags` the importer wrote |
| `tags` | the user's own tags, then the auto tags |
| `source` | `factory:<vendor>` for an imported preset; anything else is the user's |
| `favorite`, `createdAt`, ... | owned by the reading application; kept as they are |

Omitted when empty: `folder`, `autoTags`, `tags`. Other top-level keys are not kept.

## Folders

The folder is the path of the preset file below the plugin's first preset folder (its factory
folder). A preset from a plugin's preset database or an exported pack is filed under its pack
instead: `["Essentials"]`. A first level that only holds the library (`Presets`, `Factory Presets`) is dropped.
A preset under a later folder (the vendor's user-preset folder) is filed under that folder's
own name: `User Presets/Mine/A` gives `["User Presets", "Mine"]`.

## Auto tags

In this order, repeats dropped ignoring case (the first spelling wins), each cut to 40
characters, at most 32:

1. the vendor's own tags, when its format has them (the tags of Relab LX480 Dual Engine's
   preset browser);
2. every folder segment, with leading numbering such as `01 - ` or `03 ` removed;
3. each vocabulary word found as a whole word in the preset name or a folder segment, after
   splitting camelCase (`SmallRoom` reads as `small room`) and lowercasing.

The vocabulary (`FX/reaporter/core/sidecar.lua`) is one lowercase singular tag per line;
its plural (`+s`, `+es`) and the aliases after `:` match too, and a space or hyphen inside a
word matches any run of spaces, underscores or hyphens (`lo-fi`, `lo fi`, `lo_fi`):

```
small: tiny      medium     large: big     huge
room   hall   plate   chamber   church   spring   ambience   cathedral
vocal: vox   drum   guitar   snare   piano
dark   bright   long   short   lofi: lo-fi, lo fi   shimmer   modulated: modulation
```

Within one plugin a tag keeps one spelling (vocabulary words lowercase, others as first seen),
so `Halls` and `HALLS` show as one tag.

## Merging

A re-import replaces `folder` and `autoTags` and keeps everything else:

- the user's tags are the record's `tags` minus its old `autoTags` (ignoring case); the new
  `tags` are those, then the new auto tags the user does not already have;
- `autoTags` becomes the new auto tags that made it into `tags` (a user tag equal to an auto
  tag stays the user's);
- `favorite`, `createdAt` and any other field are kept;
- a record whose `source` is set and does not start with `factory:` (a preset the user saved
  under the same name) is never touched;
- records for names the preset file does not list are left as they are, and no record is
  written for a name the file does not list.

A re-import puts back an auto tag the user removed, because the sidecar does not record the
removal.
