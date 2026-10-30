"""Guards for this fork's own changes, which upstream does not carry: an upstream merge can drop one without a
conflict (the changes sit inside files upstream also edits), and the loss only shows on a device. Each test names
one change and the file it must survive in: the DM_NVN_DESWZ_GPU switch and the BC1-BC5 transcode in the NVN
Metal host, the display-rate serving beside upstream's Frostbite rate in the fps lock, the launcher's skin rows
in the settings table, the three games' profile keys, and the IPA workflow's own fetch/pack options."""
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


class NvnMetalHost(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mtl = read('dm/gfx/nvn/nvn_mtl.m')

    def test_deswz_gpu_switch_gates_the_gpu_deswizzle(self):
        self.assertIn('getenv("DM_NVN_DESWZ_GPU")', self.mtl)
        self.assertIn('g_nvn_deswz_gpu = !deswz_env_off && nvn_deswz_gpu_init(g_dev) == 0;', self.mtl)

    def test_bc_transcode_survives(self):
        self.assertIn('static int fmt_mtl_dev(int f', self.mtl)   # the device-format wrapper answering the RGBA8 twin
        self.assertIn('static void bc_decode_image(', self.mtl)
        self.assertIn('int direct = !xcode', self.mtl)   # a decompressed texture never takes the direct upload
        self.assertIn('int use_gpu = !xcode', self.mtl)   # ... nor the GPU deswizzle staging

    def test_bc_refusal_is_per_format_not_per_device(self):
        # Upstream 6d880d23 refuses a GPU without BC wholesale (before the launcher, and again at device init);
        # this fork transcodes BC1-BC5 for such GPUs instead, so both device-level refusals are out and the
        # refusal sits on the one format family with no transcode, at the texture's creation
        main = read('dm/ios/Sources/main.m')
        self.assertNotIn('supportsBCTextureCompression', main)   # no whole-device refusal before the launcher
        self.assertNotIn('has no BC texture formats', self.mtl)   # ... and none at device init either
        self.assertIn('static int fmt_bc67(int f) { return f >= 0x4d && f <= 0x50; }', self.mtl)   # BC7 .. BC6H_UF
        self.assertIn('if (fmt_bc67(t->d.format) && !bc_native()) MDIE(', self.mtl)   # refused in tex_desc, on a GPU without BC only
        self.assertIn('getenv("DM_NVN_DESWZ_GPU")', self.mtl)   # the fork's other NVN switches stay beside it
        self.assertIn('getenv("DM_PRESENT_CLASSIC")', self.mtl)

    def test_upload_forward_declaration_matches_upstream_signature(self):
        self.assertIn('pkg_upload_(const tex_t *t, uint64_t *stamp, id<MTLTexture> reuse, MTLTextureUsage keep);', self.mtl)
        self.assertIn('d.usage |= keep & (MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView);', self.mtl)


class FpsLock(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = read('dm/host/hle_fpslock.c')

    def test_both_sides_rows_survive(self):
        self.assertIn('"fc9ea4ccc955d5799f37752b2d730b31", "Unity targetFrameRate"', self.src)   # the fork's: Silksong
        self.assertIn('"799d1061182c1302e08e706b84ce76e5", "Criterion 60 fps mode"', self.src)   # upstream's: Need for Speed
        self.assertIn('"a48c0de3bc353efa0e4d359bde05ef24", "FIFA frame regulator"', self.src)   # upstream's: EA SPORTS FC

    def test_display_rate_serving_and_frostbite_tick_coexist(self):
        self.assertIn('int dtgt = dm_display_hz() == 120 ? 120 : 0;', self.src)
        self.assertIn('fb_tick(target, src);', self.src)


class SettingsTable(unittest.TestCase):
    def test_skin_rows_and_enc_thread_default(self):
        rows = {line.split('\t')[0]: line for line in read('dm/games/settings.tsv').splitlines() if line and not line.startswith('#')}
        self.assertIn('DM_HADES_SKIN', rows)
        self.assertIn('DM_SILK_SKIN', rows)
        self.assertIn('DM_GAME_ENC_THREAD', rows['DM_NVN_ENC_THREAD'])


class GameProfiles(unittest.TestCase):
    def test_profile_keys_survive(self):
        hades = read('dm/games/0100A00019DE0000/game.tsv')
        self.assertIn('display_wide', hades)
        self.assertIn('serve_patch', hades)
        silk = read('dm/games/010013C00E930000/game.tsv')
        self.assertIn('pad_skin_toggle', silk)
        self.assertIn('serve_patch', silk)
        dsr = read('dm/games/01004AB00A260000/game.tsv')
        self.assertIn('pad_layout\tfull', dsr)
        self.assertIn('v196608', dsr)


class BuildWorkflow(unittest.TestCase):
    def test_ipa_workflow_keeps_the_forks_options(self):
        yml = read('.github/workflows/build-ipa.yml').lower()
        for marker in ('split', 'romfs', 'skin', 'nsz', 'gdown', 'drive'):
            self.assertIn(marker, yml)


if __name__ == '__main__':
    unittest.main()
