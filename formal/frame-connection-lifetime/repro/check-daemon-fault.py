#!/usr/bin/env python3
"""Actual unsigned candidate daemon: accepted socket's reply dup fails, without booting a VM."""
import argparse,json,os,socket,struct,subprocess,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,default=ROOT/'.build/release/dmx');p.add_argument('--out',type=Path,required=True);p.add_argument('--expect',choices=['closed','stalled'],default='closed');args=p.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
lib=out/'daemon-emfile.dylib'
r=subprocess.run(['clang','-dynamiclib',str(ROOT/'formal/frame-connection-lifetime/repro/daemon-emfile.c'),'-o',str(lib)],capture_output=True,text=True);assert r.returncode==0,r.stderr
with tempfile.TemporaryDirectory(prefix='dmx-daemon-fault-',dir='/tmp') as home:
 env={**os.environ,'DMX_HOME':home,'DYLD_INSERT_LIBRARIES':str(lib)}
 with (out/'daemon.log').open('w') as log:
  proc=subprocess.Popen([str(args.binary.resolve()),'daemon'],env=env,stdout=log,stderr=log)
  try:
   path=Path(home)/'dmx.sock';until=time.monotonic()+5
   while not path.exists() and time.monotonic()<until:
    assert proc.poll() is None,'daemon exited';time.sleep(.01)
   with socket.socket(socket.AF_UNIX) as peer:
    peer.settimeout(1);peer.connect(str(path))
    payload=b'\0'+json.dumps({'id':1,'method':'status','params':{}}).encode();peer.sendall(struct.pack('>I',len(payload))+payload)
    try:
     data=peer.recv(1);observed='closed' if data==b'' else 'unexpected response'
    except TimeoutError:observed='stalled'
  finally:
   proc.terminate()
   try:proc.wait(timeout=10)
   except subprocess.TimeoutExpired:proc.kill();proc.wait();raise
 log=(out/'daemon.log').read_text();assert 'daemon reply dup returns EMFILE' in log,'fault was not reached'
 result={'expected':args.expect,'observed':observed,'ok':observed==args.expect,'binary_sha256':__import__('hashlib').sha256(args.binary.read_bytes()).hexdigest(),'fault':'accepted connection second/third dup fail EMFILE; actual candidate daemon; no VM'}
 (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result));assert result['ok']
