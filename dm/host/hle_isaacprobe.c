// TEMPORARY PROBE -- remove once the Isaac page-state field is found (it exists only so one on-device run can find it).
// DM_ISAAC_PROBE=1 starts a read-only watcher that hunts for the guest field which tells The Binding of Isaac's title /
// menu state from its in-game state, the field the game's custom touch pad needs before it can switch between its title
// layout and its in-game layout on its own (the Silksong pad does the same off UIManager's page field, found by the
// memory-diff probes in this host's history). Nothing here writes guest memory, and with the switch absent or 0 the
// watcher never starts and the host behaves exactly as without this file.
// What it watches, at 4 Hz: the writable data segment (data_off .. the image's end: .data and .bss) of every module in
// the loader's table -- main, the SDK and the game's NROs (Repentance, AfterbirthPlus) -- logging one line per changed
// 8-byte slot, plus the first 256 bytes of the objects main's data slots point at (the game's state very likely sits
// behind one such pointer), re-validated every poll so a freed or moved object can never fault the host: heap reads go
// through dm_guest_heap_read, which copies under the memory lock, and module reads stay inside a module's own data
// segment, whose mapping lives as long as the process. A slot that changes on every poll for ten seconds is named
// once as a counter and then left quiet. The on-device script walks title -> menus -> a run -> pause -> title with
// steady pauses between the states; the analysis diffs the log's steady stretches offline.
// Round 3 (the menu tour's analysis): two fields in Repentance's data segment separate the title / save pages, the
// main menu / character pages and the game (the pad watcher, hle_isaacpad.c, reads them now), but the pause page and
// the death (diary) page matched the in-game signature on every layer above -- their state must sit in heap objects
// behind Repentance's own data-segment pointers, which the first probe never followed. So the probe also deep-follows
// them: every pointer stored in Repentance's data segment (the build the fields were found in, k_isaacprobe_deep) gets
// its target's first 512 bytes diffed the same way, tagged with the root slot's offset, capped at IP_DEEP_MAX
// objects, with the same counter silencing per field. The tour this time only has to hold the pause page and die
// once, steadily, inside one run.
// Round 4 (that tour's analysis): the first-come table had filled with boot-time pointers (~2 s in) before any
// of the objects that matter exist, so the menu tour's deep layer read almost nothing. Two roots are therefore
// pinned -- followed always, outside the cap and the first-come scan (see the round-4 section below): +0xcc0a8,
// the overlay / menu manager (built ~3.7 s in, in place across the menus and the whole run, swapped for the
// diary's object when the death page opens), and +0xd2160, the session object behind F2. If a current-screen
// enum exists anywhere, it lives in one of those two objects.
// Second title (The Binding of Isaac: Afterbirth+ 1.7.9b, Repentance build 91c73fdd575061318d68886316afeac7):
// the pad's fields are gated on the old build and this NRO's layout differs, so the hunt starts over on the
// same instruments. Its round 1 is the wide net again -- every module's data segment, main's pointer objects
// and the deep first-come follow, whose build gate now names this build too. There are no pinned roots for
// it: the pins below are offsets in the OLD build's data segment and stay keyed to that build alone; a pin
// for this title gets derived from its own rounds, the way the old ones were.
// Round 5 (that title; the wide rounds' lesson): no census this time -- broad nets kept producing
// single-session false positives (the page-manager object's fields held through whole stretches of
// play and through neither diary), so that round was a single-position instrument: it chased the
// death flag's sister at +0x85a50. Its session closed the question -- the sister points at the
// death record's shell, an object born inside the first second after the first death and frozen
// from then on, its first word stepping once more at the second death and never stepping back:
// another event wearing state's clothes, no diary window in it.
// Round 6 (this round) starts from the code-level hunt in that title's unstripped binary instead:
// the diary page is a GameOver member embedded in the Game object at +0x27630, its first word a
// plain u32 state -- the page's Show writes 2, its Hide writes 0, and the game's own per-frame
// update gates the page's update on it -- and the Game instance pointer is a global, g_Game, at
// +0x87448 in this build's data segment. So the probe chases just two words through g_Game (the
// state section below): GOSTATE, the GameOver word, and PAUSESTATE, the same shape at the
// PauseScreen member's +0x1AE128, logged for the record. The spot chase is gone; the flag and
// the in-run flag (+0x85a20, +0x88d28) stay where they already are, timing anchors in the slot
// layer.
#include "hle.h"
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#define IP_OBJ 256          // bytes followed behind one pointer
#define IP_MAX_PTR 4096     // followed pointers, at most
#define IP_HOT_POLLS 40     // 40 polls at 4 Hz = 10 s of changing on every poll: a counter, named once

