#!/usr/bin/env python3
"""A gated real syscall probe must reject using the reusable integer instead of its copy."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=ROOT/'.build/fixes-0.3.12/raw-binding');out=p.parse_args().out.resolve()
assert not out.exists(), 'Use a fresh evidence directory'
pkg=out/'package';(pkg/'Sources/DMXCore').mkdir(parents=True);(pkg/'Tests/DMXCoreTests').mkdir(parents=True)
(pkg/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BindingMutation", platforms: [.macOS(.v15)], targets: [.target(name: "DMXCore"), .testTarget(name: "DMXCoreTests", dependencies: ["DMXCore"])])
''')
for source in (ROOT/'Sources/DMXCore').rglob('*.swift'):
 target=pkg/'Sources/DMXCore'/source.relative_to(ROOT/'Sources/DMXCore');target.parent.mkdir(parents=True,exist_ok=True)
 if source.name=='Agent.swift':
  text=source.read_text();needle='return try body(copy)';assert text.count(needle)==1
  target.write_text(text.replace(needle,'return try body(fd)',1))
 else:target.symlink_to(source)
(pkg/'Tests/DMXCoreTests/FrameConnectionTests.swift').symlink_to(ROOT/'Tests/DMXCoreTests/FrameConnectionTests.swift')
r=subprocess.run(['swift','test','--package-path',str(pkg),'--filter','FrameConnectionTests'],capture_output=True,text=True,timeout=300)
(out/'unit-tests.log').write_text(r.stdout+r.stderr)
assert r.returncode!=0 and 'read must use the acquired binding' in r.stdout+r.stderr and 'write must use the acquired binding' in r.stdout+r.stderr,(r.returncode,(r.stdout+r.stderr)[-4000:])
module=pkg/'.build/out/Products/Debug'
for name,cmd in [('compile',['swiftc','-parse-as-library','-target','arm64-apple-macos15.0','-I',module,ROOT/'formal/frame-connection-lifetime/repro/IsolatedFDProbe.swift',module/'DMXCore.o','-framework','Hypervisor','-framework','Security','-o',out/'probe']),('gate',['clang','-dynamiclib',ROOT/'formal/frame-connection-lifetime/repro/gate-poll.c','-o',out/'gate.dylib'])]:
 r=subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=60);(out/(name+'.log')).write_text(r.stdout+r.stderr);assert r.returncode==0,(name,r.stderr)
r=subprocess.run([str(out/'probe'),'gated'],env={**os.environ,'DYLD_INSERT_LIBRARIES':str(out/'gate.dylib')},capture_output=True,text=True,timeout=15)
log=r.stdout+r.stderr;(out/'gated-probe.log').write_text(log)
assert r.returncode!=0 and 'cannot splice a frame from two sockets' in log,(r.returncode,log)
(out/'result.json').write_text(json.dumps({'ok':True,'mutation':'body(fd) instead of body(copy)','unit_tests_reject_binding_mutation':True,'probe_exit_code':r.returncode,'expected_assertion':'cannot splice a frame from two sockets'},indent=2)+'\n')
print('Raw-binding mutation is rejected by both the acquired-binding unit test and the gated child probe.')
