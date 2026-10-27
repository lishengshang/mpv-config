"""Fetch fixed official ASR checkpoints; verify weight digests before registration."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))

MODELS = {
    'qwen/Qwen3-ASR-0.6B': ('Qwen/Qwen3-ASR-0.6B', '5eb144179a02acc5e5ba31e748d22b0cf3e303b0',
                           ['*.json', 'merges.txt', 'vocab.json', '*.safetensors', 'LICENSE*']),
    'sensevoice/SenseVoiceSmall': ('FunAudioLLM/SenseVoiceSmall', '3847d57b6bdf2dd8875cb1508d2af43d80a16bf7',
                                 ['*.json', '*.yaml', '*.mvn', '*.model', 'model.pt', 'LICENSE*']),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--source', choices=['huggingface', 'modelscope'], default='huggingface')
    args = parser.parse_args()
    downloads = args.directory.resolve().parent / 'downloads'
    os.environ['HF_HOME'] = str(downloads / 'huggingface')
    os.environ['HF_HUB_CACHE'] = str(downloads / 'huggingface/hub')
    os.environ['HF_XET_CACHE'] = str(downloads / 'xet')
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    from huggingface_hub import HfApi, snapshot_download
    from download_qwen_models import modelscope_weight
    for name, (repo, revision, patterns) in MODELS.items():
        folder = args.directory / name
        info = HfApi().model_info(repo, revision=revision, files_metadata=True)
        use_mirror = args.source == 'modelscope' and repo.startswith('Qwen/')
        snapshot_download(repo, revision=revision, local_dir=folder, max_workers=3,
                          allow_patterns=[p for p in patterns if not (use_mirror and p == '*.safetensors')])
        for file in info.siblings:
            if not file.rfilename.endswith(('.pt', '.safetensors')):
                continue
            target = folder / file.rfilename
            if use_mirror:
                modelscope_weight(repo.split('/')[1], file.rfilename, file.size, file.lfs.sha256, target)
            if not file.lfs or not target.is_file():
                raise RuntimeError('Official weight metadata or downloaded weight missing: ' + repo)
            with target.open('rb') as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != file.lfs.sha256:
                    raise RuntimeError('Official weight digest mismatch: ' + repo)
        (folder / 'revision.json').write_text(json.dumps(dict(repo=repo, revision=revision)) + '\n', encoding='utf-8')
        print('Verified ' + repo + ' @ ' + revision, flush=True)


if __name__ == '__main__':
    main()
