"""Execute production PiP lifecycle and per-guest playback signal methods."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from test_background_refresh import ROOT, production_method


def production_harness():
    scene = (ROOT / "MultitaskSupport/AppSceneViewController.m").read_text(encoding="utf-8")
    pip = (ROOT / "MultitaskSupport/PiPManager.m").read_text(encoding="utf-8")
    guest = (ROOT / "TweakLoader/UIKit+GuestHooks.m").read_text(encoding="utf-8")
    harness = Path(__file__).with_name("ContainerPlaybackHarness.m").read_text(encoding="utf-8")
    groups = {
        "RECEIVER": (scene, ["- (void)observeContainerPlaybackState", "- (void)hostActivityChanged:", "- (void)publishPlaybackState {"]),
        "SCENE": (scene, ["- (void)setContainerPictureInPictureActive:"]),
        "PIP": (pip, [
            "- (void)pictureInPictureControllerWillStartPictureInPicture:",
            "- (void)pictureInPictureControllerDidStartPictureInPicture:",
            "- (void)pictureInPictureControllerWillStopPictureInPicture:",
            "- (void)pictureInPictureControllerDidStopPictureInPicture:",
            "- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStart",
            "- (void)stopObservingBounds",
        ]),
        "GUEST": (guest, ["- (void)containerPlaybackStateDidChange:"]),
    }
    for marker, (source, signatures) in groups.items():
        harness = harness.replace("// INSERT_" + marker, "\n\n".join(production_method(source, signature) for signature in signatures))
    return harness


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "macOS Foundation is required for production PiP lifecycle tests")
class ContainerPlaybackTests(unittest.TestCase):
    def test_per_guest_lifecycle_and_stale_callbacks(self):
        with tempfile.TemporaryDirectory(prefix="lc-playback-tests-") as directory:
            source = Path(directory) / "Playback.m"
            executable = Path(directory) / "Playback"
            source.write_text(production_harness(), encoding="utf-8")
            subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics", str(source), "-o", str(executable)], check=True, timeout=60)
            subprocess.run([str(executable)], check=True, timeout=15)


if __name__ == "__main__":
    unittest.main()
