"""Verify full-app embedding, system declarations, and downgrade rejection."""

from pathlib import Path
import json
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from embed_sideinstaller import embed, merge_info
from verify_ipa import verify_combined, SIDEINSTALLER_ACTIONS
from test_ipa_packaging import macho, write_bundle


class ThreeAppPackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.host = self.root / "Payload/LiveContainer.app"
        self.host.mkdir(parents=True)
        self.host_info = {
            "CFBundleIdentifier": "com.kdt.livecontainer", "CFBundleExecutable": "LiveContainer",
            "CFBundleShortVersionString": "3.8.14", "CFBundleVersion": "20261123.50",
            "MinimumOSVersion": "15.0",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["livecontainer", "sidestore"]}],
            "UIBackgroundModes": ["audio", "processing"],
        }
        self.guest_info = {
            "CFBundleIdentifier": "com.frizzlem.sideinstaller", "CFBundleExecutable": "SideInstaller",
            "CFBundleShortVersionString": "2.1.1", "CFBundleVersion": "20261123.1",
            "MinimumOSVersion": "17.4",
            "CFBundleURLTypes": [{"CFBundleURLSchemes": ["sideinstaller"]}],
            "BGTaskSchedulerPermittedIdentifiers": ["com.frizzlem.sideinstaller.install.*"],
            "UIBackgroundModes": ["audio", "location"],
            "NSLocalNetworkUsageDescription": "Pair with this device",
            "NSLocationWhenInUseUsageDescription": "Keep pairing active",
        }
        (self.host / "Info.plist").write_bytes(plistlib.dumps(self.host_info))
        (self.host / "LiveContainer").write_bytes(macho(2))
        shortcuts = self.host / "PlugIns/LaunchAppExtension.appex"
        shortcuts.mkdir(parents=True)
        (shortcuts / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "LaunchAppExtension",
            "EXAppExtensionAttributes": {"EXExtensionPointIdentifier": "com.apple.appintents-extension"},
        }))
        (shortcuts / "LaunchAppExtension").write_bytes(macho(2))
        metadata = shortcuts / "Metadata.appintents"
        metadata.mkdir()
        self.actions_path = metadata / "extract.actionsdata"
        actions = {"SI" + name + "Intent": {"isDiscoverable": True, "openAppWhenRun": False,
                   "fullyQualifiedTypeName": "LaunchAppExtension.SI" + name + "Intent"} for name in SIDEINSTALLER_ACTIONS}
        self.actions_path.write_text(json.dumps({"actions": actions, "queries": {
            "SISavedPlaceQuery": {}, "SISideloadedAppQuery": {}}}))
        self.installer = self.root / "SideInstaller.ipa"
        with zipfile.ZipFile(self.installer, "w") as archive:
            base = "Payload/SideInstaller.app/"
            archive.writestr(base + "Info.plist", plistlib.dumps(self.guest_info))
            archive.writestr(base + "SideInstaller", macho(2))
            archive.writestr(base + "Assets.car", b"complete application resources")
            archive.writestr(base + "zh-Hans.lproj/Localizable.strings", b"original translations")
            write_bundle(archive, base + "PlugIns/SideInstallerLiveActivity.appex",
                         "com.frizzlem.sideinstaller.LiveActivity", macho(2), {})
        self.sidestore = self.root / "SideStore.ipa"
        with zipfile.ZipFile(self.sidestore, "w") as archive:
            write_bundle(archive, "Payload/SideStore.app", "com.SideStore.SideStore", macho(2), {"a": "中文"})
        ss = self.host / "Frameworks/SideStoreApp.framework"
        ss.mkdir(parents=True)
        with zipfile.ZipFile(self.sidestore) as archive:
            for name in archive.namelist():
                suffix = name.removeprefix("Payload/SideStore.app/")
                target = ss / suffix
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
        (ss / "Executable").write_bytes(macho())
        self.license = self.root / "LICENSE.md"
        self.license.write_text("SideInstaller by FrizzleM", encoding="utf-8")
        self.update = "https://example.com/LiveContainer%2BSideStore%2BSideInstaller.ipa"

    def embed_installer(self):
        def run(command, **_):
            if command[0] == "converter":
                Path(command[2]).write_bytes(macho())
        with patch("embed_sideinstaller.subprocess.run", side_effect=run):
            embed(self.installer, self.host, Path("converter"), self.update, self.license)

    def package(self):
        output = self.root / "Combined.ipa"
        with zipfile.ZipFile(output, "w") as archive:
            for path in self.host.rglob("*"):
                if path.is_file():
                    archive.write(path, path.relative_to(self.root).as_posix())
        return output

    def test_complete_app_and_pairing_extension_survive_embedding(self):
        self.embed_installer()
        guest = self.host / "Frameworks/SideInstallerApp.framework"
        self.assertEqual((guest / "Assets.car").read_bytes(), b"complete application resources")
        self.assertEqual((guest / "zh-Hans.lproj/Localizable.strings").read_bytes(), b"original translations")
        self.assertFalse((guest / "PlugIns/SideInstallerLiveActivity.appex").exists())
        self.assertEqual(verify_combined(self.package(), self.sidestore, self.installer), "1.0+abcdef12")

    def test_host_preserves_existing_modes_and_owns_background_tasks(self):
        result = merge_info(dict(self.host_info), self.guest_info, self.update)
        self.assertEqual(result["UIBackgroundModes"], ["audio", "processing", "location"])
        self.assertEqual(result["BGTaskSchedulerPermittedIdentifiers"], ["com.kdt.livecontainer.install.*"])
        self.assertEqual(result["CFBundleVersion"], self.host_info["CFBundleVersion"])
        self.assertEqual(result["MinimumOSVersion"], "17.4")
        repeated = merge_info(dict(result), self.guest_info, self.update)
        self.assertEqual(repeated, result)

    def test_source_mismatch_and_missing_extension_are_rejected(self):
        self.embed_installer()
        extension = self.host / "PlugIns/SideInstallerLiveActivity.appex/Info.plist"
        original = extension.read_bytes()
        altered = plistlib.loads(original)
        altered["CFBundleIdentifier"] = "com.frizzlem.sideinstaller.LiveActivity"
        extension.write_bytes(plistlib.dumps(altered))
        with self.assertRaisesRegex(ValueError, "must belong to the host"):
            verify_combined(self.package(), self.sidestore, self.installer)
        extension.write_bytes(original)
        extension.unlink()
        with self.assertRaisesRegex(ValueError, "IPA is missing"):
            verify_combined(self.package(), self.sidestore, self.installer)

    def test_three_app_package_cannot_skip_its_source_verification(self):
        self.embed_installer()
        with self.assertRaisesRegex(ValueError, "requires its SideInstaller source"):
            verify_combined(self.package(), self.sidestore)

    def test_invalid_update_urls_are_rejected(self):
        for url in ("http://example.com/a.ipa", "https://user:password@example.com/a.ipa", "file:///a.ipa"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                merge_info(dict(self.host_info), self.guest_info, url)

    def test_missing_or_misrouted_shortcut_actions_are_rejected(self):
        self.embed_installer()
        metadata = json.loads(self.actions_path.read_text())
        action = metadata["actions"].pop("SIRefreshAllAppsIntent")
        self.actions_path.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, "shortcut actions are missing"):
            verify_combined(self.package(), self.sidestore, self.installer)
        metadata["actions"]["SIRefreshAllAppsIntent"] = dict(action, openAppWhenRun=True)
        self.actions_path.write_text(json.dumps(metadata))
        with self.assertRaisesRegex(ValueError, "execute in the App Intents extension"):
            verify_combined(self.package(), self.sidestore, self.installer)


if __name__ == "__main__":
    unittest.main()
