"""Build-output lifecycle checks using a fake Xcode process; no signing or app install."""
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('installer_cleanup', Path(__file__).with_name('build-install.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class BuildCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / 'build'
        self.work.mkdir()
        (self.root / '.git').write_text('gitdir: synthetic linked worktree')
        self.developer = self.root / 'developer'
        (self.developer / 'usr/bin').mkdir(parents=True)
        (self.developer / 'usr/bin/xcodebuild').touch()
        self.conditions = ""
        self.code = 0
        self.cancel = False
        self.waits = 0
        self.terminated_before_cleanup = False
        self.exported = self.work / 'products/Debug/Jot.app'
        self.source = None
        self.derived = None
        for target, value in [('root', self.root), ('work', self.work)]:
            patch.object(installer, target, value).start()
        patch.object(installer, 'local_signing_configuration', return_value=('fixture', 'FIXTURE')).start()
        patch.object(installer, 'verify_product').start()
        patch.object(installer.shutil, 'which', return_value=None).start()
        patch.object(installer.subprocess, 'run', side_effect=self.fake_run).start()
        patch.object(installer.subprocess, 'check_output', side_effect=self.output).start()
        patch.object(installer.subprocess, 'Popen', side_effect=self.process).start()
        patch.object(installer.os, 'killpg', side_effect=self.terminate).start()
        self.addCleanup(patch.stopall)

    def fake_run(self, command, **kwargs):
        if command[0] == 'xcode-select':
            return subprocess.CompletedProcess(command, 0, str(self.developer))
        if command[0] == 'ditto':
            shutil.copytree(command[1], command[2], symlinks=True)
            return subprocess.CompletedProcess(command, 0)
        raise AssertionError(command)

    def process(self, command, **kwargs):
        self.assertTrue(kwargs['start_new_session'])
        self.derived = Path(command[command.index('-derivedDataPath') + 1])
        configuration = command[command.index('-configuration') + 1]
        self.source = self.derived / 'Build/Products' / configuration / 'Jot.app'
        (self.source / 'Contents/MacOS').mkdir(parents=True)
        (self.source / 'Contents/MacOS/Jot').write_bytes(b'verified synthetic product')
        (self.derived / 'intermediate').write_bytes(b'disposable')
        owner = self
        class Process:
            pid = 43210
            def wait(self, timeout=None):
                owner.waits += 1
                if owner.cancel and owner.waits == 1:
                    raise KeyboardInterrupt()
                return owner.code
        return Process()

    def terminate(self, pid, sig):
        self.assertEqual(pid, 43210)
        self.assertTrue(self.derived.exists())
        self.terminated_before_cleanup = True

    def output(self, command, **kwargs):
        if command[0] == 'ps':
            return ''
        return json.dumps([{'target': 'Jot', 'buildSettings': {
            'TARGET_BUILD_DIR': str(self.source.parent), 'FULL_PRODUCT_NAME': 'Jot.app',
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS': self.conditions}}])

    def test_linked_build_removes_intermediates_but_keeps_verified_deliverable(self):
        source, team = installer.build_product('Debug')
        self.assertEqual(source, self.exported)
        self.assertEqual((source / 'Contents/MacOS/Jot').read_bytes(), b'verified synthetic product')
        self.assertFalse(self.derived.exists())
        self.assertEqual(list(self.work.glob('xcode-task-*')), [])

    def test_failed_build_cleans_intermediates_and_preserves_previous_product(self):
        self.exported.mkdir(parents=True)
        (self.exported / 'previous').touch()
        self.code = 27
        with self.assertRaises(subprocess.CalledProcessError):
            installer.build_product('Debug')
        self.assertFalse(self.derived.exists())
        self.assertTrue((self.exported / 'previous').exists())

    def test_cancellation_stops_build_before_removing_its_outputs(self):
        self.cancel = True
        with self.assertRaises(KeyboardInterrupt):
            installer.build_product('Debug')
        self.assertTrue(self.terminated_before_cleanup)
        self.assertEqual(self.waits, 2)
        self.assertFalse(self.derived.exists())

    def test_invalid_release_never_replaces_previous_export(self):
        previous = self.work / 'products/Release/Jot.app'
        previous.mkdir(parents=True)
        (previous / 'sentinel').touch()
        self.conditions = 'DEBUG'
        with self.assertRaises(SystemExit):
            installer.build_product('Release')
        self.assertTrue((previous / 'sentinel').exists())
        self.assertFalse(self.derived.exists())
        self.assertFalse((self.work / 'release-proof.json').exists())

    def test_retained_development_cache_survives(self):
        source, team = installer.build_product('Debug', disposable=False)
        self.assertTrue(self.derived.exists())
        self.assertEqual(source, self.source)
        self.assertFalse(self.exported.exists())

    def test_export_symlink_never_removes_its_target(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (outside / 'sentinel').touch()
        (self.work / 'products').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(SystemExit):
            installer.build_product('Debug')
        self.assertTrue((outside / 'sentinel').exists())
        self.assertFalse(self.derived.exists())


if __name__ == '__main__':
    unittest.main()
