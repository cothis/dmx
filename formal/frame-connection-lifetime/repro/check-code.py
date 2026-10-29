#!/usr/bin/env python3
"""Real Core probes in children; destructive FD reuse never runs in the shared unit process."""
import argparse, json, os, subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=ROOT/'.build/fixes-0.3.12/code-probes');args=p.parse_args()
out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
module=ROOT/'.build/out/Products/Debug'
def run(name,cmd,env=None):
 r=subprocess.run(list(map(str,cmd)),env=env,capture_output=True,text=True,timeout=120)
 (out/(name+'.log')).write_text(r.stdout+r.stderr)
 assert r.returncode==0,(name,r.returncode,r.stdout,r.stderr)
 print(name+': passed',flush=True)
run('build-current-core',['swift','build','--package-path',ROOT])
run('compile-isolated',['swiftc','-parse-as-library','-target','arm64-apple-macos15.0','-I',module,ROOT/'formal/frame-connection-lifetime/repro/IsolatedFDProbe.swift',module/'DMXCore.o','-framework','Hypervisor','-framework','Security','-o',out/'fd-probe'])
for mode in ['read','write','midframe']:run(mode,[out/'fd-probe',mode])
run('compile-poll-gate',['clang','-dynamiclib',ROOT/'formal/frame-connection-lifetime/repro/gate-poll.c','-o',out/'gate.dylib'])
run('gated-midframe',[out/'fd-probe','gated'],{**os.environ,'DYLD_INSERT_LIBRARIES':str(out/'gate.dylib')})
# The equal-archive counterexample uses the original review fixture unmodified.
run('compile-review',['swiftc','-parse-as-library','-target','arm64-apple-macos15.0','-I',module,ROOT/'formal/frame-connection-lifetime/repro/opus55/ReviewReproduction.swift',module/'DMXCore.o','-framework','Hypervisor','-framework','Security','-o',out/'review-probe'])
run('equal-archive',[out/'review-probe','equal-archive'])
run('compile-rpc-fault',['swiftc','-parse-as-library','-target','arm64-apple-macos15.0','-I',module,ROOT/'formal/frame-connection-lifetime/repro/RPCFaultProbe.swift',module/'DMXCore.o','-framework','Hypervisor','-framework','Security','-o',out/'rpc-fault'])
run('compile-interposer',['clang','-dynamiclib',ROOT/'formal/frame-connection-lifetime/repro/opus55/emfile-inject.c','-o',out/'emfile.dylib'])
run('rpc-real-emfile',[out/'rpc-fault'],{**os.environ,'DYLD_INSERT_LIBRARIES':str(out/'emfile.dylib')})
(out/'result.json').write_text(json.dumps({'ok':True,'checks':['isolated read','isolated write','isolated midframe','gated midframe','same archive receipt','real fcntl EMFILE']},indent=2)+'\n')
