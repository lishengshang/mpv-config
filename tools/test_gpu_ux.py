"""Windows GPU UX regression with logs, exit codes and real PNG evidence.

--case playback covers all RTX menu presets; no-vs uses an isolated mpv binary;
failure uses an isolated broken preset to exercise mpv's actual rollback.
All fixtures/reports stay in ignored cache. No runtime or original preset edits.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import zlib

CONFIG = Path(__file__).resolve().parents[1]


def inspect_testsrc_png(data):
    """Require colored testsrc pixels; a valid PNG can still be a VS dummy frame.

    Sample the first 32 rows, where this suite's unletterboxed color bars live.
    Decode RGB/RGBA 8/16-bit PNG with stdlib only, ignoring alpha for the check.
    """
    try:
        if data[:8] != b'\x89PNG\r\n\x1a\n':
            raise ValueError('not PNG')
        offset, compressed, header, ended = 8, [], None, False
        while offset < len(data):
            size = struct.unpack_from('>I', data, offset)[0]
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + size]
            crc = struct.unpack_from('>I', data, offset + 8 + size)[0]
            if zlib.crc32(kind + payload) != crc:
                raise ValueError('PNG CRC mismatch')
            if kind == b'IHDR':
                header = struct.unpack('>IIBBBBB', payload)
            elif kind == b'IDAT':
                compressed.append(payload)
            elif kind == b'IEND':
                ended = True
                break
            offset += size + 12
        if not header or not ended:
            raise ValueError('incomplete PNG')
        width, height, depth, color, compression, filtering, interlace = header
        if (not 0 < width <= 8192 or not 0 < height <= 8192 or depth not in (8, 16) or
                color not in (2, 6) or compression or filtering or interlace):
            raise ValueError('unsupported PNG layout')
        channels, sample_bytes = (3 if color == 2 else 4), depth // 8
        pixel_bytes = channels * sample_bytes
        stride, rows = width * pixel_bytes, min(height, 32)
        raw = zlib.decompressobj().decompress(b''.join(compressed), (stride + 1) * rows)
        if len(raw) != (stride + 1) * rows:
            raise ValueError('truncated PNG pixels')
        previous, colorful = bytearray(stride), 0
        for row in range(rows):
            start = row * (stride + 1)
            mode, decoded = raw[start], bytearray(raw[start + 1:start + 1 + stride])
            if mode not in range(5):
                raise ValueError('invalid PNG row filter')
            if mode:
                for i in range(stride):
                    left = decoded[i - pixel_bytes] if i >= pixel_bytes else 0
                    up = previous[i]
                    upper_left = previous[i - pixel_bytes] if i >= pixel_bytes else 0
                    if mode == 1:
                        prediction = left
                    elif mode == 2:
                        prediction = up
                    elif mode == 3:
                        prediction = (left + up) // 2
                    else:
                        p = left + up - upper_left
                        distances = (abs(p - left), abs(p - up), abs(p - upper_left))
                        prediction = (left, up, upper_left)[distances.index(min(distances))]
                    decoded[i] = (decoded[i] + prediction) & 255
            for i in range(0, stride, pixel_bytes):
                rgb = decoded[i:i + 3 * sample_bytes:sample_bytes]
                colorful += max(rgb) - min(rgb) > 32
            previous = decoded
        fraction = colorful / (width * rows)
        return dict(valid=fraction > 0.05, width=width, height=height,
                    colorful_fraction=round(fraction, 4))
    except (ValueError, struct.error, zlib.error, IndexError) as exc:
        return dict(valid=False, reason=str(exc))


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=['playback', 'no-vs', 'failure'], default='playback')
    parser.add_argument('--paused', action='store_true', help='Switch filters while playback is paused')
    parser.add_argument('--launcher', type=Path, help='Use the installed component CMD launcher from the test working directory')
    parser.add_argument('--focused', action='store_true', help='RIFE/DRBA/ArtCNN shape regression without shader compilation')
    parser.add_argument('--source-width', type=int, choices=[640, 1280], default=1280,
                        help='640 exercises 2x shader rendering and may build new TRT engines')
    cache_options = parser.add_mutually_exclusive_group()
    cache_options.add_argument('--cold-shader-cache', action='store_true', help='Use a new shader cache inside this report directory')
    cache_options.add_argument('--shader-cache-dir', type=Path, help='Reuse an explicit cache for a warm follow-up run')
    parser.add_argument('--timeout', type=int, default=960, help='Overall native process timeout in seconds')
    options = parser.parse_args()
    if options.launcher and (options.case != 'playback' or not options.launcher.is_file()):
        parser.error('--launcher requires playback and an existing CMD launcher')
    if options.focused and options.case != 'playback':
        parser.error('--focused requires --case playback')
    if options.timeout < 60:
        parser.error('--timeout must be at least 60 seconds')
    folder = CONFIG / 'cache' / 'gpu-ux' / (datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + options.case +
                                         ('-paused' if options.paused else '') + ('-focused' if options.focused else '') + '-' + str(options.source_width))
    folder.mkdir(parents=True)
    if options.shader_cache_dir:
        shader_cache = options.shader_cache_dir.resolve()
    else:
        shader_cache = folder / 'shader-cache' if options.cold_shader_cache else CONFIG / 'cache/shaders_cache'
    shader_cache.mkdir(parents=True, exist_ok=True)
    mpv_root, config = CONFIG.parent, CONFIG
    if options.case == 'no-vs':
        mpv_root = folder / 'mpv-no-vs'
        mpv_root.mkdir()
        shutil.copy2(CONFIG.parent / 'mpv.exe', mpv_root / 'mpv.exe')
    elif options.case == 'failure':
        config = folder / 'portable_config'
        for part in ['scripts/uosc', 'shaders/ArtCNN']:
            shutil.copytree(CONFIG / part, config / part)
        for part in ['scripts/gpu-effects.lua', 'tools/gpu_probe.py', 'input.conf']:
            (config / part).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(CONFIG / part, config / part)
        (config / 'vs').mkdir()
        shutil.copy2(CONFIG / 'vs/NR_BILATERAL_CUDA.vpy', config / 'vs/NR_BILATERAL_CUDA.vpy')
        (config / 'vs/NR_DFTTEST_CUDA.vpy').write_text(
            'import k7sfunc\nraise RuntimeError("UX deliberate initialization failure")\n',
            encoding='utf-8', newline='\n')
        (config / 'vs/SR_HFA2k_TRT.vpy').write_text(
            'import k7sfunc as k7f\nclip = k7f.UAI_NV_TRT(video_in, model_pth="UX_missing_model.onnx")\n',
            encoding='utf-8', newline='\n')
    log = folder / 'player.log'
    opts = [f'ux-test-output={folder.as_posix()}', f'gpu-effects-runtime_path={mpv_root.as_posix()}']
    opts.append(f'ux-test-timeout={options.timeout - 30}')
    opts.append('ux-test-paused=' + ('yes' if options.paused else 'no'))
    opts.append({'playback': 'ux-test-all_rtx=yes', 'no-vs': 'ux-test-no_vs=yes',
                 'failure': 'ux-test-failure=yes'}[options.case])
    if options.focused:
        opts.append('ux-test-focused=yes')
    args = [str(mpv_root / 'mpv.exe'), '--no-config', f'--config-dir={config}', '--load-scripts=no',
            f'--script={config / "scripts/uosc"}', f'--script={config / "scripts/gpu-effects.lua"}',
            f'--script={CONFIG / "tools/test_gpu_effects_playback.lua"}', f'--input-conf={config / "input.conf"}',
            '--vo=gpu-next', '--gpu-api=d3d11', '--ao=null', '--hwdec=no', '--osc=no', '--idle=yes',
            '--resume-playback=no', '--save-position-on-quit=no', '--term-status-msg=',
            f'--osd-fonts-dir={CONFIG / "fonts"}',
            '--geometry=1280x720',
            f'--gpu-shader-cache-dir={shader_cache}',
            '--script-opts=' + ','.join(opts), f'--log-file={log}',
            f'av://lavfi:testsrc2=size={options.source_width}x{options.source_width * 9 // 16}:rate=30,format=yuv420p']
    if options.paused:
        args.insert(1, '--pause=yes')
    if options.launcher:
        forwarded = [str(options.launcher.resolve()), *args[1:]]
        if any(any(c in value for c in '"%\r\n') for value in forwarded):
            parser.error('CMD launcher test paths cannot contain quotes, percent signs or newlines')
        quoted = [subprocess.list2cmdline([value]) for value in forwarded]
        line = ' '.join(value if value.startswith('"') else '"' + value + '"' for value in quoted)
        # Pass CMD its raw /c line; list2cmdline on the whole line would insert
        # backslash-escaped quotes, which CMD does not treat as quoting.
        args = subprocess.list2cmdline([os.environ.get('COMSPEC', 'cmd.exe'), '/d', '/v:off', '/s', '/c']) + ' "' + line + '"'
    timed_out = False
    with (folder / 'console.log').open('wb') as console:
        # --no-config makes ~~ paths relative; run inside the selected fixture.
        proc = subprocess.Popen(args, stdout=console, stderr=subprocess.STDOUT, cwd=config,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0) if options.launcher else 0)
        try:
            code = proc.wait(timeout=options.timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True, timeout=10)
            code = proc.wait(timeout=10)
    content = log.read_text(encoding='utf-8', errors='replace') if log.exists() else ''
    expected = ['menu', 'light', 'next-file', 'shader-next-file']
    if options.case == 'playback':
        expected += ['bilateral', 'dfttest', 'rife', 'balanced', 'MEMC_DRBA_TRT', 'NR_BM3D_CUDA',
                     'SR_ARTCNN_TRT', 'SR_ARTCNN_CHROMA_TRT', 'SR_AnimeJaNaiV2_TRT',
                     'SR_AnimeJaNaiV3_TRT', 'SR_HFA2k_TRT', 'SR_Anime1080Fixer_TRT', 'MIX_SR_MEMC_TRT']
        if options.focused:
            expected = ['menu', 'MEMC_RIFE_TRT', 'MEMC_DRBA_TRT', 'SR_ARTCNN_TRT', 'SR_ARTCNN_CHROMA_TRT',
                        'MIX_SR_MEMC_TRT', 'next-file']
        elif options.paused:
            expected.append('MIX-before-paused-seek')
    elif options.case == 'no-vs':
        expected += ['no-vs-still-playing']
    else:
        expected += ['init-failure-preserved-light', 'missing-model-preserved-light', 'init-failure-preserved-vs']
    frames = []
    for name in expected:
        path = folder / (name + '.png')
        data = path.read_bytes() if path.exists() else b''
        frame = inspect_testsrc_png(data)
        frame['valid'] = frame['valid'] and len(data) > 1024
        frames.append(dict(name=name, **frame))
    # Expected fault case may log a VS error, but must still emit the success marker and output.
    passed = (not timed_out and code == 0 and 'GPU UX PLAYBACK PASS:' in content
              and 'GPU UX PLAYBACK FAIL:' not in content and all(f['valid'] for f in frames))
    if options.case == 'playback' and not options.focused:
        passed = passed and all('ArtCNN ' + model + ' (Conv2D)' in content for model in ['C4F16', 'C4F32'])
    report = dict(case=options.case, paused=options.paused, focused=options.focused, source_width=options.source_width,
                  launcher=str(options.launcher.resolve()) if options.launcher else None,
                  cold_shader_cache=options.cold_shader_cache, shader_cache=str(shader_cache),
                  passed=passed, exit_code=code, timed_out=timed_out,
                  log=str(log), frames=frames, command=args)
    (folder / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(('PASS' if passed else 'FAIL') + ' ' + options.case + ': ' + str(folder / 'report.json'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
