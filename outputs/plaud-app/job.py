#!/usr/bin/env python3
"""App bridge. Secrets arrive on stdin; recordings and derived artifacts stay in a library."""
import hashlib, json, os, platform, shutil, signal, socket, subprocess, sys, tempfile, time, urllib.request, uuid
import re
from collections import Counter
from datetime import datetime
from summary_service import generate as generate_summary
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
os.environ['PATH'] = str(ROOT/'tools/llama')+':'+str(ROOT/'deps/bin')+':'+os.environ.get('PATH', '/usr/bin:/bin')
os.umask(0o077)
def cancelled(signum, frame):
    raise KeyboardInterrupt()
signal.signal(signal.SIGTERM, cancelled)

def member(folder, name):
    if not isinstance(name,str) or Path(name).name != name or name in {'.','..'}:
        raise ValueError('录音库元数据包含无效文件名。')
    path=(folder/name).resolve()
    if path.parent!=folder: raise ValueError('录音库文件不能指向库外。')
    return path

def emit(**value):
    print(json.dumps(value, ensure_ascii=False), flush=True)

def run(args):
    with tempfile.TemporaryFile() as log:
        p = subprocess.run([str(x) for x in args], stdout=log, stderr=log)
        if p.returncode:
            raise RuntimeError(f'处理失败（退出码 {p.returncode}）。请检查模型是否安装、音频是否可读；未覆盖已有结果。')

