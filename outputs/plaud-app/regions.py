"""Explicit region/host allowlist; no token may be sent to arbitrary redirect hosts."""
import base64,json
from urllib.parse import urlsplit
REGIONAL={'aws:ap-southeast-1':'https://api-apse1.plaud.ai','aws:us-east-1':'https://api-use1.plaud.ai','aws:eu-central-1':'https://api-euc1.plaud.ai','aws:us-west-2':'https://api-usw2.plaud.ai'}
HOSTS={'cn':{'https://api.plaud.cn'},'global':{'https://api.plaud.ai',*REGIONAL.values()}}
def claims(token):
 try:
  part=token.split('.')[1];return json.loads(base64.urlsafe_b64decode(part+'='*(-len(part)%4)))
 except Exception:raise ValueError('登录凭据格式无效，请重新登录。')
def checked_host(host,region):
 if region not in HOSTS or host not in HOSTS[region]:raise ValueError('认证服务返回了不受信任或跨区域的地址，已停止。')
 return host
def initial_host(state,token):
 region=state.get('accountRegion') or ('cn' if state.get('apiHost')=='https://api.plaud.cn' else 'global')
 host=state.get('apiHost')
 if not host:host='https://api.plaud.cn' if region=='cn' else REGIONAL.get(claims(token).get('region'),'https://api.plaud.ai')
 return region,checked_host(host,region)