typedef struct {
    module_t *m;            // the loader's entry (its address is stable); the range is re-derived from it every poll
    uint8_t *lo;            // base + data_off at the last rebuild
    size_t len;             // the data segment's length then
    uint64_t *snap;         // the segment's last seen 8-byte slots
    uint32_t *streak;       // per slot: consecutive polls it changed on; ~0u once named a counter
    size_t nslots;
} ip_range_t;

typedef struct {
    size_t slot;            // the pointer's slot offset in main's data segment
    uint64_t target;        // the object it pointed at when last read
    int heap;               // the object lives in the guest heap (read through dm_guest_heap_read); else a module's data
    uint8_t snap[IP_OBJ];
} ip_ptr_t;

static ip_range_t *g_ranges; static int g_nranges;
static ip_ptr_t g_ptrs[IP_MAX_PTR]; static int g_nptrs, g_full_noted;
static uint8_t *g_ptr_seen;         // one bit per slot of main's data segment: the slot already has a table entry
static void ip_deep_reset(void);    // the round-3 deep follow's table (below): a range rebuild restarts it with its range

static uint64_t ip_ms(void) { return (now_ns() - g_t0_ns) / 1000000; }

// 1 when the len bytes at v are followable guest data; *heap then says heap (1) or a module's data segment (0).
static int ip_classify(uint64_t v, int *heap, size_t len) {
    if (!v || (v & 7) || v < 0x10000) return 0;
    uint64_t hb; size_t open;
    dm_guest_heap_range(&hb, &open);   // the heap's opened extent: an address in it is mapped and readable
    if (hb && v >= hb && v - hb <= open && open - (v - hb) >= len) { *heap = 1; return 1; }
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (!m->base || !m->data_off || m->size <= m->data_off) continue;
        uint64_t lo = (uint64_t)(uintptr_t)m->base + m->data_off, hi = (uint64_t)(uintptr_t)m->base + m->size;
        if (v >= lo && v <= hi && hi - v >= len) { *heap = 0; return 1; }
    }
    return 0;
}

// Read the followed object's bytes: 0 on success. A heap object can vanish between the classify and the read
// (the game shrank its heap); dm_guest_heap_read refuses the copy then instead of faulting.
static int ip_read_obj(const ip_ptr_t *p, uint8_t *out) {
    if (p->heap) return dm_guest_heap_read(p->target, out, IP_OBJ);
    memcpy(out, (const void *)(uintptr_t)p->target, IP_OBJ);   // a module's data: its mapping is process-lifetime
    return 0;
}

static ip_range_t *ip_main_range(void) {
    for (int i = 0; i < g_nranges; i++) if (!g_ranges[i].m->nro && !strcmp(g_ranges[i].m->name, "main")) return &g_ranges[i];
    return NULL;
}

static int ip_ranges_changed(void) {
    int n = 0;
    for (int i = 0; i < g_nmod; i++) { module_t *m = &g_mod[i]; if (m->base && m->data_off && m->size > m->data_off) n++; }
    if (n != g_nranges) return 1;
    int k = 0;
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (!m->base || !m->data_off || m->size <= m->data_off) continue;
        ip_range_t *r = &g_ranges[k++];
        if (r->m != m || r->lo != m->base + m->data_off || r->len != m->size - m->data_off) return 1;
    }
    return 0;
}

