"""Verify full-app embedding, system declarations, and downgrade rejection."""

from pathlib import Path
import hashlib
import json
import plistlib
import sys
import tempfile
import unittest
import warnings
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from embed_sideinstaller import embed, merge_info
from verify_ipa import verify_combined, verify_refresh_shortcuts, SIDEINSTALLER_ACTIONS
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
        self.recovery_binary = b"\x7fELF\x02\x01" + b"fixture recovery installer"
        with zipfile.ZipFile(self.installer, "w") as archive:
            base = "Payload/SideInstaller.app/"
            archive.writestr(base + "Info.plist", plistlib.dumps(self.guest_info))
            archive.writestr(base + "SideInstaller", macho(2))
            archive.writestr(base + "Assets.car", b"complete application resources")
            archive.writestr(base + "zh-Hans.lproj/Localizable.strings", b"original translations")
            write_bundle(archive, base + "PlugIns/SideInstallerLiveActivity.appex",
                         "com.frizzlem.sideinstaller.LiveActivity", macho(2), {})
            archive.writestr("CertificateReuseBuild/siboot-aarch64", self.recovery_binary)
            archive.writestr("CertificateReuseBuild/SHA256SUMS", hashlib.sha256(self.recovery_binary).hexdigest() + "  siboot-aarch64\n")
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

    def test_recovery_bundle_contains_matching_installer_and_scripts(self):
        self.embed_installer()
        recovery = self.host / "Recovery"
        self.assertEqual((recovery / "siboot-aarch64").read_bytes(), self.recovery_binary)
        info = plistlib.loads((self.host / "Info.plist").read_bytes())
        self.assertEqual(info["LCRecoveryBootstrapSHA256"], hashlib.sha256(self.recovery_binary).hexdigest())
        self.assertEqual(info["LCRecoveryFormatVersion"], 1)
        for name in ("install.sh", "install-local.sh"):
            source = Path(__file__).resolve().parents[1] / "recovery" / name
            self.assertEqual((recovery / name).read_bytes(), source.read_bytes().replace(b"\r\n", b"\n"))

    def test_recovery_installer_hash_mismatch_is_rejected(self):
        with warnings.catch_warnings(), zipfile.ZipFile(self.installer, "a") as archive:
            warnings.simplefilter("ignore", UserWarning)
            archive.writestr("CertificateReuseBuild/SHA256SUMS", "0" * 64 + "  siboot-aarch64\n")
        with self.assertRaisesRegex(ValueError, "recovery installer failed"):
            self.embed_installer()

    def test_missing_or_corrupt_recovery_files_reject_the_final_ipa(self):
        self.embed_installer()
        core = self.host / "Recovery/siboot-aarch64"
        core.write_bytes(b"corrupt core")
        with self.assertRaisesRegex(ValueError, "offline recovery installer"):
            verify_combined(self.package(), self.sidestore, self.installer)
        core.write_bytes(self.recovery_binary)
        (self.host / "Recovery/install-local.sh").unlink()
        with self.assertRaisesRegex(ValueError, "IPA is missing"):
            verify_combined(self.package(), self.sidestore, self.installer)

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


class RefreshMetadataTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "Combined.ipa"
        self.actions = {}
        self.source_actions = {}
        definitions = {"RefreshAllIntent": ("20RefreshAllAppsIntentV", "returnErrorsAsResult", 1),
                       "GetRefreshResultIntent": ("22GetRefreshResultIntentV", "requestID", 0)}
        for key, (symbol, parameter, kind) in definitions.items():
            self.actions[key] = {"mangledTypeNameV2": "16SideStoreSupport" + symbol,
                                 "isDiscoverable": True, "openAppWhenRun": False,
                                 "parameters": [{"name": parameter, "valueType": self.primitive(kind)}],
                                 "outputType": self.primitive(0)}

    @staticmethod
    def primitive(kind):
        return {"primitive": {"wrapper": {"typeIdentifier": kind}}}

    def verify(self):
        with zipfile.ZipFile(self.path, "w") as archive:
            archive.writestr("Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata",
                             json.dumps({"actions": self.actions}))
            archive.writestr("Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Metadata.appintents/extract.actionsdata",
                             json.dumps({"actions": self.source_actions}))
        with zipfile.ZipFile(self.path) as archive:
            verify_refresh_shortcuts(archive, "Payload/LiveContainer.app")

    def test_host_refresh_and_query_resolve_to_loaded_support(self):
        self.verify()

    def test_query_must_not_resolve_to_unloaded_sidestore(self):
        self.actions["GetRefreshResultIntent"]["mangledTypeNameV2"] = "9SideStore22GetRefreshResultIntentV"
        with self.assertRaisesRegex(ValueError, "host SideStoreSupport"):
            self.verify()

    def test_query_requires_text_request_and_output(self):
        self.actions["GetRefreshResultIntent"]["outputType"] = self.primitive(1)
        with self.assertRaisesRegex(ValueError, "text output"):
            self.verify()

    def test_error_result_parameter_must_survive_packaging(self):
        self.actions["RefreshAllIntent"]["parameters"] = []
        with self.assertRaisesRegex(ValueError, "refresh-result input"):
            self.verify()

    def test_older_packages_remain_verifiable(self):
        self.actions = {}
        self.verify()

    def test_query_cannot_be_lost_from_new_host_metadata(self):
        self.source_actions = self.actions
        self.actions = {}
        with self.assertRaisesRegex(ValueError, "missing SideStore's refresh-result query"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
