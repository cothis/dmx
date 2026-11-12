#!/usr/bin/env python3
"""Free 2 GiB, stop during free-page reporting, then reboot in the same daemon. Isolated data."""
import hashlib, json, os, subprocess, sys, tempfile, time
from pathlib import Path
binary=Path(sys.argv[1] if len(sys.argv)>1 else '.build/release/dmx').resolve()
guest=Path(os.environ.get('DMX_HOME',str(Path.home()/'.dmx')))/'guest'
rows=[]
with tempfile.TemporaryDirectory(prefix='dmx-life-',dir='/private/tmp') as directory:
 home=Path(directory)
 (home/'guest').symlink_to(guest)
 (home/'config.json').write_text(json.dumps(dict(cpus=2,memory='4G',shares=[],idle_timeout=300)))
 env=os.environ|{'DMX_HOME':directory}
 def run(*args):
  p=subprocess.run([str(binary),*args],env=env,capture_output=True,text=True,timeout=120)
  assert p.returncode==0,(args,p.returncode,p.stdout,p.stderr)
  return p.stdout
 def status():return json.loads(run('status','--json'))
 try:
  run('start')
  for delay in [1.5,2,2.5,3]:
   pid=status()['pid']
   run('exec','--','sh','-ec','mount -t tmpfs -o size=3G tmpfs /mnt; head -c 2147483648 /dev/zero >/mnt/blob; rm /mnt/blob; umount /mnt')
   time.sleep(delay)
   before=status()
   began=time.monotonic();run('stop');run('start')
   stop_start_s=round(time.monotonic()-began,3)
   after=status()
   assert after['pid']==pid,('successor escaped the original process',pid,after['pid'])
   result=run('exec','--','sh','-ec','head -c 67108864 /dev/urandom >/tmp/pattern; sha256sum /tmp/pattern >/tmp/pattern.sha; sleep 1; sha256sum -c /tmp/pattern.sha; rm /tmp/pattern /tmp/pattern.sha; dmesg')
   assert 'pattern: OK' in result,result[-2000:]
   assert not any(x in result for x in ['BUG:', 'Kernel panic', 'corrupted', 'Bad page state']),result[-2000:]
   rows.append(dict(offset_s=delay,same_process=True,stop_start_s=stop_start_s,reported_mb=(before.get('memory') or {}).get('reported_mb'),footprint_mb=after.get('host_footprint_mb'),pattern_ok=True))
  print(json.dumps(dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),cycles=rows,ok=True),indent=2))
 finally:
  subprocess.run([str(binary),'quit'],env=env,capture_output=True,timeout=30)
