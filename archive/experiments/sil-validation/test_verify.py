import copy
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
    def test_byte_encoding_preserves_every_byte_including_boundaries(self):
        raw = bytes(range(256)) * 5 + b"\n//not a selector\n"
        groups = verify.chunks(raw)
        self.assertEqual(b"".join(groups), raw)
        self.assertTrue(all(0 < len(part) <= 512 for part in groups))
        source, count = verify.input_declarations(raw)
        self.assertEqual(count, len(groups))
        for i in range(count):
            self.assertIn(f"theorem step{i} :", source)
            self.assertIn(f"theorem checkedTail{i} :", source)

    def test_raw_mismatch_and_size_limit_are_rejected_before_rendering(self):
        for raw, digest, expected in (
            (b"different", "wrong", "INVALID EVIDENCE"),
            (b"x" * 262145, verify.policy.digest_bytes(b"x" * 262145), "UNSUPPORTED"),
        ):
            with self.subTest(expected=expected), self.assertRaises(verify.policy.CheckFailure) as failure:
                verify.compose({"silSHA256": digest}, raw, "")
            self.assertEqual(failure.exception.status, expected)

    def test_three_success_modes_do_not_overclaim(self):
        for mode, status in verify.STATUSES.items():
            with self.subTest(mode=mode), patch.object(
                verify.policy, "verify", return_value={"status": "MODEL PROVED"},
            ) as checked:
                result = verify.check("emitter", "collection", "fixtures", "contract", "bundle", None, [], mode=mode)
            self.assertEqual(result["status"], status)
            self.assertEqual(checked.call_args.kwargs["proof_key"], mode)
            self.assertIn(verify.READER, checked.call_args.kwargs["identity_paths"])
            self.assertIn(verify.PROPOSALS, checked.call_args.kwargs["identity_paths"])
            self.assertEqual(checked.call_args.kwargs["proof_timeout"], 180)

    def test_composition_keeps_audits_and_does_not_mutate_upstream(self):
        raw = b"sil_stage canonical\n"
        proof = {"source": "import Lean\n", "obligations": [{"name": "prior", "statement": "theorem prior", "kind": "test"}]}
        prior = {
            "version": "0.0.4", "silSHA256": verify.policy.digest_bytes(raw),
            "program": "def program : ReferenceIR.Program := []", "fuel": 1,
            "translation": copy.deepcopy(proof), "proof": copy.deepcopy(proof),
        }
        original = copy.deepcopy(prior)
        result = verify.compose(prior, raw, verify.READER.read_text())
        self.assertEqual(prior, original)
        self.assertEqual(result["handoff"]["expectedTheorems"], ["SwiftFormalV005.decodedProgram"])
        self.assertEqual(result["proof"]["expectedTheorems"][0], "prior")
        self.assertEqual(result["proof"]["expectedTheorems"][-1], "SwiftFormalV005.noTrap")
        self.assertNotIn("theorem totalCorrectness", result["handoff"]["source"])

    def test_missing_version_invalidates_an_old_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "sil-validation"
            root.mkdir()
            for package, names in (
                ("sil-validation", ("verify.py", "run.py", "cases.py")),
                ("translation-validation", ("verify.py",)),
                ("lean-proof", ("check.py",)),
            ):
                target = root.parent / package
                target.mkdir(exist_ok=True)
                for name in names:
                    shutil.copyfile(verify.ROOT.parent / package / name, target / name)
            output = root / "output"
            output.mkdir()
            (output / "report.json").write_text(json.dumps({"status": "passed"}))
            process = subprocess.run(
                [sys.executable, "-B", root / "run.py", "--output", output],
                capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
            report = json.loads((output / "report.json").read_text())
            self.assertEqual(report["status"], "failed")
            self.assertIn("VERSION", report["failure"])


if __name__ == "__main__":
    unittest.main()
