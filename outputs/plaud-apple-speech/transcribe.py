#!/usr/bin/env python3
"""Optional Apple on-device ASR; requires already-installed speech assets."""
import argparse,os,pathlib,sys,subprocess,tempfile,time,json,wave,math,platform
P=pathlib.Path(__file__).resolve().parent

def stamp(t):
 ms=round(t*1000);h,ms=divmod(ms,3600000);m,ms=divmod(ms,60000);s,ms=divmod(ms,1000);return f'{h:02}:{m:02}:{s:02},{ms:03}'
def main():
 os.umask(0o077);p=argparse.ArgumentParser(description=__doc__);p.add_argument('audio',type=pathlib.Path);p.add_argument('output_prefix',type=pathlib.Path);a=p.parse_args();started=time.perf_counter()
 if sys.platform!='darwin' or int(platform.mac_ver()[0].split('.')[0])<26:raise ValueError('Apple Speech requires macOS 26 or later.')
 binary=P/'apple-speech'
 if not binary.is_file():raise ValueError('Apple helper missing; run outputs/plaud-apple-speech/setup.py')
 source=a.audio.resolve();prefix=a.output_prefix.absolute();exts=['txt','srt','json','verification.json']
 if not source.is_file():raise ValueError('Readable local audio required.')
 if any(os.path.lexists(str(prefix)+'.'+e) for e in exts):raise ValueError('Output already exists.')
 status_process=subprocess.run([str(binary),'--status','--locale','en-US'],capture_output=True,text=True)
 try:status=json.loads(status_process.stdout)
 except ValueError:raise ValueError('Apple Speech status check failed; no transcript or download attempted.')
 if status_process.returncode or status.get('assetStatus')!='installed':raise ValueError('Apple Speech assets unavailable: '+str(status.get('assetStatus'))+'. Run apple-speech --install-assets explicitly; no automatic download attempted.')
 prefix.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='.apple-speech-',dir=prefix.parent) as td:
  tmp=pathlib.Path(td);wav=tmp/'audio.wav'
  duration=float(subprocess.check_output(['ffprobe','-v','error','-protocol_whitelist','file,pipe','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(source)],stderr=subprocess.DEVNULL))
  subprocess.run(['ffmpeg','-nostdin','-v','error','-xerror','-protocol_whitelist','file,pipe','-i',str(source),'-map','0:a:0','-vn','-ar','16000','-ac','1','-c:a','pcm_s16le',str(wav)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  with wave.open(str(wav)) as w:frames=w.getnframes();pcm=frames/w.getframerate()
  if not math.isfinite(duration) or pcm<=0 or abs(duration-pcm)>.1:raise ValueError('Complete audio decode mismatch.')
  converted=time.perf_counter()
  with (tmp/'engine.log').open('w') as log:result=subprocess.run([str(binary),'--transcribe',str(wav),'--output',str(tmp/'json'),'--locale','en-US'],stdout=log,stderr=log)
  if result.returncode:raise ValueError(f'Apple Speech failed (exit{result.returncode}); no output published or synthetic timestamps inserted.')
  data=json.loads((tmp/'json').read_text())
  if abs(data['durationSeconds']-pcm)>.01 or not data['wordTimings']:raise ValueError('Apple output duration/timing mismatch.')
  data['audioFile']=str(source);words=data['wordTimings'];(tmp/'json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n');(tmp/'txt').write_text(data['text']+'\n')
  (tmp/'srt').write_text('\n'.join(f'{i}\n{stamp(w["startTime"])} --> {stamp(w["endTime"])}\n{w["word"]}\n' for i,w in enumerate(words,1)))
  report=dict(engine='apple-speech',model='Apple system SpeechTranscriber (system managed, not pinned)',macos=platform.mac_ver()[0],locale=status['locale'],asset_status_before=status['assetStatus'],asset_download_started=False,source_duration_seconds=duration,decoded_duration_seconds=pcm,pcm_samples=frames,full_input_decoded=True,full_decoded_file_submitted=True,preflight_and_conversion_seconds=converted-started,engine_process_seconds=time.perf_counter()-converted,total_seconds=time.perf_counter()-started,timed_runs=len(words),word_timestamp_method=data['wordTimestampMethod'],untimed_text_runs=data['untimedTextRuns'],inference='Apple SpeechAnalyzer on-device API; speech assets already present',accuracy='Not evaluated')
  (tmp/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
  for e in exts:os.link(tmp/e,str(prefix)+'.'+e)
 print(f'Complete Apple Speech transcript: {prefix}.json')
if __name__=='__main__':
 try:main()
 except Exception as e:print(f'Error: {e}',file=sys.stderr);sys.exit(1)
