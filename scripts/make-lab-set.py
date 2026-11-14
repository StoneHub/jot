#!/usr/bin/env python3
"""Make the synthetic lab set for `jot lab --set`: seeded, from macOS `say`, nothing played aloud, nothing private.

The set holds the #215 script in four conditions (clean, quiet, reverb, room) and a seeded conversation between four
voices with WebVTT voice tags, so `jot lab` can score words and speakers. The same seed on the same Mac regenerates the
same files, so the set never has to enter the repository. Write it outside any git checkout:

    python3 scripts/make-lab-set.py ~/Documents/jot-lab/sets/synthetic --minutes 10
"""
import argparse
import array
import json
import math
from pathlib import Path
import random
import shutil
import struct
import subprocess
import sys
import wave

RATE = 16_000
SCRIPT_VOICE = 'Samantha'
SCRIPT_WORDS_PER_MINUTE = 195
CONVERSATION_WORDS_PER_MINUTE = 180
# Four distinct English voices; the first four that this Mac has are used, in this order.
PREFERRED_VOICES = ('Samantha', 'Daniel', 'Karen', 'Fred', 'Moira', 'Rishi', 'Tessa', 'Alex', 'Kate', 'Oliver')
SPEAKERS = ('Ada', 'Ben', 'Cleo', 'Dev')
# From issue #215: 442 words, one voice.
SCRIPT = (
    "The lighthouse keeper counted seven gulls on the northern rail before breakfast. His daughter painted the rowboat a shade of green that nobody in the village liked. A copper kettle whistled while the radio reported fog over the harbor. The ferry captain refused to leave until the mail sacks were dry. Three fishermen argued about the price of herring at the market stall. A violin teacher walked past the bakery humming an old waltz. The mayor promised a new bridge but the river kept rising every spring. Children chased a striped kite across the wet sand near the pier. The postman delivered a parcel wrapped in brown paper and blue string. An old clock in the church tower stopped at a quarter past nine. The schoolmaster wrote long division problems on a dusty blackboard. A farmer brought a wagon of turnips and cabbages to the square. The blacksmith hammered horseshoes while his apprentice pumped the bellows. A traveling dentist set up a striped tent beside the fountain. The innkeeper served barley soup with thick slices of rye bread. Two sisters knitted scarves for the sailors before the winter storms. The harbor master raised a yellow flag to warn the small boats. A gray cat slept on the windowsill of the pharmacy all afternoon. The librarian stamped overdue notices with bright purple ink. A carpenter measured the oak beams twice before cutting them once. The baker's oven failed on Tuesday so everyone ate crackers. A geologist collected black pebbles from the cliffs below the chapel. The choir practiced a hymn about lanterns and distant mountains. A pharmacist mixed a syrup of honey, lemon, and peppermint. The tailor stitched brass buttons onto a heavy wool coat. A shepherd counted forty sheep crossing the stone bridge at dusk. The cobbler resoled the mayor's boots with thick leather. A cartographer drew the coastline with a fine silver pen. The orchard owner sold crates of apples to the cider mill. A young pilot flew a yellow biplane low over the fields. The museum curator dusted a skeleton of an ancient whale. A beekeeper wore a white veil while lifting the wooden frames. The watchmaker adjusted a tiny spring with steady tweezers. A sculptor carved a dolphin from a block of pale marble. The fire brigade polished their red engine every Sunday morning. A botanist pressed violets between the pages of a heavy atlas. The telegraph operator tapped out news of the regatta results. A potter shaped twelve bowls before the clay grew too stiff. The night watchman lit the lamps along the crooked harbor road. Finally the lighthouse keeper climbed the tower and wound the great lamp."
)

# Conversation material: a planning meeting, so the words are ordinary and the turns short enough for speaker changes.
TOPICS = ('the harbor survey', 'the bridge repairs', 'the school roof', 'the market schedule', 'the ferry timetable',
          'the winter festival', 'the library catalog', 'the orchard lease', 'the water tower', 'the night watch')
