"""Embed the complete SideInstaller application in a LiveContainer build."""

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import tempfile
from urllib.parse import urljoin, urlsplit
import zipfile

from verify_ipa import main_bundle, verify_dylib


FRAMEWORK = "SideInstallerApp.framework"
EXTENSION = "SideInstallerLiveActivity.appex"
IDENTIFIER = "com.frizzlem.sideinstaller"


def minimum_version(*infos):
    values = [info.get("MinimumOSVersion", "17.4") for info in infos]
    return max(values, key=lambda value: tuple(int(part) for part in value.split(".")))


def merge_values(host, guest, key):
    values = list(host.get(key, []))
    for value in guest.get(key, []):
        if value not in values:
            values.append(value)
    if values:
        host[key] = values


def merge_info(host, guest, update_url):
    url = urlsplit(update_url)
    if url.scheme != "https" or not url.hostname or url.username or url.password:
        raise ValueError("The combined update URL must be an HTTPS URL without credentials")
    keys = ("CFBundleURLTypes",
            "CFBundleDocumentTypes", "LSApplicationQueriesSchemes", "NSBonjourServices",
            "UIBackgroundModes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations")
    for key in keys:
        merge_values(host, guest, key)
    # Continued-processing tasks belong to the installed host, not its dylib.
    # isideload rebases this prefix together with the host's signed bundle ID.
    tasks = dict(guest)
    tasks["BGTaskSchedulerPermittedIdentifiers"] = [
        host["CFBundleIdentifier"] + ".install.*"]
    merge_values(host, tasks, "BGTaskSchedulerPermittedIdentifiers")
    for key, value in guest.items():
        if key.startswith("NSLocation") and key.endswith("UsageDescription"):
            host.setdefault(key, value)
    host.setdefault("NSLocalNetworkUsageDescription", guest["NSLocalNetworkUsageDescription"])
    host["NSSupportsLiveActivities"] = True
    host["MinimumOSVersion"] = minimum_version(host, guest)
    host["LCEmbeddedApps"] = ["SideStore", "SideInstaller"]
    host["LCSideInstallerShortcutsVersion"] = 1
    host["LCCombinedUpdateURL"] = update_url
    host["LCCombinedSourceURL"] = urljoin(update_url, "source.json")
    return host


def extract_payload(archive, root, destination):
    prefix = root + "/"
    for member in archive.infolist():
        if not member.filename.startswith(prefix):
            continue
        relative = PurePosixPath(member.filename[len(prefix):])
        if relative.is_absolute() or ".." in relative.parts or "\\" in str(relative):
            raise ValueError("Unsafe IPA member: " + member.filename)
        if member.is_dir():
            continue
        target = destination.joinpath(*relative.parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(member) as source, target.open("wb") as output:
            shutil.copyfileobj(source, output)
        target.chmod((member.external_attr >> 16) & 0o777 or 0o644)


def relocate_extension(app, host, host_info):
    source = app / "PlugIns" / EXTENSION
    if not source.is_dir():
        raise ValueError("SideInstaller's pairing Live Activity extension is missing")
    others = [path for path in app.rglob("*.appex") if path != source]
    if others:
        raise ValueError("Unrecognized SideInstaller extensions: " + ", ".join(p.name for p in others))
    destination = host / "PlugIns" / EXTENSION
    if destination.exists():
        raise ValueError("The host already contains " + EXTENSION)
    info = plistlib.loads((source / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != IDENTIFIER + ".LiveActivity":
        raise ValueError("Unexpected SideInstaller Live Activity identifier")
    host_info["MinimumOSVersion"] = minimum_version(host_info, info)
    info["CFBundleIdentifier"] = host_info["CFBundleIdentifier"] + ".SideInstallerLiveActivity"
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        info[key] = host_info[key]
    (source / "Info.plist").write_bytes(plistlib.dumps(info))
    destination.parent.mkdir(exist_ok=True)
    shutil.move(source, destination)
    executable = destination / info["CFBundleExecutable"]
    subprocess.run(["ldid", "-S", str(executable)], check=True)


def synchronize_extension_versions(host, host_info):
    for extension in (host / "PlugIns").glob("*.appex"):
        path = extension / "Info.plist"
        info = plistlib.loads(path.read_bytes())
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            info[key] = host_info[key]
        path.write_bytes(plistlib.dumps(info))


def embed_recovery(archive, host, host_info):
    """Keep the matching installer with the IPA so recovery never redownloads it."""
    prefix = "CertificateReuseBuild/"
    try:
        binary = archive.read(prefix + "siboot-aarch64")
        expected = archive.read(prefix + "SHA256SUMS").decode().split()[0]
    except (KeyError, UnicodeDecodeError, IndexError) as error:
        raise ValueError("The SideInstaller transport has no verified recovery installer") from error
    digest = hashlib.sha256(binary).hexdigest()
    if digest != expected or not binary.startswith(b"\x7fELF\x02\x01"):
        raise ValueError("The embedded recovery installer failed verification")
    destination = host / "Recovery"
    destination.mkdir()
    (destination / "siboot-aarch64").write_bytes(binary)
    for name in ("install.sh", "install-local.sh"):
        source = Path(__file__).parent / "recovery" / name
        (destination / name).write_bytes(source.read_bytes().replace(b"\r\n", b"\n"))
    host_info["LCRecoveryBootstrapSHA256"] = digest
    host_info["LCRecoveryFormatVersion"] = 1


def embed(ipa, host, converter, update_url, license_path):
    info_path = host / "Info.plist"
    host_info = plistlib.loads(info_path.read_bytes())
    framework = host / "Frameworks" / FRAMEWORK
    if framework.exists():
        raise ValueError("The host already contains " + FRAMEWORK)
    with tempfile.TemporaryDirectory(prefix="sideinstaller-") as temporary:
        source = Path(temporary) / "SideInstaller.app"
        with zipfile.ZipFile(ipa) as archive:
            root, guest_info = main_bundle(archive, IDENTIFIER)
            extract_payload(archive, root, source)
            embed_recovery(archive, host, host_info)
        executable = source / guest_info["CFBundleExecutable"]
        converted = executable.with_suffix(".dylib")
        subprocess.run([str(converter), str(executable), str(converted)], check=True)
        verify_dylib(converted.read_bytes())
        converted.replace(executable)
        subprocess.run(["ldid", "-S", str(executable)], check=True)
        relocate_extension(source, host, host_info)
        template = Path(__file__).parent / "sidelc" / "SideInstaller-LCAppInfo.plist"
        shutil.copy2(template, source / "LCAppInfo.plist")
        shutil.copy2(license_path, source / "SideInstaller-LICENSE.md")
        shutil.move(source, framework)
    synchronize_extension_versions(host, host_info)
    info_path.write_bytes(plistlib.dumps(merge_info(host_info, guest_info, update_url)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("host", type=Path)
    parser.add_argument("--converter", type=Path, required=True)
    parser.add_argument("--update-url", required=True)
    parser.add_argument("--license", type=Path, required=True)
    args = parser.parse_args()
    embed(args.ipa, args.host, args.converter.resolve(), args.update_url, args.license)


if __name__ == "__main__":
    main()
