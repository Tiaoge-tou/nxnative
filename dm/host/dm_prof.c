// The shelled games' profiles for the two-game shell prototype; see dm_prof.h.
// Values are transcribed from each game's generated game_profile.h at the
// prototype baseline (0c0bfb2c); when a game's game.tsv changes a field that
// differs between the two, update its row here too (game.py's combined
// header refuses to build when a differing macro has no mapping, but it
// cannot see a value edited in only one of the two places).
#include "dm_prof.h"
#include <string.h>

static const char *const mods_silk[] = {"main", "subsdk0", "sdk"};
static const struct dm_disp_ver vers_silk[] = {{"fc9ea4ccc955d5799f37752b2d730b31", "1.0.30000"}};
static const struct dm_game_prof prof_silk = {
    .id = "010013C00E930000", .name = "Hollow Knight: Silksong", .program_id = 0x010013C00E930000ull,
    .modules = mods_silk, .nmod = 3,
    .romfs_marker = "Data/globalgamemanagers",
    .mem_reserve = 0x140000000ull, .mem_alias = 0x118000000ull, .mem_used = 0x4000000ull, .sys_resource = 0x1000000ull,
    .display_versions = vers_silk, .n_display_versions = 1,
    .pad_layout = 0,
    .serve_patch = "n:menu_title.bundle@6E3E5C:41030A3D>4129C10A@6EAA5C:00000000>401ADB34@6EAA6C:*3F5B4A53>3F800000 w:menu_title.bundle@6E3E5C:41030A3D>40B8A6E1>40B8A6E1@6EAA5C:00000000>C01ADB34>C01ADB34",
    .display_wide = 0, .pad_skin_toggle = 1,
    .seg_prefix = "s",
};

static const char *const mods_hades[] = {"main", "sdk"};
static const struct dm_disp_ver vers_hades[] = {{"5219053e5eb156be80fbb2f303779531", "0.0.126424"}};
static const struct dm_game_prof prof_hades = {
    .id = "0100A00019DE0000", .name = "Hades II", .program_id = 0x0100A00019DE0000ull,
    .modules = mods_hades, .nmod = 2,
    .romfs_marker = "Audio/Switch/Music.bank",
    .mem_reserve = 0x100000000ull, .mem_alias = 0x10000000ull, .mem_used = 0x6c00000ull, .sys_resource = 0x2000000ull,
    .display_versions = vers_hades, .n_display_versions = 1,
    .pad_layout = 1,
    .serve_patch = "RunLogic.lua@1782a:34343332>#00000000>#00000000@17846:30383031>30383031>30323730",
    .display_wide = 1, .pad_skin_toggle = 0,
    .seg_prefix = "h",
};

static const struct dm_game_prof *const profs[] = {&prof_silk, &prof_hades};
const struct dm_game_prof *g_dm_prof = &prof_silk;

const struct dm_game_prof *dm_prof_by_id(const char *tid) {
    if (!tid) return NULL;
    for (unsigned i = 0; i < sizeof profs / sizeof *profs; i++)
        if (!strcmp(profs[i]->id, tid)) return profs[i];
    return NULL;
}

void dm_prof_select(const char *tid) {
    const struct dm_game_prof *p = dm_prof_by_id(tid);
    if (p) g_dm_prof = p;
}