static void ip_ranges_rebuild(void) {
    ip_deep_reset();   // the deep table keys off one range's slots; a new layout restarts it
    for (int i = 0; i < g_nranges; i++) { free(g_ranges[i].snap); free(g_ranges[i].streak); }
    free(g_ranges); g_ranges = NULL; g_nranges = 0;
    free(g_ptr_seen); g_ptr_seen = NULL;
    g_nptrs = 0; g_full_noted = 0;   // the pointer table keys off main's data slots; a new layout restarts it
    int n = 0;
    for (int i = 0; i < g_nmod; i++) { module_t *m = &g_mod[i]; if (m->base && m->data_off && m->size > m->data_off) n++; }
    if (!n) return;
    g_ranges = calloc((size_t)n, sizeof *g_ranges);
    int k = 0;
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (!m->base || !m->data_off || m->size <= m->data_off) continue;
        ip_range_t *r = &g_ranges[k++];
        r->m = m; r->lo = m->base + m->data_off; r->len = m->size - m->data_off; r->nslots = r->len / 8;
        r->snap = malloc(r->nslots * sizeof(uint64_t));
        r->streak = calloc(r->nslots, sizeof(uint32_t));
        memcpy(r->snap, r->lo, r->nslots * sizeof(uint64_t));
        LOG("[isaacprobe] tracking mod=%s build=%s data off=0x%llx len=0x%zx (%zu slots)%s",
            m->name, m->build_id, (unsigned long long)m->data_off, r->len, r->nslots, m->nro ? " (nro)" : "");
    }
    g_nranges = k;
    ip_range_t *main = ip_main_range();
    if (main) g_ptr_seen = calloc((main->nslots + 7) / 8, 1);
}

// One poll over one module's data segment: log each changed slot, name the counters. Returns the changes logged.
static int ip_diff_range(ip_range_t *r, uint64_t t) {
    int changed = 0;
    const uint64_t *cur = (const uint64_t *)(const void *)r->lo;
    for (size_t s = 0; s < r->nslots; s++) {
        uint64_t v = cur[s];
        if (v == r->snap[s]) { if (r->streak[s] != ~0u) r->streak[s] = 0; continue; }
        uint64_t old = r->snap[s]; r->snap[s] = v;
        if (r->streak[s] == ~0u) continue;   // a named counter stays quiet (and out of the heartbeat's count)
        changed++;
        if (++r->streak[s] >= IP_HOT_POLLS) {
            r->streak[s] = ~0u;
            LOG("[isaacprobe] t=%llu counter mod=%s off=0x%zx (changed on every poll for 10 s; its changes are no longer logged)",
                (unsigned long long)t, r->m->name, s * 8);
            continue;
        }
        LOG("[isaacprobe] t=%llu mod=%s off=0x%zx old=0x%016llx new=0x%016llx",
            (unsigned long long)t, r->m->name, s * 8, (unsigned long long)old, (unsigned long long)v);
    }
    return changed;
}

static void ip_ptr_drop(int i) {
    size_t idx = g_ptrs[i].slot / 8;
    if (g_ptr_seen) g_ptr_seen[idx / 8] &= (uint8_t)~(1u << (idx % 8));
    g_ptrs[i] = g_ptrs[--g_nptrs];
}

// Follow the pointers main's data slots hold and are not followed yet (the table caps the count).
static void ip_ptr_scan_new(ip_range_t *main) {
    if (!g_ptr_seen) return;
    const uint64_t *cur = (const uint64_t *)(const void *)main->lo;
    for (size_t s = 0; s < main->nslots; s++) {
        if ((g_ptr_seen[s / 8] >> (s % 8)) & 1) continue;
        int heap; if (!ip_classify(cur[s], &heap, IP_OBJ)) continue;
        if (g_nptrs >= IP_MAX_PTR) {
            if (!g_full_noted) { g_full_noted = 1; LOG("[isaacprobe] pointer table full (%d); no further pointers are followed", IP_MAX_PTR); }
            return;
        }
        ip_ptr_t *p = &g_ptrs[g_nptrs];
        p->slot = s * 8; p->target = cur[s]; p->heap = heap;
        if (ip_read_obj(p, p->snap)) continue;   // unreadable between the classify and the read: a later poll retries it
        g_ptr_seen[s / 8] |= (uint8_t)(1u << (s % 8));
        g_nptrs++;
    }
}

