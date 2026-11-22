"""Offline SenseVoiceSmall to SRT, bounded batches and native CTC timestamps."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import time
from types import SimpleNamespace
import wave

sys.path.insert(0, str(Path(__file__).resolve().parent))
from qwen_subtitles import (chunks, contain_child_processes, extract_audio, speech_batches,
                            timed_cues, write_srt)

LANGUAGES = {'zh', 'en', 'yue', 'ja', 'ko'}


def decode_result(result):
    raw = result.get('text', '')
    text = re.sub(r'<\|[^|]*\|>', '', raw).strip()
    languages = set(re.findall(r'<\|(zh|en|yue|ja|ko)\|>', raw))
    if not text or '<|nospeech|>' in raw:
        return '', [], languages
    words, stamps = result.get('words', []), result.get('timestamp', [])
    if not words or len(words) != len(stamps):
        raise RuntimeError('SenseVoice returned no aligned words; check the pinned FunASR version')
    items = []
    for word, stamp in zip(words, stamps):
        if len(stamp) != 2:
            raise RuntimeError('Unexpected SenseVoice timestamp format (expected milliseconds)')
        items.append(SimpleNamespace(text=word, start_time=stamp[0] / 1000, end_time=stamp[1] / 1000))
    return text, items, languages


def run(args):
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    # Runtime caches stay beside the explicitly installed model, never in the media folder.
    os.environ['MODELSCOPE_CACHE'] = str(Path(args.model).parent / '.cache')
    import torch
    from funasr import AutoModel

    if not torch.cuda.is_available():
        raise RuntimeError('CUDA is unavailable in the configured SenseVoice environment')
    if not (Path(args.model) / 'model.pt').is_file():
        raise RuntimeError('Local SenseVoice model missing; see docs/ai-subtitles.md')
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    wav_path = output.parent / 'sensevoice-audio.wav'
    started = time.monotonic()
    try:
        silences = extract_audio(args, wav_path)
        extracted = time.monotonic()
        torch.cuda.reset_peak_memory_stats()
        # The implementation comes from the pinned installed package, never model remote code.
        model = AutoModel(model=str(Path(args.model).resolve()), device='cuda:0',
                          disable_update=True, trust_remote_code=False, disable_pbar=True)
        loaded = time.monotonic()
        cues, languages, recognized = [], set(), 0
        with wave.open(str(wav_path)) as audio:
            duration = audio.getnframes() / audio.getframerate()
            if duration <= 0:
                raise RuntimeError('Audio is empty')
            windows = list(chunks(duration, silences, args.chunk_seconds))
            for batch in speech_batches(audio, windows, args.batch_size):
                results = model.generate(input=[data for _, _, data in batch], fs=audio.getframerate(),
                                         language=args.language or 'auto', use_itn=True,
                                         output_timestamp=True, batch_size=args.batch_size,
                                         disable_pbar=True)
                if len(results) != len(batch):
                    raise RuntimeError('SenseVoice batch output count differs from input')
                for (start, end, _), result in zip(batch, results):
                    text, items, detected = decode_result(result)
                    if text:
                        languages.update(detected)
                        cues.extend(timed_cues(text, items, start, end-start, args.max_line_width))
                recognized += len(batch)
                print(f'SenseVoice: recognized {recognized}/{len(windows)}', flush=True)
        count = write_srt(output, cues, duration)
        stats = dict(model='SenseVoiceSmall', device=torch.cuda.get_device_name(), dtype='float32',
                     duration=duration, elapsed=round(time.monotonic()-started, 2), batch_size=args.batch_size,
                     extract_seconds=round(extracted-started, 2), load_seconds=round(loaded-extracted, 2),
                     decode_seconds=round(time.monotonic()-loaded, 2),
                     peak_allocated_mib=round(torch.cuda.max_memory_allocated()/1048576),
                     cues=count, languages=sorted(languages))
        (output.parent / 'sensevoice-stats.json').write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding='utf-8')
        print('SENSEVOICE_ASR_OK ' + json.dumps(stats, ensure_ascii=False), flush=True)
    finally:
        wav_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--audio-map', default='0:a:0')
    parser.add_argument('--language', choices=['', *sorted(LANGUAGES)], default='')
    parser.add_argument('--chunk-seconds', type=int, choices=range(2, 31), default=20)
    parser.add_argument('--batch-size', type=int, choices=range(1, 17), default=4)
    parser.add_argument('--max-line-width', type=int, default=100)
    args = parser.parse_args()
    if args.max_line_width < 1:
        parser.error('max-line-width must be positive')
    try:
        job_handle = contain_child_processes()
        run(args)
        return 0
    except Exception as error:
        print(f'SENSEVOICE_ASR_ERROR: {type(error).__name__}: {error}', file=sys.stderr, flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
