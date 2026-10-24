# Hades II (0100A00019DE0000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
CUTS = {
  # Hades II updated main (v1.0.137848, the build the IPA is made from). The key is the module build ID as
  # dm/tools/patch_nso.py computes it (module bytes 0x40..0x50; also the BUILD_ID header of main.cuts.tsv) --
  # NOT the main= value of game.tsv's build line, which is a different ID and keys nothing.
  '8ce1ac48e9fa74479051f3520e632df4': [
    # Render size: the platform initialiser (main+0x2a5ef0) materialises the display size as one packed constant and never
    # asks the host for it (no nn::oe display-resolution import, only the unsized nn::vi::CreateLayer): mov x8, #1280 |
    # movk x8, #720, lsl #32, stored to the platform singleton (+8) and copied on; the renderer takes the pair from there
    # (getter main+0x2920f4 -> renderer globals -> the render-target cache and the texture factory), so the swap chain is
    # 1280x720 whatever the display. Widen the pair to 2344x1080 (1080 x 19.5/9, to a multiple of 8: the phones' aspect at
    # docked height), so with the fullscreen setting the game renders the wide picture itself instead of the present
    # stretching the 1280x720 one; the pair also feeds the engine's own settings mirror, which then agrees. The HUD draws
    # on its own 1920x1080 virtual canvas and scales from there. Companion host change: profile display_wide
    # (dm/host/hle_oe.c) covers the resolution query this build never makes.
    (0x2a6080, '08a080d2', '082581d2', 'render width: mov x8, #1280 -> #2344 (platform display size, low half)'),
    (0x2a6084, '085ac0f2', '0887c0f2', 'render height: movk x8, #720, lsl #32 -> #1080, lsl #32 (platform display size, high half)'),
  ],
}
