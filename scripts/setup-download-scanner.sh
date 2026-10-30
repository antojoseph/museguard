#!/usr/bin/env bash
# Installs only user-local copies; never executes the package's installer scripts.
set -euo pipefail
MUSE_SCANNER_VERSION=1.5.4
MUSE_SCANNER_PACKAGE_SHA256=df7fa753e2f9f67f3bc99b2a40a3be7ef559088c68ad6bdf66b4b5764e965bd6
MUSE_SCANNER_BASE="$HOME/Library/Application Support/MuseGuard/DownloadScanner"
MUSE_SCANNER_PACKAGE=""
MUSE_SCANNER_UPDATE_ONLY=0
MUSE_SCANNER_NO_UPDATE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) MUSE_SCANNER_PACKAGE="${2:?--package requires a path}"; shift 2 ;;
    --update-only) MUSE_SCANNER_UPDATE_ONLY=1; shift ;;
    --no-update) MUSE_SCANNER_NO_UPDATE=1; shift ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[[ "$(uname -s)" == Darwin && "$(id -u)" != 0 ]] || { echo 'Run as your normal macOS user, without sudo.' >&2; exit 1; }
umask 077
mkdir -p "$MUSE_SCANNER_BASE/database"
MUSE_SCANNER_WORK="$(mktemp -d "$MUSE_SCANNER_BASE/setup.XXXXXX")"
trap 'rm -rf "$MUSE_SCANNER_WORK"' EXIT
MUSE_SCANNER_ENGINE="$MUSE_SCANNER_BASE/clamav"
if [[ "$MUSE_SCANNER_UPDATE_ONLY" == 0 ]]; then
  if [[ -z "$MUSE_SCANNER_PACKAGE" ]]; then
    MUSE_SCANNER_PACKAGE="$MUSE_SCANNER_WORK/clamav.pkg"
    curl --fail --location --proto '=https' --tlsv1.2 --max-time 600 \
      --output "$MUSE_SCANNER_PACKAGE" "https://www.clamav.net/downloads/production/clamav-$MUSE_SCANNER_VERSION.macos.universal.pkg"
  fi
  [[ "$(shasum -a 256 "$MUSE_SCANNER_PACKAGE" | awk '{print $1}')" == "$MUSE_SCANNER_PACKAGE_SHA256" ]] || { echo 'Package checksum mismatch; nothing installed.' >&2; exit 1; }
  pkgutil --check-signature "$MUSE_SCANNER_PACKAGE" > "$MUSE_SCANNER_WORK/package-signature.txt"
  /usr/bin/grep -Fq 'Status: signed by a developer certificate issued by Apple for distribution' "$MUSE_SCANNER_WORK/package-signature.txt"
  /usr/bin/grep -Fq 'Developer ID Installer: Cisco (DE8Y96K9QP)' "$MUSE_SCANNER_WORK/package-signature.txt"
  pkgutil --expand-full "$MUSE_SCANNER_PACKAGE" "$MUSE_SCANNER_WORK/expanded"
  MUSE_SCANNER_EXPANDED="$MUSE_SCANNER_WORK/expanded"
  MUSE_SCANNER_PROGRAMS="$MUSE_SCANNER_EXPANDED/clamav-$MUSE_SCANNER_VERSION.macos.universal-programs.pkg/Payload/usr/local/clamav"
  MUSE_SCANNER_LIBRARIES="$MUSE_SCANNER_EXPANDED/clamav-$MUSE_SCANNER_VERSION.macos.universal-libraries.pkg/Payload/usr/local/clamav/lib"
  MUSE_SCANNER_STAGE="$MUSE_SCANNER_WORK/clamav"
  mkdir -p "$MUSE_SCANNER_STAGE/bin" "$MUSE_SCANNER_STAGE/lib" "$MUSE_SCANNER_STAGE/etc" "$MUSE_SCANNER_STAGE/licenses"
  for tool in clamscan freshclam sigtool; do
    cp -p "$MUSE_SCANNER_PROGRAMS/bin/$tool" "$MUSE_SCANNER_STAGE/bin/$tool"
    codesign --verify --strict "$MUSE_SCANNER_STAGE/bin/$tool"
    codesign -dv --verbose=2 "$MUSE_SCANNER_STAGE/bin/$tool" > "$MUSE_SCANNER_WORK/tool-signature.txt" 2>&1
    /usr/bin/grep -Fq 'TeamIdentifier=DE8Y96K9QP' "$MUSE_SCANNER_WORK/tool-signature.txt"
  done
  # Preserve the package's relative dylib symlinks; omit the 463 MB build-only archive.
  cp -pR "$MUSE_SCANNER_LIBRARIES/"*.dylib "$MUSE_SCANNER_STAGE/lib/"
  cp -pR "$MUSE_SCANNER_PROGRAMS/etc/certs" "$MUSE_SCANNER_STAGE/etc/"
  cp -p "$MUSE_SCANNER_EXPANDED/Resources/License.txt" "$MUSE_SCANNER_STAGE/licenses/ClamAV-GPL-2.txt"
  cp -p "$MUSE_SCANNER_WORK/package-signature.txt" "$MUSE_SCANNER_STAGE/package-signature.txt"
  printf '%s\n' "$MUSE_SCANNER_PACKAGE_SHA256" > "$MUSE_SCANNER_STAGE/package.sha256"
  cat > "$MUSE_SCANNER_STAGE/PROVENANCE.txt" <<EOF
