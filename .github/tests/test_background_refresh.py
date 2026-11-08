"""Execute production refresh, callback routing and guest window lifecycle checks."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "SideStoreSupport" / "SideStore.swift"


def production_coordinator():
    source = SOURCE.read_text(encoding="utf-8")
    source = source[source.index("// A reply can arrive synchronously") :]
    source = re.sub(r"^\s*@objc(?:\([^\n]*\))?\s*$", "", source, flags=re.MULTILINE)
    substitutions = {
        "NSXPCListener": "FakeListener",
        "NSXPCConnection": "FakeConnection",
        "NSXPCInterface": "FakeInterface",
        "NSExtensionItem": "FakeExtensionItem",
        "NSExtension": "FakeExtension",
        "UNNotificationRequest": "FakeNotificationRequest",
        "UNUserNotificationCenter": "FakeNotificationCenter",
        "DispatchTime.now() + 27": "DispatchTime.now() + Fixture.refreshBudget",
        "DispatchQueue.main.asyncAfter(deadline: deadline)": "Fixture.scheduleDeadline(deadline: deadline)",
    }
    for original, replacement in substitutions.items():
        source = source.replace(original, replacement)
    source = re.sub(r"\bBundle(?=\s*\()", "FakeBundle", source)
    return source


def production_method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


class BackgroundRefreshTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "macOS Foundation is required for the window lifecycle checks")
    def test_terminated_guest_window_controls(self):
        decorated = (ROOT / "MultitaskSupport/DecoratedAppSceneViewController.m").read_text(encoding="utf-8")
        host = (ROOT / "MultitaskSupport/VirtualWindowsHostView.m").read_text(encoding="utf-8")
        harness = Path(__file__).with_name("MultitaskWindowHarness.m").read_text(encoding="utf-8")
        metrics = re.findall(r"^static const CGFloat LCWindow\w+ = [^;]+;", decorated, flags=re.MULTILINE)
        harness = harness.replace("// INSERT_WINDOW_BAR_METRICS", "\n".join(metrics))
        methods = {
            "INSERT_WINDOW_BAR_HEIGHT": production_method(decorated, "- (CGFloat)windowBarHeight {"),
            "INSERT_INITIAL_WINDOW_FRAME": production_method(decorated, "- (CGRect)initialWindowFrame {"),
            "INSERT_MAXIMIZED_FRAME": production_method(decorated, "- (void)updateMaximizedFrame {"),
            "INSERT_WINDOWED_FRAME": production_method(decorated, "- (void)updateWindowedFrameWithSettings:"),
            "INSERT_VERTICAL_CONSTRAINTS": production_method(decorated, "- (void)updateVerticalConstraints {"),
            "INSERT_HOST_LAYOUT": production_method(host, "- (void)layoutSubviews {"),
            "INSERT_HOST_ACTIVATION": production_method(host, "- (void)hostSceneDidActivate:"),
            "INSERT_SAFE_AREA_CHANGE": production_method(host, "- (void)safeAreaInsetsDidChange {"),
        }
        for marker, method in methods.items():
            harness = harness.replace("// " + marker, method)
        with tempfile.TemporaryDirectory(prefix="lc-window-tests-") as directory:
            source = Path(directory) / "WindowHarness.m"
            executable = Path(directory) / "WindowHarness"
            source.write_text(harness, encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics", str(source), "-o", str(executable)], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=10)

    def test_english_and_chinese_error_resources(self):
        catalog = json.loads((ROOT / "SideStoreSupport/Localizable.xcstrings").read_text(encoding="utf-8"))
        messages = set(re.findall(r'refreshError\("([^"\\]+)"\)', SOURCE.read_text(encoding="utf-8")))
        self.assertGreater(len(messages), 5)
        for message in messages:
            translations = catalog["strings"][message]["localizations"]
            self.assertEqual(translations["en"]["stringUnit"]["value"], message)
            self.assertTrue(translations["zh-Hans"]["stringUnit"]["value"])

    @unittest.skipUnless(shutil.which("swiftc"), "swiftc is required to execute the production Swift coordinator")
    def test_production_refresh_lifecycle(self):
        harness = Path(__file__).with_name("BackgroundRefreshHarness.swift").read_text(encoding="utf-8")
        combined = harness.replace("// INSERT_PRODUCTION_COORDINATOR", production_coordinator())
        with tempfile.TemporaryDirectory(prefix="lc-refresh-tests-") as directory:
            source = Path(directory) / "RefreshHarness.swift"
            executable = Path(directory) / "RefreshHarness"
            source.write_text(combined, encoding="utf-8")
            subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", str(source), "-o", str(executable)], check=True, timeout=120)
            subprocess.run([str(executable)], check=True, timeout=30)

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "macOS Foundation is required for the Objective-C routing checks")
    def test_production_callback_routes(self):
        source = (ROOT / "LiveContainer/LCSharedUtils.m").read_text(encoding="utf-8")
        method = production_method(source, "+ (BOOL)handleSideStoreCellularCallback:")
        harness = Path(__file__).with_name("CellularCallbackHarness.m").read_text(encoding="utf-8")
        combined = harness.replace("// INSERT_PRODUCTION_ROUTER", method)
        with tempfile.TemporaryDirectory(prefix="lc-callback-tests-") as directory:
            source = Path(directory) / "CallbackHarness.m"
            executable = Path(directory) / "CallbackHarness"
            source.write_text(combined, encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(source), "-o", str(executable)], check=True, timeout=60)
            for scenario in ["direct", "direct-stale", "foreground", "background", "cold", "wrong-scheme", "wrong-host"]:
                subprocess.run([str(executable), scenario], check=True, timeout=10)


if __name__ == "__main__":
    # The existing combined-build workflow runs this entry point directly.
    from test_orientation_bridge import OrientationBridgeTests
    from test_container_playback import ContainerPlaybackTests

    parser = argparse.ArgumentParser()
    parser.add_argument("--require-swift", action="store_true")
    args, remaining = parser.parse_known_args()
    if args.require_swift and not shutil.which("swiftc"):
        parser.error("swiftc is required for the CI regression checks")
    unittest.main(argv=[__file__, *remaining])
