"""Failure-oriented release tests; no GPU, downloads or publishing required."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


def sample_plan():
    settings = release.manifest()
    return dict(schema=1, repository=settings['repository'], tag=f'player-v0.41.0-r{settings["revision"]}',
                mpv_tag='v0.41.0', mpv_commit='a' * 40, config_commit='b' * 40,
                upstream_url='https://github.com/mpv-player/mpv/releases/tag/v0.41.0',
                build=settings, needed=True, channel='prerelease', source_verified=True)


class ReleaseChecks(unittest.TestCase):
    def test_official_stable_selection_rejects_nightly_and_prerelease(self):
        items = [dict(tag_name=tag, prerelease=pre, draft=False) for tag, pre in
                 [('git-release', False), ('20261016', False), ('v0.42.0-rc1', False),
                  ('v0.42.0', True), ('v0.41.0', False), ('v0.9.0', False)]]
        self.assertEqual(release.official_release(items)['tag_name'], 'v0.41.0')
        with self.assertRaises(ValueError):
            release.official_release(items, 'git-release')

    def test_annotated_tag_is_peeled_to_immutable_commit(self):
        with patch.object(release, 'api', side_effect=[
                {'object': {'type': 'tag', 'sha': 'a' * 40}},
                {'object': {'type': 'commit', 'sha': 'b' * 40}}]):
            self.assertEqual(release.resolve_commit('mpv-player/mpv', 'v0.41.0'), 'b' * 40)

    def test_archive_members_cannot_escape_or_include_private_state(self):
        for path in ('../local.conf', '/mpv.conf', 'scripts/../local.conf', 'C:/private',
                     'scripts\\..\\private', 'local.conf', 'files/history.log',
                     'scripts/cache/token', 'tools/__pycache__/private.pyc', '.github/workflows/test.yml'):
            self.assertFalse(release.public_config(path), path)
        for path in ('mpv.conf', 'scripts/uosc/main.lua', 'local.conf.example', 'release/manifest.json'):
            self.assertTrue(release.public_config(path), path)

    def test_missing_vapoursynth_blocks_complete_player(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = Path(temp)
            for name in ('mpv.exe', 'mpv.com'):
                (runtime / name).touch()
            with patch.object(release, 'run', side_effect=[' d3d11vpp description', ' gpu-next description']):
                with self.assertRaisesRegex(ValueError, 'vapoursynth'):
                    release.validate_capabilities(runtime, release.manifest())

    def test_process_failure_does_not_become_capability_success(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = Path(temp)
            for name in ('mpv.exe', 'mpv.com'):
                (runtime / name).touch()
            with patch.object(release, 'run', side_effect=subprocess.CalledProcessError(1, 'mpv')):
                with self.assertRaises(subprocess.CalledProcessError):
                    release.validate_capabilities(runtime, release.manifest())

    def test_lua_and_missing_file_errors_are_failures_even_on_exit_zero(self):
        for line in ('[ 1][e][simple_mpv_webui] Lua error: missing socket',
                     '[ 1][f][cplayer] Cannot initialize', 'Failed to open file',
                     'Error loading module socket'):
            self.assertTrue(release.error_lines(line), line)
        self.assertFalse(release.error_lines('[ 1][v][cplayer] playing media'))

    def test_committed_snapshot_excludes_live_private_and_untracked_files(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / 'source', Path(temp) / 'target'
            source.mkdir()
            release.run(['git', 'init', source])
            (source / 'mpv.conf').write_text('idle=yes\n')
            (source / 'local.conf').write_text('private-token\n')
            (source / 'files').mkdir()
            (source / 'files/history.log').write_text('private-media\n')
            release.run(['git', '-C', source, 'add', '.'])
            release.run(['git', '-C', source, '-c', 'user.name=test', '-c', 'user.email=test@example.com',
                         'commit', '-m', 'fixture'])
            commit = release.run(['git', '-C', source, 'rev-parse', 'HEAD']).strip()
            (source / 'mpv.conf').write_text('changed-live-config\n')
            (source / 'input.conf').write_text('untracked\n')
            release.snapshot_config(source, commit, target)
            self.assertEqual((target / 'mpv.conf').read_text(), 'idle=yes\n')
            self.assertNotIn('private-token', (target / 'local.conf').read_text())
            self.assertFalse((target / 'input.conf').exists())
            self.assertFalse((target / 'files/history.log').exists())
            self.assertTrue((target / 'files').is_dir())

    def test_failed_or_mismatched_report_prevents_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            release.dump(root / 'release-info.json', sample_plan())
            report = root / 'report.json'
            args = argparse.Namespace(player=root, report=report, output=root / 'output')
            release.dump(report, {'passed': False})
            with self.assertRaises(ValueError):
                release.archive_release(args)
            release.dump(report, dict(passed=True, config_commit='c' * 40, mpv_commit='a' * 40))
            with self.assertRaises(ValueError):
                release.archive_release(args)
            self.assertFalse(args.output.exists())

    def test_archive_is_reopenable_and_does_not_ship_test_history(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            player = root / 'MPV'
            release.dump(player / 'release-info.json', sample_plan())
            config = player / 'portable_config'
            config.mkdir()
            (config / 'mpv.conf').write_text('idle=yes\n')
            (config / 'local.conf').write_text('# Generated distribution defaults\n')
            (config / 'files').mkdir()
            (config / 'files/history.log').write_text('private-test-media\n')
            report = root / 'report.json'
            release.dump(report, dict(passed=True, config_commit='b' * 40, mpv_commit='a' * 40,
                                      files_sha256=release.fingerprint(player)))
            args = argparse.Namespace(player=player, report=report, output=root / 'assets')
            release.archive_release(args)
            archive = next(args.output.glob('*.zip'))
            with zipfile.ZipFile(archive) as zipped:
                self.assertIsNone(zipped.testzip())
                self.assertNotIn('MPV/portable_config/files/history.log', zipped.namelist())
                self.assertIn('MPV/portable_config/files/', zipped.namelist())
                self.assertIn('MPV/portable_config/local.conf', zipped.namelist())

    def test_published_release_is_never_clobbered_or_promoted(self):
        with tempfile.TemporaryDirectory() as temp:
            assets = Path(temp)
            plan = sample_plan()
            release.dump(assets / 'release-plan.json', plan)
            archive = assets / (plan['tag'] + '-windows-x64.zip')
            archive.write_bytes(b'fixture')
            release.dump(assets / 'smoke-report.json', dict(passed=True, config_commit='b' * 40,
                                                           mpv_commit='a' * 40, archive_sha256=release.hash_file(archive)))
            (assets / 'SHA256SUMS').write_text(release.hash_file(archive) + '  ' + archive.name + '\n')
            with patch.object(release, 'api', return_value={'draft': False}), patch.object(release, 'run') as commands:
                with self.assertRaisesRegex(ValueError, 'already exists'):
                    release.publish_release(argparse.Namespace(assets=assets))
                commands.assert_not_called()

    def test_changed_runtime_after_verification_prevents_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            player = root / 'player'
            release.dump(player / 'release-info.json', sample_plan())
            report = root / 'report.json'
            release.dump(report, dict(passed=True, config_commit='b' * 40, mpv_commit='a' * 40,
                                      files_sha256=release.fingerprint(player)))
            (player / 'mpv.exe').write_bytes(b'changed after verification')
            with self.assertRaisesRegex(ValueError, 'changed after verification'):
                release.archive_release(argparse.Namespace(player=player, report=report, output=root / 'assets'))

    def test_uncommitted_audit_plan_cannot_be_consumed(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'plan.json'
            plan = sample_plan()
            plan['source_verified'] = False
            release.dump(path, plan)
            with self.assertRaisesRegex(ValueError, 'uncommitted'):
                release.load_plan(path)

    def test_backports_are_scoped_to_the_exact_stable_tag(self):
        plan = sample_plan()
        self.assertTrue(release.selected_backports(plan))
        plan['mpv_tag'] = 'v0.42.0'
        self.assertEqual(release.selected_backports(plan), [])

    def test_backports_reject_mutable_refs(self):
        plan = sample_plan()
        plan['build']['mpv_backports'] = {'v0.41.0': ['master']}
        with self.assertRaisesRegex(ValueError, 'immutable'):
            release.selected_backports(plan)

    def test_subtitle_backport_changes_only_known_context(self):
        commit = '8ab3f8b66dcf2c2471f4dbba5cee21cda06843b7'
        text = ' {"secondary-sub-delay", OPT_DOUBLE(sub_delay[1])},\n     double sub_delay[2];\n+    float sub_scale[2];\n'
        adapted = release.adapt_backport(text, commit, 'v0.41.0')
        self.assertIn('OPT_FLOAT(sub_delay[1])', adapted)
        self.assertIn('+    float sub_scale[2];', adapted)
        self.assertEqual(release.adapt_backport(text, commit, 'v0.42.0'), text)
        with self.assertRaisesRegex(ValueError, 'Unexpected upstream patch context'):
            release.adapt_backport(text.replace('OPT_DOUBLE', 'OPT_UNKNOWN'), commit, 'v0.41.0')

    def test_missing_subtitle_scale_blocks_incompatible_player(self):
        with tempfile.TemporaryDirectory() as temp:
            runtime = Path(temp)
            for name in ('mpv.exe', 'mpv.com'):
                (runtime / name).touch()
            with patch.object(release, 'run', side_effect=[
                    ' vapoursynth description\n d3d11vpp description', ' gpu-next description',
                    ' --sub-scale Float']):
                with self.assertRaisesRegex(ValueError, 'secondary-sub-scale'):
                    release.validate_capabilities(runtime, release.manifest())

    def test_missing_full_menu_report_blocks_publishing(self):
        with tempfile.TemporaryDirectory() as temp:
            assets = Path(temp)
            plan = sample_plan()
            release.dump(assets / 'release-plan.json', plan)
            archive = assets / (plan['tag'] + '-windows-x64.zip')
            archive.write_bytes(b'candidate')
            release.dump(assets / 'smoke-report.json', dict(passed=True, config_commit='b' * 40,
                                                           mpv_commit='a' * 40, archive_sha256=release.hash_file(archive)))
            (assets / 'SHA256SUMS').write_text(release.hash_file(archive) + '  ' + archive.name + '\n')
            with patch.object(release, 'api', return_value=None), patch.object(release, 'run') as commands:
                with self.assertRaises(FileNotFoundError):
                    release.publish_release(argparse.Namespace(assets=assets))
                commands.assert_not_called()

    def test_missing_log_fails_and_keeps_failure_report(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = argparse.Namespace(player=root, evidence=root / 'evidence')
            with patch.object(release, 'load_plan', return_value=sample_plan()), \
                    patch.object(release, 'validate_capabilities', return_value='mpv fixture'), \
                    patch.object(release, 'run', return_value=''):
                with self.assertRaisesRegex(ValueError, 'log missing'):
                    release.check_release(args)
            report = json.loads((args.evidence / 'report.json').read_text())
            self.assertIs(report['passed'], False)

    def test_error_log_with_success_marker_and_zero_exit_still_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            args = argparse.Namespace(player=root, evidence=root / 'evidence')

            def fake_process(command, **_kwargs):
                if any(str(part).endswith('mpv.com') for part in command):
                    (args.evidence / 'player.log').write_text('[e][webui] Lua error\nRELEASE SMOKE PASS:\n')
                return ''

            with patch.object(release, 'load_plan', return_value=sample_plan()), \
                    patch.object(release, 'validate_capabilities', return_value='mpv fixture'), \
                    patch.object(release, 'run', side_effect=fake_process):
                with self.assertRaisesRegex(ValueError, 'smoke test failed'):
                    release.check_release(args)
            report = json.loads((args.evidence / 'report.json').read_text())
            self.assertIs(report['passed'], False)
            self.assertTrue(report['errors'])


@unittest.skipUnless(os.environ.get('MPV_RELEASE_NATIVE_ROOT'), 'Set MPV_RELEASE_NATIVE_ROOT for a local CPU/script smoke test')
class NativeReleaseChecks(unittest.TestCase):
    def test_local_runtime_and_relocated_archive(self):
        """Exercise the gate with a local player and synthetic provenance, never publish."""
        runtime = Path(os.environ['MPV_RELEASE_NATIVE_ROOT']).resolve()
        with tempfile.TemporaryDirectory(prefix='mpv release native 中文 ') as temp:
            root = Path(temp)
            player = root / 'MPV'
            player.mkdir()
            for path in runtime.iterdir():
                if path.is_file() and (path.suffix.lower() == '.dll' or path.name in ('mpv.exe', 'mpv.com')):
                    shutil.copy2(path, player / path.name)
            for name in ('lua', 'socket', 'mime'):
                shutil.copytree(runtime / name, player / name)
            config = player / 'portable_config'
            commit = release.run(['git', '-C', release.ROOT, 'rev-parse', 'HEAD']).strip()
            release.snapshot_config(release.ROOT, commit, config)
            # Include the current local portability change in this development fixture.
            shutil.copy2(release.ROOT / 'scripts/simple-mpv-webui/main.lua', config / 'scripts/simple-mpv-webui/main.lua')
            plan = sample_plan()
            release.dump(player / 'release-info.json', plan)
            evidence = root / 'stage-evidence'
            release.check_release(argparse.Namespace(player=player, evidence=evidence))
            assets = root / 'assets'
            release.archive_release(argparse.Namespace(player=player, report=evidence / 'report.json', output=assets))
            release.check_archive(argparse.Namespace(assets=assets, evidence=root / 'archive-evidence'))
            report = json.loads((assets / 'smoke-report.json').read_text(encoding='utf-8'))
            self.assertIs(report['passed'], True)
            self.assertIn('archive_sha256', report)
            kept = release.ROOT / 'cache/release-audit' / ('native-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
            for name in ('stage-evidence', 'archive-evidence'):
                shutil.copytree(root / name, kept / name)
            release.dump(kept / 'test-scope.json', dict(
                fixture='Local development player, synthetic release provenance; never a stable-source build',
                version=report['version'], passed=True))
            print('Native fixture evidence: ' + str(kept))


if __name__ == '__main__':
    unittest.main()
