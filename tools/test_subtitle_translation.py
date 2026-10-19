"""Opt-in real translation API check; sends three fixed English cues, never private media text."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ai_subtitles import validate_timeline

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media', type=Path, required=True, help='Local playback fixture; its transcript is not uploaded')
    parser.add_argument('--timeout', type=int, default=120)
    parser.add_argument('--offline', action='store_true', help='Use local HTTP responses for display/regression diagnosis')
    parser.add_argument('--subtitles', type=Path, help='Explicit SRT to upload instead of the three fixed English cues')
    parser.add_argument('--target', choices=['Chinese', 'English'], default='Chinese')
    parser.add_argument('--reuse', type=Path, help='Reopen a previous test directory and require zero new API requests')
    args = parser.parse_args()
    if not args.media.is_file() or not 30 <= args.timeout <= 600:
        parser.error('existing media and timeout 30..600 required')
    if args.subtitles and (not args.subtitles.is_file() or args.offline):
        parser.error('--subtitles requires an existing SRT and cannot use --offline')
    if args.offline and (args.target != 'Chinese' or args.reuse):
        parser.error('--offline uses a fresh fixed English-to-Chinese fixture')
    local = ROOT / 'local.conf'
    settings = dict(api_key='offline-test', api_url='', api_mode='offline-test')
    if not args.offline:
        text = local.read_text(encoding='utf-8-sig')
        for name in ('api_key', 'api_url', 'api_mode'):
            match = re.findall(r'^\s*script-opts-append=sub_fastwhisper-' + name + r'=(.*)$', text, re.M)
            if not match or not match[-1].strip():
                parser.error('configure sub_fastwhisper-' + name + ' in ignored local.conf')
            settings[name] = match[-1].strip()
    folder = args.reuse.resolve() if args.reuse else ROOT / 'cache' / ('translation-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    if args.reuse and (not folder.is_dir() or not folder.is_relative_to(ROOT / 'cache')):
        parser.error('--reuse requires an existing directory inside this project cache')
    folder.mkdir(parents=True, exist_ok=bool(args.reuse))
    for stale in ('result.json', 'failure.json'):
        (folder / stale).unlink(missing_ok=True)
    fixture = folder / ('clip' + args.media.suffix)
    shutil.copy2(args.media, fixture)
    if args.subtitles:
        shutil.copy2(args.subtitles, folder / 'original.srt')
    command = [str(ROOT.parent / 'mpv.exe'), '--no-config', '--config-dir=' + str(ROOT),
               *([] if args.offline else ['--include=' + str(local)]),
               '--load-scripts=no', '--vo=gpu-next', '--gpu-api=d3d11',
               '--ao=null', '--pause=yes', '--idle=yes', '--osc=no', '--geometry=1280x720',
               '--resume-playback=no', '--save-position-on-quit=no', '--input-ipc-server=',
               '--term-status-msg=', '--msg-level=all=warn,sub_fastwhisper=info,test_subtitle_translation=info',
               '--script=' + str(ROOT / 'scripts/sub-fastwhisper.lua'),
               '--script=' + str(ROOT / 'tools/test_subtitle_translation.lua'),
               '--script-opts-append=sub_fastwhisper-output_path=' + (folder / 'results').as_posix(),
               '--script-opts-append=translation-test-root=' + folder.as_posix(),
               '--script-opts-append=translation-test-target=' + args.target,
               '--script-opts-append=translation-test-custom=' + ('yes' if args.subtitles else 'no'),
               '--script-opts-append=sub_fastwhisper-translate=' + args.target,
               '--script-opts-append=translation-test-timeout=' + str(args.timeout), str(fixture)]
    server = None
    if args.offline:
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *unused):
                pass

            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                response = {'choices': [{'message': {'content': '\n'.join([
                    '00:00:00,000 --> 00:00:02,000 | 请在下雨前关上窗户。',
                    '00:00:02,000 --> 00:00:04,000 | 火车将于明天早上七点半到达。',
                    '00:00:04,000 --> 00:00:06,000 | 所有生成的字幕必须保留在缓存文件夹中。'])}}]}
                body = json.dumps(response, ensure_ascii=False).encode('utf-8')
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        Thread(target=server.serve_forever, daemon=True).start()
        settings['api_url'] = 'http://127.0.0.1:' + str(server.server_port)
        command[-1:-1] = ['--script-opts-append=sub_fastwhisper-api_url=' + settings['api_url'],
                        '--script-opts-append=sub_fastwhisper-api_key=offline-test']
    # No verbose mpv log: option/subprocess debug records may contain credentials.
    process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               creationflags=subprocess.CREATE_NO_WINDOW)
    timed_out = False
    try:
        output, _ = process.communicate(timeout=args.timeout + 10)
    except subprocess.TimeoutExpired:
        timed_out = True
        subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True, timeout=10)
        output, _ = process.communicate(timeout=10)
    if server:
        server.shutdown()
        server.server_close()
    console = output.decode('utf-8', errors='replace').replace(settings['api_key'], '[redacted]')
    (folder / ('reuse-console.log' if args.reuse else 'console.log')).write_text(console, encoding='utf-8', newline='\n')
    result_path = folder / 'result.json'
    result = json.loads(result_path.read_text(encoding='utf-8')) if result_path.is_file() else {}
    translated = Path(result['translated']) if result.get('translated') else None
    timeline = validate_timeline(translated, 86400) if translated and translated.is_file() else {}
    reference = validate_timeline(folder / 'original.srt', 86400)
    request_count = console.count('AI subtitle translation in progress')
    png = folder / 'translated.png'
    passed = (process.returncode == 0 and not timed_out and result.get('passed') and timeline.get('passed')
              and reference.get('passed') and len(timeline.get('cues', [])) == len(reference['cues'])
              and request_count == (0 if args.reuse else (len(reference['cues']) + 19) // 20) and png.is_file()
              and png.stat().st_size > 1024 and 'TRANSLATION PLAYBACK FAIL:' not in console)
    if passed:
        passed = all(cue['start'] == original['start'] and cue['end'] == original['end']
                     for cue, original in zip(timeline['cues'], reference['cues']))
    report = dict(passed=bool(passed), exit_code=process.returncode, timed_out=timed_out,
                  model=settings['api_mode'], endpoint=settings['api_url'], api_requests=request_count,
                  real_api=not args.offline,
                  reused=bool(args.reuse),
                  target=args.target, reference=reference,
                  result=result, timeline=timeline)
    report_path = folder / ('reuse-report.json' if args.reuse else 'report.json')
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(('PASS: ' if passed else 'FAIL: ') + str(report_path))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
