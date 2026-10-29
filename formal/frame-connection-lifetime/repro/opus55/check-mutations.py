#!/usr/bin/env python3
"""Reproduce two review coverage gaps without changing the checkout's source."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[4]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--out", type=Path, default=ROOT / ".build/opus55-review-mutations")
OUT = parser.parse_args().out.resolve()
if OUT.exists():
    raise SystemExit(f"Use a fresh output directory (existing evidence preserved): {OUT}")
MODEL = OUT / "model"
shutil.copytree(ROOT / "formal/frame-connection-lifetime/tla", MODEL)
spec = MODEL / "Spec.tla"
old = 'IF LeaseFD /\\ closed THEN "done" ELSE "active"'
assert old in spec.read_text()
spec.write_text(spec.read_text().replace(old, '"active"'))
jar = Path(os.environ.get("TLA2TOOLS", Path.home() / ".cache/proof-skills/tla2tools.jar")).expanduser().resolve()
with (OUT / "model-without-close-guard.log").open("w") as log:
    result = subprocess.run(["java", "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC",
                             "-noGenerateSpecTE", "-workers", "1", "-coverage", "1",
                             "-config", "MC.cfg", "-metadir", str(OUT / "states"), "Spec.tla"],
                            cwd=MODEL, stdout=log, stderr=subprocess.STDOUT)
assert result.returncode == 0, "Model result changed; inspect the log"
print("Model missing the closed guard still passes its original invariants", flush=True)

pkg = OUT / "no-shutdown-package"
(pkg / "Sources/DMXCore").mkdir(parents=True)
(pkg / "Tests/DMXCoreTests").mkdir(parents=True)
(pkg / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ReviewMutation", platforms: [.macOS(.v15)], targets: [.target(name: "DMXCore"), .testTarget(name: "DMXCoreTests", dependencies: ["DMXCore"])])
''')
for source in (ROOT / "Sources/DMXCore").rglob("*.swift"):
    target = pkg / "Sources/DMXCore" / source.relative_to(ROOT / "Sources/DMXCore")
    target.parent.mkdir(parents=True, exist_ok=True)
    if source.name == "Agent.swift":
        content = source.read_text()
        old = "        Darwin.shutdown(fd, SHUT_RDWR)\n"
        assert old in content
        target.write_text(content.replace(old, "", 1))
    else:
        target.symlink_to(source)
(pkg / "Tests/DMXCoreTests/FrameConnectionTests.swift").symlink_to(ROOT / "Tests/DMXCoreTests/FrameConnectionTests.swift")
with (OUT / "no-shutdown-tests.log").open("w") as log:
    result = subprocess.run(["swift", "test", "--package-path", str(pkg), "--filter", "FrameConnectionTests"],
                            cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
assert result.returncode == 0, "Test result changed; inspect the log"
print("Core missing close's shutdown still passes all three original socket tests", flush=True)
