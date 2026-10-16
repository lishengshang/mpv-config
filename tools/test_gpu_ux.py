"""Windows GPU UX regression with logs, exit codes and real PNG evidence.

--case playback covers all RTX menu presets; no-vs uses an isolated mpv binary;
failure uses an isolated broken preset to exercise mpv's actual rollback.
All fixtures/reports stay in ignored cache. No runtime or original preset edits.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
import subprocess
import sys

CONFIG = Path(__file__).resolve().parents[1]


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', choices=['playback', 'no-vs', 'failure'], default='playback')
    parser.add_argument('--paused', action='store_true', help='Switch filters while playback is paused')
    parser.add_argument('--focused', action='store_true', help='RIFE/DRBA/ArtCNN shape regression without shader compilation')
    parser.add_argument('--source-width', type=int, choices=[640, 1280], default=1280,
                        help='640 exercises 2x shader rendering and may build new TRT engines')
    options = parser.parse_args()
    if options.focused and options.case != 'playback':
        parser.error('--focused requires --case playback')
    folder = CONFIG / 'cache' / 'gpu-ux' / (datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + options.case +
                                         ('-paused' if options.paused else '') + ('-focused' if options.focused else '') + '-' + str(options.source_width))
    folder.mkdir(parents=True)
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
            f'--gpu-shader-cache-dir={CONFIG / "cache/shaders_cache"}',
            '--script-opts=' + ','.join(opts), f'--log-file={log}',
            f'av://lavfi:testsrc2=size={options.source_width}x{options.source_width * 9 // 16}:rate=30,format=yuv420p']
    if options.paused:
        args.insert(1, '--pause=yes')
    timed_out = False
    with (folder / 'console.log').open('wb') as console:
        # --no-config makes ~~ paths relative; run inside the selected fixture.
        proc = subprocess.Popen(args, stdout=console, stderr=subprocess.STDOUT, cwd=config)
        try:
            code = proc.wait(timeout=960)
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
    elif options.case == 'no-vs':
        expected += ['no-vs-still-playing']
    else:
        expected += ['init-failure-preserved-light', 'missing-model-preserved-light', 'init-failure-preserved-vs']
    frames = []
    for name in expected:
        path = folder / (name + '.png')
        data = path.read_bytes() if path.exists() else b''
        valid = len(data) > 1024 and data[:8] == b'\x89PNG\r\n\x1a\n'
        frames.append(dict(name=name, valid=valid,
                           width=int.from_bytes(data[16:20], 'big'), height=int.from_bytes(data[20:24], 'big')))
    # Expected fault case may log a VS error, but must still emit the success marker and output.
    passed = (not timed_out and code == 0 and 'GPU UX PLAYBACK PASS:' in content
              and 'GPU UX PLAYBACK FAIL:' not in content and all(f['valid'] for f in frames))
    if options.case == 'playback' and not options.focused:
        passed = passed and all('ArtCNN ' + model + ' (Conv2D)' in content for model in ['C4F16', 'C4F32'])
    report = dict(case=options.case, paused=options.paused, focused=options.focused, source_width=options.source_width,
                  passed=passed, exit_code=code, timed_out=timed_out,
                  log=str(log), frames=frames, command=args)
    (folder / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(('PASS' if passed else 'FAIL') + ' ' + options.case + ': ' + str(folder / 'report.json'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