ClamAV $MUSE_SCANNER_VERSION, official Cisco macOS universal package.
Source: https://www.clamav.net/downloads/production/clamav-$MUSE_SCANNER_VERSION.macos.universal.pkg
SHA256: $MUSE_SCANNER_PACKAGE_SHA256
Original package signer: Developer ID Installer: Cisco (DE8Y96K9QP).
Local modification: replace /usr/local/clamav/lib LC_RPATH with loader-relative paths.
Modified binaries carry a local ad-hoc signature, not Cisco's original signature.
Corresponding upstream source: https://www.clamav.net/downloads/production/clamav-$MUSE_SCANNER_VERSION.tar.gz
License: licenses/ClamAV-GPL-2.txt; upstream licensing: https://docs.clamav.net/manual/Introduction.html
EOF
  while IFS= read -r -d '' library; do
    codesign --verify --strict "$library"
    install_name_tool -rpath /usr/local/clamav/lib '@loader_path' "$library"
    codesign --force --sign - "$library"
    codesign --verify --strict "$library"
  done < <(find "$MUSE_SCANNER_STAGE/lib" -type f -name '*.dylib' -print0)
  for tool in clamscan freshclam sigtool; do
    install_name_tool -rpath /usr/local/clamav/lib '@loader_path/../lib' "$MUSE_SCANNER_STAGE/bin/$tool"
    codesign --force --sign - "$MUSE_SCANNER_STAGE/bin/$tool"
    codesign --verify --strict "$MUSE_SCANNER_STAGE/bin/$tool"
  done
  "$MUSE_SCANNER_STAGE/bin/clamscan" --version
  printf 'DatabaseMirror database.clamav.net\n' > "$MUSE_SCANNER_STAGE/etc/freshclam.conf"
  "$MUSE_SCANNER_STAGE/bin/freshclam" --config-file="$MUSE_SCANNER_STAGE/etc/freshclam.conf" --version
  # Keep an earlier working engine until the relocated replacement has passed its checks.
  if [[ -e "$MUSE_SCANNER_ENGINE" ]]; then mv "$MUSE_SCANNER_ENGINE" "$MUSE_SCANNER_WORK/previous-engine"; fi
  mv "$MUSE_SCANNER_STAGE" "$MUSE_SCANNER_ENGINE"
fi
[[ -x "$MUSE_SCANNER_ENGINE/bin/freshclam" ]] || { echo 'Install the scanner before updating its definitions.' >&2; exit 1; }
cat > "$MUSE_SCANNER_BASE/freshclam.conf" <<EOF
DatabaseDirectory "$MUSE_SCANNER_BASE/database"
CVDCertsDirectory "$MUSE_SCANNER_ENGINE/etc/certs"
DatabaseMirror database.clamav.net
DatabaseOwner $(id -un)
ConnectTimeout 30
ReceiveTimeout 120
MaxAttempts 1
TestDatabases yes
ScriptedUpdates yes
LogTime yes
EOF
if [[ "$MUSE_SCANNER_NO_UPDATE" == 1 ]]; then
  echo 'Engine installed. Definitions were not updated; no complete scan is available until definitions load successfully.'
  exit 0
fi
# FreshClam validates official signed databases and honors its persisted CDN cooldown.
# Do not add mirror rotation, direct CVD URLs, user-agent overrides, or automatic retries.
if ! CVD_CERTS_DIR="$MUSE_SCANNER_ENGINE/etc/certs" "$MUSE_SCANNER_ENGINE/bin/freshclam" --config-file="$MUSE_SCANNER_BASE/freshclam.conf" --stdout; then
  echo 'Definition update unavailable. Honor the reported cooldown; Muse must not call unscanned files clean.' >&2
  exit 1
fi
printf 'Muse Guard download scanner ready: %s\n' "$MUSE_SCANNER_ENGINE/bin/clamscan"
