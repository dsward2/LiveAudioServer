#!/usr/bin/env bash
#
# LiveAudioServer — https://github.com/dsward2/LiveAudioServer
#
# Build a universal (arm64 + x86_64) CLame.framework-based XCFramework from
# the LAME 3.100 source release and stage it at Frameworks/Mp3Lame.xcframework.
#
# LiveAudioServerCore vendors its own copy of lame (as the CLame binaryTarget)
# rather than depending on PipelineHelpers' PHCLame, to keep LiveAudioServer
# fully self-contained. Both packages can coexist in the same app (AntennaHead
# depends on both) because CLame is packaged as a macOS versioned framework
# bundle — staged under CLame.framework/ — while PHCLame remains a static
# library XCFramework staging its headers flat to include/. A flat static lib
# for CLame would collide at include/module.modulemap with PHCLame's own map.
#
# This script produces the static library slices and then assembles the
# versioned framework bundle + XCFramework. Run it when bumping LAME, then
# re-copy the libphmp3lame.a and phlame.h into PipelineHelpers' xcframework
# (PipelineHelpers keeps its own static-library copy, renamed to avoid the
# flat-header collision — see PipelineHelpers/Package.swift for details).
#
# Re-run this script only when bumping the LAME version.
#
# Requirements (already present on any macOS 13+ machine with Xcode):
#   - curl, tar, make, lipo
#   - xcodebuild (for -create-xcframework)
#   - Xcode command-line tools

set -euo pipefail

LAME_VERSION="3.100"
LAME_SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
LAME_URL="https://downloads.sourceforge.net/project/lame/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz"

# macOS deployment target — match Package.swift's .macOS(.v13).
MACOSX_DEPLOYMENT_TARGET="13.0"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/.build-mp3lame"
OUT_XCF="${REPO_ROOT}/Frameworks/Mp3Lame.xcframework"

echo "[1/7] Preparing build directories"
rm -rf "${BUILD_ROOT}" "${OUT_XCF}"
mkdir -p "${BUILD_ROOT}" "${REPO_ROOT}/Frameworks"
cd "${BUILD_ROOT}"

echo "[2/7] Downloading lame-${LAME_VERSION}.tar.gz"
curl -fL -o "lame-${LAME_VERSION}.tar.gz" "${LAME_URL}"

actual_sha="$(shasum -a 256 "lame-${LAME_VERSION}.tar.gz" | awk '{print $1}')"
if [[ "${actual_sha}" != "${LAME_SHA256}" ]]; then
    echo "ERROR: SHA256 mismatch for LAME tarball" >&2
    echo "  expected: ${LAME_SHA256}" >&2
    echo "  actual:   ${actual_sha}" >&2
    exit 1
fi

tar xzf "lame-${LAME_VERSION}.tar.gz"
SRC="${BUILD_ROOT}/lame-${LAME_VERSION}"

# LAME 3.100 has a long-standing issue where xmmintrin.h causes a build failure
# when compiled against modern Apple SDKs. The fix is to remove the offending
# decl in include/libmp3lame.sym (the .a doesn't need it).
# Reference: https://sourceforge.net/p/lame/mailman/lame-dev/thread/...
sed -i.bak '/lame_init_old/d' "${SRC}/include/libmp3lame.sym"

HOST_ARCH="$(uname -m)"      # arm64 on Apple Silicon, x86_64 on Intel
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -find clang)"

