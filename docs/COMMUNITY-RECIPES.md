# Sharing recipes

A recipe is one small JSON file (`recipes/steam/<appid>.json`). Stirred shares them as files; it never uploads anything.

**Share:** game card "..." menu, "Copy recipe to share" (or `stirredctl recipe export <game> [--tested]`). The output has only
recipe fields (no paths, names or accounts). `--tested` marks it verified and records chip, memory, macOS, engine and date
in the notes: use it only if you really played the game with these settings. To add it to the project, open a pull request
with the file under `recipes/steam/`.

**Import:** toolbar "Import recipe..." (or `stirredctl recipe import <file>`). Imported recipes are stored in
`~/Library/Application Support/Stirred/recipes/steam/`, win over the bundled recipe for that game, are never shown as verified,
and can be removed with `stirredctl recipe remove <game>`. Your personal settings still win over both.

**What is refused** (a recipe from someone else is untrusted): environment variables other than `DXVK_`, `MVK_`, `WINE`,
`SDL_`, `MTL_`, `STEAM` prefixes (so no `DYLD_*`), graphics options outside `dxvk./d3d9./d3d10./d3d11./dxgi.`, DLL modes
other than native/builtin, an updater path outside the game folder or not an `.exe`, files over 64 KB.

**Not done yet:** fetching recipes automatically from a hosted repository, and anonymous result reports. Both need a public
repository and a privacy design (opt-in, what is sent, moderation).
