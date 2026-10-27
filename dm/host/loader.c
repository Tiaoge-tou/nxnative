// Multi-module loading (playing the role of Horizon's rtld): mapping, claiming thread slots, gate registration, cross-module relocation, take-over by name, segment permissions.
// The code area (original text and patch area) is set to read-only+execute as soon as it is copied in, and from then on the loader only writes data: on iOS these two blocks must be embedded as is as signed code segments.
#include "dm.h"
#include <TargetConditionals.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include "hle.h"

module_t g_mod[MAX_MOD];
int g_nmod;
// Stable module addresses live in g_mod; lookup order follows activation, including unload/reload.
static module_t *g_loaded[MAX_MOD]; static int g_nloaded;
static pthread_rwlock_t g_modules_mu = PTHREAD_RWLOCK_INITIALIZER;
pthread_key_t g_key18, g_keytls, g_keytlr, g_keygate;
enum { KEY_K18, KEY_KTLS, KEY_KTLR, KEY_KGATE, KEY_N };

uint64_t resolve_import(module_t *m, const char *name);
int hle_implements(const char *name);
void gate_register(uint64_t ret_addr, const char *kind, int arg, uint64_t orig);

static pthread_key_t key_value(unsigned i) {
    switch (i) {
    case KEY_K18: return g_key18; case KEY_KTLS: return g_keytls; case KEY_KTLR: return g_keytlr;
    default: return g_keygate;
    }
}
static void create_keys(void) {
    if (pthread_key_create(&g_key18, NULL) || pthread_key_create(&g_keytls, NULL) ||
        pthread_key_create(&g_keytlr, NULL) || pthread_key_create(&g_keygate, NULL)) die("cannot create the host key");
    LOG("key numbers K18=%lu KTLS=%lu KTLR=%lu KGATE=%lu", g_key18, g_keytls, g_keytlr, g_keygate);
}

// K slot check: the pthread TSD layout is fixed, slot = tpidrro_el0 + 8*key
static void tsd_check(void) {
    pthread_setspecific(g_key18, (void *)0x1234);
    uint64_t base; __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(base));
    uint64_t off = *(uint64_t *)(g_mod[0].base + g_mod[0].key_page_off + g_mod[0].key_idx[KEY_K18] * 8);
    if (((uint64_t *)(base & ~7ull))[off / 8] != 0x1234) die("TSD layout mismatch");
    pthread_setspecific(g_key18, 0);
}

static void build_symhash(module_t *m);
static void parse_dynamic(module_t *m) {
    uint32_t mod0 = *(uint32_t *)(m->base + 4);
    if (memcmp(m->base + mod0, "MOD0", 4)) die("%s: no MOD0", m->name);
    m->dyn = (const Elf64_Dyn *)(m->base + mod0 + *(int32_t *)(m->base + mod0 + 4));
    for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) switch (d->d_tag) {
        case DT_SYMTAB: m->symtab = (const Elf64_Sym *)(m->base + d->d_un.d_ptr); break;
        case DT_STRTAB: m->strtab = (const char *)(m->base + d->d_un.d_ptr); break;
        case DT_INIT: m->init = d->d_un.d_ptr; break;
        case DT_FINI: m->fini = d->d_un.d_ptr; break;
        case DT_INIT_ARRAY: m->init_array = d->d_un.d_ptr; break;
        case DT_INIT_ARRAYSZ: m->init_arraysz = d->d_un.d_val; break;
    }
    m->nsym = (unsigned)(((const uint8_t *)m->strtab - (const uint8_t *)m->symtab) / sizeof(Elf64_Sym));
    build_symhash(m);
}

static void *module_sym_linear(module_t *m, const char *name) {
    for (unsigned i = 1; i < m->nsym; i++) {
        const Elf64_Sym *s = &m->symtab[i];
        if (s->st_shndx && !strcmp(m->strtab + s->st_name, name)) return m->base + s->st_value;
    }
    return NULL;
}
// Symbol name hash table: inserted in ascending index order, not overwritten if the same name is already there ⇒ lookup results are identical, entry by entry, to a linear scan (the first defined symbol with that name).
// Of the 91–99 ms of ① host loading, relocation + forced take-over took 77–86 ms, mainly because every by-name relocation scanned the symbol tables of two modules linearly
static uint32_t sym_hash(const char *s) { uint32_t h = 2166136261u; while (*s) h = (h ^ (uint8_t)*s++) * 16777619u; return h; }
static void build_symhash(module_t *m) {
    unsigned cap = 16; while (cap < m->nsym * 2) cap <<= 1;
    m->symh = calloc(cap, sizeof *m->symh); m->symh_mask = cap - 1;
    for (unsigned i = 1; i < m->nsym; i++) {
        const Elf64_Sym *s = &m->symtab[i]; if (!s->st_shndx) continue;
        const char *nm = m->strtab + s->st_name;
        for (unsigned j = sym_hash(nm) & m->symh_mask;; j = (j + 1) & m->symh_mask) {
            if (!m->symh[j]) { m->symh[j] = i; break; }
            if (!strcmp(m->strtab + m->symtab[m->symh[j]].st_name, nm)) break;   // The same name already exists with a smaller index: keep that one
        }
    }
}
static unsigned long g_symchk_n, g_symchk_bad;
void *module_sym(module_t *m, const char *name) {
    unsigned long nq; (void)nq;
    if (!m->symh) return module_sym_linear(m, name);
    void *r = NULL;
    for (unsigned j = sym_hash(name) & m->symh_mask; m->symh[j]; j = (j + 1) & m->symh_mask) {
        const Elf64_Sym *s = &m->symtab[m->symh[j]];
        if (!strcmp(m->strtab + s->st_name, name)) { r = m->base + s->st_value; break; }
    }
    static int chk = -1; if (chk < 0) chk = getenv("DM_SYMCHECK") != NULL;
    if (chk) { void *l = module_sym_linear(m, name); g_symchk_n++; nq = g_symchk_n;
               if (l != r) { g_symchk_bad++; LOG("[RED] DM_SYMCHECK: %s in %s hash %p ≠ linear %p", name, m->name, r, l); } }
    return r;
}
static void *loaded_sym(const char *name) {   // caller holds g_modules_mu, or is doing startup relocation before guest threads run
    for (int i = 0; i < g_nloaded; i++) { void *p = module_sym(g_loaded[i], name); if (p) return p; }
    return NULL;
}
void *guest_sym(const char *name) {
    pthread_rwlock_rdlock(&g_modules_mu); void *p = loaded_sym(name); pthread_rwlock_unlock(&g_modules_mu);
    return p;
}
// For modules with the patch area before the base (patch_off < 0) addresses in the patch area count too, as for modules whose patch area follows the image (crash reports, the GC pause's "in guest code" test)
module_t *module_of(const void *p) {
    for (int i = 0; i < g_nmod; i++) {
        const uint8_t *b = g_mod[i].base;
        if ((const uint8_t *)p >= b && (const uint8_t *)p < b + g_mod[i].size) return &g_mod[i];
        if (g_mod[i].patch_off < 0 && (const uint8_t *)p >= b + g_mod[i].patch_off && (const uint8_t *)p < b + g_mod[i].patch_off + g_mod[i].patch_len) return &g_mod[i];
    }
    return NULL;
}

