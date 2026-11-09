import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('release-metadata.py').resolve()


class ReleaseMetadataTests(unittest.TestCase):
    def check_case(self, previous, current, notes=True, legacy=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            git('init')
            if legacy:
                (root / 'scripts').mkdir()
                (root / 'scripts/build.sh').write_text('<key>CFBundleShortVersionString</key><string>0.3.14</string>\n<key>CFBundleVersion</key><string>34</string>')
            else:
                (root / 'version.json').write_text(json.dumps(previous))
            git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false', 'commit', '-m', 'Previous release')
            before = git('rev-parse', 'HEAD')
            (root / 'version.json').write_text(json.dumps(current))
            (root / 'CHANGELOG.md').write_text(f"# Changelog\n\n## {current['version']} — Test\n\n- A fix.\n\n## 0.0.1\n\n- Older.\n" if notes else '# Changelog\n')
            output = root / 'outputs'
            result = subprocess.run(['python3', str(SCRIPT)], cwd=root, env={**os.environ, 'BEFORE_SHA': before, 'GITHUB_OUTPUT': str(output)}, capture_output=True, text=True)
            return result.returncode, output.read_text() if output.exists() else '', (root / 'release-notes.txt').read_text() if (root / 'release-notes.txt').exists() else ''

    def test_initial_migration(self):
        code, output, notes = self.check_case(None, {'version': '0.3.15', 'build': 35}, legacy=True)
        self.assertEqual(code, 0)
        self.assertIn('changed=true', output)
        self.assertIn('G-Clip-0.3.15-arm64.zip', notes)
        self.assertNotIn('Older', notes)

    def test_unchanged_version_skips_release(self):
        value = {'version': '0.3.15', 'build': 35}
        code, output, notes = self.check_case(value, value)
        self.assertEqual(code, 0)
        self.assertIn('changed=false', output)
        self.assertEqual(notes, '')

    def test_new_version(self):
        code, output, _ = self.check_case({'version': '0.3.15', 'build': 35}, {'version': '0.3.16', 'build': 36})
        self.assertEqual(code, 0)
        self.assertIn('changed=true', output)

    def test_invalid_bumps_rejected(self):
        for current in [{'version': '0.3.14', 'build': 36}, {'version': '0.3.16', 'build': 35}, {'version': 'invalid', 'build': 36}, {'version': '0.3.16', 'build': True}]:
            with self.subTest(current=current):
                code, _, _ = self.check_case({'version': '0.3.15', 'build': 35}, current)
                self.assertNotEqual(code, 0)

    def test_missing_notes_rejected(self):
        code, _, _ = self.check_case({'version': '0.3.15', 'build': 35}, {'version': '0.3.16', 'build': 36}, notes=False)
        self.assertNotEqual(code, 0)


if __name__ == '__main__':
    unittest.main()
