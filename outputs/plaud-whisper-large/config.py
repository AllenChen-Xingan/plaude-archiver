import hashlib,json
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[1]
def checked_model(engine):
 if engine=='whisper-large':
  lock=json.loads((HERE/'model-lock.json').read_text());path=ROOT/'work/plaud-research/models'/lock['filename'];algo='sha256';digest=lock['sha256']
 else:
  path=ROOT/'work/plaud-research/models/ggml-base.bin';algo='sha1';digest='465707469ff3a37a2b9b8d8f89f2f99de7299dac'
 if not path.is_file():raise ValueError(f'Local {engine} model missing; run its setup script first.')
 with path.open('rb') as f: actual=hashlib.file_digest(f,algo).hexdigest()
 if actual!=digest:raise ValueError(f'{engine} model checksum mismatch.')
 return path
