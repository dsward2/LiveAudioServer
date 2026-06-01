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

# Apple's notary service only accepts "Developer ID Application" certificates.
# "Apple Development" and "Mac Developer" certs sign successfully but get
# rejected at notarization with "binary is not signed with a valid Developer
# ID certificate". Catch that mistake before we burn the notary roundtrip.
if [[ "${DEVELOPER_ID}" != *"Developer ID Application"* ]]; then
    cat >&2 <<EOF
ERROR: DEVELOPER_ID must name a "Developer ID Application" certificate.
       Got: ${DEVELOPER_ID}

       "Apple Development" and "Mac Developer" certs will sign but get
       rejected at notarization. List your usable identities with:

           security find-identity -v -p codesigning

       and pick the one starting with "Developer ID Application:".
EOF
    exit 1
fi

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

# Multi-arch SwiftPM builds (--arch arm64 --arch x86_64) require XCBuild from
# a full Xcode installation. Command Line Tools alone ships no XCBuild and
# fails with: "xcbuild executable at .../XCBuild.framework/.../xcbuild does
# not exist or is not executable". Detect that and either auto-resolve to
# Xcode.app or fail with a clear hint before we touch anything on disk.
ensure_xcode_developer_dir() {
    local current
    current="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "${current}" && -e "${current}/../SharedFrameworks/XCBuild.framework" ]]; then
        return 0
    fi
    local candidates=(
        "/Applications/Xcode.app/Contents/Developer"
        "${HOME}/Applications/Xcode.app/Contents/Developer"
    )
    local c
    for c in "${candidates[@]}"; do
        if [[ -e "${c}/../SharedFrameworks/XCBuild.framework" ]]; then
            export DEVELOPER_DIR="${c}"
            echo "      DEVELOPER_DIR=${c} (auto-detected; xcode-select points at CLT)"
            return 0
        fi
    done
    local found
    found="$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null | head -1)"
    if [[ -n "${found}" && -e "${found}/Contents/SharedFrameworks/XCBuild.framework" ]]; then
        export DEVELOPER_DIR="${found}/Contents/Developer"
        echo "      DEVELOPER_DIR=${DEVELOPER_DIR} (auto-detected via Spotlight)"
        return 0
    fi
    cat >&2 <<EOF

ERROR: A full Xcode installation (not just Command Line Tools) is required
       for multi-arch builds. SwiftPM uses XCBuild from Xcode.app to drive
       --arch arm64 --arch x86_64, and that framework is not shipped with
       the Command Line Tools.

       Currently active developer dir: ${current:-(none)}

       Fix one of:
         sudo xcode-select -s /Applications/Xcode.app
         export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
EOF
    return 1
}

echo "[0/8] Locating full Xcode (multi-arch builds need XCBuild)"
ensure_xcode_developer_dir

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

# Confirm the resulting signature actually chains to Developer ID — not
# Apple Development — before we send it to the notary. Capture into a
# variable first so codesign's exit code doesn't trip `set -o pipefail`.
CODESIGN_INFO="$(codesign -dvvv "${DEST_BIN}" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"${CODESIGN_INFO}"; then
    echo "ERROR: signed binary's authority is not Developer ID Application." >&2
    echo "       Inspect with: codesign -dvvv ${DEST_BIN}" >&2
    echo "${CODESIGN_INFO}" >&2
    exit 1
fi

echo "[4/8] Staging release tree"
# Double-clickable launcher with sensible defaults for the Gqrx/RTL-SDR
# listen-on-your-phone use case (UDP 7355 = Gqrx default UDP output).
cp scripts/templates/Start\ LiveAudioServer.command "${STAGE_DIR}/Start LiveAudioServer.command"
chmod +x "${STAGE_DIR}/Start LiveAudioServer.command"
# READ-ME-FIRST.txt walks users through the one-time Gatekeeper prompt the
# unsigned .command launcher triggers on first launch. Plain .txt so it
# renders correctly in Finder's Quick Look and on any Mac.
cp scripts/templates/READ-ME-FIRST.txt "${STAGE_DIR}/READ-ME-FIRST.txt"
cp LICENSE                    "${STAGE_DIR}/LICENSE"
cp THIRD-PARTY-LICENSES.md    "${STAGE_DIR}/THIRD-PARTY-LICENSES.md"
cp README.md                  "${STAGE_DIR}/README.md"

