"""Fetch pinned official Qwen checkpoints into an explicitly supplied model directory."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import urllib.request
from huggingface_hub import HfApi, snapshot_download

MODELS = {
    'Qwen3-ASR-1.7B': '7278e1e70fe206f11671096ffdd38061171dd6e5',
    'Qwen3-ForcedAligner-0.6B': 'c7cbfc2048c462b0d63a45797104fc9db3ad62b7',
}


def modelscope_weight(model, name, size, sha256, destination):
    """Official ModelScope mirror; verify against the pinned Hugging Face LFS digest."""
    def digest(path):
        with path.open('rb') as file:
            return hashlib.file_digest(file, 'sha256').hexdigest()
    if destination.is_file() and digest(destination) == sha256:
        return
    url = 'https://modelscope.cn/models/Qwen/' + model + '/resolve/master/' + name
    pending = destination.with_suffix('.safetensors.downloading')
    block = 8 * 1024 * 1024
    with pending.open('wb') as file:
        file.truncate(size)

    def fetch(start):
        end = min(start + block, size) - 1
        for attempt in range(4):
            try:
                request = urllib.request.Request(url, headers={'Range': f'bytes={start}-{end}'})
                with urllib.request.urlopen(request, timeout=90) as response:
                    if response.headers.get('Content-Range') != f'bytes {start}-{end}/{size}':
                        raise RuntimeError('Model mirror returned an unexpected byte range')
                    payload = response.read()
                if len(payload) != end - start + 1:
                    raise RuntimeError('Truncated model download')
                with pending.open('r+b', buffering=0) as file:
                    file.seek(start)
                    file.write(payload)
                return
            except Exception:
                if attempt == 3:
                    raise
    with ThreadPoolExecutor(max_workers=12) as pool:
        for index, _ in enumerate(pool.map(fetch, range(0, size, block))):
            if index % 32 == 0:
                print(f'{model}/{name}: {min((index + 1) * block / size, 1):.0%}', flush=True)
    if digest(pending) != sha256:
        raise RuntimeError('Model mirror checksum differs from the pinned official checkpoint')
    pending.replace(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source', choices=['huggingface', 'modelscope'], default='huggingface')
    args = parser.parse_args()
    for model, revision in MODELS.items():
        folder = args.directory / model
        patterns = ['*.json', 'merges.txt', 'vocab.json']
        if args.source == 'huggingface':
            patterns.append('*.safetensors')
        snapshot_download('Qwen/' + model, revision=revision, local_dir=folder,
                          allow_patterns=patterns, max_workers=3)
        if args.source == 'modelscope':
            info = HfApi().model_info('Qwen/' + model, revision=revision, files_metadata=True)
            for file in info.siblings:
                if file.rfilename.endswith('.safetensors'):
                    modelscope_weight(model, file.rfilename, file.size, file.lfs.sha256, folder / file.rfilename)
        (folder / 'revision.json').write_text(json.dumps(dict(repo='Qwen/' + model, revision=revision)) + '\n', encoding='utf-8')
        print('Downloaded ' + model + ' @ ' + revision, flush=True)


if __name__ == '__main__':
    main()
