"""Exercise result ownership and exit handling without Xcode or a simulator."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HOOK = Path(__file__).resolve().parents[1] / "git-hooks" / "pre-push"


class PrePushGateTests(unittest.TestCase):
    def invoke(self, exit_code=0, create_result=True, count=3):
        artifacts = HOOK.parents[2] / ".artifacts" / "pre-push-tests"
        artifacts.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=artifacts) as directory:
            root = Path(directory)
            tools = root / "bin"
            tools.mkdir()
            # Deliberately leave an unrelated passing bundle available.
            prior = root / "DerivedData" / "Logs" / "Test" / "old.xcresult"
            prior.mkdir(parents=True)
            stubs = {
                "git": '#!/bin/sh\nprintf "%s\\n" "$TEST_ROOT"\n',
                "curl": "#!/bin/sh\nexit 22\n",
                "xcodebuild": '''#!/bin/sh
if [ "$2" = "-showBuildSettings" ] || [ "$3" = "-showBuildSettings" ]; then
    echo "    BUILD_DIR = $TEST_ROOT/DerivedData/Build/Products"
    exit 0
fi
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-resultBundlePath" ]; then
        shift
        if [ "$TEST_CREATE_RESULT" = "1" ]; then mkdir -p "$1"; fi
    fi
    shift
done
if [ "$TEST_XCODE_EXIT" != "0" ]; then echo "error: current invocation failed"; fi
exit "$TEST_XCODE_EXIT"
''',
                "xcrun": '#!/bin/sh\nprintf "%s\\n" "$TEST_SUMMARY"\n',
            }
            for name, content in stubs.items():
                target = tools / name
                target.write_text(content)
                target.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{tools}:{os.environ['PATH']}",
                "TEST_ROOT": str(root),
                "TEST_XCODE_EXIT": str(exit_code),
                "TEST_CREATE_RESULT": str(int(create_result)),
                "TEST_SUMMARY": json.dumps({"result": "Passed", "passedTests": count,
                                           "failedTests": 0, "totalTestCount": count}),
                "STIR_PREPUSH_SKIP_SIM_WARMUP": "1",
                "SKIP_PREPUSH_TESTS": "0",
            }
            return subprocess.run(
                ["/bin/bash", str(HOOK)], env=env, text=True, capture_output=True,
                input="refs/heads/test 123 refs/heads/test 456\n", timeout=10,
            )

    def test_current_pass_is_accepted(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_failed_exit_cannot_use_passing_current_summary(self):
        result = self.invoke(exit_code=65)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_missing_current_result_cannot_reuse_old_pass(self):
        result = self.invoke(exit_code=65, create_result=False)
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_zero_tests_is_not_a_pass(self):
        result = self.invoke(count=0)
        self.assertNotEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
