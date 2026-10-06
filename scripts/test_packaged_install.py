"""Synthetic bundle checks; no build, signing identity lookup, or live installation."""
import hashlib
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parent / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PackagedInstallTests(unittest.TestCase):
    def setUp(self):
        previous = Path.cwd()
        self.addCleanup(os.chdir, previous)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.app = self.base / 'package/Jot.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Helpers').mkdir()
        (self.app / 'Contents/MacOS/Jot').write_bytes(b'synthetic packaged executable')
        (self.app / 'Contents/Helpers/jot').write_bytes(b'synthetic helper')
        self.info = dict(CFBundleIdentifier='space.jot.app', CFBundleExecutable='Jot',
                         CFBundleShortVersionString='0.2.14', CFBundleVersion='21')
        self.write_info()
        self.sha = hashlib.sha256((self.app / 'Contents/MacOS/Jot').read_bytes()).hexdigest()
        self.args = ['--configuration', 'Release', '--product', str(self.app),
                     '--expected-team', 'FIXTURETEAM', '--expected-version', '0.2.14',
                     '--expected-build', '21', '--expected-sha256', self.sha, '--build-only']
        self.installer = load_script('build-install')
        self.installer.work = self.base / 'work'
        self.installer.work.mkdir()
        self.destination = self.base / 'installed/Jot.app'
        self.destination.parent.mkdir()
        shutil.copytree(self.app, self.destination)
        (self.destination / 'Contents/MacOS/Jot').write_bytes(b'previous executable')
        self.expected = dict(version='0.2.14', build='21', sha256=self.sha)
        self.current = dict(microphoneRunning=False, queuedAudioSeconds=0, models='ready',
                            resources=dict(processID=9876))
        self.commands = []
        self.run = patch('subprocess.run', side_effect=self.fake_run).start()
        self.addCleanup(patch.stopall)
        self.output = patch('subprocess.check_output', side_effect=self.fake_output).start()
        patch.object(self.installer.Path, 'home', return_value=self.base / 'home').start()
        patch('os.kill', side_effect=lambda pid, sig: (_ for _ in ()).throw(ProcessLookupError()) if sig == 0 else None).start()
        patch('time.sleep').start()
        self.stdout = contextlib.redirect_stdout(io.StringIO())
        self.stdout.__enter__()
        self.addCleanup(self.stdout.__exit__, None, None, None)

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def fake_run(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == 'ditto':
            shutil.copytree(command[1], command[2])
        if command[-1] == 'status':
            return subprocess.CompletedProcess(command, 0, json.dumps(dict(result=self.current)), '')
        return subprocess.CompletedProcess(command, 0, '', 'TeamIdentifier=FIXTURETEAM\n')

    def fake_output(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == 'codesign':
            return plistlib.dumps({})
        if command[0] == 'ps':
            return str(self.destination / 'Contents/MacOS/Jot')
        raise AssertionError(command)

    def install(self):
        self.installer.install_product(self.app, self.destination, 'Release', 'FIXTURETEAM', self.expected)

    def assert_previous(self):
        self.assertEqual((self.destination / 'Contents/MacOS/Jot').read_bytes(), b'previous executable')

    def test_installed_executable_matches_packaged_hash_and_launch_identity(self):
        self.install()
        self.assertEqual(hashlib.sha256((self.destination / 'Contents/MacOS/Jot').read_bytes()).hexdigest(), self.sha)
        proof = json.loads((self.installer.work / 'install-proof.json').read_text())
        self.assertEqual(proof['sha256'], self.sha)
        self.assertEqual(proof['version'], '0.2.14')
        self.assertEqual(proof['build'], '21')
        self.assertEqual(proof['running'], str(self.destination / 'Contents/MacOS/Jot'))
        self.assertFalse(list((self.installer.work / 'app-backups.noindex').rglob('Jot.app')))

    def test_invalid_product_cannot_stop_runtime_or_replace_bundle(self):
        changes = [('CFBundleIdentifier', 'other.app'), ('CFBundleExecutable', '../Jot'),
                   ('CFBundleShortVersionString', '0.2.13'), ('CFBundleVersion', '20')]
        for key, value in changes:
            with self.subTest(key=key), patch('os.kill') as kill:
                original = self.info[key]
                self.info[key] = value
                self.write_info()
                with self.assertRaises(SystemExit):
                    self.install()
                kill.assert_not_called()
                self.assert_previous()
                self.info[key] = original
                self.write_info()
        (self.app / 'Contents/MacOS/Jot').write_bytes(b'changed after packaging')
        with patch('os.kill') as kill, self.assertRaises(SystemExit):
            self.install()
        kill.assert_not_called()
        self.assert_previous()

    def test_missing_helper_is_rejected_before_replacement(self):
        (self.app / 'Contents/Helpers/jot').unlink()
        with self.assertRaises(SystemExit):
            self.install()
        self.assert_previous()

    def test_team_and_signature_failures_refuse_before_stopping_runtime(self):
        for failure in ('team', 'signature', 'entitlements'):
            with self.subTest(failure=failure), patch('os.kill') as kill:
                def reject(command, **kwargs):
                    if failure == 'team' and command[:2] == ['codesign', '-dv']:
                        return subprocess.CompletedProcess(command, 0, '', 'TeamIdentifier=OTHERTEAM\n')
                    if failure == 'signature' and command[:2] == ['codesign', '--verify']:
                        raise subprocess.CalledProcessError(1, command)
                    return self.fake_run(command, **kwargs)
                self.run.side_effect = reject
                self.output.side_effect = (lambda command, **kwargs: plistlib.dumps({'com.apple.security.get-task-allow': True})) if failure == 'entitlements' else self.fake_output
                with self.assertRaises((SystemExit, subprocess.CalledProcessError)):
                    self.install()
                kill.assert_not_called()
                self.assert_previous()
        self.run.side_effect = self.fake_run
        self.output.side_effect = self.fake_output

    def test_active_capture_or_pending_work_refuses_replacement(self):
        states = [dict(microphoneRunning=True), dict(queuedAudioSeconds=1), dict(inferenceRunning=True),
                  dict(models='preparing'), dict(models='unloading'), dict(servicePhase='pausing'),
                  dict(storageWorkPending=1), dict(speakerPassRunning=True), dict(speakerPassPending=True),
                  dict(dictationRecovery=dict(attemptPending=True)),
                  dict(dictationRecovery=dict(recoveryRunning=True)),
                  dict(dictationRecovery=dict(cleanupPending=1))]
        original = self.current.copy()
        for state in states:
            with self.subTest(state=state), patch('os.kill') as kill:
                self.current = dict(original, **state)
                with self.assertRaises(SystemExit):
                    self.install()
                kill.assert_not_called()
                self.assert_previous()

    def test_unknown_idle_state_and_wrong_runtime_refuse_replacement(self):
        self.run.side_effect = lambda command, **kwargs: (subprocess.CompletedProcess(command, 1, '', '')
                                                        if command[-1] == 'status' else self.fake_run(command, **kwargs))
        with self.assertRaises(SystemExit):
            self.install()
        self.assert_previous()
        self.run.side_effect = self.fake_run
        self.output.side_effect = lambda command, **kwargs: '/other/Jot' if command[0] == 'ps' else self.fake_output(command, **kwargs)
        with patch('os.kill') as kill, self.assertRaises(SystemExit):
            self.install()
        kill.assert_not_called()
        self.assert_previous()

    def test_failed_copy_or_destination_verification_restores_previous_bundle(self):
        for failure in ('copy', 'hash', 'signature', 'team', 'helper'):
            with self.subTest(failure=failure):
                def corrupt(command, **kwargs):
                    if command[0] == 'ditto':
                        shutil.copytree(command[1], command[2])
                        if failure == 'copy':
                            raise subprocess.CalledProcessError(1, command)
                        if failure == 'hash':
                            (self.destination / 'Contents/MacOS/Jot').write_bytes(b'corrupt copy')
                        if failure == 'helper':
                            (self.destination / 'Contents/Helpers/jot').unlink()
                        return subprocess.CompletedProcess(command, 0)
                    if str(self.destination) in command and failure == 'signature' and command[:2] == ['codesign', '--verify']:
                        raise subprocess.CalledProcessError(1, command)
                    if str(self.destination) in command and failure == 'team' and command[:2] == ['codesign', '-dv']:
                        return subprocess.CompletedProcess(command, 0, '', 'TeamIdentifier=OTHERTEAM\n')
                    return self.fake_run(command, **kwargs)
                self.run.side_effect = corrupt
                with self.assertRaises((SystemExit, subprocess.CalledProcessError)):
                    self.install()
                self.assert_previous()
                self.assertFalse((self.installer.work / 'install-proof.json').exists())

    def test_launch_failure_retains_backup_without_claiming_success(self):
        def unavailable(command, **kwargs):
            if command[-1] == 'status' and (self.destination / 'Contents/MacOS/Jot').read_bytes() != b'previous executable':
                return subprocess.CompletedProcess(command, 1, '', '')
            return self.fake_run(command, **kwargs)
        self.run.side_effect = unavailable
        with self.assertRaises(SystemExit):
            self.install()
        backups = list((self.installer.work / 'app-backups.noindex').rglob('Contents/MacOS/Jot'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), b'previous executable')
        self.assertFalse((self.installer.work / 'install-proof.json').exists())

    def test_product_arguments_cannot_silently_fall_back_to_build(self):
        for args in (['--product', str(self.app)], ['--expected-team', 'FIXTURETEAM'],
                     [*self.args[:-2], 'invalid', '--build-only']):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit), patch.object(self.installer, 'build_product') as build:
                self.installer.main(args)
            build.assert_not_called()

    def test_product_verification_does_not_build_or_read_signing_identities(self):
        with patch.object(sys, 'argv', ['build-install.py', *self.args]), \
                patch('subprocess.run') as run, patch('subprocess.check_output') as output, \
                patch('signing.local_signing_configuration', side_effect=AssertionError('identity lookup')):
            run.return_value = subprocess.CompletedProcess([], 0, '', 'TeamIdentifier=FIXTURETEAM\n')
            output.return_value = plistlib.dumps({})
            installer = load_script('build-install')
            installer.work = self.base / 'work'
            installer.main(self.args)
        commands = [call.args[0] for call in run.call_args_list + output.call_args_list]
        self.assertFalse(any(command[0] in ('xcodebuild', 'xcodegen', 'xcode-select', 'security', 'open', 'ditto')
                             for command in commands))
        self.assertTrue(any(command[:2] == ['codesign', '--verify'] for command in commands))


if __name__ == '__main__':
    unittest.main()
