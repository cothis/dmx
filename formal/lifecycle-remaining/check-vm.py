#!/usr/bin/env python3
"""Entitled tests plus a child process that must fail-stop on an uninterruptible share."""
import json,os,subprocess,tempfile,time
from pathlib import Path
root=Path(__file__).resolve().parents[2];here=Path(__file__).resolve().parent
out=here/'evidence';build=root/'.build/lifecycle-remaining';build.mkdir(parents=True,exist_ok=True)
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
platform=developer/'Platforms/MacOSX.platform/Developer';frameworks=platform/'Library/Frameworks'
subprocess.run(['swift','test','--filter','RemainingLifecycleTests'],cwd=root,check=True,stdout=(out/'vm-build.log').open('w'),stderr=subprocess.STDOUT)
subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'formal/vm-device-lifetime/repro/Runner.swift'),'-F',str(frameworks),'-framework','Testing','-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(build/'runner')],cwd=root,check=True)
subprocess.run(['codesign','--force','--sign','-','--entitlements','dmx.entitlements',str(build/'runner')],cwd=root,check=True)
env=os.environ|{'DMX_MACHINE_VM':'1','DMX_TEST_BUNDLE':str(root/'.build/debug/DMXCoreTests.xctest/Contents/MacOS/DMXCoreTests'),'DYLD_LIBRARY_PATH':str(platform/'usr/lib')}
logs=[]
for pattern in ['MachineLifecycleTests','RemainingLifecycleVMTests']:
 r=subprocess.run([str(build/'runner'),'--filter',pattern],env=env,cwd=root,capture_output=True,text=True,timeout=30)
 logs.append(r.stdout+r.stderr)
 assert r.returncode==0,r.stdout+r.stderr
(out/'vm-after.log').write_text('\n'.join(logs))
assert 'preRunExitIsLatched() passed' in logs[-1],logs[-1]
with tempfile.TemporaryDirectory(prefix='dmx-stuck-',dir='/private/tmp') as home:
 Path(home,'block').write_text('fixture')
 started=time.monotonic()
 r=subprocess.run([str(build/'runner'),'--filter','StuckShareLifecycleTests'],cwd=root,env=env|{'DMX_STUCK_SHARE_VM':'1','DMX_STUCK_SHARE_PATH':home},capture_output=True,text=True,timeout=5)
 elapsed=time.monotonic()-started
 (out/'stuck-share-after.log').write_text(r.stdout+r.stderr)
 assert r.returncode==70 and 'shutdown_timeout' in r.stdout+r.stderr,(r.returncode,r.stdout,r.stderr)
(out/'vm-results.json').write_text(json.dumps(dict(hypervisor_tests=5,pre_run_exit_latched=True,stuck_share_exit_code=r.returncode,stuck_share_exit_s=round(elapsed,3),injected_teardown_deadline_s=.5),indent=2)+'\n')
print((out/'vm-results.json').read_text())
