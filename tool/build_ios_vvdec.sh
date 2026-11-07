#!/bin/bash
# Rebuild the bundled, pinned VVdeC library. Requires Xcode, CMake and Ninja.
set -euo pipefail
vvc_repo_root=$(cd "$(dirname "$0")/.." && pwd)
vvc_build_root="$vvc_repo_root/build/ios-vvdec-library"
vvc_revision=d2614690cf13ceee1631dd6d30141755b8a689de
vvc_cmake=${CMAKE_BIN:-cmake}
vvc_ninja=${NINJA_BIN:-ninja}
mkdir -p "$vvc_build_root"
if [ ! -d "$vvc_build_root/source/.git" ]; then
    git init "$vvc_build_root/source"
    git -C "$vvc_build_root/source" remote add origin https://github.com/fraunhoferhhi/vvdec.git
    git -C "$vvc_build_root/source" fetch --depth 1 origin "$vvc_revision"
    git -C "$vvc_build_root/source" checkout --detach FETCH_HEAD
fi
[ "$(git -C "$vvc_build_root/source" rev-parse HEAD)" = "$vvc_revision" ] || {
    echo 'VVdeC source revision differs from the pinned revision.' >&2; exit 1;
}
for vvc_sdk in iphoneos iphonesimulator; do
    "$vvc_cmake" -S "$vvc_build_root/source" -B "$vvc_build_root/$vvc_sdk" -G Ninja \
        -DCMAKE_MAKE_PROGRAM="$(command -v "$vvc_ninja")" \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$vvc_sdk" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
        -DCMAKE_BUILD_TYPE=Release -DVVDEC_LIBRARY_ONLY=ON -DVVDEC_TOPLEVEL_OUTPUT_DIRS=OFF \
        -DVVDEC_ENABLE_X86_SIMD=OFF -DVVDEC_ENABLE_ARM_SIMD=ON -DVVDEC_ENABLE_LINK_TIME_OPT=OFF
    "$vvc_cmake" --build "$vvc_build_root/$vvc_sdk" --parallel 4
 done
mkdir -p "$vvc_build_root/headers/vvdec"
cp "$vvc_build_root/iphoneos/vvdec/vvdec.h" "$vvc_build_root/headers/vvdec/"
cp "$vvc_build_root/source/include/vvdec/"{vvdecDecl.h,sei.h} "$vvc_build_root/headers/vvdec/"
# Generate into build first, then replace only the decoder's own framework.
rm -rf "$vvc_build_root/VVdeC.xcframework"
xcodebuild -create-xcframework \
    -library "$vvc_build_root/iphoneos/lib/libvvdec.a" -headers "$vvc_build_root/headers" \
    -library "$vvc_build_root/iphonesimulator/lib/libvvdec.a" -headers "$vvc_build_root/headers" \
    -output "$vvc_build_root/VVdeC.xcframework"
rm -rf "$vvc_repo_root/ios/Frameworks/VVdeC/VVdeC.xcframework"
cp -R "$vvc_build_root/VVdeC.xcframework" "$vvc_repo_root/ios/Frameworks/VVdeC/"
cp "$vvc_build_root/source/LICENSE.txt" "$vvc_repo_root/ios/Frameworks/VVdeC/LICENSE.txt"
