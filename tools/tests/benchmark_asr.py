"""Compare Whisper search widths on identical local audio; never reuse completed caches."""
import argparse
import difflib
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ai_subtitles import file_digest, source_snapshot, validate_timeline

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--media', type=Path, required=True)
    parser.add_argument('--runtime-root', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=2)
    parser.add_argument('--timeout', type=int, default=900)
    parser.add_argument('--language', default='auto')
    args = parser.parse_args()
    if not args.media.is_file() or not 2 <= args.rounds <= 5 or args.timeout <= 0:
        parser.error('existing local media, 2..5 rounds and positive timeout required')
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    media, runtime = args.media.resolve(), args.runtime_root.resolve()
    backend = runtime / 'runtimes/whisper/faster-whisper-xxl.exe'
    model = runtime / 'models/whisper/faster-whisper-large-v3-turbo/model.bin'
    if not backend.is_file() or not model.is_file():
        parser.error('Whisper executable and large-v3-turbo model must already exist')
    duration = float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
                     'format=duration', '-of', 'csv=p=0', str(media)], text=True, timeout=30))
    before = source_snapshot(media)
    folder = ROOT / 'cache' / ('asr-speed-' + time.strftime('%Y%m%d-%H%M%S'))
    folder.mkdir(exist_ok=False)
    report = dict(passed=False, media=str(media), duration=duration, source_sha256=before[2],
                  backend_sha256=file_digest(backend), model_sha256=file_digest(model),
                  model='large-v3-turbo', device='cuda', precision='float16', language=args.language,
                  word_timestamps=True, condition_on_previous_text=True, batched=False, results=[])
    report['backend_version'] = subprocess.check_output([str(backend), '--version'], text=True, timeout=30).strip()
    gpu = subprocess.run(['nvidia-smi', '--query-gpu=name,driver_version,memory.total', '--format=csv,noheader'],
                         capture_output=True, text=True, timeout=15)
    report['gpu'] = gpu.stdout.strip()
    def save():
        (folder / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    save()
    transcripts = {}
    for trial in range(args.rounds):
        for beam in ((5, 1) if trial % 2 == 0 else (1, 5)):
            output = folder / f'round-{trial+1}-beam-{beam}'
            output.mkdir()
            command = [str(backend), str(media), '--beep_off', '--model', 'large-v3-turbo',
                       '--model_dir', str(runtime/'models/whisper'), '--device', 'cuda', '--compute_type', 'float16',
                       '--output_dir', str(output), '--output_format', 'srt', 'json', '--max_line_width', '100',
                       '--threads', '0', '--beam_size', str(beam)]
            if args.language != 'auto':
                command += ['--language', args.language]
            started = time.monotonic()
            with (output/'backend.log').open('wb') as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout,
                                        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            elapsed = time.monotonic()-started
            files = list(output.glob('*.srt'))
            timeline = validate_timeline(files[0], duration) if len(files)==1 else dict(passed=False)
            metadata = list(output.glob('*.json'))
            data = json.loads(metadata[0].read_text(encoding='utf-8-sig')) if len(metadata)==1 else {}
            words = sum(len(segment.get('words', [])) for segment in data.get('segments', []))
            text = ''.join(re.findall(r'\w', ''.join(c['text'] for c in timeline.get('cues', [])))).lower()
            transcripts[(trial,beam)] = text
            record = dict(round=trial+1, beam=beam, seconds=round(elapsed,3), exit_code=result.returncode,
                          timeline_valid=timeline['passed'], cues=len(timeline.get('cues', [])),
                          text_characters=len(text), word_timestamps=words, output=str(files[0]) if files else None, command=command)
            report['results'].append(record)
            save()
            print(json.dumps({k:v for k,v in record.items() if k not in ('output','command')}), flush=True)
            if result.returncode != 0 or not timeline['passed'] or not words:
                raise SystemExit('FAIL: backend/timeline; see '+str(folder/'report.json'))
    report['text_comparison'] = [dict(round=i+1, similarity=difflib.SequenceMatcher(None, transcripts[(i,5)],
                                     transcripts[(i,1)], autojunk=False).ratio()) for i in range(args.rounds)]
    report['median_seconds'] = {str(beam):round(statistics.median(r['seconds'] for r in report['results'] if r['beam']==beam),3)
                                for beam in (5,1)}
    report['speedup'] = round(report['median_seconds']['5']/report['median_seconds']['1'],3)
    report['speed_improved'] = report['median_seconds']['1'] < report['median_seconds']['5']
    report['source_unchanged'] = before == source_snapshot(media)
    report['runtime_unchanged'] = (report['backend_sha256']==file_digest(backend) and report['model_sha256']==file_digest(model))
    report['passed'] = (report['source_unchanged'] and report['runtime_unchanged'] and
                        all(r['exit_code']==0 and r['timeline_valid'] and r['word_timestamps'] for r in report['results']))
    save()
    print('REPORT: '+str(folder/'report.json'), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
