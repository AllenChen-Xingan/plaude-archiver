#!/usr/bin/env python3
"""Local non-diarized Whisper with JSON word timestamps and optional vocabulary prompt."""
import argparse,json,os,pathlib,subprocess,tempfile,time,wave,math,sys
from config import checked_model
HERE=pathlib.Path(__file__).resolve().parent

def main():
 os.umask(0o077);p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--engine',choices=['whisper','whisper-large'],required=True);p.add_argument('--prompt',default=None)
 p.add_argument('audio',type=pathlib.Path);p.add_argument('output_prefix',type=pathlib.Path)
 a=p.parse_args();start=time.perf_counter();source=a.audio.resolve();prefix=a.output_prefix.absolute()
 if not source.is_file():raise ValueError('Readable local input required.')
 if any(os.path.lexists(str(prefix)+'.'+x) for x in ['txt','srt','json','verification.json']):raise ValueError('Output already exists.')
 model=checked_model(a.engine);prefix.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='.whisper-',dir=prefix.parent) as td:
  t=pathlib.Path(td)
  def run(cmd):
   with (t/'private.log').open('w') as f:r=subprocess.run(cmd,stdout=f,stderr=f)
   if r.returncode:raise ValueError(f'{pathlib.Path(cmd[0]).name} failed ({r.returncode}); no outputs published.')
  duration=float(subprocess.check_output(['ffprobe','-v','error','-protocol_whitelist','file,pipe','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(source)],stderr=subprocess.DEVNULL))
  run(['ffmpeg','-nostdin','-v','error','-xerror','-protocol_whitelist','file,pipe','-i',str(source),'-map','0:a:0','-vn','-ar','16000','-ac','1','-c:a','pcm_s16le',str(t/'audio.wav')])
  with wave.open(str(t/'audio.wav')) as w:pcm=w.getnframes()/w.getframerate()
  if not math.isfinite(duration) or pcm<=0 or abs(duration-pcm)>.1:raise ValueError('Audio duration mismatch.')
  converted=time.perf_counter();cmd=['whisper-cli','-m',str(model),'-f',str(t/'audio.wav'),'-l','en','-oj','-otxt','-osrt','-ml','1','-sow','-of',str(t/'result')]
  if a.prompt:cmd+=['--prompt',a.prompt]
  run(cmd);raw=json.loads((t/'result.json').read_text());words=[dict(word=s['text'].strip(),startTime=s['offsets']['from']/1000,endTime=s['offsets']['to']/1000) for s in raw['transcription'] if s['text'].strip()]
  if not words:raise ValueError('Empty transcript.')
  data=dict(text=' '.join(x['word'] for x in words),wordTimings=words,durationSeconds=pcm,audioFile=str(source),whisperResult=raw)
  (t/'result.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
  report=dict(engine=a.engine,model=model.name,source_duration_seconds=duration,decoded_duration_seconds=pcm,full_input_decoded=True,full_decoded_file_submitted=True,conversion_and_preflight_seconds=converted-start,engine_process_seconds=time.perf_counter()-converted,total_seconds=time.perf_counter()-start,prompt_used=bool(a.prompt),inference='Local Whisper.cpp; no downloads')
  (t/'result.verification.json').write_text(json.dumps(report,indent=2)+'\n')
  for ext in ['txt','srt','json','verification.json']:os.link(t/('result.'+ext),str(prefix)+'.'+ext)
 print(f'Complete local Whisper output: {prefix}.txt / .srt / .json / .verification.json')
if __name__=='__main__':
 try:main()
 except (ValueError,OSError,KeyError,subprocess.CalledProcessError) as e:print(f'Error: {e}',file=sys.stderr);sys.exit(1)
