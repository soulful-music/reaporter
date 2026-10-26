-- The adapter registry, in display order. Adding a vendor: one file in adapters/ and one
-- line here (README, "Adding a vendor"). The parentheses keep require to one value.
return {
  (require("reaporter.adapters.dmgaudio")),
  (require("reaporter.adapters.eventide")),
  (require("reaporter.adapters.fabfilter")),
  (require("reaporter.adapters.liquidsonics")),
  (require("reaporter.adapters.relab")),
  (require("reaporter.adapters.reverb_foundry")),
  (require("reaporter.adapters.soundtoys")),
  (require("reaporter.adapters.valhalla")),
}
