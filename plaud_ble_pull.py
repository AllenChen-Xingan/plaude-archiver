#!/usr/bin/env python3
"""Pull recordings directly from a Plaud device over Bluetooth LE, with no cloud.

Reverse engineered from the Plaud Android app 4.0.2 (Tinnotech SDK com.tinnotech.penblesdk).
NOT TESTED against a real device. Read PLAUD_NOTE_PRO_PROTOCOL.md first.

Limits:
  * Works only for firmware on the plain protocol. If the device uses protocol
    version 30 (ECC session, first packet 0xFE30) or 20 (RSA), the link is encrypted
    with keys that the app gets from the Plaud cloud. The script detects this and stops.
  * The bind token is your Plaud user_id, right-padded with "0" to 32 characters.
    In the app: Settings > About, tap the logo 10 times. It copies userId and bindToken.
  * The script only reads. It never sends the delete command (30).

Usage:
  pip install bleak
  python3 plaud_ble_pull.py --scan
  python3 plaud_ble_pull.py --address <ADDR> --token <bindToken> --out ./plaud-ble
"""

import argparse
import asyncio
import os
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

SERVICE = "00001910-0000-1000-8000-00805f9b34fb"
CHAR_NOTIFY = "00002bb0-0000-1000-8000-00805f9b34fb"  # ll2.b, device -> app
CHAR_WRITE = "00002bb1-0000-1000-8000-00805f9b34fb"   # ll2.c, app -> device

CMD_HANDSHAKE = 1
CMD_GET_SSN = 2
CMD_GET_REC_SESSIONS = 26
CMD_SYNC_FILE_START = 28   # response: head (28), data packets (type 2), tail (29)
CMD_SYNC_FILE_TAIL = 29
CMD_SYNC_FILE_STOP = 29    # request zbm(0); the app waits for response 30
ECC_FE30 = 0xFE30


def u32(v):
    return struct.pack("<I", v & 0xFFFFFFFF)


def cmd(cmd_id, *parts):
    # j82.r(): byte 0 = 1 (command), bytes 1-2 = command id, little-endian.
    return bytes([1]) + struct.pack("<H", cmd_id) + b"".join(parts)


def handshake_packet(token, port_version, second=False):
    # bxa.y(): [01][01 00][02][00][P if port_version >= 3][token, 16 or 32 ASCII chars]
    # P is 0 in the first handshake and 1 in the second one (axa, after GET_SSN).
    n = 32 if port_version >= 9 else 16
    token = (token + "0" * n)[:n]
    body = bytes([2, 0])
    if port_version >= 3:
        body += bytes([1 if second else 0])
    return cmd(CMD_HANDSHAKE, body, token.encode())


def session_list_packet(start_session=0, flag=0):
    # eda: [now u32][start session id u32][flag u8]
    return cmd(CMD_GET_REC_SESSIONS, u32(int(time.time())), u32(start_session), bytes([flag]))


def sync_start_packet(session_id, start, end):
    # ybm: [session id u32][start offset u32][end offset u32]
    return cmd(CMD_SYNC_FILE_START, u32(session_id), u32(start), u32(end))


# --- Ogg Opus writer (for single-channel raw Opus frames) -------------------------

def _ogg_crc(data):
    crc = 0
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) if crc & 0x80000000 else (crc << 1)
            crc &= 0xFFFFFFFF
    return crc


