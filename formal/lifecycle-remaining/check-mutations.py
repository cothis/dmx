#!/usr/bin/env python3
"""Temporarily remove independent repairs and require property assertion failures. Restores sources."""
import json,subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=Path(__file__).resolve().parent/'evidence'
variants=[
 ('shutdown-shared','Sources/DMXCore/Agent.swift','shutdownBypassesBusyControl','let _: Empty = try await urgent("shutdown", Empty())','let _: Empty = try await call("shutdown", Empty())'),
 ('listing-no-retry','Sources/DMXCore/Daemon/Docker.swift','failedContainerListingRetriesAndOldEpochStops','''                    syncAgain = true
                } else { failures = 0 }''','''                    syncAgain = false
                } else { failures = 0 }'''),
 ('accept-no-backoff','Sources/DMXCore/Daemon/Docker.swift','dockerEMFILEBacksOff','if errno == EMFILE || errno == ENFILE, let source {','if false, let source {'),
 ('half-close-no-expiry','Sources/DMXCore/HV/UserNetTCP.swift','halfClosedFlowExpiresAndLiveIdleFlowStays','if let at = flow.halfClosedAt, now - at >= Self.halfCloseTimeout {','if let at = flow.halfClosedAt, false && now - at >= Self.halfCloseTimeout {'),
 ('udp-blocking-write','Sources/DMXCore/Daemon/UDPForward.swift','unreadGuestCannotBlockCountsOrClose','_ = fcntl(connection.fd, F_SETFL, fcntl(connection.fd, F_GETFL) | O_NONBLOCK)','// Mutant: blocking stream on the relay queue'),
]
results=[]
for name,file,test,old,new in variants:
 p=root/file;original=p.read_text();assert old in original,name
 try:
  p.write_text(original.replace(old,new))
  r=subprocess.run(['swift','test','--filter',test],cwd=root,capture_output=True,text=True,timeout=120)
  log=r.stdout+r.stderr;(out/(name+'.log')).write_text(log)
  assert r.returncode!=0 and 'recorded an issue' in log and 'error: SwiftCompile' not in log,log[-3000:]
  results.append(dict(name=name,exit_code=r.returncode,assertion_failed=True));print(results[-1],flush=True)
 finally:p.write_text(original)
r=subprocess.run(['swift','test'],cwd=root,capture_output=True,text=True,timeout=120)
(out/'unit-after.log').write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout+r.stderr
(out/'mutation-results.json').write_text(json.dumps(results,indent=2)+'\n')
