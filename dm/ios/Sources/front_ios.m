// iOS front end (the iOS implementation of front.h): a centered 16:9 Metal view (black bars on both sides) + a full-screen virtual gamepad layer (DmGamepad.m, controls drawn over the picture).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#include <errno.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "haptics_apple.h"
#include "save_sync.h"
#import "CloudSaves.h"

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_reset(void);
void dm_gamepad_active(void);
void front_ios_boot(void);
int front_ios_boot_ok(void);
const char *front_ios_boot_message(void);   // main.m: why a build that keeps the game files off the IPA found none usable (NULL = the generic hint)
bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0)

static CAMetalLayer *g_layer;
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);

@interface DmGameView : UIView
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = UIScreen.mainScreen.nativeScale; l.framebufferOnly = NO; l.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    l.drawableSize = CGSizeMake(self.bounds.size.width * l.contentsScale, self.bounds.size.height * l.contentsScale);
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UILabel *fps;
@property (nonatomic) BOOL launched;
- (void)startGame;
@end
static DmRootVC *g_root;
static void launcher_done(void) { [g_root startGame]; }

// The render size the guest renders at: the docked height 1080 at the screen's own aspect, so one build fills an iPhone and an iPad
// alike instead of a width baked when the IPA was made. The host writes it into the frame step state page when the game starts
// (DM_RENDER_WIDTH, loader.c dm_fps_state_apply), where the stubs at the game's baked size constants read it. The handheld
// height 720 gets the same treatment beside it (DM_RENDER_WIDTH_HD, state +0x40 and the handheld host fill), for the builds
// whose handheld sizes read them; the fallbacks are the widths the builds baked (2344 docked, 1280 handheld)
static int front_ios_render_width_h(int height) {
    CGSize n = UIScreen.mainScreen.nativeBounds.size;   // physical pixels, in portrait
    CGFloat w = MAX(n.width, n.height), h = MIN(n.width, n.height);
    int baked = height == 720 ? 1280 : 2344;
    if (h <= 0) return baked;
    int rw = (int)(height * w / h) & ~7;   // down to a multiple of 8, as every baked width was
    return rw >= 320 ? rw : baked;
}
static int front_ios_render_width(void) { return front_ios_render_width_h(1080); }

// The launcher's frame-rate choice (SS_DISPLAY_HZ, settings.tsv; only a game whose profile offers it, game.tsv display_hz, shows
// the choice): 60, 120, or 120 at a lowered render size. The choice is a request, not a fact: the display link below asks the
// screen for 80-120 Hz and measures the rate the screen truly runs at, and only a rate that holds for 30 display frames is
// handed to the host (dm_display_set_hz, hle_nvn.c), which moves the present tick, the present display link and the vi vsync
// event to it; a screen that falls back to 60 Hz (a 60 Hz panel, Low Power Mode, heat) hands 60 back and releases the mode.
// The lowered tier renders at 1912x880, the touch port of Silksong's 1916x882 tier taken to a multiple of 8 (a render width
// must be one, loader.c: 1916 was refused there and the full width used instead, which squeezed the picture): the
// width goes through the state page's docked cell as any render width does, the height through DM_RENDER_HEIGHT (loader.c)
static int front_ios_display_hz(void) { const char *e = getenv("SS_DISPLAY_HZ"); return e ? atoi(e) : 60; }
static int front_ios_display_lowered(void) { const char *e = getenv("SS_DISPLAY_HZ"); return e && strchr(e, 'L') != NULL; }

