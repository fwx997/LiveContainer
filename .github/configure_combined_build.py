"""Set a unique host build number without changing its application identity."""

import argparse
from pathlib import Path
import re
import subprocess


def configure_iokit(project_root):
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    framework = Path(sdk_path) / "System/Library/Frameworks/IOKit.framework"
    if not framework.is_dir():
        raise ValueError("The selected macOS SDK does not contain IOKit.framework")
    path = project_root / "LiveContainer.xcodeproj/project.pbxproj"
    original = path.read_text(encoding="utf-8")
    updated, count = re.subn(
        r'(name = IOKit\.framework; path = )[^;]+(; sourceTree = )[^;]+;',
        lambda match: match[1] + '"' + framework.as_posix() + '"' + match[2] + '"<absolute>";',
        original,
    )
    if count != 1:
        raise ValueError("Expected exactly one IOKit framework reference")
    # The complete three-app IPA already requires iOS 17.4. Compile its legacy
    # framework targets against the same floor used by the packaged host.
    updated = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = (?:15\.0|16\.0);",
                     "IPHONEOS_DEPLOYMENT_TARGET = 17.4;", updated)
    path.write_text(updated, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-number", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.build_number):
        parser.error("The build number must contain one to three numeric components")
    project_root = Path(__file__).resolve().parents[1]
    configure_iokit(project_root)
    path = project_root / "LiveContainer/Info.plist"
    original = path.read_text(encoding="utf-8")
    updated, count = re.subn(r"(<key>CFBundleVersion</key>\s*<string>)[^<]+(</string>)",
                            lambda match: match[1] + args.build_number + match[2], original)
    if count != 1:
        raise ValueError("Expected exactly one host CFBundleVersion")
    path.write_text(updated, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
