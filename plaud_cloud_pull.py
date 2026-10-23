#!/usr/bin/env python3
"""Download your Plaud recordings from the Plaud cloud.

Reverse engineered from the Plaud Android app 4.0.2 (ai.plaud.android.plaud, build 1278).

Flow, as the app does it:
  1. GET  {base}/file-app/v4/app/sync/version/file?cursor=<c>&limit=<n>
       -> data.files[]: {meta: {file_id, start_time, duration, serial_number, ...},
                         objects: [{object_type, content_id, download_url, mime_type, ...}]}
       -> data.has_more, data.next_cursor
  2. POST {base}/file-app/v4/files/content/url  {"content_ids": [...]}
       -> data.url_map: {content_id: presigned_url}
  3. GET the presigned URL (no auth header).

If a response has the header `x-encrypt-response: 1`, its body is a Fernet token.
The app decrypts it with a key that is built into the app (class `wng`).

Usage:
  pip install requests cryptography
  export PLAUD_TOKEN='<the part after "Bearer ">'
  python3 plaud_cloud_pull.py --out ./plaud-recordings
"""

import argparse
import json
import os
import re
import sys
import time

import requests
from cryptography.fernet import Fernet

# Built into the app as 7 string parts that are joined (class wng, field b).
APP_FERNET_KEY = b"8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI="
AUDIO_TYPES = ("audio", "audio_transcoded")


def decode_body(resp):
    if resp.headers.get("x-encrypt-response") == "1":
        return json.loads(Fernet(APP_FERNET_KEY).decrypt(resp.text.strip().encode()))
    return resp.json()


def check(body, what):
    # The app accepts either {"code": 0} or {"status": 0}.
    code = body.get("code", body.get("status"))
    if code not in (0, None):
        sys.exit(f"{what} failed: {json.dumps(body)[:500]}")
    return body.get("data") or {}


def list_files(session, base, limit):
    cursor = ""
    while True:
        resp = session.get(f"{base}/file-app/v4/app/sync/version/file",
                           params={"cursor": cursor, "limit": str(limit)}, timeout=30)
        resp.raise_for_status()
        data = check(decode_body(resp), "file list")
        for f in data.get("files") or []:
            yield f
        if not data.get("has_more"):
            return
        cursor = data.get("next_cursor") or ""


def resolve_urls(session, base, content_ids):
    resp = session.post(f"{base}/file-app/v4/files/content/url",
                        json={"content_ids": content_ids}, timeout=30)
    resp.raise_for_status()
    return check(decode_body(resp), "content url").get("url_map") or {}


def safe_name(meta, obj):
    start = meta.get("start_time") or meta.get("created_at") or 0
    # start_time can be seconds or milliseconds.
    if start > 10**11:
        start //= 1000
    stamp = time.strftime("%Y-%m-%d_%H-%M-%S", time.localtime(start)) if start else "unknown"
    ext = {"audio/ogg": "ogg", "audio/opus": "opus", "audio/mpeg": "mp3", "audio/mp3": "mp3",
           "audio/wav": "wav", "audio/x-wav": "wav", "audio/mp4": "m4a", "audio/aac": "aac"}.get(
        (obj.get("mime_type") or "").lower(), "bin")
    name = f"{stamp}_{meta.get('file_id', 'nofileid')}_{obj.get('object_type')}.{ext}"
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--token", default=os.environ.get("PLAUD_TOKEN"), help="bearer token (or set PLAUD_TOKEN)")
    ap.add_argument("--base", default="https://api.plaud.ai", help="API base URL")
    ap.add_argument("--out", default="plaud-recordings")
    ap.add_argument("--limit", type=int, default=50, help="page size")
    ap.add_argument("--transcoded", action="store_true", help="also download audio_transcoded copies")
    ap.add_argument("--list-only", action="store_true", help="print the file list and stop")
    ap.add_argument("--dump", action="store_true", help="print the raw JSON of each file entry")
    args = ap.parse_args()
    if not args.token:
        sys.exit("Set PLAUD_TOKEN or pass --token.")

    token = args.token.removeprefix("Bearer ").removeprefix("bearer ").strip()
    s = requests.Session()
    s.headers.update({"Authorization": f"Bearer {token}", "app-platform": "android"})
    os.makedirs(args.out, exist_ok=True)

    wanted = AUDIO_TYPES if args.transcoded else ("audio",)
    files = list(list_files(s, args.base, args.limit))
    print(f"{len(files)} files in the cloud")

    jobs = []  # (path, content_id, direct_url)
    for f in files:
        meta = f.get("meta") or {}
        if args.dump:
            print(json.dumps(f, indent=2, ensure_ascii=False))
        for obj in f.get("objects") or []:
            if obj.get("object_type") not in wanted:
                continue
            path = os.path.join(args.out, safe_name(meta, obj))
            dur = (meta.get("duration") or 0) / 1000
            print(f"  {meta.get('file_id')}  sn={meta.get('serial_number')}  {dur:7.0f}s  {obj.get('object_type')}  -> {path}")
            if not os.path.exists(path):
                jobs.append((path, obj.get("content_id"), obj.get("download_url")))
    if args.list_only:
        return

    need = [cid for _, cid, url in jobs if not url and cid]
    url_map = {}
    for i in range(0, len(need), 50):
        url_map.update(resolve_urls(s, args.base, need[i:i + 50]))

    for path, cid, url in jobs:
        url = url or url_map.get(cid)
        if not url:
            print(f"  skip {path}: no download URL")
            continue
        with requests.get(url, stream=True, timeout=120) as r:
            r.raise_for_status()
            tmp = path + ".part"
            with open(tmp, "wb") as fh:
                for chunk in r.iter_content(1 << 16):
                    fh.write(chunk)
            os.replace(tmp, path)
        print(f"  saved {path} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    main()
