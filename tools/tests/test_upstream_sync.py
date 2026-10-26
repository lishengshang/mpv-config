"""Real local Git histories; GitHub API calls are stubbed, never published."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'maintenance'))
import upstream_sync as sync


class UpstreamChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.upstream, self.origin, self.local = (root / name for name in ('upstream', 'origin', 'local'))
        self.upstream.mkdir()
        self.run_git(self.upstream, 'init', '-b', 'master')
        self.commit(self.upstream, 'config.txt', 'baseline\n')
        self.origin.mkdir()
        self.run_git(self.origin, 'init', '--bare')
        self.run_git(root, 'clone', str(self.upstream), str(self.local))
        self.run_git(self.local, 'remote', 'set-url', 'origin', str(self.origin))
        self.run_git(self.local, 'checkout', '-b', 'dev')
        self.commit(self.local, 'local.txt', 'custom\n')
        self.run_git(self.local, 'push', 'origin', 'dev')
        (self.local / 'local.txt').write_text('uncommitted custom\n', encoding='utf-8')
        self.original = self.snapshot()
        self.api_calls = []
        self.pulls = []

    def run_git(self, root, *args):
        result = subprocess.run(['git', '-c', 'user.name=Sync Test',
                                 '-c', 'user.email=sync@example.invalid', *args],
                                cwd=root, text=True, encoding='utf-8', capture_output=True)
        if result.returncode:
            self.fail(result.stderr)
        return result.stdout.strip()

    def commit(self, root, name, content):
        (root / name).write_text(content, encoding='utf-8')
        self.run_git(root, 'add', name)
        self.run_git(root, 'commit', '-m', 'fixture change')
        return self.run_git(root, 'rev-parse', 'HEAD')

    def snapshot(self):
        return (self.run_git(self.local, 'rev-parse', 'HEAD'),
                self.run_git(self.local, 'status', '--porcelain'),
                (self.local / 'local.txt').read_bytes())

    def api(self, root, endpoint, payload=None):
        self.api_calls.append((endpoint, payload))
        if payload is None:
            return self.pulls
        self.assertEqual(endpoint, 'pulls')
        self.assertEqual(payload['base'], 'dev')
        self.assertEqual(payload['head'], sync.BRANCH)
        return {'html_url': 'https://github.com/example/test/pull/1'}

    def check(self, publish=True):
        with patch.object(sync, 'api', side_effect=self.api), patch.object(sync, 'report'):
            result = sync.sync(self.local, publish, str(self.upstream))
        self.assertEqual(self.original, self.snapshot(), 'checkout and dirty files must be preserved')
        return result

    def remote_tip(self):
        return self.run_git(self.origin, 'rev-parse', f'refs/heads/{sync.BRANCH}')

    def opened(self, tip):
        self.pulls = [{'state': 'open', 'head': {'sha': tip},
                       'html_url': 'https://github.com/example/test/pull/1'}]

    def test_no_updates_repeatedly_creates_nothing_and_calls_no_api(self):
        before = self.run_git(self.origin, 'show-ref')
        self.assertEqual(self.check(), 'unchanged')
        self.assertEqual(self.check(), 'unchanged')
        self.assertEqual(before, self.run_git(self.origin, 'show-ref'))
        self.assertEqual(self.api_calls, [])

    def test_preview_fetches_without_publishing(self):
        self.commit(self.upstream, 'new.txt', 'upstream\n')
        before = self.run_git(self.origin, 'show-ref')
        self.assertEqual(self.check(False), 'preview')
        self.assertEqual(before, self.run_git(self.origin, 'show-ref'))
        self.assertEqual(self.api_calls, [])

    def test_conflicting_updates_open_pr_without_merging_or_creating_commits(self):
        self.commit(self.local, 'config.txt', 'local version\n')
        self.run_git(self.local, 'push', 'origin', 'dev')
        self.original = self.snapshot()
        tip = self.commit(self.upstream, 'config.txt', 'upstream version\n')
        self.assertEqual(self.check(), 'created')
        self.assertEqual(self.remote_tip(), tip)
        self.assertEqual(sum(payload is not None for _, payload in self.api_calls), 1)

    def test_open_pr_fast_forwards_in_place_without_duplicate(self):
        first = self.commit(self.upstream, 'new.txt', 'first\n')
        self.check()
        self.opened(first)
        tip = self.commit(self.upstream, 'new.txt', 'second\n')
        self.api_calls.clear()
        self.assertEqual(self.check(), 'updated')
        self.assertEqual(self.remote_tip(), tip)
        self.assertEqual(self.check(), 'updated')
        self.assertTrue(all(payload is None for _, payload in self.api_calls))

    def test_manual_conflict_fixes_are_never_overwritten(self):
        tip = self.commit(self.upstream, 'new.txt', 'first\n')
        self.check()
        manual = self.run_git(self.local, 'commit-tree', f'{tip}^{{tree}}', '-p', tip,
                              '-m', 'manual conflict resolution')
        self.run_git(self.local, 'push', 'origin', f'{manual}:refs/heads/{sync.BRANCH}')
        self.opened(manual)
        self.commit(self.upstream, 'new.txt', 'second\n')
        with self.assertRaisesRegex(RuntimeError, 'manual changes'):
            self.check()
        self.assertEqual(self.remote_tip(), manual)
        self.assertEqual(self.original, self.snapshot())

    def test_closed_revision_is_not_reopened_every_week(self):
        tip = self.commit(self.upstream, 'new.txt', 'first\n')
        self.pulls = [{'state': 'closed', 'head': {'sha': tip}}]
        before = self.run_git(self.origin, 'show-ref')
        self.assertEqual(self.check(), 'closed')
        self.assertEqual(before, self.run_git(self.origin, 'show-ref'))

    def test_merged_upstream_stops_future_publication(self):
        tip = self.commit(self.upstream, 'new.txt', 'first\n')
        self.check()
        self.run_git(self.local, 'fetch', 'origin', sync.BRANCH)
        merged = self.run_git(self.local, 'commit-tree', f'{tip}^{{tree}}',
                              '-p', self.original[0], '-p', tip, '-m', 'manual merge')
        self.run_git(self.local, 'push', 'origin', f'{merged}:refs/heads/dev')
        self.api_calls.clear()
        self.assertEqual(self.check(), 'unchanged')
        self.assertEqual(self.api_calls, [])

    def test_fetch_failure_is_not_no_updates(self):
        with patch.object(sync, 'api') as api, patch.object(sync, 'report') as report:
            with self.assertRaises(RuntimeError):
                sync.sync(self.local, True, str(self.upstream / 'missing'))
        api.assert_not_called()
        report.assert_not_called()
        self.assertEqual(self.original, self.snapshot())

    def test_failed_push_does_not_create_pr(self):
        self.commit(self.upstream, 'new.txt', 'first\n')
        real_git = sync.git

        def reject_push(root, *args, **kwargs):
            if args[0] == 'push':
                raise RuntimeError('push denied')
            return real_git(root, *args, **kwargs)

        with patch.object(sync, 'git', side_effect=reject_push):
            with self.assertRaisesRegex(RuntimeError, 'push denied'):
                self.check()
        self.assertTrue(all(payload is None for _, payload in self.api_calls))


if __name__ == '__main__':
    unittest.main()
