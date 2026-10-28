"""Migration checks: no overwrite, no source removal, private settings retained."""
import json
from types import SimpleNamespace
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'maintenance'))
import ai_runtime


class MigrationTests(unittest.TestCase):
    def test_copy_is_verified_repeatable_and_refuses_different_destination(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, target = root/'source', root/'target'
            source.write_bytes(b'original runtime')
            ai_runtime.copy_verified(source, target)
            ai_runtime.copy_verified(source, target)
            source.write_bytes(b'new runtime')
            with self.assertRaises(RuntimeError):
                ai_runtime.copy_verified(source, target)
            self.assertEqual(source.read_bytes(), b'new runtime')
            self.assertEqual(target.read_bytes(), b'original runtime')

    def test_incomplete_installation_cannot_change_local_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config'
            config.mkdir()
            local = config/'local.conf'
            local.write_text('private=keep\n', encoding='utf-8')
            with patch.object(ai_runtime, 'CONFIG', config), self.assertRaises(RuntimeError):
                ai_runtime.configure(Path(folder)/'runtime')
            self.assertEqual(local.read_text(), 'private=keep\n')

    def test_registration_preserves_tuning_and_backs_up_previous_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            config, root = Path(folder)/'config', Path(folder)/'runtime'
            config.mkdir()
            (root/'state').mkdir(parents=True)
            local = config/'local.conf'
            original = ('script-opts-append=sub_fastwhisper-api_key=fixture-only\n'
                        'script-opts-append=sub_fastwhisper-qwen_python=previous\n'
                        'script-opts-append=sub_fastwhisper-whisper_batch_size=2\n')
            local.write_text(original, encoding='utf-8')
            original_bytes = local.read_bytes()
            paths = ai_runtime.paths(root)
            for key in ('fast_whisper_path','ffmpeg_path','qwen_python','sensevoice_python'):
                paths[key].parent.mkdir(parents=True, exist_ok=True)
                paths[key].write_bytes(b'fixture')
            for key, name in [('qwen_model','config.json'),('qwen_small_model','config.json'),
                              ('qwen_aligner','config.json'),('sensevoice_model','model.pt')]:
                paths[key].mkdir(parents=True, exist_ok=True)
                (paths[key]/name).write_bytes(b'fixture')
            with patch.object(ai_runtime, 'CONFIG', config), patch.object(ai_runtime.time, 'strftime', return_value='20261028-140000'):
                ai_runtime.configure(root)
                first_registration = local.read_bytes()
                ai_runtime.configure(root)
            updated = local.read_text()
            self.assertIn('api_key=fixture-only\n', updated)
            self.assertIn('whisper_batch_size=2\n', updated)
            self.assertEqual(updated.count('sub_fastwhisper-qwen_python='), 1)
            self.assertNotIn('qwen_python=previous', updated)
            backups = list((root/'state').glob('local-*.conf'))
            self.assertEqual(len(backups), 2)
            self.assertCountEqual([backup.read_bytes() for backup in backups], [original_bytes, first_registration])
            before_collision = local.read_bytes()
            collision_id = backups[0].stem.rsplit('-', 1)[1]
            with patch.object(ai_runtime, 'CONFIG', config), \
                    patch.object(ai_runtime.time, 'strftime', return_value='20261028-140000'), \
                    patch.object(ai_runtime.uuid, 'uuid4', return_value=SimpleNamespace(hex=collision_id)):
                with self.assertRaises(FileExistsError):
                    ai_runtime.configure(root)
            self.assertEqual(local.read_bytes(), before_collision)
            self.assertCountEqual([backup.read_bytes() for backup in backups], [original_bytes, first_registration])
            self.assertTrue(json.loads((root/'state/paths.json').read_text())['output_path'].endswith('subtitles'))


if __name__ == '__main__':
    unittest.main()