// Whether main imports a symbol whose name starts with prefix (an undefined dynamic symbol: one main calls but another module defines), for behaviour that follows what the game uses
int dm_main_imports(const char *prefix) {
    size_t n = strlen(prefix);
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) {
        module_t *m = &g_mod[i];
        for (unsigned k = 1; k < m->nsym; k++) if (!m->symtab[k].st_shndx && !strncmp(m->strtab + m->symtab[k].st_name, prefix, n)) return 1;
    }
    return 0;
}

// SDK major version, from the version string the SDK's libraries keep in the sdk module's read-only data ("NintendoSDK_nnSdk-10_4_0"; SDK 12 spells it NintendoSdk_).
// Behaviour that follows the SDK version is decided by it (the NVN API version, the shared-font layout), not by the game profile. 0 = no sdk module or no version string
int dm_sdk_major(void) {
    static int major = -1;
    if (major >= 0) return major;
    major = 0;
    for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "sdk")) {
        const char *b = (const char *)g_mod[i].base + g_mod[i].ro_off, *e = (const char *)g_mod[i].base + g_mod[i].key_page_off;   // read-only data, data and bss
        for (const char *p = b; (p = memmem(p, (size_t)(e - p), "_nnSdk-", 7)); p += 7)
            if (p - b >= 11 && !strncasecmp(p - 11, "NintendoSDK", 11) && p[7] >= '0' && p[7] <= '9') {
                major = atoi(p + 7); LOG("sdk: NintendoSDK nnSdk-%.12s (major %d)", p + 7, major); break; }
    }
    if (!major) LOG("[RED] sdk: no SDK version string in the sdk module; SDK-dependent behaviour takes the newer SDKs' side");
    return major;
}

// Cross-module symbol resolution: first look for a definition in the loaded modules, and only if not found hand over to HLE / stubs
static uint64_t resolve_sym(module_t *m, const char *name) {
    void *p = loaded_sym(name); if (p) return (uint64_t)p;
    return resolve_import(m, name);
}

// Forced take-over table (hle.h HLE_FORCE, the __DATA,swforce section): a hit overrides the definition inside the module
static const hle_force_ent *g_force; static unsigned g_nforce; static unsigned *g_force_hits;
static unsigned *g_fidx, g_fmask;   // name hash over the table: force_lookup runs for every named relocation, and each lookup used to strcmp its way through all 722 entries (the swhle table's scan is hashed the same way, hle.c)
static void force_init(void) {
    unsigned long sz; g_force = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &sz);
    g_nforce = g_force ? (unsigned)(sz / sizeof *g_force) : 0;
    g_force_hits = calloc(g_nforce + 1, sizeof *g_force_hits);
    unsigned cap = 16; while (cap < g_nforce * 2) cap <<= 1;
    g_fidx = calloc(cap, sizeof *g_fidx); g_fmask = cap - 1;
    for (unsigned i = 0; i < g_nforce; i++)   // insertion doubles as the duplicate check (a wrong list must still fail loudly, at once)
        for (unsigned j = sym_hash(g_force[i].name) & g_fmask;; j = (j + 1) & g_fmask) {
            if (!g_fidx[j]) { g_fidx[j] = i + 1; break; }
            if (!strcmp(g_force[g_fidx[j] - 1].name, g_force[i].name)) die("duplicate entry in the forced takeover list: %s", g_force[i].name);
        }
}
static void *force_lookup(const char *name) {
    if (!g_fmask) return NULL;
    for (unsigned j = sym_hash(name) & g_fmask; g_fidx[j]; j = (j + 1) & g_fmask) {
        unsigned i = g_fidx[j] - 1;
        if (!strcmp(g_force[i].name, name)) {
            if (!g_force_hits[i]++ && g_flag.imports) LOG("force %s  (%s)", name, g_force[i].why);
            void *hlecount_wrap(const char *, const char *, void *); return hlecount_wrap("FORCE", name, g_force[i].fn);   // A counting stub when DM_HLECOUNT is set
        }
    }
    return NULL;
}
// Generic host: the list serves several games, so entries a game does not reference are only noted; with DM_FORCE_STRICT=1 it still fails loudly (for checking a mistyped list)
static void force_check(void) {
    unsigned unused = 0; int strict = getenv("DM_FORCE_STRICT") != NULL;
    for (unsigned i = 0; i < g_nforce; i++)
        if (!g_force_hits[i]) { if (strict || g_flag.imports) LOG("forced takeover entry with no reference at all: %s", g_force[i].name); unused++; }
    if (unused && strict) die("forced takeover list is wrong");
    LOG("force: %u entries hit, %u not referenced by this game", g_nforce - unused, unused);
}

static module_t *g_fill_mod;   // the module whose fixups declare host-filled display-mode size words (HOST_FILL_D / HOST_FILL_H), filled in dm_fps_state_apply
// Read the rewriter table header (segment boundaries, slot numbers); any row beyond the header means an old-format build output (code modified at load time), which is rejected
static void read_layout(module_t *m, const char *dir) {
    char path[1024]; snprintf(path, sizeof path, "%s/%s.fixups.tsv", dir, m->name);
    FILE *f = fopen(path, "r");
    if (!f) die("open %s", path);
    static const char *kn[KEY_N] = {"K18", "KTLS", "KTLR", "KGATE"};
    char line[256], key[32]; unsigned long v; unsigned seen = 0;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "# %31s %lx", key, &v) != 2) die("%s: the output comes from an old rewriter; rewrite the modules again with dm/tools/patch_nso.py", path);
        if (!strcmp(key, "PATCH_OFF")) m->patch_off = strtoll(line + 2 + strlen(key), NULL, 16);   // may be negative (patch area before the base)
        else if (!strcmp(key, "IMAGE_SIZE")) m->image_size = v;
        else if (!strcmp(key, "FILE_IMAGE_LEN")) m->file_image_len = v;
        else if (!strcmp(key, "KEY_PAGE_OFF")) m->key_page_off = v;
        else if (!strcmp(key, "KEY_PAGE_SIZE")) m->key_page_size = v;
        else if (!strcmp(key, "TEXT_END")) m->text_end = v;
        else if (!strcmp(key, "RO_OFF")) m->ro_off = v;
        else if (!strcmp(key, "DATA_OFF")) m->data_off = v;
        else if (!strcmp(key, "FPS_STATE_OFF")) m->fps_state_off = v;
        else if (!strcmp(key, "HOST_FILL_D")) { m->fill_d_off = v; g_fill_mod = m; }
        else if (!strcmp(key, "HOST_FILL_H")) { m->fill_h_off = v; g_fill_mod = m; }
        else if (!strcmp(key, "HOST_FILL_W")) { m->fill_w_off = v; g_fill_mod = m; }
        else if (!strcmp(key, "BUILD_ID")) sscanf(line, "# %*s %32s", m->build_id);
        else for (int k = 0; k < KEY_N; k++) {
            size_t n = strlen(kn[k]);
            if (!strncmp(key, "KEY_", 4) && !strncmp(key + 4, kn[k], n) && !strcmp(key + 4 + n, "_IDX")) {
                m->key_idx[k] = (unsigned)strtoul(strrchr(line, '\t') + 1, 0, 10); seen |= 1u << k;
            }
        }
    }
    fclose(f);
    if (!m->patch_off || m->key_page_off % 0x4000 || m->key_page_size != 0x4000 || seen != (1u << KEY_N) - 1)
        die("%s: the output comes from an old rewriter; rewrite the modules again with dm/tools/patch_nso.py", path);
    if (m->patch_off < 0 && (!m->image_size || !m->file_image_len || m->file_image_len % 0x4000 || m->patch_off % 0x4000 || m->key_page_off + m->key_page_size > m->image_size))
        die("%s: patch area before the base, but IMAGE_SIZE / FILE_IMAGE_LEN missing or wrong", path);
}

