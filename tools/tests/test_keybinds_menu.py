"""Validate Chinese shortcut descriptions and real uosc interaction in mpv."""
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    folder = ROOT / 'cache/keybinds-menu' / datetime.now().strftime('%Y%m%d-%H%M%S')
    folder.mkdir(parents=True)
    # A real local Y4M video keeps this UI test independent of external FFmpeg.
    media = folder / 'first.y4m'
    frame = bytes(40 + x * 160 // 320 for y in range(180) for x in range(320)) + bytes([128]) * (320 * 180 // 2)
    with media.open('wb') as video:
        video.write(b'YUV4MPEG2 W320 H180 F10:1 Ip A1:1 C420jpeg\n')
        for _ in range(200):
            video.write(b'FRAME\n' + frame)
    second = folder / 'second.y4m'
    shutil.copyfile(media, second)
    pipe = r'\\.\pipe\mpv-keybinds-test-' + str(os.getpid())
    command = [str(ROOT.parent / 'mpv.exe'), '--config-dir=' + str(ROOT),
               '--input-ipc-server=' + pipe, '--vo=gpu-next', '--gpu-api=d3d11', '--ao=null',
               '--hwdec=no', '--pause=yes', '--idle=yes', '--keep-open=yes', '--geometry=1280x720',
               '--input-cursor=no',
               '--resume-playback=no', '--save-position-on-quit=no', '--term-status-msg=',
               '--osd-fonts-dir=' + str(ROOT / 'fonts'), '--osd-font=Noto Sans Mono CJK SC',
               '--script-opts-append=simplehistory-log_path=' + folder.as_posix(),
               '--script-opts-append=simplebookmark-log_path=' + folder.as_posix(),
               '--script-opts-append=uosc_danmaku-auto_load=no',
               '--script-opts-append=uosc_danmaku-autoload_for_url=no',
               '--script-opts-append=uosc_danmaku-autoload_local_danmaku=no',
               '--log-file=' + str(folder / 'player.log'), str(media)]
    report = {'passed': False, 'checks': []}
    connection, process = None, None
    request_id = 0

    def call(*cmd):
        nonlocal request_id
        request_id += 1
        connection.write((json.dumps({'command': cmd, 'request_id': request_id}) + '\n').encode())
        while True:
            reply = json.loads(connection.readline())
            if reply.get('request_id') == request_id:
                if reply.get('error') != 'success':
                    raise RuntimeError((cmd, reply))
                return reply.get('data')

    def get(prop, default=None):
        try:
            return call('get_property', prop)
        except RuntimeError as error:
            if 'property not found' not in str(error) and 'property unavailable' not in str(error):
                raise
            return default

    def check(label, predicate):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if predicate():
                report['checks'].append(label)
                return
            time.sleep(.05)
        raise AssertionError(label)

    def kind():
        return get('user-data/uosc/menu/type')

    def items():
        return get('user-data/keybinds-menu/menu', {}).get('items', [])

    def open_menu():
        call('script-binding', 'uosc/keybinds')
        check('uosc keybinds entry opens Chinese menu', lambda: kind() == 'keybinds' and items())

    def close():
        call('script-message-to', 'uosc', 'close-menu')
        check('menu closes', lambda: not kind())
        time.sleep(.25)

    def shot(name):
        time.sleep(.6)
        path = folder / (name + '.png')
        call('screenshot-to-file', str(path), 'window')
        check('rendered ' + name, lambda: path.is_file() and path.stat().st_size > 1024)

    def select(hint, title_part):
        index = next(i for i, row in enumerate(items(), 1)
                     if row['hint'] == hint and title_part in row['title'])
        call('script-message-to', 'uosc', 'select-menu-item', 'keybinds', str(index))
        call('keypress', 'ENTER')
        time.sleep(.2)

    with (folder / 'console.log').open('wb') as console:
        try:
            process = subprocess.Popen(command, cwd=ROOT, stdout=console, stderr=subprocess.STDOUT,
                                       creationflags=subprocess.CREATE_NO_WINDOW)
            for _ in range(100):
                try:
                    connection = open(pipe, 'r+b', buffering=0)
                    break
                except OSError:
                    if process.poll() is not None:
                        raise RuntimeError('mpv exited before IPC')
                    time.sleep(.1)
            if connection is None:
                raise RuntimeError('IPC unavailable')
            check('media initialized', lambda: get('video-params') is not None)
            time.sleep(1)
            open_menu()
            rows = items()
            (folder / 'menu.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
            report['item_count'] = len(rows)
            check('every row has Chinese description', lambda: all(re.search('[\u4e00-\u9fff]', r['title']) for r in rows))
            check('no unknown configured command', lambda: not any(r['title'].startswith('脚本操作') for r in rows))
            check('no internal raw commands', lambda: not any('script-message' in r['title'] or 'script-binding' in r['title'] for r in rows))
            check('case-sensitive shortcuts kept', lambda: all(any(r['hint'] == key for r in rows) for key in ['s', 'S', 'Ctrl+m', 'Ctrl+M']))
            check('native aliases use correct descriptions', lambda: any(r['hint'] == 'Ctrl+V' and '剪贴板' in r['title'] for r in rows))
            check('only InputEvent winner shown for SPACE', lambda: not any(r['hint'] == 'SPACE' for r in rows))
            check('InputEvent hold and restore explained', lambda: any(r['hint'] == 'SPACE · 长按' and '3 倍速' in r['title'] for r in rows)
                  and any(r['hint'] == 'SPACE · 松开' and '恢复' in r['title'] for r in rows))
            check('mouse double click explained', lambda: any(r['hint'] == 'MBTN_LEFT · 双击' and '全屏' in r['title'] for r in rows))
            check('conditional gestures explained', lambda: any('空闲时' in r['title'] for r in rows))
            check('no duplicate rows', lambda: len({(r['hint'], r['title']) for r in rows}) == len(rows))
            shot('all-shortcuts')
            select('SPACE · 长按', '3 倍速')
            check('gesture row does not leave speed changed', lambda: get('speed') == 1 and get('pause') and kind() == 'keybinds')
            close()
            open_menu()
            for char in '音量':
                call('keypress', char)
            shot('search-chinese')
            close()
            open_menu()
            for char in 'SPACE':
                call('keypress', char)
            shot('search-key')
            close()
            open_menu()
            select(']', '加快')
            check('normal row executes original command', lambda: abs(get('speed') - 1.1) < .001 and not kind())
            call('set_property', 'speed', 1)
            # Verify comments do not alter InputEvent's real hold/release path.
            call('keydown', 'SPACE')
            check('real SPACE hold still works', lambda: get('speed') == 3 and not get('pause'))
            call('keyup', 'SPACE')
            check('real SPACE release restores state', lambda: get('speed') == 1 and get('pause'))
            start = get('time-pos')
            call('keypress', 'RIGHT')
            check('real RIGHT click seeks forward', lambda: get('time-pos') >= start + 4.8)
            call('set_property', 'pause', False)
            call('keydown', 'RIGHT')
            check('real RIGHT hold invokes fast-forward', lambda: get('speed') > 1.05)
            call('keyup', 'RIGHT')
            check('real RIGHT release restores speed', lambda: abs(get('speed') - 1) < .001)
            call('set_property', 'pause', True)
            call('loadfile', str(second), 'replace')
            check('next media initialized', lambda: get('path') == str(second) and get('video-params') is not None)
            open_menu()
            # Callback IDs belong to each open menu; compare the visible content.
            signature = lambda data: [(row['hint'], row['title']) for row in data]
            check('descriptions survive next file', lambda: signature(items()) == signature(rows))
            close()
            call('keypress', 'MBTN_RIGHT')
            check('right-click main menu still works', lambda: kind() == 'menu-ui')
            shot('main-restored')
            call('script-message-to', 'menu_ui', 'open', '工具与高级')
            time.sleep(.2)
            tools = next(row for row in get('user-data/menu-ui/menu')['items'] if row.get('id') == '工具与高级')
            index = next(i for i, row in enumerate(tools['items'], 1) if row['title'] == '所有快捷键…')
            call('script-message-to', 'uosc', 'select-menu-item', 'menu-ui', str(index), '工具与高级')
            time.sleep(.15)
            call('keypress', 'ENTER')
            check('main menu item opens Chinese shortcuts', lambda: kind() == 'keybinds')
            call('script-binding', 'uosc/keybinds')
            check('uosc keybinds toggle closes reference', lambda: not kind())
            open_menu()
            close()
            report['passed'] = True
        except Exception as error:
            report['error'] = repr(error)
        finally:
            if process and process.poll() is None:
                if connection:
                    try:
                        call('quit')
                    except (OSError, ValueError):
                        process.terminate()
                else:
                    process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
            if connection:
                connection.close()
            report['exit_code'] = process.returncode if process else None
    log = (folder / 'player.log').read_text(encoding='utf-8', errors='replace') if (folder / 'player.log').is_file() else ''
    report['errors'] = re.findall(r'^.*\[(?:e|f)\].*$', log, re.M)
    report['passed'] &= report['exit_code'] == 0 and bool(log) and not report['errors']
    (folder / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'report': str(folder / 'report.json'), **report}, ensure_ascii=True, indent=2))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