@interface DmRateLink : NSObject
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) int cur, ticks;
+ (void)startIfWanted;
- (void)tick:(CADisplayLink *)link;
@end
static DmRateLink *g_rate_link;
@implementation DmRateLink
+ (void)startIfWanted {
    int want = front_ios_display_hz();
    if (want <= 60 || g_rate_link) return;
    g_rate_link = [DmRateLink new];
    g_rate_link.link = [CADisplayLink displayLinkWithTarget:g_rate_link selector:@selector(tick:)];
    g_rate_link.link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [g_rate_link.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    LOG("front end: display rate %d Hz requested; the rate the screen holds decides (SS_DISPLAY_HZ)", want);
}
- (void)tick:(CADisplayLink *)link {
    double dt = link.targetTimestamp > link.timestamp ? link.targetTimestamp - link.timestamp : 0;
    int hz = dt > 0 && dt < 1.0 / 90 ? 120 : 60;   // a frame interval under 1/90 s is a 120 Hz screen; anything else counts as 60
    if (hz == self.cur) { self.ticks = 0; return; }
    if (++self.ticks < 30) return;   // the rate must hold for 30 display frames before the host follows it, either way
    self.cur = hz; self.ticks = 0;
    dm_display_set_hz(hz);
}
@end

// Hades II's HUD lays out against the size its script computes in RunLogic.lua (UpdateConfigOptionCache), which reads the engine's
// config options X/Y -- 1920x1080 whatever the renderer does, so without this the HUD keeps the 1920 canvas at any render width (the
// wide builds were played with the two lines below written by hand to the baked width; this writes the measured one instead). The line
// is matched in the script's own form (a config read) and in the hand-written form (literals) alike, so the write is idempotent across
// launches and a fresh datapack extract; exactly one match of each is required, any other shape leaves the file untouched. Only a
// Documents RomFS can be written (the slim layout); a bundle RomFS keeps the script as shipped
static void front_ios_hud_script_fix(int width) {
    const char *romfs = getenv("DM_ROMFS");
    if (!romfs) return;
    NSString *path = [@(romfs) stringByAppendingPathComponent:@"Scripts/RunLogic.lua"];
    if (![NSFileManager.defaultManager isWritableFileAtPath:path]) return;
    NSString *txt = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!txt) { LOG("[RED] front end: %s could not be read; HUD script left as is", path.UTF8String); return; }
    NSMutableArray<NSString *> *lines = [[txt componentsSeparatedByString:@"\n"] mutableCopy];
    for (NSString *s in @[@"Width", @"Height"]) {
        NSString *pre = [NSString stringWithFormat:@"\tlocal actual%@ = ", s], *stock = [NSString stringWithFormat:@"GetConfigOptionValue({ Name = \"%@\" })", [s isEqual:@"Width"] ? @"X" : @"Y"];
        int at = -1;
        for (int i = 0; i < (int)lines.count; i++) {
            NSString *ln = lines[i], *body = [ln hasSuffix:@"\r"] ? [ln substringToIndex:ln.length - 1] : ln;   // the script's lines end CRLF
            if (![body hasPrefix:pre]) continue;
            NSString *v = [body substringFromIndex:pre.length];
            if ([v isEqualToString:stock] || (v.length && [v rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound)) { if (at >= 0) { at = -2; break; } at = i; }
        }
        if (at < 0) { LOG("[RED] front end: RunLogic.lua: the actual%@ line is not in a known form; HUD script left as is", s.UTF8String); return; }
        lines[at] = [NSString stringWithFormat:@"%@%d%@", pre, [s isEqual:@"Width"] ? width : 1080, [lines[at] hasSuffix:@"\r"] ? @"\r" : @""];
    }
    NSString *out = [lines componentsJoinedByString:@"\n"];
    if ([out isEqualToString:txt] || [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil])
        LOG("front end: HUD script at the render size %dx1080 (%s)", width, path.UTF8String);
    else LOG("[RED] front end: %s could not be written; HUD script left as is", path.UTF8String);
}
@implementation DmRootVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    front_ios_power_watch();
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        const char *why = front_ios_boot_message();
        lb.text = why ? [NSString stringWithFormat:@"Game files unusable.\n%s", why] : @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart.";
        [self.view addSubview:lb]; return;
    }
    front_ios_audio_watch();
}
// The game view, the pad and the frame-rate counter are made once the launcher has set the switches they read (DM_SHOW_FPS, DM_METAL_HUD); the host's loading began at app launch (main.m)
- (void)startGame {
    if (self.game) return;
    dm_cloud_saves_env();   // DM_SAVE_SYNC from the launcher's Cloud saves pick, before the game's first save mount reads it (CloudSaves.m, save_sync.h)
    front_hud_env();   // before the game view makes its device (an env file's DM_METAL_HUD sets it in main.m already)
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
    dm_haptics_apple_init();
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    self.fps = front_ios_fps_label();   // above the pad, which hides while a controller is connected
    if (self.fps) [self.view addSubview:self.fps];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    if (front_ios_display_lowered()) {   // the frame-rate choice's lowered tier, unless an env file sets the size itself
        if (!getenv("DM_RENDER_WIDTH")) setenv("DM_RENDER_WIDTH", "1912", 1);
        if (!getenv("DM_RENDER_HEIGHT")) setenv("DM_RENDER_HEIGHT", "880", 1);
    }
    if (!getenv("DM_RENDER_WIDTH")) setenv("DM_RENDER_WIDTH", [NSString stringWithFormat:@"%d", front_ios_render_width()].UTF8String, 1);   // the render size follows this screen (an env file's value is a diagnostic override and is kept); before the host starts, whose game-start write reads it
    if (!getenv("DM_RENDER_WIDTH_HD")) setenv("DM_RENDER_WIDTH_HD", [NSString stringWithFormat:@"%d", front_ios_render_width_h(720)].UTF8String, 1);   // the same at the handheld height, for the builds whose handheld sizes read it
    int rw = atoi(getenv("DM_RENDER_WIDTH")); if (rw < 320 || rw > 16384 || rw % 8) rw = 2344;   // the host's own validation (loader.c), so the script and the renderer cannot disagree
    front_ios_hud_script_fix(rw);   // Hades II's HUD script gets the same width (a no-op for other games: no such file)
    front_ios_boot();
    [DmRateLink startIfWanted];   // the frame-rate choice above 60 Hz: ask the screen for it and follow the rate it holds
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; if (!self.game) return;
    // The game view always takes the whole screen. The compositor (nvn_mtl's present) fits the game's
    // actual picture inside it keeping the picture's own aspect ratio, or fills the screen under
    // DM_FULLSCREEN. Fitting the view itself to a fixed 16:9 here shrank the picture twice for games
    // that render wider than 16:9: once by the narrower view, then again by the compositor fitting
    // their wider picture into that view (black bars on all four sides, height included).
    self.game.frame = b;
    if (self.fps) {   // the top row's free stretch: right of DmGamepad.m's L3 key (102 + 17 of its units from the safe edge), level with − / + (22 units down); u is its unit
        CGRect s = UIEdgeInsetsInsetRect(b, self.view.safeAreaInsets); CGFloat u = MIN(b.size.height / 430.0, 1.3);
        self.fps.frame = CGRectMake(floor(CGRectGetMinX(s) + 130 * u), floor(CGRectGetMinY(s) + 22 * u - 11), 64, 22);
    }
}
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a];
    if (!front_ios_boot_ok() && front_ios_boot_message() && !self.presentedViewController) {   // a slim build whose game file image is missing or another version (main.m)
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Game files" message:@(front_ios_boot_message()) preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
    if (self.launched || !front_ios_boot_ok()) return;
    self.launched = YES; g_root = self;
    if (!dm_show_launcher((__bridge void *)self, launcher_done)) [self startGame];   // the settings screen first (Launcher.swift), when the app has one
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

// Thermal state and screen brightness for the power and present rows every 300 frames (hle_nvn.c; its weak defaults return -1 on the Mac). thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
// Brightness is read on the main thread at start and on each change; every change of the thermal state and of Low Power Mode (which lowers the CPU clock) is logged with the time since launch
static _Atomic double g_brightness = -1;
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }   // the frame step does not probe in it (hle_nvn.c fstep_cpu_slowed)
double dm_brightness_now(void) { return g_brightness; }
static void front_ios_power_watch(void) {
    g_brightness = UIScreen.mainScreen.brightness;
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; g_brightness = UIScreen.mainScreen.brightness; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9); }];
    LOG("front end: thermal state %d, brightness %.2f, Low Power Mode %s", dm_thermal_now(), g_brightness, dm_low_power_now() ? "on" : "off");
}

