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

    def test_host_root_leaves_the_navigation_item_to_swiftui(self):
        bridge = (ROOT / "LiveContainer/LCSharedUtils.m").read_text(encoding="utf-8")
        update = production_method(bridge, "+ (void)updateNavigationForController:")
        self.assertLess(update.index("if (isRoot && !NSUserDefaults.builtInAppIdentifier) return;"),
                        update.index("top.navigationItem"))
        views = ROOT / "LiveContainerSwiftUI/Views"
        for name in ("AppList/LCAppListView.swift", "LCAltStoreSourcesView.swift",
                     "LCTweaksView.swift", "Settings/LCSettingsView.swift"):
            with self.subTest(tab=name):
                self.assertEqual((views / name).read_text(encoding="utf-8").count("LCCompanionToolbarItem"), 1)

    def test_app_list_offers_install_and_switch_together(self):
        views = ROOT / "LiveContainerSwiftUI/Views"
        apps = (views / "AppList/LCAppListView.swift").read_text(encoding="utf-8")
        toolbar = production_method(apps, ".toolbar {")
        leading = production_method(toolbar, "ToolbarItem(placement: .topBarLeading)")
        self.assertIn("sharedModel.multiLCStatus != 2", leading)
        self.assertRegex(leading, r"(?s)if installprogressVisible\s*\{.*?ProgressView\(\).*?\}\s*else\s*\{\s*installMenu")
        self.assertIn("LCCompanionToolbarItem", toolbar.split(leading, 1)[1])
        menu = production_method(apps, "private var installMenu:")
        self.assertIn('systemImage: "plus"', menu)
        self.assertRegex(menu, r'(?s)installFromIpa".*?choosingIPA = true')
        self.assertRegex(menu, r'(?s)installFromUrl".*?await startInstallFromUrl\(\)')
        tabs = (views / "LCTabView.swift").read_text(encoding="utf-8")
        self.assertIn("LCCompanionBridge.presentNavigationMenu(from: button)", tabs)

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
