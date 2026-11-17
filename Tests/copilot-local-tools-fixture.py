#!/usr/bin/env python3
"""Run the Swift tool test beside a freshly built bridge and fake runtime."""
from pathlib import Path
import os
import platform
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="copilot-tools-fixture-", dir=binary.parent) as temporary:
    directory = Path(temporary)
    executable = directory / binary.name
    shutil.copyfile(binary, executable)
    executable.chmod(0o700)
    runtime = directory / ("Copilot-" + platform.machine())
    runtime.mkdir(mode=0o700)
    environment = dict(os.environ, GOENV="off", GOTOOLCHAIN="local", GOWORK="off", GOSUMDB="off",
                       GOPROXY="off", GONOPROXY="none", GOPRIVATE="", CGO_ENABLED="0", GOCACHE=str(root / "build/go-cache"),
                       GOMODCACHE=os.environ.get("GOMODCACHE", str(root / "build/copilot-module-cache")))
    subprocess.run(["go", "-C", str(root / "copilot"), "build", "-mod=readonly", "-trimpath",
                    "-buildvcs=false", "-o", str(runtime / "bridge"), "."], env=environment, check=True)
    shutil.copyfile(root / "Tests/copilot-swift-tools-runtime-fixture.py", runtime / "copilot-runtime")
    (runtime / "copilot-runtime").chmod(0o700)
    (runtime / "runtime.node").write_bytes(b"")
    subprocess.run([str(executable)], check=True)
