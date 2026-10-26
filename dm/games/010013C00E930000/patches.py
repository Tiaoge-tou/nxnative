# Hollow Knight: Silksong -- render wide instead of 1920x1080, at the size of the screen the build runs on.
#
# Unity's Switch player never asks the host for a display resolution (guest main imports no
# nn::oe/vi resolution query at all), so the host-side display_wide switch cannot help here: the
# size comes from the operation mode inside the guest. Two native player sites decide it:
#   * the size getter (guest 0x124e224): docked -> 1920x1080, handheld -> 1280x720. Its result
#     feeds the engine's current-resolution record and nvnWindowSetCrop.
#   * the swapchain creation (guest 0x128bd60): hard-codes 1920x1080 in three
#     nvnTextureBuilderSetSize2D calls, one per swapchain texture.
# The two IL2CPP Screen.SetResolution(1920, 1080) call sites belong to the same set (added after
# build #19's device test): on this stack the managed request is not a no-op -- the native player
# stores it in its display-state object, and the apply step feeds exactly that pair to
# nvnWindowSetCrop, so with only the six native cuts the swapchain was wide but the final crop
# stayed 1920x1080 and the host presented the 16:9 crop stretched.
# All eight sites materialise the width as `mov wN, #1920`, formerly cut to a baked 2344. They
# are now routed through the frame step state page instead (FRAME_STEP below): at each site a
# stub loads the width the host measured on the screen it runs on, so one build fills an iPhone
# and an iPad alike; without the host variable the cell holds 2344, the width the wide builds
# baked until now. The paired height encodings (`mov wN, #1080` beside each width, and the
# handheld `mov w22, #720` at the getter's entry) are routed the same way, reading the packed
# size's high word: the cells' high halves hold 1080 and 720 unless the host overrides the
# docked height (DM_RENDER_HEIGHT, the launcher's lowered-resolution frame-rate tier), so until
# that tier is chosen every height stub loads the value the mov materialised, unchanged.
# The handheld path is routed the same way, through the state page's second cell (+0x40, the width
# at the handheld height 720): the getter's handheld sizes all flow through the `mov w23, #1280`
# at its entry -- the default it stores before the mode checks and the fallback its docked checks
# select against -- so that one site carries the handheld width everywhere the getter is used.
# The mode sizes the guest reports (and crops by) come from the screen-state ctor template, data
# rather than code; HOST_FILLS below has the loader write the same two widths over them.
from nso_asm import ADRP, B, LDRW

CUTS = {
  # Silksong main (build ID as dm/tools/patch_nso.py computes it; matches the main= value in
  # game.tsv here because the base main is the shipped one -- no update replaces it). No baked
  # cuts remain: the one width that used to stay baked -- the docked mode width in the
  # screen-state ctor template -- is host-filled now (HOST_FILLS below), because it did take
  # effect after all: the guest reports the template's per-mode sizes as its display size and
  # crops its presents by them, so on any screen whose runtime width is not the baked 2344 the
  # crop (2344x1080) exceeded the swapchain texture the stubs had sized (1552x1080 on an iPad)
  # and the host dropped every present -- a black screen with the game running and audible.
  'fc9ea4ccc955d5799f37752b2d730b31': [],
}

# Display-mode size words in the screen-state ctor template (the ctor copies the rodata block at
# 0x6679240 into the state object +0xa4..+0xb3: handheld width at the template's +0, docked at
# +8, the heights beside them). They are data in the writable span, not instructions, so no stub
# can hang off them; the loader instead writes the screen's own width for each mode over the
# baked one when the game starts (patch_nso.py HOST_FILLS, loader.c dm_fps_state_apply), the
# same values the state page cells carry, so the reported size, the crop and the textures agree
# on every screen: without the host variables the fills take 2344 / 1280, as baked until now.
# With a height override (DM_RENDER_HEIGHT) the loader writes the docked height word after the
# docked width too, in the same apply; the handheld height word keeps its baked 720.
HOST_FILLS = {
  'fc9ea4ccc955d5799f37752b2d730b31': [('H', 0x6679240), ('D', 0x6679248)],
}

