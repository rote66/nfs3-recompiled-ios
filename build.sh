#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")" && pwd -P)"
target="${1:-device}"

usage() {
    cat <<'USAGE'
用法：
  ./build.sh             编译真机 Release 并生成 IPA
  ./build.sh device      同上
  ./build.sh simulator   编译 ARM64 模拟器 App
  ./build.sh clean       清理所有构建目录、包及构建日志
  ./build.sh --help      显示帮助

BUILD_JOBS=4 控制并行编译数量。IPA 需要重新签名后安装。
USAGE
}

if [ "$#" -gt 1 ]; then
    usage >&2
    exit 2
fi

case "$target" in
    --help|-h|help) usage; exit 0 ;;
    clean)
        rm -rf -- "$repo_root/build" "$repo_root/ios/build-device" "$repo_root/ios/build-simulator" "$repo_root/ios/output"
        echo "已清理构建目录和输出。"
        exit 0
        ;;
    device) sdk=iphoneos ;;
    simulator) sdk=iphonesimulator ;;
    *) usage >&2; exit 2 ;;
esac

build_jobs="${BUILD_JOBS:-4}"
if ! [[ "$build_jobs" =~ ^[1-9][0-9]*$ ]]; then
    echo "BUILD_JOBS 必须是正整数。" >&2
    exit 2
fi

if [ "$(uname -s)" != Darwin ]; then
    echo "需要 macOS 和完整 Xcode。" >&2
    exit 1
fi
if ! command -v cmake >/dev/null 2>&1; then
    echo "请先安装 CMake 3.15 或以上版本，例如 brew install cmake。" >&2
    exit 1
fi
if ! xcrun --sdk "$sdk" --find clang >/dev/null 2>&1; then
    echo "未找到 iOS SDK，请安装完整 Xcode，并用 xcode-select 选择其 Developer 目录。" >&2
    exit 1
fi
if ! xcrun --toolchain Metal --sdk "$sdk" --find metal >/dev/null 2>&1; then
    echo "未找到 Metal 编译工具，请运行 xcodebuild -downloadComponent MetalToolchain。" >&2
    exit 1
fi

build_dir="$repo_root/ios/build-$target"
output_dir="$repo_root/ios/output"
mkdir -p "$output_dir"
build_log="$output_dir/build-$target.log"

cmake -S "$repo_root" -B "$build_dir" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    2>&1 | tee "$build_log"
cmake --build "$build_dir" --parallel "$build_jobs" 2>&1 | tee -a "$build_log"

app="$build_dir/ios/nfs3.app"
codesign --force --sign - "$app" 2>&1 | tee -a "$build_log"
codesign --verify --deep --strict "$app" 2>&1 | tee -a "$build_log"

if [ "$target" = device ]; then
    staging="$(mktemp -d)"
    trap 'rm -rf -- "$staging"' EXIT
    mkdir -p "$staging/Payload"
    ditto "$app" "$staging/Payload/NFS3.app"
    (cd "$staging" && /usr/bin/zip -qr "$staging/NFS3-ios14.ipa" Payload)
    unzip -tq "$staging/NFS3-ios14.ipa" 2>&1 | tee -a "$build_log"
    mv "$staging/NFS3-ios14.ipa" "$output_dir/NFS3-ios14.ipa"
    for package in "$output_dir"/*.ipa; do
        if [ "$package" != "$output_dir/NFS3-ios14.ipa" ]; then
            rm -- "$package"
        fi
    done
    shasum -a 256 "$output_dir/NFS3-ios14.ipa" > "$output_dir/SHA256.txt"
    echo "IPA：$output_dir/NFS3-ios14.ipa（临时签名，安装前需重新签名）" | tee -a "$build_log"
else
    echo "模拟器 App：$app" | tee -a "$build_log"
fi
