"""Render the proposed native SwiftUI recovery settings, without changing the app."""
import argparse
import json
from pathlib import Path
import platform
import plistlib
import subprocess
import time

BUNDLE_ID = "com.livecontainer.RecoverySettingsPreview"

def command(*args, timeout=120):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args, _ = parser.parse_known_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = output / "RecoverySettingsPreview.app"
    app.mkdir()
    source = app / "main.swift"
    source.write_bytes(Path(__file__).with_name("RecoverySettingsPreview.swift").read_bytes())
    sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    arch = "arm64" if platform.machine() == "arm64" else "x86_64"
    command("xcrun", "swiftc", "-sdk", sdk, "-target", f"{arch}-apple-ios17.4-simulator", str(source), "-o", str(app / "Preview"))
    info = {"CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "Preview", "CFBundleName": "Recovery preview",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
            "MinimumOSVersion": "17.4", "UIDeviceFamily": [1, 2], "UILaunchScreen": {}}
    (app / "Info.plist").write_bytes(plistlib.dumps(info))
    command("codesign", "--force", "--sign", "-", str(app))
    devices = json.loads(command("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    sdk_version = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version").replace(".", "-")
    runtime = next(key for key in devices if key.endswith("iOS-" + sdk_version))
    selected = next(item for item in devices[runtime] if item["name"].startswith("iPhone"))
    device = selected["udid"]
    subprocess.run(["open", "-a", "Simulator"], check=False)
    if selected["state"] != "Booted": command("xcrun", "simctl", "boot", device)
    command("xcrun", "simctl", "bootstatus", device, "-b", timeout=600)
    command("xcrun", "simctl", "install", device, str(app), timeout=600)
    for mode, label in (("single", "detail"), ("grouped", "entry")):
        for style in ("dark", "light"):
            command("xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE_ID, mode, style)
            container = Path(command("xcrun", "simctl", "get_app_container", device, BUNDLE_ID, "data"))
            ready = container / "Documents/ready.txt"
            deadline = time.monotonic() + 60
            while not ready.exists() and time.monotonic() < deadline: time.sleep(.25)
            if not ready.exists(): raise RuntimeError("Preview did not become ready")
            command("xcrun", "simctl", "io", device, "screenshot", str(output / f"recovery-{label}-{style}.png"), timeout=180)
            command("xcrun", "simctl", "terminate", device, BUNDLE_ID)
            ready.unlink()
            print("Rendered", label, style, flush=True)
    (output / "recovery-preview.json").write_text(json.dumps({"device": selected["name"], "runtime": runtime,
        "native": "SwiftUI Form, Section, Button, Toggle and NavigationStack", "production_installed": False}, indent=2))
    command("xcrun", "simctl", "shutdown", device)

if __name__ == "__main__": main()
