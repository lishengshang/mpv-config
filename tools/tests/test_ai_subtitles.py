"""Run real mpv with Whisper or Qwen CUDA against synthetic speech or local media."""
from pathlib import Path
import argparse
import difflib
import hashlib
import json
import re
import shutil
import subprocess
import time

CONFIG = Path(__file__).resolve().parents[2]
SHORT_SPEECH = 'This is a local subtitle cache test. The subtitles should stay in the cache folder.'
LONG_SPEECH = (
    'This is a local subtitle cache test. The first sentence describes a quiet morning. '
    'A small blue bicycle stands beside the garden gate while the birds begin to sing. '
    'At the railway station, a woman checks her ticket and waits for the next train. '
    'The weather report says that rain will arrive after lunch, so please bring an umbrella. '
    'Our science teacher places three glass bottles on the table and explains the experiment. '
    'We can pause the movie, change the audio track, and return to the previous chapter. '
    'A young musician practices a difficult song before the concert on Saturday evening. '
    'The library closes early today because the staff are preparing a new reading room. '
    'After dinner, the family walks along the river and watches the lights across the water. '
    'These final words complete the recording. All generated subtitles should remain in the cache folder.'
)


def validate_timeline(path, duration):
    data = path.read_text(encoding='utf-8-sig')
    cues = []
    for block in re.split(r'\n\s*\n', data.strip()):
        match = re.fullmatch(r'(\d+)\n(\d\d):(\d\d):(\d\d),(\d{3}) --> '
                             r'(\d\d):(\d\d):(\d\d),(\d{3})\n(.+)', block, re.S)
        if not match:
            return dict(passed=False, reason='malformed cue')
        values = [int(value) for value in match.groups()[:9]]
        index, h, m, s, ms, end_h, end_m, end_s, end_ms = values
        start = h * 3600 + m * 60 + s + ms / 1000
        end = end_h * 3600 + end_m * 60 + end_s + end_ms / 1000
        if (index != len(cues) + 1 or not 0 <= start < end <= duration + 0.1 or
                (cues and start < cues[-1]['end'] - 0.05)):
            return dict(passed=False, reason='unordered, overlapping or out-of-range cue')
        cues.append(dict(start=start, end=end, text=match[10].strip()))
    return dict(passed=bool(cues), cues=cues)


