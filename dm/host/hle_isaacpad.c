// The Binding of Isaac's touch-pad layout watcher (DM_PAD_ISAAC=1): the game's own art pad
// (DmGamepad.m, dm/padisaac) has three layouts -- the menu pages, and the game -- and switches
// between them off two fields in Repentance.nro's data segment, found by the page-state probes
// (hle_isaacprobe.c; the analysis is in the project's probe notes):
//   F1, the flag word at data +0x88498, bit 0x100: clear on the menu side, set while a run
//     exists (in game -- and, as far as anyone can measure, on the pause and death pages too).
//     Only the bit is read: bit 0 pulses for a frame on transitions, so the word is never
//     compared whole.
//   F2, the three pointers at data +0xd2160 / +0xd2168 / +0xd2170, read as zero / nonzero:
//     zero until a save file is confirmed on the file-select page, nonzero for the rest of the
//     session. It is the only measured difference between the title / save pages (layout 0,
//     menu A) and the main menu / character pages (layout 1, menu B, which add an X key).
// The fields are gated on Repentance's build ID, like every fixed guest offset in this host:
// another build never runs them, and anything unexpected -- the module missing, the segment
// shorter than the fields -- leaves the published layout at its fallback, the game layout (2),
// so a layout that does not fit can never strand the player in a menu. Reads are the module
// mapping's own bytes (the loader's table, process-lifetime), exactly as the probe reads the
// same segment. Poll at 10 Hz; a new state must read the same twice in a row before it is
// published, so a transition's in-between frames never flicker the pad.
#include "hle.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <stdatomic.h>

// The builds the page fields are known in: (build ID, F1's offset, F2's first offset) in the module's data segment.
typedef struct { const char *build_id; uint32_t flag, file; } ia_row_t;
static const ia_row_t k_isaacpad[] = {
    { "8821c0a75afc814df5902fdc31e8d127", 0x88498, 0xd2160 },   // Repentance.nro, the build the page fields were found in
};

static _Atomic int g_ia_mode = 2;   // the published layout (dm_isaac_pad_mode): the game layout until the watcher derives another

static const ia_row_t *ia_row(const module_t *m) {   // the module's row in k_isaacpad, or NULL (an unknown build is never read)
    for (size_t i = 0; i < sizeof k_isaacpad / sizeof k_isaacpad[0]; i++)
        if (!strcmp(m->build_id, k_isaacpad[i].build_id)) return &k_isaacpad[i];
    return NULL;
}

static const module_t *ia_module(void) {
    for (int i = 0; i < g_nmod; i++) {
        const module_t *m = &g_mod[i];
        if (m->base && m->data_off && m->size > m->data_off && ia_row(m)) return m;
    }
    return NULL;
}

static void *isaacpad_main(void *arg) {
    (void)arg;
    LOG("[isaacpad] watching Repentance's page fields for the touch pad's layouts (build %s)", k_isaacpad[0].build_id);
    int cand = 2, nread = 0, waited = 0, noted = 0;
    for (;;) {
        const module_t *m = ia_module();
        const ia_row_t *row = m ? ia_row(m) : NULL;
        if (row && m->size - m->data_off > row->file + 24) {
            waited = 0;
            const uint8_t *data = m->base + m->data_off;
            uint64_t flag, f2 = 0, p;
            memcpy(&flag, data + row->flag, 8);
            for (int k = 0; k < 3; k++) { memcpy(&p, data + row->file + 8 * (size_t)k, 8); f2 |= p; }
            int mode = (flag & 0x100) ? 2 : f2 ? 1 : 0;   // 0 menu A (title / save), 1 menu B (main menu / character), 2 the game
            if (mode == cand) { if (nread < 2) nread++; } else { cand = mode; nread = 1; }
            if (nread >= 2 && cand != atomic_load(&g_ia_mode)) {
                atomic_store(&g_ia_mode, cand);
                LOG("[isaacpad] layout %s", cand == 0 ? "menu A" : cand == 1 ? "menu B" : "game");
            }
        } else if (!noted && ++waited >= 600) {   // a minute at 10 Hz with no module to read: say so once, then keep waiting quietly
            noted = 1;
            LOG("[isaacpad] Repentance build %s not seen; the pad stays in its game layout", k_isaacpad[0].build_id);
        }
        struct timespec ts = { 0, 100000000 }; nanosleep(&ts, NULL);
    }
    return NULL;
}

int dm_isaac_pad_mode(void) { return atomic_load(&g_ia_mode); }

void dm_isaacpad_init(void) {
    const char *e = getenv("DM_PAD_ISAAC");   // the watcher runs only when a build asks for it (the pad build's bundled env file sets it)
    if (!e || !atoi(e)) return;
    pthread_t th;
    if (!pthread_create(&th, NULL, isaacpad_main, NULL)) pthread_detach(th);
    else LOG("[RED] isaacpad: cannot start the watcher thread");
}
