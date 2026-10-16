"""Plan official-tag Windows builds and package verified prerelease candidates.

Only this project's prereleases are published. GPU/ASR acceptance and stable
promotion are separate maintenance operations. See docs/config-checks.md.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
STABLE_TAG = re.compile(r'v(\d+)\.(\d+)\.(\d+)\Z')
SHA = re.compile(r'[0-9a-f]{40}\Z')
CONFIG_FILES = {'mpv.conf', 'profiles.conf', 'input.conf', 'inputevent_key.conf',
                'menu.conf', 'manager.json', 'local.conf.example', 'LICENSE.MD', 'README.md'}
CONFIG_DIRS = {'fonts', 'icc', 'osc-style', 'script-modules', 'script-opts',
               'scripts', 'shaders', 'vs', 'tools', 'docs', 'release'}
PRIVATE_DIRS = {'.git', 'cache', 'files', 'state', 'playlists', '__pycache__', '.venv'}


def dump(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def run(args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True,
                          encoding='utf-8', errors='replace', timeout=120, **kwargs).stdout


def api(path, missing_ok=False):
    request = urllib.request.Request('https://api.github.com/' + path,
                                     headers={'Accept': 'application/vnd.github+json',
                                              'User-Agent': 'mpv-config-release'})
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if token:
        request.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(request, timeout=45) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if missing_ok and error.code == 404:
            return None
        raise


def manifest(root=ROOT):
    data = json.loads((root / 'release/manifest.json').read_text(encoding='utf-8'))
    if data['schema'] != 1 or data['mpv_repository'] != 'mpv-player/mpv':
        raise ValueError('Unsupported manifest or mpv source')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', data['repository']):
        raise ValueError('Invalid distribution repository')
    if type(data['revision']) is not int or data['revision'] < 1:
        raise ValueError('Revision must be a positive integer')
    for key in ('vapoursynth_headers_commit', 'luasocket_commit'):
        if not SHA.fullmatch(data[key]):
            raise ValueError('Build dependency must be an immutable commit: ' + key)
    return data


def official_release(releases, tag=''):
    candidates = [item for item in releases if not item.get('draft') and not item.get('prerelease')
                  and STABLE_TAG.fullmatch(item['tag_name'])]
    if tag:
        candidates = [item for item in candidates if item['tag_name'] == tag]
    if not candidates:
        raise ValueError('No official stable release found; never fall back to git-release/nightly')
    return max(candidates, key=lambda item: tuple(map(int, STABLE_TAG.fullmatch(item['tag_name']).groups())))


def resolve_commit(repo, tag):
    obj = api(f'repos/{repo}/git/ref/tags/{urllib.parse.quote(tag, safe="")}')['object']
    for _ in range(5):
        if obj['type'] == 'commit' and SHA.fullmatch(obj['sha']):
            return obj['sha']
        if obj['type'] != 'tag' or not SHA.fullmatch(obj['sha']):
            break
        obj = api(f'repos/{repo}/git/tags/{obj["sha"]}')['object']
    raise ValueError('Could not resolve official release tag to a commit')


def plan_release(args):
    settings = manifest()
    dirty = run(['git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=normal']).strip()
    if dirty and not args.allow_dirty:
        raise ValueError('Commit release changes first, or use --allow-dirty for a non-publishable audit plan')
    repo = settings['mpv_repository']
    if args.mpv_tag:
        if not STABLE_TAG.fullmatch(args.mpv_tag):
            raise ValueError('Only official vMAJOR.MINOR.PATCH tags are accepted')
        releases = [api(f'repos/{repo}/releases/tags/{args.mpv_tag}')]
    else:
        releases = api(f'repos/{repo}/releases?per_page=100')
    release = official_release(releases, args.mpv_tag)
    tag = release['tag_name']
    project_tag = f'player-{tag}-r{settings["revision"]}'
    existing = api(f'repos/{settings["repository"]}/releases/tags/{project_tag}', missing_ok=True)
    commit = resolve_commit(repo, tag)
    source = run(['git', '-C', ROOT, 'rev-parse', 'HEAD']).strip()
    plan = dict(schema=1, repository=settings['repository'], tag=project_tag,
                mpv_tag=tag, mpv_commit=commit, config_commit=source,
                upstream_url=release['html_url'], build=settings,
                needed=existing is None or existing.get('draft', False), channel='prerelease',
                source_verified=not bool(dirty))
    dump(args.output, plan)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as output:
            for key, value in [('needed', str(plan['needed']).lower()), ('tag', project_tag)]:
                output.write(f'{key}={value}\n')
    print(f'{project_tag}: ' + ('build required' if plan['needed'] else 'release already exists; bump revision for configuration changes'))


def load_plan(path):
    plan = json.loads(Path(path).read_text(encoding='utf-8'))
    if plan['schema'] != 1 or plan['channel'] != 'prerelease' or not STABLE_TAG.fullmatch(plan['mpv_tag']):
        raise ValueError('Invalid prerelease plan')
    if plan.get('source_verified') is not True:
        raise ValueError('Audit plans from an uncommitted worktree cannot be built or published')
    for key in ('mpv_commit', 'config_commit'):
        if not SHA.fullmatch(plan[key]):
            raise ValueError('Invalid source commit: ' + key)
    expected = f'player-{plan["mpv_tag"]}-r{plan["build"]["revision"]}'
    if plan['tag'] != expected or plan['repository'] != plan['build']['repository']:
        raise ValueError('Inconsistent release identity')
    selected_backports(plan)
    selected_local_patches(plan)
    return plan


def selected_backports(plan):
    commits = plan['build'].get('mpv_backports', {}).get(plan['mpv_tag'], [])
    if not isinstance(commits, list) or any(not isinstance(commit, str) or not SHA.fullmatch(commit) for commit in commits):
        raise ValueError('Backports must be immutable upstream commits')
    return commits


def selected_local_patches(plan):
    paths = plan['build'].get('mpv_local_patches', {}).get(plan['mpv_tag'], [])
    if not isinstance(paths, list) or any(not isinstance(path, str) or not
            re.fullmatch(r'release/patches/[A-Za-z0-9_-][A-Za-z0-9_.-]*\.patch', path) for path in paths):
        raise ValueError('Local patches must be committed release/patches files')
    return paths


def adapt_backport(text, commit, tag):
    # Upstream changed sub-delay precision before adding independent sub-scale.
    # Adapt only unchanged context; retain 0.41's original sub-delay types.
    if tag == 'v0.41.0' and commit == '8ab3f8b66dcf2c2471f4dbba5cee21cda06843b7':
        for old, new in [('OPT_DOUBLE(sub_delay[1])', 'OPT_FLOAT(sub_delay[1])'),
                         ('double sub_delay[2];', 'float sub_delay[2];')]:
            matches = [line for line in text.splitlines() if old in line]
            if len(matches) != 1 or not matches[0].startswith(' '):
                raise ValueError('Unexpected upstream patch context; manual review required')
            text = text.replace(old, new)
    return text


def hash_file(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else _hash_stream(stream)


def _hash_stream(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        result.update(chunk)
    return result.hexdigest()


def distributable_files(player):
    for path in sorted(player.rglob('*')):
        relative = path.relative_to(player)
        if any(part.lower() in PRIVATE_DIRS for part in relative.parts):
            continue
        if path.is_symlink():
            raise ValueError('Release cannot contain symlinks: ' + str(relative))
        if path.is_file():
            yield path, relative.as_posix()


def fingerprint(player):
    digest = hashlib.sha256()
    for path, relative in distributable_files(player):
        digest.update(relative.encode('utf-8') + b'\0' + hash_file(path).encode('ascii') + b'\n')
    return digest.hexdigest()


def safe_member(name):
    path = PurePosixPath(name)
    return bool(name and not path.is_absolute() and '\\' not in name and ':' not in name
                and all(part not in {'.', '..'} for part in name.split('/')))


def public_config(name):
    if not safe_member(name):
        return False
    path = PurePosixPath(name)
    return (not any(part.lower() in PRIVATE_DIRS for part in path.parts)
            and path.name.lower() != 'local.conf'
            and (name in CONFIG_FILES or path.parts[0] in CONFIG_DIRS))


def snapshot_config(source, commit, destination):
    """Read exact committed blobs; never export the owner's live private settings."""
    names = run(['git', '-C', source, 'ls-tree', '-r', '--name-only', '-z', commit]).split('\0')
    with tempfile.TemporaryDirectory(prefix='mpv-release-source-') as temporary:
        archive = Path(temporary) / 'source.zip'
        run(['git', '-C', source, 'archive', '--format=zip', '-o', archive, commit])
        with zipfile.ZipFile(archive) as zipped:
            for name in names:
                if not public_config(name):
                    continue
                info = zipped.getinfo(name)
                if (info.external_attr >> 16) & 0o170000 == 0o120000:
                    raise ValueError('Symlinks are not supported in a Windows release: ' + name)
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(zipped.read(info))
    for name in ('files', 'cache', 'state', 'playlists'):
        (destination / name).mkdir(parents=True)
    # Distribution defaults only. The repository owner's configuration is untouched.
    (destination / 'local.conf').write_text(
        '# Portable release defaults; personal settings may override these.\n'
        'script-opts-append=mpv_torrserver-torrserver_init=no\n'
        'ytdl-raw-options-remove=cookies-from-browser\n', encoding='utf-8')


