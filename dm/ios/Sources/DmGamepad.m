// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode; one tap on the layout button at the top centre (labelled with the current layout, "2D" / "3D" / "Tap") goes to the next, and the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   Tap (touch): no control but the layout button, every other touch goes to the game's touch screen; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (fixed ring, tilt measured from the ring centre, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: locked keys first (shoulders, − / +, the layout button, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (layout button included) hides while a physical controller is connected and comes back when it is removed; meanwhile every touch goes to the game. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_slots.h"
#include <stdatomic.h>

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_SWAP, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: on iOS 27 and later the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody), so Core Motion delivers
// them in that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Before that they come in the hardware frame, turned here by the interface orientation, which holds only where the hardware frame is the screen's portrait frame: not on iPhone
// Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen (Split View on the
// inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (iOS 27+)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    if (@available(iOS 27.0, *)) { if ([g_motion respondsToSelector:NSSelectorFromString(@"setDeviceMotionBody:")]) { [g_motion setValue:body forKey:@"deviceMotionBody"]; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)"); } }
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_SWAP_R = 15,                                  // layout button: top centre, level with − / +
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
int dm_opmode(void);   // hle_oe.c: 0 = handheld

// ---- Skin layout (DM_PAD_SKIN=1 in dm/env.txt or Documents/env.txt; art in dm/padskin, staged into the bundle by build_ipa.sh) ----
// Drawn controls are replaced by image controls in the layout of the fan Android port of Silksong: a fixed stick disc
// bottom-left (its medallion knob follows the touch), the action keys bottom-right in two rows, quick map / inventory / pause
// small at the top-right. Centres are fractions of the whole screen, radii a fraction of its width. Keys follow the game's
// Switch defaults. Two skill keys (grp SK_SKILL: tool, Clawline) do nothing until the skill is earned and
// the pad cannot know the game's progress, so the eye key (grp SK_TOGGLE, not a game key) shows or hides them for
// the session; they start hidden at each launch, the eye in its pressed state (the default the player asked
// for, set explicitly in init).
static BOOL padSkin(void) { const char *e = getenv("DM_PAD_SKIN"); return e && atoi(e); }
static int silkSkinMode(void) { const char *e = getenv("DM_SILK_SKIN"); int m = e ? atoi(e) : 1; return m < 0 ? 0 : m > 2 ? 2 : m; }   // the launcher's button-skin choice for this pad: 0 glass, 1 the image skin, 2 the letter-badge skin (dm/padskin-badge); the image skin (1) when unset
enum { SK_ALWAYS, SK_SKILL, SK_TOGGLE };
static const struct { const char *art; int bit; int grp; CGFloat x, y, r; } k_skin[] = {
    {"attack",   B_Y,     SK_ALWAYS, 0.684, 0.822, 0.040},   // needle attack
    {"jump",     B_B,     SK_ALWAYS, 0.781, 0.822, 0.040},
    {"dash",     B_ZR,    SK_ALWAYS, 0.876, 0.822, 0.040},   // Swift Step: tap dashes, hold sprints
    {"tool",     B_R,     SK_SKILL,  0.877, 0.410, 0.040},   // the equipped tool: the cluster's top right (Needolin's old seat), in its original round frame; an eye-key skill key
    {"needolin", B_X,     SK_ALWAYS, 0.783, 0.080, 0.023},   // Needolin: the top row, between map and bag, in the double-horn frame; always shown (not an eye-key skill key)
    {"bind",     B_A,     SK_ALWAYS, 0.877, 0.616, 0.040},   // Bind (heal)
    {"clawline", B_ZL,    SK_SKILL,  0.781, 0.616, 0.040},   // Clawline (swapped with Needolin)
    {"eye",      0,       SK_TOGGLE, 0.672, 0.080, 0.023},   // show / hide the skill keys
    {"map",      B_L,     SK_ALWAYS, 0.727, 0.080, 0.023},   // quick map (the top row respaced evenly for five keys)
    {"bag",      B_MINUS, SK_ALWAYS, 0.838, 0.080, 0.023},   // inventory
    {"pause",    B_PLUS,  SK_ALWAYS, 0.893, 0.080, 0.023},
    {"up",       B_UP,    SK_ALWAYS, 0.162, 0.628, 0.022},   // invisible in both skins (fully transparent art, no glass disc): the game's Up + R tool prompts read the D-pad, never the stick. On the stick disc's own up-pointing rim triangle, small enough that its hit circle (r x 1.35) stops well short of the disc centre, so a centred touch still starts the stick; skinCenter keeps it at raw fractions, anchored to the disc rather than the stacking cluster
};
#define SKIN_N (int)(sizeof k_skin / sizeof k_skin[0])
#define SKIN_REF_HW 0.4615   // the screen the skin layout was measured on (19.5:9): its height as a fraction of its width
static CGPoint skinCenter(int i, CGRect b) {   // the centre of skin key i, in points (the layout and the touch hit test share it)
    CGFloat y = k_skin[i].y;
    if (y > 0.2 && k_skin[i].bit != B_UP)   // an action key: the rows stack up from the bottom row (y 0.822) in width fractions, so the cluster keeps its phone shape on any screen; the top row stays a height fraction (it hugs the top edge). The D-pad Up key is exempt: it is anchored to the stick disc, which sits at raw fractions
        y = 0.822 + (y - 0.822) * SKIN_REF_HW * b.size.width / b.size.height;
    return CGPointMake(k_skin[i].x * b.size.width, y * b.size.height);
}
#define SILK_BADGE_SCALE (1020.0 / 880.0)   // the badge set's canvas over the plain set's (the disc sits centred in the larger canvas, badge medallion below it)
static BOOL silkBadged(const char *name) {   // the padskin keys the badge set bakes a letter medallion into: every k_skin art but the Up key (invisible in both skins, never badged); the eye carries its ON / OFF state word instead of a letter
    static const char *const badged[] = {"attack", "jump", "dash", "tool", "needolin", "bind", "clawline", "eye", "map", "bag", "pause"};
    for (int i = 0; i < (int)(sizeof badged / sizeof *badged); i++) if (!strcmp(name, badged[i])) return YES;
    return NO;
}
static CGFloat silkArtScale(const char *name) {   // a badged key's layer grows by this in badge mode, so the disc itself lands at the plain skin's size and place; unbadged art keeps 1
    return silkSkinMode() == 2 && silkBadged(name) ? SILK_BADGE_SCALE : 1.0;
}
static NSString *silkGlyph(int i) {   // a skin key's glass glyph, by art name: letters for the game keys, nil for the Up key (no glass disc at all) and for the keys drawn as symbols or a dot (the - / + bars, the eye)
    const char *a = k_skin[i].art;
    if (!strcmp(a, "attack")) return @"Y"; if (!strcmp(a, "jump")) return @"B"; if (!strcmp(a, "dash")) return @"ZR";
    if (!strcmp(a, "tool")) return @"R"; if (!strcmp(a, "needolin")) return @"X"; if (!strcmp(a, "bind")) return @"A";
    if (!strcmp(a, "clawline")) return @"ZL"; if (!strcmp(a, "map")) return @"L";
    return nil;
}
static UIImage *skinImage(const char *name) {   // a padskin image, loaded once and cached (nil when the file is absent); the badge mode reads the dm/padskin-badge set instead (same names, the mode is fixed for the process, so one cache serves both)
    static NSMutableDictionary *cache;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSString *key = [NSString stringWithUTF8String:name];
    UIImage *im = cache[key];
    if (!im) {
        NSString *p = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:silkSkinMode() == 2 ? @"dm/padskin-badge/%s.png" : @"dm/padskin/%s.png", name]];
        im = [UIImage imageWithContentsOfFile:p];
        if (im) cache[key] = im;
    }
    return im;
}
static UIImage *skinPressedImage(int i) {   // the pressed-state art (<art>_p) for skin key i, or nil when the skin ships none
    char pn[64]; snprintf(pn, sizeof pn, "%s_p", k_skin[i].art); return skinImage(pn);
}
static UIImage *namedPressedImage(const char *name) {   // the pressed-state art (<name>_p) for a named padskin image, or nil when the skin ships none
    char pn[64]; snprintf(pn, sizeof pn, "%s_p", name); return skinImage(pn);
}
static CALayer *imgLayer(CALayer *parent, const char *name) {
    CALayer *l = [CALayer layer]; l.contents = (id)skinImage(name).CGImage; [parent addSublayer:l]; return l;
}

