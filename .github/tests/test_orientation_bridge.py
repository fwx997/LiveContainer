"""Run the production host orientation policy against small UIKit substitutes."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_background_refresh import ROOT, production_method


def production_harness():
    host = (ROOT / "MultitaskSupport/VirtualWindowsHostView.m").read_text(encoding="utf-8")
    decorated = (ROOT / "MultitaskSupport/DecoratedAppSceneViewController.m").read_text(encoding="utf-8")
    harness = Path(__file__).with_name("OrientationBridgeHarness.m").read_text(encoding="utf-8")
    transaction_start = host.index("@interface LCOrientationTransaction")
    transaction_end = host.index("@interface VirtualWindowsHostView", transaction_start)
    harness = harness.replace("// INSERT_TRANSACTION", host[transaction_start:transaction_end])
    bridge = (ROOT / "LiveContainer/LCOrientationBridge.h").read_text(encoding="utf-8")
    harness = harness.replace("// INSERT_REPLY_HELPERS", bridge[bridge.index("static const NSUInteger LCOrientationBridgeVersion"):bridge.index("@protocol LCContainerPlaybackGuest")])
    host_signatures = [
        "+ (UIInterfaceOrientationMask)defaultInterfaceOrientations",
        "+ (UIInterfaceOrientationMask)supportedInterfaceOrientationsForWindow:",
        "- (DecoratedAppSceneViewController *)frontmostController",
        "- (BOOL)isOrientationOwnerEligible:",
        "- (BOOL)canControlOrientation:",
        "- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations forController:",
        "- (NSString *)fullscreenRejectionForController:",
        "- (NSDictionary *)orientationStateForController:",
        "- (void)finishOrientationTransaction:",
        "- (void)failOrientationTransaction:",
        "- (void)checkOrientationTransaction:",
        "- (void)requestInterfaceOrientations:(UIInterfaceOrientationMask)orientations\n",
        "- (void)releaseOrientationForController:",
        "- (void)restoreHostOrientationIfNeeded",
        "- (void)validateOrientationOwner",
        "- (void)bringSubviewToFront:",
        "- (void)didAddSubview:",
        "- (void)sendSubviewToBack:",
        "- (void)willRemoveSubview:",
        "- (void)hostSceneDidActivate:",
        "- (void)layoutSubviews",
    ]
    decorated_signatures = [
        "- (void)releaseHostOrientation",
        "- (void)appSceneVC:(AppSceneViewController *)vc didRequestInterfaceOrientations:",
        "- (void)appSceneVC:(AppSceneViewController *)vc\n",
        "- (void)appSceneVCOrientationConnectionDidInvalidate:",
        "- (void)closeWindow",
        "- (void)minimizeWindow {",
        "- (void)minimizeWindowPiP",
        "- (void)maximizeWindow",
        "- (void)appSceneVCAppDidExit:",
    ]
    harness = harness.replace(
        "// INSERT_PRODUCTION_HOST_METHODS",
        "\n\n".join(production_method(host, signature) for signature in host_signatures),
    )
    return harness.replace(
        "// INSERT_PRODUCTION_DECORATED_METHODS",
        "\n\n".join(production_method(decorated, signature) for signature in decorated_signatures),
    )


@unittest.skipUnless(
    sys.platform == "darwin" and shutil.which("clang"),
    "macOS Foundation is required to execute the production orientation policy",
)
class OrientationBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="lc-orientation-tests-")
        cls.addClassCleanup(cls.directory.cleanup)
        source = Path(cls.directory.name) / "OrientationHarness.m"
        cls.executable = Path(cls.directory.name) / "OrientationHarness"
        source.write_text(production_harness(), encoding="utf-8")
        subprocess.run(
            [
                "clang", "-fobjc-arc", "-framework", "Foundation",
                "-framework", "CoreGraphics", str(source), "-o", str(cls.executable),
            ],
            check=True,
            timeout=60,
        )

    def run_scenario(self, scenario):
        subprocess.run([str(self.executable), scenario], check=True, timeout=10)

    def test_portrait_landscape_and_device_defaults(self):
        for scenario in ["directions", "ipad", "invalid-masks"]:
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)

    def test_only_active_frontmost_maximized_guest_can_request_rotation(self):
        scenarios = [
            "background", "inactive-scene", "inactive-app", "floating",
            "hidden", "transparent", "host-hidden", "host-transparent", "detached-host",
            "terminated", "pip", "covered", "modal", "non-key-window", "detached", "other-window",
        ]
        for scenario in scenarios:
            with self.subTest(scenario=scenario):
                self.run_scenario("reject-" + scenario)

    def test_hidden_windows_do_not_cover_the_foreground_guest(self):
        self.run_scenario("hidden-cover")

    def test_owner_transfer_and_late_error_are_isolated(self):
        self.run_scenario("ownership")

    def test_newest_failure_releases_the_orientation_constraint(self):
        self.run_scenario("failure")

    def test_stack_and_visibility_changes_release_the_old_owner(self):
        for scenario in ["front", "back", "remove", "layout"]:
            with self.subTest(scenario=scenario):
                self.run_scenario("stack-" + scenario)

    def test_production_window_lifecycle_releases_orientation(self):
        for scenario in ["restore", "minimize", "pip", "close", "exit", "disconnect"]:
            with self.subTest(scenario=scenario):
                self.run_scenario("lifecycle-" + scenario)

    def test_background_rejects_new_requests_but_keeps_existing_owner(self):
        self.run_scenario("background-owner")

    def test_background_exit_defers_restoration_until_its_scene_activates(self):
        self.run_scenario("background-exit")

    def test_new_owner_can_take_over_a_deferred_restoration(self):
        self.run_scenario("deferred-owner")

    def test_only_matching_guest_and_connection_callbacks_reach_the_host(self):
        self.run_scenario("guest-routing")

    def test_explicit_fullscreen_reports_actual_geometry_and_releases(self):
        for scenario in ["v2-non-key", "v2-floating", "v2-release", "v2-restore-landscape", "v2-denials", "v2-timeout", "v2-stale", "v2-once"]:
            with self.subTest(scenario=scenario):
                self.run_scenario(scenario)


if __name__ == "__main__":
    unittest.main()
