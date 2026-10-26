#!/bin/bash
# Public model/source setup only; does not read recordings.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(cd -- "$here/../.." && pwd -P)
repo="$root/work/FluidAudio"
[[ $(uname -m) == arm64 ]] || { echo 'Apple Silicon required.' >&2; exit 1; }
[[ -f "$root/outputs/plaud-engine/bin/fluidaudiocli" ]] || {
  echo 'First run outputs/plaud-engine/setup.sh.' >&2; exit 1;
}
[[ $(git -C "$repo" rev-parse HEAD) == 1b0ed50d686873128a4129b3510ce3914c849bab ]] || {
  echo 'Unexpected FluidAudio source revision; refusing to patch.' >&2; exit 1;
}
git -C "$repo" apply --reverse --check "$root/outputs/plaud-engine/offline.patch" || {
  echo "ASR offline patch missing; run outputs/plaud-engine/setup.sh first." >&2; exit 1;
}
python3 "$here/download-model.py"
if git -C "$repo" apply --reverse --check "$here/process.patch" 2>/dev/null; then
  :
else
  git -C "$repo" apply --check "$here/process.patch"
  git -C "$repo" apply "$here/process.patch"
fi
if [[ -z ${SDKROOT:-} && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
cd "$repo"
swift build -c release --product fluidaudiocli
bin=$(swift build -c release --show-bin-path)
install -m 755 "$bin/fluidaudiocli" "$root/outputs/plaud-engine/bin/fluidaudiocli"
for resource in "$bin"/*.bundle; do
  [[ ! -d "$resource" ]] || cp -R "$resource" "$root/outputs/plaud-engine/bin/"
done
python3 "$here/test_alignment.py"
echo 'Offline VBx ready; inference never downloads models.'
