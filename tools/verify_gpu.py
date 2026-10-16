"""mpv integration checks: real output, exit status, errors and timeout.
Uses upstream portable Python; no extra pip dependencies. Reports are local cache.
This proves initialization/output, not subjective quality or realtime speed.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

CONFIG = Path(__file__).resolve().parents[1]
ERRORS = re.compile(
    r'Python exception|Traceback|could not init VS|Disabling filter|'
    r'Failed to (?:initialize|load|compile)|Error (?:compiling|parsing)|'
    r'Could not load|CUDA_ERROR|driver version is insufficient|'
    r'Cannot load|no such file|FileNotFoundError', re.I)


def png_valid(path):
    return path.is_file() and path.stat().st_size > 32 and path.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n'


def evaluate(returncode, log, frames, timed_out=False, required=3):
    if timed_out:
        return False, 'timeout'
    if returncode != 0:
        return False, f'exit={returncode}'
    if not log:
        return False, 'missing/empty log'
    match = ERRORS.search(log)
    if match:
        return False, 'log error: ' + match.group(0)
    if len(frames) < required or not all(png_valid(p) for p in frames):
        return False, 'missing/invalid output frames'
    return True, f'{len(frames)} real PNG frames'


def run_check(mpv, path, kind, folder, timeout, source_width=1280):
    folder.mkdir(parents=True)
    log_path = folder / 'mpv.log'
    args = [str(mpv), '--no-config', '--load-scripts=no', '--audio=no', '--hwdec=no',
            '--idle=no', '--keep-open=no', '--untimed', '--frames=3',
            '--msg-level=all=v', '--log-file=' + str(log_path)]
    if kind == 'vs':
        args += ['--vo=image', '--vo-image-format=png', '--vo-image-outdir=' + str(folder),
                 '--vf=vapoursynth=file="' + path.as_posix() + '"']
        source = f'av://lavfi:testsrc2=size={source_width}x{source_width * 9 // 16}:rate=30,format=yuv420p'
    else:
        # image VO bypasses GLSL. Capture the actual gpu-next window at 2x size.
        lua = folder / 'capture.lua'
        target = json.dumps(str(folder / 'render.png').replace('\\', '/'))
        lua.write_text('mp.register_event("playback-restart", function()\n'
                       f'  mp.commandv("screenshot-to-file", {target}, "window")\n'
                       'end)\n', encoding='utf-8')
        args += ['--script=' + str(lua), '--vo=gpu-next', '--gpu-api=d3d11',
                 '--geometry=1280x720', '--autofit=', '--autofit-larger=',
                 '--autofit-smaller=', '--keepaspect-window=no',
                 '--glsl-shaders=' + str(path)]
        source = 'av://lavfi:testsrc2=size=640x360:rate=30,format=yuv420p'
    args.append(source)
    started = time.monotonic()
    timed_out = False
    proc = subprocess.Popen(args, cwd=mpv.parent, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    try:
        console, _ = proc.communicate(timeout=timeout)
        code = proc.returncode
    except subprocess.TimeoutExpired:
        code, timed_out = None, True
        # mpv.com is a wrapper around mpv.exe; kill its tree, not only the wrapper.
        if os.name == 'nt':
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        else:
            proc.kill()
        console, _ = proc.communicate(timeout=10)
    (folder / 'console.log').write_bytes(console)
    log = log_path.read_text(encoding='utf-8', errors='replace') if log_path.exists() else ''
    frames = sorted(folder.glob('*.png'))
    passed, reason = evaluate(code, log, frames, timed_out, 3 if kind == 'vs' else 1)
    if passed and kind == 'shader':
        data = frames[0].read_bytes()
        size = (int.from_bytes(data[16:20], 'big'), int.from_bytes(data[20:24], 'big'))
        model = path.stem.removeprefix('ArtCNN_')
        if size != (1280, 720) or f'Registering hook pass: ArtCNN {model} (Conv2D)' not in log:
            passed, reason = False, 'shader execution / 2x screenshot not confirmed'
        else:
            reason = 'GPU screenshot 1280x720 + ArtCNN execution log'
    return dict(preset=path.stem, kind=kind, passed=passed, reason=reason,
                seconds=round(time.monotonic() - started, 2), exit_code=code,
                command=args, log=str(log_path), frames=[str(p) for p in frames])


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mpv-root', type=Path, default=CONFIG.parent)
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--kind', choices=['vs', 'shader', 'all'], default='all')
    parser.add_argument('--preset', help='Exact stem, e.g. NR_BILATERAL_CUDA')
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--source-width', type=int, choices=[640, 1280], default=1280,
                        help='VS input size; 640 exercises inputs below dynamic TRT minimum shapes')
    options = parser.parse_args()
    if options.timeout < 1:
        parser.error('--timeout must be positive')
    root = options.mpv_root.resolve()
    mpv = next((root / name for name in ['mpv.com', 'mpv.exe'] if (root / name).exists()), None)
    if not mpv:
        print('FAIL: mpv.com/mpv.exe missing at', root)
        return 2
    folder = CONFIG / 'cache' / 'gpu-check' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    folder.mkdir(parents=True)
    report = dict(date=datetime.now().astimezone().isoformat(), mpv_root=str(root), checks=[], results=[])
    version = subprocess.run([str(mpv), '--no-config', '--version'], capture_output=True, timeout=20)
    report['mpv'] = version.stdout.decode('utf-8', errors='replace')
    print(report['mpv'].splitlines()[0] if report['mpv'] else 'mpv version unavailable')
    try:
        gpu = subprocess.run(['nvidia-smi', '--query-gpu=name,driver_version,memory.total',
                              '--format=csv,noheader'], capture_output=True, timeout=20)
        report['gpu'] = gpu.stdout.decode('utf-8', errors='replace').strip()
        print(report['gpu'] or 'GPU information unavailable')
    except (OSError, subprocess.TimeoutExpired):
        report['gpu'] = 'nvidia-smi unavailable (does not prove GPU absence)'
    paths = []
    if options.kind in ('vs', 'all'):
        paths += [(p, 'vs') for p in sorted((CONFIG / 'vs').glob('*.vpy'))
                  if p.stem.endswith(('_TRT', '_CUDA'))]
        for name in ['python.exe', 'VSScript.dll', 'portable.vs', 'Lib', 'vs-plugins']:
            ok = (root / name).exists()
            report['checks'].append(dict(name=name, passed=ok))
            print(('OK   ' if ok else 'FAIL ') + name)
        probe = 'import importlib.metadata as m; import vapoursynth as vs; import k7sfunc; print(m.version("k7sfunc")); print(str(vs.core)); print([(p.identifier,p.namespace) for p in vs.core.plugins()])'
        try:
            proc = subprocess.run([str(root / 'python.exe'), '-c', probe], cwd=root,
                                  capture_output=True, timeout=30)
            report['runtime'] = (proc.stdout + proc.stderr).decode('utf-8', errors='replace')
            report['checks'].append(dict(name='VS/k7sfunc import', passed=proc.returncode == 0))
            print('VS/k7sfunc import:', 'OK' if proc.returncode == 0 else 'FAIL (see report)')
        except (OSError, subprocess.TimeoutExpired) as exc:
            report['checks'].append(dict(name='VS/k7sfunc import', passed=False))
            report['runtime'] = str(exc)
    if options.kind in ('shader', 'all'):
        paths += [(p, 'shader') for p in sorted((CONFIG / 'shaders' / 'ArtCNN').glob('*.glsl'))]
    if options.preset:
        paths = [(p, kind) for p, kind in paths if p.stem == options.preset]
    if not paths:
        print('FAIL: no matching presets')
        return 2
    for path, kind in paths:
        if options.run:
            try:
                result = run_check(mpv, path, kind, folder / path.stem, options.timeout, options.source_width)
            except OSError as exc:
                result = dict(preset=path.stem, kind=kind, passed=False, reason=str(exc))
            report['results'].append(result)
            print(('PASS ' if result['passed'] else 'FAIL ') + path.stem + ': ' + result['reason'], flush=True)
        else:
            print('FOUND', path.relative_to(CONFIG))
    report_path = folder / 'report.json'
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Report:', report_path)
    if not options.run:
        print('Inspection only. Use -Run for actual GPU output checks.')
    return 0 if all(c['passed'] for c in report['checks'] + report['results']) else 1


if __name__ == '__main__':
    sys.exit(main())
