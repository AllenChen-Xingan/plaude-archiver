import pathlib,json,hashlib,urllib.request,os
P=pathlib.Path(__file__).resolve().parent;ROOT=P.parents[1];LOCK=json.loads((P/'model-lock.json').read_text())
def valid(path,f):
 if not path.is_file() or path.stat().st_size!=f['size']:return False
 if 'lfs' in f:
  with path.open('rb') as h:return hashlib.file_digest(h,'sha256').hexdigest()==f['lfs']['oid']
 data=path.read_bytes();return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==f['oid']
def download():
 hashes={}
 for key,m in LOCK['models'].items():
  dest=ROOT/'work/plaud-qwen-asr/models'/key;dest.mkdir(parents=True,exist_ok=True);hashes[key]={}
  for f in m['files']:
   path=dest/f['path'];path.parent.mkdir(parents=True,exist_ok=True)
   if not valid(path,f):
    temp=path.with_name(path.name+'.part');url=f"https://huggingface.co/{m['repo']}/resolve/{m['revision']}/{f['path']}"
    print('Downloading',key,f['path'],f['size'],flush=True)
    urllib.request.urlretrieve(url,temp)
    if not valid(temp,f):raise ValueError('Upstream hash verification failed: '+f['path'])
    os.replace(temp,path)
   with path.open('rb') as h:hashes[key][f['path']]=hashlib.file_digest(h,'sha256').hexdigest()
 (P/'asset-sha256.json').write_text(json.dumps(hashes,indent=2)+'\n');print('All ASR and alignment assets verified.',flush=True)
if __name__=='__main__':download()