// ---- Hades layout (DM_PAD_HADES=1 in an env file) ----
// The touch layout of the earlier Hades II port this build replaces, measured from its recordings: a row of small keys at the
// top right, the face keys in a quarter-circle fan around a larger Y, four separate D-pad circles along the bottom, and a
// floating left stick. The keys are clear dark discs (a translucent black fill and a thin light rim, no material
// blur): a view per key, with its label and a press wash as plain layers above it. Centres are fractions of the
// whole screen, radii of its width — except the fan keys' y, which is an offset from Y's centre in width fractions
// (hadesCenter), so the quarter circle keeps its shape on a taller screen (an iPad's); on the phone the layout was
// measured on, the centres come out as before.
static BOOL padHades(void) { const char *e = getenv("DM_PAD_HADES"); return e && atoi(e); }
static int hadesSkinMode(void) { const char *e = getenv("DM_HADES_SKIN"); int m = e ? atoi(e) : 1; return m < 0 ? 0 : m > 2 ? 2 : m; }   // the launcher's button-skin choice: 0 glass, 1 the image skin, 2 the letter-badge skin (dm/hadesskin-badge); the image skin (1) when unset
static UIImage *hadesImage(const char *name) {   // a hadesskin image, loaded once and cached (nil when the file is absent); the badge mode reads the dm/hadesskin-badge set instead (same names, the mode is fixed for the process, so one cache serves both)
    static NSMutableDictionary *cache;
    if (!cache) cache = [[NSMutableDictionary alloc] init];
    NSString *key = [NSString stringWithUTF8String:name];
    UIImage *im = cache[key];
    if (!im) {
        NSString *p = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:hadesSkinMode() == 2 ? @"dm/hadesskin-badge/%s.png" : @"dm/hadesskin/%s.png", name]];
        im = [UIImage imageWithContentsOfFile:p];
        if (im) cache[key] = im;
    }
    return im;
}
static CALayer *hadesImgLayer(CALayer *parent, const char *name) {
    CALayer *l = [CALayer layer]; l.contents = (id)hadesImage(name).CGImage; [parent addSublayer:l]; return l;
}
enum { H_TOP, H_FACE, H_DPAD };   // a D-pad entry carries a direction in dir (0 left, 1 up, 2 down, 3 right) and no label
static const struct { int bit; int kind; int dir; const char *label; CGFloat x, y, r; } k_hades[] = {
    {B_MINUS, H_TOP,  0, "−", 0.691, 0.086, 0.020},
    {B_PLUS,  H_TOP,  0, "+",  0.754, 0.086, 0.020},
    {B_L,     H_TOP,  0, "L",  0.817, 0.086, 0.020},
    {B_ZL,    H_TOP,  0, "ZL", 0.880, 0.086, 0.020},
    {B_ZR,    H_TOP,  0, "ZR", 0.943, 0.086, 0.020},
    {B_R,     H_FACE, 0, "R",  0.903, -0.1451, 0.031},   // fan keys: y = offset from Y's centre, in width fractions; the four centres sit on a radius of 0.1451 about Y's centre, at 0/30/60/90 degrees from straight above Y
    {B_A,     H_FACE, 0, "A",  0.8305, -0.1257, 0.031},
    {B_X,     H_FACE, 0, "X",  0.7773, -0.0726, 0.031},
    {B_B,     H_FACE, 0, "B",  0.758,  0.0,    0.031},
    {B_Y,     H_FACE, 0, "Y",  0.903,  0.715,  0.038},
    {B_LEFT,  H_DPAD, 0, NULL, 0.645, 0.896, 0.019},
    {B_UP,    H_DPAD, 1, NULL, 0.701, 0.896, 0.019},
    {B_DOWN,  H_DPAD, 2, NULL, 0.753, 0.896, 0.019},
    {B_RIGHT, H_DPAD, 3, NULL, 0.807, 0.896, 0.019},
};
#define HADES_N (int)(sizeof k_hades / sizeof k_hades[0])
static const char *k_hadesArt[HADES_N] = {"minus", "plus", "l", "zl", "zr", "r", "a", "x", "b", "y", "left", "up", "down", "right"};   // dm/hadesskin art per k_hades key, same order
#define HADES_ART_F 0.875   // the art's disc diameter as a fraction of its square canvas (448 of 512, keys and stick alike)
static BOOL hadesBadged(const char *name) {   // the hadesskin keys the badge set bakes a letter medallion into: the ten letter keys (the D-pad arrows, the stick and the knob stay plain)
    static const char *const badged[] = {"minus", "plus", "l", "zl", "zr", "r", "a", "x", "b", "y"};
    for (int i = 0; i < (int)(sizeof badged / sizeof *badged); i++) if (!strcmp(name, badged[i])) return YES;
    return NO;
}
static CGFloat hadesArtF(const char *name) {   // a key's art fraction: in badge mode a badged key's canvas is 594 for the same 448 disc, so its layer grows to keep the disc itself at the plain skin's size and place
    return hadesSkinMode() == 2 && hadesBadged(name) ? 448.0 / 594.0 : HADES_ART_F;
}
static CGPoint hadesCenter(int i, CGRect b) {   // the centre of Hades key i, in points
    CGFloat y = k_hades[i].y;
    if (k_hades[i].kind == H_FACE && k_hades[i].bit != B_Y) {   // a fan key: its y is an offset from Y's centre in width fractions
        static int yi = -1;
        if (yi < 0) for (int j = 0; j < HADES_N; j++) if (k_hades[j].bit == B_Y) yi = j;
        y = k_hades[yi].y + y * b.size.width / b.size.height;
    }
    return CGPointMake(k_hades[i].x * b.size.width, y * b.size.height);
}
static UIView *clearDisc(UIView *parent, CGFloat tint) {
    // A plain translucent disc: a black fill at the given alpha and a thin light rim, nothing else.
    // The keys first used the system Liquid Glass material here (UIGlassEffect, regular style): over a
    // bright scene it reads as frosted grey and hides the game behind the key, so the discs are plain
    // now, like the earlier Hades II port's keys.
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [UIColor colorWithWhite:0 alpha:tint];
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    v.layer.borderWidth = 1;
    v.userInteractionEnabled = NO;
    [parent addSubview:v];
    return v;
}

