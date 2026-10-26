"""Only account device list, encryption key and device signature; never cloud recordings."""
import argparse,base64,hashlib,json,os
from pathlib import Path
import requests
from regions import initial_host,checked_host,claims
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import serialization
os.umask(0o077)
HOME=Path.home()/'Library/Application Support/PlaudeArchiverCN'
IDENTITY=HOME/'bluetooth-identity.json'
def atomic(path,obj):
 temp=path.with_suffix('.tmp')
 with temp.open('w') as f:json.dump(obj,f)
 os.chmod(temp,0o600);temp.replace(path)
def prepare(serial=None):
 state_path=HOME/'state.json'
 if not state_path.exists():raise ValueError('请先在 App 登录 Plaud，仅用于取得蓝牙认证。')
 state=json.loads(state_path.read_text());token=state.get('userToken')
 if not token:raise ValueError('请先登录 Plaud。')
 region,host=initial_host(state,token)
 session=requests.Session();session.headers.update({'Authorization':'Bearer '+token,'app-platform':'web','edit-from':'web','X-Encrypt-Response':'1'})
 def call(method,path,data=None):
  nonlocal host
  if path not in ['/device/list','/device-app/e2ee/gen_key','/device-app/device/sn-sign']:raise ValueError('禁止访问非设备认证接口')
  for attempt in range(2):
   checked_host(host,region)
   r=session.request(method,host+path,json=data,timeout=30,allow_redirects=False)
   if 300 <= r.status_code < 400:raise ValueError('不接受 HTTP 跳转，请重新选择账号区域登录。')
   r.raise_for_status()
   obj=json.loads(Fernet(b'8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI=').decrypt(r.text.strip().encode())) if r.headers.get('x-encrypt-response')=='1' else r.json()
   status=obj.get('status',obj.get('code'))
   if status == -302:
    host=checked_host(obj.get('data',{}).get('domains',{}).get('api'),region)
    continue
   if status!=0:raise ValueError('Plaud 认证接口返回失败，请重新登录；未访问云端录音。')
   return obj
  raise ValueError('账号区域重定向次数过多。')
 response=call('GET','/device/list')
 devices=response.get('data_devices')
 if devices is None:
  data=response.get('data',{})
  devices=data if isinstance(data,list) else data.get('devices',[])
 if not isinstance(devices,list):raise ValueError('无法识别设备列表格式。')
 owned={d['sn'].upper() for d in devices if str(d.get('model')) in {'881','883'}}
 if not owned:raise ValueError('当前账号没有支持的 Note Pro，请核对登录区域及绑定设备。')
 if serial:
  serial=serial.upper()
  if serial not in owned:raise ValueError('所选设备不属于当前账号。')
 elif len(owned)==1:serial=next(iter(owned))
 else:raise ValueError('请先扫描并选择当前账号中的一台 Note Pro。')
 if not state.get('devicePrivatePEM'):
  data=call('POST','/device-app/e2ee/gen_key',{})['data']
  state['devicePrivatePEM']=base64.b64decode(data['private_key_base64']).decode()
  state['devicePublicPEM']=base64.b64decode(data['public_key_base64']).decode()
  atomic(state_path,state)
 private=serialization.load_pem_private_key(state['devicePrivatePEM'].encode(),None)
 public=serialization.load_pem_public_key(state['devicePublicPEM'].encode())
 if private.public_key().public_numbers()!=public.public_numbers():raise ValueError('设备密钥对不匹配。')
 signature=call('POST','/device-app/device/sn-sign',{'sns':[serial]})['data']['signature'][serial]
 if len(base64.b64decode(signature,validate=True))!=256:raise ValueError('设备签名无效。')
 subject=claims(token)['sub']
 state['apiHost']=host;state['accountRegion']=region;atomic(state_path,state)
 atomic(IDENTITY,dict(version=1,region=region,serial=serial,signature=signature,subject=subject,devicePrivatePEM=state['devicePrivatePEM'],devicePublicPEM=state['devicePublicPEM']))
 return {'status':'蓝牙认证材料已保存在本机。请验证连接；没有读取云端录音。','serial':serial,'done':True}
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--serial');args=p.parse_args()
 try:print(json.dumps(prepare(args.serial),ensure_ascii=False))
 except Exception as e:
  print(json.dumps({'error':str(e) if isinstance(e,ValueError) else '设备认证失败，请检查登录或网络。'},ensure_ascii=False));raise SystemExit(1)
