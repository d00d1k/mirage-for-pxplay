# Changelog

## 1.1.0

- **HUD network on the Neural Engine.** A small U-Net (~240k parameters) trained on real GTA 6 gameplay marks HUD
  pixels (crosshair, counters, minimap, prompts, menus) so they stay crisp and still, and characters are no longer
  mistaken for HUD. It adds to the stillness rules, runs one frame behind, costs no GPU time and falls back to the
  rules automatically if it's unavailable.
- **Tidier character edges in fast camera turns.** When the camera swings fast around a still character, the edge of
  the character used to smear into the moving backdrop. Now the character side of that edge comes from the real frame
  and the backdrop side gets a short motion blur, so the profile stays intact. It only kicks in on fast turns, costs
  about 0.3 ms per frame, and is on by default ("Tidy character edges in fast camera turns" under More options).
- Frame pacing statistics in the log (how evenly frames arrive, how often the prediction was held).

## 1.0.0

- First release: RIFE 4.25 prediction for PXPlay 3.2.0 and PXPlay Demo 3.2.0 with HUD stillness rules, scene-cut
  guard, crosshair and menu handling, prediction hold over repeated or late frames, installer, 12 languages,
  Steady Wi-Fi helper.