// One poll over the followed objects: re-validate each (its slot may hold another object now, or none), then log changes.
static int ip_ptr_poll(ip_range_t *main, uint64_t t) {
    int changed = 0;
    const uint64_t *cur = (const uint64_t *)(const void *)main->lo;
    for (int i = 0; i < g_nptrs; i++) {
        ip_ptr_t *p = &g_ptrs[i];
        uint64_t v = cur[p->slot / 8];
        int heap;
        if (v != p->target || !ip_classify(v, &heap, IP_OBJ) || heap != p->heap) {   // the slot moved on, or the object died
            if (ip_classify(v, &heap, IP_OBJ)) {
                uint8_t buf[IP_OBJ];
                p->target = v; p->heap = heap;
                if (ip_read_obj(p, buf)) { ip_ptr_drop(i--); continue; }
                memcpy(p->snap, buf, IP_OBJ);
                LOG("[isaacprobe] t=%llu ptr mod=main slot=0x%zx now points at 0x%016llx",
                    (unsigned long long)t, p->slot, (unsigned long long)v);
            } else ip_ptr_drop(i--);
            continue;
        }
        uint8_t buf[IP_OBJ];
        if (ip_read_obj(p, buf)) { ip_ptr_drop(i--); continue; }   // died between the classify and the read
        for (size_t o = 0; o < IP_OBJ; o += 8) {
            uint64_t nv, ov;
            memcpy(&nv, buf + o, 8); memcpy(&ov, p->snap + o, 8);
            if (nv == ov) continue;
            changed++;
            LOG("[isaacprobe] t=%llu ptr mod=main slot=0x%zx objoff=0x%zx old=0x%016llx new=0x%016llx",
                (unsigned long long)t, p->slot, o, (unsigned long long)ov, (unsigned long long)nv);
        }
        memcpy(p->snap, buf, IP_OBJ);
    }
    return changed;
}

// ---- Round 3: deep follow (the pointers Repentance's own data segment holds) ----
// The pause and diary pages' state sits behind these, one pointer deeper than the layers above
// reach. The root range is picked by build ID (the build the pad's fields were found in): its
// slots are followed exactly like main's, at twice the object size and a lower cap, and every
// change is tagged with the root slot's offset in the data segment, so the analysis can name
// the root the way it named the fields (+0x884B8, +0xcc088, +0xd2160 are the expected ones).
#define IP_DEEP_OBJ 512         // bytes followed behind one deep pointer
#define IP_DEEP_MAX 1024        // followed deep pointers, at most
static const char *const k_isaacprobe_deep[] = { "8821c0a75afc814df5902fdc31e8d127",   // Repentance.nro, the build the page fields were found in
                                                 "91c73fdd575061318d68886316afeac7" };   // Repentance.nro of Afterbirth+ 1.7.9b (the second title): its round 1

typedef struct {
    size_t slot;            // the pointer's slot offset in the module's data segment (the log's root=)
    uint64_t target;        // the object it pointed at when last read
    int heap;               // the object lives in the guest heap (read through dm_guest_heap_read); else a module's data
    uint8_t *snap;          // the object's last seen bytes (IP_DEEP_OBJ)
    uint32_t *streak;       // per 8-byte field: consecutive polls it changed on; ~0u once named a counter
} ip_deep_t;

static ip_deep_t *g_deep; static int g_ndeep, g_deep_full_noted;
static uint8_t *g_deep_seen;        // one bit per slot of the module's data segment: the slot already has a table entry
static module_t *g_deep_mod;        // the module (and base) the table keys off; a change restarts the table
static uint8_t *g_deep_lo;

// ---- Round 4: the pinned roots (see the file's head) ----
// The root slot offsets are per build: a data segment's layout is its own build's, so a build with
// no row here (the 1.7.9b title, so far) simply runs without pins.
static const struct { const char *build_id; size_t a, b; } k_isaacprobe_pins[] = {
    { "8821c0a75afc814df5902fdc31e8d127", 0xcc0a8, 0xd2160 },   // the old build's overlay / menu manager and session roots
};
#define IP_PIN_MAX 2
typedef struct {
    size_t slot;            // the root slot's offset (the log's root=)
    uint64_t target;        // the object it points at now; 0 while it points at nothing followable
    int heap;               // as ip_deep_t's heap
    uint8_t snap[IP_DEEP_OBJ];
    uint32_t streak[IP_DEEP_OBJ / 8];   // per 8-byte field, as ip_deep_t's streak
} ip_pin_t;
static ip_pin_t g_pins[IP_PIN_MAX];
static int g_pins_on;       // the deep module's build has a pins row (set when its table starts, below)

