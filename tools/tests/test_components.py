"""Data-preservation and archive trust-boundary regression; no GPU/downloads required."""
import hashlib
import io
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
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'maintenance'))
import component_store as store
import components


class ComponentTests(unittest.TestCase):
    def test_component_repair_preserves_registered_unified_ai_paths(self):
        local = self.root / 'portable_config/local.conf'
        original = 'script-opts-append=sub_fastwhisper-fast_whisper_path=C:/AI/runtimes/whisper/faster-whisper-xxl.exe\n'
        local.write_text(original, encoding='utf-8', newline='\n')
        store.atomic_json(self.root/'portable_config/state/ai-runtime.json', dict(schema=1,
                          managed_keys=['sub_fastwhisper-fast_whisper_path','sub_fastwhisper-whisper_model_dir']))
        store.configure(self.root, [dict(id='whisper', root=str(self.root/'components/whisper/version'))])
        self.assertEqual(local.read_text(encoding='utf-8'), original)

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

    def split_archive(self):
        archive, item = self.archive()
        body = archive.read_bytes()
        parts = []
        for index, start in enumerate(range(0, len(body), 100)):
            path = self.base / f'part{index}'
            path.write_bytes(body[start:start + 100])
            parts.append(dict(archive=path.name, bytes=path.stat().st_size, sha256=store.digest(path)))
        archive.unlink()
        return dict(item, parts=parts)

    def test_local_parts_assemble_install_and_reuse(self):
        item = self.split_archive()
        cache = self.base / 'downloads'
        archive = store.obtain(item, self.base, cache)
        receipt = store.install(self.root, item, archive, False)
        self.assertTrue(Path(receipt['root'], 'ffmpeg.exe').is_file())
        # Verified assembled archives can be reused even without transport parts.
        for part in item['parts']:
            (self.base / part['archive']).unlink()
        self.assertEqual(store.obtain(item, self.base, cache), archive)

    def test_corrupt_part_cannot_install_or_replace_existing_archive(self):
        item = self.split_archive()
        cache = self.base / 'downloads'
        cache.mkdir()
        target = cache / (item['sha256'] + '.zip')
        target.write_bytes(b'preserve existing cache')
        (self.base / item['parts'][1]['archive']).write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'size/SHA256'):
            store.obtain(item, self.base, cache)
        self.assertEqual(target.read_bytes(), b'preserve existing cache')
        self.assertFalse((self.root / 'components').exists())

    def test_part_order_and_whole_archive_hash_are_checked(self):
        item = self.split_archive()
        item['parts'].reverse()
        with self.assertRaisesRegex(ValueError, 'Assembled archive'):
            store.obtain(item, self.base, self.base / 'downloads')
        self.assertFalse((self.base / 'downloads' / (item['sha256'] + '.zip')).exists())

    def test_invalid_parts_fail_catalog_validation(self):
        item = self.split_archive()
        path = self.base / 'catalog.json'
        invalid = [[], item['parts'] * 2, [dict(item['parts'][0], archive='../escape')],
                   [dict(item['parts'][0], bytes=2 * 1024**3)],
                   [dict(item['parts'][0], sha256='')], [dict(item['parts'][0], parts=[])]]
        for parts in invalid:
            path.write_text(json.dumps(dict(schema=1, components=[dict(item, parts=parts)])))
            with self.subTest(parts=parts), self.assertRaises(ValueError):
                store.catalog(path)

    def test_parts_check_free_space_before_reading_payload(self):
        item = self.split_archive()
        with patch.object(store.shutil, 'disk_usage', return_value=SimpleNamespace(free=0)), \
                patch.object(store, 'obtain_single') as obtain:
            with self.assertRaisesRegex(ValueError, 'free space'):
                store.obtain(item, self.base, self.base / 'downloads')
            obtain.assert_not_called()

    def test_https_parts_reuse_verified_downloads_after_interruption(self):
        item = self.split_archive()
        bodies = {p['archive']: (self.base / p['archive']).read_bytes() for p in item['parts']}
        calls = []
        fail = [True]
        def download(url, **kwargs):
            name = url.rsplit('/', 1)[1]
            calls.append(name)
            if name == item['parts'][1]['archive'] and fail[0]:
                fail[0] = False
                raise OSError('interrupted')
            response = io.BytesIO(bodies[name])
            response.url = url
            return response
        cache = self.base / 'downloads'
        with patch.object(store.urllib.request, 'urlopen', side_effect=download):
            with self.assertRaisesRegex(OSError, 'interrupted'):
                store.obtain(item, 'https://example.test/catalog.json', cache)
            archive = store.obtain(item, 'https://example.test/catalog.json', cache)
        self.assertEqual(store.digest(archive), item['sha256'])
        self.assertEqual(calls.count(item['parts'][0]['archive']), 1)

    def test_prepare_copies_bootstrap_splits_payload_and_installs(self):
        archive, item = self.archive()
        boot = self.base / ('bootstrap-' + 'a' * 16 + '.zip')
        boot.write_bytes(b'bootstrap fixture')
        bootstrap = dict(id='bootstrap', version='local-test', archive=boot.name, bytes=boot.stat().st_size,
                         expanded_bytes=100, sha256=store.digest(boot))
        catalog = self.base / 'catalog.json'
        catalog.write_text(json.dumps(dict(schema=1, bootstrap=bootstrap, components=[item])))
        output = self.base / 'prepared'
        components.prepare(SimpleNamespace(catalog=catalog, output=output, part_bytes=100))
        data, base = store.catalog(output / 'catalog.json')
        self.assertEqual((output / boot.name).read_bytes(), boot.read_bytes())
        self.assertTrue(all(p['bytes'] <= 100 for p in data['components'][0]['parts']))
        assembled = store.obtain(data['components'][0], base, self.base / 'downloads')
        self.assertEqual(assembled.read_bytes(), archive.read_bytes())
        # The transported installer must work without the original checkout/cwd.
        installer = output / 'tools/maintenance/components.py'
        self.assertTrue((output / 'tools/runtime/qwen_runtime.py').is_file())
        self.assertIn('maintenance/components.py', (output / 'tools/components.ps1').read_text())
        result = subprocess.run([sys.executable, str(installer), '--help'], cwd=self.base,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('configure', result.stdout)
        for line in (output / 'SHA256SUMS').read_text().splitlines():
            digest, name = line.split('  ', 1)
            self.assertEqual(store.digest(output / name), digest)
        with self.assertRaises(FileExistsError):
            components.prepare(SimpleNamespace(catalog=catalog, output=output, part_bytes=100))

    def test_prepare_rejects_release_limit_before_creating_output(self):
        _, item = self.archive()
        catalog = self.base / 'catalog.json'
        catalog.write_text(json.dumps(dict(schema=1, components=[item])))
        output = self.base / 'prepared'
        with self.assertRaisesRegex(ValueError, 'below 2 GiB'):
            components.prepare(SimpleNamespace(catalog=catalog, output=output, part_bytes=2 * 1024**3))
        self.assertFalse(output.exists())

    def candidate(self, files):
        for name, body in dict(files, **{'mpv.exe': b'candidate player', 'mpv.com': b'launcher'}).items():
            (self.root / name).write_bytes(body)
        return self.root

    def test_vs_adaptation_reuses_candidate_ffi_without_changing_sources(self):
        archive, item = self.archive({'libffi-8.dll': b'snapshot FFI', 'python.exe': b'python'}, 'vs')
        player = self.candidate({'libffi-8.dll': b'candidate FFI'})
        output = self.base / 'adapted'
        output.mkdir()
        with patch.object(store, 'probe', return_value={'width': 16}) as probe:
            adapted, path = components.adapt_vs(item, archive, player, output)
        self.assertEqual(probe.call_count, 1)
        self.assertNotEqual(adapted['version'], item['version'])
        self.assertEqual(store.digest(archive), item['sha256'])
        self.assertEqual((player / 'libffi-8.dll').read_bytes(), b'candidate FFI')
        self.assertEqual(adapted['metadata']['candidate_mpv_sha256'], store.digest(player / 'mpv.exe'))
        store.install(player, adapted, path, False)
        self.assertEqual((player / 'libffi-8.dll').read_bytes(), b'candidate FFI')
        self.assertEqual((player / 'mpv.exe').read_bytes(), b'candidate player')

    def test_vs_adaptation_rejects_unreviewed_shared_binary(self):
        archive, item = self.archive({'python.exe': b'snapshot Python'}, 'vs')
        player = self.candidate({'python.exe': b'candidate Python'})
        with self.assertRaisesRegex(ValueError, 'Unreviewed'):
            components.adapt_vs(item, archive, player, self.base)
        self.assertEqual((player / 'python.exe').read_bytes(), b'candidate Python')

    def test_vs_adaptation_native_failure_produces_no_archive(self):
        archive, item = self.archive({'libffi-8.dll': b'snapshot FFI'}, 'vs')
        player = self.candidate({'libffi-8.dll': b'candidate FFI'})
        output = self.base / 'adapted'
        output.mkdir()
        with patch.object(store, 'probe', side_effect=RuntimeError('native failure')):
            with self.assertRaisesRegex(RuntimeError, 'native failure'):
                components.adapt_vs(item, archive, player, output)
        self.assertEqual(list(output.iterdir()), [])

    def test_adapted_catalog_rejects_another_player_before_install(self):
        _, item = self.archive({'libffi-8.dll': b'candidate FFI'}, 'vs')
        item['metadata'] = dict(candidate_mpv_sha256='0' * 64)
        catalog = self.base / 'catalog.json'
        catalog.write_text(json.dumps(dict(schema=1, components=[item])))
        self.candidate({})
        with patch.object(store, 'install') as install:
            with self.assertRaisesRegex(ValueError, 'candidate player SHA256'):
                components.deploy(SimpleNamespace(mpv_root=self.root, catalog=catalog, components=['vs']))
            install.assert_not_called()
        self.assertFalse((self.root / 'portable_config/state').exists())

    def test_prepare_adapted_vs_catalog_reassembles_without_shipping_oversized_intermediate(self):
        _, item = self.archive({'libffi-8.dll': b'snapshot FFI', 'python.exe': b'python'}, 'vs')
        player = self.candidate({'libffi-8.dll': b'candidate FFI'})
        boot = self.base / ('bootstrap-' + 'a' * 16 + '.zip')
        boot.write_bytes(b'bootstrap')
        bootstrap = dict(id='bootstrap', version='local-test', archive=boot.name, bytes=boot.stat().st_size,
                         expanded_bytes=100, sha256=store.digest(boot))
        catalog = self.base / 'catalog.json'
        catalog.write_text(json.dumps(dict(schema=1, bootstrap=bootstrap, components=[item])))
        output = self.base / 'prepared'
        with patch.object(store, 'probe', return_value={'width': 16}):
            components.prepare(SimpleNamespace(catalog=catalog, output=output, part_bytes=100, vs_player=player))
        data, base = store.catalog(output / 'catalog.json')
        adapted = data['components'][0]
        self.assertFalse((output / adapted['archive']).exists())
        archive = store.obtain(adapted, base, self.base / 'downloads')
        store.install(player, adapted, archive, False)
        self.assertEqual((player / 'libffi-8.dll').read_bytes(), b'candidate FFI')

    def test_launcher_conflict_aborts_before_install_and_preserves_user_file(self):
        _, item = self.archive({'libffi-8.dll': b'FFI'}, 'vs')
        catalog = self.base / 'catalog.json'
        catalog.write_text(json.dumps(dict(schema=1, components=[item])))
        self.candidate({})
        launcher = self.root / 'mpv-components.cmd'
        launcher.write_bytes(b'user launcher')
        with patch.object(store, 'install') as install:
            with self.assertRaisesRegex(ValueError, 'user file was preserved'):
                components.deploy(SimpleNamespace(mpv_root=self.root, catalog=catalog, components=['vs']))
            install.assert_not_called()
        self.assertEqual(launcher.read_bytes(), b'user launcher')
        self.assertFalse((self.root / 'portable_config/state').exists())

    def test_vs_configure_creates_relative_launcher_and_preserves_it_after_move(self):
        store.configure(self.root, [dict(id='vs', root=str(self.root))])
        launcher = self.root / 'mpv-components.cmd'
        before = launcher.read_bytes()
        moved = self.base / 'moved player 中文'
        self.root.rename(moved)
        self.assertEqual(store.component_launcher(moved, write=True).read_bytes(), before)
        self.assertNotIn(str(self.root).encode(), before)

    def test_managed_vs_status_requires_launcher_and_repair_restores_readiness(self):
        archive, item = self.archive({'libffi-8.dll': b'FFI'}, 'vs')
        store.install(self.root, item, archive, False)
        args = SimpleNamespace(mpv_root=self.root, components=['vs'], hashes=False, report=None)
        with patch.object(store, 'probe', return_value={'width': 16}) as probe:
            self.assertEqual(components.status(args), 1)
            probe.assert_not_called()
            store.component_launcher(self.root, write=True)
            self.assertEqual(components.status(args), 0)


if __name__ == '__main__':
    unittest.main()
