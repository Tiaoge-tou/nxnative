# The Binding of Isaac: Repentance (010021C000222000): the rewriter's patches of this game's own builds. dm/tools/patch_nso.py loads every profile's patches.py and applies those of a module's NSO build ID;
# CUTS, OBS and FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
#
# This game has no profile of its own in dm/games (its IPAs are packed from a provisional profile); the folder holds only this patch file,
# which patch_nso.py loads like every other, so the cut reaches the game's module on the provisional path too.
CUTS = {
  # Repentance (the game's own NRO, registered in its NRR and loaded at run time with nn::ro): KAGE::Filesys::DirectoryEntry::operator<
  # (module+0x497864, 60 bytes) is not a strict weak ordering. It answers "directory before file" only when the directory is the left
  # operand; with a file on the left it falls through to the name comparison, so for a file F and a directory D with F.name < D.name
  # both operator<(F, D) and operator<(D, F) hold. The std::sort of a directory listing's entry pointers in
  # PersistentGameData::DeleteOldBackups (the title screen's save housekeeping, right after the first save commit) then walks off the
  # array and dereferences a hash-table word as an entry: the device crash of the slim-190 and slim-191 runs is at module+0x49786c,
  # the function's first dereference, and only with the add-on content mounted -- the listing that mixes the two classes (a base-only
  # run answers its buttons and never crashes). The cut rewrites the function in place, 56 of its 60 bytes (the last word, a ret, is
  # the original one): the two operands' directory bits (flags bit 1, the bit the original tests) are compared first -- differing
  # classes answer with the left operand's bit, directories first -- and equal classes keep the original tail, a strcmp of the names
  # (the PLT at module+0x644460) reduced to its sign bit. Same ABI (x0 this, x1 other, w0 the answer), no callee-saved register touched.
  '8821c0a75afc814df5902fdc31e8d127': [
    (0x497864, 'fd7bbfa9fd03009108004039c8000836280040398800083720008052fd7bc1a8c0035fd6000440f9210440f9f4b20694007c1f53fd7bc1a8', 'fd7bbfa908004039290040390a01094a8a00083600050153fd7bc1a8c0035fd6000440f9210440f9f5b20694007c1f53fd7bc1a8c0035fd6', 'directory-entry comparator (KAGE::Filesys::DirectoryEntry::operator<): directories before files in both argument orders, name order within a class'),
  ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md): what, its binding now, the loosest it could have (goal),
# purpose, why; blocked or kept: why the gap stays open (cannot close yet, or left open on purpose); checked: what was checked on game files (else a judgement)
BINDING = [
    {'what': "the Repentance module's directory-entry comparator made a strict weak ordering", 'now': 'build', 'goal': 'game', 'purpose': 'runtime',
     'why': "the game's own comparator in its run-time-loaded module; a function-matched rule could carry the rewrite over the game's updates",
     'checked': 'the shipped Repentance.nro (build 8821c0a7) disassembled and the device crash signature matched to its first dereference, 2026-11-06'},
]
