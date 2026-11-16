# Third-party components

Stirred does not ship these in its repository. On first start the app downloads them from the upstream releases
(archives pinned by SHA-256) into `~/Library/Application Support/Stirred`.

| Component | Version | License | Source |
|---|---|---|---|
| Wine Staging (macOS build by Gcenx, includes MoltenVK) | 11.21 | LGPL-2.1+ (MoltenVK: Apache-2.0) | https://github.com/Gcenx/macOS_Wine_builds, sources: https://www.winehq.org |
| DXVK-macOS (DXVK 1.10.3 fork by Gcenx) | v1.10.3-20230507 | zlib | https://github.com/Gcenx/DXVK-macOS |
| Steam client for Windows | latest, downloaded on your machine | Valve Subscriber Agreement | https://store.steampowered.com |

SHA-256 of the pinned archives:
- `wine-staging-11.21-osx64.tar.xz` `d7bcd5abf4df27aae397a7898aef074fea4a2e0b51e0a55aa9659517bbf9d452`
- `dxvk-macOS-async-v1.10.3-20230507.tar.gz` `f67d99d0a8eeedd7d406b283a3df9f939b5965acb00efcb33d0c6235c195a516`

Shipped in this repository and built from its own source: `Resources/wrappers/steamwebhelper_wrapper.exe`
(from `Wrapper/steamwebhelper_wrapper.c`, GPL-3.0-or-later).

Deliberately **not** used: Apple's Game Porting Toolkit / D3DMetal (redistribution restricted by Apple's license).

Optional, built on your machine by `Scripts/build-dxmt-engine.sh` and never shipped by Stirred: DXMT v0.80 (LGPL-2.1, https://github.com/3Shain/dxmt) and a
`winemac.so` rebuilt from Wine 11.21 + Wine Staging 11.21 (LGPL-2.1) with the changes in `Patches/dxmt/`, which are the corresponding source.

Stirred itself is GPL-3.0-or-later (see `LICENSE`).

## Legendary (optional, Epic Games support)
- What: open-source command-line client for the Epic Games Store. Version 0.21.1, native Apple-chip binary.
- License: GPL-3.0. Source and releases: https://github.com/legendary-gl/legendary (the `derrod/legendary` repository now redirects there).
- How Stirred uses it: downloaded from the release page above only when the user sets Epic up, verified by SHA-256
  (`d87978321dba9cb731fab40c72f0a30bed55baca8b5341ab21024c5733cd837e`), run as a separate program. Not bundled with Stirred, not modified.