@interface DmGamepad : UIView
@end
static __weak DmGamepad *g_view;
static void pads_start(void);   // Physical controllers, below

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    CAShapeLayer *_swap; CATextLayer *_swapLabel; BOOL _swapHeld;
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
    BOOL _skin;                                    // DM_PAD_SKIN: the image controls below replace the drawn ones
    CALayer *_skinDisc, *_skinKnob;                // the skin's stick disc and its knob (the knob follows the touch)
    CALayer *_skinBtn[SKIN_N];                     // the skin's keys, in k_skin order
    int _sSkinMode;                                // DM_SILK_SKIN: 0 the glass controls below, 1 the image skin over them, 2 the letter-badge skin (the launcher's choice; 1 when unset)
    UIView *_sGlassBox;                            // holds this pad's glass controls: the k_skin layout drawn as glass (Hades' arrangement, mirrored)
    UIView *_sGlass[SKIN_N];                       // one clear disc per skin key (nil for the Up key: invisible in both skins)
    CAShapeLayer *_sWash[SKIN_N];                  // a white wash over a glass disc, lit while its key is pressed
    CATextLayer *_sLabel[SKIN_N];                  // the glass keys' glyphs
    CAShapeLayer *_sSym[SKIN_N];                   // drawn glyphs: the - / + bars and the eye's pupil dot (text glyphs ride high, and an eye has no letter)
    UIView *_sStick, *_sKnob;                      // the glass stick disc and its knob
    BOOL _skillOff;                                // the skill keys (grp SK_SKILL) are hidden by the eye key
    CALayer *_skipKey, *_padKey;   // the cutscene keys: the skin's Skip medallion at the Bind key's place, its Pad medallion at the eye key's place (drawn in every skin mode, glass included)
    int _padMode; BOOL _padPeek;                   // the host's pad mode (hle_hid.c dm_pad_mode) and the player's recall of the pad for the rest of the mode
    NSTimer *_padTimer;                            // polls the pad mode while the skin is up
    BOOL _hades;                                   // DM_PAD_HADES: the glass controls below replace the drawn ones
    UIView *_glassBox;                             // holds the Hades glass controls: hidden while a physical controller is connected
    UIView *_hGlass[HADES_N];          // one clear disc per Hades key
    CAShapeLayer *_hWash[HADES_N];                 // a white wash over a disc, lit while its key is pressed
    CATextLayer *_hLabel[HADES_N];                 // the Hades keys' labels (the D-pad keys carry a triangle layer instead)
    CAShapeLayer *_hSym[HADES_N];                  // drawn bars for the - / + keys, centred exactly (text glyphs ride high)
    CAShapeLayer *_hTri[4];                        // the D-pad triangles, in k_hades dir order
    UIView *_hStick, *_hKnob;          // the floating stick's clear disc and its knob
    int _hSkinMode;                                // DM_HADES_SKIN: 0 the glass controls below, 1 the image skin over them, 2 the letter-badge skin (the launcher's choice; 1 when unset)
    CALayer *_hArt[HADES_N];           // one skin image per Hades key (nil while the skin is off or the art is absent: glass shows)
    CALayer *_hStickArt, *_hKnobArt;   // the skin's stick disc and knob: the pack's own art, nothing drawn behind either
    CGPoint _lCentre;                              // the floating left stick's centre: where its touch landed
}

