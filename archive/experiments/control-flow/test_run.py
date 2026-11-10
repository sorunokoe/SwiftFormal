import copy
import subprocess
import unittest
from unittest.mock import patch

import cases
import run


def positive_phases():
    return {name: {"verdict": {"status": status}} for name, status in run.SUCCESS.items()}


class ExperimentTests(unittest.TestCase):
    def test_selected_batch_keeps_the_baseline_and_rejects_unknown_cases(self):
        inventory = [("original",), ("guard",), ("diamonds-1",)]
        self.assertEqual(run.select_inventory(inventory, []), inventory)
        self.assertEqual(
            run.select_inventory(inventory, ["diamonds-1"]),
            [("original",), ("diamonds-1",)],
        )
        with self.assertRaisesRegex(ValueError, "Unknown"):
            run.select_inventory(inventory, ["missing"])

    def test_partial_success_is_not_a_full_proof(self):
        phases = positive_phases()
        self.assertEqual(run.assess("ordinary", phases, set()), "PROVED")
        phases["full"]["verdict"] = {"status": "LIMIT"}
        self.assertEqual(run.assess("growth", phases, set()), "UNKNOWN")
        with self.assertRaises(RuntimeError):
            run.assess("ordinary", phases, set())
        del phases["full"]
        with self.assertRaisesRegex(RuntimeError, "Missing"):
            run.assess("growth", phases, set())

    def test_seeded_defect_must_fail_at_its_return_not_the_infrastructure(self):
        phases = positive_phases()
        for name in ("model", "full"):
            phases[name]["verdict"] = {"status": "UNPROVED", "failed_obligations": ["return_1"]}
        self.assertEqual(run.assess("seeded", phases, {"return_1"}), "REJECTED")
        for failed in ([], ["SILInput.decoding"]):
            changed = copy.deepcopy(phases)
            changed["full"]["verdict"]["failed_obligations"] = failed
            with self.assertRaisesRegex(RuntimeError, "outside"):
                run.assess("seeded", changed, {"return_1"})
        with self.assertRaises(RuntimeError):
            run.assess("seeded", positive_phases(), {"return_1"})

    def test_only_a_real_timeout_becomes_a_limit(self):
        commands = []
        source = "import Lean\n"

        def timeout():
            commands.append({"stdin_sha256": run.policy.digest_bytes(source.encode()), "elapsed_seconds": 60})
            try:
                raise subprocess.TimeoutExpired("lean", 60)
            except subprocess.TimeoutExpired as error:
                raise run.policy.CheckFailure("TOOL ERROR", str(error)) from error

        with patch.object(run.time, "monotonic", side_effect=[0, 61]):
            measured = run.measure(timeout, commands, source)
        self.assertEqual(measured["verdict"]["status"], "LIMIT")
        self.assertEqual(measured["lean_seconds"], 60)
        self.assertEqual(measured["overhead_seconds"], 1)

        def missing_tool():
            raise run.policy.CheckFailure("TOOL ERROR", "No such file")

        with self.assertRaises(run.policy.CheckFailure):
            run.measure(missing_tool, [], source)
        phases = positive_phases()
        phases["full"]["verdict"]["status"] = "TOOL ERROR"
        with self.assertRaises(RuntimeError):
            run.assess("growth", phases, set())

    def test_fixtures_preserve_other_functions_and_reject_a_changed_baseline(self):
        original = (run.base.BRIDGE / "Fixture.swift").read_text()
        rest = original.partition("\n\n")[2]
        for body in cases.ordinary().values():
            self.assertEqual(cases.fixture(original, body).partition("\n\n")[2], rest)
        for original in ("", original.replace("return 0", "return 1", 1)):
            with self.assertRaisesRegex(ValueError, "selected function changed"):
                cases.fixture(original, "return 0")


if __name__ == "__main__":
    unittest.main()
