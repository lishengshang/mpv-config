"""Fetch configuration upstream; publish only a review branch and a manual-merge PR."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.parse import urlencode

REPOSITORY = 'lishengshang/mpv-config'
UPSTREAM = 'https://github.com/dyphire/mpv-config.git'
BASE = 'dev'
BRANCH = 'codex/upstream-sync'
UPSTREAM_REF = 'refs/remotes/upstream-sync/master'


def command(args, root, data=None, allowed=(0,)):
    result = subprocess.run(args, cwd=root, input=data, text=True,
                            encoding='utf-8', capture_output=True)
    if result.returncode not in allowed:
        raise RuntimeError(f'{args[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result


def git(root, *args, allowed=(0,)):
    # Explicit work tree also supports this project's submodule worktrees.
    return command(['git', f'--work-tree={Path(root).resolve()}', *args], root,
                   allowed=allowed)


def ancestor(root, older, newer):
    return git(root, 'merge-base', '--is-ancestor', older, newer,
               allowed=(0, 1)).returncode == 0


def api(root, endpoint, payload=None):
    args = ['gh', 'api', f'repos/{REPOSITORY}/{endpoint}']
    if payload is not None:
        args += ['--method', 'POST', '--input', '-']
    result = command(args, root, None if payload is None else json.dumps(payload))
    return json.loads(result.stdout)


def report(message):
    print(message)
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a', encoding='utf-8', newline='\n') as stream:
            stream.write(message + '\n')


def sync(root, publish=False, upstream=UPSTREAM):
    git(root, 'fetch', '--no-tags', 'origin',
        f'+refs/heads/{BASE}:refs/remotes/origin/{BASE}')
    git(root, 'fetch', '--no-tags', upstream,
        f'+refs/heads/master:{UPSTREAM_REF}')
    base = git(root, 'rev-parse', f'refs/remotes/origin/{BASE}').stdout.strip()
    tip = git(root, 'rev-parse', UPSTREAM_REF).stdout.strip()
    # A failed fetch or an unrelated history must never be reported as "no updates".
    git(root, 'merge-base', base, tip)
    if ancestor(root, tip, base):
        report('No upstream updates. No branch, commit or pull request was created.')
        return 'unchanged'

    count = git(root, 'rev-list', '--count', f'{base}..{tip}').stdout.strip()
    report(f'Upstream has {count} pending commit(s): `{tip}` → `{BASE}`.')
    if not publish:
        report('Preview only; no remote changes.')
        return 'preview'

    query = urlencode({'state': 'all', 'head': f'{REPOSITORY.split("/")[0]}:{BRANCH}',
                       'base': BASE, 'per_page': 100, 'sort': 'created', 'direction': 'desc'})
    pulls = api(root, 'pulls?' + query)
    opened = [pull for pull in pulls if pull['state'] == 'open']
    if len(opened) > 1:
        raise RuntimeError('Multiple sync PRs exist; resolve them manually.')
    # Respect a PR that the user closed without merging; do not recreate it weekly.
    if not opened and any(pull['head']['sha'] == tip for pull in pulls):
        report('This upstream revision already has a closed PR; leaving it for manual handling.')
        return 'closed'

    ref = f'refs/heads/{BRANCH}'
    remote = git(root, 'ls-remote', '--exit-code', 'origin', ref, allowed=(0, 2))
    if remote.returncode == 0:
        git(root, 'fetch', '--no-tags', 'origin', ref)
        previous = git(root, 'rev-parse', 'FETCH_HEAD').stdout.strip()
        if not ancestor(root, previous, tip):
            raise RuntimeError('Sync branch contains manual changes or upstream rewrote history. '
                               'Preserving the branch and PR; handle them manually.')
        if previous != tip:
            # Fast-forward only: no force push and no overwrite of manual conflict fixes.
            git(root, 'push', 'origin', f'{tip}:{ref}')
    else:
        git(root, 'push', 'origin', f'{tip}:{ref}')

    if opened:
        report(f'Existing PR updated in place: {opened[0]["html_url"]}')
        return 'updated'
    pull = api(root, 'pulls', {
        'title': 'chore: 同步配置上游更新（待人工审查）',
        'head': BRANCH, 'base': BASE,
        'body': '每周检查发现 dyphire/mpv-config 的 master 有尚未纳入 dev 的提交。\n\n'
                '本 PR 直接保留上游提交，不自动合并，也不创建 Issue。请检查本地定制、'
                '解决冲突并完成配置和播放验收，再手动合并。\n\n'
                '请使用 **Create a merge commit**，保留上游祖先关系；'
                'Squash/Rebase 合并会导致后续检查重复识别旧提交。\n\n'
                '若需要在同步分支上修复冲突，后续自动检查会保留你的提交并停止更新，'
                '请先完成该 PR 的处理。使用默认 GITHUB_TOKEN 创建的 PR，'
                '检查可能需要你在 GitHub 页面批准运行。\n\n'
                '上游：https://github.com/dyphire/mpv-config/commits/master/',
        'maintainer_can_modify': True,
    })
    report(f'Pull request ready for manual review: {pull["html_url"]}')
    return 'created'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--publish', action='store_true', help='Push review branch and create PR')
    args = parser.parse_args()
    try:
        sync(Path(__file__).resolve().parents[2], args.publish)
    except (RuntimeError, OSError) as error:
        report(f'Upstream sync failed: {error}')
        sys.exit(1)
