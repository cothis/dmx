#!/usr/bin/env python3
"""Isolated stalled-exec, daemon lock race, first-boot termination, crash and host-ENOSPC probes."""
import argparse, contextlib, errno, fcntl, hashlib, json, os, signal, socket, struct, subprocess, tempfile, threading, time
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary',nargs='?',default='.build/release/dmx')
parser.add_argument('--only',choices=['exec','lock','boot','disk','unpack'])
a=parser.parse_args();binary=Path(a.binary).resolve()
source=Path(os.environ.get('DMX_HOME',str(Path.home()/'.dmx')))
guest=(source/'guest').resolve();checks=[]
def check(name,ok,detail=None):
 checks.append(dict(name=name,ok=bool(ok),detail=detail));print(json.dumps(checks[-1]),flush=True)
 assert ok,(name,detail)
@contextlib.contextmanager
def fixture(parent='/private/tmp'):
 with tempfile.TemporaryDirectory(prefix='dmx-rem-',dir=parent) as d:
  home=Path(d);(home/'guest').symlink_to(guest)
  (home/'config.json').write_text(json.dumps(dict(cpus=2,memory='2G',disk_size='1G',shares=[],idle_timeout=300)))
  env=os.environ|{'DMX_HOME':d}
  def run(*argv,timeout=60,check=True):
   p=subprocess.run([str(binary),*argv],env=env,capture_output=True,text=True,timeout=timeout)
   if check:assert p.returncode==0,(argv,p.returncode,p.stdout[-1000:],p.stderr[-1000:])
   return p
  try:yield home,env,run
  finally:
   try:
    with socket.socket(socket.AF_UNIX) as client:
     client.settimeout(70);client.connect(str(home/'dmx.sock'))
     body=json.dumps({'id':1,'method':'quit','params':{}}).encode()
     client.sendall(struct.pack('>I',len(body)+1)+b'\0'+body)
     while client.recv(65536):pass
   except (OSError,TimeoutError):pass
   # The socket closes slightly before process exit releases daemon.lock.
   with open(home/'daemon.lock','a') as lock:
    end=time.monotonic()+70
    while time.monotonic()<end:
     try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
     except BlockingIOError:time.sleep(.05)
    else:raise AssertionError('fixture daemon did not release its lock')
def status(run):return json.loads(run('status','--json').stdout)
def wait(predicate,seconds=5):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if predicate():return True
  time.sleep(.05)
 return False
