#!/usr/bin/env python3
"""Stage the pinned llama.cpp server and its linked libraries in a Mac app."""

import argparse
from pathlib import Path
import re
import shutil
import subprocess


def run(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT)


def local_dependencies(path):
    commands = run("/usr/bin/otool", "-l", str(path))
    search_paths = re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)", commands)
    if any(directory not in {"@loader_path", "@executable_path"} for directory in search_paths):
        raise ValueError(f"{path.name} has an external library search path")
    for entry in run("/usr/bin/otool", "-L", str(path)).splitlines()[1:]:
        reference = entry.strip().split(" (", 1)[0]
        if reference.startswith(("/usr/lib/", "/System/Library/")):
            continue
        directory, separator, filename = reference.partition("/")
        if not separator or directory not in {"@rpath", "@loader_path", "@executable_path"} or Path(filename).name != filename:
            raise ValueError(f"{path.name} links an external library: {reference}")
        yield filename


def bundle(source, destination):
    version = run(str(source / "llama-server"), "--version")
    if "(build 11946, commit 8ca4060b7)" not in version:
        raise ValueError(f"Expected llama.cpp b11946 (8ca4060b7), got: {version.strip()}")

    pending = ["llama-server"]
    binaries = set()
    while pending:
        name = pending.pop()
        if name in binaries:
            continue
        path = (source / name).resolve(strict=True)
        if path.parent != source:
            raise ValueError(f"Runtime dependency escapes its source directory: {name}")
        if run("/usr/bin/lipo", "-archs", str(path)).strip() != "arm64":
            raise ValueError(f"Expected an Apple Silicon runtime binary: {name}")
        pending.extend(local_dependencies(path))
        binaries.add(name)

    destination.mkdir(parents=True)
    for name in sorted(binaries):
        shutil.copyfile(source / name, destination / name)
        (destination / name).chmod(0o755)
    staged = run(str(destination / "llama-server"), "--version")
    if staged != version:
        raise ValueError("Staged llama.cpp server version differs from the source")
    print(f"Staged llama.cpp b11946 with {len(binaries) - 1} linked libraries.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        bundle(args.source.resolve(strict=True), args.destination)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Cannot bundle the local inference runtime: {error}\n")


if __name__ == "__main__":
    main()
