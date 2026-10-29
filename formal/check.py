#!/usr/bin/env python3
"""Run scoped safety models and independent sensitivity checks; preserve old evidence."""
import argparse, hashlib, json, os, re, subprocess, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=Path, default=ROOT/'evidence/v0.3.12')
out=parser.parse_args().out.resolve();out.mkdir(parents=True,exist_ok=True)
jar=Path(os.environ.get('TLA2TOOLS',Path.home()/'.cache/proof-skills/tla2tools.jar')).expanduser().resolve()
assert jar.is_file(), 'Set TLA2TOOLS to a local TLA+ tools jar'
java=['java','-XX:+UseParallelGC','-cp',str(jar)]
suites={
 'frame-connection-lifetime':[
  ('MC',None),('MC_bug','NoForeignIO'),('MC_guard','NoLateAcquire'),('MC_guard_harm','NoForeignIO'),('MC_atomic','NoForeignIO'),('MC_early','NoForeignIO'),
  ('MC_sanity','NeverCompletes'),('MC_reuse','NeverReuses')],
 'rpc-reply-alignment':[
  ('MC',None),('MC_old','NoMismatchedReply'),('MC_id','NoMismatchedReply'),('MC_retire','NoUncertainReuse'),('MC_replay','NoReplay'),
  ('MC_sanity','NeverCompletes'),('MC_failure','NeverFailsBeforeSend')]
}
inputs={str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for concern in suites for p in (ROOT/concern/'tla').iterdir() if p.suffix in {'.tla','.cfg'}}
for rel in ['Sources/DMXCore/Agent.swift','Tests/DMXCoreTests/FrameConnectionTests.swift','Sources/DMXCore/GuestStore.swift','Tests/DMXCoreTests/GuestStoreTests.swift']:
 inputs[rel]=hashlib.sha256((ROOT.parent/rel).read_bytes()).hexdigest()
results=[]
for concern,checks in suites.items():
 here=ROOT/concern
 expected=('fdd9f25b97cc13fa66ea4ab44b27d4d21606bfe5a50a0bd786251865a1665554' if concern.startswith('frame-') else (here/'properties.sha256').read_text().split()[0])
 actual=hashlib.sha256((here/'tla/Properties.tla').read_bytes()).hexdigest()
 assert actual==expected, 'Frozen properties changed: '+concern
 for config,invariant in checks:
  folder=out/concern/config;folder.mkdir(parents=True,exist_ok=True)
  with tempfile.TemporaryDirectory(prefix='dmx-tlc-') as states:
   r=subprocess.run(java+['tlc2.TLC','-noGenerateSpecTE','-workers','1','-coverage','1','-config',config+'.cfg','-metadir',states,'Spec.tla'],cwd=here/'tla',capture_output=True,text=True,timeout=120)
  log=r.stdout+r.stderr;(folder/'tlc.log').write_text(log)
  assert r.returncode==(12 if invariant else 0),(concern,config,r.returncode,log[-5000:])
  if invariant:assert f'Invariant {invariant} is violated' in log,(config,log)
  else:
   actions=(['Submit','Acquire','Transfer','Finish','Close','Reuse','Terminated'] if concern.startswith('frame-') else ['Acquire','FailBeforeSend','Send','PoisonReply','Receive','NextCall','Reconnect','Terminated'])
   for action in actions:
    match=re.search(rf'<{action} line [^\n]+>: (\d+):(\d+)',log)
    assert match and int(match[2])>0, 'No coverage: '+action
  stats=re.search(r'(\d+) states generated, (\d+) distinct states found[^\n]*',log)
  depth=re.search(r'depth of the complete state graph search is (\d+)',log)
  row={'concern':concern,'config':config,'exit_code':r.returncode,'expected_violation':invariant,'properties_sha256':actual,'generated':int(stats[1]) if stats else None,'distinct':int(stats[2]) if stats else None,'depth':int(depth[1]) if depth else None}
  results.append(row);print(json.dumps(row),flush=True)
assert all(hashlib.sha256((ROOT.parent/rel).read_bytes()).hexdigest()==sha for rel,sha in inputs.items()), 'Inputs changed during checking'
(out/'results.json').write_text(json.dumps({'input_sha256':inputs,'bounds':'FD: two operations, two transfers each, one close/reuse. RPC: two calls, one duplication failure, one malformed response, reconnect. Safety only, no fairness or state constraints.','jar_sha256':hashlib.sha256(jar.read_bytes()).hexdigest(),'checks':results},indent=2)+'\n')
