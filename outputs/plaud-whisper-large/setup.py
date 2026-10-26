#!/usr/bin/env python3
"""Explicit installation only; inference never downloads models."""
import hashlib,json,pathlib,urllib.request,os
P=pathlib.Path(__file__).resolve().parent;ROOT=P.parents[1]
lock=json.loads((P/'model-lock.json').read_text());dest=ROOT/'work/plaud-research/models'/lock['filename'];dest.parent.mkdir(parents=True,exist_ok=True)
def valid(path):
 if not path.is_file() or path.stat().st_size!=lock['size']:return False
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()==lock['sha256']
if valid(dest): print('Verified large-v3 model already installed.')
else:
 part=dest.with_suffix('.bin.part')
 print('Downloading non-quantized large-v3 (3.10 GB)...',flush=True)
 urllib.request.urlretrieve(lock['url'],part)
 if not valid(part):raise SystemExit('Model verification failed; previous model not replaced.')
 os.replace(part,dest);print('Installed and verified large-v3.')
(P/'install-verification.json').write_text(json.dumps(dict(**lock,verified=True),indent=2)+'\n')
