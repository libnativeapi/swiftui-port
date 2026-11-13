#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

sdk=${SWIFT_WASM_SDK:-swift-6.4.2-RELEASE_wasm}
product=${1:-Counter}
configuration=${2:-release}

SWIFTUI_PORT_WEB=1 swift package --swift-sdk "$sdk" --scratch-path .build/wasm \
  js --product "$product" -c "$configuration"

package=.build/wasm/plugins/PackageToJS/outputs/Package
site=.build/web
staging=$(mktemp -d .build/web.XXXXXX)
trap 'rm -rf -- "$staging"' EXIT
mkdir "$staging/app"
cp -R "$package"/. "$staging/app/"
npm install --prefix "$staging/app" --ignore-scripts --omit=dev --no-audit --no-fund
cp Web/index.html "$staging/index.html"
rm -rf -- "$site"
mv -- "$staging" "$site"
printf 'Web build: %s\n' "$PWD/$site"
