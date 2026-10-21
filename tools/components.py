"""Export pinned offline components, inspect/deploy them, and repair moved-player paths."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import component_store as store

CONFIG = Path(__file__).resolve().parents[1]
SKIP_DIRS = {'__pycache__', '.cache', '.git', '.temp', 'cache', 'logs'}


def walk(source, prefix=''):
    source = Path(source).resolve()
    for parent, directories, names in os.walk(source):
        directories[:] = sorted(d for d in directories if d not in SKIP_DIRS)
        for name in sorted(names):
            path = Path(parent) / name
            if path.is_symlink() or not path.resolve().is_relative_to(source):
                raise ValueError('Source contains a link outside its component')
            if '.engine' in name or '.cache' in name or name.endswith(('.pyc', '.pyo', '.log')):
                continue
            yield prefix + path.relative_to(source).as_posix(), path


def package(identifier, files, output, metadata=None, bootstrap=False):
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    temporary = output / (identifier + '-' + uuid.uuid4().hex + '.pending.zip')
    entries, names, count_bytes = [], set(), 0
    with zipfile.ZipFile(temporary, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as archive:
        for index, (name, value) in enumerate(files):
            store.relative(name)
            if name.casefold() in names:
                raise ValueError('Duplicate source file: ' + name)
            names.add(name.casefold())
            info = zipfile.ZipInfo(('' if bootstrap else 'payload/') + name, (2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info._compresslevel = 1
            h, size = hashlib.sha256(), 0
            if isinstance(value, bytes):
                incoming = __import__('io').BytesIO(value)
            else:
                incoming = Path(value).open('rb')
            with incoming, archive.open(info, 'w', force_zip64=True) as outgoing:
                while block := incoming.read(1024 * 1024):
                    outgoing.write(block)
                    h.update(block)
                    size += len(block)
                    count_bytes += len(block)
            entries.append(dict(path=name, bytes=size, sha256=h.hexdigest()))
            if index and index % 3000 == 0:
                print(f'{identifier}: packed {index} files, {count_bytes / 1024**3:.2f} GiB', flush=True)
        tree = hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        version = 'local-' + tree[:16]
        if not bootstrap:
            info = zipfile.ZipInfo('component.json', (2020, 1, 1, 0, 0, 0))
            info.compress_type, info._compresslevel = zipfile.ZIP_DEFLATED, 1
            archive.writestr(info, json.dumps(dict(schema=1, id=identifier, version=version, files=entries,
                                                 metadata=metadata or {}), ensure_ascii=False))
    name = identifier + '-' + tree[:16] + '.zip'
    target = output / name
    if target.exists():
        raise ValueError('Immutable archive already exists; choose a new output directory: ' + name)
    os.rename(temporary, target)
    result = dict(id=identifier, version=version, archive=name, bytes=target.stat().st_size,
                  expanded_bytes=count_bytes, sha256=store.digest(target), metadata=metadata or {})
    print(f"PACKED {identifier}: {len(entries)} files, {result['bytes'] / 1024**3:.2f} GiB", flush=True)
    return result


def local_settings(path):
    if not Path(path).is_file():
        return {}
    return {key: value.strip() for key, value in re.findall(r'^\s*script-opts-append=([^=\r\n]+)=(.*)$',
            Path(path).read_text(encoding='utf-8-sig'), re.M)}


def runtime_files(root, bootstrap=False):
    root = Path(root).resolve()
    for path in sorted(root.iterdir()):
        if not path.is_file():
            continue
        if store.vs_path(path.name):
            if bootstrap and (path.name.startswith(('VSScript', 'VapourSynth')) or path.name in ('portable.vs', 'VSPipe.exe')):
                continue
            if path.suffix == '._pth' and bootstrap:
                stdlib = path.stem + '.zip'
                yield path.name, (stdlib + '\n.\nimport site\n').encode()
            else:
                yield path.name, path
    if not bootstrap:
        for name in sorted(store.VS_DIRS):
            if (root / name).is_dir():
                yield from walk(root / name, name + '/')


def qwen_files(base, site, models, vs, python_version):
    pth = 'python' + ''.join(python_version.split('.')[:2]) + '._pth'
    for name, path in walk(base, 'python/'):
        if '/site-packages/' not in name and not name.startswith(('python/Scripts/', 'python/include/', 'python/libs/', 'python/tcl/')) and not name.endswith('._pth'):
            yield name, path
    # Ship the C++ redistributable beside Python instead of relying on the host.
    for path in sorted(vs.iterdir()):
        if re.fullmatch(r'(msvcp|concrt|vccorlib|vcruntime).*\.dll', path.name, re.I) and not (base / path.name).exists():
            yield 'python/' + path.name, path
    yield 'python/' + pth, b'.\nDLLs\nLib\nLib/site-packages\nimport site\n'
    for name, path in walk(site, 'python/Lib/site-packages/'):
        if name.endswith('.pth'):
            for line in path.read_text(encoding='utf-8-sig').splitlines():
                if line and not line.startswith(('#', 'import ')) and (':/' in line or ':\\' in line or line.startswith('/')):
                    raise ValueError('Qwen environment contains a non-portable .pth path')
        yield name, path
    for model in models:
        yield from walk(model, 'models/' + model.name + '/')


def export(args):
    settings = local_settings(CONFIG / 'local.conf')
    vs = Path(args.vs_source or CONFIG.parent).resolve()
    whisper = Path(args.whisper_source or settings.get('sub_fastwhisper-fast_whisper_path', '')).resolve()
    if whisper.is_file():
        whisper = whisper.parent
    qwen_python = Path(args.qwen_python or settings.get('sub_fastwhisper-qwen_python', '')).resolve()
    models = [Path(settings.get('sub_fastwhisper-' + key, '')).resolve() for key in ('qwen_model', 'qwen_aligner')]
    configured_ffmpeg = settings.get('sub_fastwhisper-ffmpeg_path', '')
    ffmpeg = Path(args.ffmpeg or (configured_ffmpeg if Path(configured_ffmpeg).is_file() else '') or shutil.which('ffmpeg') or '').resolve()
    sibling_probe = ffmpeg.with_name('ffprobe.exe')
    ffprobe = Path(args.ffprobe or (str(sibling_probe) if sibling_probe.is_file() else '') or shutil.which('ffprobe') or '').resolve()
    for path in (vs / 'python.exe', whisper / 'faster-whisper-xxl.exe', qwen_python, *[m / 'config.json' for m in models], ffmpeg, ffprobe):
        if not path.is_file():
            raise ValueError('Installed component source missing: ' + str(path))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'tools').mkdir()
    for name in ('components.py', 'component_store.py', 'components.ps1', 'components.cmd', 'qwen_runtime.py'):
        shutil.copy2(CONFIG / 'tools' / name, output / 'tools' / name)
    bootstrap = package('bootstrap', runtime_files(vs, bootstrap=True), output, bootstrap=True)
    info = subprocess.run([str(qwen_python), '-c',
        'import json,sys,importlib.metadata as m; print(json.dumps(dict(base=sys.base_prefix,prefix=sys.prefix,python=sys.version.split()[0],torch=m.version("torch"),qwen=m.version("qwen-asr"))))'],
        check=True, capture_output=True, text=True, timeout=30)
    versions = json.loads(info.stdout)
    base = Path(versions.pop('base')).resolve()
    site = Path(versions.pop('prefix')).resolve() / 'Lib/site-packages'
    if not site.is_dir():
        raise ValueError('Expected installed Qwen site-packages')
    components = [package('media', [('ffmpeg.exe', ffmpeg), ('ffprobe.exe', ffprobe)], output),
                  package('vs', runtime_files(vs), output, {'kind': 'installed VS snapshot, engine caches excluded'}),
                  package('whisper', walk(whisper), output, {'kind': 'installed Faster-Whisper-XXL with offline model'}),
                  package('qwen', qwen_files(base, site, models, vs, versions['python']), output, versions)]
    # Pick up final installer sources after potentially lengthy runtime compression.
    for name in ('components.py', 'component_store.py', 'components.ps1', 'components.cmd', 'qwen_runtime.py'):
        shutil.copy2(CONFIG / 'tools' / name, output / 'tools' / name)
    store.atomic_json(output / 'catalog.json', dict(schema=1, generated=datetime.now().astimezone().isoformat(),
                                                  platform='windows-x86_64-nvidia', bootstrap=bootstrap, components=components))
    (output / 'install-components.cmd').write_text('@echo off\ncall "%~dp0tools\\components.cmd" %*\n', encoding='ascii', newline='\n')
    print('CATALOG: ' + str(output / 'catalog.json'))


def target_directory(root, item):
    return root if item['id'] == 'vs' else store.inside(root, f"components/{item['id']}/{item['version']}")


def adapt_vs(item, archive, player, output):
    """Rebuild the VS snapshot against the candidate's reviewed shared ABI dependency."""
    player = Path(player).resolve()
    if not (player / 'mpv.exe').is_file() or not (player / 'mpv.com').is_file():
        raise ValueError('VS adaptation requires a complete candidate player')
    with zipfile.ZipFile(archive) as zipped:
        if zipped.getinfo('component.json').file_size > 64 * 1024**2:
            raise ValueError('Component file index too large')
        manifest = json.loads(zipped.read('component.json'))
    replacements = []
    for file in manifest['files']:
        candidate = store.inside(player, file['path'])
        if candidate.is_file() and store.digest(candidate) != file['sha256']:
            if file['path'] != 'libffi-8.dll':
                raise ValueError('Unreviewed candidate/VS conflict: ' + file['path'])
            replacements.append(dict(path=file['path'], snapshot_sha256=file['sha256'],
                                     candidate_sha256=store.digest(candidate)))
    if not replacements:
        return item, archive
    with tempfile.TemporaryDirectory(prefix='.vs-adapt-', dir=output) as temporary:
        stage = Path(temporary).resolve()
        if stage.parent != Path(output).resolve():
            raise ValueError('Unsafe VS adaptation staging directory')
        store.unpack(archive, item, stage)
        for replacement in replacements:
            destination = store.inside(stage, replacement['path'])
            shutil.copyfile(store.inside(player, replacement['path']), destination)
            if store.digest(destination) != replacement['candidate_sha256']:
                raise ValueError('Candidate dependency changed during adaptation')
        probe = store.probe('vs', stage)
        metadata = dict(item.get('metadata', {}), candidate_mpv_sha256=store.digest(player / 'mpv.exe'),
                        shared_dependencies=replacements, adaptation_probe=probe)
        adapted = package('vs', walk(stage), output, metadata)
    return adapted, output / adapted['archive']


