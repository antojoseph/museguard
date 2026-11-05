#!/usr/bin/env python3
"""Build a macOS installer from a release app with a cooked Muse renderer."""

import argparse
import json
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
PRODUCT_ID = "com.antojoseph.museguard.installer"
MACH_O_MAGIC = {bytes.fromhex(magic) for magic in (
    "cffaedfe", "feedfacf", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}


def run(*command):
    subprocess.run(command, check=True)


def check_release_app(app):
    contents = app / "Contents"
    info = plistlib.loads((contents / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.sentinelpet.app" or info.get("MuseBuildConfiguration") != "release":
        raise ValueError("Build the release app with scripts/build-app.sh before creating the installer")
    renderer = json.loads((contents / "Resources/MuseRenderer.json").read_bytes())
    executable = Path(renderer.get("executable", ""))
    if (
        renderer.get("version") != 2
        or executable.parent != Path("Contents/Helpers/MuseRenderer.app/Contents/MacOS")
        or not (app / executable).is_file()
    ):
        raise ValueError("The release app must contain the cooked standalone renderer")
    for binary in (contents / "MacOS" / info["CFBundleExecutable"], app / executable):
        architectures = subprocess.check_output(("/usr/bin/lipo", "-archs", binary), text=True)
        if "arm64" not in architectures.split():
            raise ValueError(f"{binary.name} cannot run on Apple Silicon")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+(?:\.\d+)*", version):
        raise ValueError("Invalid release app version")
    return version


def sign_app(app, identity):
    options = ("--timestamp=none",) if identity == "-" else ("--timestamp", "--options", "runtime")
    sign = ("/usr/bin/codesign", "--force", *options, "--sign", identity)
    helpers = app / "Contents/Helpers"
    # Existing ad-hoc renderer signatures already work. Developer ID releases
    # need all executables and libraries signed with the distribution identity.
    scope = helpers / "LocalInference" if identity == "-" else helpers
    for path in sorted(scope.rglob("*")):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                is_binary = stream.read(4) in MACH_O_MAGIC
            if is_binary:
                run(*sign, path)
    if identity != "-":
        bundles = [path for path in helpers.rglob("*") if path.is_dir() and path.suffix in {".app", ".framework", ".bundle"}]
        for bundle in sorted(bundles, key=lambda path: len(path.parts), reverse=True):
            run(*sign, bundle)
    run(*sign, app)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def add_attribution(resources, runtime_source):
    destination = resources / "Attribution"
    destination.mkdir(exist_ok=True)
    muse = ROOT / "Unreal/MuseGuard/Content/Muse"
    shutil.copyfile(muse / "ATTRIBUTION.txt", destination / "Muse Jolly.txt")
    shutil.copyfile(muse / "ROUND_GLASSES_ATTRIBUTION.txt", destination / "Round Glasses.txt")
    shutil.copyfile(ROOT / "Unreal/AVATAR_SOURCE.md", destination / "Avatar Sources.md")
    shutil.copyfile(runtime_source / "LICENSE", destination / "llama.cpp LICENSE.txt")
    (destination / "Unreal Engine.txt").write_text(
        "Muse Guard uses Unreal® Engine. Unreal® is a trademark or registered trademark of "
        "Epic Games, Inc. in the United States of America and elsewhere.\n"
        "Unreal® Engine, Copyright 1998 – 2026, Epic Games, Inc. All rights reserved.\n",
        encoding="utf-8",
    )


def build_package(stage, app, version, options):
    root = app.parent
    component = stage / "MuseGuard-component.pkg"
    component_plist = stage / "Component.plist"
    component_plist.write_bytes(plistlib.dumps([{
        "RootRelativeBundlePath": app.name,
        "BundleIsRelocatable": False,
        "BundleIsVersionChecked": True,
        "BundleHasStrictIdentifier": True,
        "BundleOverwriteAction": "upgrade",
    }]))
    run("/usr/bin/pkgbuild", "--root", root, "--component-plist", component_plist,
        "--identifier", "com.antojoseph.museguard.app", "--version", version,
        "--install-location", "/Applications", component)

    requirements = stage / "Requirements.plist"
    requirements.write_bytes(plistlib.dumps({"os": ["14.0"], "arch": ["arm64"], "home": False}))
    distribution = stage / "Distribution.xml"
    run("/usr/bin/productbuild", "--synthesize", "--product", requirements,
        "--package", component, distribution)

    resources = stage / "InstallerResources"
    resources.mkdir()
    (resources / "Welcome.html").write_text(
        "<html><body><h1>Muse Guard</h1>"
        "<p>Install the local desktop companion and its 3D avatar in Applications.</p>"
        "<p>Requires an Apple Silicon Mac with macOS 14 or later.</p>"
        "<p>On first launch, choose Accessibility for window text and Screen Recording for visual checks. "
        "macOS asks you to approve each permission. Chrome text checks work through the extension without either.</p>"
        "<p>Muse downloads about 20 GB of model files during setup. Window and browser analysis runs on this Mac.</p>"
        '<p><a href="https://github.com/antojoseph/museguard/tree/app">View the source code</a>.</p></body></html>',
        encoding="utf-8",
    )
    (resources / "Conclusion.html").write_text(
        "<html><body><h1>Open Muse Guard</h1>"
        "<p>Open Muse Guard in Applications. Get started walks you through screen access, the local model, and Chrome setup. "
        "Quit an older running copy before opening the installed app.</p></body></html>",
        encoding="utf-8",
    )
    tree = ET.parse(distribution)
    installer = tree.getroot()
    ET.SubElement(installer, "title").text = "Muse Guard"
    ET.SubElement(installer, "welcome", file="Welcome.html")
    ET.SubElement(installer, "conclusion", file="Conclusion.html")
    tree.write(distribution, encoding="utf-8", xml_declaration=True)

    package = stage / f"MuseGuard-{version}-arm64.pkg"
    signing = ("--sign", options.installer_signing_identity, "--timestamp") if options.installer_signing_identity else ()
    run("/usr/bin/productbuild", "--distribution", distribution, "--resources", resources,
        "--package-path", stage, "--identifier", PRODUCT_ID, "--version", version, *signing, package)
    if options.installer_signing_identity:
        run("/usr/sbin/pkgutil", "--check-signature", package)
    if options.notary_profile:
        run("/usr/bin/xcrun", "notarytool", "submit", package, "--keychain-profile",
            options.notary_profile, "--wait")
        run("/usr/bin/xcrun", "stapler", "staple", package)
        run("/usr/bin/xcrun", "stapler", "validate", package)
    return package


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Release/MuseGuard.app")
    parser.add_argument("--runtime", type=Path, default=Path.home() / "Library/Application Support/MuseGuard/LocalModel/runtime")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/Installers")
    parser.add_argument("--app-signing-identity", help="Developer ID Application identity")
    parser.add_argument("--installer-signing-identity", help="Developer ID Installer identity")
    parser.add_argument("--notary-profile", help="Explicitly submit to Apple using this notarytool keychain profile")
    options = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Build on an Apple Silicon Mac")
    if bool(options.app_signing_identity) != bool(options.installer_signing_identity):
        parser.error("Provide both Developer ID identities for a signed distribution")
    if options.notary_profile and not options.installer_signing_identity:
        parser.error("Notarization requires both Developer ID identities")

    try:
        source = options.app.resolve(strict=True)
        version = check_release_app(source)
        output = options.output_dir.resolve()
        output.mkdir(parents=True, exist_ok=True)
        identity = options.app_signing_identity or "-"
        with tempfile.TemporaryDirectory(prefix=".museguard-package-", dir=output) as directory:
            stage = Path(directory)
            app = stage / "Payload/MuseGuard.app"
            app.parent.mkdir()
            run("/usr/bin/ditto", source, app)
            runtime = app / "Contents/Helpers/LocalInference"
            run(sys.executable, ROOT / "scripts/bundle-local-inference.py", options.runtime, runtime)
            run(ROOT / "scripts/bundle-browser.sh", app, identity)
            add_attribution(app / "Contents/Resources", options.runtime)
            sign_app(app, identity)
            run(runtime / "llama-server", "--version")
            package = build_package(stage, app, version, options)
            final = output / package.name
            package.replace(final)
            print(f"Installer: {final}")
        if not options.installer_signing_identity:
            print("Local installer only: the package is unsigned and the app uses ad-hoc signing.")
        elif not options.notary_profile:
            print("Package signed. Submit it for notarization before distribution.")
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Installer build failed: {error}\n")


if __name__ == "__main__":
    main()
