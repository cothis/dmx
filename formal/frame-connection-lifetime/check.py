#!/usr/bin/env python3
"""Run the fixed model, unfixed mutation and two must-fail reachability checks.

Requires Java and tla2tools.jar (set TLA2TOOLS or use ~/.cache/proof-skills).
No installation or network access is performed. Evidence is overwritten on rerun.
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
JAR = Path(os.environ.get("TLA2TOOLS", Path.home() / ".cache/proof-skills/tla2tools.jar")).expanduser().resolve()
if not JAR.is_file():
    raise SystemExit("Set TLA2TOOLS to a local tla2tools.jar; see formal/README.md")
JAVA = ["java", "-XX:+UseParallelGC", "-cp", str(JAR)]
EVIDENCE = HERE / "evidence"
EVIDENCE.mkdir(exist_ok=True)
frozen_hash = next(line.split()[0] for line in (EVIDENCE / "baseline-hashes.txt").read_text().splitlines()
                   if line.endswith("tla/Properties.tla"))
assert hashlib.sha256((HERE / "tla/Properties.tla").read_bytes()).hexdigest() == frozen_hash, "Frozen protocol properties changed"

parsed = subprocess.run(JAVA + ["tla2sany.SANY", "Spec.tla"], cwd=HERE / "tla", capture_output=True, text=True)
(EVIDENCE / "sany.log").write_text(parsed.stdout + parsed.stderr)
if parsed.returncode:
    raise SystemExit("SANY failed; see evidence/sany.log")

for name, config, expected, invariant in [
    ("model-after", "MC.cfg", 0, None),
    ("mutation", "MC_bug.cfg", 12, "NoForeignIO"),
    ("sanity-completion", "MC_sanity.cfg", 12, "NeverCompletes"),
    ("sanity-reuse", "MC_reuse.cfg", 12, "NeverReuses"),
]:
    output = EVIDENCE / name
    output.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="dmx-tlc-") as state_dir:
        args = JAVA + ["tlc2.TLC", "-noGenerateSpecTE", "-workers", "1", "-coverage", "1", "-config", config,
                       "-metadir", state_dir, "Spec.tla"]
        result = subprocess.run(args, cwd=HERE / "tla", capture_output=True, text=True)
    log = result.stdout + result.stderr
    (output / "tlc.log").write_text(log)
    assert result.returncode == expected, (name, result.returncode, log)
    if invariant:
        assert f"Invariant {invariant} is violated" in log, (name, log)
    else:
        for action in ["Submit", "Acquire", "Transfer", "Finish", "Close", "Reuse", "Terminated"]:
            coverage = re.search(rf"<{action} line [^\n]+>: (\d+):(\d+)", log)
            assert coverage and int(coverage[2]) > 0, f"No action coverage: {action}"
    stats = re.search(r"\d+ states generated, \d+ distinct states found[^\n]*", log)
    print(f"{name}: expected exit {expected}; {stats[0] if stats else 'see log'}")

# Check that all correspondence pointers resolve. This does not prove semantic refinement.
pointers = 0
for path in [HERE / "CORRESPONDENCE.md", HERE / "tla/Spec.tla"]:
    for target, first, last in re.findall(r"((?:Sources|Tests)/[\w./]+\.swift):(\d+)(?:-(\d+))?", path.read_text()):
        lines = (ROOT / target).read_text().splitlines()
        assert 1 <= int(first) <= int(last or first) <= len(lines), (path, target, first, last)
        pointers += 1
(EVIDENCE / "correspondence.log").write_text(f"{pointers} source pointers resolve; 0 broken. Semantic map manually reviewed.\n")
print(f"correspondence: {pointers} valid pointers")