def prepare(args):
    """Prepare transport assets; this does not approve redistribution or publish them."""
    data, base = store.catalog(args.catalog)
    if not isinstance(base, Path) or any('parts' in item for item in data['components']):
        raise ValueError('Prepare requires an original local, unsplit catalog')
    if not 0 < args.part_bytes < 2 * 1024**3:
        raise ValueError('Part size must be positive and below 2 GiB')
    bootstrap = data['bootstrap']
    store.validate_archive(bootstrap)
    if (bootstrap.get('id') != 'bootstrap' or 'parts' in bootstrap or bootstrap['bytes'] > 128 * 1024**2 or
            not re.fullmatch(r'bootstrap-[a-f0-9]{16}\.zip', bootstrap['archive'])):
        raise ValueError('Bootstrap must remain a single pinned archive below 128 MiB')
    items = [bootstrap, *data['components']]
    names = [item['archive'].casefold() for item in items]
    if len(names) != len(set(names)) or any('/' in name or not name.endswith('.zip') for name in names):
        raise ValueError('Prepare requires distinct flat archive names')
    if any((item['bytes'] + args.part_bytes - 1) // args.part_bytes > 1000
           for item in data['components']):
        raise ValueError('Part size would exceed 1000 parts per archive')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    extra = sum(item['bytes'] + item['expanded_bytes'] for item in data['components']
                if item['id'] == 'vs') if getattr(args, 'vs_player', None) else 0
    if shutil.disk_usage(output).free < sum(item['bytes'] for item in items) + extra + 512 * 1024**2:
        raise ValueError('Insufficient free space for prepared assets')
    prepared = []
    for item in items:
        source = store.obtain(item, base, output)
        adapted = False
        if item['id'] == 'vs' and getattr(args, 'vs_player', None):
            item, source = adapt_vs(item, source, args.vs_player, output)
            adapted = source.parent == output
        result = {key: item[key] for key in ('id', 'version', 'archive', 'bytes', 'expanded_bytes', 'sha256')}
        if 'metadata' in item:
            result['metadata'] = item['metadata']
        if item['id'] == 'bootstrap' or item['bytes'] <= args.part_bytes:
            if source != output / item['archive']:
                shutil.copyfile(source, output / item['archive'])
        else:
            result['parts'] = []
            whole = hashlib.sha256()
            with source.open('rb') as incoming:
                remaining = item['bytes']
                while remaining:
                    name = item['archive'] + f".part{len(result['parts']) + 1:04d}"
                    count, h = 0, hashlib.sha256()
                    with (output / name).open('xb') as outgoing:
                        while count < min(args.part_bytes, remaining):
                            block = incoming.read(min(1024 * 1024, min(args.part_bytes, remaining) - count))
                            if not block:
                                raise ValueError('Source archive changed during preparation')
                            outgoing.write(block)
                            h.update(block)
                            whole.update(block)
                            count += len(block)
                    result['parts'].append(dict(archive=name, bytes=count, sha256=h.hexdigest()))
                    remaining -= count
            if whole.hexdigest() != item['sha256']:
                raise ValueError('Source archive changed during preparation')
            store.validate_archive(result)
            if adapted:
                # Only remove the intermediate archive created in this output directory.
                if source.resolve().parent != output:
                    raise ValueError('Unsafe adapted archive cleanup path')
                source.unlink()
        prepared.append(result)
        print('PREPARED ' + item['id'], flush=True)
    (output / 'tools').mkdir()
    for name in ('components.py', 'component_store.py', 'components.ps1', 'components.cmd', 'qwen_runtime.py'):
        shutil.copyfile(CONFIG / 'tools' / name, output / 'tools' / name)
    (output / 'install-components.cmd').write_text('@echo off\ncall "%~dp0tools\\components.cmd" %*\n', encoding='ascii', newline='\n')
    for item in prepared:
        for asset in item.get('parts', [item]):
            path = output / asset['archive']
            if path.stat().st_size != asset['bytes'] or store.digest(path) != asset['sha256']:
                raise ValueError('Prepared asset size/SHA256 mismatch')
    store.atomic_json(output / 'catalog.json', dict(schema=1, platform=data.get('platform'),
                      bootstrap=prepared[0], components=prepared[1:]))
    sums = [(store.digest(path), path.relative_to(output).as_posix())
            for path in sorted(output.rglob('*')) if path.is_file()]
    (output / 'SHA256SUMS').write_text(''.join(f'{h}  {name}\n' for h, name in sums), encoding='utf-8', newline='\n')
    print('TRANSPORT CATALOG: ' + str(output / 'catalog.json'))


