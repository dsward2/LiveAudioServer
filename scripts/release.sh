#!/usr/bin/env bash
#
# LiveAudioServer — https://github.com/dsward2/LiveAudioServer
#
# Build a signed, notarized, stapled universal (arm64 + x86_64) release of
# LiveAudioServer and package it into a distributable .zip for a GitHub
# release. Intended for users who do not want to install Xcode/SwiftPM —
# they download the zip, unzip, and double-click "Start LiveAudioServer.command".
#
# --------------------------------------------------------------------------
# One-time setup (run once on your release machine):
#
#   1. Have a "Developer ID Application" certificate in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates).
#
#   2. Store notarization credentials in the keychain so this script doesn't
#      see your Apple ID password:
#
#        xcrun notarytool store-credentials LiveAudioServer-notary \
#            --apple-id you@example.com \
#            --team-id  TEAMIDXXXX \
#            --password APP-SPECIFIC-PASSWORD
#
#      (Generate the app-specific password at https://appleid.apple.com.)
#
#   3. Identify your signing identity:
#
#        security find-identity -v -p codesigning
#
#      Copy the full name, e.g. "Developer ID Application: Douglas Ward (XXXXXXXXXX)".
#
# Per-release invocation:
#
#     export DEVELOPER_ID='Developer ID Application: Douglas Ward (XXXXXXXXXX)'
#     export NOTARY_PROFILE='LiveAudioServer-notary'   # keychain profile name
#     ./scripts/release.sh
#
# Output:  build/release/LiveAudioServer-vX.Y.Z-macos-universal.zip
# --------------------------------------------------------------------------

set -euo pipefail

: "${DEVELOPER_ID:?Set DEVELOPER_ID to your 'Developer ID Application: ...' identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool keychain profile name}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

# Extract version from Sources/LiveAudioServer/Version.swift
VERSION="$(awk -F'"' '/^let liveAudioServerVersion / {print $2}' Sources/LiveAudioServer/Version.swift)"
if [[ -z "${VERSION}" ]]; then
    echo "ERROR: could not parse version from Version.swift" >&2
    exit 1
fi

NAME="LiveAudioServer"
RELEASE_DIR_NAME="${NAME}-v${VERSION}"
STAGE_ROOT="${REPO_ROOT}/build/release"
STAGE_DIR="${STAGE_ROOT}/${RELEASE_DIR_NAME}"
ZIP_PATH="${STAGE_ROOT}/${RELEASE_DIR_NAME}-macos-universal.zip"

echo "==> LiveAudioServer ${VERSION} — release build"

echo "[1/8] Cleaning build tree"
rm -rf "${STAGE_ROOT}" .build
mkdir -p "${STAGE_DIR}"

echo "[2/8] Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
SRC_BIN="${BIN_DIR}/${NAME}"
if [[ ! -x "${SRC_BIN}" ]]; then
    echo "ERROR: expected binary at ${SRC_BIN} not found" >&2
    exit 1
fi

# Sanity-check the architectures.
ARCHS="$(lipo -archs "${SRC_BIN}" 2>/dev/null || true)"
echo "      Built: ${SRC_BIN}"
echo "      Archs: ${ARCHS}"
if ! [[ "${ARCHS}" == *"arm64"* && "${ARCHS}" == *"x86_64"* ]]; then
    echo "ERROR: binary is not universal (got: ${ARCHS})" >&2
    exit 1
fi

echo "[3/8] Code-signing with hardened runtime"
DEST_BIN="${STAGE_DIR}/liveaudioserver"
cp "${SRC_BIN}" "${DEST_BIN}"
codesign --force \
         --sign "${DEVELOPER_ID}" \
         --timestamp \
         --options runtime \
         "${DEST_BIN}"
codesign --verify --strict --verbose=2 "${DEST_BIN}"

echo "[4/8] Staging release tree"
# Double-clickable launcher with sensible defaults for the Gqrx/RTL-SDR
# listen-on-your-phone use case (UDP 7355 = Gqrx default UDP output).
cp scripts/templates/Start\ LiveAudioServer.command "${STAGE_DIR}/Start LiveAudioServer.command"
chmod +x "${STAGE_DIR}/Start LiveAudioServer.command"
cp LICENSE                    "${STAGE_DIR}/LICENSE"
cp THIRD-PARTY-LICENSES.md    "${STAGE_DIR}/THIRD-PARTY-LICENSES.md"
cp README.md                  "${STAGE_DIR}/README.md"

echo "[5/8] Zipping for notarization"
NOTARY_ZIP="${STAGE_ROOT}/notarize.zip"
# Use ditto so extended attrs and signatures survive the round trip.
ditto -c -k --keepParent "${STAGE_DIR}" "${NOTARY_ZIP}"

echo "[6/8] Submitting to Apple notary service (this can take 1-15 minutes)"
xcrun notarytool submit "${NOTARY_ZIP}" \
                       --keychain-profile "${NOTARY_PROFILE}" \
                       --wait

echo "[7/8] Stapling the notarization ticket to the binary"
xcrun stapler staple "${DEST_BIN}"
xcrun stapler validate "${DEST_BIN}"

echo "[8/8] Packaging final release zip"
rm -f "${NOTARY_ZIP}" "${ZIP_PATH}"
(cd "${STAGE_ROOT}" && ditto -c -k --keepParent "${RELEASE_DIR_NAME}" "${ZIP_PATH}")

SHA="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
SIZE="$(du -h "${ZIP_PATH}" | awk '{print $1}')"

cat <<EOF

============================================================
  Release artifact ready
============================================================
  File:   ${ZIP_PATH}
  Size:   ${SIZE}
  SHA256: ${SHA}

Next steps:
  1. Tag the release in git:
       git tag v${VERSION} && git push --tags
  2. Create a GitHub release for the tag and upload the zip.
  3. Update the Homebrew formula's url/sha256 if you keep that path.

Users on macOS 13+ install with:
  - Download the zip from the GitHub release
  - Unzip
  - Double-click "Start LiveAudioServer.command"
============================================================
EOF
