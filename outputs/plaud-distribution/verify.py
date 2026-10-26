import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);manifest=json.loads((root.parent/'manifest.json').read_text())
for name,wanted in manifest.items():
 p=root/name
 if not p.is_file() or hashlib.file_digest(p.open('rb'),'sha256').hexdigest()!=wanted:
  raise SystemExit('Package checksum mismatch: '+name)
print('Package checksums verified:',len(manifest),'files')