def ps_quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def file_digest(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def source_snapshot(path):
    info = path.stat()
    return (info.st_size, info.st_mtime_ns, file_digest(path), sorted(p.name for p in path.parent.iterdir()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', type=Path)
    parser.add_argument('--engine', choices=['whisper', 'qwen', 'qwen-small', 'sensevoice'], default='whisper')
    parser.add_argument('--runtime-root', type=Path, help='Test prepared components before changing local.conf')
    parser.add_argument('--whisper-mode', choices=['balanced', 'context'], default='context')
    parser.add_argument('--cancel-recognition', action='store_true', help='Cancel and switch files during real recognition before the normal lifecycle checks')
    parser.add_argument('--menu-switch', action='store_true', help='Select the requested alternative through uosc keys and restore Whisper')
    parser.add_argument('--full-config', action='store_true', help='Load actual root configuration with only the two test scripts')
    parser.add_argument('--management', action='store_true', help='Exercise the actual management menu, forced regeneration and explicit export')
    parser.add_argument('--segment', action='store_true', help='Exercise progressive output, cancellation and next-file cancellation')
    parser.add_argument('--fixed-segments', action='store_true', help='Compare fixed slices instead of silence boundaries (requires --segment)')
    parser.add_argument('--long-speech', action='store_true', help='Use the same long speech fixture as the segment comparison')
    parser.add_argument('--render', action='store_true', help='Render with D3D11 and capture partial/completed subtitles')
    parser.add_argument('--media', type=Path, help='Remux a complete local video into the test cache; leave the source untouched')
    parser.add_argument('--language', help='Recognition language (defaults to en for synthetic speech, auto for real media)')
    parser.add_argument('--timeout', type=int, default=600, help='Playback test timeout in seconds, including all generations')
    args = parser.parse_args()
    if args.menu_switch and args.engine == 'whisper':
        parser.error('--menu-switch requires an alternative engine')
    if args.segment and (args.engine != 'whisper' or args.management or args.menu_switch):
        parser.error('--segment requires Whisper without management/menu-switch')
    if args.fixed_segments and not args.segment:
        parser.error('--fixed-segments requires --segment')
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    if args.media and (not args.media.is_file() or args.long_speech):
        parser.error('--media requires an existing local file and cannot be combined with --long-speech')
    language = args.language or ('auto' if args.media else 'en')
    if language == 'auto':
        language = ''
    local = (CONFIG / 'local.conf').read_text(encoding='utf-8')
    if args.runtime_root:
        import sys
        sys.path.insert(0, str(CONFIG / 'tools/maintenance'))
        from ai_runtime import paths
        local += '\n' + '\n'.join('script-opts-append=sub_fastwhisper-' + key + '=' + value.as_posix()
                                    for key, value in paths(args.runtime_root.resolve()).items())
        # The prepared-root values intentionally override machine-local paths in this test only.
        local = '\n'.join(reversed(local.splitlines()))
    runtime_opts = []
    if args.runtime_root:
        runtime_opts.extend('sub_fastwhisper-' + key + '=' + value.as_posix()
                            for key, value in paths(args.runtime_root.resolve()).items() if key != 'output_path')
    for key in ('whisper_model_dir', 'ffmpeg_path'):
        match = re.search(r'^\s*script-opts-append=sub_fastwhisper-' + key + '=(.+)$', local, re.M)
        if match:
            runtime_opts.append('sub_fastwhisper-' + key + '=' + match[1].strip())
    qwen_opts = []
    if args.engine in ('qwen', 'qwen-small', 'sensevoice'):
        keys = ('sensevoice_python', 'sensevoice_model') if args.engine == 'sensevoice' else ('qwen_python', 'qwen_model', 'qwen_aligner')
        if args.engine == 'qwen-small':
            keys += ('qwen_small_model',)
            qwen_opts.append('sub_fastwhisper-qwen_variant=small')
        for key in keys:
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
    first, second = folder / 'A' / 'clip.mkv', folder / 'B' / 'clip.mkv'
    first.parent.mkdir()
    second.parent.mkdir()
    speech_text = None
    source_before = None
    if args.media:
        args.media = args.media.resolve()
        source_before = source_snapshot(args.media)
        subprocess.run([ffmpeg, '-hide_banner', '-nostdin', '-loglevel', 'error', '-i', str(args.media),
                        '-map', '0:v:0', '-map', '0:a:0', '-c', 'copy', str(first)], check=True, timeout=120)
    else:
        speech = folder / 'speech.wav'
        speech_text = LONG_SPEECH if args.segment or args.long_speech else SHORT_SPEECH
        synth = (
            'Add-Type -AssemblyName System.Speech; '
            '$asrSynth = [System.Speech.Synthesis.SpeechSynthesizer]::new(); '
            "$asrSynth.SelectVoice('Microsoft Zira Desktop'); "
            '$asrSynth.SetOutputToWaveFile(' + ps_quote(speech) + '); '
            '$asrSynth.Speak(' + ps_quote(speech_text) + '); '
            '$asrSynth.Dispose()'
        )
        subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', synth], check=True, timeout=30)
        subprocess.run([ffmpeg, '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'testsrc2=size=320x180:rate=24', '-i', str(speech), '-c:v', 'libx264',
                        '-preset', 'ultrafast', '-c:a', 'aac', '-shortest', str(first)], check=True, timeout=30)
    shutil.copy2(first, second)
    before = {str(p.parent): sorted(x.name for x in p.parent.iterdir()) for p in (first, second)}
    mock_args = [str(CONFIG.parent / 'mpv.exe'), '--no-config', '--config-dir=' + str(CONFIG),
                 '--load-scripts=no', '--idle=yes', '--vo=null', '--ao=null', '--term-status-msg=',
                 '--script=' + str(CONFIG / 'tools/tests/test_ai_subtitles.lua'),
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
            'sub_fastwhisper-backend=' + ('whisper' if args.menu_switch else 'qwen' if args.engine == 'qwen-small' else args.engine),
            'sub_fastwhisper-whisper_mode=' + args.whisper_mode,
            'sub_fastwhisper-model=large-v3-turbo', 'sub_fastwhisper-device=cuda',
            'sub_fastwhisper-compute_type=float16', 'sub_fastwhisper-language=' + language,
            'sub_fastwhisper-api_key=', 'sub_fastwhisper-output_path=' + (real_root / 'results').as_posix(),
            'sub_fastwhisper-use_segment=' + ('yes' if args.segment else 'no'),
            'sub_fastwhisper-segment_silence=' + ('no' if args.fixed_segments else 'yes'),
            'asr-playback-root=' + real_root.as_posix(), 'asr-playback-first=' + first.as_posix(),
            'asr-playback-second=' + second.as_posix(),
            'asr-playback-render=' + ('yes' if args.render else 'no'),
            'asr-playback-segment=' + ('yes' if args.segment else 'no')]
    opts.extend(runtime_opts)
    opts.extend(qwen_opts)
    opts.append('asr-playback-timeout=' + str(args.timeout))
    if args.menu_switch:
        opts.append('asr-playback-menu_switch=yes')
        opts.append('asr-playback-preset=' + {'qwen':'qwen-quality','qwen-small':'qwen-small','sensevoice':'sensevoice'}[args.engine])
    if args.management:
        opts.append('asr-playback-management=yes')
    if args.cancel_recognition:
        opts.append('asr-playback-cancel_recognition=yes')
    log_path = folder / 'player.log'
    command = [str(CONFIG.parent / 'mpv.exe'), '--no-config', '--config-dir=' + str(CONFIG),
               '--load-scripts=no', '--script=' + str(CONFIG / 'scripts/sub-fastwhisper.lua'),
               '--script=' + str(CONFIG / 'tools/tests/test_ai_subtitles_playback.lua'),
               '--input-conf=' + str(CONFIG / 'input.conf'), '--script-opts=' + ','.join(opts),
               '--vo=null', '--ao=null', '--pause=yes', '--idle=yes', '--keep-open=yes',
               '--save-position-on-quit=no', '--resume-playback=no', '--term-status-msg=', '--input-ipc-server=',
               '--log-file=' + str(log_path), str(first)]
    if args.full_config:
        command.remove('--no-config')
        command.insert(1, '--msg-level=all=warn,sub_fastwhisper=info,test_ai_subtitles_playback=info')
    if args.menu_switch or args.management:
        command.insert(1, '--script=' + str(CONFIG / 'scripts/uosc'))
    if args.management or args.render:
        command.remove('--vo=null')
        command[1:1] = ['--vo=gpu-next', '--gpu-api=d3d11', '--osc=no', '--geometry=1280x720',
                        '--osd-fonts-dir=' + str(CONFIG / 'fonts'), '--osd-font=Noto Sans Mono CJK SC']
    timed_out = False
    with (folder / 'console.log').open('wb') as console:
        proc = subprocess.Popen(command, cwd=CONFIG, stdout=console, stderr=subprocess.STDOUT,
                                creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            code = proc.wait(timeout=args.timeout + 30)
        except subprocess.TimeoutExpired:
            timed_out = True
            subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True, timeout=10)
            code = proc.wait(timeout=10)
    log = log_path.read_text(encoding='utf-8', errors='replace') if log_path.is_file() else ''
    after = {str(p.parent): sorted(x.name for x in p.parent.iterdir()) for p in (first, second)}
    source_unchanged = not args.media or source_before == source_snapshot(args.media)
    result_path = real_root / 'playback.json'
    result = json.loads(result_path.read_text(encoding='utf-8')) if result_path.is_file() else {}
    outputs = [Path(result[key]) for key in ('first', 'second') if key in result]
    text_valid = len(outputs) == 2 and all(p.is_file() for p in outputs) and all(
        '-->' in p.read_text(encoding='utf-8') and
        (args.media or 'subtitle' in p.read_text(encoding='utf-8').lower()) for p in outputs)
    duration = result.get('metrics', {}).get('media_duration', 0)
    timelines = [validate_timeline(p, duration) for p in outputs if p.is_file()]
    orphan_command = (
        '$asrProcesses = @(Get-CimInstance Win32_Process | Where-Object { '
        "$_.Name -match '^(faster-whisper.*|ffmpeg|python.*)\\.exe$' -and "
        "$_.CommandLine -and $_.CommandLine.Replace('\\', '/').Contains(" + ps_quote(folder.as_posix()) + ') }); '
        'ConvertTo-Json -InputObject @($asrProcesses | Select-Object ProcessId,Name) -Compress'
    )
    orphan_check = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', orphan_command],
                                  capture_output=True, text=True, timeout=30)
    orphans = json.loads(orphan_check.stdout) if orphan_check.returncode == 0 and orphan_check.stdout.strip() else None
    expected_jobs = 3 if args.management else 2
    passed = (code == 0 and not timed_out and before == after and source_unchanged and text_valid
              and 'ASR CACHE PLAYBACK PASS:' in log and 'ASR CACHE PLAYBACK FAIL:' not in log
              and not re.search(r'\[(?:e|f)\]', log) and 'Lua error' not in log
              and len(timelines) == 2 and all(t['passed'] for t in timelines) and orphans == []
              and log.count('AI subtitle cache completed:') == expected_jobs
              and log.count('AI subtitle cache reused:') >= 2)
    if args.engine != 'whisper':
        marker = 'SENSEVOICE_ASR_OK ' if args.engine == 'sensevoice' else 'QWEN_ASR_OK '
        passed = passed and log.count(marker) == expected_jobs and result.get('menu_switch', False) == args.menu_switch
    if args.management:
        exported = real_root / 'selected-export.srt'
        passed = passed and exported.is_file() and exported.read_bytes() == outputs[0].read_bytes()
        passed = passed and (real_root / 'management.png').is_file()
    if args.render:
        required = ['completed.png'] + (['partial.png'] if args.segment else [])
        passed = passed and all((real_root / name).is_file() and (real_root / name).stat().st_size > 1000 for name in required)
    report = dict(passed=bool(passed), exit_code=code, timed_out=timed_out,
                  source_folders_unchanged=before == after and source_unchanged,
                  valid_outputs=text_valid, completed_jobs=log.count('AI subtitle cache completed:'),
                  reuse_events=log.count('AI subtitle cache reused:'), engine=args.engine,
                  model={'whisper':'large-v3-turbo','qwen':'Qwen3-ASR-1.7B','qwen-small':'Qwen3-ASR-0.6B','sensevoice':'SenseVoiceSmall'}[args.engine],
                  whisper_mode=args.whisper_mode,
                  device='cuda', precision='bfloat16' if args.engine.startswith('qwen') else 'float32' if args.engine == 'sensevoice' else 'float16',
                  media=str(args.media) if args.media else '320x180/24fps H.264 + AAC, synthetic English speech',
                  language=language or 'auto', fixture_sha256=file_digest(first),
                  source_sha256=source_before[2] if source_before else None,
                  mock_passed=True, outputs=[str(p) for p in outputs], log=str(log_path))
    report['full_root_config'] = args.full_config
    report['menu_switch'] = args.menu_switch
    report['management'] = args.management
    report['segment'] = args.segment
    report['silence_boundaries'] = args.segment and not args.fixed_segments
    report['render'] = args.render
    report['cancel_recognition'] = args.cancel_recognition
    report['playback'] = result
    report['timelines'] = timelines
    report['remaining_backend_processes'] = orphans
    reference = re.findall(r'[a-z]+', (speech_text or '').lower())
    report['reference_text'] = speech_text
    report['transcript_comparison'] = []
    for timeline in timelines if speech_text else []:
        hypothesis = re.findall(r'[a-z]+', ' '.join(cue['text'] for cue in timeline.get('cues', [])).lower())
        edits = [dict(operation=op, reference=' '.join(reference[a:b]), recognized=' '.join(hypothesis[c:d]))
                 for op, a, b, c, d in difflib.SequenceMatcher(None, reference, hypothesis, autojunk=False).get_opcodes()
                 if op != 'equal']
        report['transcript_comparison'].append(dict(reference_words=len(reference), recognized_words=len(hypothesis), differences=edits))
    (folder / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(('PASS' if passed else 'FAIL') + ': ' + str(folder / 'report.json'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
