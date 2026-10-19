"""Verified component archives, exclusive installation and machine-local registration."""
import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import urllib.parse
import urllib.request
import uuid
import zipfile

IDS = ('vs', 'media', 'whisper', 'qwen')
VS_DIRS = {'Lib', 'vs-coreplugins', 'vs-plugins', 'vs-scripts'}
VS_DLL = re.compile(r'^(python|VSScript|VapourSynth|libcrypto|libssl|libffi|sqlite3|vcruntime|msvcp|concrt|vccorlib).*\.dll$', re.I)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def relative(value):
    if not isinstance(value, str) or '\\' in value or ':' in value or not value or value.startswith('/'):
        raise ValueError('Unsafe component path')
    parts = value.split('/')
    if any(p in ('', '.', '..') or p.rstrip(' .') != p or any(ord(c) < 32 for c in p) or
           re.match(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)', p, re.I) for p in parts):
        raise ValueError('Unsafe component path: ' + value)
    return Path(*PurePosixPath(value).parts)


def inside(root, name):
    root = Path(os.path.abspath(root))
    target = root / relative(name)
    for part in [target, *target.parents]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0):
            raise ValueError('Refuse reparse path: ' + str(part))
    # relative() disallows absolute paths and '..'; all ancestors, including
    # root's parents, have been checked without repeatedly resolving long paths.
    return target


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.pending')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    os.replace(temporary, path)


def catalog(value):
    if str(value).startswith('https://'):
        with urllib.request.urlopen(str(value), timeout=30) as response:
            if urllib.parse.urlsplit(response.url).scheme != 'https':
                raise ValueError('Catalog redirected outside HTTPS')
            data = response.read(2 * 1024 * 1024 + 1)
        base = str(value)
    else:
        path = Path(value).resolve()
        data, base = path.read_bytes(), path.parent
    if len(data) > 2 * 1024 * 1024:
        raise ValueError('Catalog too large')
    result = json.loads(data)
    if result.get('schema') != 1 or not isinstance(result.get('components'), list):
        raise ValueError('Unsupported component catalog')
    seen = set()
    for item in result['components']:
        if item.get('id') not in IDS or item['id'] in seen or not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9._-]{0,79}', item.get('version', '')):
            raise ValueError('Invalid/duplicate component identity')
        seen.add(item['id'])
        relative(item['archive'])
        if not re.fullmatch('[a-f0-9]{64}', item.get('sha256', '')):
            raise ValueError('Missing immutable archive SHA256')
        if not isinstance(item.get('bytes'), int) or not 0 < item['bytes'] <= 96 * 1024**3:
            raise ValueError('Invalid archive size')
        if not isinstance(item.get('expanded_bytes'), int) or not 0 < item['expanded_bytes'] <= 128 * 1024**3:
            raise ValueError('Invalid expanded size')
    return result, base