// Frame step state (the page after the key page, read-write; layout in patch_nso.py FRAME_STEP): the rewriter's stubs step the game by the host's whole vsyncs capped at this
// target, 0 = the game's own interval logic. The profile's fps_target, overridden by DM_FPS_TARGET (0, 30 or 60); the graphics layer decides the steps and paces presents
// (hle_nvn.c fstep_tick)
uint8_t *dm_fps_state;
static const char *g_fps_mod;   // the module holding the state page (for the log)
static void install_fps_state(module_t *m) {
    if (m->fps_state_off + 0x48 > m->size || m->fps_state_off < m->key_page_off + m->key_page_size) die("%s: frame step state page out of range", m->name);
    dm_fps_state = m->base + m->fps_state_off; g_fps_mod = m->name;
}
// The settings in the state page, written when the game starts (main.c, after host loading): on iOS the loading runs at app launch, before the launcher has set DM_FPS_TARGET and
// DM_RENDER_SCALE (Launcher.swift), and nothing reads the page before the game runs
void dm_fps_state_apply(void) {
    if (!dm_fps_state) return;
    const char *e = getenv("DM_FPS_TARGET"); int t = e ? atoi(e) : DM_GAME_FPS_TARGET;
    if (t != 0 && t != 30 && t != 60) { LOG("[RED] DM_FPS_TARGET=%s: must be 0, 30 or 60; using the game's own frame step", e); t = 0; }
    float f = (float)t; memcpy(dm_fps_state, &f, sizeof f);
    // Render scale of the 3D views (the stubs at Tears of the Kingdom's main+0xd5cc0, Breath of the Wild's main+0x1266880): 1.0 keeps the game's own size and dynamic resolution;
    // another factor fixes the size at that fraction (DM_RENDER_SCALE, 0.5 to 1.0). Independent of the frame step: written at target 0 too
    const char *rs = getenv("DM_RENDER_SCALE"); float sc = 1.0f;
    if (rs) { char *end; sc = strtof(rs, &end); if (end == rs || *end || !(sc >= 0.5f && sc <= 1.0f)) { LOG("[RED] DM_RENDER_SCALE=%s: must be 0.5 to 1.0; keeping the game's size", rs); sc = 1.0f; } else LOG("%s: 3D views rendered at %.2f of the game's size (DM_RENDER_SCALE)", g_fps_mod, sc); }
    memcpy(dm_fps_state + 0x10, &sc, sizeof sc);
    // Render size (state +0x38, a packed u64 width | height << 32): the size the build's stub at its baked size constant renders at
    // (Hades II's render pair), in place of a width baked when the IPA was made, so one build fits every screen.
    // The front end measures the screen and sets DM_RENDER_WIDTH (front_ios.m); the height is the docked 1080 those sizes are designed
    // around. Without the variable the cell takes 2344, the width the wide builds baked until now, so behaviour is unchanged.
    // DM_RENDER_HEIGHT overrides the height word on its own (the launcher's lowered-resolution frame-rate tier, front_ios.m sets
    // it beside the lowered width): the build's height stubs read the packed high word, as its width stubs read the low one
    const char *rht = getenv("DM_RENDER_HEIGHT"); long ht = rht ? strtol(rht, NULL, 10) : 0;
    if (rht && (ht < 240 || ht > 2160 || ht % 2)) { LOG("[RED] DM_RENDER_HEIGHT=%s: an even value between 240 and 2160 expected; using 1080", rht); ht = 0; }
    const char *rw = getenv("DM_RENDER_WIDTH"); long w = rw ? strtol(rw, NULL, 10) : 0;
    if (rw && (w < 320 || w > 16384 || w % 8)) { LOG("[RED] DM_RENDER_WIDTH=%s: a multiple of 8 between 320 and 16384 expected; using 2344", rw); w = 0; }
    // On a screen narrower than 16:9 the measured docked width (an iPad's 1552 or 1640 at the 1080 height) is
    // NOT served: a guest whose docked composition is laid out for the stock 1920x1080 (Silksong) derives a
    // 16:10 sub-rect from the narrower width and letterboxes it inside the frame, the never-cleared strips
    // outside it showing as coloured bands -- and a mirrored ghost strip under sprites was only ever seen on
    // those sub-rect paths. The stock pair is served instead and the front end scales it to the screen, as
    // it does the handheld frame on such a screen. A height override (the lowered-resolution tier) opts
    // out: its widths are the tier's own
    long deff = (!ht && w && w < 1920) ? 1920 : (w ? w : 2344);
    uint64_t rpair = (uint64_t)(uint32_t)deff | (uint64_t)(uint32_t)(ht ? ht : 1080) << 32; memcpy(dm_fps_state + 0x38, &rpair, sizeof rpair);
    if (rw || rht) LOG("%s: render size %ldx%ld (DM_RENDER_WIDTH / DM_RENDER_HEIGHT)", g_fps_mod, deff, ht ? ht : 1080);
    // Render size at the handheld height (state +0x40, a packed u64 width | 720 << 32): the same routing for a build whose
    // handheld sizes read a state cell too (Silksong's size getter default). The front end sets DM_RENDER_WIDTH_HD beside
    // DM_RENDER_WIDTH; without it the cell takes 1280, the handheld width every build baked until now. On a screen
    // narrower than the stock handheld frame the cell is held at 1280 as well: the guest's handheld composition is
    // laid out for the stock frame and cannot shrink with the screen (told 1032 on an iPad, it lays its HUD canvas
    // out for a wider frame and the edges fall off the picture), so it composes the stock frame and the front end
    // scales that to the screen -- the slight stretch is the price, and it is what builds before the host fills
    // did (build #50 on an iPad at 2360x1640). A guest with a resolution record is excepted (serve_narrow, below)
    const char *rh = getenv("DM_RENDER_WIDTH_HD"); long hw = rh ? strtol(rh, NULL, 10) : 0;
    if (rh && (hw < 320 || hw > 16384 || hw % 8)) { LOG("[RED] DM_RENDER_WIDTH_HD=%s: a multiple of 8 between 320 and 16384 expected; using 1280", rh); hw = 0; }
    // A guest with a resolution record (HOST_FILL_W) is excepted from the narrow hold: its composition
    // follows the record's world pair, so it is served the screen's own sizes on every channel at once and
    // the record's world pair is set to the same aspect in the fill below -- the wide screen's arrangement,
    // under which the display sizes and the world pair agree. The decision is published for the one size
    // channel that lives elsewhere, nn::oe's default-resolution answer (hle_oe.c)
    int serve_narrow = hw && hw < 1280 && g_fill_mod && g_fill_mod->fill_w_off;
    if (serve_narrow) setenv("DM_SERVE_NARROW", "1", 1);
    long heff = (hw > 1280 || serve_narrow) ? hw : 1280;
    uint64_t hpair = (uint64_t)(uint32_t)heff | 720ULL << 32; memcpy(dm_fps_state + 0x40, &hpair, sizeof hpair);
    if (rh) LOG("%s: render size %ldx720 (DM_RENDER_WIDTH_HD)", g_fps_mod, heff);
    // Host-filled display-mode size words (fixups HOST_FILL_D / HOST_FILL_H, the module is the state page's own): a guest whose
    // mode sizes live in a data template rather than in code (Silksong's screen-state ctor template: handheld width at +0,
    // docked at +8) takes its reported display size -- and with it the present crop -- from that template, so a width baked
    // there outlives every stub at the code sites and disagrees with the textures on any screen but the one it was baked for.
    // The loader writes the screen's own widths over the baked ones here, before the guest starts and copies the template.
    // With a height override (DM_RENDER_HEIGHT) the template's docked height word follows too (the word after the docked
    // width): the guest reads its display height from the same template, and a lowered width with the stock height would
    // report a size nothing renders at. The handheld height stays 720, as the handheld pair does.
    // The handheld word follows the narrow rule of the state page's handheld cell above: on a screen no wider
    // than the stock frame it is left at the baked 1280, so the reported size, the crop and the frame the
    // guest composes stay the stock one and the front end's scale to the screen is the only transform (the
    // serve_narrow exception fills the screen's own width here too). The
    // docked word is always filled: a baked docked width wider than the swapchain the stubs sized drops
    // every present (an iPad's docked black screen)
    if (g_fill_mod) {
        module_t *m = g_fill_mod;
        if (m->fill_d_off) { if (m->fill_d_off + 4 > m->size) die("%s: HOST_FILL_D out of range", m->name); uint32_t v32 = (uint32_t)deff; memcpy(m->base + m->fill_d_off, &v32, sizeof v32); }
        if (m->fill_d_off && ht) { if (m->fill_d_off + 8 > m->size) die("%s: HOST_FILL_D height out of range", m->name); uint32_t v32 = (uint32_t)ht; memcpy(m->base + m->fill_d_off + 4, &v32, sizeof v32); }
        if (m->fill_h_off) { if (m->fill_h_off + 4 > m->size) die("%s: HOST_FILL_H out of range", m->name); if (hw > 1280 || serve_narrow) { uint32_t v32 = (uint32_t)hw; memcpy(m->base + m->fill_h_off, &v32, sizeof v32); } }
        if (m->fill_d_off || m->fill_h_off) LOG("%s: display-mode sizes filled from the host (docked %ld, handheld %ld)", m->name, deff, heff);
        // A resolution record (HOST_FILL_W: four words, a world size at a 576-line reference then the handheld size,
        // stock 1024x576 / 1280x720), copied with the display template into a managed settings object at its init
        // (Silksong: the pair of vector loads at main+0x253cfd4). Its world pair is the world camera's reference:
        // the camera projects for the pair's aspect, and the composite stretches that picture into the frame. Left
        // stock on a screen wider than 16:9, the world is drawn for 16:9 and stretched sideways into the wide
        // frame -- sprites come out fat -- while the HUD, composed in screen space, stays true, which is why the
        // stretch went unnoticed while the picture was judged by the HUD. On a wide screen the world word takes
        // the screen's own aspect at the same 576 reference (the handheld frame's width over its 720 height);
        // the stock words are checked first, so a module whose record differs is left alone. The handheld pair
        // is never written (build #71: it does not drive the HUD). On a narrow screen served its own sizes
        // (serve_narrow, above) the same agreement is arranged the other way: the world pair keeps its 1024
        // width and its height takes the screen's aspect, so the world is composed taller instead of being
        // stretched by the front end's scale
        if (m->fill_w_off && hw && hw != 1280) {
            if (m->fill_w_off + 16 > m->size) die("%s: HOST_FILL_W out of range", m->name);
            uint32_t cur[4]; memcpy(cur, m->base + m->fill_w_off, sizeof cur);
            if (cur[0] == 1024 && cur[1] == 576 && cur[2] == 1280 && cur[3] == 720) {
                if (hw > 1280) {
                    uint32_t v32 = (uint32_t)((hw * 576 + 360) / 720); memcpy(m->base + m->fill_w_off, &v32, sizeof v32);
                    LOG("%s: resolution record world pair widened to the screen (%ux576); the handheld pair stays stock", m->name, v32);
                } else if (serve_narrow) {
                    uint32_t v32 = (uint32_t)((1024 * 720 + hw / 2) / hw); memcpy(m->base + m->fill_w_off + 4, &v32, sizeof v32);
                    LOG("%s: resolution record world pair set to the screen for a narrow screen (1024x%u); the handheld pair stays stock", m->name, v32);
                }
            }
        }
    }
    char cap[32]; snprintf(cap, sizeof cap, ", capped at %d fps", t);
    LOG("%s: frame step %s%s (%s)", g_fps_mod, !t ? "as the game sets it" : "in whole vsyncs decided by the host", t ? cap : "", e ? "DM_FPS_TARGET" : "game profile fps_target");
}
static void install_key_page(module_t *m) {
    if (m->key_page_off + m->key_page_size > m->size) die("%s: key page out of range", m->name);
    uint64_t *page = (uint64_t *)(m->base + m->key_page_off);
    memset(page, 0, m->key_page_size);
    for (unsigned i = 0; i < KEY_N; i++) page[m->key_idx[i]] = (uint64_t)key_value(i) * 8;
    for (int k = 0; k < KEY_N; k++) if (!page[m->key_idx[k]]) die("%s: key page entry %d is 0 (host key not created) -- the game would read TSD slot 0", m->name, k);
    if (mprotect(m->base + m->key_page_off, m->key_page_size, PROT_READ)) die("%s key page mprotect", m->name);
    if (m->fps_state_off) install_fps_state(m);
}