def _ogg_page(serial, seq, granule, packets, header_type):
    lacing = b""
    for p in packets:
        lacing += b"\xff" * (len(p) // 255) + bytes([len(p) % 255])
    hdr = struct.pack("<4sBBqIIIB", b"OggS", 0, header_type, granule, serial, seq, 0, len(lacing)) + lacing
    page = bytearray(hdr + b"".join(packets))
    struct.pack_into("<I", page, 22, _ogg_crc(page))
    return bytes(page)


def write_ogg_opus(path, frames, rate=16000):
    serial = 0x504C4144  # "PLAD"
    head = b"OpusHead" + struct.pack("<BBHIhB", 1, 1, 312, rate, 0, 0)
    tags = b"OpusTags" + struct.pack("<I", 4) + b"plud" + struct.pack("<I", 0)
    with open(path, "wb") as f:
        f.write(_ogg_page(serial, 0, 0, [head], 0x02))
        f.write(_ogg_page(serial, 1, 0, [tags], 0x00))
        seq, granule = 2, 0
        for i in range(0, len(frames), 50):  # 50 frames = 1 s per page
            chunk = frames[i:i + 50]
            granule += 960 * len(chunk)      # 20 ms at 48 kHz
            last = i + 50 >= len(frames)
            f.write(_ogg_page(serial, seq, granule, chunk, 0x04 if last else 0x00))
            seq += 1


# --- E2EE recording files (fem.a.h / decryptE2eeFile) ----------------------------

def decrypt_plaud_file(data, private_key_pem):
    """Decrypt a 'PLAUD.AI' version-1 file: RSA-wrapped ChaCha20 key, 512-byte header.

    Header (little-endian): [0] magic, [8] version u16, [10] header size u16, [12] crc u32,
    [16] user id[32], [48] file type u16, [50] channel u16, [52] encrypt type u16,
    [54] duration s u32, [58] file uuid[16], [128] counter u32, [132] nonce[12],
    [144] segment size u32, [256] key cipher[256].
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms

    if data[:8] != b"PLAUD.AI":
        raise ValueError("not a PLAUD.AI file")
    version, header_size = struct.unpack_from("<HH", data, 8)
    if version != 1:
        raise ValueError(f"header version {version} not supported (version 2 uses an ECDH key)")
    counter = struct.unpack_from("<I", data, 128)[0]
    nonce = data[132:144]
    segment = struct.unpack_from("<I", data, 144)[0]
    if segment:
        print(f"  warning: segment size {segment} is not tested; decrypting as one stream")
    priv = serialization.load_pem_private_key(private_key_pem, None)
    key = priv.decrypt(data[256:512], padding.PKCS1v15())
    # The app falls back to the last 32 bytes when the firmware wraps a longer key.
    key = key[-32:]
    dec = Cipher(algorithms.ChaCha20(key, struct.pack("<I", counter) + nonce), None).decryptor()
    return dec.update(data[header_size:])


# --- Device session ------------------------------------------------------------

class Plaud:
    def __init__(self, client, token, port_version, keys_dir=None):
        self.c = client
        self.token = token
        self.port_version = port_version
        self.keys_dir = keys_dir
        self.q = asyncio.Queue()
        self.ogg_audio = False
        self.channels = 1
        # Protocol 20 session (g03.J/K/L): ChaCha20-Poly1305 key, fixed nonce, AAD.
        self.aead = None
        self.nonce = self.aad = None
        self.tx_seq = 1      # g03.M starts at 1; the first packet uses 2
        self.rx_seq = -1     # g03.N

    debug = False

    def _on_notify(self, _char, data):
        data = bytes(data)
        if self.aead is not None:
            try:
                plain = self.aead.decrypt(self.nonce, data, self.aad)
            except Exception as e:
                print(f"  <- undecryptable {len(data)}B ({type(e).__name__}): {data.hex()}")
                return
            seq = struct.unpack_from("<I", plain, 0)[0]
            if seq <= self.rx_seq:
                print(f"  <- replayed seq {seq}, dropped")
                return
            self.rx_seq = seq
            data = plain[4:]
        if self.debug and not (data and data[0] == 2):
            print(f"  <- {data.hex()}")
        self.q.put_nowait(data)

    async def send(self, pkt):
        if self.debug:
            print(f"  -> {pkt.hex()}")
        if self.aead is not None:
            self.tx_seq += 1
            pkt = self.aead.encrypt(self.nonce, u32(self.tx_seq) + pkt, self.aad)
        await self.c.write_gatt_char(CHAR_WRITE, pkt, response=False)

    async def recv(self, timeout=10.0):
        pkt = await asyncio.wait_for(self.q.get(), timeout)
        if len(pkt) >= 2 and struct.unpack_from("<H", pkt, 0)[0] == ECC_FE30:
            sys.exit("Device started an ECC session (0xFE30). This firmware encrypts the link "
                     "with keys from the Plaud cloud. Use plaud_cloud_pull.py instead.")
        return pkt

    async def recv_cmd(self, want, timeout=10.0):
        deadline = time.monotonic() + timeout
        while True:
            pkt = await self.recv(max(0.1, deadline - time.monotonic()))
            if len(pkt) >= 3 and pkt[0] == 1 and struct.unpack_from("<H", pkt, 1)[0] in want:
                return pkt

    async def _recv_fe(self, timeout):
        """Next pre-handshake packet: [cmd u16 = 0xFE11/0xFE12][...]."""
        deadline = time.monotonic() + timeout
        while True:
            pkt = await self.recv(max(0.1, deadline - time.monotonic()))
            if len(pkt) >= 2 and struct.unpack_from("<H", pkt, 0)[0] in (0xFE11, 0xFE12):
                return pkt

    async def rsa_prehandshake(self, serial):
        """Protocol 20 (ih2.t, zf2, e03): unlock the link with the cloud keys in keys_dir."""
        import base64
        import json
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric import padding
        from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

        sigs = json.load(open(os.path.join(self.keys_dir, "sn_signature.json")))
        sig_b64 = sigs.get(serial) or next(iter(sigs.values()))
        sig = base64.b64decode(sig_b64)
        pub_pem = open(os.path.join(self.keys_dir, "user_rsa_public.pem"), "rb").read()
        priv = serialization.load_pem_private_key(
            open(os.path.join(self.keys_dir, "user_rsa_private.pem"), "rb").read(), None)

        secret = {}  # index -> packet; e03 collects every 0xFE12 packet and sorts by byte 3
        state = {"total": None}

        def take(pkt):
            if pkt is not None and len(pkt) >= 4 and struct.unpack_from("<H", pkt, 0)[0] == 0xFE12:
                secret[pkt[3]] = pkt
                state["total"] = pkt[2]

        async def send_chunks(cmd_id, blob):
            n = (len(blob) + 99) // 100
            last = None
            for i in range(n):
                # m0h / bxa(type 2): [cmd u16][total u8][index u8][<= 100 bytes]
                await self.send(struct.pack("<H", cmd_id) + bytes([n, i]) + blob[i * 100:(i + 1) * 100])
                try:
                    last = await self._recv_fe(3.0 if i < n - 1 else 10.0)
                    take(last)
                except asyncio.TimeoutError:
                    last = None
            return last

        print(f"sending SN signature ({len(sig)} bytes)")
        rsp = await send_chunks(0xFE10, sig)
        if rsp is None:
            sys.exit("Device did not answer the SN signature.")
        if struct.unpack_from("<H", rsp, 0)[0] == 0xFE11:
            print(f"device asked for the user public key, sending it ({len(pub_pem)} bytes)")
            await send_chunks(0xFE12, pub_pem)
        try:
            while state["total"] is None or len(secret) < state["total"]:
                take(await self._recv_fe(10.0))
        except asyncio.TimeoutError:
            sys.exit(f"Timed out waiting for the session secret: got {len(secret)} of {state['total']} parts.")
        print(f"session secret: {len(secret)} parts")

        blob = b"".join(secret[i][4:] for i in sorted(secret))
        try:
            plain = priv.decrypt(blob, padding.PKCS1v15())
        except Exception as e:
            sys.exit(f"Could not RSA-decrypt the session secret ({len(blob)} bytes): {e}. "
                     f"The device may hold a different user public key.")
        key, self.nonce, self.aad = plain[:32], plain[32:44], plain[44:56]
        self.aead = ChaCha20Poly1305(key)
        check = self.aead.decrypt(self.nonce, plain[56:], self.aad)
        if check != b"PLAUD.AI":
            sys.exit(f"Session check failed: {check!r}")
        print("encrypted session established (ChaCha20-Poly1305)")

    async def start(self, serial=None):
        await self.c.start_notify(CHAR_NOTIFY, self._on_notify)
        if self.keys_dir:
            await self.rsa_prehandshake(serial)
        await self.send(handshake_packet(self.token, self.port_version))
        rsp = await self.recv_cmd({CMD_HANDSHAKE, CMD_GET_SSN})
        if struct.unpack_from("<H", rsp, 1)[0] == CMD_GET_SSN:
            print("device asked for a second handshake (GET_SSN)")
            await self.send(handshake_packet(self.token, self.port_version, second=True))
            rsp = await self.recv_cmd({CMD_HANDSHAKE})
        self._parse_handshake(rsp)

    def _parse_handshake(self, b):
        # HandShakeRsp: [3] status, [4..5] port version, [6] timezone, [7] tz min,
        # [8] audio channels, [9] wifi, [10] no NS/AGC, [11] ogg audio
        status = b[3]
        if status != 0:
            sys.exit(f"Handshake refused, status={status}. Check the bind token, or the "
                     f"device is bound to another account.")
        self.port_version = struct.unpack_from("<H", b, 4)[0]
        self.channels = b[8] if len(b) > 8 else 1
        self.ogg_audio = len(b) > 11 and b[11] == 1
        print(f"handshake ok: port_version={self.port_version} channels={self.channels} "
              f"ogg_audio={self.ogg_audio} raw={b.hex()}")

    async def sessions(self):
        await self.send(session_list_packet())
        files, total = [], None
        while total is None or len(files) < total:
            b = await self.recv_cmd({CMD_GET_REC_SESSIONS}, timeout=15)
            if total is None:
                total = struct.unpack_from("<H", b, 7)[0]
            if len(b) < 11 or struct.unpack_from("<H", b, 9)[0] != len(files):
                continue
            pv = self.port_version
            size = 8 if pv == 1 else 9 if 2 <= pv <= 6 else 10
            for off in range(11, len(b) - size + 1, size):
                sid, fsize = struct.unpack_from("<II", b, off)
                files.append((sid, fsize))
        return files

    async def pull(self, sid, fsize):
        await self.send(sync_start_packet(sid, 0, fsize))
        head = await self.recv_cmd({CMD_SYNC_FILE_START}, timeout=15)
        if len(head) > 7 and head[7] > 0:
            print(f"  session {sid}: device refused sync, status={head[7]}")
            return None
        data, pos = bytearray(), 0
        while True:
            pkt = await self.recv(timeout=20)
            if pkt[0] == 1 and struct.unpack_from("<H", pkt, 1)[0] == CMD_SYNC_FILE_TAIL:
                crc = struct.unpack_from("<H", pkt, 7)[0] if len(pkt) >= 9 else None
                print(f"  session {sid}: tail, device crc={crc}")
                break
            if pkt[0] != 2:
                continue
            i = 1
            if self.port_version >= 7:
                if struct.unpack_from("<I", pkt, 1)[0] != sid:
                    continue
                i = 5
            offset = struct.unpack_from("<I", pkt, i)[0]
            if offset == 0xFFFFFFFF:
                print(f"  session {sid}: end marker, code={pkt[i + 5] if len(pkt) > i + 5 else '?'}")
                break
            n = pkt[i + 4]
            chunk = pkt[i + 5:i + 5 + n]
            if offset != pos:
                # The app restarts the sync from the last good offset here. Keep it simple.
                print(f"  session {sid}: gap at {pos}, got {offset}; stopping this file")
                break
            data += chunk
            pos += len(chunk)
            if fsize:
                print(f"\r  session {sid}: {pos}/{fsize} bytes", end="", flush=True)
        print()
        return bytes(data)


async def scan():
    found = await BleakScanner.discover(timeout=8.0, return_adv=True)
    for dev, adv in found.values():
        name = dev.name or adv.local_name or ""
        if "plaud" in name.lower() or SERVICE in [u.lower() for u in adv.service_uuids]:
            mfr = {k: v.hex() for k, v in adv.manufacturer_data.items()}
            print(f"{dev.address}  {name!r}  rssi={adv.rssi}  manufacturer_data={mfr}")


async def run(args):
    async with BleakClient(args.address, timeout=20.0) as client:
        p = Plaud(client, args.token, args.port_version, args.keys_dir)
        p.debug = args.debug
        for uuid, label in (("00002a26-0000-1000-8000-00805f9b34fb", "firmware"),
                            ("00002a24-0000-1000-8000-00805f9b34fb", "model")):
            try:
                print(f"{label}: {(await client.read_gatt_char(uuid)).decode(errors='replace')}")
            except Exception as e:
                print(f"{label}: read failed ({e})")
        await p.start(args.serial)
        files = await p.sessions()
        print(f"{len(files)} recordings on the device")
        for sid, fsize in files:
            print(f"  session {sid} ({time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(sid))})  {fsize} bytes")
        if args.list_only:
            return
        os.makedirs(args.out, exist_ok=True)
        for sid, fsize in files:
            base = os.path.join(args.out, f"plaud_{sid}")
            if any(os.path.exists(base + ext) for ext in (".ogg", ".opus.raw", ".plaud")):
                continue
            data = await p.pull(sid, fsize)
            if not data:
                continue
            if data[:8] == b"PLAUD.AI":
                # End-to-end encrypted on the device. Keep the original, then decrypt it.
                open(base + ".plaud", "wb").write(data)
                if args.keys_dir:
                    pem = open(os.path.join(args.keys_dir, "user_rsa_private.pem"), "rb").read()
                    open(base + ".ogg", "wb").write(decrypt_plaud_file(data, pem))
                    print(f"  saved {base}.plaud and decrypted {base}.ogg")
                else:
                    print(f"  saved {base}.plaud (encrypted; pass --keys-dir to decrypt)")
                continue
            if p.ogg_audio:
                open(base + ".ogg", "wb").write(data)
            elif p.channels == 1:
                frame = 80
                write_ogg_opus(base + ".ogg", [data[k:k + frame] for k in range(0, len(data) - frame + 1, frame)])
            else:
                open(base + ".opus.raw", "wb").write(data)  # multistream Opus, 80 bytes per channel per 20 ms
            print(f"  saved {base}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scan", action="store_true", help="list nearby Plaud devices")
    ap.add_argument("--address", help="BLE address (macOS: the UUID that --scan prints)")
    ap.add_argument("--token", help="bind token: your user_id padded with 0 to 32 chars")
    ap.add_argument("--port-version", type=int, default=9,
                    help="protocol version from the advertisement; >= 9 sends a 32-char token")
    ap.add_argument("--out", default="plaud-ble")
    ap.add_argument("--list-only", action="store_true")
    ap.add_argument("--debug", action="store_true", help="print every command packet sent and received")
    ap.add_argument("--keys-dir", help="protocol 20: folder with sn_signature.json (from "
                    "/device-app/device/sn-sign), user_rsa_private.pem and user_rsa_public.pem "
                    "(from /device-app/e2ee/gen_key)")
    ap.add_argument("--serial", help="device serial number, used to pick the SN signature")
    ap.add_argument("--decrypt", metavar="FILE", help="decrypt a downloaded PLAUD.AI file to .ogg (needs --keys-dir)")
    args = ap.parse_args()
    if args.decrypt:
        if not args.keys_dir:
            ap.error("--decrypt needs --keys-dir")
        pem = open(os.path.join(args.keys_dir, "user_rsa_private.pem"), "rb").read()
        out = os.path.splitext(args.decrypt)[0] + ".ogg"
        open(out, "wb").write(decrypt_plaud_file(open(args.decrypt, "rb").read(), pem))
        print(f"decrypted to {out}")
    elif args.scan:
        asyncio.run(scan())
    elif args.address and args.token:
        asyncio.run(run(args))
    else:
        ap.error("use --scan, or give --address and --token")


if __name__ == "__main__":
    main()
