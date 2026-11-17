"""Verify Finder PATH resolution and fail-before-write with unsupported Python."""
import os
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'codex_switch.sh'

class PythonRuntimeTests(unittest.TestCase):
    def test_finder_path_has_tomllib(self):
        source = SCRIPT.read_text()
        bootstrap = source.split('ROOT=', 1)[0]
        result = subprocess.run(['/bin/bash', '-c', bootstrap + '\npython3 -c "import tomllib; print(tomllib.loads(\\\"model_provider = \\\\\\\"main\\\\\\\"\\\")[\\\"model_provider\\\"])"'],
                                env={**os.environ, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'},
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'main')

    def test_invalid_override_fails_before_work(self):
        result = subprocess.run(['/bin/bash', str(SCRIPT), 'magpie', '--dry-run'],
                                env={**os.environ, 'CODEX_SWITCHER_PYTHON': '/nonexistent/python'},
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 69)
        self.assertIn('Python 3.11+', result.stderr)
        self.assertNotIn('检查并启动网关', result.stdout)

if __name__ == '__main__':
    unittest.main()
