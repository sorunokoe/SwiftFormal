import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class RunnerTests(unittest.TestCase):
    def test_missing_version_invalidates_previous_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shutil.copyfile(Path(__file__).with_name("run.py"), root / "run.py")
            output = root / "output"
            output.mkdir()
            (output / "report.json").write_text('{"status": "passed"}\n')
            result = subprocess.run(
                [sys.executable, root / "run.py", "--output", output],
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 1)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("VERSION", report["error"])
            self.assertIn("EXPERIMENT FAILED", result.stderr)


if __name__ == "__main__":
    unittest.main()
