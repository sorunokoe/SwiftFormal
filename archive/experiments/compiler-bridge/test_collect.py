import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent


class CollectorTests(unittest.TestCase):
    def invoke(self, output, *arguments):
        return subprocess.run(
            [sys.executable, str(ROOT / "collect.py"), "--output", str(output), *arguments],
            capture_output=True,
            text=True,
            timeout=120,
        )

    def test_collects_real_compiler_artifacts_and_observations(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = self.invoke(output)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "passed")
            self.assertEqual(len(report["observations"]), 26)
            self.assertEqual(
                {item["mode"] for item in report["observations"]}, {"-Onone", "-O"}
            )
            traps = [
                item for item in report["observations"] if item["kind"] == "expected_trap"
            ]
            self.assertEqual(len(traps), 6)
            self.assertTrue(all(item["returncode"] < 0 for item in traps))
            for name in ["silgen.sil", "sil-onone.sil", "sil-optimized.sil"]:
                self.assertIn("sil_stage", (output / name).read_text())
            for name in ["Fixture.swift", "main.swift"]:
                self.assertEqual(
                    report["source_sha256"][name],
                    hashlib.sha256((ROOT / name).read_bytes()).hexdigest(),
                )
            self.assertIn("compilerVersion", report["target_info"])
            raw = [
                item
                for item in report["observations"]
                if item["operation"] == "raw" and item["inputs"] == ["0", "1"]
            ]
            self.assertEqual([item["stdout"].strip() for item in raw], ["-1", "-1"])
            self.assertNotIn("proved", result.stdout.lower())

    def test_missing_compiler_invalidates_previous_success(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            (output / "report.json").write_text('{"status": "passed"}\n')
            result = self.invoke(output, "--swiftc", str(output / "missing-swiftc"))
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("missing-swiftc", report["error"])
            self.assertIn("EXPERIMENT FAILED", result.stderr)

    def test_changed_body_is_rejected_and_changes_compiler_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            original = (ROOT / "Fixture.swift").read_text()
            fixtures.joinpath("Fixture.swift").write_text(
                original.replace("return subtotal - discount", "return 0", 1)
            )
            shutil.copyfile(ROOT / "main.swift", fixtures / "main.swift")
            output = root / "artifacts"
            result = self.invoke(output, "--fixtures", str(fixtures))
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("clamped(100, 20): expected '80', got '0'", report["error"])
            sil = (output / "sil-onone.sil").read_text()
            body = sil.split("// clampedDiscount(_:_:)", 1)[1].split(
                "} // end sil function", 1
            )[0]
            self.assertNotIn("ssub_with_overflow_Int64", body)
            self.assertEqual((ROOT / "Fixture.swift").read_text(), original)

    def test_normal_failure_exit_is_not_accepted_as_a_trap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            shutil.copyfile(ROOT / "Fixture.swift", fixtures / "Fixture.swift")
            main = (ROOT / "main.swift").read_text().replace(
                'case "increment":\n',
                'case "increment":\n    if a == Int64.max { exit(1) }\n',
                1,
            )
            fixtures.joinpath("main.swift").write_text("import Darwin\n" + main)
            output = root / "artifacts"
            result = self.invoke(output, "--fixtures", str(fixtures))
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("Expected trap signal", report["error"])
            self.assertIn("got exit 1", report["error"])


if __name__ == "__main__":
    unittest.main()
