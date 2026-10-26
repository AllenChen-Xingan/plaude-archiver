#!/bin/bash
# Run from any directory. Downloads public source/models only; never reads audio.
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd -P)
root=$(cd -- "$here/../.." && pwd -P)
revision=1b0ed50d686873128a4129b3510ce3914c849bab
[[ $(uname -m) == arm64 ]] || { echo 'Apple Silicon required.' >&2; exit 1; }
for tool in git swift python3 curl ffmpeg ffprobe; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool (see report)" >&2; exit 1; }
done
mkdir -p "$root/work" "$here/bin" "$here/licenses"
repo="$root/work/FluidAudio"
if [[ ! -d "$repo/.git" ]]; then
  git init "$repo"
  git -C "$repo" remote add origin https://github.com/FluidInference/FluidAudio.git
  git -C "$repo" fetch --depth 1 origin "$revision"
  git -C "$repo" checkout --detach "$revision"
fi
[[ $(git -C "$repo" rev-parse HEAD) == "$revision" ]] || {
  echo 'Existing FluidAudio checkout has another revision; use a clean installation folder.' >&2; exit 1;
}
if git -C "$repo" apply --reverse --check "$here/offline.patch" 2>/dev/null; then
  : # Our exact patch already installed.
else
  git -C "$repo" apply --check "$here/offline.patch"
  git -C "$repo" apply "$here/offline.patch"
fi
if [[ -z ${SDKROOT:-} && -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
cd "$repo"
# Full default traits are required by the upstream CLI at this revision.
swift build -c release --product fluidaudiocli
bin=$(swift build -c release --show-bin-path)
install -m 755 "$bin/fluidaudiocli" "$here/bin/fluidaudiocli"
for resource in "$bin"/*.bundle; do
  [[ ! -d "$resource" ]] || cp -R "$resource" "$here/bin/"
done
cp "$repo/LICENSE" "$here/licenses/FluidAudio-APACHE-2.0.txt"
cp -R "$repo/ThirdPartyLicenses" "$here/licenses/"
python3 "$here/download-model.py"
cp "$root/work/plaud-english/models/phonon-2/LICENSE" "$here/licenses/Phonon-2-LICENSE.txt"
cp "$root/work/plaud-english/models/phonon-2/NOTICE" "$here/licenses/Phonon-2-NOTICE.txt"
echo 'Installed. First transcription compiles the ANE model; allow several minutes.'
