# Runtime architecture

The SwiftUI app is a view/controller over `outputs/plaud`, a Python CLI. Both entry points use detached workers and the same library job queue. Every recording has a directory with the audio copy, metadata, versioned transcripts, notes and quality checks. A selectable library is independent of the application runtime and model storage. Stopping a job or closing the UI never deletes device recordings.

## Authentication

Choose China or International before login. `LoginWindow` recognizes only the selected region's cookies. `BluetoothLogin` saves the chosen region and a host from a fixed list, and does not reuse keys when switching accounts. `prepare_bluetooth.py` permits only device-list, encryption-key and signature endpoints; global regional redirects are accepted only within the global allowlist. No recording endpoints are used.

The local `bluetooth-identity.json` contains the subject, matching serial/signature and encryption keys, but not the web token. It is private (0600). Routine BLE uses only this file and the advertised serial. Credentials can expire or become invalid after account/device changes. China was tested with a real device; international fixtures cover routing but are not a replacement for a real-account test.

## Processing

Default transcription: pinned Qwen3-ASR-1.7B bf16 plus Qwen3-ForcedAligner bf16 through MLX. Diarization: native FluidAudio Offline VBx. Default summary: Qwen3-4B GGUF through a private localhost llama.cpp server, using Metal. Summaries include a generated title and editable prompt; no silent truncation of a long recording. Source audio/transcripts are preserved. Model weights are checked against pinned hashes.

Groq transcription and Groq/DeepSeek summaries are opt-in alternatives using the user's Keychain key. CLI requires `--allow-cloud` for audio upload and `--allow-text-upload` for text upload. Apple Speech and Foundation Models are optional and rely on Apple's own availability/resource management. Additional developer engines in the CLI may require their own runtime; the release initializer tests the default Qwen/VBx/local-summary chain.

## Installation

`outputs/plaud-distribution/install.sh` installs private dependencies; no Homebrew or global Python. `dependencies-osx-arm64.lock` pins conda-forge packages, and the Metal llama.cpp distribution and micromamba bootstrap have explicit SHA-256 values. Runtime: `~/Library/Application Support/PlaudeLocal/runtime`. CLI: `~/.local/bin/plaud`. Models are automatically downloaded and initialized by a real public-audio self-test. User-selected recording libraries are not removed on reinstall.

Current tested build: Apple Silicon, macOS 26.2+ (the pinned MLX library's minimum), 20 GiB free disk; 16 GB RAM or more recommended for the default full-precision models. No Intel support or production notarization. Account login, macOS privacy prompts and confirmation of cloud uploads are human steps. Automatic bulk BLE sync and launch-at-login are not implemented.