// Frame-rate counter: the frames put on screen in the last second (nvn_mtl.m counts them for NVN and for the Vulkan layer alike; frames the display link merged away are not counted).
// On when the IPA was built with it (the NSP script's SHOW_FPS / --show-fps → DMShowFPS in Info.plist); DM_SHOW_FPS=0 / 1 in Documents/env.txt overrides that without a rebuild. NULL when off
uint64_t mtl_present_count(void);
static UILabel *front_ios_fps_label(void) {
    const char *e = getenv("DM_SHOW_FPS");
    if (!(e ? atoi(e) != 0 : [[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMShowFPS"] boolValue])) return nil;
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold]; l.textColor = UIColor.whiteColor; l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; l.layer.cornerRadius = 6; l.layer.masksToBounds = YES; l.userInteractionEnabled = NO;
    l.text = @"-- fps";
    __block uint64_t n0 = mtl_present_count(); __block double t0 = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t; uint64_t n = mtl_present_count(); double now = CACurrentMediaTime();
        if (now - t0 < 1.5) l.text = [NSString stringWithFormat:@"%.0f fps", (n - n0) / (now - t0)];   // a longer span is the time in the background: no reading
        n0 = n; t0 = now;
    }];
    LOG("front end: frame-rate counter on");
    return l;
}

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's view and the pad, the title, a bar and a count, centered; UIKit views, so it draws while the game's thread waits
static UIView *g_prog; static UILabel *g_prog_count; static UIProgressView *g_prog_bar; static UILabel *g_prog_title;
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; return; }
        if (!g_prog) {
            UIView *root = g_root.view; if (!root) return;
            g_prog = [[UIView alloc] initWithFrame:root.bounds]; g_prog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            g_prog.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(floor((root.bounds.size.width - 320) / 2), floor((root.bounds.size.height - 96) / 2), 320, 96)];
            box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            g_prog_title = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 320, 30)]; g_prog_title.textAlignment = NSTextAlignmentCenter; g_prog_title.textColor = UIColor.whiteColor;
            g_prog_title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
            g_prog_bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; g_prog_bar.frame = CGRectMake(20, 48, 280, 4);
            g_prog_count = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 320, 22)]; g_prog_count.textAlignment = NSTextAlignmentCenter;
            g_prog_count.textColor = [UIColor colorWithWhite:0.72 alpha:1]; g_prog_count.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [root addSubview:g_prog];
        }
        g_prog_title.text = tt; g_prog_bar.progress = total > 0 ? (float)done / (float)total : 0;
        g_prog_count.text = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                             [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}
