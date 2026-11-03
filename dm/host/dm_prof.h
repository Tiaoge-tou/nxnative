// Runtime game profile for the two-game shell prototype (proto/shell2).
//
// A normal build compiles the host for one game: dm/games/game.py turns the
// game's game.tsv into game_profile.h, a set of DM_GAME_* macros. The shell
// build (game.py header with DM_SHELL_GAMES set) instead emits those macros
// as reads of the profile selected at launch, so one binary can boot either
// game. dm_prof.c holds one static table per shelled game, transcribed from
// its game.tsv (the values its generated game_profile.h carries); the front
// end picks one with dm_prof_select() before the host preloads, and nothing
// reads g_dm_prof before that. Single-game builds never see this header:
// their macros stay literals and this file is compiled but unused (the
// default selection is the first table, matching the build's own game when
// GAME names one of the two).
#pragma once
#include <stdint.h>

struct dm_disp_ver { const char *build, *ver; };   // one DM_GAME_DISPLAY_VERSIONS row

struct dm_game_prof {
    const char *id;            // DM_GAME_ID (title ID, 16 hex digits)
    const char *name;          // DM_GAME_NAME
    uint64_t program_id;       // DM_GAME_PROGRAM_ID
    const char *const *modules;// DM_GAME_MODULES, in load order
    int nmod;                  // DM_GAME_NMOD
    const char *romfs_marker;  // DM_GAME_ROMFS_MARKER
    uint64_t mem_reserve;      // DM_GAME_MEM_RESERVE
    uint64_t mem_alias;        // DM_GAME_MEM_ALIAS
    uint64_t mem_used;         // DM_GAME_MEM_USED
    uint64_t sys_resource;     // DM_GAME_SYS_RESOURCE
    const struct dm_disp_ver *display_versions; int n_display_versions;  // DM_GAME_DISPLAY_VERSIONS
    int pad_layout;            // DM_GAME_PAD_LAYOUT
    const char *serve_patch;   // DM_GAME_SERVE_PATCH
    int display_wide;          // DM_GAME_DISPLAY_WIDE
    int pad_skin_toggle;       // DM_GAME_PAD_SKIN_TOGGLE
    const char *seg_prefix;    // Mach-O guest section prefix: guest sections are
                               // __dm<seg_prefix><module>x0/W/x1 (gen_embed.py
                               // DM_EMBED_PREFIX, loader.c); one letter keeps
                               // every name within the 16-char section limit
};

extern const struct dm_game_prof *g_dm_prof;   // the selected game; the first table until dm_prof_select runs
const struct dm_game_prof *dm_prof_by_id(const char *tid);   // NULL when tid is not a shelled game
void dm_prof_select(const char *tid);          // point g_dm_prof at tid's table (no-op for an unknown ID)