def installed(root):
    items = []
    for kind in store.IDS:
        path = store.inside(root, 'portable_config/state/components/' + kind + '.json')
        if path.is_file():
            item = json.loads(path.read_text(encoding='utf-8'))
            if item.get('id') != kind or not re.fullmatch('[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}', item.get('version', '')):
                raise ValueError('Invalid installed receipt')
            item['root'] = str(target_directory(root, item))
            items.append(item)
    return items


def status(args):
    root = args.mpv_root.resolve()
    receipts = {item['id']: item for item in installed(root)}
    settings = local_settings(root / 'portable_config/local.conf')
    paths = {'vs': root, 'media': Path(settings.get('sub_fastwhisper-ffmpeg_path', shutil.which('ffmpeg') or str(root / 'ffmpeg.exe'))).parent,
             'whisper': Path(settings.get('sub_fastwhisper-fast_whisper_path', str(root / 'faster-whisper-xxl.exe'))).parent,
             'qwen': Path(settings.get('sub_fastwhisper-qwen_python', str(root / 'components/qwen/missing/python/python.exe'))).parent.parent}
    results = []
    for kind in args.components:
        directory = Path(receipts[kind]['root']) if kind in receipts else paths[kind]
        try:
            if kind == 'vs' and kind in receipts and not store.component_launcher(root).is_file():
                raise ValueError('Component launcher missing; run configure to repair it')
            health = store.probe(kind, directory)
            if args.hashes and kind in receipts:
                for index, file in enumerate(receipts[kind]['files']):
                    if store.digest(store.inside(directory, file['path'])) != file['sha256']:
                        raise ValueError('Installed file modified: ' + file['path'])
                    if index and index % 3000 == 0:
                        print(f"{kind}: hashed {index}/{len(receipts[kind]['files'])} files", flush=True)
            result = dict(id=kind, ready=True, root=str(directory), managed=kind in receipts, probe=health)
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            result = dict(id=kind, ready=False, root=str(directory), error=str(error))
        results.append(result)
        print(('READY ' if result['ready'] else 'MISSING/FAILED ') + kind + ('' if result['ready'] else ': ' + result['error'][:300]), flush=True)
    if args.report:
        store.atomic_json(args.report, dict(passed=all(r['ready'] for r in results), components=results))
    return 0 if all(r['ready'] for r in results) else 1


