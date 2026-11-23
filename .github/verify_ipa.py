"""Reject incomplete SideStore conversions before publishing a combined IPA."""

import argparse
from pathlib import Path
import plistlib
import struct
from urllib.parse import urlsplit
import zipfile


def macho_commands(data, filetype):
    if len(data) < 32:
        raise ValueError("Mach-O header is missing or truncated")
    magic, cpu, _, actual_type, count, size, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, actual_type) != (0xFEEDFACF, 0x0100000C, filetype):
        raise ValueError(f"Expected arm64 Mach-O type {filetype}, got {actual_type}")
    end = 32 + size
    if end > len(data):
        raise ValueError("Mach-O load commands are truncated")
    offset = 32
    commands = []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Mach-O load command header is truncated")
        command, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or length % 8 or offset + length > end:
            raise ValueError("Invalid Mach-O load command length")
        commands.append((command, data[offset:offset + length]))
        offset += length
    if offset != end:
        raise ValueError("Mach-O load command count does not match its size")
    return commands


def verify_dylib(data):
    commands = macho_commands(data, 6)  # MH_DYLIB, not an unconverted MH_EXECUTE.
    if not any(command == 0xD and len(payload) >= 24 for command, payload in commands):
        raise ValueError("Converted SideStore is missing LC_ID_DYLIB")
    if any(command == 0x19 and payload[8:24].rstrip(b"\0") == b"__PAGEZERO"
           for command, payload in commands):
        raise ValueError("Converted SideStore still contains __PAGEZERO")


def read_required(archive, name):
    try:
        data = archive.read(name)
    except KeyError as error:
        raise ValueError(f"IPA is missing {name}") from error
    if not data:
        raise ValueError(f"IPA contains an empty {name}")
    return data


def bundle(archive, root):
    info = plistlib.loads(read_required(archive, root + "/Info.plist"))
    executable = info.get("CFBundleExecutable")
    if not executable or "/" in executable or "\\" in executable:
        raise ValueError(f"Invalid CFBundleExecutable in {root}")
    return info, read_required(archive, root + "/" + executable)


def main_bundle(archive, identifier):
    bad = archive.testzip()
    if bad:
        raise ValueError(f"IPA CRC check failed: {bad}")
    infos = [name for name in archive.namelist() if name.startswith("Payload/")
             and name.count("/") == 2 and name.endswith(".app/Info.plist")]
    if len(infos) != 1:
        raise ValueError("IPA must contain exactly one main application")
    root = infos[0].rsplit("/", 1)[0]
    info, executable = bundle(archive, root)
    if info.get("CFBundleIdentifier") != identifier:
        raise ValueError(f"Unexpected main bundle identifier: {info.get('CFBundleIdentifier')}")
    macho_commands(executable, 2)
    return root, info


def verify_sideinstaller(combined, lc_root, lc_info, source_path):
    if lc_info.get("LCEmbeddedApps") != ["SideStore", "SideInstaller"]:
        raise ValueError("The three-app package marker is missing or invalid")
    url = urlsplit(lc_info.get("LCCombinedUpdateURL", ""))
    if url.scheme != "https" or not url.hostname or url.username or url.password:
        raise ValueError("The three-app update URL must be HTTPS without credentials")
    embedded = lc_root + "/Frameworks/SideInstallerApp.framework"
    info, executable = bundle(combined, embedded)
    verify_dylib(executable)
    read_required(combined, embedded + "/LCAppInfo.plist")
    read_required(combined, embedded + "/SideInstaller-LICENSE.md")
    with zipfile.ZipFile(source_path) as source:
        _, original = main_bundle(source, "com.frizzlem.sideinstaller")
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            if not original.get(key) or info.get(key) != original[key]:
                raise ValueError(f"Embedded SideInstaller {key} does not match its source IPA")
    extension = lc_root + "/PlugIns/SideInstallerLiveActivity.appex"
    ext_info, ext_executable = bundle(combined, extension)
    macho_commands(ext_executable, 2)
    if ext_info.get("CFBundleIdentifier") != lc_info["CFBundleIdentifier"] + ".SideInstallerLiveActivity":
        raise ValueError("The Live Activity extension must belong to the host")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if ext_info.get(key) != lc_info[key]:
            raise ValueError("The Live Activity version must match the host")
    minimum = lambda bundle_info: tuple(int(part) for part in bundle_info.get("MinimumOSVersion", "0").split("."))
    if minimum(lc_info) < max(minimum(info), minimum(ext_info), (17, 4)):
        raise ValueError("The host minimum iOS version cannot be lower than SideInstaller's")
    schemes = [scheme for entry in lc_info.get("CFBundleURLTypes", [])
               for scheme in entry.get("CFBundleURLSchemes", [])]
    if "sideinstaller" not in schemes or lc_info.get("NSSupportsLiveActivities") is not True:
        raise ValueError("SideInstaller's host URL / Live Activity declarations are missing")
    tasks = lc_info.get("BGTaskSchedulerPermittedIdentifiers", [])
    if lc_info["CFBundleIdentifier"] + ".install.*" not in tasks:
        raise ValueError("The host's background installation task is missing")


def verify_combined(combined_path, sidestore_path, sideinstaller_path=None):
    with zipfile.ZipFile(sidestore_path) as sidestore, zipfile.ZipFile(combined_path) as combined:
        ss_root, ss_info = main_bundle(sidestore, "com.SideStore.SideStore")
        lc_root, lc_info = main_bundle(combined, "com.kdt.livecontainer")
        embedded_root = lc_root + "/Frameworks/SideStoreApp.framework"
        embedded_info, executable = bundle(combined, embedded_root)
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            if not ss_info.get(key) or embedded_info.get(key) != ss_info[key]:
                raise ValueError(f"Embedded SideStore {key} does not match its source IPA")
        verify_dylib(executable)
        strings_path = "/zh-Hans.lproj/Localizable.strings"
        strings = read_required(combined, embedded_root + strings_path)
        if strings != read_required(sidestore, ss_root + strings_path):
            raise ValueError("Embedded Chinese strings do not match the source SideStore IPA")
        if not plistlib.loads(strings):
            raise ValueError("Embedded Chinese strings are empty")
        has_installer = lc_root + "/Frameworks/SideInstallerApp.framework/Info.plist" in combined.namelist()
        if sideinstaller_path is not None:
            verify_sideinstaller(combined, lc_root, lc_info, sideinstaller_path)
        elif has_installer or "SideInstaller" in lc_info.get("LCEmbeddedApps", []):
            raise ValueError("A three-app package requires its SideInstaller source for verification")
    return ss_info["CFBundleShortVersionString"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)
    subparsers.add_parser("dylib").add_argument("path", type=Path)
    combined = subparsers.add_parser("combined")
    combined.add_argument("path", type=Path)
    combined.add_argument("sidestore", type=Path)
    combined.add_argument("--sideinstaller", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "dylib":
            verify_dylib(args.path.read_bytes())
        else:
            print("Verified combined package:", verify_combined(args.path, args.sidestore, args.sideinstaller))
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        parser.exit(1, f"IPA validation failed: {error}\n")


if __name__ == "__main__":
    main()
