import hashlib,json,os,shutil,socket,struct,subprocess,tarfile,tempfile,time
from pathlib import Path
ROOT=Path.cwd(); OUT=ROOT/'.build/menu-release-review'; DOWNLOAD=OUT/'public-v0.4.0'; DIST=ROOT/'.build/dist/v0.4.0'
work=Path(tempfile.mkdtemp(prefix='dmx-public-',dir='/tmp')); reports=[]; homes=[]; completed=False
def save(): (OUT/'public-verification.json').write_text(json.dumps({'ok':completed and all(x['ok'] for x in reports),'work':str(work),'checks':reports},indent=2))
def check(name,ok,detail=None):
 reports.append({'name':name,'ok':bool(ok),'detail':detail});save()
 if not ok:raise AssertionError(name+': '+str(detail))
def run(args,env=None,timeout=180):
 p=subprocess.run(list(map(str,args)),env=env,capture_output=True,timeout=timeout)
 if p.returncode:raise AssertionError((list(map(str,args)),p.returncode,p.stdout.decode(errors='replace'),p.stderr.decode(errors='replace')))
 return p.stdout

def data(args,env=None,timeout=180):return json.loads(run(args,env,timeout))
def signature(app):
 for cmd in [['codesign','--verify','--deep','--strict','--check-notarization',app],['xcrun','stapler','validate',app],['spctl','--assess','--type','execute',app]]:run(cmd,timeout=60)
def sha(path):
 with path.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def install(area,cached_tools=None):
 home=area/'home';home.mkdir(parents=True,exist_ok=True);homes.append(home)
 if cached_tools:
  for name in ['bin','cli-plugins']:(home/name).symlink_to(cached_tools/name)
 env={**os.environ,'DMX_HOME':str(home),'DOCKER_CONFIG':str(area/'docker'),'PREFIX':str(area/'prefix'),'DMX_APP_DIR':str(area/'Applications/dmx.app')}
 for name in ['DMX_RELEASE_URL','DMX_TOOLS_URL','DMX_VERSION']:env.pop(name,None)
 (home/'config.json').write_text(json.dumps({'cpus':2,'memory':'2G','shares':[],'idle_timeout':600}))
 output=run(['sh',DOWNLOAD/'install.sh'],env,timeout=600);(area/'install.log').write_bytes(output)
 cli=area/'prefix/bin/dmx';app=area/'Applications/dmx.app'
 signature(app);check(area.name+'_one_installer',cli.is_symlink() and cli.resolve()==(app/'Contents/MacOS/dmx').resolve() and not(home/'dmx.sock').exists())
 return home,env,cli,app

def docker(cli,home,env,*args):return run([cli.parent/'docker' if (cli.parent/'docker').exists() else home/'bin/docker',*args],{**env,'DOCKER_HOST':'unix://'+str(home/'docker.sock')},timeout=180).strip()
def wait_off(home):
 deadline=time.monotonic()+15
 while (home/'dmx.sock').exists() and time.monotonic()<deadline:time.sleep(.1)
 return not(home/'dmx.sock').exists()
def clean_engine(cli,home,env):
 run([cli,'stop','--json'],env,timeout=160);check(home.parent.name+'_daemon_cleanup',wait_off(home))

