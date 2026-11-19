"""Regression checks for late dialogue getting lost after short mix inputs end."""
import tempfile
import unittest
import wave
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import numpy as np
from core import Project
from captions import transcribe


class RecognitionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'tone.wav'
        t = np.arange(16000) / 16000
        samples = (.2*np.sin(2*np.pi*1000*t)*32767).astype('<i2')
        with wave.open(str(self.path), 'wb') as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
            stream.writeframes(samples.tobytes())
        self.project = Project()
        self.project.data['captionStyle']['language'] = 'en-US'
        media = self.project.add_media(self.path)
        self.project.add_clip(media['id'], 0, 0)
        self.project.add_clip(media['id'], 0, 2)
        self.calls = []

    def recognize(self, path, **options):
        with wave.open(path, 'rb') as stream:
            audio = np.frombuffer(stream.readframes(stream.getnframes()), dtype='<i2')/32768
        self.calls.append((audio, options))
        word = SimpleNamespace(word='Hello', start=2.2, end=2.6)
        segment = SimpleNamespace(words=[word], end=2.6)
        return iter([segment]), None

    def test_late_audio_keeps_the_same_level_and_captions(self):
        model = SimpleNamespace(transcribe=self.recognize)
        with patch('faster_whisper.WhisperModel', return_value=model):
            captions = transcribe(self.project)
        audio, options = self.calls[0]
        early = np.std(audio[3200:11200]); late = np.std(audio[35200:43200])
        self.assertAlmostEqual(late/early, 1, delta=.025)
        self.assertLess(np.max(np.abs(audio)), .25)
        self.assertEqual(captions[0]['text'], 'Hello')
        self.assertGreater(captions[0]['start'], 2)
        self.assertFalse(options['vad_filter'])
        self.assertFalse(options['condition_on_previous_text'])

    def test_uses_cached_base_without_downloading_medium(self):
        model = SimpleNamespace(transcribe=self.recognize)
        with patch('faster_whisper.WhisperModel', side_effect=[OSError('not cached'), model]) as ctor:
            transcribe(self.project)
        self.assertEqual([call.args[0] for call in ctor.call_args_list], ['medium','base'])
        self.assertTrue(all(call.kwargs['local_files_only'] for call in ctor.call_args_list))

    def test_first_run_still_downloads_only_base(self):
        model = SimpleNamespace(transcribe=self.recognize)
        with patch('faster_whisper.WhisperModel', side_effect=[OSError('not cached'), OSError('not cached'), model]) as ctor:
            transcribe(self.project)
        self.assertEqual(ctor.call_args.args[0], 'base')
        self.assertNotIn('local_files_only', ctor.call_args.kwargs)


if __name__ == '__main__':
    unittest.main()
