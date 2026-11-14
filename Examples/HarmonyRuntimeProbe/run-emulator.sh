#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
deveco="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
device="${HARMONY_DEVICE:-127.0.0.1:5555}"
hdc=("$deveco/sdk/default/openharmony/toolchains/hdc" -t "$device")
bundle=dev.swiftuiport.runtimeprobe
expected=(
  'SWIFT_RUNTIME_PROBE PASS values=217,225'
  'SWIFT_FOUNDATION_PROBE PASS value=42'
  'SWIFT_RENDERER_PROBE PASS value=1'
  'SWIFT_CONCURRENCY_PROBE PASS value=42'
)

property() {
  "${hdc[@]}" shell param get "$1" | tr -d '[:space:]'
}
if [[ $(property const.product.model) != emulator ||
      $(property const.product.devicetype) != 2in1 ||
      $(property const.product.cpu.abilist) != arm64-v8a ]]; then
  echo "Select a connected ARM64 HarmonyOS PC emulator with HARMONY_DEVICE." >&2
  exit 1
fi

export DEVECO_SDK_HOME="$deveco/sdk"
export JAVA_HOME="$deveco/jbr/Contents/Home"
export PATH="$deveco/tools/node/bin:$deveco/tools/ohpm/bin:$JAVA_HOME/bin:$PATH"
if [[ "${SWIFT_RUNTIME_PREPARED:-0}" != 1 ]]; then ./prepare-runtime.sh; fi
ohpm install --all
node "$deveco/tools/hvigor/bin/hvigorw.js" --mode module -p product=default assembleHap --no-daemon

hap=entry/build/default/outputs/default/entry-default-unsigned.hap
unzip -l "$hap" | awk '$4 ~ /^libs\/arm64-v8a\// { print $4 }'
"${hdc[@]}" shell aa force-stop "$bundle" >/dev/null || true
install=$("${hdc[@]}" install -r "$hap")
printf '%s\n' "$install"
[[ "$install" == *'install bundle successfully'* ]]
start=$("${hdc[@]}" shell aa start -b "$bundle" -a EntryAbility)
printf '%s\n' "$start"
[[ "$start" == *'start ability successfully'* ]]
for ((attempt = 0; attempt < 20; attempt++)); do
  pid=$("${hdc[@]}" shell pidof "$bundle" | tr -d '[:space:]')
  if [[ "$pid" =~ ^[0-9]+$ ]]; then
    result=$("${hdc[@]}" shell "hilog -x -P $pid -T SwiftRuntimeProbe")
    complete=1
    for marker in "${expected[@]}"; do
      if [[ "$result" != *"$marker"* ]]; then complete=0; break; fi
    done
    if [[ "$complete" == 1 ]]; then
      printf '%s\n' "$result" | grep -E 'SWIFT_[A-Z]+_PROBE PASS'
      exit 0
    fi
  fi
  sleep 1
done
echo "No PASS marker from the running probe. Recent probe logs:" >&2
"${hdc[@]}" shell 'hilog -x -T SwiftRuntimeProbe' >&2
exit 1