def deploy(args):
    root = args.mpv_root.resolve()
    if not (root / 'mpv.exe').is_file() or not (root / 'portable_config').is_dir():
        raise ValueError('Destination needs mpv.exe and portable_config; player/config are not replaced')
    data, base = store.catalog(args.catalog)
    indexed = {item['id']: item for item in data['components']}
    selected = set(args.components)
    if selected.intersection({'whisper', 'qwen'}):
        selected.add('media')
    if not selected.issubset(indexed):
        raise ValueError('Catalog does not contain requested components and media dependency')
    if 'vs' in selected:
        candidate_sha256 = indexed['vs'].get('metadata', {}).get('candidate_mpv_sha256')
        if candidate_sha256 and (not re.fullmatch('[a-f0-9]{64}', candidate_sha256) or
                                 store.digest(root / 'mpv.exe') != candidate_sha256):
            raise ValueError('Adapted VS catalog does not match this candidate player SHA256')
        store.component_launcher(root)
    receipts = []
    with store.install_lock(root):
        for kind in ('media', 'vs', 'whisper', 'qwen'):
            if kind not in selected:
                continue
            item = indexed[kind]
            print('INSTALL ' + kind + ' ' + item['version'], flush=True)
            previous = next((r for r in installed(root) if r['id'] == kind), None)
            if previous and previous.get('archive_sha256') == item['sha256']:
                directory = Path(previous['root'])
                if all(store.inside(directory, f['path']).is_file() and store.digest(store.inside(directory, f['path'])) == f['sha256'] for f in previous['files']):
                    previous['probe'] = store.probe(kind, directory)
                    receipts.append(previous)
                    print('REUSED ' + kind, flush=True)
                    continue
            archive = store.obtain(item, base, root / 'portable_config/cache/component-downloads')
            receipts.append(store.install(root, item, archive))
            print('INSTALLED ' + kind, flush=True)
        store.configure(root, receipts)
    if args.report:
        store.atomic_json(args.report, dict(passed=True, components=[{k: v for k, v in r.items() if k != 'files'} for r in receipts]))
    return 0