// ---- Round 6: the state chase (see the file's head) ----
// Two u32 state words inside one object, keyed by build like the pins: the module's data segment
// holds g_Game, the pointer to the single Game object, and two of its embedded members keep
// their page state in their first word -- the GameOver member's word is 2 while the diary page
// shows and 0 while it is hidden (the game's own per-frame gate reads it), and the PauseScreen
// member's word is the same shape for the pause page. Both words are read through the pointer
// every poll and logged on change; the pointer's own moves are logged too, so a Game object
// that is created late, or recreated, is followed as it comes and goes.
static const struct { const char *build_id; size_t gslot, go_off, pause_off; } k_isaacprobe_state[] = {
    { "91c73fdd575061318d68886316afeac7", 0x87448, 0x27630, 0x1AE128 },   // 1.7.9b: g_Game, and the GameOver / PauseScreen members inside Game
};
typedef struct {
    size_t gslot;             // the g_Game slot's offset in the module's data segment
    size_t go_off, pause_off; // the two members' offsets inside the Game object
    uint64_t game;            // the Game pointer last seen; 0 while no Game object exists
    int have_go, have_pause;  // the words below hold a reading taken at the current pointer
    uint32_t go, pause;       // the state words last logged (the log's gostate / pausestate)
} ip_state_t;
static ip_state_t g_state;
static int g_state_on;       // the deep module's build has a state row (set when its table starts, below)

static int ip_is_pin(size_t slot) {
    if (!g_pins_on) return 0;
    for (size_t i = 0; i < sizeof g_pins / sizeof g_pins[0]; i++) if (g_pins[i].slot == slot) return 1;
    return 0;
}

static int ip_pins_active(void) {
    int n = 0;
    for (size_t i = 0; i < sizeof g_pins / sizeof g_pins[0]; i++) if (g_pins[i].target) n++;
    return n;
}

static ip_range_t *ip_deep_range(void) {
    for (int i = 0; i < g_nranges; i++)
        for (size_t j = 0; j < sizeof k_isaacprobe_deep / sizeof k_isaacprobe_deep[0]; j++)
            if (!strcmp(g_ranges[i].m->build_id, k_isaacprobe_deep[j])) return &g_ranges[i];
    return NULL;
}

static void ip_deep_reset(void) {
    if (g_deep) for (int i = 0; i < g_ndeep; i++) { free(g_deep[i].snap); free(g_deep[i].streak); }
    free(g_deep); g_deep = NULL; g_ndeep = 0; g_deep_full_noted = 0;
    free(g_deep_seen); g_deep_seen = NULL;
    g_deep_mod = NULL; g_deep_lo = NULL;
    for (size_t i = 0; i < sizeof g_pins / sizeof g_pins[0]; i++) memset(&g_pins[i], 0, sizeof g_pins[i]);
    g_pins_on = 0;   // re-armed (or not) from the deep module's build when its table starts
    memset(&g_state, 0, sizeof g_state);
    g_state_on = 0;   // the state chase re-arms the same way
}

// Read a followed deep object's bytes: 0 on success (the heap read refuses a vanished object).
static int ip_deep_read(const ip_deep_t *p, uint8_t *out) {
    if (p->heap) return dm_guest_heap_read(p->target, out, IP_DEEP_OBJ);
    memcpy(out, (const void *)(uintptr_t)p->target, IP_DEEP_OBJ);   // a module's data: its mapping is process-lifetime
    return 0;
}

static void ip_deep_drop(int i) {
    size_t idx = g_deep[i].slot / 8;
    if (g_deep_seen) g_deep_seen[idx / 8] &= (uint8_t)~(1u << (idx % 8));
    free(g_deep[i].snap); free(g_deep[i].streak);
    g_deep[i] = g_deep[--g_ndeep];
}

