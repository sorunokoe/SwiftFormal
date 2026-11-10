import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import verify


class VerificationTests(unittest.TestCase):
    def test_packaged_interpreter_must_match_current_source(self):
        with (
            patch.object(verify.policy, "read_bundle", return_value={"referenceSHA256": "wrong"}),
            self.assertRaises(verify.policy.CheckFailure) as failure,
        ):
            verify.generate("emitter", "collection", "fixtures", "contract", [])
        self.assertEqual(failure.exception.status, "INVALID EVIDENCE")
        self.assertIn("reference interpreter", str(failure.exception))

    def test_translation_success_is_not_reported_as_contract_success(self):
        for translation_only, expected in [(True, "TRANSLATION VALIDATED"), (False, "IR CONTRACT PROVED")]:
            with self.subTest(translation_only=translation_only):
                with patch.object(verify.policy, "verify", return_value={"status": "MODEL PROVED"}) as checked:
                    result = verify.check("emitter", "collection", "fixtures", "contract", "bundle", None, [],
                                          translation_only=translation_only)
                self.assertEqual(result["status"], expected)
                self.assertEqual(checked.call_args.kwargs["proof_key"], "translation" if translation_only else "proof")
                self.assertIn(verify.REFERENCE, checked.call_args.kwargs["identity_paths"])

    def test_missing_version_invalidates_previous_experiment_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "translation-validation"
            root.mkdir()
            previous = root.parent / "lean-proof"
            previous.mkdir()
            shutil.copyfile(verify.ROOT.parent / "lean-proof" / "check.py", previous / "check.py")
            for name in ("run.py", "verify.py"):
                shutil.copyfile(verify.ROOT / name, root / name)
            output = root / "output"
            output.mkdir()
            (output / "report.json").write_text(json.dumps({"status": "passed"}))
            result = subprocess.run(
                [sys.executable, "-B", root / "run.py", "--output", output],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("VERSION", report["failure"])


if __name__ == "__main__":
    unittest.main()