def save(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    tmp.replace(path)

def quality_warning(text):
    words=re.findall(r"[a-z0-9']+",text.lower())
    grams=Counter(tuple(words[i:i+5]) for i in range(max(0,len(words)-4)))
    if len(words)>=80 and grams and max(grams.values())>=10 and len(grams)/sum(grams.values())<0.5:
        return '检测到大量重复文本，可能是识别循环。请先核对音频，或改用其他模型重新转写；暂不生成摘要。'
    return ''

def ensure_assets(request):
    """Prepare only the selected engine's missing assets before touching user audio."""
    jobs=[];engine=request.get('engine','qwen-asr')
    if request['action']=='transcribe':
        diar=ROOT/'work/plaud-diarization/models'
        lock=json.loads((ROOT/'outputs/plaud-diarization/model-lock.json').read_text())
        if not (ROOT/'outputs/plaud-engine/bin/fluidaudiocli').is_file():
            raise ValueError('缺少说话人推理引擎组件。请先安装应用运行环境；不能只复制模型文件。')
        if any(not (diar/name).is_file() for name in lock['files']):
            jobs.append(('说话人标注模型',[sys.executable,ROOT/'outputs/plaud-diarization/download-model.py']))
        if engine=='apple-speech':
            if not platform.mac_ver()[0] or int(platform.mac_ver()[0].split('.')[0])<26:
                raise ValueError('Apple Speech 需要 macOS 26 或更新版本。')
            helper=ROOT/'outputs/plaud-apple-speech/apple-speech'
            if not helper.is_file():raise ValueError('缺少苹果语音 CLI 组件，请更新应用。')
            result=subprocess.run([str(helper),'--status'],capture_output=True,text=True)
            try:capability=json.loads(result.stdout)
            except ValueError:raise ValueError('无法检测苹果语音模型状态。')
            if not capability.get('available') or capability.get('assetStatus')=='unsupported':
                raise ValueError('此 Mac 当前不支持所选苹果语音模型。请选择其他引擎。')
            if capability.get('assetStatus')!='installed':jobs.append(('苹果英语语音模型（由系统管理）',[helper,'--install-assets']))
        elif engine=='qwen-asr':
            lock=json.loads((ROOT/'outputs/plaud-qwen-asr/model-lock.json').read_text())
            missing=any(not (ROOT/'work/plaud-qwen-asr/models'/kind/file['path']).is_file()
                        for kind,model in lock['models'].items() for file in model['files'])
            if not (ROOT/'outputs/plaud-qwen-asr/install-verification.json').is_file() or missing:
                jobs.append(('Qwen3-ASR 与对齐模型（约 5.9 GB）',[sys.executable,ROOT/'outputs/plaud-qwen-asr/setup.py']))
        elif engine=='whisper-large' and not (ROOT/'work/plaud-research/models/ggml-large-v3.bin').is_file():
            jobs.append(('Whisper large-v3（约 3.1 GB）',[sys.executable,ROOT/'outputs/plaud-whisper-large/setup.py']))
        elif engine=='parakeet' and not (ROOT/'work/plaud-english/models/phonon-2/download-manifest.json').is_file():
            jobs.append(('Phonon-2 模型',[sys.executable,ROOT/'outputs/plaud-engine/download-model.py']))
    for title,command in jobs:
        if request.get('offline'):raise ValueError('离线模式缺少'+title+'。请先联网安装模型。')
        emit(status='首次使用：缺少'+title+'，正在自动下载并校验；不会上传录音。')
        run(command)

def import_audio(source, library):
    source = Path(source).resolve()
    if not source.is_file(): raise ValueError('找不到音频文件。')
    if source.suffix.lower() not in {'.ogg','.wav','.mp3','.m4a','.flac','.mp4','.aac','.webm'}:
        raise ValueError('请选择支持的音频文件。')
    with source.open('rb') as f: digest=hashlib.file_digest(f,'sha256').hexdigest()
    for existing in library.glob('*/recording.json'):
        try:
            old=json.loads(existing.read_text())
            if old.get('sha256')==digest and member(existing.parent,old['audio']).is_file():
                return existing.parent,old
        except (ValueError,KeyError,OSError): continue
    label=re.sub(r'[^\w .-]','_',source.stem)[:65].strip(' .') or '录音'
    folder = library / (datetime.now().strftime('%Y-%m-%d %H-%M-%S')+' '+label+' '+uuid.uuid4().hex[:8])
    folder.mkdir(parents=True, mode=0o700)
    audio = folder / ('audio' + source.suffix.lower())
    shutil.copyfile(source, audio)
    meta = dict(id=folder.name, title=source.stem, audio=audio.name, created=time.time(), sha256=digest,state='已导入')
    save(folder/'recording.json', meta)
    return folder, meta

def cloud_asr(audio, key, prompt, output):
    if not key: raise ValueError('请先在 App 中保存 Groq API Key。')
    # FLAC reduces transfer size without losing decoded audio samples.
    flac = output.parent / 'upload.flac'
    try:
        run(['ffmpeg','-nostdin','-v','error','-i',audio,'-ar','16000','-ac','1',flac])
        if flac.stat().st_size > 24_000_000:
            raise ValueError('此录音超过当前云端上传限制，请使用本地模型或先分段。')
        boundary = 'Plaud' + uuid.uuid4().hex
        fields = [('model','whisper-large-v3'),('language','en'),('response_format','verbose_json'),
                  ('timestamp_granularities[]','word'),('temperature','0')]
        if prompt: fields.append(('prompt',prompt))
        parts=[]
        for name,value in fields:
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
        parts += [f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.flac"\r\nContent-Type: audio/flac\r\n\r\n'.encode(),flac.read_bytes(),f'\r\n--{boundary}--\r\n'.encode()]
        request=urllib.request.Request('https://api.groq.com/openai/v1/audio/transcriptions',data=b''.join(parts),
            headers={'Authorization':'Bearer '+key,'Content-Type':'multipart/form-data; boundary='+boundary,'User-Agent':'PlaudLocalApp/1.0'})
        with urllib.request.urlopen(request,timeout=300) as response: data=json.load(response)
        words=[dict(word=w['word'],startTime=w['start'],endTime=w['end']) for w in data.get('words',[])]
        if not words: raise ValueError('云端未返回词时间戳，无法进行可靠的说话人对齐。')
        duration=float(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration','-of','default=noprint_wrappers=1:nokey=1',str(flac)]))
        save(output,dict(text=data.get('text',''),wordTimings=words,durationSeconds=duration,provider='Groq',model='whisper-large-v3'))
    finally:
        flac.unlink(missing_ok=True)


def main():
    request=json.load(sys.stdin)
    library=Path(request['library']).expanduser().resolve(); library.mkdir(parents=True,exist_ok=True,mode=0o700)
    action=request['action']
    if action=='install':
        model=request['model']; emit(status='正在下载并校验公开模型，可能需要几分钟…')
        if model=='apple-speech':run([ROOT/'outputs/plaud-apple-speech/apple-speech','--install-assets'])
        elif model=='qwen-asr': run([sys.executable,ROOT/'outputs/plaud-qwen-asr/setup.py'])
        elif model=='large': run([sys.executable,ROOT/'outputs/plaud-whisper-large/setup.py'])
        elif model=='fast':
            if not (ROOT/'outputs/plaud-engine/bin/fluidaudiocli').is_file():raise ValueError('缺少原生推理组件，请重新运行安装器。')
            run([sys.executable,ROOT/'outputs/plaud-engine/download-model.py'])
            run([sys.executable,ROOT/'outputs/plaud-diarization/download-model.py'])
        elif model=='summary':
            lock=json.loads((ROOT/'outputs/plaud-app/summary-model.json').read_text())
            folder=ROOT/'work/plaud-summary'; folder.mkdir(parents=True,exist_ok=True)
            target=folder/lock['file']; temp=target.with_suffix('.part')
            if not target.exists():
                urllib.request.urlretrieve(f"https://huggingface.co/{lock['repo']}/resolve/{lock['revision']}/{lock['file']}",temp)
                with temp.open('rb') as f:
                    if hashlib.file_digest(f,'sha256').hexdigest()!=lock['sha256']: raise RuntimeError('摘要模型下载校验失败。')
                temp.replace(target)
            with target.open('rb') as f:
                if hashlib.file_digest(f,'sha256').hexdigest()!=lock['sha256']: raise RuntimeError('摘要模型校验失败。')
        else: raise ValueError('未知模型。')
        emit(status='模型安装和校验完成。',done=True); return
    if action=='prepare-bluetooth':
        from prepare_bluetooth import prepare
        emit(**prepare(request.get('serial') or None));return
    if action=='scan':
        p=subprocess.run([sys.executable,str(ROOT/'outputs/plaud-app/bluetooth_scan.py')],capture_output=True,text=True)
        if p.returncode:raise RuntimeError('蓝牙扫描失败，请检查系统蓝牙和终端/App蓝牙权限。')
        devices=json.loads(p.stdout);save(library/'bluetooth-devices.json',devices)
        emit(status='扫描完成：'+str(len(devices))+' 台 Note Pro',devices=devices,done=True);return
    if action in {'connect','download'}:
        emit(status='正在通过本地认证材料匹配蓝牙设备…')
        command=[str(ROOT/'outputs/plaud-download')]
        if action=='connect':command+=['--check']
        if request.get('serial'):command+=['--serial',request['serial']]
        p=subprocess.run(command,capture_output=True,text=True)
        if p.returncode:
            if '缺少本机设备认证材料' in p.stdout:raise RuntimeError('缺少本机设备认证材料。请先登录并准备蓝牙密钥，然后验证连接。')
            raise RuntimeError('本地蓝牙认证或传输失败，请核对设备和认证材料；未删除原录音。')
        if action=='connect':emit(status='设备认证与录音列表检查通过；连接已释放，可开始导入。',done=True);return
        events=[json.loads(s) for s in p.stdout.splitlines() if s.startswith('{')]
        found=next((x['saved_path'] for x in events if 'saved_path' in x),None)
        if not found: raise RuntimeError('未返回可验证的录音。')
        folder,meta=import_audio(found,library)
    elif action=='import': folder,meta=import_audio(request['source'],library)
    else:
        folder=(library/request['id']).resolve()
        if folder.parent!=library: raise ValueError('无效录音。')
        meta=json.loads((folder/'recording.json').read_text())
        audio=member(folder,meta['audio'])
        if action=='transcribe':
            if request.get('offline') and request.get('engine')=='groq':raise ValueError('离线模式不能调用云端转写。')
            ensure_assets(request)
            engine=request['engine']; prompt=request.get('prompt','').strip()
            prefix=folder/('transcript-'+str(time.time_ns()))
            emit(status='正在识别完整录音并标注说话人…')
            command=[ROOT/'outputs/plaud-transcribe','--engine',engine]
            if engine=='groq':
                if request.get('allow_upload') is not True: raise ValueError('尚未允许上传录音。')
                external=folder/('cloud-'+uuid.uuid4().hex+'.json')
                emit(status='正在将所选音频上传至 Groq，之后在本地标注说话人…')
                cloud_asr(audio,request.get('api_key',''),prompt,external)
                command=[ROOT/'outputs/plaud-transcribe','--asr-json',external]
            elif engine not in {'parakeet','whisper','whisper-large','qwen-asr','apple-speech'}: raise ValueError('未知模型。')
            elif prompt and (engine.startswith('whisper') or engine=='qwen-asr'): command+=['--prompt',prompt]
            run(command+[audio,prefix])
            result=json.loads(Path(str(prefix)+'.json').read_text())
            warning=quality_warning(result.get('text',''))
            meta.update(transcript=prefix.name+'.txt',result_json=prefix.name+'.json',engine=engine,
                        quality_warning=warning,state='需要核对：异常重复' if warning else '已转写')
            # Notes from an older transcription remain on disk but are no longer shown as current.
            meta.pop('notes',None)
        elif action=='summarize':
            if not meta.get('transcript'): raise ValueError('请先转写。')
            if meta.get('quality_warning'): raise ValueError(meta['quality_warning'])
            provider=request.get('summary_provider','local')
            if request.get('offline') and provider in {'groq','deepseek'}:raise ValueError('离线模式不能调用云端摘要。')
            if provider in {'groq','deepseek'} and request.get('allow_text_upload') is not True:
                raise ValueError('尚未允许将转写文本发送至所选云端服务商。')
            result=generate_summary(member(folder,meta['transcript']).read_text(),request.get('summary_prompt',''),
                                    provider,request.get('api_key',''),emit)
            stem='notes-'+str(time.time_ns());name=stem+'.md'
            (folder/name).write_text('# '+result['title']+'\n\n> AI 生成，请核对原始转写。\n\n'+result['markdown'])
            save(folder/(stem+'.json'),result)
            meta.update(notes=name,suggested_title=result['title'],state='已生成摘要、名称和待办')
            if request.get('rename',True):
                meta.setdefault('title_history',[]).append(meta['title']);meta['title']=result['title']
                (folder/'录音名称.txt').write_text(result['title']+'\n')
        elif action=='rename':
            title=request.get('title','').strip()
            if not title or len(title)>120 or any(ord(c)<32 for c in title):raise ValueError('名称须为1至120个字符，且不能包含控制字符。')
            meta.setdefault('title_history',[]).append(meta['title']);meta['title']=title
            (folder/'录音名称.txt').write_text(title+'\n')
        else: raise ValueError('未知操作。')
        save(folder/'recording.json',meta)
    emit(status=meta['state'],id=meta['id'],done=True)

if __name__=='__main__':
    try: main()
    except urllib.error.HTTPError as error:
        emit(error=f'云端请求失败（HTTP {error.code}）。请检查 API Key、额度或文件限制。'); sys.exit(1)
    except Exception as error:
        emit(error=str(error) if isinstance(error,(ValueError,RuntimeError)) else '操作失败，请检查本地依赖、存储权限和连接。'); sys.exit(1)
