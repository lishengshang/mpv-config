"""Local Qwen3-ASR to SRT adapter. Models load offline, one GPU stage at a time."""
import argparse
import gc
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import wave


LANGUAGES = dict(zip(
    'zh en yue ar de fr es pt id it ko ru th vi ja tr hi ms nl sv da fi pl cs fil fa el hu mk ro'.split(),
    'Chinese English Cantonese Arabic German French Spanish Portuguese Indonesian Italian Korean Russian Thai Vietnamese Japanese Turkish Hindi Malay Dutch Swedish Danish Finnish Polish Czech Filipino Persian Greek Hungarian Macedonian Romanian'.split()))
ALIGN_LANGUAGES = set('Chinese English Cantonese French German Italian Japanese Korean Portuguese Russian Spanish'.split())


def contain_child_processes():
    """Windows: closing/killing this runner also terminates its FFmpeg child."""
    if os.name != 'nt':
        return None
    import ctypes
    from ctypes import wintypes as w

    class BasicLimits(ctypes.Structure):
        _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                    ('flags', w.DWORD), ('min_ws', ctypes.c_size_t), ('max_ws', ctypes.c_size_t),
                    ('active', w.DWORD), ('affinity', ctypes.c_size_t), ('priority', w.DWORD), ('scheduling', w.DWORD)]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [('basic', BasicLimits), ('io', ctypes.c_uint64 * 6),
                    ('process_memory', ctypes.c_size_t), ('job_memory', ctypes.c_size_t),
                    ('peak_process', ctypes.c_size_t), ('peak_job', ctypes.c_size_t)]

    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [w.LPVOID, w.LPCWSTR]
    kernel.CreateJobObjectW.restype = w.HANDLE
    kernel.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, w.LPVOID, w.DWORD]
    kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
    kernel.GetCurrentProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    handle = kernel.CreateJobObjectW(None, None)
    limits = ExtendedLimits()
    limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    if not handle or not kernel.SetInformationJobObject(handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)) or not kernel.AssignProcessToJobObject(handle, kernel.GetCurrentProcess()):
        error = ctypes.WinError(ctypes.get_last_error())
        if handle:
            kernel.CloseHandle(handle)
        raise error
    # Keep the handle open until process exit. It is non-inheritable by children.
    return handle


def language_name(value):
    if not value:
        return None
    aliases = {'tl': 'Filipino', 'zh-cn': 'Chinese', 'zh-tw': 'Chinese'}
    name = LANGUAGES.get(value.lower(), aliases.get(value.lower(), value.title()))
    if name not in LANGUAGES.values():
        raise ValueError('Qwen does not support language: ' + value)
    return name


def chunks(duration, silences, limit):
    """Prefer silence boundaries without dropping or overlapping audio."""
    start = 0.0
    while start < duration - 0.01:
        end = min(start + limit, duration)
        if end < duration:
            choices = [s for s in silences if start + limit * 0.5 <= s <= end]
            if choices:
                end = choices[-1]
        yield start, end
        start = end


def stamp(seconds):
    ms = max(0, round(seconds * 1000))
    return f'{ms // 3600000:02}:{ms // 60000 % 60:02}:{ms // 1000 % 60:02},{ms % 1000:03}'


def timed_cues(text, items, offset, duration, width):
    """Restore punctuation from the transcript; use aligned times only for timing."""
    spans, cursor = [], 0
    for item in items:
        # The aligner removes punctuation. Locate its words/characters in the original text.
        positions = []
        for char in item.text:
            pos = text.find(char, cursor)
            if pos < 0:
                pos = next((index for index in range(cursor, len(text))
                            if text[index].casefold() == char.casefold()), -1)
            if pos < 0:
                raise ValueError('Aligner text differs from the transcript')
            positions.append(pos)
            cursor = pos + 1
        if positions:
            start, end = float(item.start_time), float(item.end_time)
            if not math.isfinite(start + end) or end < start:
                raise ValueError('Invalid alignment timestamp')
            spans.append((positions[0], cursor, max(0, start), min(duration, end)))
    if not spans:
        raise ValueError('Aligner returned no words')
    cues, parts, cue_start, cue_end = [], [], None, None
    for i, (begin, end, start, stop) in enumerate(spans):
        fragment = text[0 if i == 0 else begin:spans[i + 1][0] if i + 1 < len(spans) else len(text)]
        if parts and (start - cue_end > 0.7 or stop - cue_start > 8 or
                      len(''.join(parts)) + len(fragment) > width):
            cues.append((offset + cue_start, offset + max(cue_start + 0.04, cue_end), ''.join(parts).strip()))
            parts, cue_start = [], None
        if cue_start is None:
            cue_start = start
        cue_end = max(start, stop)
        parts.append(fragment)
        sentence_end = re.search(r'[.!?。！？][\s”’"\']*$', fragment)
        clause_end = cue_end - cue_start >= 2 and re.search(r'[,，;；:：][\s”’"\']*$', fragment)
        if sentence_end or clause_end:
            cues.append((offset + cue_start, offset + max(cue_start + 0.04, cue_end), ''.join(parts).strip()))
            parts, cue_start = [], None
    if parts:
        cues.append((offset + cue_start, offset + max(cue_start + 0.04, cue_end), ''.join(parts).strip()))
    return cues


