# Plaud Local for Mac — preview

A CLI-first recording library for Plaud Note Pro. Choose a Finder folder, import audio over Bluetooth or from a file, transcribe with local MLX Qwen3-ASR, label speakers with VBx, and generate a title, summary and action items locally. The SwiftUI app invokes the same background CLI jobs.

## One-command install

```bash
curl -fsSL https://raw.githubusercontent.com/AllenChen-Xingan/plaude-archiver/v0.2.0-preview.1/install.sh | /bin/bash
```

**Apple Silicon, macOS 26.2 or newer, at least 20 GiB free disk; 16 GB RAM or more recommended.** The pinned MLX binary requires macOS 26.2; Intel and older macOS are not supported by this build. Apple M5/macOS 27 is the real machine tested. This is a preview, not a notarized production release.

No Homebrew, Python, Conda, Git or Xcode needs to be installed first. The installer downloads a private, checksum-verified runtime under `~/Library/Application Support/PlaudeLocal/runtime`, including Python, Git, ffmpeg and official Metal-enabled llama.cpp. It does not use sudo, modify system Python or edit shell profiles. It downloads and verifies Qwen3-ASR + alignment models (~5.92 GB), the speaker models and the local summary model (~2.50 GB), then runs a public-audio inference self-test. Rerun the same command after an interrupted install; verified complete models are reused.

Network access to GitHub, conda-forge, PyPI and Hugging Face is needed during installation. The app opens after installation. OS permission prompts and your own login still need your interaction. macOS can require approving the ad-hoc-signed app in Privacy & Security; the installer never disables Gatekeeper.

To inspect before executing, download [install.sh](install.sh). The bootstrap pins the release archive's SHA-256; dependency versions/hashes are in [the runtime lock](outputs/plaud-distribution/dependencies-osx-arm64.lock). Downloading an archive manually and running `bash plaud-local-preview/install.sh --check` performs only the compatibility check.

## First setup: China or International

1. Choose **China / plaud.cn** or **International / plaud.ai** in the first setup page, then click **Login and prepare Bluetooth authentication**.
2. Login is used only for device ownership, the device encryption key and device signature. The application does **not** list or download Plaud cloud recordings and does not use Plaud transcription.
3. A single owned Note Pro is prepared automatically. For multiple owned devices, scan, select the intended serial number and prepare its credentials. Account changes do not reuse the old account's keys.
4. Choose a recording library folder. Wake the recorder, disconnect it from the phone if needed, then **Scan → Verify connection → Import one recording**.

Routine BLE uses a private local identity file without the web login token. Authentication may need refreshing after account, device binding or key changes. Signing out of the webpage does not revoke the saved device key. Keep the application-support directory private; never share it or put it in a Git repository.

**Validation boundary:** China-account authentication and real Note Pro BLE download were tested. International host selection, permitted regional redirects and cross-region rejection are covered by tests; a real international-account login is still awaiting user testing. This is not a claim that every firmware, account or macOS version works. Only Note Pro protocol 20 is supported. The current download action imports one smallest completed recording and retains the device original; automatic background batch sync remains a separate feature proposal.

## CLI and storage

```bash
~/.local/bin/plaud scan
~/.local/bin/plaud prepare-bluetooth --serial YOUR_DEVICE_SERIAL
~/.local/bin/plaud connect --serial YOUR_DEVICE_SERIAL
~/.local/bin/plaud download --serial YOUR_DEVICE_SERIAL --library "$HOME/Documents/My recordings"
~/.local/bin/plaud process "/path/meeting.m4a" --library "$HOME/Documents/My recordings" --background
~/.local/bin/plaud jobs --library "$HOME/Documents/My recordings"
```

The app is installed at `~/Applications/Plaude Archiver CN.app` (the name is retained for compatibility; it supports both region choices). Audio, versioned TXT/SRT/JSON transcripts, Markdown summaries, names and job status are saved in your chosen folder. Closing the UI does not cancel background jobs. No startup/login service is installed.

Default ASR is Qwen3-ASR on MLX; default summary is local Qwen3-4B through llama.cpp. Apple Speech/Foundation Models remain optional. Groq Whisper transcription and Groq/DeepSeek summaries are also optional, using **your own** API key stored in Keychain and explicit upload authorization. No personal key, account, private recording or model weights are bundled. Local inference does not upload recordings. Speaker labels are anonymous labels, not identity recognition.

## Development and validation

The app is Swift/SwiftUI; CLI/auth/library code is Python; the installer is Bash. [Architecture and operations](outputs/plaud-app/README.md). Python tests:

```bash
python3 -m pip install requests cryptography
python3 -m unittest discover -s outputs/plaud-app/tests
```

Native app: `cd PlaudeArchiver && ./build.sh` (requires a compatible Swift SDK). Release archives also need the pinned FluidAudio binary/resources and Apple helpers; install those build artifacts before running `outputs/plaud-distribution/build.py`. Ordinary end users use the release installer and need no compiler. Installation testing with `--no-activate` installs into `PLAUD_INSTALL_DIR` and runs real inference without replacing the GUI or preferences.

Independent interoperability project, not affiliated with Plaud. Based on [roopen219/plaude-archiver](https://github.com/roopen219/plaude-archiver). See [LICENSE](LICENSE); runtime/model license notices accompany the respective downloads. The tiny LibriSpeech initialization sample is public domain.
