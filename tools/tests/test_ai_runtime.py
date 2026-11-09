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
    def test_copy_preserves_existing_partial_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, target = root / 'source', root / 'target'
            source.write_bytes(b'original runtime')
            partial = root / 'target.copying'
            partial.write_bytes(b'previous interrupted copy')
            ai_runtime.copy_verified(source, target)
            self.assertEqual(target.read_bytes(), b'original runtime')
            self.assertEqual(partial.read_bytes(), b'previous interrupted copy')
            self.assertEqual(set(root.iterdir()), {source, target, partial})

    def test_copy_failure_cleans_only_owned_partial_and_allows_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, target = root / 'source', root / 'target'
            source.write_bytes(b'original runtime')
            previous = root / 'target.copying'
            previous.write_bytes(b'previous interrupted copy')

            def interrupted(incoming, outgoing, size):
                outgoing.write(incoming.read(3))
                raise OSError('fixture: interrupted copy')

            with patch.object(ai_runtime.shutil, 'copyfileobj', side_effect=interrupted):
                with self.assertRaisesRegex(OSError, 'interrupted copy'):
                    ai_runtime.copy_verified(source, target)
            self.assertEqual(set(root.iterdir()), {source, previous})
            ai_runtime.copy_verified(source, target)
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(previous.read_bytes(), b'previous interrupted copy')
            self.assertEqual(set(root.iterdir()), {source, target, previous})

    def test_copy_checksum_failure_cleans_owned_partial(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, target = root / 'source', root / 'target'
            source.write_bytes(b'original runtime')
            with patch.object(ai_runtime, 'digest', side_effect=['source hash', 'wrong hash']):
                with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
                    ai_runtime.copy_verified(source, target)
            self.assertEqual(list(root.iterdir()), [source])

    def test_copy_temporary_name_collision_preserves_existing_file(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, target = root / 'source', root / 'target'
            source.write_bytes(b'original runtime')
            previous = root / 'target.collision.copying'
            previous.write_bytes(b'other copy')
            with patch.object(ai_runtime.uuid, 'uuid4', return_value=SimpleNamespace(hex='collision')):
                with self.assertRaises(FileExistsError):
                    ai_runtime.copy_verified(source, target)
            self.assertEqual(previous.read_bytes(), b'other copy')
            self.assertEqual(set(root.iterdir()), {source, previous})

    def test_tree_copy_rejects_destination_in_source_before_writing(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'source'
            source.mkdir()
            (source / 'model.bin').write_bytes(b'original model')
            for target in (source, source / 'nested'):
                with self.subTest(target=target), patch.object(ai_runtime, 'copy_verified',
                        side_effect=AssertionError('copy started before destination validation')):
                    with self.assertRaisesRegex(ValueError, 'outside its source'):
                        ai_runtime.copy_tree(source, target)
            self.assertEqual(list(source.iterdir()), [source / 'model.bin'])
            self.assertEqual((source / 'model.bin').read_bytes(), b'original model')

    def test_tree_copy_preserves_source_and_nested_files(self):
        with tempfile.TemporaryDirectory() as folder:
            source, target = Path(folder) / 'source', Path(folder) / 'target'
            (source / 'model').mkdir(parents=True)
            (source / 'model/weights').write_bytes(b'original weights')
            ai_runtime.copy_tree(source, target)
            ai_runtime.copy_tree(source, target)
            self.assertEqual((target / 'model/weights').read_bytes(), b'original weights')
            self.assertEqual((source / 'model/weights').read_bytes(), b'original weights')

    def test_python_clone_rejects_destination_under_base_or_site(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            base, site = root / 'base', root / 'site'
            base.mkdir()
            site.mkdir()
            info = json.dumps(dict(base=str(base), site=str(site), version='3.12.0'))
            for source in (base, site):
                target = source / 'nested'
                with self.subTest(source=source), \
                        patch.object(ai_runtime.subprocess, 'check_output', return_value=info), \
                        patch.object(ai_runtime, 'qwen_files', side_effect=AssertionError('source traversal started')):
                    with self.assertRaisesRegex(ValueError, 'outside its source'):
                        ai_runtime.clone_python(root / 'python.exe', target)
                self.assertFalse(target.exists())

    def test_prepare_rejects_whisper_destination_under_source(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'whisper'
            source.mkdir()
            backend = source / 'faster-whisper-xxl.exe'
            backend.write_bytes(b'original runtime')
            settings = {'sub_fastwhisper-qwen_python': str(backend),
                        'sub_fastwhisper-fast_whisper_path': str(backend)}
            target = source / 'nested'
            with patch.object(ai_runtime, 'clone_python'), patch.object(ai_runtime, 'copy_verified',
                    side_effect=AssertionError('copy started before destination validation')):
                with self.assertRaisesRegex(ValueError, 'outside its source'):
                    ai_runtime.prepare(target, settings)
            self.assertEqual(backend.read_bytes(), b'original runtime')
            self.assertFalse((target / 'runtimes/whisper').exists())

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

    def test_missing_whisper_model_cannot_change_local_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            config, root = Path(folder)/'config', Path(folder)/'runtime'
            config.mkdir()
            (root/'state').mkdir(parents=True)
            local = config/'local.conf'
            local.write_text('private=keep\n', encoding='utf-8')
            paths = ai_runtime.paths(root)
            for key in ('fast_whisper_path','ffmpeg_path','qwen_python','sensevoice_python'):
                paths[key].parent.mkdir(parents=True, exist_ok=True)
                paths[key].write_bytes(b'fixture')
            for key, name in [('qwen_model','config.json'),('qwen_small_model','config.json'),
                              ('qwen_aligner','config.json'),('sensevoice_model','model.pt')]:
                paths[key].mkdir(parents=True, exist_ok=True)
                (paths[key]/name).write_bytes(b'fixture')
            with patch.object(ai_runtime, 'CONFIG', config), self.assertRaisesRegex(RuntimeError, 'whisper_model_dir'):
                ai_runtime.configure(root)
            self.assertEqual(local.read_text(), 'private=keep\n')
            self.assertEqual(list((root/'state').glob('local-*.conf')), [])

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
            previous_pending = config / 'local.conf.pending'
            previous_pending.write_bytes(b'previous private configuration draft')
            paths = ai_runtime.paths(root)
            for key in ('fast_whisper_path','ffmpeg_path','qwen_python','sensevoice_python'):
                paths[key].parent.mkdir(parents=True, exist_ok=True)
                paths[key].write_bytes(b'fixture')
            for key, name in [('qwen_model','config.json'),('qwen_small_model','config.json'),
                              ('qwen_aligner','config.json'),('sensevoice_model','model.pt')]:
                paths[key].mkdir(parents=True, exist_ok=True)
                (paths[key]/name).write_bytes(b'fixture')
            (paths['whisper_model_dir']/'faster-whisper-large-v3-turbo').mkdir(parents=True)
            (paths['whisper_model_dir']/'faster-whisper-large-v3-turbo/model.bin').write_bytes(b'fixture')
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
            self.assertEqual(previous_pending.read_bytes(), b'previous private configuration draft')
            with patch.object(ai_runtime, 'CONFIG', config), \
                    patch.object(Path, 'replace', side_effect=OSError('fixture: replace failed')):
                with self.assertRaisesRegex(OSError, 'replace failed'):
                    ai_runtime.configure(root)
            self.assertEqual(local.read_bytes(), before_collision)
            self.assertEqual(list(config.glob('local.conf.*pending')), [previous_pending])
            collision = config / 'local.conf.collision.pending'
            collision.write_bytes(b'other registration')
            with patch.object(ai_runtime, 'CONFIG', config), \
                    patch.object(ai_runtime.uuid, 'uuid4', return_value=SimpleNamespace(hex='collision')):
                with self.assertRaises(FileExistsError):
                    ai_runtime.configure(root)
            self.assertEqual(collision.read_bytes(), b'other registration')
            self.assertEqual(local.read_bytes(), before_collision)


if __name__ == '__main__':
    unittest.main()
