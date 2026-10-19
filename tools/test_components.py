"""Data-preservation and archive trust-boundary regression; no GPU/downloads required."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import component_store as store
import components


class ComponentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mpv-components-test-')
        self.base = Path(self.temp.name)
        self.root = self.base / 'player'
        self.root.mkdir()
        (self.root / 'portable_config').mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, files=None, kind='media', extra=None):
        files = files or {'ffmpeg.exe': b'fixture executable', 'ffprobe.exe': b'fixture probe'}
        index = [dict(path=n, bytes=len(b), sha256=hashlib.sha256(b).hexdigest()) for n, b in files.items()]
        manifest = dict(schema=1, id=kind, version='local-test', files=index)
        path = self.base / (kind + '.zip')
        with zipfile.ZipFile(path, 'w') as z:
            z.writestr('component.json', json.dumps(manifest))
            for name, body in files.items():
                z.writestr('payload/' + name, body)
            if extra:
                z.writestr(*extra)
        item = dict(id=kind, version='local-test', archive=path.name, bytes=path.stat().st_size,
                    expanded_bytes=sum(map(len, files.values())), sha256=store.digest(path))
        return path, item

    def test_reject_unsafe_windows_names(self):
        for value in ('../escape', '/root', 'C:/x', 'a\\b', 'a/../b', 'a/b:stream', 'CON.txt', 'a./b', 'a//b'):
            with self.subTest(value=value), self.assertRaises(ValueError):
                store.relative(value)

    def test_hash_mismatch_does_not_touch_player(self):
        archive, item = self.archive()
        item['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            store.obtain(item, self.base, self.base / 'downloads')
        self.assertEqual(list(self.root.iterdir()), [self.root / 'portable_config'])

    def test_path_traversal_rejected_before_install(self):
        archive, item = self.archive(extra=('../outside.txt', 'bad'))
        with self.assertRaises(ValueError):
            store.install(self.root, item, archive, False)
        self.assertFalse((self.base / 'outside.txt').exists())

    def test_symlink_entry_rejected(self):
        link = zipfile.ZipInfo('payload/evil')
        link.create_system, link.external_attr = 3, (stat.S_IFLNK | 0o777) << 16
        archive, item = self.archive(extra=(link, '../outside'))
        with self.assertRaises(ValueError):
            store.install(self.root, item, archive, False)

    def test_vs_cannot_replace_mpv_or_configuration(self):
        for name in ('mpv.exe', 'portable_config/local.conf', 'lua51.dll'):
            archive, item = self.archive({name: b'bad'}, 'vs')
            with self.assertRaises(ValueError):
                store.install(self.root, item, archive, False)

    def test_install_conflict_retains_user_file(self):
        archive, item = self.archive()
        target = self.root / 'components/media/local-test/ffmpeg.exe'
        target.parent.mkdir(parents=True)
        target.write_bytes(b'user modified')
        with self.assertRaises(ValueError):
            store.install(self.root, item, archive, False)
        self.assertEqual(target.read_bytes(), b'user modified')
        self.assertFalse((target.parent / 'ffprobe.exe').exists())

    def test_failed_final_probe_rolls_back_only_created_files(self):
        archive, item = self.archive()
        sentinel = self.root / 'preserve.user'
        sentinel.write_bytes(b'user data')
        with patch.object(store, 'probe', side_effect=[{'ready': True}, RuntimeError('native failure')]):
            with self.assertRaises(RuntimeError):
                store.install(self.root, item, archive)
        self.assertEqual(sentinel.read_bytes(), b'user data')
        self.assertFalse((self.root / 'components/media/local-test/ffmpeg.exe').exists())
        self.assertFalse((self.root / 'portable_config/state/components/media.json').exists())

    def test_success_and_repeat_preserve_unrelated_files(self):
        archive, item = self.archive()
        receipt = store.install(self.root, item, archive, False)
        again = store.install(self.root, item, archive, False)
        self.assertEqual(receipt['files'], again['files'])
        self.assertEqual((Path(receipt['root']) / 'ffmpeg.exe').read_bytes(), b'fixture executable')

    def test_copy_fallback_checks_additional_space(self):
        archive, item = self.archive()
        from types import SimpleNamespace
        with patch.object(store.os, 'link', side_effect=OSError('hard links unsupported')), \
                patch.object(store.shutil, 'disk_usage', side_effect=[SimpleNamespace(free=10 * 1024**3), SimpleNamespace(free=0)]):
            with self.assertRaisesRegex(ValueError, 'copy fallback'):
                store.install(self.root, item, archive, False)
        self.assertFalse((self.root / 'components/media/local-test/ffmpeg.exe').exists())

    def test_private_configuration_is_preserved_and_backed_up(self):
        local = self.root / 'portable_config/local.conf'
        local.write_text('# preserve\nscript-opts-append=sub_fastwhisper-api_key=private-sentinel\n', encoding='utf-8')
        store.configure(self.root, [dict(id='whisper', root=str(self.root / 'components/whisper/version'))])
        text = local.read_text(encoding='utf-8')
        self.assertIn('api_key=private-sentinel', text)
        self.assertIn('whisper_model_dir=', text)
        backup = next((self.root / 'portable_config/state/components').glob('local.conf.before-*'))
        self.assertIn('private-sentinel', backup.read_text())

    def test_moved_receipt_uses_current_root(self):
        archive, item = self.archive()
        store.install(self.root, item, archive, False)
        moved = self.base / 'moved-player'
        self.root.rename(moved)
        receipts = components.installed(moved)
        self.assertEqual(Path(receipts[0]['root']), moved / 'components/media/local-test')

    def test_root_junction_or_symlink_cannot_redirect_install(self):
        outside = self.base / 'outside'
        outside.mkdir()
        link = self.root / 'components'
        try:
            if os.name == 'nt':
                subprocess.run(['cmd.exe', '/c', 'mklink', '/J', str(link), str(outside)], check=True, capture_output=True)
            else:
                link.symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest('symlink creation unavailable')
        archive, item = self.archive()
        try:
            with self.assertRaises(ValueError):
                store.inside(link, 'redirected-file')
            with self.assertRaises(ValueError):
                store.install(self.root, item, archive, False)
            self.assertEqual(list(outside.iterdir()), [])
        finally:
            if os.name == 'nt':
                link.rmdir()
            else:
                link.unlink()

    def test_catalog_does_not_accept_unpinned_or_duplicate_components(self):
        archive, item = self.archive()
        path = self.base / 'catalog.json'
        for entries in ([dict(item, sha256='')], [item, item]):
            path.write_text(json.dumps(dict(schema=1, components=entries)))
            with self.assertRaises(ValueError):
                store.catalog(path)

    def test_qwen_export_rebuilds_relative_python_and_local_runtime(self):
        base, site, vs = [self.base / name for name in ('python', 'venv-site', 'vs')]
        for path in (base, site, vs):
            path.mkdir()
        (base / 'python.exe').write_bytes(b'python')
        (base / 'python312._pth').write_text('C:/old-machine\n')
        (base / 'vcruntime140.dll').write_bytes(b'base CRT')
        (vs / 'vcruntime140.dll').write_bytes(b'other CRT')
        (vs / 'msvcp140.dll').write_bytes(b'C++ CRT')
        (site / 'qwen_asr.py').write_bytes(b'local package')
        files = dict(components.qwen_files(base, site, [], vs, '3.12.12'))
        self.assertEqual(files['python/python312._pth'], b'.\nDLLs\nLib\nLib/site-packages\nimport site\n')
        self.assertEqual(files['python/vcruntime140.dll'].read_bytes(), b'base CRT')
        self.assertEqual(files['python/msvcp140.dll'].read_bytes(), b'C++ CRT')
        self.assertIn('python/Lib/site-packages/qwen_asr.py', files)

    def test_qwen_export_refuses_absolute_site_path(self):
        base, site, vs = [self.base / name for name in ('python', 'venv-site', 'vs')]
        for path in (base, site, vs):
            path.mkdir()
        (site / 'leak.pth').write_text('C:/old-machine/site-packages\n')
        with self.assertRaises(ValueError):
            list(components.qwen_files(base, site, [], vs, '3.12.12'))


if __name__ == '__main__':
    unittest.main()