build_one_arch() {
    local arch="$1"
    local stage="${BUILD_ROOT}/stage-${arch}"
    echo "[*] Configuring + building libmp3lame for ${arch}"
    rm -rf "${stage}"
    mkdir -p "${stage}"

    # When the slice arch matches the host arch we let autotools run in native
    # mode (no --host=); otherwise we cross-compile and pre-seed any test
    # results that would require running the produced binary.
    local host_arg=()
    local cross_env=()
    if [[ "${arch}" != "${HOST_ARCH}" ]]; then
        host_arg=("--host=${arch}-apple-darwin")
        # LAME's configure runs a couple of "does this work at runtime" probes
        # that obviously can't execute when cross-compiling. Provide sane
        # defaults so configure doesn't bail.
        cross_env=(ac_cv_func_malloc_0_nonnull=yes ac_cv_func_realloc_0_nonnull=yes)
    fi

    # LAME 3.100 predates clang 16+'s default of treating implicit function
    # declarations as errors. The -Wno-* flags keep that legacy code compiling
    # under modern Xcode without touching the upstream sources.
    local cflags="-arch ${arch} -isysroot ${SDK_PATH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -O2 -fPIC -Wno-implicit-function-declaration -Wno-implicit-int"
    local ldflags="-arch ${arch} -isysroot ${SDK_PATH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET}"

    (
        cd "${SRC}"
        make distclean >/dev/null 2>&1 || true
        # Use `+ "..."` parameter expansion so empty arrays don't trip `set -u`.
        env ${cross_env[@]+"${cross_env[@]}"} \
            ./configure \
                ${host_arg[@]+"${host_arg[@]}"} \
                --prefix="${stage}" \
                --disable-shared \
                --enable-static \
                --disable-frontend \
                --disable-decoder \
                --disable-analyzer-hooks \
                --disable-gtktest \
                CC="${CC}" \
                CFLAGS="${cflags}" \
                LDFLAGS="${ldflags}" \
                >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null
        make install >/dev/null
    )
}

echo "[3/7] Building arm64 slice"
build_one_arch arm64

echo "[4/7] Building x86_64 slice"
build_one_arch x86_64

echo "[5/7] lipo-ing universal libmp3lame.a"
UNI_DIR="${BUILD_ROOT}/universal"
mkdir -p "${UNI_DIR}"
lipo -create \
    "${BUILD_ROOT}/stage-arm64/lib/libmp3lame.a" \
    "${BUILD_ROOT}/stage-x86_64/lib/libmp3lame.a" \
    -output "${UNI_DIR}/libmp3lame.a"
lipo -info "${UNI_DIR}/libmp3lame.a"

echo "[6/7] Assembling versioned CLame.framework bundle"
# Package as a macOS versioned framework (not a flat static-library XCFramework)
# so that Xcode stages it as CLame.framework/ rather than merging its headers
# flat into include/. Without this, two packages in the same graph that both
# vendor a static lame XCFramework would collide at include/module.modulemap.
FW_BUILD="${BUILD_ROOT}/CLame.framework"
FW_A="${FW_BUILD}/Versions/A"
mkdir -p "${FW_A}/Headers" "${FW_A}/Modules" "${FW_A}/Resources"

# Binary: static archive renamed to match the framework name
cp "${UNI_DIR}/libmp3lame.a" "${FW_A}/CLame"
cp "${BUILD_ROOT}/stage-arm64/include/lame/lame.h" "${FW_A}/Headers/lame.h"

cat > "${FW_A}/Modules/module.modulemap" <<'MODMAP'
framework module CLame {
    umbrella header "lame.h"
    export *
}
MODMAP

cat > "${FW_A}/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CLame</string>
    <key>CFBundleIdentifier</key><string>com.dsward.CLame</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>CLame</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${LAME_VERSION}.0</string>
    <key>CFBundleVersion</key><string>${LAME_VERSION}.0</string>
    <key>MinimumOSVersion</key><string>${MACOSX_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
PLIST

# macOS versioned framework requires Current symlink and top-level symlinks
(cd "${FW_BUILD}/Versions" && ln -s A Current)
(cd "${FW_BUILD}" && ln -s Versions/Current/CLame CLame)
(cd "${FW_BUILD}" && ln -s Versions/Current/Headers Headers)
(cd "${FW_BUILD}" && ln -s Versions/Current/Modules Modules)
(cd "${FW_BUILD}" && ln -s Versions/Current/Resources Resources)

echo "[7/7] Creating Mp3Lame.xcframework"
# Use -framework (not -library) so the XCFramework references the bundle
xcodebuild -create-xcframework \
    -framework "${FW_BUILD}" \
    -output    "${OUT_XCF}" \
    >/dev/null

echo
echo "Done."
echo "  Output:  ${OUT_XCF}"
du -sh "${OUT_XCF}"
echo
echo "To update PipelineHelpers with a new LAME build:"
echo "  Copy ${UNI_DIR}/libmp3lame.a → PipelineHelpers/Frameworks/Mp3Lame.xcframework/.../libphmp3lame.a"
echo "  Copy ${BUILD_ROOT}/stage-arm64/include/lame/lame.h → PipelineHelpers/.../Headers/phlame.h"
echo
echo "You can now build the project with: swift build -c release"
