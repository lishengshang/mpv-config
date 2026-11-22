"""Adapter tests that do not load a model or require CUDA."""
from types import SimpleNamespace
import ctypes
from ctypes import wintypes  # Load before tests temporarily replace sys.path.
import unittest
from unittest.mock import patch
from pathlib import Path
import sys
import tempfile
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'runtime'))
from qwen_subtitles import chunks, language_name, stamp, timed_cues, speech_batches, write_srt
from sensevoice_subtitles import decode_result
import qwen_runtime


def item(text, start, end):
    return SimpleNamespace(text=text, start_time=start, end_time=end)


class AdapterTests(unittest.TestCase):
    def test_windows_unicode_import_uses_ascii_alias(self):
        def get_short(value, buffer, size):
            buffer.value = 'C:/SHORT~1/site-packages'
            return len(buffer.value)
        with patch.object(qwen_runtime.os, 'name', 'nt'), patch.object(qwen_runtime.os.path, 'exists', return_value=True), \
                patch.object(ctypes, 'WinDLL', return_value=SimpleNamespace(GetShortPathNameW=get_short), create=True), \
                patch.object(qwen_runtime.sys, 'path', ['C:/中文/site-packages', 'C:/ascii']):
            qwen_runtime.prepare_import_paths()
            self.assertEqual(qwen_runtime.sys.path, ['C:/SHORT~1/site-packages', 'C:/ascii'])

    def test_windows_missing_short_names_fails_clearly(self):
        def get_short(value, buffer, size):
            return 0
        with patch.object(qwen_runtime.os, 'name', 'nt'), patch.object(qwen_runtime.os.path, 'exists', return_value=True), \
                patch.object(ctypes, 'WinDLL', return_value=SimpleNamespace(GetShortPathNameW=get_short), create=True), \
                patch.object(qwen_runtime.sys, 'path', ['C:/中文/site-packages']):
            with self.assertRaisesRegex(RuntimeError, 'ASCII component destination'):
                qwen_runtime.prepare_import_paths()

    def test_chunk_boundaries_cover_audio_once(self):
        self.assertEqual(list(chunks(46, [12, 18, 37], 20)), [(0, 18), (18, 37), (37, 46)])

    def test_language_codes(self):
        self.assertEqual(language_name('ja'), 'Japanese')
        self.assertEqual(language_name('english'), 'English')
        self.assertIsNone(language_name(''))
        with self.assertRaises(ValueError):
            language_name('unsupported')

    def test_english_punctuation_preserved(self):
        text = 'Hello, world! This is a test.'
        words = ['Hello', 'world', 'This', 'is', 'a', 'test']
        cues = timed_cues(text, [item(w, i, i + 0.5) for i, w in enumerate(words)], 20, 10, 100)
        self.assertEqual([c[2] for c in cues], ['Hello, world!', 'This is a test.'])
        self.assertEqual(cues[0][:2], (20, 21.5))

    def test_cjk_punctuation_preserved(self):
        cues = timed_cues('你好。世界！', [item(w, i / 4, (i + 1) / 4) for i, w in enumerate('你好世界')], 0, 2, 100)
        self.assertEqual([c[2] for c in cues], ['你好。', '世界！'])

    def test_casefold_does_not_change_original_offsets(self):
        cues = timed_cues('Straße ist groß.', [item(w, i / 4, (i + 1) / 4) for i, w in enumerate(['Straße', 'ist', 'groß'])], 0, 2, 100)
        self.assertEqual(cues[0][2], 'Straße ist groß.')

    def test_long_clauses_prefer_punctuation(self):
        text = '这是用于测试的长句，后面还有一段完整文字。'
        words = [char for char in text if char.isalnum()]
        cues = timed_cues(text, [item(w, i / 4, (i + 1) / 4) for i, w in enumerate(words)], 0, 10, 100)
        self.assertEqual([c[2] for c in cues], ['这是用于测试的长句，', '后面还有一段完整文字。'])

    def test_text_mismatch_is_an_error(self):
        with self.assertRaises(ValueError):
            timed_cues('original', [item('different', 0, 1)], 0, 2, 100)

    def test_invalid_time_is_an_error(self):
        with self.assertRaises(ValueError):
            timed_cues('hello', [item('hello', 2, 1)], 0, 3, 100)

    def test_timestamp_rounding_carries(self):
        self.assertEqual(stamp(59.9999), '00:01:00,000')

    def test_batched_audio_preserves_offsets_and_skips_silence(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'audio.wav'
            with wave.open(str(source), 'wb') as audio:
                audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                audio.writeframes(b'\0\0' * 16000 + b'\0\x10' * 32000)
            with wave.open(str(source)) as audio:
                batches = list(speech_batches(audio, [(0,1),(1,2),(2,3)], 2))
            self.assertEqual([[(start,end) for start,end,_ in batch] for batch in batches], [[(1,2),(2,3)]])
            self.assertEqual(len(batches[0][0][2]), 16000)

    def test_bad_or_empty_output_cannot_replace_existing_subtitle(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'saved.srt'
            path.write_text('previous', encoding='utf-8')
            for cues in ([], [(float('nan'),1,'bad')], [(2,1,'bad')], [(0,1,'')]):
                with self.assertRaises(RuntimeError):
                    write_srt(path, cues, 3)
                self.assertEqual(path.read_text(encoding='utf-8'), 'previous')

    def test_sensevoice_tags_and_millisecond_timestamps(self):
        text, words, languages = decode_result(dict(text='<|zh|><|NEUTRAL|><|Speech|><|withitn|>你好。',
            words=['你','好'], timestamp=[[100,300],[300,600]]))
        self.assertEqual(text, '你好。')
        self.assertEqual(languages, {'zh'})
        self.assertEqual(timed_cues(text, words, 20, 2, 100), [(20.1,20.6,'你好。')])

    def test_sensevoice_missing_timestamps_and_legacy_format_fail(self):
        with self.assertRaises(RuntimeError):
            decode_result(dict(text='hello'))
        with self.assertRaises(RuntimeError):
            decode_result(dict(text='hello',words=['hello'],timestamp=[['hello',0,1]]))
        self.assertEqual(decode_result(dict(text='<|nospeech|>'))[0], '')


if __name__ == '__main__':
    unittest.main()
