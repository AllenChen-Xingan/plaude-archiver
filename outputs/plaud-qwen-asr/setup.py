#!/usr/bin/env python3
"""Install pinned MLX Qwen3 speech models; network is used only here."""
import pathlib,sys,subprocess,json,os
P=pathlib.Path(__file__).resolve().parent;ROOT=P.parents[1];V=ROOT/'work/plaud-qwen-asr/venv';lock=json.loads((P/'model-lock.json').read_text())
if not (V/'bin/python').exists():subprocess.run([sys.executable,'-m','venv',str(V)],check=True)
requirements=P/'requirements-lock.txt'
if requirements.exists():cmd=[str(V/'bin/python'),'-m','pip','install','-r',str(requirements)]
else:cmd=[str(V/'bin/python'),'-m','pip','install',f"mlx-audio[stt] @ git+https://github.com/Blaizzy/mlx-audio.git@{lock['mlx_audio_revision']}"]
subprocess.run(cmd,check=True)
from download_models import download
download()
subprocess.run([str(V/'bin/python'),'-c','from mlx_audio.stt import load; import mlx.core; print("MLX speech runtime import verified")'],check=True)
subprocess.run([str(V/'bin/python'),'-m','pip','check'],check=True)
(P/'install-verification.json').write_text(json.dumps({'verified':True,'mlx_audio_revision':lock['mlx_audio_revision'],'models':{k:{'revision':m['revision'],'path':str(ROOT/'work/plaud-qwen-asr/models'/k)} for k,m in lock['models'].items()},'precision':'bf16; non-quantized','alignment':'Qwen3-ForcedAligner-0.6B actual inferred word timestamps'},indent=2)+'\n')
print('Qwen3 ASR and ForcedAligner installed and verified.')
