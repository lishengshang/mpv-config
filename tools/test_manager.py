"""Exercise real manager routing using isolated local Git revisions and files."""
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    folder = ROOT / 'cache' / ('manager-test-' + time.strftime('%Y%m%d-%H%M%S'))
    source, config = folder / 'upstream', folder / 'portable_config'
    source.mkdir(parents=True)
    (config / 'scripts').mkdir(parents=True)
    (config / 'script-modules').mkdir()
    shutil.copy2(ROOT / 'script-modules/managed-update.lua', config / 'script-modules/managed-update.lua')
    for args in (['init', str(source)],):
        subprocess.run(['git', *args], check=True, capture_output=True)
    for version in (1, 2):
        for name in ('safe.lua', 'custom.lua', 'new.lua'):
            (source / name).write_text(f'-- {name} version {version}\n', encoding='utf-8', newline='\n')
        subprocess.run(['git', '-C', str(source), 'add', '.'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@localhost',
                        'commit', '-m', f'v{version}'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(source), 'tag', f'v{version}'], check=True, capture_output=True)
    (config / 'scripts/safe.lua').write_text('-- safe.lua version 1\n', encoding='utf-8', newline='\n')
    (config / 'scripts/custom.lua').write_text('-- personal customization\n', encoding='utf-8', newline='\n')
    (config / 'manager.json').write_text(json.dumps([dict(git=source.as_posix(), branch='v1', whitelist='%.lua$')]), encoding='utf-8')
    opts = ['manager-root=' + (folder / 'manager').as_posix(), 'manager-test-root=' + folder.as_posix()]
    command = [str(ROOT.parent / 'mpv.exe'), '--no-config', '--config-dir=' + str(config), '--load-scripts=no',
               '--script=' + str(ROOT / 'scripts/uosc'), '--osc=no', '--geometry=1280x720',
               '--osd-fonts-dir=' + str(ROOT / 'fonts'), '--osd-font=Noto Sans Mono CJK SC',
               '--script=' + str(ROOT / 'scripts/manager.lua'), '--script=' + str(ROOT / 'tools/test_manager_playback.lua'),
               '--input-conf=' + str(ROOT / 'input.conf'), '--script-opts=' + ','.join(opts),
               '--vo=gpu-next', '--gpu-api=d3d11', '--ao=null', '--idle=yes', '--pause=yes', '--input-ipc-server=',
               '--log-file=' + str(folder / 'player.log'), 'av://lavfi:testsrc2=size=160x90:rate=24']
    with (folder / 'console.log').open('wb') as log:
        proc = subprocess.Popen(command, cwd=config, stdout=log, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = proc.wait(timeout=90)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True, timeout=10)
            code = proc.wait(timeout=10)
    log = (folder / 'player.log').read_text(encoding='utf-8', errors='replace')
    screenshot = folder / 'preview.png'
    passed = (code == 0 and 'MANAGER PASS:' in log and 'MANAGER FAIL:' not in log
              and screenshot.is_file() and screenshot.stat().st_size > 1024)
    report = dict(passed=passed, exit_code=code, log=str(folder / 'player.log'))
    (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(('PASS: ' if passed else 'FAIL: ') + str(folder / 'report.json'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
