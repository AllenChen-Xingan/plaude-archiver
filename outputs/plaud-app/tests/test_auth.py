import base64,json,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import prepare_bluetooth as auth
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
class Response:
 status_code=200;headers={}
 def __init__(self,value):self.value=value
 def raise_for_status(self):pass
 def json(self):return self.value
class Session:
 def __init__(self,redirect=None):self.headers={};self.calls=[];self.redirect=redirect
 def request(self,method,url,**kw):
  self.calls.append((method,url))
  if self.redirect and len(self.calls)==1:return Response({'status':-302,'data':{'domains':{'api':self.redirect}}})
  if url.endswith('/device/list'):return Response({'status':0,'data_devices':[{'sn':'8811000000000001','model':881}]})
  if url.endswith('/device-app/device/sn-sign'):return Response({'status':0,'data':{'signature':{'8811000000000001':base64.b64encode(bytes(256)).decode()}}})
  raise AssertionError('Unexpected endpoint: '+url)
class Auth(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
  cls.private=key.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()).decode()
  cls.public=key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
 def run_case(self,region,redirect=None):
  temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);root=Path(temp.name)
  payload=base64.urlsafe_b64encode(json.dumps({'sub':'test-account'}).encode()).decode().rstrip('=')
  state=dict(userToken='x.'+payload+'.x',accountRegion=region,apiHost='https://api.plaud.cn' if region=='cn' else 'https://api.plaud.ai',devicePrivatePEM=self.private,devicePublicPEM=self.public)
  (root/'state.json').write_text(json.dumps(state));session=Session(redirect)
  with patch.object(auth,'HOME',root),patch.object(auth,'IDENTITY',root/'identity.json'),patch.object(auth.requests,'Session',return_value=session):
   result=auth.prepare()
  identity=json.loads((root/'identity.json').read_text())
  self.assertNotIn('userToken',identity);self.assertEqual(identity['region'],region)
  self.assertEqual((root/'identity.json').stat().st_mode&0o777,0o600)
  self.assertTrue(all('/file' not in url for _,url in session.calls))
  return session,result
 def test_china(self):self.assertEqual(len(self.run_case('cn')[0].calls),2)
 def test_international(self):self.assertEqual(len(self.run_case('global')[0].calls),2)
 def test_international_regional_redirect(self):
  session,_=self.run_case('global','https://api-euc1.plaud.ai')
  self.assertTrue(session.calls[-1][1].startswith('https://api-euc1.plaud.ai/'))
 def test_redirect_refused_before_second_request(self):
  with self.assertRaises(ValueError):self.run_case('global','https://evil.example')
if __name__=='__main__':unittest.main()