def validate_capabilities(runtime, settings, env=None):
    mpv = runtime / 'mpv.com'
    if not mpv.is_file() or not (runtime / 'mpv.exe').is_file():
        raise ValueError('Complete Windows player runtime is required')
    vf = run([mpv, '--no-config', '--vf=help'], env=env, cwd=runtime)
    vo = run([mpv, '--no-config', '--vo=help'], env=env, cwd=runtime)
    for key, listing in [('required_filters', vf), ('required_outputs', vo)]:
        for feature in settings[key]:
            if not re.search(r'^\s*' + re.escape(feature) + r'\s', listing, re.M):
                raise ValueError('Player is missing required capability: ' + feature)
    if settings.get('required_options'):
        listing = run([mpv, '--no-config', '--list-options'], env=env, cwd=runtime)
        for option in settings['required_options']:
            if not re.search(r'^\s*--' + re.escape(option) + r'\s', listing, re.M):
                raise ValueError('Player is missing required option: ' + option)
    return run([mpv, '--version'], env=env, cwd=runtime).splitlines()[0]


def package_release(args):
    plan = load_plan(args.plan)
    source = ROOT
    if run(['git', '-C', source, 'rev-parse', 'HEAD']).strip() != plan['config_commit']:
        raise ValueError('Plan and configuration checkout differ')
    destination = Path(args.output).resolve()
    if destination.exists():
        raise ValueError('Output directory exists; choose a fresh path')
    runtime = Path(args.runtime).resolve()
    if runtime == destination or runtime in destination.parents or destination in runtime.parents:
        raise ValueError('Runtime and staging output must be separate directories')
    version = validate_capabilities(runtime, plan['build'])
    provenance = json.loads((runtime / 'build-info.json').read_text(encoding='utf-8'))
    for key in ('mpv_tag', 'mpv_commit'):
        if provenance[key] != plan[key]:
            raise ValueError('Runtime source differs from planned official tag')
    if provenance['dependencies'] != plan['build']:
        raise ValueError('Runtime dependency pins differ from the release plan')
    if not re.search(r'\bmpv v?' + re.escape(plan['mpv_tag'][1:]) + r'(?:\s|[-+])', version):
        raise ValueError('Runtime version differs from planned official release')
    destination.mkdir(parents=True)
    player = destination / 'MPV'
    shutil.copytree(runtime, player)
    config = player / 'portable_config'
    if config.exists():
        raise ValueError('Runtime must not contain bundled personal configuration')
    snapshot_config(source, plan['config_commit'], config)
    dump(player / 'release-info.json', plan)
    dump(player / 'components.json', {'schema': 1, 'components': plan['build']['components'],
                                     'pending': plan['build']['pending_components']})
    # Verification and archiving are deliberately separate. A staged candidate
    # must pass the runtime check before it can become a downloadable ZIP.
    print('Staged: ' + str(player))