static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = 0.2; l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor; t.contentsScale = UIScreen.mainScreen.scale;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        _skillOff = YES;   // the skill keys start hidden at every launch, the eye key in its pressed state (the default the player asked for, stated here so no refactor can quietly flip it); tapping the eye shows them for the session
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
            k_idle = [UIColor colorWithWhite:1 alpha:0.14]; k_on = [UIColor colorWithWhite:1 alpha:0.45]; k_line = [UIColor colorWithWhite:1 alpha:0.38];
            k_ringFill = [UIColor colorWithWhite:1 alpha:0.06]; k_text = [UIColor colorWithWhite:1 alpha:0.75]; k_textOn = [UIColor colorWithWhite:0 alpha:0.7];
        });
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _swap = shape(_controls); _swapLabel = label(_swap, @"");
        _skin = padSkin();
        if (_skin) {   // image controls instead of the drawn ones; the drawn layers stay hidden for good
            _skinDisc = imgLayer(_controls, "stick"); _skinDisc.opacity = 0.75;
            _skinKnob = imgLayer(_controls, "knob"); _skinKnob.opacity = 0.95;
            for (int i = 0; i < SKIN_N; i++) { _skinBtn[i] = imgLayer(_controls, k_skin[i].art); _skinBtn[i].opacity = 1.0; }
            _skipKey = imgLayer(_controls, "skip"); _skipKey.hidden = YES;   // the cutscene keys: skin medallions from dm/padskin; applyPadMode shows them while the host reports a cutscene
            _padKey = imgLayer(_controls, "pad"); _padKey.hidden = YES;
            _padTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 target:self selector:@selector(padTick) userInfo:nil repeats:YES];   // the view lives as long as the app, so the timer needs no invalidation
            _sSkinMode = silkSkinMode();
            _sGlassBox = [[UIView alloc] initWithFrame:self.bounds];
            _sGlassBox.userInteractionEnabled = NO; _sGlassBox.backgroundColor = UIColor.clearColor;
            _sGlassBox.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:_sGlassBox];   // a view over the layer tree, like the Hades glass box; padsChanged hides it while a physical controller is connected
            for (int i = 0; i < SKIN_N; i++) if (silkGlyph(i) || k_skin[i].bit == B_MINUS || k_skin[i].bit == B_PLUS || k_skin[i].grp == SK_TOGGLE) _sGlass[i] = clearDisc(_sGlassBox, 0.30);
            _sStick = clearDisc(_sGlassBox, 0.30); _sKnob = clearDisc(_sGlassBox, 0.30);
            CALayer *ov = [CALayer layer]; [_sGlassBox.layer addSublayer:ov];   // washes and glyphs, above every glass disc
            for (int i = 0; i < SKIN_N; i++) {
                _sWash[i] = shape(ov); _sWash[i].fillColor = UIColor.whiteColor.CGColor; _sWash[i].opacity = 0;
                _sWash[i].strokeColor = nil; _sWash[i].shadowOpacity = 0;
                if (k_skin[i].bit == B_MINUS || k_skin[i].bit == B_PLUS || k_skin[i].grp == SK_TOGGLE) { _sSym[i] = shape(ov); _sSym[i].fillColor = k_text.CGColor; _sSym[i].strokeColor = nil; _sSym[i].shadowOpacity = 0; }
                else if (silkGlyph(i)) _sLabel[i] = label(ov, silkGlyph(i));
            }
            _sGlassBox.hidden = _sSkinMode >= 1;   // the image skin covers the glass; with the choice at 0 the images stay hidden instead (applyPadMode and refresh keep them so)
            if (!_sSkinMode) { _skinDisc.hidden = YES; _skinKnob.hidden = YES; for (int i = 0; i < SKIN_N; i++) _skinBtn[i].hidden = YES; }
            for (int b = 0; b < B_N; b++) { _key[b].hidden = YES; if (_label[b]) _label[b].hidden = YES; }
            _swap.hidden = YES; _swapLabel.hidden = YES; _ring.hidden = YES; _knob.hidden = YES;
        }
        _hades = padHades();
        if (_hades) {   // glass controls instead of the drawn ones; the drawn layers stay hidden for good
            _glassBox = [[UIView alloc] initWithFrame:self.bounds];
            _glassBox.userInteractionEnabled = NO; _glassBox.backgroundColor = UIColor.clearColor;
            _glassBox.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [self addSubview:_glassBox];
            for (int i = 0; i < HADES_N; i++) _hGlass[i] = clearDisc(_glassBox, 0.30);
            _hStick = clearDisc(_glassBox, 0.30); _hKnob = clearDisc(_glassBox, 0.30);
            CALayer *ov = [CALayer layer]; [_glassBox.layer addSublayer:ov];   // washes and labels, above every glass disc
            for (int i = 0; i < HADES_N; i++) {
                _hWash[i] = shape(ov); _hWash[i].fillColor = UIColor.whiteColor.CGColor; _hWash[i].opacity = 0;
                _hWash[i].strokeColor = nil; _hWash[i].shadowOpacity = 0;
                if (k_hades[i].bit == B_MINUS || k_hades[i].bit == B_PLUS) { _hSym[i] = shape(ov); _hSym[i].fillColor = k_text.CGColor; _hSym[i].strokeColor = nil; _hSym[i].shadowOpacity = 0; }
                else if (k_hades[i].label) _hLabel[i] = label(ov, [NSString stringWithUTF8String:k_hades[i].label]);
                else { _hTri[k_hades[i].dir] = shape(ov); _hTri[k_hades[i].dir].fillColor = k_text.CGColor; _hTri[k_hades[i].dir].strokeColor = nil; _hTri[k_hades[i].dir].shadowOpacity = 0; }
            }
            _hSkinMode = hadesSkinMode();
            if (_hSkinMode) {   // image skin over the glass: a key whose art is absent keeps its glass disc and label
                CALayer *ab = [CALayer layer]; [_glassBox.layer addSublayer:ab];   // art above the washes and labels
                for (int i = 0; i < HADES_N; i++) if (hadesImage(k_hadesArt[i])) {
                    _hArt[i] = hadesImgLayer(ab, k_hadesArt[i]);
                    _hGlass[i].hidden = YES; _hWash[i].hidden = YES;
                    if (_hLabel[i]) _hLabel[i].hidden = YES;
                    if (_hSym[i]) _hSym[i].hidden = YES;
                    if (k_hades[i].kind == H_DPAD) _hTri[k_hades[i].dir].hidden = YES;
                }
                if (hadesImage("stick")) { _hStickArt = hadesImgLayer(ab, "stick"); _hStick.hidden = YES; }
                if (hadesImage("knob")) { _hKnobArt = hadesImgLayer(ab, "knob"); _hKnob.hidden = YES; }
            }
            for (int b = 0; b < B_N; b++) { _key[b].hidden = YES; if (_label[b]) _label[b].hidden = YES; }
            _swap.hidden = YES; _swapLabel.hidden = YES; _ring.hidden = YES; _knob.hidden = YES;
        }
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _skin || _hades || _tap || (fullOnly(b) && !_full);
    _ring.hidden = _knob.hidden = _skin || _hades || _tap;
    _swapLabel.string = _tap ? @"Tap" : _full ? @"3D" : @"2D";
    [CATransaction commit];
}
- (void)nextLayout {   // 2D → 3D (→ Tap in handheld mode) → 2D: release every touch first (no key stays held), save, lay out again
    int l = _tap ? 0 : _full ? (dm_opmode() == 0 ? 2 : 0) : 1;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout];
}