static void register_gates(module_t *m, const char *dir) {
    char path[1024], line[256]; snprintf(path, sizeof path, "%s/%s.gates.tsv", dir, m->name);
    FILE *f = fopen(path, "r");
    int ng = 0;
    if (f) {
        unsigned long ret, orig; char kind[16]; int arg;
        while (fgets(line, sizeof line, f))
            if (sscanf(line, "%lx %15s %d %lx", &ret, kind, &arg, &orig) == 4) { gate_register((uint64_t)m->base + ret, kind, arg, orig); ng++; }
        fclose(f);
    }
    LOG("%s: gates %d patch_off %#llx keys %lu/%lu/%lu/%lu", m->name, ng, m->patch_off, g_key18, g_keytls, g_keytlr, g_keygate);
}

// DT_RELR (from SDK 20; all three modules of The Legend of Zelda: Breath of the Wild 1.9.0 have it): a compact table of relative relocations with the addend in the slot (*slot += base).
// Each 8-byte entry: even = a new start offset (relocate it, the pointer moves to the next slot); odd = a bitmap whose bits 1-63 stand for the 63 slots after the pointer, which then moves on by 63 slots.
// Without it main's GOT and vtables hold module offsets (main's RELA keeps only symbol relocations)
static unsigned relr_apply(module_t *m, uint64_t relr, uint64_t relrsz, uint64_t delta) {
    const uint64_t *e = (const uint64_t *)(m->base + relr); uint64_t *where = NULL; unsigned n = 0;
    for (uint64_t i = 0; i < relrsz / 8; i++) {
        uint64_t v = e[i];
        if (!(v & 1)) { where = (uint64_t *)(m->base + v); *where++ += delta; n++; continue; }
        if (!where) die("%s: DT_RELR bitmap entry with no start before it", m->name);
        for (unsigned b = 0; (v >>= 1); b++) if (v & 1) { where[b] += delta; n++; }
        where += 63;
    }
    return n;
}

