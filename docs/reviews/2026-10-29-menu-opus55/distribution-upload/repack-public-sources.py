import hashlib,io,sys,tarfile
from pathlib import Path
old,new=map(Path,sys.argv[1:])
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
assert sha(old)=='4df14eda667bddb071c44c6813b5b7aeba36594a042e1763de8178b963752008'
with tarfile.open(old) as source,tarfile.open(new,'w',format=tarfile.PAX_FORMAT) as dest:
 for member in source:
  prefix='dmx-sources-0.3.12';assert member.name==prefix or member.name.startswith(prefix+'/')
  info=tarfile.TarInfo(member.name.replace(prefix,'dmx-sources-0.4.0',1));info.type=member.type;info.mode=member.mode;info.mtime=0
  if member.isfile():
   stream=source.extractfile(member)
   if member.name==prefix+'/README.md':
    assert member.size<16384
    data=stream.read().replace(b'0.3.12',b'0.4.0');info.size=len(data);dest.addfile(info,io.BytesIO(data))
   else:info.size=member.size;dest.addfile(info,stream)
  else:assert member.isdir();dest.addfile(info)
assert new.stat().st_size==496209920
assert sha(new)=='ff958e5f94157f84c34c64fda74ab5fbdcc3726627740c0dfd29bf898b882579'
print('Reconstructed source archive is byte-identical to the locally qualified v0.4.0 archive.')
