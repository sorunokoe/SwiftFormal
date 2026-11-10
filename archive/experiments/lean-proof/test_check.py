import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from check import CheckFailure, audit, generate, verify


def message(name, axioms=()):
    detail = (
        f"'{name}' depends on axioms: [{', '.join(axioms)}]"
        if axioms else f"'{name}' does not depend on any axioms"
    )
    return json.dumps({"severity": "information", "data": detail}) + "\n"


class AuditTests(unittest.TestCase):
    def test_accepts_complete_audit_with_only_allowed_axioms(self):
        output = message("Example.witness") + message("Example.total", ["propext", "Quot.sound"])
        result = audit(0, output, "", ["Example.witness", "Example.total"])
        self.assertEqual(result["status"], "MODEL PROVED")
        self.assertEqual(set(result["axioms"]), {"Example.witness", "Example.total"})

    def test_zero_exit_with_missing_or_empty_inventory_is_not_a_proof(self):
        for output, expected in [
            ("", ["Example.total"]),
            (message("Example.witness"), ["Example.witness", "Example.total"]),
            ("", []),
        ]:
            with self.subTest(expected=expected):
                self.assertNotEqual(audit(0, output, "", expected)["status"], "MODEL PROVED")

    def test_rejects_sorry_foreign_and_native_evaluation_axioms(self):
        for axiom in ["sorryAx", "inventedAssumption", "Lean.ofReduceBool"]:
            with self.subTest(axiom=axiom):
                result = audit(0, message("Example.total", [axiom]), "", ["Example.total"])
                self.assertEqual(result["status"], "UNPROVED")
                self.assertIn(axiom, result["reason"])

    def test_rejects_errors_warnings_duplicates_and_unknown_output(self):
        valid = message("Example.total")
        cases = [
            (1, valid, ""),
            (0, valid, "unexpected diagnostic"),
            (0, valid + valid, ""),
            (0, valid + "forged success\n", ""),
            (0, valid + json.dumps({"severity": "error", "data": "proof failed"}), ""),
            (0, valid + json.dumps({"severity": "warning", "data": "unfinished proof"}), ""),
            (0, valid + message("Example.unrequested"), ""),
        ]
        for code, output, stderr in cases:
            with self.subTest(code=code, output=output):
                self.assertNotEqual(audit(code, output, stderr, ["Example.total"])["status"], "MODEL PROVED")


class BindingTests(unittest.TestCase):
    def test_failed_emitter_cannot_supply_a_success_status(self):
        for output in ('{"status":"MODEL PROVED"}', '[]', 'not json'):
            with self.subTest(output=output):
                process = subprocess.CompletedProcess([], 1, output, "")
                with patch("check.execute", return_value=process), self.assertRaises(CheckFailure) as failure:
                    generate("emitter", "collection", "fixtures", "contract", [])
                self.assertEqual(failure.exception.status, "TOOL ERROR")

    def test_modified_proof_is_rejected_before_lean_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "bundle.json"
            bundle.write_text(json.dumps({"proof": {"source": "altered Lean code"}}))
            environment = Mock()
            with (
                patch("check.digest_file", return_value="identity"),
                patch("check.generate", return_value={"proof": {"source": "current generated code"}}),
                self.assertRaises(CheckFailure) as failure,
            ):
                verify("emitter", "collection", "fixtures", "contract", bundle, environment, [])
            self.assertEqual(failure.exception.status, "INVALID EVIDENCE")
            environment.check_source.assert_not_called()


if __name__ == "__main__":
    unittest.main()
