#!/usr/bin/env python3
"""Run entitled VM lifecycle regressions; --mutations demonstrates each regression fails."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[3]
concern=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--mutations',action='store_true')
args=parser.parse_args()
out=concern/'evidence'
build=root/'.build/lifecycle';build.mkdir(parents=True,exist_ok=True)
developer=Path(subprocess.check_output(['xcode-select','-p'],text=True).strip())
platform=developer/'Platforms/MacOSX.platform/Developer'
frameworks=platform/'Library/Frameworks'
subprocess.run(['xcrun','swiftc','-parse-as-library',str(concern/'repro/Runner.swift'),'-F',str(frameworks),'-framework','Testing','-Xlinker','-rpath','-Xlinker',str(frameworks),'-o',str(build/'runner')],cwd=root,check=True)
subprocess.run(['codesign','--force','--sign','-','--entitlements','dmx.entitlements',str(build/'runner')],cwd=root,check=True)
env=os.environ|{'DMX_MACHINE_VM':'1','DMX_TEST_BUNDLE':str(root/'.build/debug/DMXCoreTests.xctest/Contents/MacOS/DMXCoreTests'),'DYLD_LIBRARY_PATH':str(platform/'usr/lib')}

def run(name,pattern,expected):
 compile=subprocess.run(['swift','test','--filter','DeviceStopTests'],cwd=root,capture_output=True,text=True,timeout=180)
 (out/(name+'-build.log')).write_text(compile.stdout+compile.stderr)
 assert compile.returncode==0,compile.stdout+compile.stderr
 result=subprocess.run([str(build/'runner'),'--filter',pattern],cwd=root,env=env,capture_output=True,text=True,timeout=30)
 log=result.stdout+result.stderr;(out/(name+'.log')).write_text(log)
 assert (result.returncode==0)==expected,log
 assert ('4 tests' in log and 'passed' in log) if expected else ('recorded an issue' in log),log
 print(name, 'passed' if expected else 'failed as required',flush=True)
 return dict(name=name,exit_code=result.returncode,expected_success=expected)

results=[]
if not args.mutations and (out/'code-results.json').exists():
 results=[r for r in json.loads((out/'code-results.json').read_text()) if not r['expected_success']]
if args.mutations:
 machine=root/'Sources/DMXCore/HV/Machine.swift'
 memory=root/'Sources/DMXCore/Daemon/MemoryController.swift'
 mutations=[
  ('missing-alive-guard',machine,'staleReleaseCannotReplaceSuccessorRAM',lambda s:s.replace('''            guard vmAlive else { return }
            hv_vm_unmap(start''','''            hv_vm_unmap(start''')),
  ('missing-init-cleanup',machine,'partialInitReleasesVM',lambda s:s.replace('''                hv_vm_destroy()
                munmap(memory, reservedSize)''','''                _ = reservedSize''')),
  ('missing-start-cleanup',machine,'failedStartReleasesVCPUsAndVM',lambda s:s.replace('''            stop(.failed(error as? DMXError ?? DMXError("vm_error", "\\(error)")))
            // Callers may immediately try another Machine after a failed start.
            teardown.wait()''','''            // Mutant: failed start leaves its parked vCPUs and VM alive.''')),
  ('missing-tick-guard',memory,'detachedTickDoesNotSetNextSwapFlag',lambda s:s.replace('''                guard active(agent) else { return }
                swapOn = true''','''                swapOn = true''')),
 ]
 for name,path,pattern,mutate in mutations:
  original=path.read_text();changed=mutate(original);assert changed!=original,name
  try:
   path.write_text(changed)
   results.append(run(name,pattern,False))
  finally:path.write_text(original)
results.append(run('machine-after','MachineLifecycleTests',True))
(out/'code-results.json').write_text(json.dumps(results,indent=2)+'\n')
