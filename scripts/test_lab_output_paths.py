"""Synthetic output-path checks against the exact Swift implementation."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def extract_function(source, name):
    """Balance braces, ignoring Swift strings and comments; never substitute code."""
    start = source.index(f"func {name}(")
    opening = source.index("{", start)
    depth = 0
    position = opening
    state = "code"
    comment_depth = 0
    while position < len(source):
        char = source[position]
        pair = source[position:position + 2]
        if state == "string":
            if char == "\\":
                position += 2
                continue
            if char == '"':
                state = "code"
        elif state == "line":
            if char == "\n":
                state = "code"
        elif state == "block":
            if pair == "/*":
                comment_depth += 1
                position += 2
                continue
            if pair == "*/":
                comment_depth -= 1
                if not comment_depth:
                    state = "code"
                position += 2
                continue
        elif pair == "//":
            state = "line"
            position += 2
            continue
        elif pair == "/*":
            state = "block"
            comment_depth = 1
            position += 2
            continue
        elif char == '"':
            state = "string"
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if not depth:
                return source[start:position + 1]
        position += 1
    raise ValueError(f"Unbalanced function: {name}")


@unittest.skipUnless(shutil.which("swiftc"), "requires the Swift compiler")
class OutputPathTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="jot-output-path-build-")
        cls.addClassCleanup(cls.build.cleanup)
        build = Path(cls.build.name)
        source = (ROOT / "Sources/JotLab/main.swift").read_text()
        exact_function = extract_function(source, "prepareOutput")
        exact_error = (ROOT / "Sources/JotCore/LabError.swift").read_text()
        harness = build / "main.swift"
        harness.write_text(exact_error + "\n" + exact_function + "\n" + r'''
do {
    try prepareOutput(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
''')
        cls.binary = build / "prepare-output"
        compiled = subprocess.run(
            [shutil.which("swiftc"), "-swift-version", "6", str(harness), "-module-cache-path",
             str(build / "module-cache"), "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=120,
        )
        if compiled.returncode:
            raise AssertionError(compiled.stdout + compiled.stderr)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="jot-output-path-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def prepare(self, output):
        return subprocess.run([str(self.binary), str(output)], capture_output=True,
                              text=True, timeout=10)

    def git_directory(self, marker_is_file=False):
        repository = self.root / ("repository-file" if marker_is_file else "repository-dir")
        nested = repository / "nested" / "folder"
        nested.mkdir(parents=True)
        if marker_is_file:
            (repository / ".git").write_text("gitdir: synthetic-worktree-metadata\n")
        else:
            (repository / ".git").mkdir()
        return nested

    def assert_rejected_inside_git(self, output):
        result = self.prepare(output)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("inside the git repository", result.stderr)

    def test_plain_new_directory_is_created(self):
        output = self.root / "plain" / "new"
        result = self.prepare(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(output.is_dir())

    def test_existing_empty_directory_is_accepted(self):
        output = self.root / "empty"
        output.mkdir()
        self.assertEqual(self.prepare(output).returncode, 0)

    def test_ds_store_only_directory_is_accepted(self):
        output = self.root / "empty"
        output.mkdir()
        marker = output / ".DS_Store"
        marker.write_bytes(b"synthetic marker")
        self.assertEqual(self.prepare(output).returncode, 0)
        self.assertEqual(marker.read_bytes(), b"synthetic marker")

    def test_nonempty_directory_is_refused_without_modification(self):
        output = self.root / "nonempty"
        output.mkdir()
        marker = output / "existing.txt"
        marker.write_text("synthetic content")
        result = self.prepare(output)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not empty", result.stderr)
        self.assertEqual(marker.read_text(), "synthetic content")

    def test_direct_nested_git_directory_is_refused(self):
        nested = self.git_directory()
        self.assert_rejected_inside_git(nested)
        output = nested / "not-created"
        self.assert_rejected_inside_git(output)
        self.assertFalse(output.exists())

    def test_file_form_git_marker_is_refused(self):
        self.assert_rejected_inside_git(self.git_directory(marker_is_file=True))

    def test_symlink_to_existing_git_output_is_refused(self):
        for marker_is_file in (False, True):
            with self.subTest(marker_is_file=marker_is_file):
                nested = self.git_directory(marker_is_file)
                alias = self.root / ("alias-file" if marker_is_file else "alias-dir")
                alias.symlink_to(nested, target_is_directory=True)
                self.assert_rejected_inside_git(alias)

    def test_missing_output_below_symlink_into_git_is_refused(self):
        for marker_is_file in (False, True):
            with self.subTest(marker_is_file=marker_is_file):
                nested = self.git_directory(marker_is_file)
                alias = self.root / ("alias-file" if marker_is_file else "alias-dir")
                alias.symlink_to(nested, target_is_directory=True)
                output = alias / "not-created" / "output"
                self.assert_rejected_inside_git(output)
                self.assertFalse((nested / "not-created").exists())

    def test_symlink_to_plain_directory_remains_accepted(self):
        target = self.root / "plain"
        target.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(target, target_is_directory=True)
        self.assertEqual(self.prepare(alias).returncode, 0)
        output = alias / "new" / "output"
        result = self.prepare(output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((target / "new" / "output").is_dir())


if __name__ == "__main__":
    unittest.main()
