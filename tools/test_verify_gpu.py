"""Regression checks for false positives in the GPU verifier."""
import sys
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_gpu import CONFIG, evaluate, run_check
from test_gpu_ux import inspect_testsrc_png


class TestsrcFrameChecks(unittest.TestCase):
    @staticmethod
    def png(depth, color, black=False):
        def chunk(kind, payload):
            return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
        width, height = 16, 16
        maximum = (1 << depth) - 1
        pixels = []
        for x in range(width):
            rgb = [0, 0, 0]
            if not black:
                rgb[x % 3] = maximum
            if color == 6:
                rgb.append(maximum)
            pixels.extend(rgb)
        row = bytes(pixels) if depth == 8 else struct.pack('>' + 'H' * len(pixels), *pixels)
        header = struct.pack('>IIBBBBB', width, height, depth, color, 0, 0, 0)
        return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) +
                chunk(b'IDAT', zlib.compress((b'\0' + row) * height)) + chunk(b'IEND', b''))

    def test_colored_rgb_and_rgba_frames(self):
        for depth, color in ((8, 2), (16, 6)):
            with self.subTest(depth=depth, color=color):
                self.assertTrue(inspect_testsrc_png(self.png(depth, color))['valid'])

    def test_black_dummy_frame_is_not_valid_output(self):
        for depth, color in ((8, 2), (16, 6)):
            with self.subTest(depth=depth, color=color):
                self.assertFalse(inspect_testsrc_png(self.png(depth, color, black=True))['valid'])

    def test_corrupt_and_truncated_png_fail(self):
        good = self.png(16, 6)
        bad = bytearray(good)
        bad[20] ^= 1
        for data in (b'', good[:40], bad):
            self.assertFalse(inspect_testsrc_png(data)['valid'])


class FailureChecks(unittest.TestCase):
    def test_no_log_or_frames_cannot_pass(self):
        self.assertFalse(evaluate(0, '', [])[0])
        self.assertFalse(evaluate(0, 'finished playback, success', [])[0])

    def test_timeout_and_nonzero_cannot_pass(self):
        self.assertFalse(evaluate(0, 'success', [], timed_out=True)[0])
        self.assertFalse(evaluate(1, 'success', [])[0])

    def test_disabled_filter_cannot_pass(self):
        self.assertFalse(evaluate(0, 'Disabling filter vapoursynth', [])[0])

    def test_real_broken_vpy(self):
        mpv = CONFIG.parent / 'mpv.com'
        if not mpv.exists():
            self.skipTest('local mpv.com missing')
        with tempfile.TemporaryDirectory(prefix='mpv-check-') as temp:
            root = Path(temp)
            broken = root / 'broken.vpy'
            broken.write_text('raise RuntimeError("intentional integration failure")\n', encoding='utf-8')
            result = run_check(mpv, broken, 'vs', root / 'result', 30)
            self.assertFalse(result['passed'], result)

    def test_real_timeout(self):
        mpv = CONFIG.parent / 'mpv.com'
        if not mpv.exists():
            self.skipTest('local mpv.com missing')
        with tempfile.TemporaryDirectory(prefix='mpv-timeout-') as temp:
            root = Path(temp)
            slow = root / 'slow.vpy'
            slow.write_text('import time\ntime.sleep(8)\n', encoding='utf-8')
            result = run_check(mpv, slow, 'vs', root / 'result', 1)
            self.assertFalse(result['passed'], result)
            self.assertEqual(result['reason'], 'timeout')


if __name__ == '__main__':
    unittest.main()
