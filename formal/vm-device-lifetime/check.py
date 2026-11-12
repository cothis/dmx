#!/usr/bin/env python3
"""Check device teardown safety and independently remove each defense."""
import hashlib, json, os, re, subprocess, tempfile
from pathlib import Path
root=Path(__file__).resolve().parent
jar=Path(os.environ.get('TLA2TOOLS',Path.home()/'.cache/proof-skills/tla2tools.jar'))
assert hashlib.sha256((root/'tla/Properties.tla').read_bytes()).hexdigest()==(root/'properties.sha256').read_text().strip(), 'Frozen properties changed'
results=[]
for config,violation in [('MC',None),('MC_old','NoFreedRAM'),('MC_drain','NoFreedRAM'),('MC_guard','NoForeignHV'),('MC_sanity','NeverCompletes')]:
 with tempfile.TemporaryDirectory(prefix='dmx-lifecycle-tlc-') as tmp:
  run=subprocess.run(['java','-cp',str(jar),'tlc2.TLC','-noGenerateSpecTE','-workers','1','-coverage','1','-config',config+'.cfg','-metadir',tmp,'Spec.tla'],cwd=root/'tla',capture_output=True,text=True,timeout=60)
 log=run.stdout+run.stderr
 (root/'evidence'/f'{config}.log').write_text(log)
 assert run.returncode==(12 if violation else 0),log
 if violation: assert f'Invariant {violation} is violated' in log,log
 else:
  for action in ['Begin','Finish','Stop','Destroy','Reboot','External','Complete','Terminated']:
   match=re.search(rf'<{action} line [^\n]+>: (\d+):(\d+)',log)
   assert match and int(match[2])>0,action
 stats=re.search(r'(\d+) states generated, (\d+) distinct states found',log)
 results.append(dict(config=config,expected_violation=violation,exit_code=run.returncode,states=int(stats[2]) if stats else None))
 print(results[-1],flush=True)
(root/'evidence/results.json').write_text(json.dumps(dict(bounds='One queued callback with begin/finish, one stale external callback, one stop and successor VM; safety only, no fairness or state constraints.',checks=results,properties_sha256=hashlib.sha256((root/'tla/Properties.tla').read_bytes()).hexdigest()),indent=2)+'\n')
