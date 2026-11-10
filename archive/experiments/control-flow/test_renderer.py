from pathlib import Path
import shutil
import sys
import tempfile
import unittest

import cases
import run


class RendererRegressionTests(unittest.TestCase):
    def test_repeated_branch_conditions_produce_a_checked_contract_proof(self):
        artifacts = run.ROOT / ".artifacts"
        artifacts.mkdir(exist_ok=True)
        commands = []

        def execute(argv):
            result = run.policy.execute(argv, commands, cwd=run.ROOT, timeout=180)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result

        with tempfile.TemporaryDirectory(prefix="renderer-", dir=artifacts) as temporary:
            root = Path(temporary)
            fixtures = root / "fixtures"
            fixtures.mkdir()
            original = (run.base.BRIDGE / "Fixture.swift").read_text()
            (fixtures / "Fixture.swift").write_text(cases.fixture(original, cases.diamonds(1)))
            shutil.copyfile(run.base.BRIDGE / "main.swift", fixtures / "main.swift")
            execute([sys.executable, "-B", run.base.BRIDGE / "collect.py",
                     "--fixtures", fixtures, "--output", root / "bridge"])
            package = run.ROOT.parent / "lean-proof"
            execute(["swift", "build", "--package-path", package, "--product", "proof-emitter"])
            binary = Path(execute(["swift", "build", "--package-path", package, "--show-bin-path"]).stdout.strip())
            emitter = binary / "proof-emitter"
            collection = root / "bridge" / "report.json"
            bundle = run.policy.generate(emitter, collection, fixtures, run.base.CONTRACT, commands)
            bundle_path = root / "bundle.json"
            run.policy.write_json(bundle_path, bundle)
            environment = run.policy.LeanEnvironment("lean", commands)
            verdict = run.policy.verify(
                emitter, collection, fixtures, run.base.CONTRACT, bundle_path, environment, commands,
            )
            self.assertEqual(verdict["status"], "MODEL PROVED", verdict)


if __name__ == "__main__":
    unittest.main()
