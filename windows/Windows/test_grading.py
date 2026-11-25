"""Automatic colour grading: LUT maths, analysis, FFmpeg/preview parity."""
import json, os, subprocess, tempfile, unittest
from pathlib import Path
import numpy as np
from PIL import Image
import grading
from core import tool, CREATE_FLAGS


class GradingTests(unittest.TestCase):
    def test_neutral_is_identity(self):
        t = grading.table(dict(look='none', correct=False))
        i = np.linspace(0, 1, grading.SIZE); b, g, r = np.meshgrid(i, i, i, indexing='ij')
        self.assertLess(abs(t - np.stack([r, g, b], -1).reshape(-1, 3)).max(), 1e-6)

    def test_new_fields_default_neutral_and_clamp(self):
        old = dict(look='none', correct=False)
        a = grading.table(old); b = grading.table(dict(old, basic={}, wheels={}))
        self.assertTrue(np.array_equal(a, b))
        old = dict(look='natural', auto=dict(black=.04, white=.92, gamma=.94, wb=[1.02, .99, .98], flat=False))
        i = np.linspace(0, 1, grading.SIZE); blue, green, red = np.meshgrid(i, i, i, indexing='ij')
        grid = np.stack([red, green, blue], -1).reshape(-1, 3)
        g = grading.normalized(old); base = grading.correct(grid, g['auto'])
        expected = np.ascontiguousarray(np.clip(base + (grading.look(base, grading.LOOKS[g['look']]) - base) * g['amount'], 0, 1), dtype=np.float32)
        self.assertTrue(np.array_equal(grading.table(old), expected))
        g = grading.normalized(dict(basic=dict(exposure=99, contrast=-2), wheels=dict(lift=[1, 0, 0])))
        self.assertEqual(g['basic']['exposure'], 5); self.assertEqual(g['basic']['contrast'], 0)
        self.assertEqual(g['wheels']['lift'], [.25, 0, 0])

    def test_primary_wheels_and_basic_adjustments_change_lut(self):
        rgb = np.array([[.2, .3, .4], [.7, .6, .5]])
        base = grading.apply(rgb, dict(look='none', correct=False))
        grade = dict(look='none', correct=False, wheels=dict(lift=[.1, 0, 0]), basic=dict(exposure=.5))
        self.assertFalse(np.allclose(base, grading.apply(rgb, grade)))

    def test_normalized_clamps_and_defaults(self):
        g = grading.normalized(dict(look='nope', amount=9, auto=dict(black=-1, white='x', wb=[5, 0, 1])))
        self.assertEqual(g['look'], grading.DEFAULT_LOOK); self.assertEqual(g['amount'], 1.5)
        self.assertEqual(g['auto']['black'], 0); self.assertEqual(g['auto']['white'], 1); self.assertEqual(g['auto']['wb'], [1.25, .8, 1])
        self.assertIsNone(grading.normalized('bad'))

    def test_every_look_is_monotonic_in_grey(self):
        grey = np.linspace(0, 1, 64)[:, None].repeat(3, 1)
        for look in grading.LOOKS:
            y = grading.apply(grey, dict(look=look, correct=False)) @ grading.LUMA
            self.assertTrue(np.all(np.diff(y) >= -1e-3), look)

    def test_flat_footage_gets_stretched(self):
        rng = np.random.default_rng(1); flat = (.12 + .6 * rng.random((90, 160, 1)) ** 1.5) * np.array([1, .98, .95])
        auto = grading.stats([flat.astype(np.float32)])
        self.assertTrue(auto['flat']); self.assertGreater(auto['black'], .1)
        out = grading.apply(flat.reshape(-1, 3), dict(look='none', auto=auto)) @ grading.LUMA
        self.assertGreater(np.percentile(out, 99.5) - np.percentile(out, .5), .85)

    def test_match_aims_at_a_common_grey(self):
        a, b = grading.match([dict(median=.2, gamma=1), dict(median=.5, gamma=1)])
        self.assertLess(a['gamma'], 1); self.assertGreater(b['gamma'], 1)

    def test_ffmpeg_lut_matches_preview(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / 'in.png'; out = Path(tmp) / 'out.png'
            x = np.linspace(0, 255, 256, dtype=np.uint8); img = np.stack(np.meshgrid(x, x[::-1]), -1)
            Image.fromarray(np.dstack([img, x[None, :].repeat(256, 0) // 2]).astype(np.uint8)).save(src)
            grade = dict(look='alpine', auto=dict(black=.08, white=.9, gamma=.9, wb=[1.01, 1, .98], flat=True),
                         basic=dict(exposure=.25, contrast=1.15, pivot=.48, saturation=1.1, vibrance=.2),
                         wheels=dict(lift=[.01, 0, -.01], gamma=[0, .01, 0], gain=[.01, 0, 0]))
            subprocess.run([tool('ffmpeg'), '-v', 'error', '-y', '-i', str(src), '-vf', 'format=rgba,' + grading.ffmpeg_filter(grade, tmp), str(out)],
                           check=True, creationflags=CREATE_FLAGS)
            a = np.asarray(Image.open(out).convert('RGB'), dtype=float)
            b = np.asarray(grading.pil(Image.open(src).convert('RGBA'), grade).convert('RGB'), dtype=float)
            self.assertLess(abs(a - b).mean(), 2.0)

    def test_effects_route_grade_to_both_paths(self):
        from effects import color, color_filters, validate
        e = dict(grade=dict(look='golden'))
        validate(e); self.assertTrue(color_filters(e)[0].startswith('lut3d='))
        im = Image.new('RGBA', (8, 8), (90, 100, 110, 255)); self.assertNotEqual(color(im, e).getpixel((0, 0)), im.getpixel((0, 0)))
        with self.assertRaises(ValueError): validate(dict(grade='x'))

    def test_dji_srt_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, 'DJI_0001.SRT').write_text('1\n[iso : 110] [color_md : d_cinlike] [focal_len : 240]', encoding='utf-8')
            self.assertEqual(grading.srt_profile(Path(tmp, 'DJI_0001.MP4')), 'd_cinlike')
            self.assertIsNone(grading.srt_profile(Path(tmp, 'none.MP4')))


if __name__ == '__main__':
    unittest.main()