def isolated_environment(runtime):
    env = os.environ.copy()
    system = Path(os.environ.get('SystemRoot', 'C:/Windows'))
    env['PATH'] = os.pathsep.join(map(str, [runtime, system / 'System32', system,
                                          system / 'System32/WindowsPowerShell/v1.0']))
    for key in ('LUA_PATH', 'LUA_CPATH', 'PYTHONPATH', 'PYTHONHOME', 'MPV_HOME'):
        env.pop(key, None)
    return env


def error_lines(log):
    return [line for line in log.splitlines() if re.search(r'\[(?:e|f)\]', line)
            or re.search(r'Lua error|Error loading|Failed to (?:open|load)|option.*not found', line, re.I)]


def check_release(args):
    runtime = Path(args.player).resolve()
    plan = load_plan(runtime / 'release-info.json')
    evidence = Path(args.evidence).resolve()
    evidence.mkdir(parents=True, exist_ok=False)
    env = isolated_environment(runtime)
    report = {'passed': False, 'scope': 'CPU playback and script startup; GPU/ASR untested',
              'config_commit': plan['config_commit'], 'mpv_commit': plan['mpv_commit']}
    try:
        report['version'] = validate_capabilities(runtime, plan['build'], env)
        config = runtime / 'portable_config'
        run([sys.executable, ROOT / 'tools/check_config.py', '--config-root', config,
             '--mpv-root', runtime, '--mpv'], env=env, cwd=evidence)
        script = evidence / 'smoke.lua'
        script.write_text('''local loaded = 0
mp.register_event('file-loaded', function()
    loaded = loaded + 1
    mp.add_timeout(0.3, function()
        if loaded == 1 then
            mp.set_property_number('speed', 1.25)
            mp.commandv('playlist-next', 'force')
        else
            assert(mp.get_property_number('speed') == 1, 'speed did not reset')
            mp.msg.info('RELEASE SMOKE PASS: two files loaded and speed reset')
            mp.commandv('quit', '0')
        end
    end)
end)
mp.add_timeout(15, function() mp.commandv('quit', '5') end)
''', encoding='utf-8')
        # A local Y4M fixture avoids requiring external FFmpeg or network media.
        media = evidence / 'sample.y4m'
        media.write_bytes(b'YUV4MPEG2 W16 H16 F25:1 Ip A1:1 C420jpeg\n' +
                          (b'FRAME\n' + bytes([100]) * 256 + bytes([128]) * 128) * 100)
        log = evidence / 'player.log'
        command = [runtime / 'mpv.com', '--config-dir=' + str(config), '--vo=null', '--ao=null',
                   '--hwdec=no', '--osc=no', '--idle=yes', '--pause=no', '--input-ipc-server=',
                   '--resume-playback=no', '--save-position-on-quit=no', '--term-status-msg=',
                   '--msg-level=all=v', '--script=' + str(script), '--log-file=' + str(log),
                   '--reset-on-next-file=speed', media, media]
        report['console'] = run(command, env=env, cwd=evidence)
        if not log.is_file() or not log.stat().st_size:
            raise ValueError('Runtime log missing or empty')
        content = log.read_text(encoding='utf-8', errors='replace')
        report['errors'] = error_lines(content)
        if report['errors'] or 'RELEASE SMOKE PASS:' not in content:
            raise ValueError('Runtime smoke test failed; inspect player.log')
        report['files_sha256'] = fingerprint(runtime)
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        if isinstance(error, subprocess.CalledProcessError):
            report['console'] = (error.stdout or '') + (error.stderr or '')
        raise
    finally:
        dump(evidence / 'report.json', report)
    print('PASS (CPU/scripts only): ' + str(evidence / 'report.json'))


