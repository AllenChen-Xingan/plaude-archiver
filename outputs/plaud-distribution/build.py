import pathlib,shutil,json,hashlib,tarfile
ROOT=pathlib.Path(__file__).resolve().parents[2];HERE=pathlib.Path(__file__).resolve().parent
REPO=ROOT/'work/plaude-archiver' if (ROOT/'work/plaude-archiver/PlaudeArchiver').exists() else ROOT
out=HERE/'stage';shutil.rmtree(out,ignore_errors=True);payload=out/'payload';payload.mkdir(parents=True)
def copy(rel):
 src=ROOT/rel;dst=payload/rel;dst.parent.mkdir(parents=True,exist_ok=True)
 if src.is_dir():shutil.copytree(src,dst)
 else:shutil.copy2(src,dst)
for rel in ['outputs/plaud','outputs/plaud-transcribe','outputs/plaud-asr-transcribe','outputs/plaud-download','outputs/plaud-engine/bin','outputs/plaud-engine/licenses','outputs/plaud-diarization/licenses','work/plaud-research/cn_account_guarded_probe.py']:
 copy(rel)
# Explicit production files: never include diagnostics, credentials or private samples.
files={
 'plaud-app':['job.py','summary_service.py','prepare_bluetooth.py','regions.py','bluetooth_scan.py','summary-model.json','default-summary-prompt.txt'],
 'plaud-qwen-asr':['setup.py','transcribe.py','download_models.py','model-lock.json','asset-sha256.json','requirements-lock.txt','LICENSE-MLX-Audio.txt','LICENSE-Qwen3-ASR.txt'],
 'plaud-whisper-large':['config.py','setup.py','transcribe.py','model-lock.json','LICENSE-OpenAI-Whisper.txt','LICENSE-whisper.cpp.txt'],
 'plaud-diarization':['alignment.py','download-model.py','model-lock.json','process.patch','setup.sh','test_alignment.py'],
 'plaud-engine':['setup.sh','download-model.py','offline.patch','model-lock.json'],
 'plaud-apple-speech':['setup.py','transcribe.py','SpeechCLI.swift']}
for folder,names in files.items():
 for name in names:copy('outputs/'+folder+'/'+name)
for rel in ['outputs/plaud-apple/apple-summary','outputs/plaud-apple/model-status','outputs/plaud-apple-speech/apple-speech']:copy(rel)
shutil.copy2(REPO/'LICENSE',payload/'LICENSE-plaude-archiver.txt')
shutil.copytree(REPO/'PlaudeArchiver/Plaude Archiver CN.app',payload/'Plaude Archiver CN.app')
(payload/'Plaude Archiver CN.app/Contents/Resources/RuntimeRoot.txt').unlink(missing_ok=True)
# Preview distribution defaults to MLX speech plus local Qwen summary.
p=payload/'outputs/plaud';s=p.read_text().replace("default='apple-speech'","default='qwen-asr'").replace("default='apple'","default='local'");p.write_text(s)
shutil.copy2((ROOT/'testdata/smoke.flac' if (ROOT/'testdata/smoke.flac').exists() else ROOT/'outputs/plaud-benchmark/samples/1272-128104-0001.flac'),payload/'smoke.flac')
for name in ['install.sh','verify.py','bluetooth-requirements.txt','README.txt','dependencies-osx-arm64.lock']:shutil.copy2(HERE/name,out/name)
manifest={str(p.relative_to(payload)):hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in sorted(payload.rglob('*')) if p.is_file()}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2))
archive=HERE/'plaud-local-preview.tar.gz'
with tarfile.open(archive,'w:gz') as t:t.add(out,arcname='plaud-local-preview')
(HERE/'plaud-local-preview.tar.gz.sha256').write_text(hashlib.file_digest(archive.open('rb'),'sha256').hexdigest()+'  '+archive.name+'\n')
print(archive,archive.stat().st_size,len(manifest))
