"""Release-to-installer handoff, with all build/publication/native commands mocked."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


def load_release():
    spec = importlib.util.spec_from_file_location('release', Path(__file__).parent / 'release.py')
    release = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(release)
    return release


class ReleaseInstallTests(unittest.TestCase):
    def setUp(self):
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'Jot-0.2.14.zip'
        self.archive.write_bytes(b'synthetic final zip')
        self.checksum = self.root / 'Jot-0.2.14.zip.sha256'
        self.checksum.write_text(f'{hashlib.sha256(self.archive.read_bytes()).hexdigest()}  {self.archive.name}\n')
        self.release = load_release()
        self.commands = []

    def install(self):
        self.release.install_packaged_product(self.root / 'scripts/build-install.py', self.archive, self.checksum,
                                             'FIXTURETEAM', '0.2.14', '21', 'a' * 64, {'FIXTURE': 'true'})

    def test_final_zip_handoff_pins_team_version_build_and_executable_hash(self):
        with patch('subprocess.run') as run:
            self.install()
        extract, install = run.call_args_list
        self.assertEqual(extract.args[0][:4], ['ditto', '-x', '-k', str(self.archive)])
        command = install.args[0]
        self.assertEqual(command[:4], [sys.executable, str(self.root / 'scripts/build-install.py'), '--configuration', 'Release'])
        self.assertEqual(command[4], '--product')
        self.assertEqual(Path(command[5]), Path(extract.args[0][4]) / 'Jot.app')
        self.assertEqual(command[6:], ['--expected-team', 'FIXTURETEAM', '--expected-version', '0.2.14',
                                      '--expected-build', '21', '--expected-sha256', 'a' * 64])
        self.assertEqual(install.kwargs['env'], {'FIXTURE': 'true'})
        self.assertFalse(Path(extract.args[0][4]).exists())

    def test_checksum_or_asset_name_mismatch_never_extracts_or_installs(self):
        original = self.checksum.read_text()
        for invalid in (original.replace(self.archive.name, 'Other.zip'), 'b' * 64 + f'  {self.archive.name}\n', ''):
            with self.subTest(invalid=invalid), patch('subprocess.run') as run:
                self.checksum.write_text(invalid)
                with self.assertRaises(SystemExit):
                    self.install()
                run.assert_not_called()
        self.checksum.write_text(original)
        self.archive.write_bytes(b'corrupted after packaging')
        with patch('subprocess.run') as run, self.assertRaises(SystemExit):
            self.install()
        run.assert_not_called()

    def test_extraction_failure_does_not_invoke_installer(self):
        with patch('subprocess.run', side_effect=subprocess.CalledProcessError(1, ['ditto'])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                self.install()
        self.assertEqual(run.call_count, 1)
        self.assertFalse(Path(run.call_args.args[0][4]).exists())

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('ditto'), 'native ditto requires macOS')
    def test_native_ditto_handoff_uses_archived_bytes_after_source_changes(self):
        product = self.root / 'product/Jot.app/Contents/MacOS'
        product.mkdir(parents=True)
        executable = product / 'Jot'
        executable.write_bytes(b'synthetic packaged bytes')
        original = subprocess.run
        original(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(product.parents[1]), str(self.archive)], check=True)
        self.checksum.write_text(f'{hashlib.sha256(self.archive.read_bytes()).hexdigest()}  {self.archive.name}\n')
        executable.write_bytes(b'changed after packaging')
        installer_calls = []

        def run(command, **kwargs):
            if command[0] == 'ditto':
                return original(command, **kwargs)
            installer_calls.append(command)
            extracted = Path(command[command.index('--product') + 1]) / 'Contents/MacOS/Jot'
            self.assertEqual(extracted.read_bytes(), b'synthetic packaged bytes')
            return subprocess.CompletedProcess(command, 0)

        with patch('subprocess.run', side_effect=run):
            self.install()
        self.assertEqual(len(installer_calls), 1)

    def test_fixture_release_builds_once_and_installs_from_the_final_zip(self):
        for directory in ('scripts', 'docs', 'Sources/JotCore', 'Resources', 'build/product/Jot.app/Contents/MacOS'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        (self.root / 'Sources/JotCore/JotVersion.swift').write_text('let current = "0.2.13"\n')
        (self.root / 'project.yml').write_text("CFBundleShortVersionString: '0.2.13'\nCFBundleVersion: '20'\n")
        (self.root / 'Resources/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.2.13', CFBundleVersion='20')))
        product = self.root / 'build/product/Jot.app'
        (product / 'Contents/MacOS/Jot').write_bytes(b'synthetic release executable')
        sha = hashlib.sha256((product / 'Contents/MacOS/Jot').read_bytes()).hexdigest()
        (product / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.2.14', CFBundleVersion='21')))

        def output(command, **kwargs):
            if command[:3] == ['git', 'branch', '--show-current']:
                return 'main'
            if command[:3] == ['git', 'status', '--porcelain']:
                return ''
            if command[:3] == ['git', 'tag', '--list']:
                return '\n'.join(f'v0.0.{i}' for i in range(20)) if command[-1] == 'v*' else ''
            if command[:2] == ['git', 'rev-parse']:
                return 'b' * 40
            if command[:3] == ['gh', 'release', 'view']:
                return 'https://example.invalid/synthetic-release'
            raise AssertionError(command)

        def run(command, **kwargs):
            self.commands.append(command)
            if len(command) > 1 and str(command[1]).endswith('build-install.py'):
                if '--build-only' in command:
                    (self.root / 'build/release-proof.json').write_text(json.dumps(dict(source=str(product), signingTeam='FIXTURETEAM', sha256=sha)))
                else:
                    self.assertIn('--product', command)
                    extracted = Path(command[command.index('--product') + 1])
                    self.assertEqual((extracted / 'Contents/MacOS/Jot').read_bytes(), b'synthetic release executable')
                    self.assertEqual(command[command.index('--expected-sha256') + 1], sha)
            if command[:3] == ['ditto', '-x', '-k']:
                shutil.copytree(product, Path(command[4]) / 'Jot.app')
            elif command[:3] == ['ditto', '-c', '-k']:
                Path(command[-1]).write_bytes(b'synthetic release zip')
            return subprocess.CompletedProcess(command, 0, '', '')

        with patch.object(self.release, '__file__', str(self.root / 'scripts/release.py')), \
                patch.object(sys, 'argv', ['release.py', 'patch', '--notes', 'Synthetic fixture', '--local', '--install']), \
                patch.object(self.release, 'local_signing_configuration', return_value=('Fixture Identity', 'FIXTURETEAM')), \
                patch('subprocess.run', side_effect=run), patch('subprocess.check_output', side_effect=output), \
                contextlib.redirect_stdout(io.StringIO()):
            self.release.main()
        installer_calls = [command for command in self.commands if len(command) > 1 and str(command[1]).endswith('build-install.py')]
        self.assertEqual(len(installer_calls), 2)
        self.assertEqual(sum('--build-only' in command for command in installer_calls), 1)
        self.assertEqual(sum('--product' in command for command in installer_calls), 1)
        extraction = next(command for command in self.commands if command[:3] == ['ditto', '-x', '-k'])
        self.assertEqual(Path(extraction[3]).resolve(), (self.root / 'build/Jot-0.2.14.zip').resolve())
        self.assertFalse(Path(extraction[4]).exists())


if __name__ == '__main__':
    unittest.main()