def archive_release(args):
    player = Path(args.player).resolve()
    plan = load_plan(player / 'release-info.json')
    report = json.loads(Path(args.report).read_text(encoding='utf-8'))
    if report['passed'] is not True or any(report[key] != plan[key] for key in ('config_commit', 'mpv_commit')):
        raise ValueError('Missing or mismatched successful runtime check')
    if report['files_sha256'] != fingerprint(player):
        raise ValueError('Player changed after verification; run the check again')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    target = output / (plan['tag'] + '-windows-x64.zip')
    with zipfile.ZipFile(target, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path, relative in distributable_files(player):
            if relative == 'portable_config/local.conf':
                continue
            archive.write(path, 'MPV/' + relative)
        # Empty directories and generated defaults must exist even on first run.
        for name in ('files', 'cache', 'state', 'playlists'):
            archive.writestr('MPV/portable_config/' + name + '/', b'')
        archive.writestr('MPV/portable_config/local.conf',
                         (player / 'portable_config/local.conf').read_bytes())
    if target.stat().st_size >= 2 * 1024**3:
        raise ValueError('Release asset must be smaller than 2 GiB')
    (output / 'SHA256SUMS').write_text(hash_file(target) + '  ' + target.name + '\n', encoding='utf-8')
    dump(output / 'release-plan.json', plan)
    dump(output / 'smoke-report.json', report)
    menu_path = getattr(args, 'menu_report', None)
    if menu_path:
        menu_report = json.loads(Path(menu_path).read_text(encoding='utf-8'))
        if menu_report.get('ok') is not True or menu_report.get('player_sha256') != hash_file(player / 'mpv.exe'):
            raise ValueError('Menu check failed or belongs to a different player')
        dump(output / 'menu-report.json', menu_report)
    notes = (f'Based on [{plan["mpv_tag"]}]({plan["upstream_url"]}), source `{plan["mpv_commit"]}`.\n\n'
             f'Configuration commit: `{plan["config_commit"]}`. Windows x64, project build with VapourSynth.\n\n'
             'Automated checks cover CPU playback, script startup, next-file/reset and native command parsing. '
             'GPU rendering, VS output, AI inference and fresh-machine portability require acceptance before stable promotion.\n\n'
             'Optional components are versioned separately. This candidate does not claim a complete offline AI/VS installation.\n')
    if selected_backports(plan):
        notes += '\nUpstream compatibility backports (included in mpv-source.patch):\n' + ''.join(
            f'- [{commit[:7]}](https://github.com/mpv-player/mpv/commit/{commit})\n' for commit in selected_backports(plan))
    if selected_local_patches(plan):
        notes += '\nProject compatibility patches (included in mpv-source.patch):\n' + ''.join(
            f'- [{path}](https://github.com/{plan["repository"]}/blob/{plan["config_commit"]}/{path})\n'
            for path in selected_local_patches(plan))
    if menu_path:
        notes += '\nFull menu, subtitle controls, next-file and reset checks passed with software D3D11 (WARP). See menu-report.json.\n'
    (output / 'release-notes.md').write_text(notes, encoding='utf-8')
    print('Created: ' + str(target))


def check_archive(args):
    assets = Path(args.assets).resolve()
    plan = load_plan(assets / 'release-plan.json')
    archive = assets / (plan['tag'] + '-windows-x64.zip')
    hashes = (assets / 'SHA256SUMS').read_text(encoding='utf-8').strip()
    if hashes != hash_file(archive) + '  ' + archive.name:
        raise ValueError('Archive hash mismatch')
    with tempfile.TemporaryDirectory(prefix='mpv release 中文 ') as temporary:
        unpacked = Path(temporary)
        with zipfile.ZipFile(archive) as zipped:
            if zipped.testzip():
                raise ValueError('ZIP integrity failure')
            for info in zipped.infolist():
                if not safe_member(info.filename.rstrip('/')):
                    raise ValueError('Unsafe ZIP member: ' + info.filename)
            zipped.extractall(unpacked)
        check_release(argparse.Namespace(player=unpacked / 'MPV', evidence=args.evidence))
    report = json.loads((Path(args.evidence) / 'report.json').read_text(encoding='utf-8'))
    report['archive_sha256'] = hash_file(archive)
    dump(assets / 'smoke-report.json', report)


def publish_release(args):
    directory = Path(args.assets).resolve()
    plan = load_plan(directory / 'release-plan.json')
    report = json.loads((directory / 'smoke-report.json').read_text(encoding='utf-8'))
    if report['passed'] is not True or any(report[key] != plan[key] for key in ('config_commit', 'mpv_commit')):
        raise ValueError('Refusing to publish an unverified candidate')
    expected_archive = plan['tag'] + '-windows-x64.zip'
    hashes = (directory / 'SHA256SUMS').read_text(encoding='utf-8').strip()
    if hashes != hash_file(directory / expected_archive) + '  ' + expected_archive:
        raise ValueError('Archive hash mismatch')
    if report.get('archive_sha256') != hash_file(directory / expected_archive):
        raise ValueError('Final archive has not passed relocation and playback checks')
    # Do not overwrite published assets or silently promote a release on reruns.
    repo = plan['repository']
    existing = api(f'repos/{repo}/releases/tags/{plan["tag"]}', missing_ok=True)
    if existing and not existing['draft']:
        raise ValueError('Release already exists; increase the configuration revision')
    if existing and existing['target_commitish'] != plan['config_commit']:
        raise ValueError('Draft belongs to a different configuration commit; increase revision')
    menu_report = json.loads((directory / 'menu-report.json').read_text(encoding='utf-8'))
    with zipfile.ZipFile(directory / expected_archive) as zipped:
        with zipped.open('MPV/mpv.exe') as binary:
            binary_hash = _hash_stream(binary)
    if menu_report.get('ok') is not True or menu_report.get('player_sha256') != binary_hash:
        raise ValueError('Final player has not passed the full menu check')
    if not existing:
        run(['gh', 'release', 'create', plan['tag'], '--repo', repo, '--target', plan['config_commit'],
             '--draft', '--prerelease', '--latest=false', '--title', plan['tag'],
             '--notes-file', directory / 'release-notes.md'])
    for filename in (expected_archive, 'SHA256SUMS', 'release-plan.json', 'smoke-report.json', 'menu-report.json'):
        run(['gh', 'release', 'upload', plan['tag'], directory / filename, '--repo', repo, '--clobber'])
    run(['gh', 'release', 'edit', plan['tag'], '--repo', repo,
         '--draft=false', '--prerelease', '--latest=false'])
    print(f'Published prerelease: https://github.com/{repo}/releases/tag/{plan["tag"]}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    plan = commands.add_parser('plan')
    plan.add_argument('--mpv-tag', default='')
    plan.add_argument('--allow-dirty', action='store_true', help='Write a diagnostic plan that cannot be built or published')
    plan.add_argument('--output', required=True, type=Path)
    package = commands.add_parser('stage')
    package.add_argument('--plan', required=True, type=Path)
    package.add_argument('--runtime', required=True, type=Path)
    package.add_argument('--output', required=True, type=Path)
    check = commands.add_parser('check')
    check.add_argument('--player', required=True, type=Path)
    check.add_argument('--evidence', required=True, type=Path)
    archive = commands.add_parser('archive')
    archive.add_argument('--player', required=True, type=Path)
    archive.add_argument('--report', required=True, type=Path)
    archive.add_argument('--menu-report', required=True, type=Path)
    archive.add_argument('--output', required=True, type=Path)
    publish = commands.add_parser('publish')
    publish.add_argument('--assets', required=True, type=Path)
    packed = commands.add_parser('check-archive')
    packed.add_argument('--assets', required=True, type=Path)
    packed.add_argument('--evidence', required=True, type=Path)
    args = parser.parse_args()
    handlers = {'plan': plan_release, 'stage': package_release, 'check': check_release,
                'archive': archive_release, 'publish': publish_release, 'check-archive': check_archive}
    try:
        handlers[args.command](args)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
