"""Run the menu integration against real mpv/uosc. Evidence stays in cache."""
import json
import argparse
import hashlib
import re
import shutil
from pathlib import Path
import subprocess
import sys
from datetime import datetime

ROOT = Path(__file__).resolve().parents[2]


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--full', action='store_true', help='Load the real config and all daily scripts; isolate history and network danmaku')
    parser.add_argument('--software-renderer', action='store_true', help='Use D3D11 WARP without enhancement shaders for CI menu checks')
    parser.add_argument('--local-media', action='store_true', help='Generate a local H.264/AAC fixture with the bundled FFmpeg')
    parser.add_argument('--input-conf', type=Path, default=ROOT / 'input.conf', help='Validate an alternate input configuration, such as the staged snapshot')
    options = parser.parse_args()
    folder = ROOT / 'cache/menu-rework' / (datetime.now().strftime('%Y%m%d-%H%M%S') + ('-full' if options.full else ''))
    folder.mkdir(parents=True)
    for filename, text in [('one.srt', '测试主字幕'), ('two.srt', '测试次字幕')]:
        (folder / filename).write_text(f'1\n00:00:00,000 --> 00:10:00,000\n{text}\n', encoding='utf-8')
    source = 'av://lavfi:testsrc2=size=640x360:rate=30[out0];sine=frequency=440:sample_rate=48000[out1]'
    if options.local_media:
        ffmpeg = ROOT.parent / 'ffmpeg.exe'
        if not ffmpeg.is_file():
            ffmpeg = shutil.which('ffmpeg')
        if not ffmpeg:
            raise SystemExit('FFmpeg required for the local media fixture')
        media = folder / 'media' / 'sample.mkv'
        media.parent.mkdir()
        subprocess.run([str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'testsrc2=size=640x360:rate=30', '-f', 'lavfi', '-i',
                        'sine=frequency=440:sample_rate=48000', '-t', '20', '-c:v', 'libx264',
                        '-preset', 'ultrafast', '-c:a', 'aac', str(media)], check=True, timeout=60)
        source = str(media)
    scripts = ['scripts/uosc', 'scripts/menu-ui.lua', 'scripts/panel-manager.lua', 'scripts/dyn_menu.lua', 'scripts/inputevent.lua',
               'scripts/gpu-effects.lua', 'scripts/quality-menu.lua', 'tools/tests/test_menu_ui_playback.lua']
    if options.full:
        scripts = ['tools/tests/test_menu_ui_playback.lua']
    opts = [f'menu-test-output={folder.as_posix()}', f'simplehistory-log_path={folder.as_posix()}',
            f'simplebookmark-log_path={folder.as_posix()}', 'uosc_danmaku-auto_load=no',
            'uosc_danmaku-autoload_for_url=no', 'uosc_danmaku-autoload_local_danmaku=no']
    args = [str(ROOT.parent / 'mpv.exe'), *([] if options.full else ['--no-config']),
            f'--config-dir={ROOT}', '--load-scripts=' + ('yes' if options.full else 'no'),
            *(f'--script={ROOT / path}' for path in scripts), f'--input-conf={options.input_conf.resolve()}',
            '--vo=gpu-next', '--gpu-api=d3d11', '--ao=null', '--hwdec=no', '--osc=no', '--idle=yes',
            '--input-cursor=no',  # Isolate keyboard navigation from physical mouse movement.
            '--pause=yes', '--input-ipc-server=', '--resume-playback=no', '--save-position-on-quit=no', '--geometry=1280x720',
            '--speed=1', '--mute=no', '--secondary-sub-scale=1', '--video-aspect-override=no', '--loop-file=no',
            '--term-status-msg=', f'--osd-fonts-dir={ROOT / "fonts"}', '--osd-font=Noto Sans Mono CJK SC',
            f'--screenshot-directory={folder}', '--screenshot-template=continuous-%n',
            '--reset-on-next-file=vid,aid,sid,secondary-sid,speed,secondary-sub-scale',
            *(f'--script-opts-append={opt}' for opt in opts), f'--log-file={folder / "player.log"}', source]
    if options.software_renderer:
        args[1:1] = ['--d3d11-warp=yes', '--glsl-shaders-clr']
    timed_out = False
    with (folder / 'console.log').open('wb') as console:
        proc = subprocess.Popen(args, cwd=ROOT, stdout=console, stderr=subprocess.STDOUT)
        try:
            code = proc.wait(timeout=110)
        except subprocess.TimeoutExpired:
            timed_out = True
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True, timeout=10)
            code = proc.wait(timeout=10)
    report_path = folder / 'report.json'
    report = json.loads(report_path.read_text(encoding='utf-8')) if report_path.is_file() else {'ok': False, 'error': 'missing report'}
    log = (folder / 'player.log').read_text(encoding='utf-8', errors='replace') if (folder / 'player.log').is_file() else ''
    report['exit_code'], report['timed_out'] = code, timed_out
    report['renderer'] = 'd3d11-warp' if options.software_renderer else 'd3d11-auto'
    report['media'] = 'local-h264-aac' if options.local_media else 'lavfi-device'
    report['player_sha256'] = hashlib.sha256((ROOT.parent / 'mpv.exe').read_bytes()).hexdigest()
    report['fatal_errors'] = [line for line in log.splitlines() if re.match(r'^\[.*?\]\[f\]\[', line)]
    report['runtime_errors'] = [line for line in log.splitlines() if re.match(r'^\[.*?\]\[e\]\[', line)]
    report['ok'] = bool(report.get('ok') and code == 0 and not timed_out and 'MENU UI PASS:' in log)
    report['ok'] &= not (report['fatal_errors'] or report['runtime_errors'])
    report['ok'] &= all((folder / name).is_file() and (folder / name).stat().st_size > 1024
                        for name in ['main.png', 'subtitles.png', 'next-file.png'])
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({'report': str(report_path), **report}, ensure_ascii=False, indent=2))
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
