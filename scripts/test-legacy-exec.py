#!/usr/bin/env python3
"""New host + previous guest: bounded input, clear upgrade error, and responsive cancellation."""
import argparse,contextlib,fcntl,hashlib,http.server,json,os,shutil,signal,socket,struct,subprocess,tempfile,threading,time
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary');p.add_argument('guest');p.add_argument('--require-fallback',action='store_true');args=p.parse_args()
binary=Path(args.binary).resolve();old=Path(args.guest).resolve();checks=[]
def check(name,ok,detail=None):
 checks.append(dict(name=name,ok=bool(ok),detail=detail));print(json.dumps(checks[-1]),flush=True);assert ok,(name,detail)
class Offline(http.server.BaseHTTPRequestHandler):
 def do_GET(self):self.server.hits+=1;self.send_error(404)
 def log_message(self,*args):pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Offline);server.hits=0
threading.Thread(target=server.serve_forever,daemon=True).start()
with tempfile.TemporaryDirectory(prefix='dmx-legacy-',dir='/private/tmp') as directory:
 home=Path(directory);shutil.copytree(old,home/'guest',copy_function=shutil.copy2)
 (home/'config.json').write_text('{"cpus":2,"memory":"1G","disk_size":"1G","shares":[],"idle_timeout":300}')
 env=os.environ|{'DMX_HOME':directory,'DMX_RELEASE_URL':f'http://127.0.0.1:{server.server_port}'}
 def run(*argv,stdin=None,timeout=20):return subprocess.run([str(binary),*argv],env=env,input=stdin,capture_output=True,timeout=timeout)
 def gone(marker):
  return run('exec','--','sh','-c',f'kill -0 $(cat {marker}) 2>/dev/null').returncode!=0
 try:
  r=run('start','--json');check('legacy_boots',r.returncode==0,r.stderr.decode(errors='replace')[-300:])
  if args.require_fallback:check('failed_download_retains_previous_guest',server.hits>0,server.hits)
  r=run('exec','--','cat',stdin=b'small input\n');check('legacy_small_stdin_works',r.returncode==0 and r.stdout==b'small input\n',r.stderr.decode(errors='replace'))
  for name,large in [('bulk',True),('sigint',False)]:
   marker='/tmp/legacy-'+name
   child=subprocess.Popen([str(binary),'exec','--','sh','-c',f'echo $$ >{marker}; exec sleep 24681'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   try:
    end=time.monotonic()+5
    while time.monotonic()<end and run('exec','--','test','-f',marker).returncode!=0:time.sleep(.02)
    check('legacy_'+name+'_started',run('exec','--','test','-f',marker).returncode==0)
    def feed():
     try:child.stdin.write(b'x'*((1<<20) if large else 4096));child.stdin.flush()
     except (OSError,ValueError):pass
    writer=threading.Thread(target=feed,daemon=True);writer.start()
    if not large:time.sleep(.1);child.send_signal(signal.SIGINT)
    start=time.monotonic();child.wait(timeout=2);writer.join(timeout=1)
    if child.stdin:child.stdin.close();child.stdin=None
    out,err=child.communicate(timeout=2)
    if large:check('legacy_bulk_fails_with_upgrade_hint',child.returncode!=0 and b'byte credit' in err and b'guest fetch --force' in err,dict(code=child.returncode,stderr=err.decode(errors='replace')))
    else:check('legacy_sigint_returns',child.returncode==130 and time.monotonic()-start<2,dict(code=child.returncode,seconds=round(time.monotonic()-start,3)))
    check('legacy_'+name+'_reaped',gone(marker))
   finally:
    if child.poll() is None:child.kill();child.wait()
 finally:
  try:
   with socket.socket(socket.AF_UNIX) as client:
    client.settimeout(55);client.connect(str(home/'dmx.sock'))
    body=json.dumps(dict(id=1,method='quit',params={})).encode();client.sendall(struct.pack('>I',len(body)+1)+b'\0'+body)
    while client.recv(65536):pass
  except OSError:pass
  with open(home/'daemon.lock','a') as lock:
   end=time.monotonic()+55
   while True:
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
    except BlockingIOError:
     if time.monotonic()>end:raise RuntimeError('legacy fixture daemon did not exit')
     time.sleep(.05)
server.shutdown();server.server_close()
print(json.dumps(dict(ok=True,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),checks=checks),indent=2))
