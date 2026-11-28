"""Render the production UIKit picker on iPhone and iPad simulators for visual review."""

import argparse
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import time
import zipfile

from test_background_refresh import ROOT, production_method


BUNDLE_ID = "com.livecontainer.CompanionPickerPreview"


def command(*arguments, timeout=120):
    return subprocess.check_output(arguments, text=True, timeout=timeout).strip()


def production_source():
    source = (ROOT / "LiveContainer/LCSharedUtils.m").read_text(encoding="utf-8")
    start = source.index("@interface LCCompanionPicker :")
    end = source.index("@implementation LCCompanionBridge", start)
    presentation = production_method(source, "+ (void)presentNavigationMenuFromView:")
    fixture = Path(__file__).with_name("CompanionPickerPreview.m").read_text(encoding="utf-8")
    return fixture.replace("// INSERT_PICKER", source[start:end]).replace("// INSERT_PRESENTATION", presentation)


def extract_icon(ipa, destination):
    with zipfile.ZipFile(ipa) as archive:
        icon = next(name for name in archive.namelist() if name.startswith("Payload/") and name.endswith(".app/AppIcon60x60@2x.png"))
        destination.write_bytes(archive.read(icon))


def build_app(output, store, installer):
    app = output / "CompanionPickerPreview.app"
    app.mkdir(parents=True, exist_ok=True)
    source = output / "CompanionPickerPreview.m"
    source.write_text(production_source(), encoding="utf-8")
    sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    command("xcrun", "--sdk", "iphonesimulator", "clang", "-fobjc-arc", "-fblocks", "-isysroot", sdk,
            "-target", f"{arch}-apple-ios17.4-simulator", "-framework", "UIKit", "-framework", "Foundation",
            str(source), "-o", str(app / "CompanionPickerPreview"))
    info = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "CompanionPickerPreview",
            "CFBundleName": "Picker Preview", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.4", "UIDeviceFamily": [1, 2],
            "UILaunchScreen": {}}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    shutil.copy2(ROOT / "Resources/DefaultIcon.png", app / "ui.png")
    extract_icon(store, app / "builtinSideStore.png")
    extract_icon(installer, app / "builtinSideInstaller.png")
    command("codesign", "--force", "--sign", "-", str(app))
    return app


def simulator_models():
    devices = json.loads(command("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    runtimes = [key for key in devices if ".iOS-" in key]
    runtime = max(runtimes, key=lambda key: tuple(int(value) for value in key.split(".iOS-")[-1].split("-")))
    selected = []
    for family in ("iPhone", "iPad"):
        device = next(item for item in devices[runtime] if item["name"].startswith(family))
        selected.append((family, runtime, device["deviceTypeIdentifier"]))
    return selected


def render_style(device, family, style, output):
    command("xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE_ID, style)
    container = Path(command("xcrun", "simctl", "get_app_container", device, BUNDLE_ID, "data"))
    layout_file = container / "Documents/layout.json"
    deadline = time.monotonic() + 20
    while not layout_file.exists() and time.monotonic() < deadline:
        time.sleep(0.25)
    layout = json.loads(layout_file.read_text())
    name = f"{family}-{style}"
    (output / f"{name}.json").write_text(json.dumps(layout, indent=2) + "\n")
    command("xcrun", "simctl", "io", device, "screenshot", str(output / f"{name}.png"))
    command("xcrun", "simctl", "terminate", device, BUNDLE_ID)
    layout_file.unlink()
    assert layout["popover"], layout
    assert layout["headerHeight"] == 0 and layout["contentHeight"] == 168, layout
    assert layout["topInset"] == layout["adjustedTopInset"] == 6, layout
    assert [row["title"] for row in layout["rows"]] == ["LiveContainer", "SideStore", "SideInstaller"], layout
    assert all(row["height"] == 52 and row["titleX"] == layout["separatorX"] for row in layout["rows"]), layout
    print("Rendered production picker:", name, flush=True)


def render_device(app, family, runtime, device_type, output):
    device = command("xcrun", "simctl", "create", "Companion Picker " + family, device_type, runtime)
    try:
        command("xcrun", "simctl", "boot", device)
        command("xcrun", "simctl", "bootstatus", device, "-b", timeout=240)
        command("xcrun", "simctl", "install", device, str(app))
        for style in ("light", "dark"):
            render_style(device, family, style, output)
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], check=False, timeout=30)
        subprocess.run(["xcrun", "simctl", "delete", device], check=False, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sidestore-ipa", type=Path, required=True)
    parser.add_argument("--sideinstaller-ipa", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = build_app(output, args.sidestore_ipa, args.sideinstaller_ipa)
    for family, runtime, device_type in simulator_models():
        render_device(app, family, runtime, device_type, output)


if __name__ == "__main__":
    main()