def reconfigure(args):
    root = args.mpv_root.resolve()
    with store.install_lock(root):
        receipts = installed(root)
        if not receipts:
            raise ValueError('No managed component receipts; install a verified component catalog first')
        for receipt in receipts:
            store.probe(receipt['id'], receipt['root'])
        store.configure(root, receipts)
        for receipt in receipts:
            store.atomic_json(store.inside(root, 'portable_config/state/components/' + receipt['id'] + '.json'), receipt)
    print('MOVED PLAYER PATHS UPDATED; private settings preserved')
    return 0


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    command = commands.add_parser('export')
    command.add_argument('--output', type=Path, required=True)
    for name in ('vs-source', 'whisper-source', 'qwen-python', 'ffmpeg', 'ffprobe'):
        command.add_argument('--' + name)
    command = commands.add_parser('prepare', help='Split a local catalog into Release-sized transport assets')
    command.add_argument('--catalog', required=True)
    command.add_argument('--output', type=Path, required=True)
    command.add_argument('--part-bytes', type=int, default=1900 * 1024**2)
    command.add_argument('--vs-player', type=Path, help='Adapt the reviewed libffi-8.dll overlap to this candidate and probe VS')
    for name in ('status', 'install', 'configure'):
        command = commands.add_parser(name)
        command.add_argument('--mpv-root', type=Path, default=CONFIG.parent)
        command.add_argument('--components', nargs='+', choices=store.IDS, default=list(store.IDS))
        command.add_argument('--report', type=Path)
        if name == 'status':
            command.add_argument('--hashes', action='store_true', help='Also check every managed payload SHA256')
        if name == 'install':
            command.add_argument('--catalog', required=True)
    args = parser.parse_args()
    try:
        return {'export': export, 'prepare': prepare, 'status': status, 'install': deploy, 'configure': reconfigure}[args.action](args) or 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
