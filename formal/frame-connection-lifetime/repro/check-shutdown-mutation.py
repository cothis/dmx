#!/usr/bin/env python3
"""The improved wakeup tests must fail without shutdown, before peer teardown."""
import argparse,json,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=ROOT/'.build/fixes-0.3.12/no-shutdown');out=p.parse_args().out.resolve()
assert not out.exists(), 'Use a fresh evidence directory'
pkg=out/'package';(pkg/'Sources/DMXCore').mkdir(parents=True);(pkg/'Tests/DMXCoreTests').mkdir(parents=True)
(pkg/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Sensitivity", platforms: [.macOS(.v15)], targets: [.target(name: "DMXCore"), .testTarget(name: "DMXCoreTests", dependencies: ["DMXCore"])])
''')
for source in (ROOT/'Sources/DMXCore').rglob('*.swift'):
 target=pkg/'Sources/DMXCore'/source.relative_to(ROOT/'Sources/DMXCore');target.parent.mkdir(parents=True,exist_ok=True)
 if source.name=='Agent.swift':
  text=source.read_text();needle='        Darwin.shutdown(fd, SHUT_RDWR)\n';assert text.count(needle)==1
  target.write_text(text.replace(needle,'',1))
 else:target.symlink_to(source)
(pkg/'Tests/DMXCoreTests/FrameConnectionTests.swift').symlink_to(ROOT/'Tests/DMXCoreTests/FrameConnectionTests.swift')
r=subprocess.run(['swift','test','--package-path',str(pkg),'--filter','FrameConnectionTests'],capture_output=True,text=True,timeout=300)
log=r.stdout+r.stderr;(out/'test.log').write_text(log)
assert r.returncode!=0 and 'close alone must end I/O' in log and 'abort alone must end the leased write' in log,log[-8000:]
(out/'result.json').write_text(json.dumps({'ok':True,'mutation':'remove only close shutdown','exit_code':r.returncode,'expected_assertions':['close alone must end I/O','abort alone must end the leased write']},indent=2)+'\n')
print('Shutdown removal rejected by both direct wakeup assertions (no peer teardown before assertions).')
