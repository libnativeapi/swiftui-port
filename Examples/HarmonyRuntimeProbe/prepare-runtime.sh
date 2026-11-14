#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
work="$PWD/.build"
inputs="$work/runtime"
sdk_name=swift-6.4.2-RELEASE_static-linux-0.1.0
archive="${SWIFT_STATIC_SDK_ARCHIVE:-$work/$sdk_name.artifactbundle.tar.gz}"
checksum=3786b179936d9cc9e266dd506bd1654176358d7b25288e243359f4d17cc4dc5a
sdk_path="$sdk_name.artifactbundle/$sdk_name/swift-linux-musl/musl-1.2.5.sdk/aarch64"

mkdir -p "$inputs" "$work/sdk"
if [[ ! -f "$archive" && -z "${SWIFT_STATIC_SDK_ARCHIVE:-}" ]]; then
  url="https://download.swift.org/swift-6.4.2-release/static-sdk/swift-6.4.2-RELEASE"
  curl --fail --location --retry 2 --output "$archive.part" "$url/$sdk_name.artifactbundle.tar.gz"
  mv "$archive.part" "$archive"
fi
printf '%s  %s\n' "$checksum" "$archive" | shasum -a 256 -c -
sdk="$work/sdk/$sdk_path"
if [[ ! -f "$work/sdk/.arm64-extracted" ]]; then
  tar -xzf "$archive" -C "$work/sdk" "$sdk_path"
  touch "$work/sdk/.arm64-extracted"
fi

if [[ -n "${SWIFT_TOOLCHAIN_BIN:-}" ]]; then
  swiftc=("$SWIFT_TOOLCHAIN_BIN/swiftc")
  ar=("$SWIFT_TOOLCHAIN_BIN/llvm-ar")
  sdk_args=()
else
  swiftc=(swiftly run swiftc)
  ar=(swiftly run llvm-ar)
  sdk_args=(+6.4.2)
fi
"${swiftc[@]}" --version ${sdk_args[@]+"${sdk_args[@]}"} | grep -F '(swift-6.4.2-RELEASE)'

resources="$sdk/usr/lib/swift_static"
libraries="$resources/linux-static"
# This SDK's serialized modules reference this placeholder VFS path.
if [[ ! -e "$resources/<clang-system-vfs-overlay>" ]]; then
  printf '%s\n' '{"version":0,"roots":[]}' > "$resources/<clang-system-vfs-overlay>"
fi
compile() {
  local module="$1" output="$2"
  shift 2
  "${swiftc[@]}" -target aarch64-swift-linux-musl -sdk "$sdk" -resource-dir "$resources" \
    -static-stdlib -parse-as-library -whole-module-optimization -emit-object -emit-module -O \
    -D SWIFTUI_PORT_HARMONY -I "$inputs" -module-name "$module" \
    -emit-module-path "$inputs/$module.swiftmodule" -o "$inputs/$output.o" "$@" ${sdk_args[@]+"${sdk_args[@]}"}
}

dazzui="${DAZZUI_SWIFT_PATH:-$PWD/../../../../dazzlabs/dazzui/packages/swift/DazzUI}"
if [[ ! -f "$dazzui/Example/Sources/Example/App.swift" ]]; then
  echo "Set DAZZUI_SWIFT_PATH to the DazzUI Swift package directory." >&2
  exit 1
fi
compile SwiftUIRuntime SwiftUIRuntime -package-name SwiftUIPort ../../Sources/SwiftUIRuntime/*.swift
compile SwiftUI SwiftUI ../../Sources/SwiftUI/SwiftUI.swift
compile FluentIcons FluentIcons "$dazzui/Windows/FluentIcons/FluentIcon.swift"

swift_sources() {
  local source
  while IFS= read -r -d '' source; do sources+=("$source"); done \
    < <(find "$1" -name '*.swift' ! -name Main.swift -print0)
}
sources=()
swift_sources "$dazzui/Sources/DazzUI"
compile DazzUI DazzUI "${sources[@]}"
sources=()
swift_sources "$dazzui/Example/Sources/Example"
compile HarmonyRuntimeProbe Probe entry/src/main/cpp/{Probe,HarmonyBackend,GalleryHost}.swift "${sources[@]}"

mkdir -p entry/src/main/resources/rawfile/fluent
cp "$dazzui/Windows/FluentIcons/Resources/"*.svg entry/src/main/resources/rawfile/fluent/

for name in swiftCore swift_Concurrency swift_StringProcessing swift_RegexParser \
  swiftMusl swiftSynchronization swiftDispatch dispatch BlocksRuntime \
  Foundation FoundationEssentials FoundationInternationalization CoreFoundation \
  _FoundationCShims _FoundationCollections _FoundationICU; do
  cp "$libraries/lib$name.a" "$inputs/"
done
cp "$libraries/aarch64/swiftrt.o" "$sdk/usr/lib/libc++.a" "$sdk/usr/lib/libc++abi.a" "$inputs/"
cp "$sdk/usr/lib/libfts.a" "$inputs/"
# Use the OHOS C++ library's exception TLS implementation. The Linux archive
# uses local-exec TLS for this member, which cannot be linked into a shared object.
"${ar[@]}" d "$inputs/libc++abi.a" cxa_exception_storage.cpp.o ${sdk_args[@]+"${sdk_args[@]}"}
