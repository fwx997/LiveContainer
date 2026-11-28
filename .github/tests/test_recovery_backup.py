"""Run recovery cache/export operations against real files using the production code."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RecoveryBackupTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "macOS Foundation is required")
    def test_production_cache_publish_locking_and_sensitive_file_removal(self):
        production = (ROOT / "LiveContainer/LCRecoveryBackup.m").read_text(encoding="utf-8")
        harness = Path(__file__).with_name("RecoveryBackupHarness.m").read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory(prefix="lc-recovery-") as directory:
            directory = Path(directory)
            source = directory / "Recovery.m"
            binary = directory / "Recovery"
            source.write_text(harness.replace("// INSERT_RECOVERY_SOURCE", production), encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-fblocks", "-Wno-incomplete-implementation",
                            "-Wno-deprecated-declarations", "-I", str(ROOT / "LiveContainer"),
                            "-framework", "Foundation", str(source), "-o", str(binary)], check=True, timeout=60)
            fixtures = directory / "fixtures"
            fixtures.mkdir()
            subprocess.run([str(binary), str(fixtures)], check=True, timeout=30)


if __name__ == "__main__": unittest.main()
