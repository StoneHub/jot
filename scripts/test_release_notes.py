"""Release notes come from --notes or the reviewed next.md draft; everything native is mocked."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'Sources/JotCore').mkdir(parents=True)
        (self.root / 'Resources').mkdir()
        (self.root / 'docs/release-notes').mkdir(parents=True)
        (self.root / 'Sources/JotCore/JotVersion.swift').write_text('let current = "0.3.3"\n')
        (self.root / 'project.yml').write_text("CFBundleShortVersionString: '0.3.3'\nCFBundleVersion: '24'\n")
        (self.root / 'Resources/Info.plist').write_text(
            '<key>CFBundleShortVersionString</key><string>0.3.3</string><key>CFBundleVersion</key><string>24</string>')
        self.draft = self.root / 'docs/release-notes/next.md'
        spec = importlib.util.spec_from_file_location('release_notes_fixture', Path(__file__).with_name('release.py'))
        self.release = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.release)
        # main() resolves the repository from its own file; point it at the fixture tree.
        self.release.__file__ = str(self.root / 'scripts/release.py')
        self.written = None

    def fake_output(self, command, **kwargs):
        if command[:2] == ['git', 'branch']:
            return 'main'
        if command[:2] == ['git', 'tag']:
            return 'v0.3.3'
        return ''

    def fake_run(self, command, **kwargs):
        if command[:2] == ['swift', 'test']:
            # Stop at the first build step; the bump and notes are already on disk.
            notes = self.root / 'docs/release-notes/0.3.4.md'
            self.written = notes.read_text() if notes.exists() else None
            self.draft_present = self.draft.exists()
            return subprocess.CompletedProcess(command, 1, '', '')
        return subprocess.CompletedProcess(command, 0, '', '')

    def cut(self, *args):
        with patch.object(sys, 'argv', ['release.py', 'patch', '--local', *args]), \
                patch('subprocess.check_output', side_effect=self.fake_output), \
                patch('subprocess.run', side_effect=self.fake_run), \
                patch.object(self.release, 'local_signing_configuration', return_value=('fixture', 'FIXTURE')), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()), \
                self.assertRaises(SystemExit):
            self.release.main()

    def test_draft_becomes_versioned_notes_and_is_restored_on_failure(self):
        self.draft.write_text('# Jot (next release)\n\nFixed the thing.\n')
        self.cut()
        self.assertEqual(self.written, '# Jot 0.3.4\n\nFixed the thing.\n')
        self.assertFalse(self.draft_present)
        self.assertEqual(self.draft.read_text(), '# Jot (next release)\n\nFixed the thing.\n')
        self.assertFalse((self.root / 'docs/release-notes/0.3.4.md').exists())

    def test_explicit_notes_leave_the_draft_alone(self):
        self.draft.write_text('# Jot (next release)\n\nDraft.\n')
        self.cut('--notes', 'Typed notes.')
        self.assertEqual(self.written, '# Jot 0.3.4\n\nTyped notes.\n')
        self.assertTrue(self.draft_present)

    def test_missing_or_empty_notes_stop_before_any_change(self):
        for draft in (None, '# Jot (next release)\n\n'):
            with self.subTest(draft=draft):
                if draft is None:
                    self.draft.unlink(missing_ok=True)
                else:
                    self.draft.write_text(draft)
                self.cut()
                self.assertIsNone(self.written)
                self.assertIn('0.3.3', (self.root / 'project.yml').read_text())


if __name__ == '__main__':
    unittest.main()
