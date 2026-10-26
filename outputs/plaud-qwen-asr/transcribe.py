#!/usr/bin/env python3
"""Offline Qwen3-ASR-1.7B bf16 plus real Qwen3 forced word alignment."""
import os
os.environ.update(HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',HF_HUB_DISABLE_TELEMETRY='1',TOKENIZERS_PARALLELISM='false')
import argparse,pathlib,json,hashlib,subprocess,tempfile,time,wave,math,sys,collections,re
P=pathlib.Path(__file__).resolve().parent;ROOT=P.parents[1]
def stamp(t):
 ms=round(t*1000);h,ms=divmod(ms,3600000);m,ms=divmod(ms,60000);s,ms=divmod(ms,1000);return f'{h:02}:{m:02}:{s:02},{ms:03}'
def main():
 os.umask(0o077);p=argparse.ArgumentParser(description=__doc__);p.add_argument('--prompt',default=None);p.add_argument('audio',type=pathlib.Path);p.add_argument('output_prefix',type=pathlib.Path);a=p.parse_args();start=time.perf_counter()
 source=a.audio.resolve();prefix=a.output_prefix.absolute();exts=['txt','srt','json','verification.json']
 if not source.is_file():raise ValueError('Readable local audio required.')
 if any(os.path.lexists(str(prefix)+'.'+e) for e in exts):raise ValueError('Output exists; choose a new prefix.')
 lock=json.loads((P/'model-lock.json').read_text());hashes=json.loads((P/'asset-sha256.json').read_text())
 for key,files in hashes.items():
  for name,digest in files.items():
   path=ROOT/'work/plaud-qwen-asr/models'/key/name
   with path.open('rb') as f:actual=hashlib.file_digest(f,'sha256').hexdigest()
   if actual!=digest:raise ValueError('Qwen asset checksum mismatch: '+name)
 prefix.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(prefix='.qwen-asr-',dir=prefix.parent) as td:
  tmp=pathlib.Path(td);wav=tmp/'audio.wav'
  subprocess.run(['ffmpeg','-nostdin','-v','error','-xerror','-protocol_whitelist','file,pipe','-i',str(source),'-map','0:a:0','-vn','-ar','16000','-ac','1','-c:a','pcm_s16le',str(wav)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  with wave.open(str(wav)) as w:assert w.getframerate()==16000 and w.getnchannels()==1;frames=w.getnframes();pcm=w.readframes(frames)
  duration=frames/16000
  if not duration>0:raise ValueError('Empty audio.')
  import numpy as np
  import mlx.core as mx
  from mlx_audio.stt import load
  audio=np.frombuffer(pcm,dtype='<i2').astype(np.float32)/32768
  print('Loading local Qwen3-ASR and ForcedAligner...',file=sys.stderr,flush=True)
  asr=load(str(ROOT/'work/plaud-qwen-asr/models/asr'));aligner=load(str(ROOT/'work/plaud-qwen-asr/models/aligner'));loaded=time.perf_counter()
  # Gapless <=30-second chunks. Seek low-energy boundary in final 2 seconds;
  # these boundaries are audio cuts, never used as fabricated word timestamps.
  bounds=[0]
  while frames-bounds[-1]>30*16000:
   lo=bounds[-1]+28*16000;hi=bounds[-1]+30*16000;step=160
   candidates=range(lo,hi,step);end=min(candidates,key=lambda i:float(np.mean(audio[max(lo,i-160):min(hi,i+160)]**2)))
   bounds.append(end)
  bounds.append(frames)
  texts=[];words=[];chunks=[];asr_seconds=0.;align_seconds=0.;max_tokens=1024
  for index,(begin,end) in enumerate(zip(bounds,bounds[1:])):
   part=audio[begin:end];offset=begin/16000;part_duration=(end-begin)/16000
   print(f'Qwen ASR + alignment chunk {index+1}/{len(bounds)-1} ({offset:.2f}-{end/16000:.2f}s)...',file=sys.stderr,flush=True)
   t=time.perf_counter();out=asr.generate(part,language='English',temperature=0.0,max_tokens=max_tokens,batch_size=1,chunk_duration=30.0,verbose=False,system_prompt=a.prompt);asr_seconds+=time.perf_counter()-t
   if out.generation_tokens>=max_tokens:raise ValueError('Qwen generation token budget exhausted; refusing partial transcript.')
   text=out.text.strip();chunk_words=[];corrected=0
   if text:
    t=time.perf_counter();aligned=aligner.generate(audio=part,text=text,language='English');align_seconds+=time.perf_counter()-t
    previous=0.
    for item in aligned.items:
     aa,bb=float(item.start_time),float(item.end_time)
     if not all(math.isfinite(v) for v in [aa,bb]) or aa<0 or bb<aa or aa<previous or bb>part_duration+.15:raise ValueError('ForcedAligner returned invalid timestamps; refusing fabricated alignment.')
     previous=aa
     if bb>part_duration:corrected+=1
     chunk_words.append(dict(word=item.text,startTime=offset+min(aa,part_duration),endTime=offset+min(bb,part_duration)))
    if not chunk_words:raise ValueError('Nonempty ASR without forced word alignment.')
    texts.append(text);words.extend(chunk_words)
   chunks.append(dict(startSample=begin,endSample=end,startTime=offset,endTime=end/16000,generationTokens=out.generation_tokens,wordCount=len(chunk_words),alignment_end_clamps=corrected))
   mx.clear_cache()
  if not words:raise ValueError('No speech transcription with word timestamps.')
  text=' '.join(texts);tokens=re.findall(r"[a-z']+",text.lower());grams=collections.Counter(tuple(tokens[i:i+5]) for i in range(max(0,len(tokens)-4)));repeat=max(grams.values(),default=0)
  data=dict(text=text,wordTimings=words,durationSeconds=duration,audioFile=str(source),chunks=chunks,wordTimestampMethod='Qwen3-ForcedAligner-0.6B bf16 on same audio chunks; global offsets',qualityWarnings=(['Repeated five-word phrase; review transcript.'] if repeat>=10 else []))
  (tmp/'json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n');(tmp/'txt').write_text(text+'\n');(tmp/'srt').write_text('\n'.join(f'{i}\n{stamp(w["startTime"])} --> {stamp(w["endTime"])}\n{w["word"]}\n' for i,w in enumerate(words,1)))
  report=dict(engine='qwen-asr',model='Qwen3-ASR-1.7B-bf16',aligner='Qwen3-ForcedAligner-0.6B-bf16',source_revision=lock['mlx_audio_revision'],model_revisions={k:m['revision'] for k,m in lock['models'].items()},decoded_duration_seconds=duration,source_duration_seconds=duration,full_input_decoded=True,full_decoded_file_submitted=True,pcm_samples=frames,chunk_samples_sum=sum(x['endSample']-x['startSample'] for x in chunks),chunk_count=len(chunks),model_load_and_preflight_seconds=loaded-start,asr_process_seconds=asr_seconds,forced_alignment_seconds=align_seconds,total_seconds=time.perf_counter()-start,word_count=len(words),max_repeated_fivegram=repeat,prompt_used=bool(a.prompt),inference='Local MLX; HF offline; actual forced alignment, no synthetic word timing',accuracy='Not evaluated against private reference')
  (tmp/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
  for e in exts:os.link(tmp/e,str(prefix)+'.'+e)
 print(f'Complete local Qwen ASR and word alignment: {prefix}.json',flush=True)
if __name__=='__main__':
 try:main()
 except Exception as e:print(f'Error: {type(e).__name__}: {e}',file=sys.stderr);sys.exit(1)