// Follow the pointers the root segment's slots hold and are not followed yet (the table caps the count).
static void ip_deep_scan_new(ip_range_t *r) {
    if (!g_deep_seen || !g_deep) return;
    const uint64_t *cur = (const uint64_t *)(const void *)r->lo;
    for (size_t s = 0; s < r->nslots; s++) {
        if ((g_deep_seen[s / 8] >> (s % 8)) & 1) continue;
        if (ip_is_pin(s * 8)) continue;   // the pinned roots are followed separately, always
        int heap; if (!ip_classify(cur[s], &heap, IP_DEEP_OBJ)) continue;
        if (g_ndeep >= IP_DEEP_MAX) {
            if (!g_deep_full_noted) { g_deep_full_noted = 1; LOG("[isaacprobe] deep pointer table full (%d); no further pointers are followed", IP_DEEP_MAX); }
            return;
        }
        ip_deep_t *p = &g_deep[g_ndeep];
        p->slot = s * 8; p->target = cur[s]; p->heap = heap;
        p->snap = malloc(IP_DEEP_OBJ); p->streak = calloc(IP_DEEP_OBJ / 8, sizeof(uint32_t));
        if (ip_deep_read(p, p->snap)) { free(p->snap); free(p->streak); p->snap = NULL; p->streak = NULL; continue; }   // unreadable between the classify and the read: a later poll retries it
        g_deep_seen[s / 8] |= (uint8_t)(1u << (s % 8));
        g_ndeep++;
    }
}

// Diff one followed object's fresh bytes against its snapshot, logging each changed field (a field
// that changes on every poll for 10 s is named a counter once, then left quiet). Returns the changes.
static int ip_deep_diff(const char *modname, size_t slot, uint8_t *snap, uint32_t *streak, const uint8_t *buf, uint64_t t) {
    int changed = 0;
    for (size_t o = 0; o < IP_DEEP_OBJ; o += 8) {
        uint64_t nv, ov;
        memcpy(&nv, buf + o, 8); memcpy(&ov, snap + o, 8);
        if (nv == ov) { if (streak[o / 8] != ~0u) streak[o / 8] = 0; continue; }
        memcpy(snap + o, &nv, 8);
        if (streak[o / 8] == ~0u) continue;   // a named counter stays quiet (and out of the heartbeat's count)
        changed++;
        if (++streak[o / 8] >= IP_HOT_POLLS) {
            streak[o / 8] = ~0u;
            LOG("[isaacprobe] t=%llu counter deep mod=%s root=0x%zx objoff=0x%zx (changed on every poll for 10 s; its changes are no longer logged)",
                (unsigned long long)t, modname, slot, o);
            continue;
        }
        LOG("[isaacprobe] t=%llu deep mod=%s root=0x%zx objoff=0x%zx old=0x%016llx new=0x%016llx",
            (unsigned long long)t, modname, slot, o, (unsigned long long)ov, (unsigned long long)nv);
    }
    return changed;
}

// One poll over the followed deep objects: re-validate each, then log changes (counters named once, then quiet).
static int ip_deep_poll(ip_range_t *r, uint64_t t) {
    int changed = 0;
    const uint64_t *cur = (const uint64_t *)(const void *)r->lo;
    uint8_t buf[IP_DEEP_OBJ];
    for (int i = 0; i < g_ndeep; i++) {
        ip_deep_t *p = &g_deep[i];
        uint64_t v = cur[p->slot / 8];
        int heap;
        if (v != p->target || !ip_classify(v, &heap, IP_DEEP_OBJ) || heap != p->heap) {   // the slot moved on, or the object died
            if (ip_classify(v, &heap, IP_DEEP_OBJ)) {
                p->target = v; p->heap = heap;
                if (ip_deep_read(p, buf)) { ip_deep_drop(i--); continue; }
                memcpy(p->snap, buf, IP_DEEP_OBJ); memset(p->streak, 0, IP_DEEP_OBJ / 8 * sizeof(uint32_t));
                LOG("[isaacprobe] t=%llu deep mod=%s root=0x%zx now points at 0x%016llx",
                    (unsigned long long)t, r->m->name, p->slot, (unsigned long long)v);
            } else ip_deep_drop(i--);
            continue;
        }
        if (ip_deep_read(p, buf)) { ip_deep_drop(i--); continue; }   // died between the classify and the read
        changed += ip_deep_diff(r->m->name, p->slot, p->snap, p->streak, buf, t);
    }
    return changed;
}

// Read a pinned root's object: 0 on success (the heap read refuses a vanished object).
static int ip_pin_read(const ip_pin_t *p, uint8_t *out) {
    if (p->heap) return dm_guest_heap_read(p->target, out, IP_DEEP_OBJ);
    memcpy(out, (const void *)(uintptr_t)p->target, IP_DEEP_OBJ);   // a module's data: its mapping is process-lifetime
    return 0;
}

