# The Binding of Isaac: Repentance (`010021C000222000`)

Base game v0 (display version C1.4.1&M1.4.6), SDK 12.3.3. Nicalis' own engine on NVN. The game itself is two NROs the base loads at run time through nn::ro — `AfterbirthPlus.nro` and `Repentance.nro` (the RomFS's `.nro/`, registered by the `.nrr/` files) — over an ExeFS of `main`, `subsdk0` (GLSLC), `subsdk1` (NintendoSDK_movie) and `sdk`. Its shaders are GLSL sources (68 of them in the NROs) that `main` compiles at run time with GLSLC in `subsdk0`: the NSP script captures them by booting the game in the Mac host. The DLC (010021C000223001) packs as its own add-on image, outside the IPA. Plays on the iPhone.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `modules main subsdk0 subsdk1 sdk` | [`game.tsv`](game.tsv) | `subsdk1` (the movie player) is in the list only because the game's NROs import from it; `main` takes nothing from it. The survey's guess alone loads `main subsdk0 sdk`, and the build's NRO collection adds `subsdk1` to a provisional profile; the row here is that final row |
| `mem_reserve 0x100000000`, `mem_alias 0x10000000`, `mem_stack 0x10000000`, `app_pool 0xCD500000`, `sys_resource 0x0` | `game.tsv` | no system resource, so no virtual address memory: `main` sets a heap of at most the pool − used memory, a 3328 MB heap region. The values are the provisional profile's, from the survey |
| Directory-entry comparator cut | [`patches.py`](patches.py) | Repentance NRO build `8821c0a7…`: `KAGE::Filesys::DirectoryEntry::operator<` is not a strict weak ordering (directories before files only with the directory on the left), which walked the title screen's save housekeeping off its sorted array when the add-on content was mounted. The cut rewrites the function in place; the file's own header has the whole story |
| `display_wide on` | `game.tsv` | **a probe, not a settled setting.** With the fullscreen setting on, `nn::oe`'s default display resolution becomes the host's render width (2344x1080 on the phone) instead of 1920x1080. Every build so far came from a provisional profile (no `display_wide`), so the game has only ever rendered 1920x1080 and the present stretched it to the screen — measured on the iPhone at 1.221x horizontally. Whether this engine sizes its frame from the resolution answer is what the probe build with this profile reads from the device log: the `default display resolution` line, the present's picture shape and its crop |

## Status

Playable on the iPhone from the provisional profile (title screen, runs, the add-on content mounted). This profile exists to run the `display_wide` probe above as a single change against those builds; its other rows are the provisional profile's values, not new measurements. If the probe shows the game ignoring the wide answer, `display_wide` comes back off and the profile stands as the provisional's copy in the tree.
