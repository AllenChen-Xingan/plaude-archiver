#!/usr/bin/env python3
"""Download only pinned, official model assets; no credentials or audio access."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
lock = json.loads((HERE / 'model-lock.json').read_text())
dest = HERE.parent.parent / 'work/plaud-diarization/models'
dest.mkdir(parents=True, exist_ok=True)

def download(name):
    target = dest / name
    target.parent.mkdir(parents=True, exist_ok=True)
    expected = lock.get('sha256', {}).get(name)
    if target.exists() and expected and hashlib.sha256(target.read_bytes()).hexdigest() == expected:
        return name, expected
    partial = target.with_name(target.name + '.partial')
    url = f"https://huggingface.co/{lock['repo']}/resolve/{lock['revision']}/{name}"
    subprocess.run(['curl', '-fLsS', '--retry', '3', '--connect-timeout', '30',
                    url, '-o', str(partial)], check=True)
    digest = hashlib.sha256(partial.read_bytes()).hexdigest()
    if expected and digest != expected:
        raise RuntimeError(f'Checksum mismatch: {name}')
    partial.replace(target)
    return name, digest

with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    hashes = dict(pool.map(download, lock['files']))
(dest / 'download-manifest.json').write_text(json.dumps({**lock, 'sha256': hashes}, indent=2) + '\n')
print(f'Verified {len(hashes)} model assets: {dest}')

(dest / '.fluidaudio-revision').write_text(lock['revision'] + '\n')
cache = dest.parent / 'cache'
cache.mkdir(exist_ok=True)
link = cache / 'speaker-diarization'
if not link.exists():
    link.symlink_to('../models', target_is_directory=True)
