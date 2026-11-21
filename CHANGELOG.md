# Changelog

## 1.1.0

- **HUD network on the Neural Engine.** A small U-Net (~240k parameters) trained on real GTA 6 gameplay marks HUD
  pixels (crosshair, counters, minimap, prompts, menus) so they stay crisp and still, and characters are no longer
  mistaken for HUD. It adds to the stillness rules, runs one frame behind, costs no GPU time and falls back to the
  rules automatically if it's unavailable.
- Frame pacing statistics in the log (how evenly frames arrive, how often the prediction was held).

## 1.0.0

- First release: RIFE 4.25 prediction for PXPlay 3.2.0 and PXPlay Demo 3.2.0 with HUD stillness rules, scene-cut
  guard, crosshair and menu handling, prediction hold over repeated or late frames, installer, 12 languages,
  Steady Wi-Fi helper.
