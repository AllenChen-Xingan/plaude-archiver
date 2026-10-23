<div align="center">

# 🏴‍☠️ plaude-pirate

### Own your Plaud recordings. Pull them straight off the device over Bluetooth — no cloud sync required.

A macOS menu-bar app (and a pair of Python scripts) that talk to a **Plaud Note Pro** in its own language, decrypt its recordings, and hand you plain `.ogg` files. Reverse-engineered from the Android app, down to the firmware's encrypted BLE handshake.

</div>

---

## What this is

Plaud recorders upload your audio to Plaud's cloud, where it gets transcribed and summarised. The recordings are "end-to-end encrypted" — but the key is issued by Plaud's own servers, so *they* can read everything. And if you just want your raw audio on your own machine, you normally have to go through their app and their cloud.

This project cuts out the middle. It:

- 🔑 Logs into Plaud once (in a real browser window) to grab the two keys the device needs.
- 📡 Connects to the recorder directly over **Bluetooth LE** using CoreBluetooth.
- 🔓 Runs the device's encrypted unlock handshake (RSA-wrapped **ChaCha20-Poly1305**) itself.
- 💾 Downloads every recording and decrypts each one to a playable **Ogg Opus** file.

After the one-time key fetch, it never touches Plaud's servers again.

## The menu-bar app

<div align="center">
<em>🎙️ waveform icon in your menu bar → Sign in → Download my recordings → done.</em>
</div>

```bash
cd PlaudMenuBar
./build.sh          # compiles + wraps + signs PlaudMenuBar.app
open ./PlaudMenuBar.app
```

- **Sign in to Plaud** opens `web.plaud.ai` in a window. Log in normally; the app reads the session cookie the site sets. It never scrapes the page or asks you to paste a token.
- **Download my recordings** fetches your keys (once), connects over Bluetooth, and saves everything to `~/Downloads/Plaud Recordings`.

> macOS needs the app to be a signed bundle with a Bluetooth usage string, or it kills the process the instant it touches the radio. `build.sh` handles the bundle + ad-hoc signing for you.

## The Python scripts

For the terminal crowd, same capability, fewer frameworks:

```bash
pip install bleak requests cryptography
python3 plaud_ble_pull.py --scan                       # find your device
python3 plaud_ble_pull.py --address <ADDR> --token <user_id> \
        --keys-dir ./secrets/keys                      # pull + decrypt over BLE
```

`plaud_cloud_pull.py` is the alternative path: it downloads whatever your device already synced, straight from Plaud's cloud API.

## How it works

```
  web.plaud.ai  ──login cookie──▶  sn-sign + gen_key  ──▶  device signature + your RSA key
                                                                    │
  Note Pro  ◀──BLE 0x1910──▶  FE10 signature ▶ FE12 secret ▶  RSA-unwrap ▶ ChaCha20-Poly1305 session
                                                                    │
                            handshake ▶ list ▶ pull  ──▶  PLAUD.AI file  ──▶  decrypt  ──▶  .ogg
```

The full protocol — GATT UUIDs, packet framing, the protocol-20 RSA handshake, the ECC (protocol-30) variant, and the on-device file format — is written up in **[PLAUD_NOTE_PRO_PROTOCOL.md](PLAUD_NOTE_PRO_PROTOCOL.md)**.

### Architecture (Swift)

| File | Does |
|------|------|
| `LoginWindow.swift` | WKWebView + session-cookie capture |
| `PlaudAPI.swift` | `sn-sign` / `gen_key`, Fernet-decrypts replies, follows the region redirect |
| `Crypto.swift` | Fernet (AES-CBC + HMAC), RSA PKCS#1, ChaCha20, the `PLAUD.AI` file format |
| `Protocol.swift` | Tinnotech BLE packet format + the ChaCha20-Poly1305 session |
| `BLE.swift` | CoreBluetooth: scan, connect, unlock, handshake, list, pull |
| `AppDelegate.swift` | Menu bar wiring and the download flow |

## What the teardown turned up

- The device's recordings are encrypted on the device, to a key only your account's RSA key can unwrap.
- …except Plaud's `gen_key` endpoint hands *your private key* to the app (and keeps a copy). So the "end-to-end" encryption is **not** private from Plaud. This tool inherits that: it removes your dependence on Plaud's app, not Plaud's ability to read your audio. Re-binding the device to a key pair you generate yourself would fix that — see the protocol notes.
- The device verifies a cloud-issued signature over its serial before it trusts the app. That signature is static and reusable, so once fetched, your device works offline forever.

## Status

✅ Verified end to end on a real Plaud Note Pro: login → key fetch → BLE unlock → download → decrypt → playable Opus.

## Legal & ethical

This is for pulling **your own** recordings off **your own** device. It only talks to Plaud's own servers and your hardware. It is not affiliated with, endorsed by, or supported by Plaud. Built for interoperability and research. Don't point it at devices or accounts that aren't yours.

## License

MIT.
