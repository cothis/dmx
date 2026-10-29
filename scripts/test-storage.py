#!/usr/bin/env python3
"""Bounded host/guest/container logs on a real, isolated VM; never touch the user's engine."""
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import socket
import shutil
import time

DMX = Path(sys.argv[1] if len(sys.argv) > 1 else '.build/release/dmx').resolve()
ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(os.environ.get('DMX_HOME', Path.home() / '.dmx'))
GUEST = (SOURCE / 'guest').resolve()
DOCKER = SOURCE / 'cache/docker-tools/bin/docker'
LIMIT = 1 << 20
checks = []
metrics = {}
HARNESS = os.environ.get('DMX_RUST_TEST')
if HARNESS is None:
    built = subprocess.run(['cargo', 'test', '--locked', '--no-run', '--message-format=json'],
                           cwd=ROOT / 'guest/agent', capture_output=True, text=True, timeout=180)
    if built.returncode:
        raise RuntimeError(built.stderr)
    artifacts = [json.loads(line) for line in built.stdout.splitlines() if line.strip()]
    HARNESS = next(a['executable'] for a in artifacts if a.get('reason') == 'compiler-artifact'
                   and a.get('profile', {}).get('test') and a.get('executable'))
HARNESS = Path(HARNESS).resolve()
metrics['guest_test_harness_sha256'] = hashlib.sha256(HARNESS.read_bytes()).hexdigest()


def check(name, ok, detail=''):
    checks.append({'name': name, 'ok': bool(ok), 'detail': str(detail)[:500]})
    if not ok:
        raise AssertionError(name + ': ' + str(detail))