OPENERS = ('Let us start with {topic}.', 'Can we talk about {topic} next?', 'I have an update on {topic}.',
           'Before we move on, {topic} needs a decision.', 'Where did we land on {topic}?')
STATEMENTS = ('The estimate came in at {number} thousand, which is {adj} than last year.',
              'We measured {number} meters along the {place} side and found nothing unusual.',
              'The contractor can start on {day} if the permit arrives by {day2}.',
              'I spoke with {name} and the materials are {adj} to come by this month.',
              'There were {number} complaints last week, mostly about noise after {hour}.',
              'The {place} route takes {number} minutes longer but avoids the flooded road.',
              'We still owe {name} a written answer about the {place} fence.',
              'The old plan assumed {number} volunteers, and we have about half that.',
              'Insurance covers the {place} building but not the sheds behind it.',
              'If the weather holds we can finish the {place} section before {day}.')
QUESTIONS = ('Does that change the budget for {topic}?', 'Who is handling the paperwork for {topic}?',
             'Can {name} cover the {place} shift on {day}?', 'Is {number} enough, or do we need a margin?',
             'Should we ask the council before {day2}?')
REPLIES = ('Agreed.', 'Not yet.', 'I think so.', 'That works for me.', 'Let me check and come back to you.',
           'No, we decided that last month.', 'Yes, if {name} agrees.', 'Probably, but not before {day}.',
           'I would rather wait until {day2}.', 'Fine, put it on the list.')
NAMES = ('Marta', 'Owen', 'Priya', 'Sam', 'Theo', 'Ines')
PLACES = ('north', 'south', 'east', 'west', 'river', 'hill', 'market', 'chapel')
DAYS = ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
HOURS = ('nine', 'ten', 'eleven', 'noon', 'six', 'seven')
ADJECTIVES = ('cheaper', 'dearer', 'easier', 'harder', 'simpler', 'slower')


def sentences(text):
    """Split the script at sentence ends, keeping the punctuation."""
    out, current = [], []
    for word in text.split():
        current.append(word)
        if word.endswith(('.', '?', '!')):
            out.append(' '.join(current))
            current = []
    if current:
        out.append(' '.join(current))
    return out


def conversation_lines(rng, words_wanted):
    """Turns of (speaker name, text) from the templates, seeded, until about `words_wanted` words."""
    def fill(template):
        return template.format(topic=rng.choice(TOPICS), number=rng.randint(3, 90), adj=rng.choice(ADJECTIVES),
                               place=rng.choice(PLACES), day=rng.choice(DAYS), day2=rng.choice(DAYS), name=rng.choice(NAMES),
                               hour=rng.choice(HOURS))
    lines, words, speaker = [], 0, rng.randrange(len(SPEAKERS))
    while words < words_wanted:
        kind = rng.random()
        if kind < 0.15:
            text = fill(rng.choice(OPENERS)) + ' ' + fill(rng.choice(STATEMENTS))
        elif kind < 0.55:
            text = ' '.join(fill(rng.choice(STATEMENTS)) for _ in range(rng.randint(1, 3)))
        elif kind < 0.75:
            text = fill(rng.choice(QUESTIONS))
        else:
            text = fill(rng.choice(REPLIES))
        lines.append((SPEAKERS[speaker], text))
        words += len(text.split())
        speaker = (speaker + rng.randint(1, len(SPEAKERS) - 1)) % len(SPEAKERS)
    return lines


# MARK: audio

def say(text, voice, rate, path):
    """One utterance to a 16 kHz mono 16-bit WAV; `say` never plays when -o is given."""
    subprocess.run(['say', '-v', voice, '-r', str(rate), '-o', str(path), '--data-format=LEI16@16000', text], check=True)


def available_voices():
    listing = subprocess.run(['say', '-v', '?'], capture_output=True, text=True, check=True).stdout
    return {line.split()[0] for line in listing.splitlines() if line.strip()}


