"""Read advertisements only: no pairing, cloud access, writes, or audio transfer."""
import asyncio,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'work/plaud-research'))
from cn_account_guarded_probe import advert_serial
from bleak import BleakScanner
async def main():
 found={}
 def seen(device,advert):
  raw=advert.manufacturer_data.get(0x005d)
  if raw is None:return
  serial=advert_serial(b'\x5d\x00'+raw)
  if serial:found[serial]=dict(serial=serial,name=advert.local_name or device.name or 'Note Pro',rssi=advert.rssi)
 async with BleakScanner(detection_callback=seen):await asyncio.sleep(10)
 print(json.dumps(list(found.values()),ensure_ascii=False))
asyncio.run(main())