def obtain(item, base, download_root):
    if isinstance(base, Path):
        path = inside(base, item['archive'])
        if path.stat().st_size != item['bytes'] or digest(path) != item['sha256']:
            raise ValueError('Local archive size/SHA256 mismatch: ' + item['id'])
        return path
    url = urllib.parse.urljoin(base, item.get('url') or item['archive'])
    if urllib.parse.urlsplit(url).scheme != 'https':
        raise ValueError('Component downloads require HTTPS')
    root = Path(download_root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    target = inside(root, item['sha256'] + '.zip')
    if target.is_file() and target.stat().st_size == item['bytes'] and digest(target) == item['sha256']:
        return target
    temporary = target.with_suffix('.' + uuid.uuid4().hex + '.part')
    with urllib.request.urlopen(url, timeout=60) as response, temporary.open('xb') as output:
        if urllib.parse.urlsplit(response.url).scheme != 'https':
            raise ValueError('Component redirected outside HTTPS')
        count = 0
        while block := response.read(1024 * 1024):
            count += len(block)
            if count > item['bytes']:
                raise ValueError('Download exceeded pinned size')
            output.write(block)
    if temporary.stat().st_size != item['bytes'] or digest(temporary) != item['sha256']:
        raise ValueError('Downloaded component hash mismatch; partial file retained')
    os.replace(temporary, target)
    return target


def vs_path(name):
    parts = relative(name).parts
    if parts[0] in VS_DIRS:
        return True
    if len(parts) != 1:
        return False
    return (bool(VS_DLL.fullmatch(name)) or name.endswith('.pyd') or name.startswith('LICENSE') or
            bool(re.fullmatch(r'python[\w.]*\.(exe|zip|_pth|cat)', name)) or name in ('portable.vs', 'VSPipe.exe'))


def unpack(archive, item, stage):
    stage = Path(stage).resolve()
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        if len(entries) > 250000:
            raise ValueError('Too many archive entries')
        names = set()
        for entry in entries:
            relative(entry.filename)
            key = entry.filename.casefold()
            if key in names or stat.S_ISLNK(entry.external_attr >> 16):
                raise ValueError('Duplicate or link archive entry')
            names.add(key)
        info = package.getinfo('component.json')
        if info.file_size > 64 * 1024**2:
            raise ValueError('Component file index too large')
        manifest = json.loads(package.read(info))
        if manifest.get('schema') != 1 or manifest.get('id') != item['id'] or manifest.get('version') != item['version']:
            raise ValueError('Archive identity mismatch')
        files = manifest.get('files', [])
        expected = {'component.json'}
        total = 0
        for file in files:
            name = str(relative(file['path']).as_posix())
            if item['id'] == 'vs' and not vs_path(name):
                raise ValueError('VS archive attempted to replace player/configuration files')
            if not re.fullmatch('[a-f0-9]{64}', file.get('sha256', '')) or not isinstance(file.get('bytes'), int) or file['bytes'] < 0:
                raise ValueError('Invalid payload file index')
            total += file['bytes']
            expected.add('payload/' + name)
        if total != item['expanded_bytes'] or names != {n.casefold() for n in expected} or len(expected) != len(files) + 1:
            raise ValueError('Unexpected/missing payload or expanded size mismatch')
        if shutil.disk_usage(stage.parent).free < total + 512 * 1024**2:
            raise ValueError('Insufficient free space for component staging')
        for index, file in enumerate(files):
            name = 'payload/' + file['path']
            entry = package.getinfo(name)
            if entry.file_size != file['bytes']:
                raise ValueError('ZIP file size disagrees with index')
            target = inside(stage, file['path'])
            target.parent.mkdir(parents=True, exist_ok=True)
            h, count = hashlib.sha256(), 0
            with package.open(entry) as source, target.open('xb') as output:
                while block := source.read(1024 * 1024):
                    count += len(block)
                    if count > file['bytes']:
                        raise ValueError('Expanded file exceeded index size')
                    h.update(block)
                    output.write(block)
            if count != file['bytes'] or h.hexdigest() != file['sha256']:
                raise ValueError('Payload SHA256 mismatch: ' + file['path'])
            if index and index % 3000 == 0:
                print(f"{item['id']}: verified {index}/{len(files)} files", flush=True)
    return manifest


def checked(command, cwd, timeout=90):
    environment = os.environ.copy()
    for name in ('PYTHONHOME', 'PYTHONPATH', 'VIRTUAL_ENV', 'CONDA_PREFIX'):
        environment.pop(name, None)
    system = Path(os.environ.get('SystemRoot', 'C:/Windows'))
    environment.update(PATH=os.pathsep.join(map(str, [cwd, Path(cwd) / 'python', system / 'System32', system])),
                       PYTHONNOUSERSITE='1', PYTHONIOENCODING='utf-8', HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1')
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=environment, capture_output=True, timeout=timeout,
                            creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    output = (result.stdout + result.stderr).decode('utf-8', errors='replace')
    if result.returncode:
        raise RuntimeError(f'Component probe exit={result.returncode}: {output[-2000:]}')
    return output


def probe(kind, directory):
    directory = Path(directory).resolve()
    if kind == 'vs':
        code = ('import json,sys,pathlib,importlib.metadata as m; import vapoursynth as vs,k7sfunc; '
                'import ctypes,ssl,sqlite3; assert ctypes.windll.kernel32.GetCurrentProcessId()>0; '
                'assert pathlib.Path(k7sfunc.__file__).resolve().is_relative_to(pathlib.Path(sys.executable).parent); '
                'c=vs.core.std.BlankClip(width=16,height=16,length=1); f=c.get_frame(0); '
                'print("COMPONENT_PROBE_OK "+json.dumps({"python":sys.version.split()[0],"k7sfunc":m.version("k7sfunc"),"width":f.width}))')
        output = checked([directory / 'python.exe', '-I', '-c', code], directory)
    elif kind == 'qwen':
        python = directory / 'python/python.exe'
        legacy = not python.is_file()
        if legacy:
            python = directory / 'Scripts/python.exe'
        portable_checks = '' if legacy else (
            'assert sys.prefix==sys.base_prefix; '
            'assert all(pathlib.Path(x).resolve().is_relative_to(p) for x in sys.path if x); '
            'assert (p/"msvcp140.dll").is_file(); ')
        helper = str(Path(__file__).resolve().parent)
        code = ('import sys; sys.path.insert(0,' + repr(helper) + '); '
                'from qwen_runtime import prepare_import_paths; sys.path.pop(0); prepare_import_paths(); '
                'import json,pathlib,torch,qwen_asr; '
                'p=pathlib.Path(sys.prefix).resolve(); '
                'assert pathlib.Path(torch.__file__).resolve().is_relative_to(p); '
                'assert pathlib.Path(qwen_asr.__file__).resolve().is_relative_to(p); '
                'assert torch.cuda.is_available(); ' + portable_checks +
                'print("COMPONENT_PROBE_OK "+json.dumps({"python":sys.version.split()[0],"torch":torch.__version__,"cuda":torch.cuda.get_device_name(),"portable":sys.prefix==sys.base_prefix}))')
        output = checked([python, '-I', '-c', code], directory, 180)
        models = directory.parent / 'models' if legacy else directory / 'models'
        for folder in ('Qwen3-ASR-1.7B', 'Qwen3-ForcedAligner-0.6B'):
            if not (models / folder / 'config.json').is_file():
                raise ValueError('Qwen local model is missing')
    elif kind == 'whisper':
        output = checked([directory / 'faster-whisper-xxl.exe', '--help'], directory)
        if not all(flag in output for flag in ('--model', '--model_dir', '--compute_type')):
            raise ValueError('Whisper help did not confirm required options')
        if not any((directory / '_models').rglob('model.bin')):
            raise ValueError('Whisper package lacks offline model')
        return {'kind': 'CLI/model presence', 'inference_verified': False}
    else:
        for executable in ('ffmpeg.exe', 'ffprobe.exe'):
            output = checked([directory / executable, '-version'], directory)
            if 'version' not in output:
                raise ValueError('Media CLI output missing')
        return {'kind': 'media CLI', 'ready': True}
    match = re.search(r'COMPONENT_PROBE_OK (\{[^\r\n]+\})', output)
    if not match:
        raise ValueError('Native probe produced no valid output')
    return json.loads(match[1])


@contextlib.contextmanager
def install_lock(root):
    path = inside(root, 'portable_config/state/components/install.lock')
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    except FileExistsError:
        raise ValueError('Install lock exists. Inspect the interrupted installation before removing its lock: ' + str(path))
    with os.fdopen(handle, 'w') as stream:
        stream.write(str(os.getpid()))
    try:
        yield
    finally:
        path.unlink()


def install(root, item, archive, run_probe=True):
    root = Path(root).resolve()
    stage = inside(root, 'portable_config/cache/component-staging/' + item['id'] + '-' + uuid.uuid4().hex)
    stage.mkdir(parents=True)
    manifest = unpack(archive, item, stage / 'payload')
    payload = stage / 'payload'
    if run_probe:
        probe(item['id'], payload)
    target = root if item['id'] == 'vs' else inside(root, f"components/{item['id']}/{item['version']}")
    plans = []
    new_bytes = 0
    for index, file in enumerate(manifest['files']):
        destination = inside(target, file['path'])
        if destination.exists():
            if not destination.is_file() or digest(destination) != file['sha256']:
                raise ValueError('Existing component file differs; nothing was overwritten: ' + str(destination))
        else:
            plans.append((inside(payload, file['path']), destination))
            new_bytes += file['bytes']
        if index and index % 3000 == 0:
            print(f"{item['id']}: checked destinations {index}/{len(manifest['files'])}", flush=True)
    created = []
    copy_space_checked = False
    try:
        for index, (source, destination) in enumerate(plans):
            destination.parent.mkdir(parents=True, exist_ok=True)
            # Exclusive creation avoids overwriting a concurrent/user file.
            try:
                os.link(source, destination)
            except FileExistsError:
                raise
            except OSError:
                if not copy_space_checked:
                    if shutil.disk_usage(root).free < new_bytes + 512 * 1024**2:
                        raise ValueError('Insufficient free space for component copy fallback')
                    copy_space_checked = True
                with source.open('rb') as incoming, destination.open('xb') as outgoing:
                    created.append(destination)
                    shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
            else:
                created.append(destination)
            if index and index % 3000 == 0:
                print(f"{item['id']}: installed {index}/{len(plans)} files", flush=True)
        health = probe(item['id'], target) if run_probe else {'test_only': True}
        receipt = dict(schema=1, id=item['id'], version=item['version'], archive_sha256=item['sha256'],
                       root=str(target), files=manifest['files'], probe=health)
        atomic_json(inside(root, 'portable_config/state/components/' + item['id'] + '.json'), receipt)
    except Exception:
        for path in reversed(created):
            if path.resolve().is_relative_to(root):
                path.unlink(missing_ok=True)
        raise
    # Only this installer-created staging directory, resolved inside this player's cache.
    if not stage.resolve().is_relative_to(root / 'portable_config/cache/component-staging'):
        raise ValueError('Unexpected staging cleanup location')
    shutil.rmtree(stage)
    return receipt


def configure(root, receipts):
    root = Path(root).resolve()
    local = inside(root, 'portable_config/local.conf')
    text = local.read_text(encoding='utf-8-sig') if local.is_file() else ''
    values = {}
    for item in receipts:
        directory = Path(item['root'])
        if item['id'] == 'media':
            values['sub_fastwhisper-ffmpeg_path'] = directory / 'ffmpeg.exe'
        elif item['id'] == 'vs':
            values['gpu-effects-runtime_path'] = root
        elif item['id'] == 'whisper':
            values['sub_fastwhisper-fast_whisper_path'] = directory / 'faster-whisper-xxl.exe'
            values['sub_fastwhisper-whisper_model_dir'] = directory / '_models'
        elif item['id'] == 'qwen':
            values['sub_fastwhisper-qwen_python'] = directory / 'python/python.exe'
            values['sub_fastwhisper-qwen_model'] = directory / 'models/Qwen3-ASR-1.7B'
            values['sub_fastwhisper-qwen_aligner'] = directory / 'models/Qwen3-ForcedAligner-0.6B'
    for key, value in values.items():
        pattern = r'^\s*script-opts-append=' + re.escape(key) + r'=.*$'
        line = 'script-opts-append=' + key + '=' + Path(value).as_posix()
        text = re.sub(pattern, lambda _: line, text, flags=re.M) if re.search(pattern, text, re.M) else text.rstrip() + '\n' + line + '\n'
    if local.is_file():
        backup = inside(root, 'portable_config/state/components/local.conf.before-' + uuid.uuid4().hex)
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(local, backup)
    temporary = local.with_name('local.conf.' + uuid.uuid4().hex + '.pending')
    temporary.parent.mkdir(parents=True, exist_ok=True)
    temporary.write_text(text, encoding='utf-8', newline='\n')
    os.replace(temporary, local)
