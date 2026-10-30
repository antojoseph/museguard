#!/usr/bin/env python3
"""Exercise the compiled helper with its installed build-time Engine denied.

This is an opt-in integration check after scripts/package-renderer.sh. It reads
only generated character frames; no desktop capture or app permissions are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import time
import zlib


def decode_frame(path):
    try:
        data = path.read_bytes()
    except FileNotFoundError:
        return None
    if len(data) < 24:
        return None
    magic, version, width, height, sequence, flags = struct.unpack_from("<6I", data)
    header = 40 if version == 2 else 24
    if magic != 0x4D555345 or version not in (1, 2) or not 1 <= width <= 2048 or not 1 <= height <= 2048:
        raise RuntimeError("Invalid renderer frame header")
    if len(data) != header + width * height * 4:
        raise RuntimeError("Invalid renderer frame length")
    return width, height, sequence, flags, data[header:]


def save_png(path, width, height, pixels):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    scanlines = b"".join(b"\0" + pixels[row * width * 4:(row + 1) * width * 4] for row in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=root / "build/PackagedRenderer/MuseRenderer.app")
    parser.add_argument("--output", type=Path, default=root / "build/packaged-renderer-check")
    parser.add_argument("--engine", type=Path, default=Path(os.environ.get("MUSE_UNREAL_ROOT", "/Users/Shared/Epic Games/UE_5.8")))
    arguments = parser.parse_args()
    app = arguments.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    if not executable.is_file():
        raise RuntimeError("Package the renderer before running this integration check")
    content = app / "Contents/UE/MuseGuard/Content"
    for required in ("Paks/MuseGuard-Mac.pak", "Muse/Jolly.musemesh", "Muse/RoundGlasses.json", "Muse/GuardAccessories.json"):
        if not (content / required).is_file():
            raise RuntimeError("Packaged renderer data missing: " + required)
    sandbox = shutil.which("sandbox-exec")
    if not sandbox:
        raise RuntimeError("sandbox-exec is required to prove the installed Engine is inaccessible")
    # JSON quoting is also valid string quoting for this sandbox profile.
    denied_sources = [arguments.engine.resolve(),
                      Path(os.environ.get("MUSE_AVATAR_SOURCE", str(root / "Unreal/MuseGuard"))).resolve(),
                      Path.home() / "Library/Application Support/MuseGuard/Renderer",
                      Path.home() / "Library/Application Support/MuseGuard/RendererPackaging"]
    profile = '(version 1) (allow default) (deny network*) ' + ' '.join(
        '(deny file-read* (subpath %s))' % json.dumps(str(path)) for path in denied_sources
    ) + ' (deny file-write* (subpath %s))' % json.dumps(str(app))
    arguments.output.mkdir(parents=True, exist_ok=True)
    result = {"app": str(app), "installed_engine_denied": str(arguments.engine.resolve()), "network_denied": True,
              "build_sources_denied": [str(path) for path in denied_sources[1:]], "helper_bundle_write_denied": True, "frames": []}
    with tempfile.TemporaryDirectory(prefix="muse-packaged-check-") as temporary:
        bridge = Path(temporary)
        command = {"state": "idle", "accessory": "guard", "gaze": 0, "reduceMotion": False,
                   "debugMotion": False, "phaseStart": time.time(), "phaseDuration": 1.0,
                   "travelDirection": 0, "working": False, "protectionActive": False,
                   "desktopScene": {"enabled": False}, "precisePointing": False, "pointingDirection": 0}

        def heartbeat():
            command["heartbeat"] = time.time()
            pending = bridge / "command.tmp"
            pending.write_text(json.dumps(command))
            pending.replace(bridge / "command.json")

        heartbeat()
        with (arguments.output / "stdout.log").open("wb") as log:
            process = subprocess.Popen([sandbox, "-p", profile, str(executable), "/Game/Maps/MuseStage", "-game",
                                        "-RenderOffscreen", "-windowed", "-ResX=448", "-ResY=448", "-nosound",
                                        "-unattended", "-NoSplash", "-NoLoadingScreen", "-MuseBridge=" + str(bridge)],
                                       cwd=executable.parent, stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 60
                started = time.monotonic()
                while decode_frame(bridge / "frame.rgba") is None:
                    if process.poll() is not None:
                        raise RuntimeError(f"Standalone renderer exited before producing frames ({process.returncode}); see {arguments.output / 'stdout.log'}")
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Standalone renderer did not produce a frame within 60 seconds")
                    heartbeat()
                    time.sleep(0.1)
                result["startup_seconds"] = round(time.monotonic() - started, 2)
                for name, state, seconds, working, pointing in (
                    ("idle", "idle", 2, False, None),
                    ("working", "idle", 3, True, None),
                    ("point-left", "stop", 2, False, -1),
                    ("point-right", "explain", 2, False, 1),
                    ("sleep", "sleep", 8, False, None),
                ):
                    command.update(state=state, phaseStart=time.time(), working=working,
                                   precisePointing=pointing is not None, pointingDirection=pointing or 0)
                    begin = decode_frame(bridge / "frame.rgba")[2]
                    began = time.monotonic()
                    while time.monotonic() - began < seconds:
                        if process.poll() is not None:
                            raise RuntimeError(f"Standalone renderer exited during {name}")
                        heartbeat()
                        time.sleep(0.1)
                    width, height, sequence, flags, pixels = decode_frame(bridge / "frame.rgba")
                    opaque = sum(alpha > 24 for alpha in pixels[3::4])
                    if sequence <= begin or not 1000 < opaque < width * height * 0.95:
                        raise RuntimeError(f"Empty, stalled, or opaque-background frame during {name}")
                    if pointing is not None:
                        arm_pixels = [x for y in range(int(height * 0.4), int(height * 0.6)) for x in range(width)
                                      if pixels[(y * width + x) * 4 + 3] > 24]
                        left_reach = width / 2 - min(arm_pixels)
                        right_reach = max(arm_pixels) - width / 2
                        if (left_reach - right_reach) * -pointing < 8:
                            raise RuntimeError(f"Pointing arm does not face the requested screen direction during {name}")
                    save_png(arguments.output / (name + ".png"), width, height, pixels)
                    result["frames"].append({"state": name, "width": width, "height": height, "flags": flags,
                                              "visible_pixels": opaque, "fps": round((sequence - begin) / (time.monotonic() - began), 1),
                                              "sha256": hashlib.sha256(pixels).hexdigest()})
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
    (arguments.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