// One poll over the pinned roots: re-resolve each root's target -- a swap adopts the new object,
// restarts its diff and is logged with the usual deep tag; a root pointing at nothing followable
// idles (never dropped) until it points again -- then diff the current objects.
static int ip_deep_pin_poll(ip_range_t *r, uint64_t t) {
    if (!g_pins_on) return 0;   // this build has no pinned roots: its slots are not the old build's
    int changed = 0;
    const uint64_t *cur = (const uint64_t *)(const void *)r->lo;
    uint8_t buf[IP_DEEP_OBJ];
    for (size_t i = 0; i < sizeof g_pins / sizeof g_pins[0]; i++) {
        ip_pin_t *p = &g_pins[i];
        if (p->slot + 8 > r->len) continue;
        uint64_t v = cur[p->slot / 8];
        int heap;
        if (v != p->target) {
            if (ip_classify(v, &heap, IP_DEEP_OBJ)) {
                p->target = v; p->heap = heap;
                if (ip_pin_read(p, buf)) { p->target = 0; continue; }   // died between the classify and the read: idle, a later poll retries
                memcpy(p->snap, buf, IP_DEEP_OBJ); memset(p->streak, 0, sizeof p->streak);
                LOG("[isaacprobe] t=%llu deep mod=%s root=0x%zx now points at 0x%016llx",
                    (unsigned long long)t, r->m->name, p->slot, (unsigned long long)v);
            } else p->target = 0;   // nothing followable there now: 0, or a pointer too near a range's end to hold an object
            continue;
        }
        if (!p->target) continue;
        if (ip_pin_read(p, buf)) { p->target = 0; continue; }   // the object died under us: idle until the root points again
        changed += ip_deep_diff(r->m->name, p->slot, p->snap, p->streak, buf, t);
    }
    return changed;
}

// Read one state word behind the Game pointer: 0 on success. The word's address is classified
// first (the pointer may be stale for a poll around the object's birth or death), and a heap read
// refuses a vanished object instead of faulting; the word is never written, only read.
static int ip_state_read(uint64_t addr, uint32_t *out) {
    int heap;
    if (!ip_classify(addr, &heap, 4)) return 1;
    if (heap) { uint8_t b[4]; if (dm_guest_heap_read(addr, b, 4)) return 1; memcpy(out, b, 4); return 0; }
    memcpy(out, (const void *)(uintptr_t)addr, 4);   // a module's data: its mapping is process-lifetime
    return 0;
}

// Poll one state word behind the current Game pointer: log its first reading at this pointer and
// every change after. Returns the changes logged.
static int ip_state_word(ip_range_t *r, uint64_t t, const char *tag, size_t off, int *have, uint32_t *last) {
    uint32_t v;
    if (ip_state_read(g_state.game + off, &v)) return 0;   // unreadable this poll (the object is being born or freed): a later poll retries
    if (*have && v == *last) return 0;
    if (*have) LOG("[isaacprobe] t=%llu %s mod=%s old=%u new=%u",
                   (unsigned long long)t, tag, r->m->name, *last, v);
    else LOG("[isaacprobe] t=%llu %s mod=%s value=%u (first read, g_Game=0x%016llx)",
             (unsigned long long)t, tag, r->m->name, v, (unsigned long long)g_state.game);
    *have = 1; *last = v;
    return 1;
}

// One poll over the chased state: follow g_Game itself -- logged as it appears, moves or goes,
// with the words' readings restarted at each new pointer -- then the two state words behind it.
static int ip_state_poll(ip_range_t *r, uint64_t t) {
    if (!g_state_on) return 0;   // this build has no chased state
    ip_state_t *p = &g_state;
    if (p->gslot + 8 > r->len) return 0;
    const uint64_t *cur = (const uint64_t *)(const void *)r->lo;
    int changed = 0;
    uint64_t v = cur[p->gslot / 8];
    if (v != p->game) {
        LOG("[isaacprobe] t=%llu state mod=%s g_Game old=0x%016llx new=0x%016llx",
            (unsigned long long)t, r->m->name, (unsigned long long)p->game, (unsigned long long)v);
        p->game = v; p->have_go = 0; p->have_pause = 0;
        changed++;
    }
    if (!p->game) return changed;   // no Game object yet: the words behind the pointer do not exist
    changed += ip_state_word(r, t, "gostate", p->go_off, &p->have_go, &p->go);
    changed += ip_state_word(r, t, "pausestate", p->pause_off, &p->have_pause, &p->pause);
    return changed;
}

