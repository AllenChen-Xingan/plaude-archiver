# v0.2.0-preview.1 validation

Test host: Apple M5, 32 GB RAM, macOS 27. A second physical Mac has not been tested.

- Swift release build: passed with SDK 26.5. Existing deprecation warnings remain.
- Region/auth tests: 10 passed, including China, international regional redirect, arbitrary-host rejection, cross-region rejection, no web token in BLE identity, 0600 private identity permissions, and no recording endpoints.
- Real China account: device ownership/signature preparation and Note Pro protocol 20 BLE audio import passed; original device audio retained.
- Real international account: awaiting interactive user login at publication time; not claimed verified.
- Installation into a fresh empty runtime directory: passed with PATH initially limited to `/usr/bin:/bin:/usr/sbin:/sbin`. No Homebrew was invoked or installed. Private Python/Git/ffmpeg and the official Metal llama.cpp package installed successfully.
- Model downloads: Qwen3-ASR, ForcedAligner, VBx and local Qwen summary downloaded and verified, without copying another environment's venv or model directory.
- End-to-end installer self-test: public audio imported, Qwen speech transcribed, speakers labeled, local summary/title saved; passed. This is initialization coverage, not an accuracy benchmark.
- Native summary GPU: official llama.cpp package reports the Apple M5 Metal device.
- Archive: payload hashes verified; explicit allowlist excludes login state, identity/signature caches, API keys, private recordings and Python environments.
- Compatibility floor: pinned MLX dylib declares macOS 26.2 minimum. Installer refuses unsupported OS/CPU before downloading models.

Known limits: ad-hoc signed (no Apple notarization), no Intel build, no automatic batch BLE importer, and only the default Qwen/VBx/local-summary chain is covered by the installer initialization test. OS Bluetooth prompts and website authentication require user interaction.