// The address a symbol relocation of module m binds to, as Horizon's rtld would with the modules loaded now (forced take-over, then the loaded modules in load order, then HLE / stub).
// *other: the module's own definition was taken over by an earlier module's; *weak0: an undefined weak symbol nothing defines, bound to 0
static uint64_t bind_sym(module_t *m, const Elf64_Sym *s, int *other, int *weak0) {
    uint64_t v = (uint64_t)force_lookup(m->strtab + s->st_name);
    *other = *weak0 = 0;
    // Symbols the module defines itself are also looked up globally in load order (the ELF default; Horizon's rtld does the same): the definition of an earlier-loaded module overrides a later one; only local / non-default visibility binds to itself.
    // Engage's main defines its own operator new / delete (Unity's memory manager) and sdk has a copy too (forwarding to malloc / free): previously sdk bound its own delete,
    // so blocks from main's new were freed by sdk's libc++ string code into the SDK heap, and CentralHeap::Free reported NotNMallocPtr
    if (!v && s->st_shndx) {
        uint64_t self = (uint64_t)m->base + s->st_value;
        v = ELF64_ST_BIND(s->st_info) == STB_LOCAL || ELF64_ST_VISIBILITY(s->st_other) != STV_DEFAULT ? self : resolve_sym(m, m->strtab + s->st_name);
        if (!v) v = self;
        *other = v != self;
    }
    // An undefined weak symbol that no module defines and the host does not implement is 0, as Horizon's rtld binds it: the code tests its address before calling it.
    // Octopath Traveler 0's main imports the thread_local init function _ZTHN13LowLevelTasks5FTask10ActiveTaskE weakly; a named stub made it look defined and the game called it
    const char *nm = m->strtab + s->st_name;
    *weak0 = !v && !s->st_shndx && ELF64_ST_BIND(s->st_info) == STB_WEAK && !loaded_sym(nm) && !hle_implements(nm);
    if (!v && !*weak0) v = resolve_sym(m, nm);
    return v;
}

typedef struct { const Elf64_Rela *tab[2]; uint64_t n[2]; uint64_t relr, relrsz; } relocs_t;
static relocs_t relocs_of(const module_t *m) {
    uint64_t rela = 0, relasz = 0, jmprel = 0, pltsz = 0; relocs_t r = {0};
    for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) switch (d->d_tag) {
        case DT_RELA: rela = d->d_un.d_ptr; break;
        case DT_RELASZ: relasz = d->d_un.d_val; break;
        case DT_JMPREL: jmprel = d->d_un.d_ptr; break;
        case DT_PLTRELSZ: pltsz = d->d_un.d_val; break;
        case DT_RELR: r.relr = d->d_un.d_ptr; break;
        case DT_RELRSZ: r.relrsz = d->d_un.d_val; break;
    }
    r.tab[0] = (const Elf64_Rela *)(m->base + rela); r.tab[1] = (const Elf64_Rela *)(m->base + jmprel);
    r.n[0] = relasz / sizeof(Elf64_Rela); r.n[1] = pltsz / sizeof(Elf64_Rela);
    return r;
}

static void relocate(module_t *m) {
    relocs_t rl = relocs_of(m);
    int cnt[3] = {0}, nint = 0, nweak0 = 0;
    unsigned nrelr = rl.relr ? relr_apply(m, rl.relr, rl.relrsz, (uint64_t)m->base) : 0;
    for (int t = 0; t < 2; t++)
        for (uint64_t i = 0; i < rl.n[t]; i++) {
            const Elf64_Rela *r = &rl.tab[t][i];
            uint64_t *where = (uint64_t *)(m->base + r->r_offset);
            unsigned type = ELF64_R_TYPE(r->r_info), si = ELF64_R_SYM(r->r_info);
            if (type == R_AARCH64_RELATIVE) { *where = (uint64_t)m->base + r->r_addend; cnt[0]++; continue; }
            const Elf64_Sym *s = &m->symtab[si]; int other, weak0;
            uint64_t v = bind_sym(m, s, &other, &weak0);
            if (other && nint++ < 8) LOG("%s: %s bound to an earlier module's definition (%s)", m->name, m->strtab + s->st_name, module_of((void *)v) ? module_of((void *)v)->name : "?");
            if (weak0 && nweak0++ < 8) LOG("%s: undefined weak %s bound to 0", m->name, m->strtab + s->st_name);
            if (type == R_AARCH64_JUMP_SLOT) { *where = v; cnt[2]++; }
            else { *where = v + r->r_addend; cnt[1]++; }       // ABS64 / GLOB_DAT
        }
    if (!m->nro || m->loads <= 1)
        LOG("%s: reloc relative=%d relr=%u abs/glob=%d jump=%d%s", m->name, cnt[0], nrelr, cnt[1], cnt[2], nint ? " (some bound to an earlier module's definition)" : "");
    if (nint > 8) LOG("%s: %d bound to an earlier module's definition in all", m->name, nint);
}