// ---- Layout (points; computed inside the safe area) ----
- (CGRect)safe { return UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets); }
- (CGRect)corner { UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { return MIN(self.bounds.size.height / 430.0, 1.3); }   // 1 = 430 points tall (iPhone Pro Max landscape)
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 1, K_FACE_X * u, CGRectGetMaxY(s) - K_PAD_Y * u); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome {   // the left stick's ring centre; in skin mode the disc centre (a fraction of the whole screen)
    if (_hades) { CGRect b = self.bounds; return CGPointMake(0.168 * b.size.width, 0.664 * b.size.height); }
    if (_skin) { CGRect b = self.bounds; return CGPointMake(0.162 * b.size.width, 0.742 * b.size.height); }
    CGRect s = self.corner; return side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u); }
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : _hades && _stick[0] ? _lCentre : self.stickHome; }
- (CGFloat)stickR:(int)i { if (_hades && !i) return 0.061 * self.bounds.size.width; if (_skin && !i) return 0.074 * self.bounds.size.width; return (i ? K_RSTICK_R : K_STICK_R) * self.u; }
- (BOOL)inRightArea:(CGPoint)p { CGRect b = self.bounds; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter { CGRect s = self.corner; CGFloat u = self.u; return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u); }
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    return side(s, b == B_ZR || b == B_R, (z ? K_ZL_X : K_L_X) * u, CGRectGetMinY(s) + (z ? K_ZL_Y : K_L_Y) * u); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; return side(s, b == B_RS, K_CLICK_X * u, CGRectGetMinY(s) + K_ZL_Y * u); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + K_PILL_Y * u);   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)swapCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + K_PILL_Y * self.u); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (int)skinBtnAt:(CGPoint)p {   // skin mode: the image key under the point, or -1 (hidden skill keys take no touch)
    CGRect b = self.bounds;
    for (int i = 0; i < SKIN_N; i++) { if (_skillOff && k_skin[i].grp == SK_SKILL) continue;
        CGPoint c = skinCenter(i, b);
        if (dist(p, c) <= k_skin[i].r * b.size.width * 1.35) return i; }
    return -1;
}
- (int)hadesBtnAt:(CGPoint)p {   // Hades mode: the glass key under the point, or -1
    CGRect b = self.bounds;
    for (int i = 0; i < HADES_N; i++) {
        CGPoint c = hadesCenter(i, b);
        if (dist(p, c) <= k_hades[i].r * b.size.width * 1.4) return i; }
    return -1;
}
- (int)btnAt:(CGPoint)p {   // locked keys (tested on touch-down only, then locked)
    CGFloat u = self.u;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        BOOL hit = isDrop(b) ? dist(p, [self dropCenter:b]) <= [self dropR:b] * 1.35
                 : isClick(b) ? dist(p, [self clickCenter:b]) <= K_CLICK_R * u * 1.35
                 : CGRectContainsPoint(CGRectInset([self pillRect:b], -8 * u, -8 * u), p);
        if (hit) return b; }
    return -1;
}
- (BOOL)inSwap:(CGPoint)p { return dist(p, self.swapCenter) <= K_SWAP_R * self.u * 1.6; }
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceR * 1.25;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0; BOOL swap = NO;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]];
        else if (c == C_SWAP) swap = YES; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits || swap != _swapHeld;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (swap && !_swapHeld) || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn; _swapHeld = swap;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes (all of them while a physical controller is connected) go to the game's touch screen, normalized on the 16:9 picture that front_ios.m
// centres in the screen: Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = self.bounds; CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0) return;
    const char *fs = getenv("DM_FULLSCREEN");   // adaptive full-screen is the default, so the touch maps to the whole screen; only an explicit 0 (an env file) fits it to the centred 16:9 picture
    if (fs && !atoi(fs)) { if (w / h > 16.0 / 9.0) w = h * 16.0 / 9.0; else h = w * 9.0 / 16.0; }
    CGFloat x0 = (b.size.width - w) / 2, y0 = (b.size.height - h) / 2;
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = [_game[i] locationInView:self];
        t[n++] = (dm_touch){(uint32_t)i, (float)fmin(fmax((p.x - x0) / w, 0), 0.999), (float)fmin(fmax((p.y - y0) / h, 0), 0.999)};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        if (_hades) {   // Hades mode: a glass key, the floating left stick (a touch in the left half), the right stick (the right third), else the game's touch screen
            int hb = [self hadesBtnAt:p];
            if (hb >= 0) { [_owner setObject:@(C_BTN | (uint64_t)k_hades[hb].bit << 8) forKey:t]; continue; }
            if (!_stick[0] && p.x < self.bounds.size.width * 0.5) { [_owner setObject:@(C_STICK) forKey:t]; _stick[0] = t; _stickNow[0] = p; _lCentre = p; continue; }
            if (!_stick[1] && [self inRightArea:p]) { [_owner setObject:@(C_STICK | 1ull << 8) forKey:t]; _stick[1] = t; _stickNow[1] = p; _rCentre = p; continue; }
            game |= [self gameBegin:t]; continue;
        }
        if (_skin) {   // skin mode: an image key, the disc (a fixed stick), else the game's touch screen
            if (_padMode >= 2 && !_padPeek && dist(p, skinCenter(7, self.bounds)) <= k_skin[7].r * self.bounds.size.width * 1.35) { _padPeek = YES; [self applyPadMode]; continue; }   // the Pad recall key: the pad comes back for the rest of the cutscene
            if (_padMode == 3 && !_padPeek && dist(p, skinCenter(5, self.bounds)) <= k_skin[5].r * self.bounds.size.width * 1.35) { [_owner setObject:@(C_BTN | (uint64_t)B_A << 8) forKey:t]; continue; }   // the Skip key: A, through the usual input path
            if ([self padHidden]) { game |= [self gameBegin:t]; continue; }   // hidden for a cutscene or a load: the touch is the game's
            int sb = [self skinBtnAt:p];
            if (sb >= 0 && k_skin[sb].grp == SK_TOGGLE) { _skillOff = !_skillOff; [self refresh]; continue; }   // the eye key only flips the skill keys' visibility
            if (sb >= 0) { [_owner setObject:@(C_BTN | (uint64_t)k_skin[sb].bit << 8) forKey:t]; continue; }
            if (!_stick[0] && dist(p, self.stickHome) <= [self stickR:0] * K_STICK_GRAB) { [_owner setObject:@(C_STICK) forKey:t]; _stick[0] = t; _stickNow[0] = p; continue; }
            game |= [self gameBegin:t]; continue;
        }
        int hit = _tap ? -1 : [self btnAt:p];
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if ([self inSwap:p]) { [_owner setObject:@(C_SWAP) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + self.faceR * 1.6); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / (self.dpadR * K_DPAD_GRAB); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / ([self stickR:0] * K_STICK_GRAB); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p; }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL swap = NO, game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if (ended && (v & 0xff) == C_SWAP && [self inSwap:[t locationInView:self]]) swap = YES;   // layout button: counts only when released on the button
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
    if (swap) [self nextLayout];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }
