"""Exercise panel ownership and real key routing in mpv. Evidence stays in cache."""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
PROPS = {'files': 'file_browser/open', 'history': 'simplehistory/menu-open',
         'bookmarks': 'simplebookmark/menu-open', 'menu': 'uosc/menu/type',
         'console': 'mpv/console/open'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--full', action='store_true', help='Load all daily scripts and configuration')
    parser.add_argument('--skip-manager', action='store_true', help='Regression control: must fail the initial overlap check')
    args = parser.parse_args()
    if args.full and args.skip_manager:
        parser.error('--skip-manager requires the isolated script set, without --full')
    folder = ROOT / 'cache/panel-manager' / (datetime.now().strftime('%Y%m%d-%H%M%S') + ('-full' if args.full else ''))
    folder.mkdir(parents=True)
    media = folder / 'first.mkv'
    ffmpeg = ROOT.parent / 'ffmpeg.exe'
    if not ffmpeg.is_file():
        ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('FFmpeg required for local media fixtures')
    subprocess.run([str(ffmpeg), '-hide_banner', '-loglevel', 'error', '-f', 'lavfi',
                    '-i', 'testsrc2=size=640x360:rate=30', '-t', '8', '-c:v', 'libx264',
                    '-preset', 'ultrafast', str(media)], check=True, timeout=30)
    second = folder / 'second.mkv'
    shutil.copyfile(media, second)
    pipe = r'\\.\pipe\mpv-panel-test-' + str(os.getpid())
    scripts = ['scripts/uosc', 'scripts/menu-ui.lua', 'scripts/inputevent.lua',
               'scripts/file-browser', 'scripts/simplehistory.lua', 'scripts/simplebookmark.lua']
    if not args.skip_manager:
        scripts.append('scripts/panel-manager.lua')
    command = [str(ROOT.parent / 'mpv.exe'), *([] if args.full else ['--no-config']),
               '--config-dir=' + str(ROOT), '--load-scripts=' + ('yes' if args.full else 'no'),
               *([] if args.full else ['--script=' + str(ROOT / s) for s in scripts]),
               '--input-conf=' + str(ROOT / 'input.conf'), '--input-ipc-server=' + pipe,
               '--vo=gpu-next', '--gpu-api=d3d11', '--ao=null', '--hwdec=no', '--osc=no',
               '--idle=yes', '--pause=yes', '--keep-open=yes', '--geometry=1280x720',
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
            result = json.loads(connection.readline())
            if result.get('request_id') == request_id:
                if result.get('error') != 'success':
                    raise RuntimeError((cmd, result))
                return result.get('data')

    def get(prop, default=None):
        try:
            return call('get_property', prop)
        except RuntimeError as error:
            if 'property not found' not in str(error) and 'property unavailable' not in str(error):
                raise
            return default

    def panels():
        return sorted(k for k, p in PROPS.items() if get('user-data/' + p) not in [None, False, '', 'no'])

    def stats():
        return any(b.get('owner') == 'stats' and 'stats/__forced_' in b.get('cmd', '')
                   for b in get('input-bindings', []))

    def check(label, predicate, timeout=4):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                report['checks'].append(label)
                return
            time.sleep(.04)
        raise AssertionError((label, panels(), get('user-data/panel-manager/state')))

    def key(name):
        call('keypress', name)
        time.sleep(.15)

    def open_panel(name):
        call('script-message-to', 'panel_manager', 'open', name)
        check('exclusive ' + name, lambda: panels() == [name] and not stats())

    def shot(name):
        path = folder / (name + '.png')
        # The open property precedes uosc's fade-in and the next rendered frame.
        time.sleep(.8)
        call('screenshot-to-file', str(path), 'window')
        if not path.is_file() or path.stat().st_size < 1000:
            raise AssertionError('missing screenshot: ' + name)

    def no_hidden_keys(owners):
        return not any(b.get('owner') in owners and b.get('priority', -1) >= 0
                       and (b.get('key', '').upper() in ['ENTER', 'UP', 'DOWN', 'ESC'] or
                            '/search' in b.get('cmd', '') or '/list-search' in b.get('cmd', ''))
                       for b in get('input-bindings', []))

    with (folder / 'console.log').open('wb') as console:
        try:
            process = subprocess.Popen(command, cwd=ROOT, stdout=console, stderr=subprocess.STDOUT,
                                       creationflags=subprocess.CREATE_NO_WINDOW)
            for _ in range(150):
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
            time.sleep(.8)
            # The configured distinct filter excludes the current zero-time item.
            # Record another real file without reading or changing daily history.
            call('loadfile', str(second), 'replace')
            check('history fixture second file', lambda: get('path') == str(second))
            time.sleep(.3)
            call('script-message-to', 'simplebookmark', 'bookmark-fileonly')
            time.sleep(.15)
            call('loadfile', str(media), 'replace')
            check('history fixture first file', lambda: get('path') == str(media))
            time.sleep(.3)
            call('script-message-to', 'simplebookmark', 'bookmark-fileonly')

            # Reproduce the original symptom using the renderers' own entrypoints.
            call('script-message-to', 'simplehistory', 'open-list')
            check('history opens', lambda: panels() == ['history'])
            call('script-message-to', 'file_browser', 'browse-files')
            check('direct entrypoints exclude history', lambda: panels() == ['files'])
            check('history releases keys', lambda: no_hidden_keys({'simplehistory'}))
            key('ESC')
            check('file browser closes', lambda: not panels())

            key('i')
            check('temporary stats opens', stats)
            key('TAB')
            check('Tab cancels temporary stats', lambda: panels() == ['files'] and not stats())
            shot('files')
            key('`')
            check('backtick switches to history', lambda: panels() == ['history'] and not stats())
            check('file browser releases keys', lambda: no_hidden_keys({'file_browser'}))
            shot('history')
            key('Ctrl+f')
            check('history search is active', lambda: any(b.get('owner') == 'simplehistory'
                  and 'search_exit' in b.get('cmd', '') for b in get('input-bindings', [])))
            open_panel('files')
            check('history search releases keys', lambda: no_hidden_keys({'simplehistory'}))
            key('s')
            key('DOWN')
            open_panel('history')
            check('file selection releases keys', lambda: no_hidden_keys({'file_browser'}))
            key('ESC')
            check('search switch leaves no panel', lambda: not panels())

            key('I')
            check('persistent stats opens', stats)
            open_panel('history')
            key('TAB')
            check('stats stays suspended across switches', lambda: panels() == ['files'] and not stats())
            key('ESC')
            check('persistent stats resumes', lambda: not panels() and stats())
            key('ESC')
            check('stats Escape closes without revival', lambda: not stats())
            time.sleep(.25)
            if stats():
                raise AssertionError('stats revived after Escape')

            key('I')
            check('stats opens for binding search', stats)
            key('4')
            key('/')
            check('stats retains its own search box', lambda: panels() == ['console'] and stats())
            key('ESC')
            check('stats search closes', lambda: not panels() and stats())
            key('ESC')
            check('stats closes after search', lambda: not stats())

            key('~')
            check('tilde opens console', lambda: panels() == ['console'])
            key('i')
            key('TAB')
            check('console keeps text input', lambda: panels() == ['console'] and not stats())
            shot('console')
            open_panel('files')
            check('console releases keys', lambda: no_hidden_keys({'console'}))
            key('F4')
            check('F4 switches to main menu', lambda: panels() == ['menu'])
            shot('menu')
            open_panel('history')
            check('uosc releases keys', lambda: no_hidden_keys({'uosc'}))
            open_panel('bookmarks')
            key('Ctrl+f')
            check('bookmark search is active', lambda: any(b.get('owner') == 'simplebookmark'
                  and 'search_exit' in b.get('cmd', '') for b in get('input-bindings', [])))
            open_panel('console')
            check('bookmark search releases keys', lambda: no_hidden_keys({'simplebookmark'}))
            key('ESC')
            check('console closes normally', lambda: not panels())

            call('script-message-to', 'panel_manager', 'open', 'files')
            time.sleep(.06)
            call('script-message-to', 'panel_manager', 'open', 'history')
            call('script-message-to', 'panel_manager', 'open', 'console')
            check('rapid switches keep latest request', lambda: panels() == ['console'])
            time.sleep(.3)
            if panels() != ['console']:
                raise AssertionError('late panel acknowledgement replaced the latest request')
            key('ESC')
            check('rapid switch releases keys', lambda: not panels() and no_hidden_keys({'simplehistory', 'file_browser', 'console'}))

            open_panel('history')
            call('script-message-to', 'uosc', 'open-menu', json.dumps({
                'type': 'panel-regression', 'title': 'Panel regression',
                'items': [{'title': 'Close with Escape', 'value': 'ignore'}]}))
            check('external uosc menu excludes history', lambda: panels() == ['menu'])
            key('ESC')
            check('external menu closes', lambda: not panels())

            key('i')
            check('temporary stats opens again', stats)
            check('temporary stats expires', lambda: not stats(), timeout=6)
            open_panel('files')
            call('loadfile', str(second), 'append')
            call('playlist-next', 'force')
            check('next media initialized', lambda: get('path') == str(second) and get('video-params') is not None)
            # A browser may remain open across files; explicitly close its own binding.
            call('script-message-to', 'file_browser', 'close-browser')
            check('default restored after next file', lambda: not panels() and not stats())
            check('all modal keys released', lambda: no_hidden_keys({'simplehistory', 'simplebookmark', 'file_browser', 'console', 'stats', 'uosc'}))
            report['passed'] = True
        except Exception as error:
            report['error'] = repr(error)
        finally:
            if process is not None and process.poll() is None:
                if connection is not None:
                    try:
                        call('quit')
                    except (OSError, ValueError):
                        pass
                else:
                    process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
            if connection is not None:
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