def read_wav(path):
    with wave.open(str(path), 'rb') as file:
        if file.getframerate() != RATE or file.getnchannels() != 1 or file.getsampwidth() != 2:
            raise SystemExit(f'{path} is not 16 kHz mono 16-bit; `say --data-format=LEI16@16000` should have made it so.')
        frames = file.readframes(file.getnframes())
    samples = array.array('h')
    samples.frombytes(frames)
    return [value / 32768.0 for value in samples]


def write_wav(path, samples):
    clipped = array.array('h', (max(-32768, min(32767, int(round(value * 32767)))) for value in samples))
    with wave.open(str(path), 'wb') as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(RATE)
        file.writeframes(clipped.tobytes())


def gain(samples, db):
    factor = 10 ** (db / 20)
    return [value * factor for value in samples]


def echo(samples, taps=((0.023, 0.5), (0.047, 0.4), (0.079, 0.3), (0.113, 0.2))):
    """The #215 reverb: four delayed copies added in, the same length as the input."""
    out = list(samples)
    for delay, level in taps:
        offset = int(delay * RATE)
        for index in range(offset, len(samples)):
            out[index] += level * samples[index - offset]
    return out


def tone_bed(count, amplitude=0.004):
    """Three low tones with a slow 2 Hz swell, as a fan or fridge hum."""
    two_pi = 2 * math.pi
    return [amplitude * (math.sin(two_pi * 220 * t) + math.sin(two_pi * 277 * t) + math.sin(two_pi * 330 * t)) * (0.6 + 0.4 * math.sin(two_pi * 2 * t))
            for t in (index / RATE for index in range(count))]


