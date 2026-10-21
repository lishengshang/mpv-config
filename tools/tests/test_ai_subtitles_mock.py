"""Run subtitle lifecycle/cache/menu assertions without models or a GPU."""
import argparse
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mpv', type=Path, default=ROOT.parent / 'mpv.exe')
    args = parser.parse_args()
    folder = ROOT / 'cache' / ('asr-mock-' + time.strftime('%Y%m%d-%H%M%S'))
    for name in ('A', 'B'):
        (folder / name).mkdir(parents=True)
        (folder / name / 'clip.wav').write_bytes(b'local identity fixture')
    command = [str(args.mpv), '--no-config', '--config-dir=' + str(ROOT), '--load-scripts=no',
               '--script=' + str(ROOT / 'tools/tests/test_ai_subtitles.lua'), '--idle=yes', '--vo=null', '--ao=null',
               '--input-ipc-server=', '--log-file=' + str(folder / 'player.log'),
               '--script-opts=asr-test-root=' + folder.as_posix() + ',asr-test-script=' + (ROOT / 'scripts/sub-fastwhisper.lua').as_posix()]
    with (folder / 'console.log').open('wb') as log:
        result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=30)
    content = (folder / 'player.log').read_text(encoding='utf-8', errors='replace')
    markers = [line for line in content.splitlines() if 'ASR CACHE MOCK ' in line]
    passed = result.returncode == 0 and any('ASR CACHE MOCK PASS:' in line for line in markers)
    print('\n'.join(markers) + '\n' + str(folder / 'player.log'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
