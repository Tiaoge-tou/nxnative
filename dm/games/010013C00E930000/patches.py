# Hollow Knight: Silksong -- render wide instead of 1920x1080, at the size of the screen the build runs on.
#
# Unity's Switch player never asks the host for a display resolution (guest main imports no
# nn::oe/vi resolution query at all), so the host-side display_wide switch cannot help here: the
# size comes from the operation mode inside the guest. Two native player sites decide it:
#   * the size getter (guest 0x124e224): docked -> 1920x1080 (handheld stays 1280x720). Its result
#     feeds the engine's current-resolution record and nvnWindowSetCrop.
#   * the swapchain creation (guest 0x128bd60): hard-codes 1920x1080 in three
#     nvnTextureBuilderSetSize2D calls, one per swapchain texture.
# The two IL2CPP Screen.SetResolution(1920, 1080) call sites belong to the same set (added after
# build #19's device test): on this stack the managed request is not a no-op -- the native player
# stores it in its display-state object, and the apply step feeds exactly that pair to
# nvnWindowSetCrop, so with only the six native cuts the swapchain was wide but the final crop
# stayed 1920x1080 and the host presented the 16:9 crop stretched.
# All eight sites materialise the width as `mov wN, #1920`; heights are already 1080 everywhere,
# so only the width encodings were cut, formerly to a baked 2344. They are now routed through the
# frame step state page instead (FRAME_STEP below): at each site a stub loads the width the host
# measured on the screen it runs on, so one build fills an iPhone and an iPad alike; without the
# host variable the cell holds 2344, the width the wide builds baked until now.
# The handheld/movie path (1280x720) is deliberately untouched everywhere below.
from nso_asm import ADRP, B, LDRW

CUTS = {
  # Silksong main (build ID as dm/tools/patch_nso.py computes it; matches the main= value in
  # game.tsv here because the base main is the shipped one -- no update replaces it)
  'fc9ea4ccc955d5799f37752b2d730b31': [
    # The one width that stays baked, on purpose: the display-mode max width in the screen-state
    # ctor template (the ctor copies the rodata block at 0x6679240 into the state object
    # +0xa4..+0xb3; the +0xac word is the clamp ceiling of the native SetResolution setter, so
    # widened requests were still clamped to 1920). It is an upper bound, not a requested size:
    # every runtime width the host can pick at the docked height (1080 x the screen's aspect,
    # down to a multiple of 8) is at most 2344 on any current iPhone or iPad, so the ceiling never
    # binds; only a screen wider than 2.17:1 would meet it, and none is in scope. It is data in
    # the writable span rather than an instruction, so there is no site here for a stub to hang
    # off, and no second host write path is invented for a value that cannot take effect.
    (0x6679248, '80070000', '28090000',
     'display-mode max width in the screen-state ctor template: 1920 -> 2344 (the clamp ceiling of the native SetResolution setter; stays baked: an upper bound every runtime width stays under, not a requested size)'),
  ],
}

# ---- Render width from the host (frame step state page +0x38, a packed u64 width | height << 32) ----
# The host writes the cell when the game starts (loader.c dm_fps_state_apply): the width of DM_RENDER_WIDTH, which the iOS front end
# computes from the screen (1080 x the screen's aspect, down to a multiple of 8; front_ios.m), at the docked height 1080. Without the
# variable the host writes 2344, the width the wide builds baked until now, so a build behaves exactly as those did. The function
# exists so the rewriter reserves the state page for this main (a FAR main: the page is appended to the image, see patch_nso.py);
# the stubs are the game's only readers of the cell, and no frame step is installed (state +0 stays the profile's target, 0 for
# this game). This build's heights are baked 1080 at every site and the cell's high half says the same, so the stubs read only the
# low word, with the 32-bit load the original movz wN amounted to (same register, upper half zeroed).
# Each site below is a single `mov wN, #1920` that overwrites its register unconditionally -- an argument or a value about to be
# stored -- so the stub writes only that register (adrp + ldr w + b back: no flags, no LR, nothing else observable). The flags
# matter at the first site: the csel two instructions later still tests the tst before it. Sites in the order of the former cuts.
_WIDTH_SITES = [
  (0x124e2f8, 8, '08f08052', 'size getter, docked path (dual check)'),
  (0x124e324, 8, '08f08052', 'size getter, docked path (single check)'),
  (0x124e364, 8, '08f08052', 'constant size getter'),
  (0x128bf10, 1, '01f08052', 'swapchain texture 1'),
  (0x128bfa8, 1, '01f08052', 'swapchain texture 2'),
  (0x128c148, 1, '01f08052', 'swapchain texture 3'),
  (0x23f1354, 0, '00f08052', 'Screen.SetResolution request (defaults initialiser)'),
  (0x296b530, 0, '00f08052', 'Screen.SetResolution request (settings apply)'),
]
def render_width(ctx):
    here, emit, site, put, state = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    for off, reg, orig, what in _WIDTH_SITES:
        site(off, orig)
        start = here(); emit(ADRP(reg, here(), state)); emit(LDRW(reg, reg, 14))   # ldr wN, [xN, #0x38] (the width, low word of the packed render size)
        emit(B(here(), off + 4))
        put(off, [B(off, start)], f'{what}: render width from the host render size (state page +0x38)')

# The key is the module build ID as dm/tools/patch_nso.py computes it (module bytes 0x40..0x50; also the BUILD_ID header of
# main.fixups.tsv) -- NOT the main= value of game.tsv's build line (which happens to agree for this game)
FRAME_STEP = {'fc9ea4ccc955d5799f37752b2d730b31': render_width}