def pink_noise(count, amplitude, rng):
    """Paul Kellet's pink filter over seeded white noise, scaled to the asked amplitude."""
    b0 = b1 = b2 = b3 = b4 = b5 = b6 = 0.0
    out = []
    for _ in range(count):
        white = rng.uniform(-1, 1)
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        out.append((b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11)
        b6 = white * 0.115926
    return [value * amplitude / 0.11 for value in out]


def mix(*tracks):
    length = max(len(track) for track in tracks)
    return [sum(track[index] for track in tracks if index < len(track)) for index in range(length)]


# MARK: lines to audio and captions

def synthesize(lines, voices, rate, gap, speak, rng=None):
    """Each (speaker, text) said on its own, joined with `gap` seconds of silence (jittered when `rng` is given);
    returns the samples and one cue per line with exact times."""
    samples, cues = [], []
    scratch = Path(voices['_scratch'])
    for index, (speaker, text) in enumerate(lines):
        path = scratch / f'line-{index}.wav'
        speak(text, voices[speaker], rate, path)
        line = read_wav(path)
        path.unlink()
        start = len(samples) / RATE
        samples.extend(line)
        cues.append(dict(start=start, end=len(samples) / RATE, speaker=speaker, text=text))
        pause = gap if rng is None else gap * rng.uniform(0.6, 1.6)
        samples.extend([0.0] * int(pause * RATE))
    return samples, cues


def clock(seconds):
    minutes, rest = divmod(seconds, 60)
    hours, minutes = divmod(int(minutes), 60)
    return f'{hours:02d}:{minutes:02d}:{rest:06.3f}'


def webvtt(cues, voice_tags):
    lines = ['WEBVTT', '']
    for cue in cues:
        lines.append(f'{clock(cue["start"])} --> {clock(cue["end"])}')
        lines.append(f'<v {cue["speaker"]}>{cue["text"]}' if voice_tags else cue['text'])
        lines.append('')
    return '\n'.join(lines)


def choose_voices(installed):
    chosen = [voice for voice in PREFERRED_VOICES if voice in installed][:len(SPEAKERS)]
    if len(chosen) < len(SPEAKERS):
        raise SystemExit(f'Need {len(SPEAKERS)} of these voices installed (System Settings → Accessibility → Spoken Content → '
                         f'System voice → Manage voices): {", ".join(PREFERRED_VOICES)}. Found {", ".join(sorted(chosen)) or "none"}.')
    return dict(zip(SPEAKERS, chosen))


def build_set(folder, minutes, seed, speak=say, installed=None, script=True, conversation=True):
    """Writes the set into `folder` and returns the manifest."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    scratch = folder / '.scratch'
    scratch.mkdir(exist_ok=True)
    rng = random.Random(seed)
    items = []
    try:
        if script:
            voices = {SCRIPT_VOICE: SCRIPT_VOICE, '_scratch': str(scratch)}
            lines = [(SCRIPT_VOICE, sentence) for sentence in sentences(SCRIPT)]
            clean, cues = synthesize(lines, voices, SCRIPT_WORDS_PER_MINUTE, 0.35, speak)
            (folder / 'script.vtt').write_text(webvtt(cues, voice_tags=False))
            quiet = gain(clean, -21)                     # a laptop microphone across a room
            reverb = echo(quiet)
            room = mix(reverb, tone_bed(len(reverb)), pink_noise(len(reverb), 0.004, random.Random(seed + 1)))
            for name, samples in (('script-clean', clean), ('script-quiet', quiet), ('script-reverb', reverb), ('script-room', room)):
                write_wav(folder / f'{name}.wav', samples)
                items.append(dict(name=name, audio=f'{name}.wav', captions='script.vtt'))
        if conversation:
            voices = choose_voices(installed if installed is not None else available_voices())
            voices['_scratch'] = str(scratch)
            lines = conversation_lines(rng, int(minutes * CONVERSATION_WORDS_PER_MINUTE * 0.85))
            samples, cues = synthesize(lines, voices, CONVERSATION_WORDS_PER_MINUTE, 0.5, speak, rng)
            write_wav(folder / 'conversation.wav', samples)
            (folder / 'conversation.vtt').write_text(webvtt(cues, voice_tags=True))
            items.append(dict(name='conversation', audio='conversation.wav', captions='conversation.vtt'))
            manifest_voices = {speaker: voices[speaker] for speaker in SPEAKERS}
        else:
            manifest_voices = {}
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    manifest = dict(name='synthetic', generator=dict(script='scripts/make-lab-set.py', seed=seed, minutes=minutes, voices=manifest_voices),
                    items=items)
    (folder / 'set.json').write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('folder', type=Path, help='where to write the set; new or empty, outside any git checkout')
    parser.add_argument('--minutes', type=float, default=10, help='length of the four-voice conversation (default 10; #218 used 30)')
    parser.add_argument('--seed', type=int, default=7)
    parser.add_argument('--script-only', action='store_true', help='only the #215 script items')
    parser.add_argument('--conversation-only', action='store_true', help='only the conversation')
    args = parser.parse_args(argv)
    if sys.platform != 'darwin' or not shutil.which('say'):
        raise SystemExit('The set is made with macOS `say`; run this on the Mac.')
    folder = args.folder.expanduser()
    if folder.exists() and any(child.name != '.DS_Store' for child in folder.iterdir()):
        raise SystemExit(f'{folder} is not empty; choose a new folder.')
    for parent in (folder, *folder.resolve().parents):
        if (parent / '.git').exists():
            raise SystemExit(f'{folder} is inside the git checkout at {parent}; lab sets stay outside the repository.')
    manifest = build_set(folder, args.minutes, args.seed, script=not args.conversation_only, conversation=not args.script_only)
    for item in manifest['items']:
        with wave.open(str(folder / item['audio']), 'rb') as file:
            print(f'{item["name"]}: {file.getnframes() / RATE / 60:.1f} min, captions {item["captions"]}')
    print(f'Wrote {folder / "set.json"}. Score it with: jot lab --set {folder} --out <new folder outside git>')
    return 0


if __name__ == '__main__':
    sys.exit(main())
