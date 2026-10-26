"""CN account-owned device only. No fixed address or cached-signature fallback.

GET /device/list and POST /device-app/device/sn-sign are evidenced by saved
official CN web source and the existing PlaudAPI client. After successful online
download only, a verified identity/signature cache enables offline use. Existing
RSA key is read only and never copied. Refuses FE11/new binding and protocol30.
"""
import argparse,asyncio,base64,hashlib,json,os,struct,subprocess,time,uuid
from pathlib import Path
from bleak import BleakScanner,BleakClient
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305,AESGCM
from cryptography.hazmat.primitives.ciphers import Cipher,algorithms

WRITE='00002bb1-0000-1000-8000-00805f9b34fb'
NOTIFY='00002bb0-0000-1000-8000-00805f9b34fb'
ROOT=Path(__file__).resolve().parents[2]
CACHE=Path(__file__).resolve().parent/'private/verified-device.json'
def emit(**x):print(json.dumps(x,sort_keys=True),flush=True)
def advert_serial(data):
    if len(data)<22 or data[2]!=2 or data[5]!=4 or data[10]!=8:return None
    if int.from_bytes(data[3:5],'little') not in (881,883):return None
    if int.from_bytes(data[20:22],'little')!=20:return None
    return data[11:19].hex().upper()

def strict_rsa(blob,key):
    assert len(blob)==256
    nums=key.private_numbers();n=nums.public_numbers.n;c=int.from_bytes(blob,'big');assert c<n
    raw=pow(c,nums.d,n).to_bytes(256,'big');sep=raw.find(b'\0',2)
    assert raw[:2]==b'\0\x02' and sep>=10
    return raw[sep+1:]

def validated_audio(data,key):
    assert len(data)>=512 and data[:8]==b'PLAUD.AI'
    version,header=struct.unpack_from('<HH',data,8)
    assert version==1 and 512<=header<len(data)
    assert struct.unpack_from('<I',data,144)[0]==0,'Unsupported segmented encryption'
    content_key=strict_rsa(data[256:512],key)
    assert len(content_key)==32
    nonce=data[128:144]
    clear=Cipher(algorithms.ChaCha20(content_key,nonce),mode=None).decryptor().update(data[header:])
    pos=0;pages=0;last_flags=0
    while pos<len(clear):
        assert clear[pos:pos+4]==b'OggS' and len(clear)-pos>=27
        segments=clear[pos+26];assert pos+27+segments<=len(clear)
        size=27+segments+sum(clear[pos+27:pos+27+segments]);assert pos+size<=len(clear)
        page=bytearray(clear[pos:pos+size]);stored=struct.unpack_from('<I',page,22)[0];page[22:26]=b'\0'*4
        crc=0
        for b in page:
            crc^=b<<24
            for _ in range(8):crc=((crc<<1)^0x04c11db7 if crc&0x80000000 else crc<<1)&0xffffffff
        assert crc==stored
        last_flags=clear[pos+5];pos+=size;pages+=1
    assert pages>0 and last_flags&4
    return clear,pages

