"""The synthetic lab set: seeded lines, exact captions, the four script conditions; `say` is replaced by a tone writer."""
import importlib.util
import json
import math
from pathlib import Path
import random
import tempfile
import unittest
import wave

SOURCE = Path(__file__).with_name('make-lab-set.py')
spec = importlib.util.spec_from_file_location('make_lab_set', SOURCE)
make = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make)


def fake_say(text, voice, rate, path):
    """0.2 s of a voice-specific tone per word, so lengths follow the text and voices can be told apart."""
    frequency = 200 + 50 * (sum(map(ord, voice)) % 7)
    count = int(0.2 * make.RATE) * len(text.split())
    make.write_wav(path, [0.3 * math.sin(2 * math.pi * frequency * index / make.RATE) for index in range(count)])


def frames(path):
    with wave.open(str(path), 'rb') as file:
        return file.getnframes()


class LinesTests(unittest.TestCase):
    def test_script_splits_into_its_sentences(self):
        lines = make.sentences(make.SCRIPT)
        self.assertEqual(len(lines), 40)
        self.assertEqual(sum(len(line.split()) for line in lines), 442)
        self.assertTrue(all(line.endswith('.') for line in lines))

    def test_conversation_is_seeded_changes_speaker_every_turn_and_uses_all_four(self):
        first = make.conversation_lines(random.Random(7), 400)
        again = make.conversation_lines(random.Random(7), 400)
        other = make.conversation_lines(random.Random(8), 400)
        self.assertEqual(first, again)
        self.assertNotEqual(first, other)
        self.assertGreaterEqual(sum(len(text.split()) for _, text in first), 400)
        self.assertEqual({speaker for speaker, _ in first}, set(make.SPEAKERS))
        self.assertTrue(all(a != b for (a, _), (b, _) in zip(first, first[1:])))
        self.assertNotIn('{', ' '.join(text for _, text in first), 'every template field is filled')

    def test_voices_come_from_the_preferred_list_in_order_or_the_script_stops(self):
        voices = make.choose_voices({'Fred', 'Karen', 'Alex', 'Daniel', 'Samantha', 'Zarvox'})
        self.assertEqual(list(voices.values()), ['Samantha', 'Daniel', 'Karen', 'Fred'])
        with self.assertRaises(SystemExit):
            make.choose_voices({'Samantha', 'Daniel'})


class AudioTests(unittest.TestCase):
    def test_wav_round_trip_and_clipping(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'a.wav'
            make.write_wav(path, [0.5, -0.5, 1.5, -1.5, 0.0])
            samples = make.read_wav(path)
        self.assertEqual(len(samples), 5)
        self.assertAlmostEqual(samples[0], 0.5, places=3)
        self.assertAlmostEqual(samples[2], 1.0, places=3)
        self.assertAlmostEqual(samples[3], -1.0, places=3)

    def test_gain_echo_bed_and_noise_keep_lengths_and_levels(self):
        tone = [0.5 * math.sin(2 * math.pi * 440 * i / make.RATE) for i in range(make.RATE)]
        quiet = make.gain(tone, -21)
        self.assertAlmostEqual(max(quiet) / max(tone), 10 ** (-21 / 20), places=4)
        reverb = make.echo(quiet)
        self.assertEqual(len(reverb), len(quiet))
        self.assertEqual(reverb[:100], quiet[:100], 'nothing arrives before the first tap')
        self.assertGreater(max(map(abs, reverb)), max(map(abs, quiet)))
        bed = make.tone_bed(make.RATE)
        self.assertEqual(len(bed), make.RATE)
        self.assertLess(max(map(abs, bed)), 0.013)
        noise = make.pink_noise(make.RATE, 0.004, random.Random(1))
        self.assertEqual(noise, make.pink_noise(make.RATE, 0.004, random.Random(1)), 'seeded')
        rms = math.sqrt(sum(v * v for v in noise) / len(noise))
        self.assertTrue(0.001 < rms < 0.02, rms)
        room = make.mix(reverb, bed, noise)
        self.assertEqual(len(room), make.RATE)


class SetTests(unittest.TestCase):
    def test_build_writes_five_items_with_exact_captions_and_tagged_voices(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            installed = set(make.PREFERRED_VOICES)
            manifest = make.build_set(folder, minutes=0.5, seed=7, speak=fake_say, installed=installed)
            self.assertEqual(json.loads((folder / 'set.json').read_text()), manifest)
            self.assertEqual([item['name'] for item in manifest['items']],
                             ['script-clean', 'script-quiet', 'script-reverb', 'script-room', 'conversation'])
            self.assertFalse((folder / '.scratch').exists())
            for item in manifest['items']:
                self.assertTrue((folder / item['audio']).is_file(), item)
                self.assertTrue((folder / item['captions']).is_file(), item)
            # Every script condition is the same length: 442 words at 0.2 s, each of the 40 sentences followed by a 0.35 s gap.
            lengths = {frames(folder / f'{name}.wav') for name in ('script-clean', 'script-quiet', 'script-reverb', 'script-room')}
            self.assertEqual(lengths, {442 * int(0.2 * make.RATE) + 40 * int(0.35 * make.RATE)})
            script = (folder / 'script.vtt').read_text()
            self.assertTrue(script.startswith('WEBVTT\n\n00:00:00.000 --> '))
            self.assertEqual(script.count('-->'), 40)
            self.assertNotIn('<v ', script, 'one voice: no speaker scoring')
            conversation = (folder / 'conversation.vtt').read_text()
            cues = [line for line in conversation.splitlines() if '-->' in line]
            self.assertGreater(len(cues), 5)
            self.assertEqual({line.split('>')[0] for line in conversation.splitlines() if line.startswith('<v ')},
                             {f'<v {speaker}' for speaker in make.SPEAKERS})
            last_end = cues[-1].split('--> ')[1]
            hours, minutes, seconds = last_end.split(':')
            self.assertLessEqual(float(seconds) + 60 * int(minutes), frames(folder / 'conversation.wav') / make.RATE)
            self.assertEqual(manifest['generator']['voices'], dict(zip(make.SPEAKERS, make.PREFERRED_VOICES[:4])))

    def test_the_same_seed_gives_the_same_captions(self):
        texts = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as folder:
                make.build_set(folder, minutes=0.3, seed=3, speak=fake_say, installed=set(make.PREFERRED_VOICES), script=False)
                texts.append((Path(folder) / 'conversation.vtt').read_text())
        self.assertEqual(texts[0], texts[1])


if __name__ == '__main__':
    unittest.main()
