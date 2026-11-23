"""Run the production companion routing and task guards against a host fixture."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_background_refresh import ROOT, production_method


def production_harness():
    source = (ROOT / "LiveContainer/LCSharedUtils.m").read_text(encoding="utf-8")
    harness = Path(__file__).with_name("CompanionSwitchHarness.m").read_text(encoding="utf-8")
    registry = production_method(source, "+ (NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)builtInApps")
    signatures = [
        "+ (NSString *)currentAppIdentifier",
        "+ (NSString *)switchBlockReason",
        "+ (BOOL)openApp:(NSString *)identifier URL:",
        "+ (BOOL)handleCompanionURL:",
    ]
    bridge = "\n\n".join(production_method(source, item) for item in signatures)
    bridge = bridge.replace("UIApplication.sharedApplication", "FakeApplication.sharedApplication")
    return harness.replace("// INSERT_REGISTRY", registry).replace("// INSERT_BRIDGE", bridge)


class CompanionHarnessTests(unittest.TestCase):
    def test_production_methods_are_extracted(self):
        self.assertNotIn("// INSERT_", production_harness())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "macOS Foundation is required")
    def test_direct_switch_callbacks_and_active_tasks(self):
        with tempfile.TemporaryDirectory(prefix="lc-companion-") as directory:
            source = Path(directory) / "Companion.m"
            binary = Path(directory) / "Companion"
            source.write_text(production_harness(), encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation", str(source), "-o", str(binary)], check=True, timeout=60)
            subprocess.run([str(binary)], check=True, timeout=20)


if __name__ == "__main__":
    unittest.main()
