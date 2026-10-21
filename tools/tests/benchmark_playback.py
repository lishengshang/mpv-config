"""Measure a fixed local clip/current preset; synthetic inputs are labeled explicitly."""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media', type=Path, help='Use the same real clip and --start for preset comparisons')
    parser.add_argument('--start', type=float, default=0)
    parser.add_argument('--seconds', type=float, default=30)
    parser.add_argument('--warmup', type=float, default=2)
    parser.add_argument('--preset', default='none', help='GPU menu preset ID, or none; may compile TRT/shaders')
    parser.add_argument('--height', type=int, choices=[720, 1080, 2160], default=720, help='Synthetic source height')
    parser.add_argument('--minimal', action='store_true', help='Skip root options; still load GPU controller and sampler')
    args = parser.parse_args()
    if not all(math.isfinite(v) for v in (args.seconds, args.start, args.warmup)) or not 2 <= args.seconds <= 120 or args.start < 0 or not 0 <= args.warmup <= 30:
        parser.error('seconds must be 2..120, start >= 0, warmup 0..30')
    presets = re.findall(r"^preset\('([^']+)'", (ROOT / 'scripts/gpu-effects.lua').read_text(encoding='utf-8'), re.M)
    if args.preset != 'none' and args.preset not in presets:
        parser.error('unknown GPU preset: ' + args.preset)
    if args.media and not args.media.is_file():
        parser.error('local media file missing')
    folder = ROOT / 'cache/player-health' / ('benchmark-' + datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
    folder.mkdir(parents=True)
    source = str(args.media.resolve()) if args.media else f'av://lavfi:testsrc2=size={args.height * 16 // 9}x{args.height}:rate=30,format=yuv420p'
    command = [str(ROOT.parent / 'mpv.exe'), *(['--no-config'] if args.minimal else []), '--config-dir=' + str(ROOT),
               '--load-scripts=no', '--script=' + str(ROOT / 'scripts/gpu-effects.lua'),
               '--script=' + str(ROOT / 'scripts/player-health.lua'), '--script=' + str(ROOT / 'tools/tests/benchmark_playback.lua'),
               '--vo=gpu-next', '--gpu-api=d3d11', '--ao=null', '--osc=no', '--idle=yes', '--keep-open=yes',
               '--pause=no', '--speed=1', '--resume-playback=no', '--save-position-on-quit=no', '--input-ipc-server=',
               '--geometry=1280x720', '--autofit=', '--autofit-larger=', '--autofit-smaller=', '--loop-file=no',
               '--start=' + str(args.start), '--log-file=' + str(folder / 'player.log'), '--term-status-msg=',
               '--script-opts-append=benchmark-seconds=' + str(args.seconds),
               '--script-opts-append=benchmark-seek=' + ('yes' if args.media else 'no'),
               '--script-opts-append=benchmark-start=' + str(args.start),
               '--script-opts-append=benchmark-preset=' + args.preset,
               '--script-opts-append=benchmark-output=' + folder.as_posix(),
               '--script-opts-append=player-health-warmup_seconds=' + str(args.warmup), source]
    with (folder / 'console.log').open('wb') as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = process.wait(timeout=510)
        except subprocess.TimeoutExpired:
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True, timeout=10)
            code = process.wait(timeout=10)
    result_file = folder / 'result.json'
    result = json.loads(result_file.read_text(encoding='utf-8')) if result_file.is_file() else {}
    sample_file = Path(result['report']) if result.get('report') else None
    sample = json.loads(sample_file.read_text(encoding='utf-8')) if sample_file and sample_file.is_file() else {}
    png = (folder / 'output.png').read_bytes() if (folder / 'output.png').is_file() else b''
    log_file = folder / 'player.log'
    log = log_file.read_text(encoding='utf-8', errors='replace') if log_file.is_file() else ''
    passed = (code == 0 and 'BENCHMARK PASS:' in log and 'BENCHMARK FAIL:' not in log and sample.get('valid')
              and sample.get('elapsed', 0) >= args.seconds and len(png) > 1024 and png[:8] == b'\x89PNG\r\n\x1a\n')
    report = dict(passed=bool(passed), exit_code=code, source_kind='local file' if args.media else 'synthetic testsrc2',
                  source=source, preset=args.preset, sample=sample, log=str(folder / 'player.log'))
    (folder / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(('PASS: ' if passed else 'FAIL: ') + str(folder / 'report.json'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
