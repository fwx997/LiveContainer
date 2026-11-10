"""Compile the complete production media PiP controller against AVKit doubles.

This exercises state transitions without fetching media or using an iOS device.
The regular container-playback suite calls run_media_harness on macOS.
"""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

from test_background_refresh import ROOT


def production_harness():
    folder = ROOT / "MultitaskSupport"
    header = (folder / "LCMediaPiPController.h").read_text(encoding="utf-8")
    header = re.sub(r"^@import .+;$", "", header, flags=re.MULTILINE)
    source = (folder / "LCMediaPiPController.m").read_text(encoding="utf-8")
    source = source.replace('#import "LCMediaPiPController.h"', "")
    harness = Path(__file__).with_name("MediaPiPHarness.m").read_text(encoding="utf-8")
    return harness.replace("// INSERT_HEADER", header).replace("// INSERT_IMPLEMENTATION", source)


def run_media_harness():
    with tempfile.TemporaryDirectory(prefix="lc-media-pip-tests-") as directory:
        source = Path(directory) / "MediaPiP.m"
        executable = Path(directory) / "MediaPiP"
        source.write_text(production_harness(), encoding="utf-8")
        subprocess.run([
            "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "CoreGraphics",
            "-framework", "CoreMedia", str(source), "-o", str(executable),
        ], check=True, timeout=60)
        subprocess.run([str(executable)], check=True, timeout=15)


class MediaPiPHarnessTests(unittest.TestCase):
    def test_harness_uses_the_complete_current_controller(self):
        harness = production_harness()
        self.assertNotIn("// INSERT_", harness)
        self.assertNotIn('@import AVKit;', harness)
        self.assertIn("@implementation LCMediaPiPController", harness)
        self.assertIn("late lease cannot authorize a new PiP player", harness)


if __name__ == "__main__":
    unittest.main()
