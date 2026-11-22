"""Validate real GPU sampling, invalidation, menu and local diagnostic probes."""
from datetime import datetime
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    folder = ROOT / 'cache/player-health' / ('test-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    folder.mkdir(parents=True)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=640x360:rate=30', '-t', '20', '-c:v', 'libx264', '-preset', 'ultrafast', str(folder / 'first.mkv')], check=True, timeout=30)
    shutil.copy2(folder / 'first.mkv', folder / 'second.mkv')
    command = [str(ROOT.parent / 'mpv.exe'), '--config-dir=' + str(ROOT), '--load-scripts=no',
               '--script=' + str(ROOT / 'scripts/uosc'), '--script=' + str(ROOT / 'scripts/player-health.lua'),
               '--script=' + str(ROOT / 'tools/tests/test_player_health.lua'), '--vo=gpu-next', '--gpu-api=d3d11',
               '--ao=null', '--osc=no', '--idle=yes', '--pause=no', '--input-ipc-server=',
               '--resume-playback=no', '--save-position-on-quit=no', '--geometry=1280x720', '--term-status-msg=',
               '--script-opts-append=health-test-output=' + folder.as_posix(),
               '--script-opts-append=player-health-warmup_seconds=0', '--log-file=' + str(folder / 'player.log'), str(folder / 'first.mkv')]
    with (folder / 'console.log').open('wb') as log:
        proc = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = proc.wait(timeout=100)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True, timeout=10)
            code = proc.wait(timeout=10)
    result_file = folder / 'result.json'
    result = json.loads(result_file.read_text(encoding='utf-8')) if result_file.is_file() else {}
    log = (folder / 'player.log').read_text(encoding='utf-8', errors='replace')
    screenshot = folder / 'menu.png'
    result['passed'] = bool(result.get('passed') and code == 0 and 'PLAYER HEALTH PASS:' in log
                            and screenshot.is_file() and screenshot.stat().st_size > 1024)
    result['exit_code'] = code
    (folder / 'report.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(('PASS: ' if result['passed'] else 'FAIL: ') + str(folder / 'report.json'))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
