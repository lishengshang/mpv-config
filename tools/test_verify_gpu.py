"""Regression checks for false positives in the GPU verifier."""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_gpu import CONFIG, evaluate, run_check


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