// ---- Pad mode (skin mode): the host watches the game's state (hle_hid.c dm_pad_mode) and the pad hides while a cutscene or a load runs ----
// Mode 1 (a load) hides the pad outright; modes 2 and 3 (a cutscene) show the Pad recall key at the eye key's place, and mode 3 (the
// cutscene can be skipped) the Skip key at the Bind key's place. Recalling brings the whole pad back for the rest of the mode. While the
// pad is hidden every other touch goes to the game's own touch screen, as touches outside the controls always do. The two cutscene keys
// are the skin's drawn medallions whatever the skin choice is (the glass choice too): their art loads through skinImage like any skin
// key's, and the glass controls at their places stay hidden with the rest of the glass pad while they show
- (BOOL)padHidden { return _padMode > 0 && !_padPeek; }
- (void)applyPadMode {
    BOOL hide = [self padHidden];
    _skinDisc.hidden = hide || !_sSkinMode; _skinKnob.hidden = hide || !_sSkinMode;
    for (int i = 0; i < SKIN_N; i++) _skinBtn[i].hidden = hide || !_sSkinMode || (_skillOff && k_skin[i].grp == SK_SKILL);
    _skipKey.hidden = !(_padMode == 3 && !_padPeek);   // the cutscene keys are drawn medallions in every skin mode, the glass choice included: the glass pad yields their places (its box hides below, each glass key in refresh, both with padHidden)
    _padKey.hidden = !(_padMode >= 2 && !_padPeek);
    if (_sGlassBox) _sGlassBox.hidden = hide || _sSkinMode >= 1;
    [self refresh];
}
- (void)padTick {
    int m = dm_pad_mode();
    if (m == _padMode) return;
    _padMode = m; _padPeek = NO;
    [self reset];   // held touches end with the mode change: their keys may be hidden now
    [self applyPadMode];
}

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
static CGPathRef triPath(CGPoint c, CGFloat s, int dir) {   // a D-pad triangle: dir 0 left, 1 up, 2 down, 3 right
    CGPoint v[3];
    const CGFloat k = 1.1547;   // 2/sqrt(3): base = the two equal sides (an equilateral triangle)
    switch (dir) {
        case 0:  v[0] = CGPointMake(c.x - s, c.y); v[1] = CGPointMake(c.x + s, c.y - s * k); v[2] = CGPointMake(c.x + s, c.y + s * k); break;
        case 1:  v[0] = CGPointMake(c.x, c.y - s); v[1] = CGPointMake(c.x - s * k, c.y + s); v[2] = CGPointMake(c.x + s * k, c.y + s); break;
        case 2:  v[0] = CGPointMake(c.x, c.y + s); v[1] = CGPointMake(c.x - s * k, c.y - s); v[2] = CGPointMake(c.x + s * k, c.y - s); break;
        default: v[0] = CGPointMake(c.x + s, c.y); v[1] = CGPointMake(c.x - s, c.y - s * k); v[2] = CGPointMake(c.x - s, c.y + s * k); break;
    }
    CGPoint sh = dir == 0 ? CGPointMake(-s / 3, 0) : dir == 1 ? CGPointMake(0, -s / 3) : dir == 2 ? CGPointMake(0, s / 3) : CGPointMake(s / 3, 0);   // the centroid sits s/3 toward the base; shift toward the tip so it lands on c
    for (int i = 0; i < 3; i++) { v[i].x += sh.x; v[i].y += sh.y; }
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[2].x + v[0].x) / 2, (v[2].y + v[0].y) / 2);
    for (int i = 0; i < 3; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 3].x, v[(i + 1) % 3].y, s * 0.15);   // corners slightly rounded
    CGPathCloseSubpath(p); return p;
}
static CGPathRef symPath(CGPoint c, CGFloat r, BOOL plus) {   // the - / + keys as bars centred on c: a text glyph's ink is not centred in its line box and rides high
    CGFloat hl = r * 0.50, ht = r * 0.085;
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathAddRoundedRect(p, NULL, CGRectMake(c.x - hl, c.y - ht, 2 * hl, 2 * ht), ht, ht);
    if (plus) CGPathAddRoundedRect(p, NULL, CGRectMake(c.x - ht, c.y - hl, 2 * ht, 2 * hl), ht, ht);
    return p;
}
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef base = CTFontCreateUIFontForLanguage(kCTFontUIFontEmphasizedSystem, fs, NULL);
    CTFontDescriptorRef bd = CTFontCopyFontDescriptor(base);
    NSDictionary *traits = @{ (id)kCTFontTraitsAttribute: @{ (id)kCTFontWeightTrait: @0.56 } };   // heavy, one step past the emphasized (bold) face
    CTFontDescriptorRef d = CTFontDescriptorCreateCopyWithAttributes(bd, (CFDictionaryRef)traits);
    CTFontRef f = CTFontCreateWithFontDescriptor(d, fs, NULL);
    t.font = f; t.fontSize = fs;
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f), w = fs * 3;
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(base); CFRelease(bd); CFRelease(d); CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _controls.frame = self.layer.bounds;
    if (_skin) {   // the skin's image controls, at fractions of the whole screen (k_skin); the drawn ones stay hidden
        CGRect b = self.bounds; CGFloat d = 0.148 * b.size.width; CGPoint hc = self.stickHome;
        _skinDisc.frame = CGRectMake(hc.x - d / 2, hc.y - d / 2, d, d);
        CGFloat kd = d * 0.67; _skinKnob.bounds = CGRectMake(0, 0, kd, kd); _skinKnob.position = hc;
        for (int i = 0; i < SKIN_N; i++) { CGFloat dd = k_skin[i].r * 2 * b.size.width * silkArtScale(k_skin[i].art); CGPoint c = skinCenter(i, b);
            _skinBtn[i].frame = CGRectMake(c.x - dd / 2, c.y - dd / 2, dd, dd); }
        if (_skipKey) { CGPoint c = skinCenter(5, b); CGFloat dd = k_skin[5].r * 2 * b.size.width; _skipKey.frame = CGRectMake(c.x - dd / 2, c.y - dd / 2, dd, dd); }   // the Skip medallion at the Bind key's place, at its size
        if (_padKey) { CGPoint c = skinCenter(7, b); CGFloat dd = k_skin[7].r * 2 * b.size.width; _padKey.frame = CGRectMake(c.x - dd / 2, c.y - dd / 2, dd, dd); }   // the Pad medallion at the eye key's place, at its size
        if (_sGlassBox) {
            for (int i = 0; i < SKIN_N; i++) if (_sGlass[i]) { CGFloat r = k_skin[i].r * b.size.width; CGPoint c = skinCenter(i, b);
                _sGlass[i].frame = CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r); _sGlass[i].layer.cornerRadius = r;
                setPath(_sWash[i], circlePath(c, r));
                if (_sLabel[i]) placeLabel(_sLabel[i], c, r * 1.02);
                else if (_sSym[i]) setPath(_sSym[i], k_skin[i].grp == SK_TOGGLE ? circlePath(c, r * 0.20) : symPath(c, r, k_skin[i].bit == B_PLUS)); }
            _sStick.frame = CGRectMake(hc.x - d / 2, hc.y - d / 2, d, d); _sStick.layer.cornerRadius = d / 2;
            CGFloat kd2 = d * 0.44; _sKnob.bounds = CGRectMake(0, 0, kd2, kd2); _sKnob.layer.cornerRadius = kd2 / 2; _sKnob.center = hc;   // the Hades glass knob's fraction: a solid disc at the medallion's 0.67 reads far bigger than the art, whose cap sits inside transparent margins
        }
        [CATransaction commit]; [self refresh]; return;
    }
    if (_hades) {   // the glass discs at fractions of the whole screen (k_hades); the stick disc is placed by refresh (it floats)
        CGRect b = self.bounds;
        _glassBox.frame = b;
        for (int i = 0; i < HADES_N; i++) { CGFloat r = k_hades[i].r * b.size.width;
            CGPoint c = hadesCenter(i, b);
            _hGlass[i].frame = CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r); _hGlass[i].layer.cornerRadius = r;
            setPath(_hWash[i], circlePath(c, r));
            if (_hLabel[i]) placeLabel(_hLabel[i], c, r * 1.02);
            else if (_hSym[i]) setPath(_hSym[i], symPath(c, r, k_hades[i].bit == B_PLUS));
            else setPath(_hTri[k_hades[i].dir], triPath(c, r * 0.44, k_hades[i].dir)); }
        for (int i = 0; i < HADES_N; i++) if (_hArt[i]) { CGFloat r = k_hades[i].r * b.size.width;
            CGPoint c = hadesCenter(i, b); CGFloat s = 2 * r / hadesArtF(k_hadesArt[i]);
            _hArt[i].frame = CGRectMake(c.x - s / 2, c.y - s / 2, s, s); }
        [CATransaction commit]; [self refresh]; return;
    }
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGPoint sc = self.swapCenter; setPath(_swap, circlePath(sc, K_SWAP_R * u)); placeLabel(_swapLabel, sc, 12 * u);
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    [CATransaction commit];
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
- (void)refresh {   // pressed state → fill, sticks → knob position
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; }
    _swap.fillColor = (_swapHeld ? k_on : k_idle).CGColor; _swapLabel.foregroundColor = (_swapHeld ? k_textOn : k_text).CGColor;
    CGPoint h = self.stickHome, o = [self knobOffset:0];
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor;
    if (_skin) {   // pressed keys swap to their _p art and dip; the eye key shows its _p art while the skill keys are hidden (and dims instead when the skin ships no eye _p art); the medallion knob follows the touch, kept inside the disc
        if (_sSkinMode) for (int i = 0; i < SKIN_N; i++) {
            if (k_skin[i].grp == SK_TOGGLE) { UIImage *p = _skillOff ? skinPressedImage(i) : nil;
                _skinBtn[i].contents = (id)(p ? p : skinImage(k_skin[i].art)).CGImage;
                _skinBtn[i].opacity = p ? 1.0 : (_skillOff ? 0.45 : 1.0); _skinBtn[i].transform = CATransform3DIdentity; continue; }
            _skinBtn[i].hidden = [self padHidden] || (_skillOff && k_skin[i].grp == SK_SKILL);
            BOOL on = (_btnBits >> k_skin[i].bit) & 1;
            UIImage *p = on ? skinPressedImage(i) : nil;
            _skinBtn[i].contents = (id)(p ? p : skinImage(k_skin[i].art)).CGImage;
            _skinBtn[i].opacity = 1.0;
            _skinBtn[i].transform = on ? CATransform3DMakeScale(0.93, 0.93, 1) : CATransform3DIdentity; }
        CGFloat ol = hypot(o.x, o.y), maxO = 0.30 * [self stickR:0];
        if (ol > maxO) { o.x *= maxO / ol; o.y *= maxO / ol; }
        _skinKnob.position = CGPointMake(h.x + o.x, h.y + o.y); _skinKnob.opacity = _stick[0] ? 1.0 : 0.95;
        if (!_sSkinMode) {   // the glass controls: a key's wash lit while it is pressed (the eye's while the skill keys are hidden), the skill discs hidden with the eye off, the knob following the touch
            for (int i = 0; i < SKIN_N; i++) { if (!_sWash[i]) continue;
                _sWash[i].opacity = (k_skin[i].grp == SK_TOGGLE ? _skillOff : ((_btnBits >> k_skin[i].bit) & 1)) ? 0.35 : 0;
                BOOL hid = [self padHidden] || (_skillOff && k_skin[i].grp == SK_SKILL);   // the whole key hides, letter and symbol with the disc: the glyph layers live in the overlay, not in the disc view
                if (_sGlass[i]) _sGlass[i].hidden = hid;
                if (_sLabel[i]) _sLabel[i].hidden = hid;
                if (_sSym[i]) _sSym[i].hidden = hid;
                _sWash[i].hidden = hid; }
            _sKnob.center = CGPointMake(h.x + o.x, h.y + o.y);
            _sStick.hidden = _sKnob.hidden = [self padHidden];
        }
        if (_skipKey && !_skipKey.hidden) { BOOL on = (_btnBits >> B_A) & 1;   // the Skip key presses like a skin key: A's bit swaps in its _p art and it dips (without _p art it only dips)
            UIImage *p = on ? namedPressedImage("skip") : nil;
            _skipKey.contents = (id)(p ? p : skinImage("skip")).CGImage;
            _skipKey.transform = on ? CATransform3DMakeScale(0.93, 0.93, 1) : CATransform3DIdentity; }
    }
    if (_hades) {   // pressed keys: wash lit and a small dip; the stick's glass follows its touch (full opacity), at half opacity at rest
        for (int i = 0; i < HADES_N; i++) { BOOL on = (_btnBits >> k_hades[i].bit) & 1;
            if (_hArt[i]) {   // skin key pressed: a small dip and a dim, no glow (the pack ships no pressed art)
                _hArt[i].transform = on ? CATransform3DMakeScale(0.93, 0.93, 1) : CATransform3DIdentity;
                _hArt[i].opacity = on ? 0.6 : 1.0; continue; }
            _hWash[i].opacity = on ? 0.28 : 0;
            _hGlass[i].transform = on ? CGAffineTransformMakeScale(0.93, 0.93) : CGAffineTransformIdentity;
            if (_hLabel[i]) _hLabel[i].foregroundColor = (on ? k_textOn : k_text).CGColor;
            if (k_hades[i].kind == H_DPAD) _hTri[k_hades[i].dir].fillColor = (on ? k_textOn : k_text).CGColor;
            if (_hSym[i]) _hSym[i].fillColor = (on ? k_textOn : k_text).CGColor; }
        CGPoint c = [self stickCentre:0]; CGFloat R = [self stickR:0];
        CGPoint so = [self knobOffset:0]; CGFloat ol = hypot(so.x, so.y), maxO = R * 0.56;
        if (ol > maxO) { so.x *= maxO / ol; so.y *= maxO / ol; }
        CGFloat kr = R * 0.44;
        [UIView performWithoutAnimation:^{
            _hStick.frame = CGRectMake(c.x - R, c.y - R, 2 * R, 2 * R); _hStick.layer.cornerRadius = R;
            _hKnob.frame = CGRectMake(c.x + so.x - kr, c.y + so.y - kr, 2 * kr, 2 * kr); _hKnob.layer.cornerRadius = kr;
            _hStick.alpha = _hKnob.alpha = _stick[0] ? 1.0 : 0.5;
        }];
        if (_hStickArt) { CGFloat S = 2 * R / HADES_ART_F;   // the pack's disc and knob at the glass disc's size, following its touch the same way
            _hStickArt.frame = CGRectMake(c.x - S / 2, c.y - S / 2, S, S); _hStickArt.opacity = _stick[0] ? 1.0 : 0.5; }
        if (_hKnobArt) { CGFloat S = 2 * R / HADES_ART_F;   // both canvases are the pack's own 512 squares, so one side serves both and the knob keeps its drawn size inside the disc
            _hKnobArt.bounds = CGRectMake(0, 0, S, S); _hKnobArt.position = CGPointMake(c.x + so.x, c.y + so.y); _hKnobArt.opacity = _stick[0] ? 1.0 : 0.5; }
    }
    [CATransaction commit];
}

