"""Cover failed conversions and incomplete combined IPA artifacts."""

from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_ipa import verify_combined, verify_dylib


def macho(filetype=6, cpu=0x0100000C, pagezero=False, identifier=True):
    commands = []
    if identifier:
        commands.append(struct.pack("<6I", 0xD, 32, 24, 0, 0, 0) + b"example\0")
    if pagezero:
        commands.append(struct.pack("<2I16s4Q4I", 0x19, 72, b"__PAGEZERO", 0, 0, 0, 0, 0, 0, 0, 0))
    body = b"".join(commands)
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, filetype, len(commands), len(body), 0, 0) + body


def write_bundle(archive, root, identifier, binary, strings, version="1.0+abcdef12"):
    info = {"CFBundleExecutable": "Executable", "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version, "CFBundleVersion": "1"}
    archive.writestr(root + "/Info.plist", plistlib.dumps(info))
    if binary is not None:
        archive.writestr(root + "/Executable", binary)
    archive.writestr(root + "/zh-Hans.lproj/Localizable.strings", plistlib.dumps(strings))


class IPAPackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.sidestore = Path(self.directory.name) / "SideStore.ipa"
        self.combined = Path(self.directory.name) / "Combined.ipa"
        with zipfile.ZipFile(self.sidestore, "w") as archive:
            write_bundle(archive, "Payload/SideStore.app", "com.SideStore.SideStore", macho(2), {"Refresh": "刷新"})

    def combined_ipa(self, binary=macho(), strings=None, version="1.0+abcdef12"):
        with zipfile.ZipFile(self.combined, "w") as archive:
            write_bundle(archive, "Payload/LiveContainer.app", "com.kdt.livecontainer", macho(2), {})
            write_bundle(archive, "Payload/LiveContainer.app/Frameworks/SideStoreApp.framework",
                         "com.SideStore.SideStore", binary, strings if strings is not None else {"Refresh": "刷新"}, version)

    def test_complete_converted_package_passes(self):
        self.combined_ipa()
        self.assertEqual(verify_combined(self.combined, self.sidestore), "1.0+abcdef12")

    def test_missing_embedded_executable_is_rejected(self):
        self.combined_ipa(binary=None)
        with self.assertRaisesRegex(ValueError, "IPA is missing.*Executable"):
            verify_combined(self.combined, self.sidestore)

    def test_unconverted_executable_is_rejected(self):
        self.combined_ipa(binary=macho(2))
        with self.assertRaisesRegex(ValueError, "Expected arm64 Mach-O type 6"):
            verify_combined(self.combined, self.sidestore)

    def test_wrong_architecture_or_incomplete_conversion_is_rejected(self):
        binaries = [macho(cpu=0x01000007), macho(pagezero=True), macho(identifier=False), macho()[:40]]
        for binary in binaries:
            with self.subTest(binary=binary), self.assertRaises(ValueError):
                verify_dylib(binary)

    def test_different_source_ipa_is_rejected(self):
        self.combined_ipa(version="1.0+12345678")
        with self.assertRaisesRegex(ValueError, "CFBundleShortVersionString"):
            verify_combined(self.combined, self.sidestore)

    def test_wrong_localizations_are_rejected(self):
        self.combined_ipa(strings={"Refresh": "Refresh"})
        with self.assertRaisesRegex(ValueError, "Chinese strings"):
            verify_combined(self.combined, self.sidestore)


if __name__ == "__main__":
    unittest.main()
