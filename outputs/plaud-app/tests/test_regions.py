import base64,json,sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from regions import checked_host,initial_host,claims,HOSTS
class Regions(unittest.TestCase):
 def token(self,region):return 'x.'+base64.urlsafe_b64encode(json.dumps({'sub':'test','region':region}).encode()).decode().rstrip('=')+'.x'
 def test_china(self):self.assertEqual(initial_host({'apiHost':'https://api.plaud.cn'},self.token('cn')),('cn','https://api.plaud.cn'))
 def test_global_hosts(self):
  for host in HOSTS['global']:self.assertEqual(checked_host(host,'global'),host)
 def test_reject_token_exfiltration(self):
  for host in ['https://evil.com','https://api.plaud.ai.evil.com','http://api.plaud.ai','https://api.plaud.ai@evil.com','https://api.plaud.ai/path','https://api.plaud.cn']:
   with self.assertRaises(ValueError):checked_host(host,'global')
 def test_no_cross_region(self):
  with self.assertRaises(ValueError):checked_host('https://api.plaud.ai','cn')
 def test_claim_hint(self):self.assertEqual(initial_host({'accountRegion':'global'},self.token('aws:eu-central-1')),('global','https://api-euc1.plaud.ai'))
 def test_invalid_token(self):
  with self.assertRaises(ValueError):claims('invalid')
if __name__=='__main__':unittest.main()
