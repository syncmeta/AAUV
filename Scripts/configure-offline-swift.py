#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess


root = Path(__file__).resolve().parent.parent
workspace = root / "AAUV.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
inventory = json.loads((root / "ThirdPartySources/inventory.json").read_text())
lock = json.loads((workspace / "Package.resolved").read_text())
mirrors = []
for pin in lock["pins"]:
    source = inventory["source_archives"][pin["identity"]]
    mirror = source["mirror"]
    path = (root / mirror["path"]).resolve()
    if not path.is_relative_to(root / "ThirdPartySources/swift-mirrors"):
        raise SystemExit("Unexpected Swift mirror location")
    revision = subprocess.check_output(
        ["git", "-C", path, "rev-parse", "--verify", f"refs/tags/{mirror['tag']}^{{commit}}"], text=True
    ).strip()
    if revision != pin["state"]["revision"]:
        raise SystemExit(f"Swift mirror revision does not match Package.resolved for {pin['identity']}")
    mirrors.append({"original": pin["location"], "mirror": path.as_uri()})

settings = {"version": 1, "object": mirrors}
config = workspace / "configuration/mirrors.json"
config.parent.mkdir(parents=True, exist_ok=True)
if config.exists() and json.loads(config.read_text()) != settings:
    raise SystemExit(f"Existing SwiftPM mirror configuration at {config}")
config.write_text(json.dumps(settings, indent=2) + "\n")
print(config)