# ---- Render width from the host (frame step state page +0x38, a packed u64 width | height << 32) ----
# The host writes the cell when the game starts (loader.c dm_fps_state_apply): the width of DM_RENDER_WIDTH, which the iOS front end
# computes from the screen (1080 x the screen's aspect, down to a multiple of 8; front_ios.m), at the docked height 1080. Without the
# variable the host writes 2344, the width the wide builds baked until now, so a build behaves exactly as those did. The function
# exists so the rewriter reserves the state page for this main (a FAR main: the page is appended to the image, see patch_nso.py);
# the stubs are the game's only readers of the cell, and no frame step is installed (state +0 stays the profile's target, 0 for
# this game). The width stubs read the cell's low word and the height stubs its high word (+0x3c docked, +0x44 handheld), each
# with the 32-bit load the original movz wN amounted to (same register, upper half zeroed).
# Each site below is a single `mov wN, #1920` that overwrites its register unconditionally -- an argument or a value about to be
# stored -- so the stub writes only that register (adrp + ldr w + b back: no flags, no LR, nothing else observable). The flags
# matter at the first site: the csel two instructions later still tests the tst before it. Sites in the order of the former cuts.
# The handheld cell (+0x40, the width at 720 from DM_RENDER_WIDTH_HD, 1280 without the variable) is read by one more site, in
# _WIDTH_SITES_HD: the getter's entry default, the register every handheld return of the getter flows through.
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
_WIDTH_SITES_HD = [
  (0x124e238, 23, '17a08052', 'size getter, handheld width (the entry default every handheld return flows through)'),
]
# The height paired with each width above: the same sites materialise it as `mov wN, #1080` (docked) and the getter's entry
# default as `mov w22, #720` (handheld), each beside its width site. The stubs read the packed size's high word (+0x3c docked,
# +0x44 handheld), which the host fills with 1080 / 720 -- the baked values -- unless DM_RENDER_HEIGHT overrides the docked
# height (loader.c dm_fps_state_apply), so the lowered-resolution frame-rate tier shrinks the render target at every site at
# once and every other build renders exactly as before. Same stub shape as the widths: the mov overwrites its register
# unconditionally, so adrp + ldr w + b back touches nothing else (the getter's csel still tests the tst before the pair)
_HEIGHT_SITES = [
  (0x124e2fc, 9, '09878052', 'size getter, docked path (dual check)'),
  (0x124e32c, 8, '08878052', 'size getter, docked path (single check)'),
  (0x124e36c, 8, '08878052', 'constant size getter'),
  (0x128bf04, 2, '02878052', 'swapchain texture 1'),
  (0x128bfac, 2, '02878052', 'swapchain texture 2'),
  (0x128c13c, 2, '02878052', 'swapchain texture 3'),
  (0x23f134c, 1, '01878052', 'Screen.SetResolution request (defaults initialiser)'),
  (0x296b524, 1, '01878052', 'Screen.SetResolution request (settings apply)'),
]
_HEIGHT_SITES_HD = [
  (0x124e23c, 22, '165a8052', 'size getter, handheld height (the entry default beside the handheld width)'),
]
def render_width(ctx):
    here, emit, site, put, state = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    for off, reg, orig, what in _WIDTH_SITES:
        site(off, orig)
        start = here(); emit(ADRP(reg, here(), state)); emit(LDRW(reg, reg, 14))   # ldr wN, [xN, #0x38] (the width, low word of the packed render size)
        emit(B(here(), off + 4))
        put(off, [B(off, start)], f'{what}: render width from the host render size (state page +0x38)')
    for off, reg, orig, what in _WIDTH_SITES_HD:
        site(off, orig)
        start = here(); emit(ADRP(reg, here(), state)); emit(LDRW(reg, reg, 16))   # ldr wN, [xN, #0x40] (the handheld width, low word of the packed handheld render size)
        emit(B(here(), off + 4))
        put(off, [B(off, start)], f'{what}: render width from the host render size (state page +0x40)')
    for off, reg, orig, what in _HEIGHT_SITES:
        site(off, orig)
        start = here(); emit(ADRP(reg, here(), state)); emit(LDRW(reg, reg, 15))   # ldr wN, [xN, #0x3c] (the height, high word of the packed render size)
        emit(B(here(), off + 4))
        put(off, [B(off, start)], f'{what}: render height from the host render size (state page +0x3c)')
    for off, reg, orig, what in _HEIGHT_SITES_HD:
        site(off, orig)
        start = here(); emit(ADRP(reg, here(), state)); emit(LDRW(reg, reg, 17))   # ldr wN, [xN, #0x44] (the handheld height, high word of the packed handheld render size)
        emit(B(here(), off + 4))
        put(off, [B(off, start)], f'{what}: render height from the host render size (state page +0x44)')

# The key is the module build ID as dm/tools/patch_nso.py computes it (module bytes 0x40..0x50; also the BUILD_ID header of
# main.fixups.tsv) -- NOT the main= value of game.tsv's build line (which happens to agree for this game)
FRAME_STEP = {'fc9ea4ccc955d5799f37752b2d730b31': render_width}