// ---- NRO modules (nn::ro, hle_ro.c) ----
// A game may load modules at run time: nn::ro::LoadModule hands over an NRO image it read from its files (Super Smash Bros. Ultimate: the fighters' code, 98 NROs in data.arc, whose
// exports main imports: 1,045 lua2cpp::create_agent_* functions). iOS runs no code loaded at run time, so the NROs are rewritten offline like the other modules (dm/tools/nro_collect.py,
// patch_nso.py) and listed in <patched dir>/nro.tsv with their SHA-256. All are mapped at start (code read-only + execute from then on); none takes part in symbol lookups until the game
// loads it. A load restores the NRO's data and bss as rewritten (after the first), relocates it against the modules loaded then, in load order (Horizon's rtld does the same), and binds the
// symbol relocations of the modules loaded before it that it defines and nothing loaded defined (Horizon: BindVariables, and functions bound lazily at their first call): main's lua2cpp
// imports are stubs until then. Only data is written, so the same works with code embedded in the iOS executable. An unload binds every relocation that pointed into the NRO again
static void map_image(module_t *m, const char *dir);
static uint8_t g_refused[16][32]; static int g_nrefused;   // NROs the pack refused (online SDKs, nro.tsv rows named "refused")
int nro_refused(const uint8_t sha256[32]) {
    for (int i = 0; i < g_nrefused && i < 16; i++) if (!memcmp(g_refused[i], sha256, 32)) return 1;
    return 0;
}
static void preload_nros(const char *dir) {
    char path[1024], line[512]; snprintf(path, sizeof path, "%s/nro.tsv", dir);
    const char *off = getenv("DM_NRO");
    if (off && !atoi(off)) { LOG("NRO: loading off (DM_NRO=0): every LoadModule fails"); return; }
    FILE *f = fopen(path, "r");
    if (!f) return;
    int n0 = g_nmod; size_t data = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#' || line[0] == '\n') continue;
        char name[16], hex[65]; unsigned size;
        if (sscanf(line, "%15s %64s %u", name, hex, &size) != 3 || strlen(hex) != 64) die("%s: bad row %s", path, line);
        if (!strcmp(name, "refused")) {   // an online SDK the pack left out (dm/tools/nro_collect.py ONLINE_SDKS): LoadModule refuses its hash
            if (g_nrefused < (int)(sizeof g_refused / sizeof *g_refused)) for (int k = 0; k < 32; k++) sscanf(hex + 2 * k, "%2hhx", &g_refused[g_nrefused][k]);
            g_nrefused++; continue;
        }
        if (g_nmod >= MAX_MOD) die("%s: more NROs than module slots (MAX_MOD %d)", path, MAX_MOD);
        module_t *m = &g_mod[g_nmod];
        strlcpy(m->name, name, sizeof m->name); m->nro = 1; m->nro_size = size;
        for (int k = 0; k < 32; k++) sscanf(hex + 2 * k, "%2hhx", &m->sha256[k]);
        read_layout(m, dir); map_image(m, dir); parse_dynamic(m); register_gates(m, dir);
        m->pristine_len = m->key_page_off - m->data_off;
        if (!(m->pristine = malloc(m->pristine_len))) die("%s: pristine data copy", m->name);
        memcpy(m->pristine, m->base + m->data_off, m->pristine_len); data += m->pristine_len;
        g_nmod++;
    }
    fclose(f);
    LOG("NRO: %d modules mapped (%s), loaded when the game asks; data and bss kept as rewritten %.1f MB", g_nmod - n0, path, data / 1048576.0);
}

module_t *nro_find(const uint8_t sha256[32]) {
    for (int i = 0; i < g_nmod; i++) if (g_mod[i].nro && !memcmp(g_mod[i].sha256, sha256, 32)) return &g_mod[i];
    return NULL;
}

// Bind the symbol relocations of module k again: those whose symbol nm defines (load) or whose slot points into nm (unload). Returns how many changed
static unsigned rebind(module_t *k, module_t *nm, int load) {
    relocs_t rl = relocs_of(k); unsigned n = 0;
    uint64_t lo = (uint64_t)nm->base, hi = lo + nm->size;
    for (int t = 0; t < 2; t++)
        for (uint64_t i = 0; i < rl.n[t]; i++) {
            const Elf64_Rela *r = &rl.tab[t][i];
            unsigned type = ELF64_R_TYPE(r->r_info);
            if (type == R_AARCH64_RELATIVE) continue;
            const Elf64_Sym *s = &k->symtab[ELF64_R_SYM(r->r_info)];
            uint64_t *where = (uint64_t *)(k->base + r->r_offset), add = type == R_AARCH64_JUMP_SLOT ? 0 : (uint64_t)r->r_addend, cur = *where - add;
            if (load ? s->st_shndx || !module_sym(nm, k->strtab + s->st_name) : !(cur >= lo && cur < hi)) continue;
            int other, weak0; uint64_t v = bind_sym(k, s, &other, &weak0);
            if (v != cur) { *where = v + add; n++; }
        }
    return n;
}

void nro_load(module_t *m) {
    pthread_rwlock_wrlock(&g_modules_mu);
    if (m->loads) memcpy(m->base + m->data_off, m->pristine, m->pristine_len);
    m->loads++; m->loaded = 1; g_loaded[g_nloaded++] = m;
    relocate(m);
    unsigned n = 0;
    for (int i = 0; i < g_nmod; i++) if (g_mod[i].loaded && &g_mod[i] != m) n += rebind(&g_mod[i], m, 1);
    pthread_rwlock_unlock(&g_modules_mu);
    LOG("NRO %s loaded (load %u, base %p): %u imports of the modules loaded before bound to it", m->name, m->loads, m->base, n);
}

void nro_unload(module_t *m) {
    pthread_rwlock_wrlock(&g_modules_mu);
    m->loaded = 0;
    for (int i = 0; i < g_nloaded; i++) if (g_loaded[i] == m) { memmove(g_loaded + i, g_loaded + i + 1, (size_t)(--g_nloaded - i) * sizeof *g_loaded); break; }
    unsigned n = 0;
    for (int i = 0; i < g_nmod; i++) if (g_mod[i].loaded) n += rebind(&g_mod[i], m, 0);
    pthread_rwlock_unlock(&g_modules_mu);
    LOG("NRO %s unloaded: %u imports that pointed into it bound again", m->name, n);
}

