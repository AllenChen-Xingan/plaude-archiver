Plaud Local v0.2.0-preview.1 — Apple Silicon, macOS 26.2+, 20 GiB free disk

One command from the release page installs this package. For an extracted package: bash plaud-local-preview/install.sh
Check requirements: bash plaud-local-preview/install.sh --check
The installer downloads a checksum-verified private micromamba runtime, installs pinned Python 3.14, Git and ffmpeg from conda-forge, and downloads the official Metal-enabled llama.cpp binary. It creates isolated Python environments, downloads checksum-verified models and runs a public-audio ASR/speaker/summary self-test. No preinstalled Homebrew, Conda, Python or Xcode is required. No sudo or shell profile changes. macOS Bluetooth permission and your own login still require your interaction.

Models: Qwen3-ASR bf16 + ForcedAligner (~5.92 GB), VBx speaker models and Qwen3-4B local summary (~2.50 GB). Failed setup can be rerun; complete verified model files are reused, incomplete files restart. No subscription or API key is needed for local processing. Internet access to GitHub, conda-forge, PyPI and Hugging Face is required during setup; there is no silently selected download mirror.

CLI: ~/.local/bin/plaud
UI: ~/Applications/Plaude Archiver CN.app (both China and international accounts)
Runtime: ~/Library/Application Support/PlaudeLocal/runtime
Example: ~/.local/bin/plaud process '/path/meeting.m4a' --library '/path/My recordings' --background

First setup: choose China (plaud.cn) or International (plaud.ai), click Login; device credentials are prepared automatically for a single owned Note Pro. If multiple devices belong to the account, scan/select and click Prepare Bluetooth keys. Verify connection and import. Only device ownership, key and signature endpoints are allowed. Plaud cloud recordings are never listed/downloaded. Routine BLE uses local credentials, no web token; reauthorize after account/device/key changes. Groq/DeepSeek are separate optional AI providers; supply your own API key and explicitly authorize uploads.

Scope: Note Pro protocol 20; downloads one smallest completed recording, retains device original. Automatic batch sync is a separate unfinished feature. China real-account BLE was tested. International routing and redirect restrictions are tested, but a real international-account login remains to be tested. No account, private recording, device identity or API key is packaged. The bundled LibriSpeech test audio is public domain.

Developer preview: ad-hoc signed, not Apple notarized; a downloaded app may require approval in Privacy & Security. Do not disable Gatekeeper globally. No second clean physical Mac has been tested. Homebrew is neither invoked nor installed. Bluetooth permission and device availability are required. Closing UI does not cancel CLI workers; no login item is installed.
