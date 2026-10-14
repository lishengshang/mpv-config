"""Failure-oriented regression tests; no GPU/runtime dependency."""
import sys
import tempfile
import unittest
import shutil
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_config import CONFIG, Checker

MPV = next((CONFIG.parent / name for name in ('mpv.com', 'mpv.exe') if (CONFIG.parent / name).is_file()), None)
MPV = MPV or shutil.which('mpv')


class ReferenceChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mpv-config-check-')
        self.root = Path(self.temp.name)
        self.write('mpv.conf', 'include="~~/profiles.conf"\ninclude="~~/local.conf"\nprofile=valid\n')
        self.write('profiles.conf', '[valid]\n')
        self.write('input.conf', '')

    def tearDown(self):
        self.temp.cleanup()

    def write(self, file, text):
        path = self.root / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def findings(self):
        return Checker(self.root).run()

    def test_optional_private_file_never_read(self):
        (self.root / 'local.conf').write_bytes(b'\xffprivate')
        self.assertEqual(self.findings(), [])

    def test_missing_shader_in_profile_reports_location(self):
        self.write('profiles.conf', '[valid]\nglsl-shaders="~~/shaders/missing.glsl"\n')
        finding = self.findings()[0]
        self.assertEqual((finding.rule, finding.file, finding.line), ('missing-asset', 'profiles.conf', 2))

    def test_missing_vpy_inside_nested_command(self):
        self.write('input.conf', 'x script-message cycle-commands "vf toggle vapoursynth=\\"~~/vs/missing.vpy\\""\n')
        self.assertEqual(self.findings()[0].rule, 'missing-asset')

    def test_comment_references_do_not_count(self):
        self.write('input.conf', '#x apply-profile absent\nx ignore # ~~ /none; apply-profile absent\n')
        self.write('profiles.conf', '[valid]\n#glsl-shaders="~~/none.glsl"\n')
        self.assertEqual(self.findings(), [])

    def test_forward_reference_and_profile_list(self):
        self.write('mpv.conf', 'profile=valid,other\ninclude="~~/profiles.conf"\n')
        self.write('profiles.conf', '[valid]\n[other]\n')
        self.assertEqual(self.findings(), [])

    def test_missing_profile_in_cycle_command(self):
        self.write('input.conf', 'x script-message cycle-commands "apply-profile absent;show-text test"\n')
        self.assertEqual(self.findings()[0].rule, 'missing-profile')

    def test_include_cycle_is_error(self):
        self.write('profiles.conf', '[valid]\ninclude="~~/mpv.conf"\n')
        self.assertTrue(any(f.rule == 'include-cycle' for f in self.findings()))

    def test_missing_include_is_error(self):
        self.write('mpv.conf', 'include="~~/absent.conf"\n')
        self.assertTrue(any(f.rule == 'missing-include' for f in self.findings()))

    def test_external_include_not_read(self):
        self.write('mpv.conf', 'include="~~/../outside.conf"\n')
        findings = self.findings()
        self.assertEqual(findings[0].rule, 'external-path')
        self.assertFalse(any(f.severity == 'error' for f in findings))


@unittest.skipUnless(MPV, 'Native checks require mpv with Lua support')
class NativeChecks(unittest.TestCase):
    setUp = ReferenceChecks.setUp
    tearDown = ReferenceChecks.tearDown
    write = ReferenceChecks.write

    def findings(self):
        return Checker(self.root).run(MPV)

    def test_modifier_alias_collision(self):
        self.write('input.conf', 'CTRL+SHIFT+a ignore\nCTRL+A ignore\n')
        duplicate = [f for f in self.findings() if f.rule == 'duplicate-key']
        self.assertEqual(len(duplicate), 1)
        self.assertEqual(duplicate[0].line, 2)

    def test_case_and_section_are_distinct(self):
        self.write('input.conf', 'CTRL+a ignore\nCTRL+A ignore\na {one} ignore\na {two} ignore\n')
        self.assertFalse(any(f.severity == 'error' for f in self.findings()))

    def test_mouse_alias_collision(self):
        self.write('input.conf', 'MOUSE_BTN0 ignore\nMBTN_LEFT ignore\n')
        self.assertTrue(any(f.rule == 'duplicate-key' for f in self.findings()))

    def test_event_actions_and_conditions_are_distinct(self):
        self.write('inputevent_key.conf', 'RIGHT ignore #event:click\n'
                   'RIGHT ignore #event:click|chapter == 0\nRIGHT ignore #event:press\n')
        self.assertFalse(any(f.severity == 'error' for f in self.findings()))

    def test_duplicate_event_branch(self):
        self.write('inputevent_key.conf', 'CTRL+SHIFT+a ignore #event:click\nCTRL+A ignore #event:click\n')
        self.assertTrue(any(f.rule == 'duplicate-key' for f in self.findings()))

    def test_unknown_command_and_invalid_argument(self):
        self.write('input.conf', 'a not-a-command\nb add volume invalid-number\n')
        locations = {f.line for f in self.findings() if f.rule == 'input-syntax'}
        self.assertEqual(locations, {1, 2})

    def test_unknown_key(self):
        self.write('input.conf', 'not-a-key ignore\n')
        self.assertTrue(any(f.rule in ('input-syntax', 'input-key') for f in self.findings()))

    def test_builtin_profile(self):
        self.write('mpv.conf', 'profile=high-quality\n')
        self.assertFalse(any(f.rule == 'missing-profile' for f in self.findings()))

    def test_commands_are_not_executed(self):
        sentinel = self.root / 'must-not-exist'
        self.write('input.conf', f'a run "{Path(sys.executable).as_posix()}" -c "from pathlib import Path; '
                   f"Path('{sentinel.as_posix()}').write_text('unexpected')\"\n")
        self.assertFalse(any(f.severity == 'error' for f in self.findings()))
        self.assertFalse(sentinel.exists())


if __name__ == '__main__':
    unittest.main()