// DM_LOADHASH=1 (diagnostics): after loading, output an address-independent sha256 per module, to prove that the load results of "early start / no early start" are byte-identical.
// Module base addresses and host ASLR differ every run, and only the values of the relocation slots change with them: copy the image and, using the same relocation table, replace every slot with an address-independent token --
// RELATIVE → (0, addend); symbol target falls in some module → (1 + module number, offset within the module); otherwise (host forced take-over / host symbol) → (name FNV, addend); all other bytes as is.
#include <CommonCrypto/CommonDigest.h>
void loader_hash_log(void) {
    if (!getenv("DM_LOADHASH")) return;
    for (int k = 0; k < g_nmod; k++) {
        module_t *m = &g_mod[k];
        uint8_t *cp = malloc(m->size); memcpy(cp, m->base, m->size);
        uint64_t rela = 0, relasz = 0, jmprel = 0, pltsz = 0, relr = 0, relrsz = 0;
        for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) switch (d->d_tag) {
            case DT_RELA: rela = d->d_un.d_ptr; break; case DT_RELASZ: relasz = d->d_un.d_val; break;
            case DT_JMPREL: jmprel = d->d_un.d_ptr; break; case DT_PLTRELSZ: pltsz = d->d_un.d_val; break;
            case DT_RELR: relr = d->d_un.d_ptr; break; case DT_RELRSZ: relrsz = d->d_un.d_val; break;
        }
        // DT_RELR slots: subtracting the base makes them address-independent (done on the copy, reusing relr_apply's walk)
        if (relr) { uint8_t *b = m->base; m->base = cp; relr_apply(m, relr, relrsz, -(uint64_t)b); m->base = b; }
        const Elf64_Rela *tabs[2] = {(const Elf64_Rela *)(m->base + rela), (const Elf64_Rela *)(m->base + jmprel)};
        uint64_t sizes[2] = {relasz, pltsz}; unsigned nslot = 0;
        for (int t = 0; t < 2; t++)
            for (uint64_t i = 0; i < sizes[t] / sizeof(Elf64_Rela); i++) {
                const Elf64_Rela *r = &tabs[t][i]; uint64_t tok[1] = {0};
                if (ELF64_R_TYPE(r->r_info) != R_AARCH64_RELATIVE) {
                    uint64_t v = *(const uint64_t *)(m->base + r->r_offset); int hit = 0;
                    for (int j = 0; j < g_nmod; j++) if (v >= (uint64_t)g_mod[j].base && v < (uint64_t)g_mod[j].base + g_mod[j].size) { tok[0] = 1 + j; hit = 1; break; }
                    if (!hit) { const char *nm = m->strtab + m->symtab[ELF64_R_SYM(r->r_info)].st_name; uint64_t h = 0xcbf29ce484222325ull;
                                for (; *nm; nm++) h = (h ^ (uint8_t)*nm) * 0x100000001b3ull; tok[0] = h | 1ull << 63; }
                }
                memcpy(cp + r->r_offset, &tok[0], 8);                // The 8 slot bytes are replaced by the token head; the token tail is appended below in slot order
                nslot++;
            }
        CC_SHA256_CTX c; CC_SHA256_Init(&c); CC_SHA256_Update(&c, cp, (CC_LONG)m->size);
        for (int t = 0; t < 2; t++)                                // Token tails (addend / offset) are appended in slot order, and together with the slot head uniquely determine the slot value
            for (uint64_t i = 0; i < sizes[t] / sizeof(Elf64_Rela); i++) {
                const Elf64_Rela *r = &tabs[t][i]; uint64_t tail = (uint64_t)r->r_addend;
                if (ELF64_R_TYPE(r->r_info) != R_AARCH64_RELATIVE) {
                    uint64_t v = *(const uint64_t *)(m->base + r->r_offset);
                    for (int j = 0; j < g_nmod; j++) if (v >= (uint64_t)g_mod[j].base && v < (uint64_t)g_mod[j].base + g_mod[j].size) { tail = v - (uint64_t)g_mod[j].base; break; }
                }
                CC_SHA256_Update(&c, &tail, 8);
            }
        uint8_t d[32]; CC_SHA256_Final(d, &c); free(cp);
        char hx[65]; for (int i = 0; i < 32; i++) sprintf(hx + 2 * i, "%02x", d[i]);
        LOG("DM_LOADHASH %s size %#zx relocation slots %u sha256 %s", m->name, m->size, nslot, hx);
    }
}