try:
 files=sorted(p for p in DOWNLOAD.iterdir() if p.is_file());expected=sorted(p for p in DIST.iterdir() if p.is_file())
 check('all14_assets_downloaded_and_match_built_bytes',len(files)==14 and {p.name for p in files}=={p.name for p in expected} and all(sha(p)==sha(DIST/p.name) for p in files),[{'name':p.name,'bytes':p.stat().st_size,'sha256':sha(p)} for p in files])
 fresh=work/'fresh';home,env,cli,app=install(fresh)
 selftest=data([cli,'boot','--selftest','--json'],env,timeout=240)
 check('fresh_published_selftest23',selftest['ok'] and len(selftest['checks'])==23,{'host':selftest.get('host'),'checks':len(selftest['checks'])})
 guest=data([cli,'guest','--json'],env)
 check('fresh_guest_pinned_release',guest['ok'] and guest['guest']['tag']=='v0.4.0' and guest['guest']['pinned_tag']=='v0.4.0' and not guest['guest']['needs_fetch'] and guest['pinned']['sha256']=='39f9716e0c945dcd4ab0935aea13ee7fbe1fe0392734fde863d4e5c238e88070',guest)
 before=data([cli,'start','--json'],env);matrix=json.loads((ROOT/'scripts/image-matrix.json').read_text())['images']['alpine']
 for platform,digest in matrix['platforms'].items():
  image='alpine@'+digest
  output=docker(cli,home,env,'run','--rm','--platform',platform,image,'sh','-c','uname -m; od -An -tu1 -N5 /bin/busybox').decode()
  values=list(map(int,output.splitlines()[-1].split()))
  check('published_'+platform,values==[127,69,76,70,1 if platform=='linux/386' else 2],output)
 container=docker(cli,home,env,'run','-d','--name','public-update-proof','-v','public-volume:/proof','busybox:1.37','sh','-c','echo retained > /proof/marker; exec sleep 600').decode()
 updated=data([cli,'update','--version','0.4.0','--force','--json'],env)
 after=data([cli,'status','--json'],env)
 check('published_whole_app_update_vm',updated['updated'] and before['pid']==after['pid'] and after['state']=='running' and updated['signature']=='V4YA23448U',updated)
 check('published_whole_app_update_container_volume',docker(cli,home,env,'inspect','--format','{{.Id}} {{.State.Running}}','public-update-proof').decode()==container+' true' and docker(cli,home,env,'exec','public-update-proof','cat','/proof/marker')==b'retained')
 signature(app);clean_engine(cli,home,env)
 # The previous public CLI updates itself, then the new installer adds the app without
 # restarting its original VM or changing the running container/named volume.
 olddir=OUT/'legacy-v0.3.12';olddir.mkdir(exist_ok=True)
 run(['gh','release','download','v0.3.12','--pattern','dmx-0.3.12-darwin-arm64.tar.gz*','--dir',olddir,'--clobber'],timeout=180)
 oldtar=olddir/'dmx-0.3.12-darwin-arm64.tar.gz';want=(olddir/(oldtar.name+'.sha256')).read_text().split()[0];check('previous_public_archive_checksum',sha(oldtar)==want)
 legacy=work/'legacy';legacy.mkdir();legacy_home=legacy/'home';legacy_home.mkdir();homes.append(legacy_home)
 for name in ['guest','bin','cli-plugins']:(legacy_home/name).symlink_to(home/name)
 (legacy_home/'config.json').write_text(json.dumps({'cpus':2,'memory':'2G','shares':[],'idle_timeout':600}))
 legacy_cli=legacy/'prefix/bin/dmx';legacy_cli.parent.mkdir(parents=True)
 with tarfile.open(oldtar) as tar:
  member=tar.getmember('dmx');assert member.isfile();legacy_cli.write_bytes(tar.extractfile(member).read())
 legacy_cli.chmod(0o755)
 run(['codesign','--verify','--strict','-R','=anchor apple generic and certificate leaf[subject.OU] = "V4YA23448U"',legacy_cli])
 legacy_env={**env,'DMX_HOME':str(legacy_home),'DOCKER_CONFIG':str(legacy/'docker'),'PREFIX':str(legacy/'prefix'),'DMX_APP_DIR':str(legacy/'Applications/dmx.app')}
 original=data([legacy_cli,'start','--json'],legacy_env)
 cid=docker(legacy_cli,legacy_home,legacy_env,'run','-d','--name','legacy-update-proof','-v','legacy-volume:/proof','busybox:1.37','sh','-c','echo legacy > /proof/marker; exec sleep 600').decode()
 update=data([legacy_cli,'update','--version','0.4.0','--json'],legacy_env,timeout=180)
 check('previous_cli_updates_to_040_without_restart',update['updated'] and run([legacy_cli,'--version'],legacy_env).strip()==b'0.4.0' and data([legacy_cli,'status','--json'],legacy_env)['pid']==original['pid'],update)
 run(['sh',DOWNLOAD/'install.sh'],legacy_env,timeout=180)
 migrated=data([legacy_cli,'status','--json'],legacy_env)
 check('legacy_unified_installer_keeps_vm_container_volume',legacy_cli.is_symlink() and migrated['pid']==original['pid'] and docker(legacy_cli,legacy_home,legacy_env,'inspect','--format','{{.Id}} {{.State.Running}}','legacy-update-proof').decode()==cid+' true' and docker(legacy_cli,legacy_home,legacy_env,'exec','legacy-update-proof','cat','/proof/marker')==b'legacy')
 signature(legacy/'Applications/dmx.app');clean_engine(legacy_cli,legacy_home,legacy_env)
 completed=True;save();print(json.dumps({'ok':True,'checks':len(reports),'report':str(OUT/'public-verification.json')}),flush=True)
except BaseException as error:
 reports.append({'name':'verification_exception','ok':False,'detail':repr(error)});save();raise
finally:
 for state in homes:
  if (state/'dmx.sock').exists():
   try:
    with socket.socket(socket.AF_UNIX) as s:
     s.settimeout(15);s.connect(str(state/'dmx.sock'));p=json.dumps({'id':1,'method':'quit','params':{}}).encode();s.sendall(struct.pack('>I',len(p)+1)+b'\0'+p);s.recv(4096)
   except OSError:pass
   wait_off(state)
 if completed and reports and all(x['ok'] for x in reports) and not any((h/'dmx.sock').exists() for h in homes):shutil.rmtree(work)