def wait(predicate, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            if predicate():
                return True
        except FileNotFoundError:
            pass  # A log can be between rename and create during rotation.
        time.sleep(.05)
    return False


with tempfile.TemporaryDirectory(prefix='dmx-storage-') as scratch:
    home = Path(scratch)
    (home / 'guest').symlink_to(GUEST)
    (home / 'logs').mkdir()
    (home / 'config.json').write_text(json.dumps({'cpus': 2, 'memory': '2G', 'shares': [str(HARNESS.parent)], 'idle_timeout': 300}))
    env = {**os.environ, 'DMX_HOME': str(home), 'DOCKER_CONFIG': str(home / 'docker-config'), 'DOCKER_HOST': 'unix://' + str(home / 'docker.sock')}
    (home / 'docker-config').mkdir()
    for name in ['daemon.log', 'console.log']:
        for suffix in ['', '.1', '.2']:
            (home / 'logs' / (name + suffix)).write_bytes(b'o' * (4 * LIMIT))
    # Reproduce an older launchd job whose stdout/stderr already reference the old log inode.
    with (home / 'logs/daemon.log').open('ab') as legacy:
        daemon = subprocess.Popen([DMX, 'daemon'], env=env, stdin=subprocess.DEVNULL, stdout=legacy, stderr=legacy)

    def command(*args, seconds=150):
        return subprocess.run([DMX, *args], capture_output=True, env=env, timeout=seconds)

    def guest(script):
        r = command('exec', '--', 'sh', '-c', script)
        check('guest_command_' + str(len(checks)), r.returncode == 0, r.stderr.decode(errors='replace'))
        return r.stdout

    def docker(*args):
        r = subprocess.run([DOCKER, *args], capture_output=True, env=env, timeout=180)
        check('docker_command_' + str(len(checks)), r.returncode == 0, r.stderr.decode(errors='replace'))
        return r.stdout

    def host_sizes(name):
        return [(home / 'logs' / (name + suffix)).stat().st_size for suffix in ['', '.1', '.2']]

    try:
        check('foreground_socket', wait(lambda: (home / 'dmx.sock').exists() or daemon.poll() is not None) and daemon.poll() is None)
        started = command('start', '--json')
        check('real_vm_start', started.returncode == 0, started.stdout.decode())
        metrics['idle_before_docker'] = json.loads(started.stdout)
        descriptors = subprocess.run(['lsof', '-a', '-p', str(daemon.pid), '-d', '1,2', '-Fn'], capture_output=True, text=True)
        names = [line[1:] for line in descriptors.stdout.splitlines() if line.startswith('n')]
        check('legacy_stdio_detached', names == ['/dev/null', '/dev/null'], names)
        check('old_host_logs_bounded', all(0 <= n <= LIMIT for name in ['daemon.log', 'console.log'] for n in host_sizes(name)), {name: host_sizes(name) for name in ['daemon.log', 'console.log']})
        guest("dd if=/dev/zero bs=8192 count=1024 2>/dev/null > /dev/hvc0; printf 'CONSOLE-TAIL\\n' > /dev/hvc0")
        check('console_flood_tail', wait(lambda: (home / 'logs/console.log').read_bytes().rstrip(b'\r\n').endswith(b'CONSOLE-TAIL')))
        check('console_flood_bound', all(n <= LIMIT for n in host_sizes('console.log')), host_sizes('console.log'))
        guest("mkdir -p /var/lib/dmx/log; for s in '' .1 .2; do dd if=/dev/zero bs=1048576 count=4 2>/dev/null > /var/lib/dmx/log/dockerd.log$s; done")
        # A failed script leaves a descendant holding stderr. Retry must work before it exits.
        stub = '#!/bin/sh\nsleep 120 &\necho $! >> /run/dmx/log-probe-pids\necho INHERITED-PIPE-START-FAIL >&2\nexit 23\n'
        prepared = command('exec', '--', 'sh', '-c', 'cp /sbin/dmx-docker /tmp/original-dmx-docker; printf %s "$1" > /sbin/dmx-docker', 'sh', stub)
        check('failed_start_fixture', prepared.returncode == 0)
        failed = subprocess.run([DOCKER, 'info'], capture_output=True, env=env, timeout=30)
        check('failed_start_returns', failed.returncode != 0)
        check('failed_start_tail_retained', b'INHERITED-PIPE-START-FAIL' in guest('tail -c 8192 /var/lib/dmx/log/dockerd.log'))
        guest('cp /tmp/original-dmx-docker /sbin/dmx-docker')
        began = time.monotonic()
        docker('info', '--format', '{{.LoggingDriver}}')
        check('retry_before_inherited_pipe_closes', time.monotonic() - began < 20)
        guest('for p in $(cat /run/dmx/log-probe-pids); do kill "$p" 2>/dev/null || true; done')
        # Real dockerd/containerd inheritance, beyond the controlled failed-script fixture.
        previous_dockerd = guest('cat /var/run/docker.pid').strip()
        metrics['containerd_before_crash'] = guest('for p in $(pidof containerd); do echo pid=$p; readlink /proc/$p/fd/2; done').decode()
        guest('kill -9 "$(cat /var/run/docker.pid)"')
        check('dockerd_restart_after_crash', wait(lambda: subprocess.run([DOCKER, 'info'], capture_output=True, env=env, timeout=20).returncode == 0 and command('exec', '--', 'cat', '/var/run/docker.pid').stdout.strip() not in [b'', previous_dockerd], 25))
        metrics['containerd_after_crash'] = guest('for p in $(pidof containerd); do echo pid=$p; readlink /proc/$p/fd/2; done').decode()
        before = guest('wc -c /var/lib/dmx/log/dockerd.log /var/lib/dmx/log/dockerd.log.1 /var/lib/dmx/log/dockerd.log.2').decode()
        check('old_guest_logs_bounded', all(int(line.split()[0]) <= LIMIT for line in before.splitlines()[:-1]), before)
        guest("p=$(cat /var/run/docker.pid); dd if=/dev/zero bs=8192 count=1024 2>/dev/null > /proc/$p/fd/2; printf 'DOCKERD-TAIL\\n' > /proc/$p/fd/2")
        check('dockerd_flood_tail', wait(lambda: b'DOCKERD-TAIL' in command('exec', '--', 'tail', '-c', '1024', '/var/lib/dmx/log/dockerd.log').stdout))
        sizes = guest('wc -c /var/lib/dmx/log/dockerd.log /var/lib/dmx/log/dockerd.log.1 /var/lib/dmx/log/dockerd.log.2').decode()
        check('dockerd_flood_bound', all(int(line.split()[0]) <= LIMIT for line in sizes.splitlines()[:-1]), sizes)
        pin = json.loads((ROOT / 'scripts/image-matrix.json').read_text())['images']['alpine']
        image = 'alpine@' + pin['platforms']['linux/arm64']
        # About 30 MiB of ordinary container stdout, more than its default two-file budget.
        docker('run', '-d', '--name', 'log-flood', image, 'sh', '-c', "yes '012345678901234567890123456789' | head -c 30000000; echo CONTAINER-TAIL")
        check('container_flood_exit', docker('wait', 'log-flood').strip() == b'0')
        config = json.loads(docker('inspect', '--format', '{{json .HostConfig.LogConfig}}', 'log-flood'))
        check('container_defaults', config == {'Type': 'json-file', 'Config': {'max-size': '10m', 'max-file': '2'}}, config)
        check('docker_logs_retains_tail', b'CONTAINER-TAIL' in docker('logs', '--tail', '1', 'log-flood'))
        container = json.loads(docker('inspect', 'log-flood'))[0]
        prefix = container['LogPath']
        usage = guest('wc -c ' + prefix + ' ' + prefix + '.1').decode()
        # Docker rotates by record: allow one bounded record beyond the nominal file size.
        check('container_flood_bound', all(int(line.split()[0]) <= 10_000_000 + 65536 for line in usage.splitlines()[:-1]), usage)
        metrics['container_log_sizes'] = usage
        docker('run', '--name', 'explicit-log', '--log-driver', 'none', image, 'echo', 'explicit')
        explicit = json.loads(docker('inspect', '--format', '{{json .HostConfig.LogConfig}}', 'explicit-log'))
        check('per_container_override', explicit['Type'] == 'none', explicit)
        # Verify persisted creation-time settings are untouched by a daemon restart.
        stopped = command('stop', '--json')
        check('stop', stopped.returncode == 0)
        check('old_daemon_exits', wait(lambda: daemon.poll() is not None))
        restarted = command('start', '--json')
        check('restart_after_manual_daemon_exit', restarted.returncode == 0, restarted.stdout.decode())
        docker('info')
        retained = json.loads(docker('inspect', '--format', '{{json .HostConfig.LogConfig}}', 'explicit-log'))
        check('existing_container_override_preserved', retained['Type'] == 'none', retained)
        metrics['idle_after_docker'] = json.loads(command('status', '--json').stdout)
        # Cross-compiled tests run inside Linux, exercising the same collector/log code.
        result = command('exec', '--', str(HARNESS), '--nocapture')
        check('guest_rust_rotation_tests', result.returncode == 0 and b'test result: ok.' in result.stdout,
              result.stdout.decode() + result.stderr.decode())
        # Diagnostic setup failure must never prevent the otherwise healthy engine starting.
        command('stop', '--json')
        check('stopped_before_log_failures', wait(lambda: not (home / 'dmx.sock').exists()))
        saved_logs = home / 'logs.saved'
        (home / 'logs').rename(saved_logs)
        (home / 'logs').mkdir(mode=0o500)
        unavailable = command('start', '--json')
        check('unwritable_host_logs_still_boot', unavailable.returncode == 0, unavailable.stdout.decode())
        warning_status = json.loads(unavailable.stdout)
        check('unwritable_logs_reported', len(warning_status.get('log_warnings', [])) == 2, warning_status.get('log_warnings'))
        check('plain_status_reports_log_warning', b'log warning:' in command('status').stdout)
        guest("rm -f /var/lib/dmx/log/dockerd.log; printf PRESERVE > /var/lib/dmx/log/keep; ln -s /var/lib/dmx/log/keep /var/lib/dmx/log/dockerd.log")
        docker('info', '--format', '{{.LoggingDriver}}')
        check('unsafe_guest_log_still_starts_docker', guest('cat /var/lib/dmx/log/keep') == b'PRESERVE')
        # Keep a passive client open: stop/start must retry sinks in the SAME daemon.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as holder:
            holder.connect(str(home / 'dmx.sock'))
            check('passive_client_accepted', json.loads(command('status', '--json').stdout).get('clients', 0) >= 1)
            old_pid = warning_status['pid']
            (home / 'logs').chmod(0o700)
            command('stop', '--json')
            recovered = command('start', '--json')
            check('same_daemon_log_recovery', recovered.returncode == 0 and json.loads(recovered.stdout)['pid'] == old_pid
                  and not json.loads(recovered.stdout).get('log_warnings'), recovered.stdout.decode())
            check('recovered_console_is_live', b'--- dmx VM boot ' in (home / 'logs/console.log').read_bytes())
            docker('info', '--format', '{{.LoggingDriver}}')
            check('guest_disabled_sink_warning', wait(lambda: b'diagnostic logging disabled' in (home / 'logs/console.log').read_bytes()))
        command('stop', '--json')
        check('unavailable_logger_daemon_exits', wait(lambda: not (home / 'dmx.sock').exists()))
        shutil.rmtree(home / 'logs')
        saved_logs.rename(home / 'logs')
        target = home / 'keep-host'
        contents = b'preserve host target' * 100000
        target.write_bytes(contents)
        (home / 'logs/daemon.log').unlink()
        (home / 'logs/daemon.log').symlink_to(target)
        (home / 'logs/console.log').unlink()
        os.mkfifo(home / 'logs/console.log', 0o600)
        unsafe = command('start', '--json')
        check('unsafe_host_logs_still_boot', unsafe.returncode == 0, unsafe.stdout.decode())
        check('unsafe_host_logs_reported', len(json.loads(unsafe.stdout).get('log_warnings', [])) == 2)
        check('unsafe_log_target_unchanged', target.read_bytes() == contents)
    finally:
        (home / 'logs').chmod(0o700)
        command('stop', '--json')
        if daemon.poll() is None:
            daemon.terminate()
            daemon.wait(timeout=15)
        wait(lambda: not (home / 'dmx.sock').exists())
        print(json.dumps({'ok': all(c['ok'] for c in checks), 'checks': checks, 'metrics': metrics}, indent=2))