if a.only in [None,'exec']:
 with fixture() as (home,env,run):
  run('start')
  for sig,label in [(signal.SIGKILL,'disconnect'),(signal.SIGINT,'sigint')]:
   marker='/tmp/stalled-'+label
   p=subprocess.Popen([str(binary),'exec','--','sh','-c',f'echo $$ >{marker}; exec sleep 24681'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   def feed():
    try:p.stdin.write(b'x'*(8<<20));p.stdin.flush()
    except (BrokenPipeError,OSError,ValueError):pass
   feeder=threading.Thread(target=feed,daemon=True);feeder.start();time.sleep(.5)
   began=time.monotonic();p.send_signal(sig)
   try:p.wait(timeout=2)
   except subprocess.TimeoutExpired:p.kill();p.wait();raise
   check('stalled_stdin_'+label+'_returns',True,dict(seconds=round(time.monotonic()-began,3),exit_code=p.returncode))
   gone=wait(lambda:run('exec','--','sh','-c',f'kill -0 $(cat {marker}) 2>/dev/null',check=False).returncode!=0,2)
   check('stalled_stdin_'+label+'_reaped',gone)
   if p.stdin:p.stdin.close()
   feeder.join(timeout=1)
  # Full-duplex input stays lossless across many credit windows and EOF.
  data=os.urandom(8<<20)
  p=subprocess.run([str(binary),'exec','--','sha256sum'],input=data,env=env,capture_output=True,timeout=30)
  check('credit_stream_sha256',p.returncode==0 and bool(p.stdout.split()) and p.stdout.split()[0].decode()==hashlib.sha256(data).hexdigest(),dict(code=p.returncode,stdout=p.stdout.decode(errors='replace'),stderr=p.stderr.decode(errors='replace'),expected=hashlib.sha256(data).hexdigest()))
if a.only in [None,'lock']:
 with fixture() as (home,env,run):
  lock=open(home/'daemon.lock','w');fcntl.flock(lock,fcntl.LOCK_EX)
  release=threading.Thread(target=lambda:(time.sleep(1),fcntl.flock(lock,fcntl.LOCK_UN)),daemon=True);release.start()
  start=time.monotonic();p=run('start',check=False,timeout=20);elapsed=time.monotonic()-start
  release.join();lock.close()
  check('lost_spawn_lock_race_retries',p.returncode==0 and elapsed<3,dict(seconds=round(elapsed,3),stderr=p.stderr))
if a.only in [None,'boot']:
 with fixture() as (home,env,run):
  daemon=subprocess.Popen([str(binary),'daemon'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  check('first_boot_daemon_listens',wait(lambda:(home/'dmx.sock').exists()))
  start=subprocess.Popen([str(binary),'start'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  check('first_boot_disk_created',wait(lambda:(home/'data.img').exists()))
  began=time.monotonic();daemon.send_signal(signal.SIGTERM)
  daemon.wait(timeout=70);start.communicate(timeout=5)
  check('sigterm_during_first_boot_bounded',time.monotonic()-began<66,dict(seconds=round(time.monotonic()-began,3),exit_code=daemon.returncode))
  run('start');p=run('exec','--','sh','-ec','echo recovered >/var/lib/first-boot; sync; cat /var/lib/first-boot')
  check('disk_usable_after_first_boot_sigterm',p.stdout.strip()=='recovered')
if a.only in [None,'disk']:
 with tempfile.TemporaryDirectory(prefix='dmx-space-',dir='/private/tmp') as temp:
  root=Path(temp);image=root/'limited.dmg';mount=root/'mnt';mount.mkdir()
  subprocess.run(['hdiutil','create','-size','256m','-fs','APFS','-volname','dmx-space-test',str(image)],check=True,capture_output=True)
  attached=False
  try:
   subprocess.run(['hdiutil','attach','-nobrowse','-mountpoint',str(mount),str(image)],check=True,capture_output=True);attached=True
   with fixture(str(mount)) as (home,env,run):
    run('start')
    filler=mount/'filler'
    with filler.open('wb',buffering=0) as file:
     block=b'x'*(1<<20)
     while True:
      try:file.write(block)
      except OSError as e:
       if e.errno!=errno.ENOSPC:raise
       break
    # Do not let diagnostic writes consume the recovered space: the journal and writes wait.
    writer=subprocess.Popen([str(binary),'exec','--','sh','-ec','dd if=/dev/urandom of=/var/lib/enospc-probe bs=1M count=32 2>/dev/null; sync; sha256sum /var/lib/enospc-probe'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    observed=None
    def blocked():
     global observed
     observed=status(run)
     return (observed.get('disk_error') or {}).get('code')=='disk_full'
    found=wait(blocked,10)
    if not found:
     observed={'status':observed,'writer_exit':writer.poll(),'guest_dmesg':run('exec','--','dmesg',check=False).stdout[-3000:]}
    check('enospc_is_reported_as_waiting',found,observed)
    check('enospc_request_still_pending',writer.poll() is None)
    filler.unlink();output,errors=writer.communicate(timeout=20)
    check('enospc_write_resumes',writer.returncode==0 and len(output.split()[0])==64,errors.decode(errors='replace'))
    check('enospc_status_clears',wait(lambda:not status(run).get('disk_error'),5))
    messages=run('exec','--','dmesg').stdout
    check('enospc_does_not_abort_guest_journal',not any(x in messages for x in ['Aborting journal','I/O error','Remounting filesystem read-only']))
  finally:
   if attached:subprocess.run(['hdiutil','detach',str(mount)],check=True,capture_output=True)
if a.only in [None,'unpack']:
 with fixture() as (home,env,run):
  run('start')
  # Pin a daemon open so cleanup can safely recognize its exact PID, then crash unpack offsets.
  for delay in [.02,.08,.2]:
   run('exec','--','sh','-ec','rm -rf /var/lib/dmx/docker /var/lib/dmx/docker.new; sync')
   pid=status(run)['pid']
   request=subprocess.Popen([str(binary),'exec','--','sh','-c','/sbin/dmx-docker'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   time.sleep(delay);os.kill(pid,signal.SIGKILL);request.communicate(timeout=10)
   # The OS releases daemon.lock on exit; the next CLI must survive that handover too.
   run('start')
   # Start Docker through its real API proxy; no external images are needed.
   with socket.socket(socket.AF_UNIX) as client:
    client.settimeout(60);client.connect(str(home/'docker.sock'));client.sendall(b'GET /_ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n')
    response=b''
    while True:
     chunk=client.recv(65536)
     if not chunk:break
     response+=chunk
   check('docker_recovers_after_unpack_crash_'+str(delay),b'200 OK' in response and response.endswith(b'OK'),response[-100:].decode(errors='replace'))
  marker=run('exec','--','cat','/var/lib/dmx/docker/.version').stdout
  x86=run('exec','--','cat','/var/lib/dmx/x86/sha256').stdout
  check('durable_markers_published','durable-v1' in marker and 'durable-v1' in x86)
print(json.dumps(dict(ok=True,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),checks=checks),indent=2))