#if TARGET_OS_IPHONE
// iOS does not allow code loaded at run time to execute, and Apple allows an executable only one segment with execute permission (ITMS-90999): the image is compiled into this executable by dm/ios/tools/gen_embed.py --
// the two code blocks (original text, patch area) are sections in __TEXT, and W (the rest of ro + data + bss) is a separate RW segment. The three blocks are not adjacent in the file; here one contiguous address range is reserved,
// and they are vm_remap'ed back at their original relative positions: code pages with copy=FALSE (sharing the same signed pages with __TEXT, r-x), W with copy=TRUE (copy-on-write, paged only when used).
// The run-time layout is byte-identical to the original image. Remapping signed pages to a new address and then executing them on iOS is exactly what libffi's trampoline table (FFI_EXEC_TRAMPOLINE_TABLE) does
#include <mach/mach.h>
static void remap_at(module_t *m, vm_address_t to, const void *from, unsigned long size, boolean_t copy, vm_prot_t need) {
    vm_address_t a = to; vm_prot_t cur = 0, max = 0;
    kern_return_t kr = vm_remap(mach_task_self(), &a, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (vm_address_t)from, copy, &cur, &max, VM_INHERIT_NONE);
    if (kr != KERN_SUCCESS || a != to) die("%s vm_remap %p → %#lx (%#lx bytes) failed: %d", m->name, from, (unsigned long)to, size, kr);
    if ((cur & need) != need) die("%s permissions after vm_remap %#x, missing %#x", m->name, cur, need);
}
#define IMAGE_MH (&_mh_execute_header)
// The NRO modules (loader.c "NRO modules") are packed instead of getting sections of their own: a Mach-O file has at most 255 sections, and Super Smash Bros. Ultimate's 98 NROs would
// take 294. gen_embed.py puts their pieces one after another, each 16K aligned, in __TEXT,__dm_nro_x0 / __DM_NRO_W,__img / __TEXT,__dm_nro_x1, and __DATA,__dm_nro_tab lists them:
// 32 bytes of name, then the offset and length of its x0, W and x1 pieces in their sections (u64 each). A module name never holds an underscore, so these names meet no module's
typedef struct { char name[32]; uint64_t off[3][2]; } nro_ent;
static int nro_pieces(const char *name, const uint8_t **x0, unsigned long *z0, const uint8_t **w, unsigned long *zw, const uint8_t **x1, unsigned long *z1) {
    unsigned long zt, s0, sw, s1;
    const nro_ent *t = (const nro_ent *)getsectiondata(IMAGE_MH, "__DATA", "__dm_nro_tab", &zt);
    const uint8_t *b0 = getsectiondata(IMAGE_MH, "__TEXT", "__dm_nro_x0", &s0), *bw = getsectiondata(IMAGE_MH, "__DM_NRO_W", "__img", &sw), *b1 = getsectiondata(IMAGE_MH, "__TEXT", "__dm_nro_x1", &s1);
    if (!t || !b0 || !bw || !b1) return 0;
    for (unsigned long i = 0; i < zt / sizeof *t; i++) if (!strncmp(t[i].name, name, sizeof t[i].name)) {
        *x0 = b0 + t[i].off[0][0]; *z0 = t[i].off[0][1]; *w = bw + t[i].off[1][0]; *zw = t[i].off[1][1]; *x1 = b1 + t[i].off[2][0]; *z1 = t[i].off[2][1];
        return 1;
    }
    return 0;
}
static void map_image(module_t *m, const char *dir) {
    (void)dir;
    char sx0[17], sx1[17], dm[17]; snprintf(sx0, sizeof sx0, "__dm%sx0", m->name); snprintf(sx1, sizeof sx1, "__dm%sx1", m->name); snprintf(dm, sizeof dm, "__DM%sW", m->name);
    unsigned long z0 = 0, zw = 0, z1 = 0;
    const uint8_t *x0 = NULL, *w = NULL, *x1 = NULL;
    if (m->nro) { if (!nro_pieces(m->name, &x0, &z0, &w, &zw, &x1, &z1)) die("NRO %s: not in the embedded NRO table (__DATA,__dm_nro_tab)", m->name); }
    else { x0 = getsectiondata(IMAGE_MH, "__TEXT", sx0, &z0); w = getsectiondata(IMAGE_MH, dm, "__img", &zw); x1 = getsectiondata(IMAGE_MH, "__TEXT", sx1, &z1); }
    if (!x0 || !w || !x1) die("embedded sections %s / %s / %s missing", sx0, dm, sx1);
    // Patch area before the base (patch_off < 0): W ends at the end of data (FILE_IMAGE_LEN); bss and the key page are zero pages from vm_allocate and are not in the executable
    int front = m->patch_off < 0;
    if (z0 + zw != (front ? m->file_image_len : (uint64_t)m->patch_off) || (z0 & 0x3FFF) || (zw & 0x3FFF) || (z1 & 0x3FFF) || ((uintptr_t)x0 & 0x3FFF) || ((uintptr_t)w & 0x3FFF) || ((uintptr_t)x1 & 0x3FFF))
        die("%s embedded section layout mismatch (x0 %#lx w %#lx x1 %#lx, PATCH_OFF %#llx)", m->name, z0, zw, z1, (unsigned long long)m->patch_off);
    m->size = front ? m->image_size : m->patch_off + z1;
    uint64_t pre = front ? (uint64_t)-m->patch_off : 0;
    if (front) m->patch_len = z1;
    vm_address_t base = 0;
    if (vm_allocate(mach_task_self(), &base, pre + m->size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) die("%s failed to reserve %#llx bytes of address space", m->name, (unsigned long long)(pre + m->size));
    base += pre;
    remap_at(m, base, x0, z0, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    remap_at(m, base + z0, w, zw, TRUE, VM_PROT_READ | VM_PROT_WRITE);
    // A module with nothing to rewrite has an empty patch area (87 of Super Smash Bros. Ultimate's 98 NROs: no x18, SVC or TLS register use); vm_remap refuses 0 bytes
    // (KERN_INVALID_ARGUMENT), which stopped the app at launch on an iPhone at the first such NRO (found in PR #94)
    if (z1) remap_at(m, base + m->patch_off, x1, z1, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    m->base = (uint8_t *)base; install_key_page(m);
}
#else
static uint8_t *slurp(const char *path, size_t *n) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) die("open %s", path);
    struct stat st; fstat(fd, &st);
    uint8_t *p = malloc(st.st_size);
    if (read(fd, p, st.st_size) != st.st_size) die("read %s", path);
    close(fd); *n = st.st_size; return p;
}

// Seal the code area immediately after copying into anonymous pages (16 KB pages): [0, text_end) and the patch area are read-only+execute, and from then on any write to the code area crashes on the spot;
// what lies between (ro and data on the same page can only go together) is writable
static void map_image(module_t *m, const char *dir) {
    char path[1024]; snprintf(path, sizeof path, "%s/%s.patched.bin", dir, m->name);
    size_t sz; uint8_t *raw = slurp(path, &sz);
    if (m->patch_off < 0) {
        // Patch area before the base: file = the first part of the image (text + ro + data) + patch area; bss and the key page are anonymous zero pages. The gap from the patch area's end to the base is left inaccessible (PROT_NONE)
        uint64_t pre = (uint64_t)-m->patch_off, fl = m->file_image_len;
        if (sz < fl) die("%s is shorter than FILE_IMAGE_LEN %#llx", path, (unsigned long long)fl);
        m->size = m->image_size; m->patch_len = (sz - fl + 0x3FFF) & ~0x3FFFull;
        if (m->patch_len > pre) die("%s patch area of %#llx bytes does not fit in the %#llx before the base", path, (unsigned long long)m->patch_len, (unsigned long long)pre);
        uint8_t *a = mmap(NULL, pre + m->size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (a == MAP_FAILED) die("%s mmap %#llx", m->name, (unsigned long long)(pre + m->size));
        m->base = a + pre;
        memcpy(m->base, raw, fl); memcpy(a, raw + fl, sz - fl); free(raw); install_key_page(m);
        uint64_t rx = (m->text_end + 0x3FFF) & ~0x3FFFull;
        if (mprotect(m->base, rx, PROT_READ | PROT_EXEC)) die("%s mprotect text", m->name);
        if (mprotect(a, m->patch_len, PROT_READ | PROT_EXEC)) die("%s mprotect patch", m->name);
        if (pre > m->patch_len && mprotect(a + m->patch_len, pre - m->patch_len, PROT_NONE)) die("%s mprotect gap", m->name);
        return;
    }
    m->size = (sz + 0x3FFF) & ~0x3FFFull;
    m->base = mmap(NULL, m->size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m->base == MAP_FAILED) die("%s mmap", m->name);
    memcpy(m->base, raw, sz); free(raw); install_key_page(m);
    uint64_t rx = (m->text_end + 0x3FFF) & ~0x3FFFull;
    if (mprotect(m->base, rx, PROT_READ | PROT_EXEC)) die("%s mprotect text", m->name);
    uint64_t po = m->patch_off & ~0x3FFFull;
    if (mprotect(m->base + po, m->size - po, PROT_READ | PROT_EXEC)) die("%s mprotect patch", m->name);
}
#endif

void load_modules(const char *dir, const char **names, int n) {
    // Map everything and parse the symbol tables first, then relocate all at once (cross-module symbols must all be in place first)
    // DM_BOOTPROF: breakdown of ① host loading (milliseconds), to set the upper bound for ③ pre-relocation / mmap
    uint64_t t0 = now_ns(), tm = 0, tp = 0, tg = 0, tr = 0, t;
    for (int i = 0; i < n; i++) {
        module_t *m = &g_mod[i];
        strlcpy(m->name, names[i], sizeof m->name);
        read_layout(m, dir);
    }
    create_keys();
    for (int i = 0; i < n; i++) {
        module_t *m = &g_mod[i];
        t = now_ns(); map_image(m, dir); tm += now_ns() - t;   // On return the code area is already read-only+execute; from here on the loader only writes data
        if (!i) tsd_check();
        t = now_ns(); parse_dynamic(m); tp += now_ns() - t;
        t = now_ns(); register_gates(m, dir); tg += now_ns() - t;
        LOG("%s: base %p size %#zx", names[i], m->base, m->size);
        m->loaded = 1; g_loaded[g_nloaded++] = m; g_nmod++;
    }
    force_init();
    t = now_ns(); for (int i = 0; i < g_nmod; i++) relocate(&g_mod[i]); tr = now_ns() - t;
    force_check();
    preload_nros(dir);   // mapped now, relocated when the game loads them (hle_ro.c)
    { void hlecount_seal(void); hlecount_seal(); }   // DM_HLECOUNT: relocation done, seal the counting stub pages as read-only executable
    if (getenv("DM_SYMCHECK")) LOG("DM_SYMCHECK: %lu symbol lookups at load time, hash and linear disagree %lu", g_symchk_n, g_symchk_bad);
    if (g_flag.bootprof) LOG("① breakdown: mapping (read + copy + seal pages) %.1f ms, dynamic section parsing %.1f ms, gate registration %.1f ms, relocation + forced takeover %.1f ms, total %.1f ms",
                             tm / 1e6, tp / 1e6, tg / 1e6, tr / 1e6, (now_ns() - t0) / 1e6);
}

// Plays the role of rtld's InitModules (rtld+0x830): call each module's DT_INIT in forward order of the load list.
// The timing is decided by nn::init::Start: after nninitStartup and _init_libc2, before nnMain (the 4th argument callback of Start).
void run_module_inits(void) {
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (!m->init || m->nro) continue;   // an NRO's init runs when the game loads it (hle_ro.c)
        LOG("%s: DT_INIT +%#llx (init_array %llu entries)", m->name, m->init, m->init_arraysz / 8);
        ((void (*)(void))(m->base + m->init))();
    }
}
