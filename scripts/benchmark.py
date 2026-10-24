#!/usr/bin/env python3
"""Repeatable Docker workloads with ri_phys_footprint, including guest RAM, on macOS.

Default: a throwaway dmx VM, 2 CPUs / 4G ceiling / no shares. Other engines must already be
configured to match: --endpoint unix:///... --label ENGINE --pid VM_PID [--pid OTHER_PID].
Does not install, configure, start or stop external engines. stdout JSON, progress stderr.
Numbers on a busy host are provisional: record load and repeat on a quiet Mac for comparison.
"""

import argparse
import ctypes
import datetime
import hashlib
import importlib.util
import json
import os
import platform
import resource
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("image_matrix", ROOT / "scripts/test-images.py")
images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(images)


class Usage(ctypes.Structure):
    # Prefix of rusage_info_v4 in the macOS SDK's sys/resource.h. The full output is larger;
    # proc_pid_rusage writes into a 1 KiB buffer, then only this prefix is decoded.
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user_ticks", "system_ticks", "package_wakeups", "interrupt_wakeups", "pageins",
        "wired_bytes", "resident_bytes", "footprint_bytes")]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
libproc.proc_pid_rusage.restype = ctypes.c_int


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


timebase = Timebase()
libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
libsystem.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
libsystem.mach_timebase_info.restype = ctypes.c_int
if libsystem.mach_timebase_info(ctypes.byref(timebase)) or not timebase.denom:
    raise RuntimeError("cannot read Mach clock timebase")


def usage(pid):
    buf = ctypes.create_string_buffer(1024)
    if libproc.proc_pid_rusage(pid, 4, buf):
        raise OSError(ctypes.get_errno(), f"proc_pid_rusage({pid})")
    u = Usage.from_buffer_copy(buf.raw[:ctypes.sizeof(Usage)])
    return {"pid": pid, "footprint_mb": round(u.footprint_bytes / (1 << 20), 2),
            "cpu_s": (u.user_ticks + u.system_ticks) * timebase.numer / timebase.denom / 1e9}


def snapshot(pids):
    processes = [usage(pid) for pid in pids]
    return {"footprint_mb": round(sum(p["footprint_mb"] for p in processes), 2),
            "cpu_s": sum(p["cpu_s"] for p in processes), "processes": processes}


def pressure():
    return int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"], text=True))


