#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:-device}"
case "$platform" in
    device) sdk=iphoneos ;;
    simulator) sdk=iphonesimulator ;;
    *) echo "Usage: bash ios/build.sh [device|simulator]" >&2; exit 2 ;;
esac
build="$root/ios/build-$platform"
cmake -S "$root" -B "$build" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
cmake --build "$build" --parallel "${BUILD_JOBS:-4}"
app="$build/ios/nfs3.app"
codesign --force --sign - "$app"
if [ "$platform" = device ]; then
    output="$root/ios/output"
    mkdir -p "$output"
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT
    mkdir -p "$staging/Payload"
    ditto "$app" "$staging/Payload/NFS3.app"
    (cd "$staging" && /usr/bin/zip -qr "$staging/NFS3-ios14.ipa" Payload)
    mv "$staging/NFS3-ios14.ipa" "$output/NFS3-ios14.ipa"
    for package in "$output"/*.ipa; do
        if [ "$package" != "$output/NFS3-ios14.ipa" ]; then
            rm -- "$package"
        fi
    done
    shasum -a 256 "$output/NFS3-ios14.ipa" > "$output/SHA256.txt"
    echo "IPA: $output/NFS3-ios14.ipa (ad-hoc signed; re-sign for installation)"
fi
