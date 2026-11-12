#!/usr/bin/env python3
import hashlib,json,os,re,subprocess,tempfile
from pathlib import Path
root=Path(__file__).resolve().parent
jar=Path(os.environ.get('TLA2TOOLS',Path.home()/'.cache/proof-skills/tla2tools.jar'))
assert hashlib.sha256((root/'tla/Properties.tla').read_bytes()).hexdigest()==(root/'properties.sha256').read_text().strip(), 'Frozen properties changed'
checks=[]
for name,violation in [('MC',None),('MC_frames','NoLegalInputRejected'),('MC_credit','NoLegalInputRejected'),('MC_sanity','NeverSends')]:
 with tempfile.TemporaryDirectory(prefix='dmx-credit-') as tmp:
  r=subprocess.run(['java','-XX:+UseParallelGC','-cp',str(jar),'tlc2.TLC','-noGenerateSpecTE','-workers','1','-coverage','1','-metadir',tmp,'-config',name+'.cfg','Spec.tla'],cwd=root/'tla',capture_output=True,text=True,timeout=60)
 log=r.stdout+r.stderr;(root/'evidence'/(name+'.log')).write_text(log)
 assert r.returncode==(12 if violation else 0),log
 if violation:assert f'Invariant {violation} is violated' in log
 else:
  for action in ['Send','Take','Write']:
   m=re.search(rf'<{action} line [^\n]+>: (\d+):(\d+)',log);assert m and int(m[2])>0,action
 m=re.search(r'(\d+) states generated, (\d+) distinct states found',log)
 checks.append(dict(config=name,exit_code=r.returncode,violation=violation,states=int(m[2]) if m else None));print(checks[-1],flush=True)
(root/'evidence/model-results.json').write_text(json.dumps(dict(bounds='Byte window 4, chunks 1..2, total input at most 8; safety only, no fairness or state constraints.',checks=checks,properties_sha256=hashlib.sha256((root/'tla/Properties.tla').read_bytes()).hexdigest()),indent=2)+'\n')
