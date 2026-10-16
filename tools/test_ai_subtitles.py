"""Run real mpv with Whisper or Qwen CUDA against local synthetic speech."""
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
import time

CONFIG = Path(__file__).resolve().parents[1]


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', type=Path)
    parser.add_argument('--engine', choices=['whisper', 'qwen'], default='whisper')
    parser.add_argument('--menu-switch', action='store_true', help='Select Qwen through actual uosc key routing and restore Whisper')
    parser.add_argument('--full-config', action='store_true', help='Load actual root configuration with only the two test scripts')
    args = parser.parse_args()
    if args.menu_switch and args.engine != 'qwen':
        parser.error('--menu-switch requires --engine qwen')
    local = (CONFIG / 'local.conf').read_text(encoding='utf-8')
    qwen_opts = []
    if args.engine == 'qwen':
        for key in ('qwen_python', 'qwen_model', 'qwen_aligner'):
            match = re.search(r'^\s*script-opts-append=sub_fastwhisper-' + key + '=(.+)$', local, re.M)
            if not match:
                raise SystemExit('FAIL: local Qwen setting missing: ' + key)
            qwen_opts.append('sub_fastwhisper-' + key + '=' + match[1].strip())
    backend = args.backend
    if backend is None:
        match = re.search(r'^\s*script-opts-append=sub_fastwhisper-fast_whisper_path=(.+)$', local, re.M)
        if not match:
            raise SystemExit('FAIL: provide --backend or configure local backend path')
        backend = Path(match[1].strip())
    if not backend.is_file():
        raise SystemExit('FAIL: installed backend missing')
    ffmpeg = shutil.which('ffmpeg')
    if ffmpeg is None:
        raise SystemExit('FAIL: ffmpeg missing')
    folder = CONFIG / 'cache' / ('asr-playback-' + time.strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(parents=True)
    speech = folder / 'speech.wav'
    synth = (
        'Add-Type -AssemblyName System.Speech; '
        '$asrSynth = [System.Speech.Synthesis.SpeechSynthesizer]::new(); '
        "$asrSynth.SelectVoice('Microsoft Zira Desktop'); "
        '$asrSynth.SetOutputToWaveFile(' + ps_quote(speech) + '); '
        "$asrSynth.Speak('This is a local subtitle cache test. The subtitles should stay in the cache folder.'); "
        '$asrSynth.Dispose()'
    )
    subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', synth], check=True, timeout=30)
    first, second = folder / 'A' / 'clip.mkv', folder / 'B' / 'clip.mkv'
    first.parent.mkdir()
    second.parent.mkdir()
    subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                    'testsrc2=size=320x180:rate=24', '-i', str(speech), '-c:v', 'libx264',
                    '-preset', 'ultrafast', '-c:a', 'aac', '-shortest', str(first)], check=True, timeout=30)
    shutil.copy2(first, second)
    before = {str(p.parent): sorted(x.name for x in p.parent.iterdir()) for p in (first, second)}
    mock_args = [str(CONFIG.parent / 'mpv.exe'), '--no-config', '--config-dir=' + str(CONFIG),
                 '--load-scripts=no', '--idle=yes', '--vo=null', '--ao=null', '--term-status-msg=',
                 '--script=' + str(CONFIG / 'tools/test_ai_subtitles.lua'),
                 '--script-opts=asr-test-root=' + folder.as_posix() +
                 ',asr-test-script=' + (CONFIG / 'scripts/sub-fastwhisper.lua').as_posix()]
    # Mock regression uses the same media identities but a separate result directory.
    with (folder / 'mock.log').open('wb') as log:
        mock = subprocess.run(mock_args, cwd=CONFIG, stdout=log, stderr=subprocess.STDOUT, timeout=30)
    mock_log = (folder / 'mock.log').read_text(encoding='utf-8', errors='replace')
    if mock.returncode != 0 or 'ASR CACHE MOCK PASS:' not in mock_log:
        raise SystemExit('FAIL: mock regression; see ' + str(folder / 'mock.log'))
    # Fresh root separates synthetic mock results from real backend output.
    real_root = folder / 'real'
    real_root.mkdir()
    opts = ['sub_fastwhisper-fast_whisper_path=' + backend.as_posix(),
            'sub_fastwhisper-backend=' + ('whisper' if args.menu_switch else args.engine),
            'sub_fastwhisper-model=large-v3-turbo', 'sub_fastwhisper-device=cuda',
            'sub_fastwhisper-compute_type=float16', 'sub_fastwhisper-language=en',
            'sub_fastwhisper-api_key=', 'sub_fastwhisper-output_path=' + (real_root / 'results').as_posix(),
            'asr-playback-root=' + real_root.as_posix(), 'asr-playback-first=' + first.as_posix(),
            'asr-playback-second=' + second.as_posix()]
    opts.extend(qwen_opts)
    opts.append('asr-playback-timeout=600')
    if args.menu_switch:
        opts.append('asr-playback-menu_switch=yes')
    log_path = folder / 'player.log'
    command = [str(CONFIG.parent / 'mpv.exe'), '--no-config', '--config-dir=' + str(CONFIG),
               '--load-scripts=no', '--script=' + str(CONFIG / 'scripts/sub-fastwhisper.lua'),
               '--script=' + str(CONFIG / 'tools/test_ai_subtitles_playback.lua'),
               '--input-conf=' + str(CONFIG / 'input.conf'), '--script-opts=' + ','.join(opts),
               '--vo=null', '--ao=null', '--pause=yes', '--idle=yes', '--keep-open=yes',
               '--save-position-on-quit=no', '--resume-playback=no', '--term-status-msg=',
               '--log-file=' + str(log_path), str(first)]
    if args.full_config:
        command.remove('--no-config')
        command.insert(1, '--msg-level=all=warn,sub_fastwhisper=info,test_ai_subtitles_playback=info')
    if args.menu_switch:
        command.insert(1, '--script=' + str(CONFIG / 'scripts/uosc'))
    timed_out = False
    with (folder / 'console.log').open('wb') as console:
        proc = subprocess.Popen(command, cwd=CONFIG, stdout=console, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = proc.wait(timeout=630)
        except subprocess.TimeoutExpired:
            timed_out = True
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True, timeout=10)
            code = proc.wait(timeout=10)
    log = log_path.read_text(encoding='utf-8', errors='replace') if log_path.is_file() else ''
    after = {str(p.parent): sorted(x.name for x in p.parent.iterdir()) for p in (first, second)}
    result_path = real_root / 'playback.json'
    result = json.loads(result_path.read_text(encoding='utf-8')) if result_path.is_file() else {}
    outputs = [Path(result[key]) for key in ('first', 'second') if key in result]
    text_valid = len(outputs) == 2 and all(
        'cache' in p.read_text(encoding='utf-8').lower() and '-->' in p.read_text(encoding='utf-8') for p in outputs)
    passed = (code == 0 and not timed_out and before == after and text_valid
              and 'ASR CACHE PLAYBACK PASS:' in log and 'ASR CACHE PLAYBACK FAIL:' not in log
              and 'Lua error' not in log and log.count('AI subtitle cache completed:') == 2
              and log.count('AI subtitle cache reused:') >= 2)
    if args.engine == 'qwen':
        passed = passed and log.count('QWEN_ASR_OK ') == 2 and result.get('menu_switch', False) == args.menu_switch
    report = dict(passed=passed, exit_code=code, timed_out=timed_out, source_folders_unchanged=before == after,
                  valid_outputs=text_valid, completed_jobs=log.count('AI subtitle cache completed:'),
                  reuse_events=log.count('AI subtitle cache reused:'), engine=args.engine,
                  model='Qwen3-ASR-1.7B' if args.engine == 'qwen' else 'large-v3-turbo',
                  device='cuda', precision='bfloat16' if args.engine == 'qwen' else 'float16',
                  media='320x180/24fps H.264 + AAC, synthetic English speech',
                  mock_passed=True, outputs=[str(p) for p in outputs], log=str(log_path))
    report['full_root_config'] = args.full_config
    report['menu_switch'] = args.menu_switch
    (folder / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(('PASS' if passed else 'FAIL') + ': ' + str(folder / 'report.json'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