static void *isaacprobe_main(void *arg) {
    (void)arg;
    LOG("[isaacprobe] TEMPORARY page-state probe on (DM_ISAAC_PROBE=1): read-only, polling module data segments at 4 Hz");
    int poll = 0, changed10 = 0;
    for (;;) {
        if (ip_ranges_changed()) ip_ranges_rebuild();
        uint64_t t = ip_ms();
        int changed = 0;
        for (int i = 0; i < g_nranges; i++) changed += ip_diff_range(&g_ranges[i], t);
        ip_range_t *main = ip_main_range();
        if (main) { ip_ptr_scan_new(main); changed += ip_ptr_poll(main, t); }
        ip_range_t *deep = ip_deep_range();
        if (deep) {
            if (g_deep_mod != deep->m || g_deep_lo != deep->lo) {   // a new root range (or the first): the table restarts on it
                ip_deep_reset();
                g_deep_mod = deep->m; g_deep_lo = deep->lo;
                g_deep = calloc(IP_DEEP_MAX, sizeof *g_deep);
                if (deep->nslots) g_deep_seen = calloc((deep->nslots + 7) / 8, 1);
                LOG("[isaacprobe] deep-following the pointers in mod=%s's data segment (build %s): %d-byte objects, at most %d",
                    deep->m->name, deep->m->build_id, IP_DEEP_OBJ, IP_DEEP_MAX);
                for (size_t j = 0; j < sizeof k_isaacprobe_pins / sizeof k_isaacprobe_pins[0]; j++) {
                    if (strcmp(deep->m->build_id, k_isaacprobe_pins[j].build_id)) continue;
                    g_pins[0].slot = k_isaacprobe_pins[j].a; g_pins[1].slot = k_isaacprobe_pins[j].b; g_pins_on = 1;
                    LOG("[isaacprobe] deep-pinned roots +0x%zx and +0x%zx: followed always, outside the table",
                        g_pins[0].slot, g_pins[1].slot);
                    break;
                }
                if (!g_pins_on) LOG("[isaacprobe] no pinned roots for build %s: this round runs the wide net only", deep->m->build_id);
                for (size_t j = 0; j < sizeof k_isaacprobe_state / sizeof k_isaacprobe_state[0]; j++) {
                    if (strcmp(deep->m->build_id, k_isaacprobe_state[j].build_id)) continue;
                    g_state.gslot = k_isaacprobe_state[j].gslot; g_state.go_off = k_isaacprobe_state[j].go_off; g_state.pause_off = k_isaacprobe_state[j].pause_off; g_state_on = 1;
                    LOG("[isaacprobe] state-chasing g_Game at +0x%zx: the GameOver state word at Game+0x%zx and the PauseScreen word at Game+0x%zx, logged on change",
                        g_state.gslot, g_state.go_off, g_state.pause_off);
                    break;
                }
            }
            ip_deep_scan_new(deep); changed += ip_deep_poll(deep, t); changed += ip_deep_pin_poll(deep, t); changed += ip_state_poll(deep, t);
        }
        changed10 += changed;
        if (++poll % 40 == 0) {
            LOG("[isaacprobe] heartbeat t=%llu changed=%d slots in the last 10 s, %d pointers followed, %d ranges tracked, %d deep pointers followed",
                (unsigned long long)t, changed10, g_nptrs, g_nranges, g_ndeep + ip_pins_active());
            changed10 = 0;
        }
        struct timespec ts = { 0, 250000000 }; nanosleep(&ts, NULL);
    }
    return NULL;
}

void dm_isaacprobe_init(void) {
    const char *e = getenv("DM_ISAAC_PROBE");   // the probe runs only when a build asks for it (the probe build's bundled env file sets it)
    if (!e || !atoi(e)) return;
    pthread_t th;
    if (!pthread_create(&th, NULL, isaacprobe_main, NULL)) pthread_detach(th);
    else LOG("[RED] isaacprobe: cannot start the watcher thread");
}
