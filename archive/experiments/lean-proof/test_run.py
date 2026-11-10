import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class BootstrapTests(unittest.TestCase):
    def test_missing_version_replaces_previous_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ("run.py", "check.py"):
                shutil.copyfile(Path(__file__).parent / name, root / name)
            output = root / "output"
            output.mkdir()
            report_path = output / "report.json"
            report_path.write_text(json.dumps({"status": "passed"}))
            result = subprocess.run(
                [sys.executable, "-B", root / "run.py", "--output", output],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads(report_path.read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("VERSION", report["failure"])


if __name__ == "__main__":
    unittest.main()
