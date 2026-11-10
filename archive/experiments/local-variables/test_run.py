from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run


class ExperimentTests(unittest.TestCase):
    def test_setup_failures_invalidate_previous_success_before_running_tools(self):
        for failure in ("missing-version", "changed-contract"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                output = root / "output"
                output.mkdir()
                report = output / "report.json"
                report.write_text(json.dumps({"status": "passed"}))
                contract = root / "contract.json"
                contract.write_text("{}")
                if failure == "changed-contract":
                    (root / "VERSION").write_text("0.0.6\n")
                with (
                    patch.object(run, "ROOT", root),
                    patch.object(run, "CONTRACT", contract),
                    patch.object(run.sys, "argv", ["run.py", "--output", str(output)]),
                    patch.object(run.policy, "execute") as execute,
                    redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(run.main(), 1)
                execute.assert_not_called()
                result = json.loads(report.read_text())
                self.assertEqual(result["status"], "failed")
                self.assertIn(
                    "VERSION" if failure == "missing-version" else "approved contract changed",
                    result["failure"],
                )

    def test_ambiguous_or_missing_return_is_not_silently_refactored(self):
        for source in ("return 0\n", "    return subtotal - discount\n" * 2):
            with self.subTest(source=source), self.assertRaisesRegex(RuntimeError, "exactly one"):
                run.variants(source)


if __name__ == "__main__":
    unittest.main()
