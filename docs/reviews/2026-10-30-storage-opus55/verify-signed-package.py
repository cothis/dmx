import hashlib,json,struct,subprocess,tarfile,tempfile
from pathlib import Path
root=Path.cwd();out=root/'.build/storage-review';dist=out/'qualified-v0.4.1';app=root/'.build/signed/dmx.app'
def run(argv):
 p=subprocess.run(list(map(str,argv)),capture_output=True,text=True,timeout=60)
 assert p.returncode==0,(str(argv[0]),p.returncode,p.stdout,p.stderr)
 return p.stdout

def sections(path):
 data=path.read_bytes();header=struct.unpack_from('<8I',data);assert header[0]==0xfeedfacf
 result={};offset=32
 for _ in range(header[4]):
  cmd,size=struct.unpack_from('<II',data,offset)
  if cmd==0x19:
   for i in range(struct.unpack_from('<I',data,offset+64)[0]):
    start=offset+72+i*80;name=data[start:start+16].split(b'\0')[0].decode();segment=data[start+16:start+32].split(b'\0')[0].decode();length=struct.unpack_from('<Q',data,start+40)[0];fileoff=struct.unpack_from('<I',data,start+48)[0]
    if length and fileoff and segment!='__LINKEDIT':result[segment+','+name]=hashlib.sha256(data[fileoff:fileoff+length]).hexdigest()
  offset+=size
 return result

def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
log=(out/'signed-package.log').read_text();result=json.loads(next(line for line in reversed(log.splitlines()) if line.startswith('{"ok"')))
assert result['ok'] and result['pin_changed'] is False
assert result['guest']['sha256']=='43b167dc3f66f153b6712bda0a4b3047f57ab84f8d8f771482356ecb8fa34ecb'
assert sections(root/'.build/release/dmx')==sections(root/'.build/signed/dmx')
assert sections(root/'.build/release/dmx-menu')==sections(app/'Contents/MacOS/dmx-menu')
assert sha(root/'.build/signed/dmx')==sha(app/'Contents/MacOS/dmx')
run(['codesign','--verify','--strict','--check-notarization',root/'.build/signed/dmx'])
for cmd in [['codesign','--verify','--deep','--strict','--check-notarization',app],['xcrun','stapler','validate',app],['spctl','--assess','--type','execute',app]]:run(cmd)
assert run([root/'.build/signed/dmx','--version']).strip()=='0.4.1'
archive=dist/'dmx-0.4.1-darwin-arm64.tar.gz'
with tempfile.TemporaryDirectory(prefix='dmx-signed-archive-') as tmp:
 target=Path(tmp)
 with tarfile.open(archive) as tar:
  for member in tar:
   parts=Path(member.name).parts
   assert (member.isfile() or member.isdir()) and not member.name.startswith('/') and '..' not in parts
   assert member.name in ['dmx','LICENSE','THIRD_PARTY.md','dmx.app'] or member.name.startswith('dmx.app/')
   dest=target/member.name;dest.parent.mkdir(parents=True,exist_ok=True)
   if member.isdir():
    dest.mkdir(exist_ok=True);dest.chmod(0o755);continue
   dest.write_bytes(tar.extractfile(member).read());dest.chmod(member.mode&0o777)
  run(['codesign','--verify','--deep','--strict','--check-notarization',target/'dmx.app'])
  assert sha(target/'dmx')==sha(target/'dmx.app/Contents/MacOS/dmx')==sha(root/'.build/signed/dmx')
  run(['xcrun','stapler','validate',target/'dmx.app'])
files=sorted(p for p in dist.iterdir() if p.is_file());assert len(files)==14
assets=[{'name':p.name,'bytes':p.stat().st_size,'sha256':sha(p)} for p in files]
report={'ok':True,'commit':run(['git','rev-parse','v0.4.1^{commit}']).strip(),'pin_changed':False,'cli_notary':'fd17644b-1eec-4178-95ae-9258b17a73bd','app_notary':'8ef8ff4e-c09a-4aa3-9020-a05b87775c57','compiled_sections_match_qualified_source':True,'archive_roundtrip_signature_and_staple':True,'package':result,'assets':assets}
(out/'signed-package-verification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'ok':True,'commit':report['commit'],'assets':len(assets),'pin_changed':False}))
