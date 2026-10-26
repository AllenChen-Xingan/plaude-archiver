#!/bin/bash
set -euo pipefail
umask 077
trap 'echo "Installation stopped at line $LINENO. Re-run to retry; verified model files are retained." >&2' ERR
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
here=$(cd "$(dirname "$0")" && pwd -P)
target="${PLAUD_INSTALL_DIR:-$HOME/Library/Application Support/PlaudeLocal/runtime}"
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'This MLX edition requires an Apple Silicon Mac; Intel is not supported.' >&2; exit 1; }
os_major=$(sw_vers -productVersion | cut -d. -f1)
os_minor=$(sw_vers -productVersion | cut -d. -f2)
[[ "$os_major" -gt 26 || ( "$os_major" -eq 26 && "$os_minor" -ge 2 ) ]] || { echo 'This pinned MLX runtime requires macOS 26.2 or newer.' >&2; exit 1; }
if [[ ${1:-} == --check ]]; then
 echo "Destination: $target"
 echo 'No Homebrew, Conda, Python, Xcode or administrator access is required beforehand.'
 echo 'Downloads a private runtime, ~5.92 GB speech/alignment models, ~2.50 GB summary model and speaker assets; allow 20 GiB free.'
 exit 0
fi
activate=1
if [[ ${1:-} == --no-activate ]]; then activate=0; shift; fi
[[ $# == 0 ]] || { echo 'Usage: bash install.sh [--check|--no-activate]'; exit 2; }
[[ $(df -Pk "$HOME" | awk 'NR==2 {print $4}') -ge 20971520 ]] || { echo 'Please free at least 20 GiB.' >&2; exit 1; }
mkdir -p "$target"
if [[ -n $(ls -A "$target") && ! -f "$target/.plaud-install" ]]; then
 echo 'Destination is not a managed installation; choose an empty PLAUD_INSTALL_DIR.' >&2; exit 1
fi
touch "$target/.plaud-install"
mkdir -p "$target/.installer" "$target/tools"
fetch() {
 local url="$1" out="$2" sha="$3"
 if [[ -f "$out" ]] && [[ $(shasum -a 256 "$out" | awk '{print $1}') == "$sha" ]]; then return; fi
 curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 30 "$url" -o "$out.part"
 [[ $(shasum -a 256 "$out.part" | awk '{print $1}') == "$sha" ]] || { echo 'Download checksum mismatch.' >&2; return 1; }
 mv "$out.part" "$out"
}
echo '[1/5] Installing private Python, Git and audio tools (no Homebrew)...'
mm="$target/.installer/micromamba"
fetch https://github.com/mamba-org/micromamba-releases/releases/download/2.9.0-0/micromamba-osx-arm64 "$mm" ec2a072f028e1a7cf20f3e2e74d5a8127cf5a5f27636375b5359811565f4e5be
chmod 755 "$mm"
export MAMBA_ROOT_PREFIX="$target/.installer/mamba"
operation=create
[[ ! -f "$target/deps/conda-meta/history" ]] || operation=install
"$mm" "$operation" --no-rc -p "$target/deps" --file "$here/dependencies-osx-arm64.lock" -y
fetch https://github.com/ggml-org/llama.cpp/releases/download/b11889/llama-b11889-bin-macos-arm64.tar.gz "$target/.installer/llama-metal.tar.gz" 4a3aa4a1e6425d6e0709dc3752943f5e58f4fde6ccb9cebdf0f5de8d1d694f57
mkdir -p "$target/tools/llama"
tar -xzf "$target/.installer/llama-metal.tar.gz" -C "$target/tools/llama" --strip-components=1
export PATH="$target/tools/llama:$target/deps/bin:$PATH"
python="$target/deps/bin/python3"
"$python" "$here/verify.py" "$here/payload"
ditto "$here/payload" "$target"
echo '[2/5] Preparing isolated Bluetooth runtime...'
"$python" -m venv "$target/work/plaud-research/venv"
py="$target/work/plaud-research/venv/bin/python"
"$py" -m pip install --retries 3 -r "$here/bluetooth-requirements.txt"
echo '[3/5] Downloading/checking speech, alignment and speaker models...'
"$py" "$target/outputs/plaud-diarization/download-model.py"
"$py" "$target/outputs/plaud-qwen-asr/setup.py"
echo '[4/5] Downloading/checking local summary model...'
"$py" "$target/outputs/plaud" install summary --library "$target/self-test-library"
echo '[5/5] Initializing models with public test audio...'
"$py" "$target/outputs/plaud" process "$target/smoke.flac" --engine qwen-asr --summary-provider local --library "$target/self-test-library" --offline
if [[ "$activate" == 0 ]]; then
 echo "Installation and inference self-test passed at $target (no app/preferences activated)."; exit 0
fi
mkdir -p "$HOME/.local/bin" "$HOME/Applications"
"$py" - "$target" <<'PY'
import pathlib,shlex,sys,subprocess
root=pathlib.Path(sys.argv[1]);app=root/'Plaude Archiver CN.app'
(app/'Contents/Resources/RuntimeRoot.txt').write_text(str(root)+'\n')
subprocess.run(['codesign','--force','--sign','-','--preserve-metadata=entitlements',str(app)],check=True)
launcher=pathlib.Path.home()/'.local/bin/plaud'
launcher.write_text('#!/bin/bash\nexport PATH='+shlex.quote(str(root/'tools/llama')+':'+str(root/'deps/bin')+':/usr/bin:/bin:/usr/sbin:/sbin')+'\nexec '+shlex.quote(str(root/'work/plaud-research/venv/bin/python'))+' '+shlex.quote(str(root/'outputs/plaud'))+' "$@"\n');launcher.chmod(0o755)
PY
ditto "$target/Plaude Archiver CN.app" "$HOME/Applications/Plaude Archiver CN.app"
defaults write ai.local.plaudarchiver.cn RuntimeFolder -string "$target"
defaults write ai.local.plaudarchiver.cn PreferredASREngine -string qwen-asr
defaults write ai.local.plaudarchiver.cn SummaryProvider -string local
echo "Installed. CLI: $HOME/.local/bin/plaud"
echo 'Open the app, choose China or International and log in for Bluetooth authorization.'
echo 'Optional: add export PATH="$HOME/.local/bin:$PATH" to your shell profile.'
open "$HOME/Applications/Plaude Archiver CN.app"
