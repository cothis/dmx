"""Run from the repo after publication. Requires independent qualified local release bytes."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path.cwd()
OUT = ROOT / '.build/storage-review'
DOWNLOAD = OUT / 'public-v0.4.1'
REFERENCE = OUT / 'qualified-v0.4.1'
VERSION = '0.4.1'
PREVIOUS = '0.4.0'
work = Path(tempfile.mkdtemp(prefix='dmx-public-log-', dir='/tmp'))
homes = []
checks = []
complete = False


def save():
    (OUT / 'public-verification.json').write_text(json.dumps({'ok': complete and all(c['ok'] for c in checks), 'checks': checks}, indent=2))


def check(name, ok, detail=None):
    checks.append({'name': name, 'ok': bool(ok), 'detail': detail})
    save()
    if not ok:
        raise AssertionError(name + ': ' + str(detail))


def run(argv, env=None, timeout=240):
    result = subprocess.run(list(map(str, argv)), env=env, capture_output=True, timeout=timeout)
    if result.returncode:
        raise AssertionError((list(map(str, argv)), result.returncode, result.stdout.decode(errors='replace')[-2000:], result.stderr.decode(errors='replace')[-2000:]))
    return result.stdout


def data(argv, env=None, timeout=240):
    return json.loads(run(argv, env, timeout))


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def signature(app):
    for argv in [['codesign', '--verify', '--deep', '--strict', '--check-notarization', app],
                 ['xcrun', 'stapler', 'validate', app], ['spctl', '--assess', '--type', 'execute', app]]:
        run(argv, timeout=60)


def environment(area):
    home = area / 'home'
    home.mkdir(parents=True)
    homes.append(home)
    (home / 'config.json').write_text('{"cpus":2,"memory":"2G","shares":[],"idle_timeout":600}')
    env = {**os.environ, 'DMX_HOME': str(home), 'DOCKER_CONFIG': str(area / 'docker'),
           'PREFIX': str(area / 'prefix'), 'DMX_APP_DIR': str(area / 'Applications/dmx.app')}
    for key in ['DMX_RELEASE_URL', 'DMX_TOOLS_URL', 'DMX_VERSION']:
        env.pop(key, None)
    return home, env, area / 'prefix/bin/dmx', area / 'Applications/dmx.app'


def docker(home, env, *args):
    return run([home / 'bin/docker', *args], {**env, 'DOCKER_HOST': 'unix://' + str(home / 'docker.sock')}).strip()


def stop(cli, home, env):
    run([cli, 'stop', '--json'], env)
    end = time.monotonic() + 15
    while (home / 'dmx.sock').exists() and time.monotonic() < end:
        time.sleep(.1)
    check(home.parent.name + '_daemon_exits', not (home / 'dmx.sock').exists())


try:
    files = sorted(p for p in DOWNLOAD.iterdir() if p.is_file())
    expected = sorted(p for p in REFERENCE.iterdir() if p.is_file())
    check('all14_public_assets_match_independent_qualified_bytes', len(files) == len(expected) == 14
          and {p.name for p in files} == {p.name for p in expected}
          and all(sha(p) == sha(REFERENCE / p.name) for p in files),
          [{'name': p.name, 'bytes': p.stat().st_size, 'sha256': sha(p)} for p in files])
    home, env, cli, app = environment(work / 'fresh')
    run(['sh', DOWNLOAD / 'install.sh'], env, timeout=600)
    signature(app)
    check('fresh_unified_install_without_engine', cli.is_symlink() and cli.resolve() == (app / 'Contents/MacOS/dmx').resolve()
          and not (home / 'dmx.sock').exists())
    selftest = data([cli, 'boot', '--selftest', '--json'], env)
    check('published_selftest23', selftest['ok'] and len(selftest['checks']) == 23, selftest.get('host'))
    guest = data([cli, 'guest', '--json'], env)
    check('published_guest_pin', guest['guest']['tag'] == 'v' + VERSION and guest['guest']['pinned_tag'] == 'v' + VERSION
          and not guest['guest']['needs_fetch'] and guest['pinned']['sha256'] == sha(REFERENCE / 'dmx-guest-0.4.1.tar.gz'))
    # Actual published host + downloaded pinned guest execute all new overflow/failure paths.
    storage = work / 'storage-source'
    storage.mkdir()
    (storage / 'guest').symlink_to(home / 'guest')
    (storage / 'cache').symlink_to(Path.home() / '.dmx/cache')
    report = data(['python3', '-I', ROOT / 'scripts/test-storage.py', cli],
                  {**os.environ, 'DMX_HOME': str(storage)}, timeout=600)
    (OUT / 'public-storage.json').write_text(json.dumps(report, indent=2))
    check('published_storage_regressions', report['ok'], len(report['checks']))
    run([cli, 'start', '--json'], env)
    pins = json.loads((ROOT / 'scripts/image-matrix.json').read_text())['images']['alpine']['platforms']
    for platform, digest in pins.items():
        output = docker(home, env, 'run', '--rm', '--platform', platform, 'alpine@' + digest,
                        'sh', '-c', 'uname -m; od -An -tu1 -N5 /bin/busybox').decode()
        check('published_' + platform, list(map(int, output.splitlines()[-1].split())) == [127, 69, 76, 70, 1 if platform == 'linux/386' else 2], output)
    stop(cli, home, env)

    # Real previous public app -> new whole app while its engine/container/volume stay live.
    previous = OUT / 'previous-public-0.4.0'
    previous.mkdir(exist_ok=True)
    run(['gh', 'release', 'download', 'v' + PREVIOUS, '--pattern', 'install.sh', '--dir', previous, '--clobber'])
    old_home, old_env, old_cli, old_app = environment(work / 'previous')
    run(['sh', previous / 'install.sh'], old_env, timeout=600)
    check('previous_public_version', run([old_cli, '--version'], old_env).strip() == PREVIOUS.encode())
    original = data([old_cli, 'start', '--json'], old_env)
    disk_before = (old_home / 'data.img').stat().st_ino
    cid = docker(old_home, old_env, 'run', '-d', '--name', 'update-proof', '-v', 'update-proof:/proof',
                 'alpine@' + pins['linux/arm64'], 'sh', '-c', 'echo retained > /proof/marker; exec sleep 600').decode()
    old_options = json.loads(docker(old_home, old_env, 'inspect', '--format', '{{json .HostConfig.LogConfig}}', 'update-proof'))
    check('previous_container_unbounded_fixture', old_options['Type'] == 'json-file' and not old_options.get('Config'), old_options)
    updated = data([old_cli, 'update', '--version', VERSION, '--json'], old_env)
    after = data([old_cli, 'status', '--json'], old_env)
    check('previous_app_update_keeps_vm', updated['updated'] and after['pid'] == original['pid'] and after['state'] == 'running'
          and run([old_cli, '--version'], old_env).strip() == VERSION.encode(), updated)
    check('update_keeps_live_container_and_volume', docker(old_home, old_env, 'inspect', '--format', '{{.Id}} {{.State.Running}}', 'update-proof').decode() == cid + ' true'
          and docker(old_home, old_env, 'exec', 'update-proof', 'cat', '/proof/marker') == b'retained')
    signature(old_app)
    stop(old_cli, old_home, old_env)
    new_engine = data([old_cli, 'start', '--json'], old_env)
    check('new_engine_uses_patched_version_and_same_data_disk', new_engine['version'] == VERSION and (old_home / 'data.img').stat().st_ino == disk_before)
    docker(old_home, old_env, 'start', 'update-proof')
    check('reboot_keeps_volume', docker(old_home, old_env, 'exec', 'update-proof', 'cat', '/proof/marker') == b'retained')
    kept_options = json.loads(docker(old_home, old_env, 'inspect', '--format', '{{json .HostConfig.LogConfig}}', 'update-proof'))
    check('existing_container_logging_unchanged', kept_options == old_options, kept_options)
    docker(old_home, old_env, 'create', '--name', 'new-defaults', 'alpine@' + pins['linux/arm64'], 'true')
    options = json.loads(docker(old_home, old_env, 'inspect', '--format', '{{json .HostConfig.LogConfig}}', 'new-defaults'))
    check('new_container_defaults_after_update', options == {'Type': 'json-file', 'Config': {'max-size': '10m', 'max-file': '2'}}, options)
    stop(old_cli, old_home, old_env)
    complete = True
    save()
    print(json.dumps({'ok': True, 'checks': len(checks)}), flush=True)
except BaseException as error:
    checks.append({'name': 'verification_exception', 'ok': False, 'detail': repr(error)})
    save()
    raise
finally:
    for home in homes:
        if (home / 'dmx.sock').exists():
            try:
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(15)
                    connection.connect(str(home / 'dmx.sock'))
                    body = json.dumps({'id': 1, 'method': 'quit', 'params': {}}).encode()
                    connection.sendall(struct.pack('>I', len(body) + 1) + b'\0' + body)
                    connection.recv(4096)
            except OSError:
                pass
    if complete and not any((h / 'dmx.sock').exists() for h in homes):
        shutil.rmtree(work)