def run(args):
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
    import numpy as np
    import torch
    from qwen_asr import Qwen3ASRModel, Qwen3ForcedAligner

    if not torch.cuda.is_available():
        raise RuntimeError('CUDA is unavailable in the configured Qwen Python environment')
    for name in (args.model, args.aligner):
        if not (Path(name) / 'config.json').is_file():
            raise RuntimeError('Local model missing: ' + name + '; see docs/ai-subtitles.md')
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    wav_path = output.parent / 'qwen-audio.wav'
    started = time.monotonic()
    cmd = [args.ffmpeg, '-hide_banner', '-nostdin', '-y', '-i', args.input,
           '-map', args.audio_map, '-vn', '-ac', '1', '-ar', '16000',
           '-af', 'aresample=async=1:first_pts=0,silencedetect=noise=-35dB:d=0.4', '-c:a', 'pcm_s16le', str(wav_path)]
    process = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                             encoding='utf-8', errors='replace', creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    if process.returncode:
        raise RuntimeError('FFmpeg audio extraction failed: ' + process.stderr[-3000:])
    silences = [float(s) for s in re.findall(r'silence_end: ([0-9.]+)', process.stderr)]
    with wave.open(str(wav_path)) as audio:
        rate = audio.getframerate()
        duration = audio.getnframes() / rate
        if duration <= 0:
            raise RuntimeError('Audio is empty')
        windows = list(chunks(duration, silences, args.chunk_seconds))

        def samples(start, end):
            audio.setpos(round(start * rate))
            return np.frombuffer(audio.readframes(round((end - start) * rate)), dtype='<i2').astype(np.float32) / 32768

        dtype = torch.bfloat16
        settings = dict(dtype=dtype, device_map='cuda:0', attn_implementation='sdpa', local_files_only=True)
        torch.cuda.reset_peak_memory_stats()
        print('Qwen: loading ASR', flush=True)
        model = Qwen3ASRModel.from_pretrained(args.model, max_inference_batch_size=1,
                                            max_new_tokens=1024, **settings)
        records = []
        for index, (start, end) in enumerate(windows):
            data = samples(start, end)
            # Entirely silent windows are skipped rather than prompting a language model with silence.
            if len(data) == 0 or float(np.max(np.abs(data))) < 0.003:
                continue
            result = model.transcribe(audio=(data, rate), language=language_name(args.language))[0]
            text = result.text.strip()
            if text:
                records.append(dict(start=start, end=end, text=text, language=result.language))
            print(f'Qwen: recognized {index + 1}/{len(windows)}', flush=True)
        # Persist text before releasing ASR. Never load both GPU models together.
        (output.parent / 'qwen-transcript.json').write_text(json.dumps(records, ensure_ascii=False), encoding='utf-8')
        del model
        gc.collect()
        torch.cuda.empty_cache()
        if not records:
            raise RuntimeError('No speech recognized; no completed subtitle was created')
        aligner = None
        if any(r['language'] in ALIGN_LANGUAGES for r in records):
            print('Qwen: loading forced aligner', flush=True)
            aligner = Qwen3ForcedAligner.from_pretrained(args.aligner, **settings)
        cues, coarse = [], 0
        for index, record in enumerate(records):
            start, end, text = record['start'], record['end'], record['text']
            if record['language'] in ALIGN_LANGUAGES:
                items = aligner.align(audio=(samples(start, end), rate), text=text,
                                      language=record['language'])[0].items
                cues.extend(timed_cues(text, items, start, end - start, args.max_line_width))
            else:
                # ASR covers more languages than the official aligner. Keep real chunk bounds,
                # never invent word timestamps for those languages or mixed-language outputs.
                cues.append((start, end, text))
                coarse += 1
            print(f'Qwen: timed {index + 1}/{len(records)}', flush=True)
        payload = []
        last_end = 0.0
        for start, end, text in cues:
            start = max(last_end, start)
            end = min(duration, max(start + 0.04, end))
            if end <= start or not text.strip():
                raise RuntimeError('Invalid subtitle timing')
            payload.append(f'{len(payload) + 1}\n{stamp(start)} --> {stamp(end)}\n{text}\n\n')
            last_end = end
        pending = output.with_suffix('.srt.pending')
        pending.write_text(''.join(payload), encoding='utf-8', newline='\n')
        pending.replace(output)
        stats = dict(model=Path(args.model).name, device=torch.cuda.get_device_name(), dtype='bfloat16',
                     duration=duration, elapsed=round(time.monotonic() - started, 2),
                     peak_allocated_mib=round(torch.cuda.max_memory_allocated() / 1048576),
                     coarse_chunks=coarse, cues=len(payload))
        (output.parent / 'qwen-stats.json').write_text(json.dumps(stats, ensure_ascii=False, indent=2), encoding='utf-8')
        print('QWEN_ASR_OK ' + json.dumps(stats, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--aligner', required=True)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--audio-map', default='0:a:0')
    parser.add_argument('--language', default='')
    parser.add_argument('--chunk-seconds', type=float, default=20)
    parser.add_argument('--max-line-width', type=int, default=100)
    args = parser.parse_args()
    if not 2 <= args.chunk_seconds <= 30 or args.max_line_width < 1:
        parser.error('chunk-seconds must be 2..30; max-line-width must be positive')
    try:
        job_handle = contain_child_processes()
        run(args)
        return 0
    except Exception as error:
        print(f'QWEN_ASR_ERROR: {type(error).__name__}: {error}', file=sys.stderr, flush=True)
        return 1
    finally:
        (Path(args.output).parent / 'qwen-audio.wav').unlink(missing_ok=True)


if __name__ == '__main__':
    raise SystemExit(main())