void *front_metal_layer(void) { return (__bridge void *)g_layer; }
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    // The guest clock keeps running meanwhile, as on the Switch (hle_swkbd.c): a freeze here as well stopped Octopath Traveler 0's frame loop for as long as the box was up and made its sound stutter
    // (4,977 ms and 2,577 ms frames, 5,181 wakeups a second). The inline keyboard freezes around its own call (hle_swkbd.c)
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game. hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("front end: save data write failed errno=%d, telling the player", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("[RED] front end: no window for the save-failure alert errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"Storage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"Saving failed (errno %d); progress was not saved.", err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category is Playback, as a game's or media app's: the ring / silent switch does not mute it (the default SoloAmbient follows the switch, which silenced the game whenever the phone was on silent) and it still interrupts other apps' audio.
// Set once at boot and again on return to the foreground (the system may reset it after an interruption)
static int g_session_off;   // the last activation failed (another app or a call still held the session): tried again when the app becomes active
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategoryPlayback error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    LOG("audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for 5 ms)", s.sampleRate, s.IOBufferDuration * 1000);
}

// Real audio output is suspended (the silent sink paces the game) while the app is in the background or another audio session has interrupted ours (Siri, an alarm, a call).
// Without the interruption observer the AudioUnits stayed "started" while iOS no longer called them, and a game waiting for its buffers back lost its sound until restart.
// All of this runs on the main queue, like the scene callbacks
static int g_audio_bg, g_audio_intr;
static void front_ios_audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
static void front_ios_audio_watch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue], reason = [n.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) { LOG("audio session: interrupted (reason %lu)", (unsigned long)reason); g_audio_intr = 1; }
        else {
            LOG("audio session: interruption ended"); g_audio_intr = 0;
            if (!g_audio_bg) front_ios_audio_session();
        }
        front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; LOG("audio session: the media services were reset; setting the session and the outputs up again");
        front_ios_audio_session(); dm_audio_reset();
    }];
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed).
// The screen stays on while the game is active: only touches reset the idle timer, so with a controller (or during a cutscene) the screen dimmed and locked mid-game
// Cloud saves (save_sync.h): what the game committed goes out before iOS suspends the app, without the sender's quiet wait. iOS gives a background task about half a minute
static void save_sync_background(void) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^end)(void) = ^{ if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; } };   // on the main queue, as the expiry handler runs
    task = [app beginBackgroundTaskWithName:@"cloud save" expirationHandler:end];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!save_sync_flush(20000)) LOG("front end: the save did not reach the cloud before the app was suspended; it goes after the next save or at the next start");
        dispatch_async(dispatch_get_main_queue(), end);
    });
}

void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); save_sync_background(); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); break;
        case 3:   // Becoming active again also ends an interruption whose "ended" never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); dm_gamepad_active(); dm_focus_set(1); break;
    }
}
