# Hollow Knight: Silksong -- render wide (2344x1080) instead of 1920x1080.
#
# Unity's Switch player never asks the host for a display resolution (guest main imports no
# nn::oe/vi resolution query at all), so the host-side display_wide switch cannot help here: the
# size comes from the operation mode inside the guest. Two native player sites decide it:
#   * the size getter (guest 0x124e224): docked -> 1920x1080 (handheld stays 1280x720). Its result
#     feeds the engine's current-resolution record and nvnWindowSetCrop.
#   * the swapchain creation (guest 0x128bd60): hard-codes 1920x1080 in three
#     nvnTextureBuilderSetSize2D calls, one per swapchain texture.
# All six sites materialise the width as `mov wN, #1920`; heights are already 1080 everywhere, so
# only the width encodings are cut, to 2344 (the iPhone fullscreen render width used across this
# fork). The handheld/movie path (1280x720) is deliberately untouched.
# Encodings verified with capstone: mov w8, #2344 = 08 25 81 52; mov w1, #2344 = 01 25 81 52.
# (An earlier draft of these values encoded 2340 by mistake -- always decode-check.)
# The two IL2CPP Screen.SetResolution(1920, 1080) call sites ARE cut as well (added after build
# #19's device test): on this stack the managed request is not a no-op -- the native player stores
# it in its display-state object, and the apply step feeds exactly that pair to nvnWindowSetCrop,
# so with only the six cuts above the swapchain was 2344x1080 but the final crop stayed
# 1920x1080 and the host presented the 16:9 crop stretched. Both sites materialise the width as
# `mov w0, #1920` right before the icall; their heights are already `mov w1, #1080`.

CUTS = {
  # Silksong main (build ID as dm/tools/patch_nso.py computes it; matches the main= value in
  # game.tsv here because the base main is the shipped one -- no update replaces it)
  'fc9ea4ccc955d5799f37752b2d730b31': [
    (0x124e2f8, '08f08052', '08258152',
     'size getter, docked path (dual check): render width 1920 -> 2344 (height already 1080)'),
    (0x124e324, '08f08052', '08258152',
     'size getter, docked path (single check): render width 1920 -> 2344'),
    (0x124e364, '08f08052', '08258152',
     'constant size getter: width 1920 -> 2344'),
    (0x128bf10, '01f08052', '01258152',
     'swapchain texture 1: width 1920 -> 2344'),
    (0x128bfa8, '01f08052', '01258152',
     'swapchain texture 2: width 1920 -> 2344'),
    (0x128c148, '01f08052', '01258152',
     'swapchain texture 3: width 1920 -> 2344'),
    (0x23f1354, '00f08052', '00258152',
     'Screen.SetResolution request (defaults initialiser): width 1920 -> 2344 (drives the window crop)'),
    (0x296b530, '00f08052', '00258152',
     'Screen.SetResolution request (settings apply): width 1920 -> 2344 (drives the window crop)'),
    (0x6679248, '80070000', '28090000',
     'display-mode max width in the screen-state ctor template: 1920 -> 2344 (the ctor copies the rodata block at 0x6679240 into the state object +0xa4..+0xb3; the +0xac word is the clamp ceiling of the native SetResolution setter, so widened requests were still clamped to 1920)'),
  ],
}
