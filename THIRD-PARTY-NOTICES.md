# Third-party notices

Mirage ships the components below. Each keeps its own license; the full texts are in
`Licenses/` inside the installed files (`~/Library/Application Support/Mirage for PXPlay/Licenses`)
and in this repository.

Mirage does **not** include, copy or redistribute any part of PXPlay. PXPlay is a paid
product of its own developer. Mirage loads into the copy of PXPlay that you bought and
installed yourself, and edits two of its classes only in memory while it runs.

## rife-metal — Apache License 2.0

- Project: https://github.com/cinemore/rife-metal (version 0.1.8, commit `ac6408022eb6bc1a53181f5b2716a9f5ded507c2`)
- Copyright 2026 xzhih
- License: Apache License 2.0 — `Sources/RifeRuntime/LICENSE`
- Used in: `Sources/RifeRuntime` (built into `libFGBackends.dylib`), the Metal shaders in `Resources/FG/RifeShaders`.

The copy here is the library-only package prepared by OpenDuckFrame (below), with these
additional changes made for Mirage (Apache 2.0, section 4(b)):

| File | Change |
| --- | --- |
| `Package.swift` | Shaders are copied as source instead of precompiled by a build plugin |
| `Sources/RifeMetal/RifeStream.swift` | Exposes the optical-flow textures of the last frame (used for prediction) |
| `Sources/RifeMetalCore/IFNetGraph.swift` | Exposes the final flow textures after inference |
| `Sources/RifeMetalCore/BackwardWarpKernel.swift` | Loads its shaders through `LoadProbeShaders.swift` |
| `Sources/RifeMetalCore/PaddedFrameConvert.swift` | Same: shader loading through `LoadProbeShaders.swift` |
| `Sources/RifeMetalCore/LoadProbeShaders.swift` | New: compiles the shaders from `PXPLAY_FG_RESOURCES/RifeShaders` at run time |

## OpenDuckFrame — MIT License

- Project: https://github.com/Jun-bao/OpenDuckFrame
- Copyright (c) 2026 OpenDuckFrame contributors; Copyright (c) 2026 Khua contributors
- License: MIT — `Licenses/OpenDuckFrame-LICENSE.txt`
- Used in: the prepared rife-metal package (stream I/O, experiment options, runtime support
  patches) and the four-stage "ODF-VFI" model layout of the RIFE 4.25 weights.

## Practical-RIFE (RIFE 4.25 model weights) — MIT License

- Project: https://github.com/hzwer/Practical-RIFE
- Copyright (c) 2021 hzwer
- License: MIT — reproduced in `Sources/RifeRuntime/THIRD-PARTY.md`
- Used in: `Resources/FG/rife-v4.25.rmw`, the Practical-RIFE v4.25 weights converted to
  rife-metal's file format (same values, different layout).

## Not included

Earlier experiments used Apple VideoToolbox frame interpolation, MetalDuck and DraFG. None
of their code or files are part of Mirage.