async def main(download=False,offline=True,serial=None):
    path=Path.home()/'Library/Application Support/PlaudeArchiverCN/bluetooth-identity.json'
    if not path.exists():raise ValueError('缺少本机设备认证材料，请先登录并准备蓝牙密钥。')
    before=path.read_bytes()
    try:
        assert path.stat().st_mode&0o077==0
        s=json.loads(before);cache=s;subject=s['subject']
        key=serialization.load_pem_private_key(s['devicePrivatePEM'].encode(),None)
        public=serialization.load_pem_public_key(s['devicePublicPEM'].encode())
        assert key.public_key().public_numbers()==public.public_numbers()
        owned={s['serial']}
        if serial and serial.upper() not in owned:raise ValueError('所选设备与本机认证材料不匹配，未连接。')
        emit(offline=True,network_calls=0)
        assert owned
        matched={};unsupported=0
        def on_advert(device,a):
            raw=a.manufacturer_data.get(0x005d)
            if raw is None:return
            sn=advert_serial(b'\x5d\x00'+raw)
            if sn in owned:matched[device.address]=(device,sn)
        async with BleakScanner(detection_callback=on_advert):await asyncio.sleep(15)
        emit(account_note_pro_count=len(owned),account_matched_advertisements=len(matched))
        if len(matched)!=1:
            emit(outcome='stop_no_unique_account_device',connected=False);raise SystemExit(2)
        device,sn=next(iter(matched.values()))
        # Never use next(iter(cached signatures)): sign the account-owned, advertised SN.
        signature=base64.b64decode(cache['signature'],validate=True)
        assert len(signature)==256
        key=serialization.load_pem_private_key(s['devicePrivatePEM'].encode(),None)
        public=serialization.load_pem_public_key(s['devicePublicPEM'].encode())
        assert key.public_key().public_numbers()==public.public_numbers()
        emit(account_device_guard_passed=True,signature_available=True)
        q=asyncio.Queue()
        async with BleakClient(device,timeout=20) as client:
            await client.start_notify(NOTIFY,lambda _,data:q.put_nowait(bytes(data)))
            for i in range(3):
                await client.write_gatt_char(WRITE,struct.pack('<HBB',0xFE10,3,i)+signature[i*100:(i+1)*100],response=True)
            parts={};total=None
            while total is None or len(parts)<total:
                frame=await asyncio.wait_for(q.get(),12)
                assert len(frame)>=5 and int.from_bytes(frame[:2],'little')==0xFE12,'Unsupported or binding response'
                count,index=frame[2:4]
                assert 0<count<=3 and index<count and (total is None or total==count)
                assert index not in parts or parts[index]==frame[4:]
                total=count;parts[index]=frame[4:]
            blob=b''.join(parts[i] for i in range(total));assert len(blob)==256
            nums=key.private_numbers();n=nums.public_numbers.n;c=int.from_bytes(blob,'big');assert c<n
            raw=pow(c,nums.d,n).to_bytes(256,'big');sep=raw.find(b'\0',2)
            valid=raw[:2]==b'\0\x02' and sep>=10
            emit(strict_rsa_valid=valid)
            assert valid
            secret=raw[sep+1:];assert len(secret)==80
            nonce,aad=secret[32:44],secret[44:56]
            candidates=[]
            for algo in (ChaCha20Poly1305,AESGCM):
                cipher=algo(secret[:32])
                try:
                    if cipher.decrypt(nonce,secret[56:],aad)==b'PLAUD.AI':candidates.append(cipher)
                except Exception:pass
            assert len(candidates)==1;cipher=candidates[0]
            emit(authenticated_session=True,cipher=type(cipher).__name__)
            tx=1;rx=-1
            async def send(packet):
                nonlocal tx
                assert len(packet)>=3 and packet[0]==1 and int.from_bytes(packet[1:3],'little') in (1,3,26,28,29)
                tx+=1
                await client.write_gatt_char(WRITE,cipher.encrypt(nonce,struct.pack('<I',tx)+packet,aad),response=True)
            async def next_packet(timeout=15):
                nonlocal rx
                clear=cipher.decrypt(nonce,await asyncio.wait_for(q.get(),timeout),aad)
                assert len(clear)>=5
                seq=int.from_bytes(clear[:4],'little');assert seq>rx;rx=seq
                return clear[4:]
            async def receive(want):
                end=time.monotonic()+15
                while time.monotonic()<end:
                    packet=await next_packet(max(.01,end-time.monotonic()))
                    if len(packet)>=3 and packet[0]==1 and int.from_bytes(packet[1:3],'little') in want:return packet
                raise TimeoutError()
            bind=(subject+'0'*32)[:32].encode('ascii');assert len(bind)==32
            await send(b'\x01\x01\x00\x02\x00\x00'+bind)
            reply=await receive({1,2})
            if int.from_bytes(reply[1:3],'little')==2:
                await send(b'\x01\x01\x00\x02\x00\x01'+bind);reply=await receive({1})
            assert len(reply)>=6 and reply[3]==0
            version=int.from_bytes(reply[4:6],'little');assert version==20
            emit(handshake_success=True,protocol=version)
            async def get_list():
                await send(b'\x01\x1a\x00'+struct.pack('<IIB',int(time.time()),0,0))
                entries=[];expected=None
                for _ in range(1000):
                    reply=await receive({26});assert len(reply)>=11
                    count,offset=struct.unpack_from('<HH',reply,7)
                    assert expected is None or expected==count;expected=count
                    assert offset==len(entries) and (len(reply)-11)%10==0
                    for i in range(11,len(reply),10):entries.append(struct.unpack_from('<II',reply,i))
                    if len(entries)>=expected:break
                assert len(entries)==expected
                return entries
            async def require_idle():
                await send(b'\x01\x03\x00');reply=await receive({3})
                assert len(reply)>=15 and reply[8]==0 and struct.unpack_from('<I',reply,3)[0]!=4099,'Device not idle'
            entries=await get_list()
            emit(recording_count=len(entries),positive_size_count=sum(size>0 for _,size in entries),smallest_bytes=min((size for _,size in entries if size>0),default=0),outcome='account_owned_ble_list_success')
            if not download:return
            if not any(size>0 for _,size in entries):
                emit(outcome='no_finalized_recording_to_download');raise SystemExit(3)
            await require_idle();confirmed=await get_list()
            if not any(size>0 for _,size in confirmed):
                emit(outcome='no_finalized_recording_to_download');raise SystemExit(3)
            sid,size=min((x for x in confirmed if x[1]>0),key=lambda x:(x[1],x[0]))
            assert (sid,size) in entries and size<=100*1024*1024
            await require_idle()
            await send(b'\x01\x1c\x00'+struct.pack('<III',sid,0,size))
            head=await receive({28});assert len(head)>=8 and head[7]==0
            data=bytearray();ended=False
            while not ended:
                packet=await next_packet(20)
                if len(packet)>=7 and packet[0]==1 and int.from_bytes(packet[1:3],'little')==29:
                    assert struct.unpack_from('<I',packet,3)[0]==sid;ended=True;continue
                if not packet or packet[0]!=2:continue
                assert len(packet)>=10 and struct.unpack_from('<I',packet,1)[0]==sid
                offset=struct.unpack_from('<I',packet,5)[0]
                if offset==0xffffffff:ended=True;continue
                n=packet[9];assert len(packet)==10+n
                if offset<len(data):
                    assert data[offset:offset+n]==packet[10:];continue
                assert offset==len(data) and len(data)+n<=size
                data.extend(packet[10:])
            assert len(data)==size
            # Stop transfer (29) is not delete (30); only read back status/list next.
            await send(b'\x01\x1d\x00');await receive({30})
            await require_idle();after=await get_list();assert (sid,size) in after
            clear,pages=validated_audio(bytes(data),key)
            dest=ROOT/'outputs/plaud-recordings';dest.mkdir(mode=0o700,parents=True,exist_ok=True)
            name='ble-smallest-'+str(uuid.uuid4())
            stage=dest/(name+'.part');final=dest/(name+'.ogg')
            try:
                with os.fdopen(os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600),'wb') as f:f.write(clear)
                probe=subprocess.run(['ffprobe','-v','error','-show_entries','format=duration,size:stream=codec_name,sample_rate,channels','-of','json',str(stage)],capture_output=True,text=True,timeout=30)
                assert probe.returncode==0
                decoded=subprocess.run(['ffmpeg','-v','error','-i',str(stage),'-f','null','-'],capture_output=True,timeout=60)
                assert decoded.returncode==0
                stage.rename(final)
            finally:
                if stage.exists():stage.unlink()
            emit(ble_download_bytes=size,ogg_bytes=len(clear),ogg_crc_pages=pages,ogg_eos=True,source_retained=True,full_decode_success=True,audio_metadata=json.loads(probe.stdout),saved_path=str(final))
    finally:emit(state_unchanged=path.read_bytes()==before)

if __name__=='__main__':
    args=argparse.ArgumentParser();args.add_argument('--download-smallest',action='store_true');args.add_argument('--offline',action='store_true');args.add_argument('--serial');opts=args.parse_args()
    try:asyncio.run(main(opts.download_smallest,True,opts.serial))
    except Exception as e:
        emit(outcome='blocked',error_type=type(e).__name__,message=str(e) if isinstance(e,ValueError) else '蓝牙认证或传输失败；原录音保留');raise SystemExit(1)
