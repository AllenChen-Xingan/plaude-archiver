# Plaud Menu Bar

A macOS menu-bar app that downloads your own Plaud Note Pro recordings over Bluetooth, with no Plaud cloud sync. It uses the Plaud cloud only once, to fetch the two keys the device needs (your RSA key pair and the device signature). After that, downloads are fully local.

Built from the reverse-engineered protocol in `../PLAUD_NOTE_PRO_PROTOCOL.md`.

## Build

```bash
./build.sh
```

This compiles the Swift package and wraps it in `PlaudMenuBar.app`, ad-hoc signed with a Bluetooth entitlement. The bundle and signature are required: macOS kills a bare binary the moment it touches Bluetooth (the TCC rule that crashed the Python script).

## Run

```bash
open ./PlaudMenuBar.app
```

A waveform icon appears in the menu bar. From its menu:

1. **Sign in to Plaud** — opens web.plaud.ai in a window. Log in normally. The app reads the `pld_ut` session cookie the site sets; it does not scrape the page. The window closes itself once it has the token.
2. **Download my recordings** — the first run fetches your RSA key pair (`e2ee/gen_key`) and, after it sees the device, the device signature (`device/sn-sign`). Both are cached. Then it connects over Bluetooth, unlocks the encrypted session, lists recordings, and saves each one as `.ogg` (plus the raw encrypted `.plaud`).
3. **Choose download folder** — defaults to `~/Downloads/Plaud Recordings`.

On first Bluetooth use, macOS asks to allow Bluetooth for the app. Allow it.

## How it works

- `LoginWindow.swift` — WKWebView + cookie capture of the `pld_ut` (UT) token.
- `PlaudAPI.swift` — `sn-sign` and `gen_key` with `X-Encrypt-Response: 1`, Fernet-decrypts replies, follows the region redirect.
- `Crypto.swift` — Fernet (AES-128-CBC + HMAC), RSA PKCS#1 decrypt, plain ChaCha20 for the recording file, PLAUD.AI header parse.
- `Protocol.swift` — the Tinnotech BLE packet format and the ChaCha20-Poly1305 session wrapper.
- `BLE.swift` — CoreBluetooth: scan, connect, protocol-20 unlock, handshake, session list, file pull.
- `Store.swift` — caches the token, keys and signatures in `~/Library/Application Support/PlaudMenuBar/`.

## Status

- Verified end to end: the app logs in, fetches keys, connects over Bluetooth, downloads and decrypts recordings to playable Ogg Opus (tested 2026-10-24 on a real Note Pro, 2 recordings).
- The scan matches the device by its advertised service 0x504C / name / serial (0x1910 is only visible after connecting).

## Security notes

- The RSA private key is cached in `~/Library/Application Support/PlaudMenuBar/state.json`. Plaud's servers also hold a copy of this key (it comes from `gen_key`), so their encryption is not private from Plaud.
- The app only ever talks to Plaud's own hosts and your device.