echo "[5/8] Zipping for notarization"
NOTARY_ZIP="${STAGE_ROOT}/notarize.zip"
# Use ditto so extended attrs and signatures survive the round trip.
ditto -c -k --keepParent "${STAGE_DIR}" "${NOTARY_ZIP}"

echo "[6/8] Submitting to Apple notary service (this can take 1-15 minutes)"
NOTARY_OUT="${STAGE_ROOT}/notarize.log"
set +e
xcrun notarytool submit "${NOTARY_ZIP}" \
                       --keychain-profile "${NOTARY_PROFILE}" \
                       --wait | tee "${NOTARY_OUT}"
NOTARY_RC=$?
set -e

# notarytool exits 0 as long as the submission was *processed* — even when
# the status is "Invalid". Inspect the output and bail loudly with the
# detailed issues log when Apple rejected the submission.
SUBMISSION_ID="$(awk '/^  id: / {id=$2} END {print id}' "${NOTARY_OUT}")"
STATUS="$(awk '/^  status: / {s=$2} END {print s}' "${NOTARY_OUT}")"

if [[ "${NOTARY_RC}" -ne 0 || "${STATUS}" != "Accepted" ]]; then
    echo
    echo "ERROR: notarization status was '${STATUS:-unknown}'." >&2
    if [[ -n "${SUBMISSION_ID}" ]]; then
        echo "       Fetching Apple's issues log for submission ${SUBMISSION_ID}..." >&2
        echo "       (You can also re-run this manually with:" >&2
        echo "          xcrun notarytool log ${SUBMISSION_ID} \\" >&2
        echo "              --keychain-profile ${NOTARY_PROFILE})" >&2
        echo >&2
        xcrun notarytool log "${SUBMISSION_ID}" \
                            --keychain-profile "${NOTARY_PROFILE}" \
                            >&2 || true
    fi
    exit 1
fi

# `stapler` can only embed a notarization ticket into .app, .pkg, .dmg, or
# .kext wrappers — it errors out (code 73) on a bare Mach-O binary because
# there's nowhere in a flat executable for the ticket to live. The binary is
# still fully notarized: Apple's servers vouch for it via an online check on
# first launch. We try staple anyway in case a future macOS adds support,
# but treat failure as informational.
echo "[7/8] Stapling notarization ticket (best-effort for bare binaries)"
if xcrun stapler staple "${DEST_BIN}" 2>&1 | grep -q "successful"; then
    xcrun stapler validate "${DEST_BIN}" || true
    STAPLED="yes"
else
    echo "      Bare Mach-O cannot be stapled — relying on online notary check at first launch."
    STAPLED="no (notarized online only)"
fi

echo "[8/8] Packaging final release zip"
rm -f "${NOTARY_ZIP}" "${ZIP_PATH}"
(cd "${STAGE_ROOT}" && ditto -c -k --keepParent "${RELEASE_DIR_NAME}" "${ZIP_PATH}")

SHA="$(shasum -a 256 "${ZIP_PATH}" | awk '{print $1}')"
SIZE="$(du -h "${ZIP_PATH}" | awk '{print $1}')"

cat <<EOF

============================================================
  Release artifact ready
============================================================
  File:    ${ZIP_PATH}
  Size:    ${SIZE}
  SHA256:  ${SHA}
  Stapled: ${STAPLED}

Next steps:
  1. Tag the release in git:
       git tag v${VERSION} && git push --tags
  2. Create a GitHub release for the tag and upload the zip.
  3. Update the Homebrew formula's url/sha256 if you keep that path.

Users on macOS 13+ install with:
  - Download the zip from the GitHub release
  - Unzip
  - Double-click "Start LiveAudioServer.command"

Note: the binary is notarized but not stapled (Apple doesn't support
stapling a bare Mach-O). Gatekeeper performs an online ticket lookup on
first launch — users need internet that first time. After that, the
result is cached locally.
============================================================
EOF
