// The Binding of Isaac's touch-pad layout watcher (DM_PAD_ISAAC=1): the game's own art pad
// (DmGamepad.m, dm/padisaac) has four layouts -- the menu pages, the game and the death page --
// and switches between them off three fields in Repentance.nro's data segment, found by the
// page-state probes (hle_isaacprobe.c; the analysis is in the project's probe notes):
//   F1, the flag word at data +0x88498, bit 0x100: clear on the menu side, set while a run
//     exists (in game -- and, as far as anyone can measure, on the pause page too).
//     Only the bit is read: bit 0 pulses for a frame on transitions, so the word is never
//     compared whole.
//   F2, the three pointers at data +0xd2160 / +0xd2168 / +0xd2170, read as zero / nonzero:
//     zero until a save file is confirmed on the file-select page, nonzero for the rest of the
//     session. It is the only measured difference between the title / save pages (layout 0,
//     menu A) and the main menu / character pages (layout 1, menu B, which add an X key).
//   FD, the flag word at data +0x85408, read as zero / nonzero: zero everywhere until the run's
//     death, nonzero from the death instant through the diary page (layout 3, menu C). It is a
//     latch like F2, and the fourth probe round settled that it never clears in-process: neither
//     the word nor the diary object's three pointers at data +0x85428 do, on any exit path, so
//     the field alone cannot tell the diary from the run that follows it -- after a restart the
//     pad would sit in menu C over live gameplay. The watcher therefore shields it: leaving menu
//     C at all -- the front end notes an A / B press delivered there (dm_isaac_pad_diary_exit),
//     or the raw layout derived here stops being menu C -- arms a shield that stores the diary
//     pointers, the death counter at data +0x7d0d8 and the run's three pointers at data
//     +0x7be80; while it holds, a run (F1 set) ignores the stale flag and publishes the game
//     layout. The shield drops when the word itself reads zero, when any stored pointer
//     changes, or when the death counter steps past the value it armed with: the diary
//     pointers alone turned out never to move again -- the first shielded build's log armed
//     once and held for a whole session, a later diary included -- but the probes had seen
//     the counter step at a death and the +0x7be80 pointers replaced there, so a new death
//     is seen and its diary gets its page. Every edge is logged, with its reason. The menus
//     never consult FD, so the shield changes nothing there; its one blind spot is a death
//     that moves none of the stored values, whose page then shows the game layout (its
//     A / B are the diamond's there, so the page still works).
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

// The builds the page fields are known in: (build ID, F1's offset, F2's first offset, FD's offset, the diary pointers' first offset, the death counter's offset, the run pointers' first offset) in the module's data segment.
typedef struct { const char *build_id; uint32_t flag, file, death, death3, death_ctr, run3; } ia_row_t;
static const ia_row_t k_isaacpad[] = {
    { "8821c0a75afc814df5902fdc31e8d127", 0x88498, 0xd2160, 0x85408, 0x85428, 0x7d0d8, 0x7be80 },   // Repentance.nro, the build the page fields were found in
};

static _Atomic int g_ia_mode = 2;   // the published layout (dm_isaac_pad_mode): the game layout until the watcher derives another
static _Atomic int g_ia_exit_note;   // the front end saw an A / B press delivered on the death page (dm_isaac_pad_diary_exit): the diary shield arms on it

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
    int prev_raw = 2, shield = 0; uint64_t arm[3] = {0, 0, 0}, arm_run[3] = {0, 0, 0}, arm_ctr = 0;   // the diary shield: armed on any exit from menu C, holding the diary pointers, the run pointers and the death counter as they were
    for (;;) {
        const module_t *m = ia_module();
        const ia_row_t *row = m ? ia_row(m) : NULL;
        if (row && m->size - m->data_off > row->file + 24) {   // FD's offsets and the shield's sit below F2's, inside the same bound
            waited = 0;
            const uint8_t *data = m->base + m->data_off;
            uint64_t flag, death, f2 = 0, p, dtrip[3], ctr, rtrip[3];
            memcpy(&flag, data + row->flag, 8);
            memcpy(&death, data + row->death, 8);
            for (int k = 0; k < 3; k++) { memcpy(&p, data + row->file + 8 * (size_t)k, 8); f2 |= p; }
            for (int k = 0; k < 3; k++) memcpy(&dtrip[k], data + row->death3 + 8 * (size_t)k, 8);
            memcpy(&ctr, data + row->death_ctr, 8);
            for (int k = 0; k < 3; k++) memcpy(&rtrip[k], data + row->run3 + 8 * (size_t)k, 8);
            int noted_exit = atomic_exchange(&g_ia_exit_note, 0);   // an A / B press the front end delivered on the death page since the last poll
            if (shield) {   // the shield's release, judged on the live fields: the flag cleared, a new death counted, or a stored pointer set replaced at a new death
                const char *off = !death ? "the death flag cleared"
                    : ctr > arm_ctr ? "a new death was counted"
                    : dtrip[0] != arm[0] || dtrip[1] != arm[1] || dtrip[2] != arm[2] ? "the death page's pointers changed"
                    : rtrip[0] != arm_run[0] || rtrip[1] != arm_run[1] || rtrip[2] != arm_run[2] ? "a new death replaced the run's pointers"
                    : NULL;
                if (off) { shield = 0; LOG("[isaacpad] diary shield off: %s", off); }
            }
            int raw = (flag & 0x100) ? (death ? 3 : 2) : f2 ? 1 : 0;   // the layout the fields alone give: 0 menu A (title / save), 1 menu B (main menu / character), 2 the game, 3 menu C (the death page)
            if (!shield && prev_raw == 3 && (noted_exit || raw != 3)) {   // menu C was left: by a press delivered there, or by the raw layout moving on (the flag itself never clears)
                shield = 1; arm[0] = dtrip[0]; arm[1] = dtrip[1]; arm[2] = dtrip[2];
                arm_run[0] = rtrip[0]; arm_run[1] = rtrip[1]; arm_run[2] = rtrip[2]; arm_ctr = ctr;
                LOG("[isaacpad] diary shield on: the death flag stays set after the diary; it is ignored in game until it clears, its pointers change or a new death is counted");
            }
            prev_raw = raw;
            int mode = (flag & 0x100) ? (death && !shield ? 3 : 2) : f2 ? 1 : 0;   // as raw, but a shielded run reads the game layout: the stale death flag is ignored while F1 stands
            if (mode == cand) { if (nread < 2) nread++; } else { cand = mode; nread = 1; }
            if (nread >= 2 && cand != atomic_load(&g_ia_mode)) {
                atomic_store(&g_ia_mode, cand);
                LOG("[isaacpad] layout %s", cand == 0 ? "menu A" : cand == 1 ? "menu B" : cand == 2 ? "game" : "menu C");
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

void dm_isaac_pad_diary_exit(void) { atomic_store(&g_ia_exit_note, 1); }

void dm_isaacpad_init(void) {
    const char *e = getenv("DM_PAD_ISAAC");   // the watcher runs only when a build asks for it (the pad build's bundled env file sets it)
    if (!e || !atoi(e)) return;
    pthread_t th;
    if (!pthread_create(&th, NULL, isaacpad_main, NULL)) pthread_detach(th);
    else LOG("[RED] isaacpad: cannot start the watcher thread");
}