// ---- Physical controllers ----
// Each controller with an extended gamepad profile is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins)
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static void read_pad(GCExtendedGamepad *g) {
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)g.controller); if (p < 0) return;
    dm_haptics_apple_controller(p, g.controller);
    uint64_t m = 0;
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.buttonB, B_A); K(g.buttonA, B_B); K(g.buttonY, B_X); K(g.buttonX, B_Y);   // by position: right A, bottom B, top X, left Y
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    dm_pad_set_player(p, m, axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value), axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value));
}
// Home and Capture: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); the app gives them no function
static void pad_keep_system_buttons(GCController *c) { for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled; }
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) { gone.extendedGamepad.valueChangedHandler = nil; dm_motion_detach(gone, 0); }
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && c.extendedGamepad) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_keep_system_buttons(c); c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c.extendedGamepad);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16];
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        g_held[p].extendedGamepad.valueChangedHandler = nil;
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c.extendedGamepad && c != gone && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_keep_system_buttons(c);
        c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *g, GCControllerElement *el) { (void)el; read_pad(g); };
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c.extendedGamepad);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    return pad_slot_mask(&g_slots) != 0;
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (c && (!c.extendedGamepad || g_merge)) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), c.extendedGamepad ? "" : " (no extended gamepad profile: not used)");
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{ self->_padOff = any; self->_controls.hidden = any; self->_glassBox.hidden = any; if (self->_sGlassBox) self->_sGlassBox.hidden = self->_sSkinMode >= 1 || any; [self reset]; });   // the touch gamepad hides while any controller is in use
}
@end

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; });
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
