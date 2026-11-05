# Third-party components

Stirred does not ship these in the repository; `Scripts/assemble-engine.sh` downloads them from the upstream releases.

| Component | Version used | License | Source |
|---|---|---|---|
| Wine (Staging, macOS build by Gcenx) | 11.21 | LGPL-2.1+ | https://github.com/Gcenx/macOS_Wine_builds (sources: https://www.winehq.org) |
| DXMT | v0.80 | LGPL-2.1 (see upstream LICENSE) | https://github.com/3Shain/dxmt |
| DXVK (planned) | 3.1.1 | zlib | https://github.com/doitsujin/dxvk |
| MoltenVK (planned) | 1.4.2 | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK |
| Steam client | latest, downloaded by the user's machine from Valve | Valve Subscriber Agreement | https://store.steampowered.com |

SHA-256 of archives used in phase 0 (2026-11-05):
- wine-staging-11.21-osx64.tar.xz `d7bcd5abf4df27aae397a7898aef074fea4a2e0b51e0a55aa9659517bbf9d452`
- dxmt-v0.80-builtin.tar.gz `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`

Not used, by design: Apple Game Porting Toolkit / D3DMetal (redistribution restricted by Apple's license).
TODO before any public release: confirm Wine build licensing text shipped with the Gcenx archive, add the GPL-3 LICENSE file.
