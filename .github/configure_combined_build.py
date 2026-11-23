"""Set a unique host build number without changing its application identity."""

import argparse
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-number", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.build_number):
        parser.error("The build number must contain one to three numeric components")
    path = Path(__file__).resolve().parents[1] / "LiveContainer/Info.plist"
    original = path.read_text(encoding="utf-8")
    updated, count = re.subn(r"(<key>CFBundleVersion</key>\s*<string>)[^<]+(</string>)",
                            lambda match: match[1] + args.build_number + match[2], original)
    if count != 1:
        raise ValueError("Expected exactly one host CFBundleVersion")
    path.write_text(updated, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