def check_cpu_reader():
    """Catch a Mach-ticks-as-nanoseconds error against getrusage, before measuring an engine."""
    before = usage(os.getpid())["cpu_s"]
    r = resource.getrusage(resource.RUSAGE_SELF)
    reference = r.ru_utime + r.ru_stime
    started = time.process_time()
    while time.process_time() - started < 0.05: sum(range(1000))
    r = resource.getrusage(resource.RUSAGE_SELF)
    expected = r.ru_utime + r.ru_stime - reference
    measured = usage(os.getpid())["cpu_s"] - before
    assert abs(measured - expected) < max(0.005, expected * 0.05), (measured, expected)
    return {"getrusage_s": expected, "reader_s": measured}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("dmx", nargs="?", default=".build/release/dmx")
    p.add_argument("--endpoint", help="existing external Docker Unix socket URI")
    p.add_argument("--label", default="dmx")
    p.add_argument("--pid", type=int, action="append", help="external engine's VM and other charged processes; repeat to sum")
    p.add_argument("--cpus", type=int, default=2, help="VM CPUs; comparison protocol defaults to 2")
    p.add_argument("--ceiling-gb", type=int, choices=(4, 8, 16), default=4, help="VM memory ceiling; comparison protocol defaults to 4")
    args = p.parse_args()
    if not 1 <= args.cpus <= (os.cpu_count() or 1):
        p.error("--cpus must fit the host's available cores")
    if args.endpoint and (not args.endpoint.startswith("unix://") or not args.pid or args.label == "dmx"):
        p.error("external engines need --endpoint unix:///... --label ENGINE --pid VM_PID (repeat for other engine processes)")
    if not args.endpoint and args.pid:
        p.error("dmx's PID is read from its own status, not --pid")
    if not args.endpoint and args.label != "dmx":
        p.error("an external engine label requires --endpoint and --pid")
    reader_check = check_cpu_reader()
    state = Path(tempfile.mkdtemp(prefix="dmx-bm-", dir="/tmp"))
    if not args.endpoint:
        guest = Path(os.environ.get("DMX_HOME") or Path.home() / ".dmx") / "guest"
        (state / "guest").symlink_to(guest)
        (state / "config.json").write_text(json.dumps({"cpus": args.cpus, "memory": f"{args.ceiling_gb}G", "shares": [], "idle_timeout": 600, "disk_size": "16G"}))
    matrix = images.Matrix(Path(args.dmx).resolve(), state)
    matrix.case = "dmx-benchmark-" + state.name
    report = {"ok": False, "engine": args.label, "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "host": {"macos": platform.mac_ver()[0], "arch": platform.machine(), "cores": os.cpu_count()},
              "host_load_start": os.getloadavg(), "host_pressure_start": pressure(),
              "mach_timebase": {"numer": timebase.numer, "denom": timebase.denom}, "cpu_reader_check": reader_check,
              "settings": {"cpus": args.cpus, "ceiling_mb": args.ceiling_gb * 1024, "container_cpus": 2, "shares": "none"}}
    try:
        if args.endpoint:
            matrix.dmx("tools", "install", "--json", env={**matrix.env, "DMX_HOME": str(matrix.tools)}, timeout=900)
            matrix.env["DOCKER_HOST"] = args.endpoint
            report["docker_versions"] = matrix.cli("version", "--format", "{{.Client.Version}} / {{.Server.Version}}")
            pids = sorted(set(args.pid))
        else:
            matrix.dmx("tools", "install", "--json", env={**matrix.env, "DMX_HOME": str(matrix.tools)}, timeout=900)
            started = time.monotonic()
            matrix.dmx("start", "--json")
            report["vm_start_ms"] = round((time.monotonic() - started) * 1000)
            status = json.loads(matrix.dmx("status", "--json"))
            pids = [status["pid"]]
            report["before_docker"] = snapshot(pids)
            # Catch an FFI layout error against dmx's independently implemented Swift reader.
            assert abs(report["before_docker"]["footprint_mb"] - status["host_footprint_mb"]) < 16
            started = time.monotonic()
            report["docker_versions"] = matrix.cli("version", "--format", "{{.Client.Version}} / {{.Server.Version}}")
            report["first_docker_ms"] = round((time.monotonic() - started) * 1000)
        report["process_commands"] = {pid: subprocess.check_output(["ps", "-p", str(pid), "-o", "comm="], text=True).strip() for pid in pids}
        info = json.loads(matrix.cli("info", "--format", "{{json .}}"))
        report["docker_info"] = {k: info.get(k) for k in ("ServerVersion", "KernelVersion", "NCPU", "MemTotal", "Architecture", "Driver")}
        if args.endpoint:
            ceiling_mb = args.ceiling_gb * 1024
            assert info["NCPU"] == args.cpus and ((ceiling_mb - 512) << 20) <= info["MemTotal"] <= (ceiling_mb << 20), "configure the external engine to the requested VM CPU count and memory ceiling first"
        entry = json.loads(images.PINS.read_text())["images"]["alpine"]
        image = entry["repository"] + "@" + entry["platforms"]["linux/arm64"]
        report["image"] = image
        matrix.cli("pull", "--platform", "linux/arm64", image, timeout=600)
        images.progress("settling idle memory for 35 s")
        time.sleep(35)
        report["idle"] = snapshot(pids)
        cpu_at = time.monotonic()
        time.sleep(10)
        later = snapshot(pids)
        report["idle_cpu_percent_of_one_core"] = round(100 * (later["cpu_s"] - report["idle"]["cpu_s"]) / (time.monotonic() - cpu_at), 3)
        times = []
        for _ in range(5):
            started = time.monotonic()
            matrix.run(image, "linux/arm64", "true")
            times.append(round((time.monotonic() - started) * 1000, 2))
            matrix.cli("rm", "-fv", matrix.case)
        report["run_true_ms"] = {"samples": times, "median": statistics.median(times)}
        started = time.monotonic()
        out = matrix.run(image, "linux/arm64", "sh", "-c", "head -c 268435456 /dev/zero | sha256sum")
        report["sha256_256m_ms"] = round((time.monotonic() - started) * 1000)
        matrix.cli("rm", "-fv", matrix.case)
        h = hashlib.sha256()
        for _ in range(256): h.update(bytes(1 << 20))
        assert out.split()[0] == h.hexdigest(), out
        images.progress("allocating and freeing 2 GiB of container tmpfs")
        before = snapshot(pids)
        samples = []
        stop_sampling = threading.Event()

        def sample():
            while not stop_sampling.wait(0.1): samples.append(snapshot(pids)["footprint_mb"])

        sampler = threading.Thread(target=sample)
        sampler.start()
        try:
            matrix.cli("run", "-d", "--pull", "never", "--platform", "linux/arm64", "--name", matrix.case,
                       "--network", "none", "--memory", "3g", "--cpus", "2", "--pids-limit", "256", "--ulimit", "core=0:0",
                       "--tmpfs", "/data:size=3g", image, "sh", "-c",
                       "dd if=/dev/zero of=/data/big bs=1M count=2048 2>/dev/null && echo filled; while [ ! -e /tmp/release ]; do sleep 0.1; done; rm /data/big; echo freed")
            deadline = time.monotonic() + 60
            while "filled" not in matrix.cli("logs", matrix.case):
                assert time.monotonic() < deadline, "allocation did not finish"
                time.sleep(0.1)
            report["holding_2g"] = snapshot(pids)
            matrix.cli("exec", matrix.case, "touch", "/tmp/release")
            assert matrix.cli("wait", matrix.case) == "0"
            matrix.cli("rm", "-fv", matrix.case)
            freed_at = time.monotonic()
            while snapshot(pids)["footprint_mb"] > before["footprint_mb"] + 64 and time.monotonic() - freed_at < 10:
                time.sleep(0.1)
            report["return_after_2g"] = {"baseline_mb": before["footprint_mb"], "after": snapshot(pids),
                                         "elapsed_s": round(time.monotonic() - freed_at, 2)}
            report["peak_2g_footprint_mb"] = max(samples + [report["holding_2g"]["footprint_mb"]])
        finally:
            stop_sampling.set(); sampler.join()
        report["host_load_end"] = os.getloadavg()
        report["host_pressure_end"] = pressure()
        report["ok"] = report["return_after_2g"]["after"]["footprint_mb"] <= before["footprint_mb"] + 64
    except Exception as e:
        report["error"] = str(e)
    finally:
        try:
            if matrix._exists(): matrix.cli("rm", "-fv", matrix.case)
            if not args.endpoint: matrix.stop()
            shutil.rmtree(state)
        except Exception as e:
            report["ok"] = False
            report["cleanup_error"] = str(e)
            report["retained_state"] = str(state)
        finally:
            print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
