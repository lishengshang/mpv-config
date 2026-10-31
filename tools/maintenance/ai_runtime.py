"""Prepare and register one AI subtitle root; never remove source environments."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from components import CONFIG, local_settings, qwen_files, walk
from component_store import atomic_json


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def copy_verified(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if digest(source) != digest(destination):
            raise RuntimeError('Refuse to overwrite a different installed file: ' + str(destination))
        return
    pending = destination.with_name(destination.name + '.copying')
    shutil.copy2(source, pending)
    if digest(source) != digest(pending):
        raise RuntimeError('Migration checksum mismatch: ' + str(source))
    pending.replace(destination)


def copy_tree(source, destination):
    for name, path in walk(source):
        copy_verified(path, destination / name)


def clone_python(source, destination):
    if (destination / 'python/python.exe').is_file():
        # A previous managed preparation can be reused; package installs are independent.
        marker = destination / 'prepared.json'
        if marker.is_file():
            return
    info = json.loads(subprocess.check_output([str(source), '-c',
        'import sys,json; print(json.dumps(dict(base=sys.base_prefix,site=sys.prefix+"/Lib/site-packages",version=sys.version.split()[0])))'], text=True))
    print('Preparing independent Python: ' + str(destination), flush=True)
    for name, value in qwen_files(Path(info['base']), Path(info['site']), [], CONFIG.parent, info['version']):
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, bytes):
            if target.exists() and target.read_bytes() != value:
                raise RuntimeError('Existing Python path policy differs: ' + str(target))
            target.write_bytes(value)
        else:
            copy_verified(value, target)
    (destination / 'prepared.json').write_text(json.dumps(info, indent=2) + '\n', encoding='utf-8')


def paths(root):
    return {
        'fast_whisper_path': root / 'runtimes/whisper/faster-whisper-xxl.exe',
        'ffmpeg_path': root / 'runtimes/whisper/ffmpeg.exe',
        'whisper_model_dir': root / 'models/whisper',
        'qwen_python': root / 'runtimes/qwen/python/python.exe',
        'qwen_model': root / 'models/qwen/Qwen3-ASR-1.7B',
        'qwen_small_model': root / 'models/qwen/Qwen3-ASR-0.6B',
        'qwen_aligner': root / 'models/qwen/Qwen3-ForcedAligner-0.6B',
        'sensevoice_python': root / 'runtimes/sensevoice/python/python.exe',
        'sensevoice_model': root / 'models/sensevoice/SenseVoiceSmall',
        'output_path': root / 'subtitles',
    }


def prepare(root, settings):
    for folder in ('runtimes', 'models', 'subtitles', 'downloads', 'state'):
        (root / folder).mkdir(parents=True, exist_ok=True)
    target = paths(root)
    qwen_source = Path(settings.get('sub_fastwhisper-qwen_python', ''))
    if not qwen_source.is_file():
        raise RuntimeError('Configure the existing Qwen Python first, or run tools/setup-qwen-asr.ps1')
    clone_python(qwen_source, root / 'runtimes/qwen')
    clone_python(target['qwen_python'], root / 'runtimes/sensevoice')
    whisper_source = Path(settings.get('sub_fastwhisper-fast_whisper_path', ''))
    if not whisper_source.is_file():
        raise RuntimeError('Configure a trusted Whisper executable first; see docs/ai-subtitles.md')
    if whisper_source.resolve() != target['fast_whisper_path'].resolve():
        for name, source in walk(whisper_source.parent):
            if not name.startswith('_models/'):
                copy_verified(source, root / 'runtimes/whisper' / name)
    whisper_models = Path(settings.get('sub_fastwhisper-whisper_model_dir') or whisper_source.parent / '_models')
    if whisper_models.resolve() != target['whisper_model_dir'].resolve():
        copy_tree(whisper_models, target['whisper_model_dir'])
    for key in ('qwen_model', 'qwen_aligner', 'qwen_small_model'):
        source = Path(settings.get('sub_fastwhisper-' + key, ''))
        if source.is_dir() and str(source) != '.' and source.resolve() != target[key].resolve():
            copy_tree(source, target[key])
    old_cache = settings.get('sub_fastwhisper-output_path', str(CONFIG / 'cache/ai-subtitles'))
    old_cache = Path(old_cache.replace('~~/', CONFIG.as_posix() + '/'))
    if old_cache.is_dir() and old_cache.resolve() != target['output_path'].resolve():
        copy_tree(old_cache, target['output_path'])
    (root / 'state/paths.json').write_text(json.dumps({key: str(value) for key, value in target.items()}, indent=2) + '\n', encoding='utf-8')


def configure(root):
    target = paths(root)
    required = ('fast_whisper_path', 'ffmpeg_path', 'qwen_python', 'sensevoice_python')
    if not all(target[key].is_file() for key in required):
        raise RuntimeError('Runtimes missing; local.conf was not changed')
    for key, name in [('qwen_model', 'config.json'), ('qwen_small_model', 'config.json'),
                      ('qwen_aligner', 'config.json'), ('sensevoice_model', 'model.pt')]:
        if not (target[key] / name).is_file():
            raise RuntimeError('Model missing: ' + key + '; local.conf was not changed')
    if not any(target['whisper_model_dir'].rglob('model.bin')):
        raise RuntimeError('Model missing: whisper_model_dir; local.conf was not changed')
    local = CONFIG / 'local.conf'
    text = local.read_text(encoding='utf-8-sig') if local.is_file() else ''
    backup = root / 'state' / ('local-' + time.strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex + '.conf')
    if local.is_file():
        with local.open('rb') as source, backup.open('xb') as target_file:
            shutil.copyfileobj(source, target_file)
    # Only managed AI paths are replaced; private API options and tuning are retained.
    for key, value in target.items():
        text = re.sub(r'^\s*script-opts-append=sub_fastwhisper-' + key + r'=[^\r\n]*\r?\n?', '', text, flags=re.M)
        text = text.rstrip('\r\n') + '\nscript-opts-append=sub_fastwhisper-' + key + '=' + value.as_posix() + '\n'
    pending = local.with_suffix('.conf.pending')
    pending.write_text(text.replace('\r\n', '\n'), encoding='utf-8', newline='\n')
    pending.replace(local)
    (root / 'state/paths.json').write_text(json.dumps({key: str(value) for key, value in target.items()}, indent=2) + '\n', encoding='utf-8')
    atomic_json(CONFIG / 'state/ai-runtime.json', dict(schema=1, root=str(root),
                managed_keys=['sub_fastwhisper-' + key for key in target]))
    print('AI paths configured; previous local.conf backed up inside the private runtime state directory.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'configure'])
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.action == 'prepare':
        prepare(root, local_settings(CONFIG / 'local.conf'))
    else:
        configure(root)


if __name__ == '__main__':
    main()
