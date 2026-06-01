#!/usr/bin/env bash
#
# LiveAudioServer — https://github.com/dsward2/LiveAudioServer
#
# Build a universal (arm64 + x86_64) static Mp3Lame.xcframework from the LAME
# 3.100 source release and stage it at Frameworks/Mp3Lame.xcframework.
#
# This produces the artifact that Package.swift consumes via a binaryTarget,
# so `swift build` works on a fresh clone without any external package
# manager (no Homebrew, no MacPorts).
#
# Re-run this script only when bumping the LAME version. The generated
# Frameworks/Mp3Lame.xcframework is committed to the repo.
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

echo "[6/7] Assembling Headers and module map"
HDR="${BUILD_ROOT}/Headers"
rm -rf "${HDR}"
mkdir -p "${HDR}"
cp "${BUILD_ROOT}/stage-arm64/include/lame/lame.h" "${HDR}/lame.h"
cat > "${HDR}/module.modulemap" <<'MODMAP'
module CLame {
    header "lame.h"
    export *
}
MODMAP

echo "[7/7] Creating Mp3Lame.xcframework"
xcodebuild -create-xcframework \
    -library  "${UNI_DIR}/libmp3lame.a" \
    -headers  "${HDR}" \
    -output   "${OUT_XCF}" \
    >/dev/null

echo
echo "Done."
echo "  Output:  ${OUT_XCF}"
du -sh "${OUT_XCF}"
echo
echo "You can now build the project with: swift build -c release"
