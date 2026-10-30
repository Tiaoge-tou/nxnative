# Hades II (0100A00019DE0000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B, LDRX, NOP

# No plain cuts: this build's baked render size is not rewritten to another build's size but routed through the frame step state
# page (FRAME_STEP below), so the size follows the screen the build runs on.
# The GUI reference width at main+0x2abfbc (mov w11, #1920, the "Screen" statics design size) is deliberately NOT patched, in any
# form: an earlier cut of it to 2344 shipped in one build and the device showed the title, save-select and end-of-run screens laid
# out on a ~1920 canvas, offset with a black bar on the right, while the in-run HUD stayed correct -- the menu-class screens lay out
# against that design size together with the script's centring math, so 1920 is its correct value at any render width. Do not
# re-add it (the render pair below plus the script-side canvas fix in front_ios.m are the whole wide configuration).
CUTS = {}

# ---- Render size from the host (frame step state page +0x38, a packed u64 width | height << 32) ----
# The host writes the cell when the game starts (loader.c dm_fps_state_apply): the width of DM_RENDER_WIDTH, which the iOS front end
# computes from the screen (1080 x the screen's aspect, down to a multiple of 8; front_ios.m), at the docked height 1080. Without the
# variable the host writes 2344 x 1080, the pair the wide builds baked until now, so a build behaves exactly as those did. The function
# exists so the rewriter reserves the state page for this main (which also makes the loader apply run for it); the stub is the game's
# only reader of the cell, and no frame step is installed (state +0 stays the profile's target, 0 for this game).
# Render size: the platform initialiser (main+0x2a5ef0) materialises the display size as one packed constant and never asks the
# host for it (no nn::oe display-resolution import, only the unsized nn::vi::CreateLayer): mov x8, #1280 | movk x8, #720, lsl #32,
# stored to the platform singleton (+8) and copied on; the renderer takes the pair from there (getter main+0x2920f4 -> renderer
# globals -> the render-target cache and the texture factory), so the swap chain is 1280x720 whatever the display. The stub loads
# the cell's whole pair into x8 instead, so the renderer, the swap chain and the engine's own settings mirror all follow the host's
# size; the movk is NOPed out (the cell already carries the height in its high half). The stub writes only x8, the register the pair
# itself wrote -- a scratch the initialiser rewrites a few instructions earlier and stores right after the pair -- and sets no flags
# and uses no LR, so nothing else can observe it.
def render_width(ctx):
    here, emit, site, put, state = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    site(0x2a6080, '08a080d2085ac0f2')
    start = here(); emit(ADRP(8, here(), state)); emit(LDRX(8, 8, 7))   # x8 = state page; ldr x8, [x8, #0x38] (the packed render size)
    emit(B(here(), 0x2a6088))
    put(0x2a6080, [B(0x2a6080, start), NOP], 'render size: mov x8, #1280 | movk x8, #720, lsl #32 replaced by the host render size (state page +0x38)')

# The key is the module build ID as dm/tools/patch_nso.py computes it (module bytes 0x40..0x50; also the BUILD_ID header of
# main.fixups.tsv) -- NOT the main= value of game.tsv's build line, which is a different ID and keys nothing
FRAME_STEP = {'8ce1ac48e9fa74479051f3520e632df4': render_width}

BINDING = [
    {'what': "render size routed from the host: the platform initialiser's packed display-size constant read from the frame-step state page instead", 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': "the initialiser materialises the size as one packed constant and never asks the host for it (no display-resolution import), so the size has to be served at the site that materialises it; a function-matched rule could carry the stub over the game's updates"},
]
