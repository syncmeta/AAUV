#!/usr/bin/env python3
import argparse
import base64
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
from zipfile import ZipFile


ROOT = Path(__file__).resolve().parent.parent
LOCK = "AAUV.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SOURCE_FILES = (
    ".gitignore", "LICENSE", "README.md", "THIRD_PARTY.md", "project.yml", "Info.plist",
    "ShareInfo.plist", "TunnelInfo.plist", "AAUV-App-iOS.entitlements",
    "AAUV-App-macOS.entitlements", "AAUV-Share-iOS.entitlements", "AAUV-iOS.entitlements", LOCK,
)
SOURCE_DIRS = {
    "Sources": {".swift"}, "Share": {".swift", ".strings"}, "Tunnel": {".swift"}, "Tests": {".swift", ".py"},
    "Scripts": {".sh", ".py"}, "Resources": {".json", ".png", ".strings", ".svg", ".txt"},
    "Licenses": {".txt"},
    "copilot/nativeauth": {".go"},
}
OFFLINE_GO = dict(os.environ, GOPROXY="off", GOSUMDB="off", GOWORK="off", GOTOOLCHAIN="local",
                  GOCACHE=str(ROOT / "build/go-cache"))


def run(*args, cwd=ROOT, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env)


def app_files():
    files = [ROOT / name for name in SOURCE_FILES]
    for directory, extensions in SOURCE_DIRS.items():
        files.extend(file for file in (ROOT / directory).rglob("*")
                     if file.suffix in extensions and not any(part.startswith(".") for part in file.relative_to(ROOT).parts))
    for directory in ("core", "copilot"):
        files.extend(file for file in (ROOT / directory).iterdir()
                     if file.suffix in {".go", ".c", ".h"} or file.name in {"go.mod", "go.sum"})
    for file in sorted(files):
        if file.is_symlink() or not file.is_file() or not file.resolve().is_relative_to(ROOT):
            raise ValueError(f"Expected a regular project source file at {file.relative_to(ROOT)}")
        yield file


def normalized(info):
    info.uid = info.gid = info.mtime = 0
    info.uname = info.gname = ""
    info.mode = 0o755 if info.mode & 0o111 else 0o644
    return info


def add_file(archive, path, name):
    archive.add(path, f"AAUV-source/{name}", recursive=False, filter=normalized)


def add_bytes(archive, name, data):
    info = tarfile.TarInfo(f"AAUV-source/{name}")
    info.size = len(data)
    archive.addfile(info, io.BytesIO(data))


def git_source(archive, name, checkout, pin):
    if run("git", "-C", checkout, "rev-parse", "HEAD").decode().strip() != pin["revision"]:
        raise ValueError(f"{name} checkout is not at the pinned revision")
    data = run("git", "-C", checkout, "archive", "--format=tar.gz", f"--prefix={name}/", pin["revision"])
    path = f"ThirdPartySources/{name}.tar.gz"
    add_bytes(archive, path, data)
    return {**pin, "archive": path, "sha256": hashlib.sha256(data).hexdigest()}


def swift_mirror(archive, name, checkout, pin):
    for tag in (pin["version"], f"v{pin['version']}"):
        ref = subprocess.run(["git", "-C", checkout, "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}"],
                             capture_output=True, check=False)
        if ref.returncode == 0 and ref.stdout.decode().strip() == pin["revision"]:
            break
    else:
        raise ValueError(f"No tag for the pinned Swift package {name}")

    destination = f"ThirdPartySources/swift-mirrors/{name}.git"
    with tempfile.TemporaryDirectory(prefix="swift-mirror-", dir=ROOT / "build") as folder:
        mirror = Path(folder) / "mirror.git"
        run("git", "clone", "--quiet", "--bare", "--depth", "1", "--single-branch", "--branch", tag,
            checkout.resolve().as_uri(), mirror)
        add_bytes(archive, f"{destination}/config", b"[core]\n\trepositoryformatversion = 0\n\tbare = true\n")
        for file in sorted(mirror.rglob("*")):
            relative = file.relative_to(mirror)
            if relative.parts[0] in {"HEAD", "shallow", "packed-refs", "objects", "refs"}:
                add_file(archive, file, f"{destination}/{relative}")
    return {"path": destination, "tag": tag}


def go_packages(directory, package, os_name, arch, cgo, tags, env):
    fmt = "{{with .Module}}{{if not .Main}}{{.Path}}@{{.Version}}{{if .Replace}}!replace{{end}}{{end}}{{end}}"
    target_env = dict(env, GOOS=os_name, GOARCH=arch, CGO_ENABLED=str(cgo))
    output = run("go", "list", "-mod=readonly", "-deps", "-tags", tags, "-f", fmt, package,
                 cwd=directory, env=target_env)
    return set(output.decode().split())


def tool_modules():
    expected = run("go", "list", "-mod=readonly", "-m", "-f", "{{.Version}}",
                   "github.com/sagernet/gomobile", cwd=ROOT / "core", env=OFFLINE_GO).decode().strip()
    modules = {}
    for name in ("gomobile", "gobind"):
        output = run("go", "version", "-m", ROOT / "build/tools/bin" / name).decode()
        pinned = False
        for line in output.splitlines():
            fields = line.split()
            if fields and fields[0] in {"mod", "dep"}:
                modules[f"{fields[1]}@{fields[2]}"] = fields[3]
                if fields[:3] == ["mod", "github.com/sagernet/gomobile", expected]:
                    pinned = True
        if not pinned:
            raise ValueError(f"Build the pinned {name} tool first")
    return modules


def go_zip_sum(source):
    # The Go module h1 checksum hashes each file and its full name in sorted order.
    summary = hashlib.sha256()
    with ZipFile(source) as module:
        for name in sorted(module.namelist()):
            digest = hashlib.sha256(module.read(name)).hexdigest()
            summary.update(f"{digest}  {name}\n".encode())
    return "h1:" + base64.b64encode(summary.digest()).decode()


def escape_go(text):
    return "".join("!" + letter.lower() if "A" <= letter <= "Z" else letter for letter in text)


def go_cache(env):
    return Path(run("go", "env", "GOMODCACHE", env=env).decode().strip()) / "cache/download"


def go_proxy_path(key):
    module, version = key.rsplit("@", 1)
    return f"{escape_go(module)}/@v/{escape_go(version)}"


def add_go_metadata(archive, key, cache, mod_sums, metadata):
    if key in metadata:
        return
    proxy_path = go_proxy_path(key)
    mod = cache / (proxy_path + ".mod")
    if not mod.is_file():
        return
    mod_hash = hashlib.sha256(mod.read_bytes()).hexdigest()
    checksum = "h1:" + base64.b64encode(hashlib.sha256(f"{mod_hash}  go.mod\n".encode()).digest()).decode()
    if key in mod_sums and checksum != mod_sums[key]:
        raise ValueError(f"Go module metadata checksum failed for {key}")
    version = key.rsplit("@", 1)[1]
    info = {"Version": version}
    cached_info = cache / (proxy_path + ".info")
    if cached_info.is_file():
        existing = json.loads(cached_info.read_text())
        if existing["Version"] != version:
            raise ValueError(f"Go module version metadata failed for {key}")
        if "Time" in existing:
            info["Time"] = existing["Time"]
    else:
        pseudo_time = re.search(r"(\d{4})(\d\d)(\d\d)(\d\d)(\d\d)(\d\d)-[0-9a-f]{12}(?:\+incompatible)?$", version)
        if pseudo_time:
            info["Time"] = "%s-%s-%sT%s:%s:%sZ" % pseudo_time.groups()
    info_bytes = (json.dumps(info, sort_keys=True) + "\n").encode()
    prefix = f"ThirdPartySources/go-proxy/{proxy_path}"
    add_file(archive, mod, prefix + ".mod")
    add_bytes(archive, prefix + ".info", info_bytes)
    metadata[key] = {
        "mod": {"archive": prefix + ".mod", "sha256": mod_hash},
        "info": {"archive": prefix + ".info", "sha256": hashlib.sha256(info_bytes).hexdigest()},
    }


def add_go_modules(archive, modules, env, expected, mod_sums, included, metadata):
    cache = go_cache(env)
    for key in sorted(modules - included.keys()):
        if key not in expected:
            raise ValueError(f"Missing a pinned Go checksum for {key}")
        proxy_path = go_proxy_path(key)
        source = cache / (proxy_path + ".zip")
        if not source.is_file():
            raise ValueError(f"Missing cached source for {key}")
        if go_zip_sum(source) != expected[key]:
            raise ValueError(f"Go source checksum failed for {key}")
        add_go_metadata(archive, key, cache, mod_sums, metadata)
        if key not in metadata:
            raise ValueError(f"Missing cached go.mod for {key}")
        path = f"ThirdPartySources/go-proxy/{proxy_path}.zip"
        add_file(archive, source, path)
        included[key] = {"archive": path, "sum": expected[key], "sha256": hashlib.sha256(source.read_bytes()).hexdigest()}


def assemble(archive):
    for file in app_files():
        add_file(archive, file, file.relative_to(ROOT))

    version, revision, repository, tags, ios_tags = run("sh", "Scripts/build-proxy.sh", "source-info").decode().splitlines()
    sing_box = ROOT / "build/upstream/sing-box"
    sources = {
        "sing-box": git_source(archive, "sing-box", sing_box,
                               {"version": version, "revision": revision, "location": repository})
    }
    checkouts = {item.name.lower(): item for item in (ROOT / "build/markdown-packages/checkouts").iterdir()}
    for pin in json.loads((ROOT / LOCK).read_text())["pins"]:
        identity = pin["identity"]
        version = {**pin["state"], "location": pin["location"]}
        sources[identity] = git_source(archive, identity, checkouts[identity], version)
        sources[identity]["mirror"] = swift_mirror(archive, identity, checkouts[identity], version)

    sqlite_name, sqlite_url, sqlite_hash = run("sh", "Scripts/prepare-android-sqlite.sh", "source-info").decode().splitlines()
    sqlite = ROOT / "build/upstream" / sqlite_name
    if hashlib.sha3_256(sqlite.read_bytes()).hexdigest() != sqlite_hash:
        raise ValueError("Android SQLite source archive failed its SHA3-256 check")
    sqlite_path = f"ThirdPartySources/{sqlite_name}"
    add_file(archive, sqlite, sqlite_path)
    sources["android-sqlite"] = {"archive": sqlite_path, "location": sqlite_url, "sha3_256": sqlite_hash}

    copilot_env = dict(OFFLINE_GO, GOMODCACHE=os.environ.get("GOMODCACHE", str(ROOT / "build/copilot-module-cache")))
    tools = tool_modules()
    expected = dict(tools)
    mod_sums = {}
    for lock in (ROOT / "core/go.sum", ROOT / "copilot/go.sum", sing_box / "go.sum"):
        for line in lock.read_text().splitlines():
            module, version, checksum = line.split()
            if version.endswith("/go.mod"):
                mod_sums[f"{module}@{version.removesuffix('/go.mod')}"] = checksum
            else:
                expected[f"{module}@{version}"] = checksum
    targets = {"gomobile-tools": set(tools)}
    for arch in ("arm64", "amd64"):
        targets[f"sing-box-macos-{arch}"] = go_packages(sing_box, "./cmd/sing-box", "darwin", arch, 0, tags, OFFLINE_GO)
        targets[f"libbox-iossimulator-{arch}"] = go_packages(sing_box, "./experimental/libbox", "ios", arch, 1,
                                                           f"{ios_tags},ios,iossimulator", OFFLINE_GO)
        targets[f"copilot-macos-{arch}"] = go_packages(ROOT / "copilot", ".", "darwin", arch, 0, "", copilot_env)
    targets["libbox-ios-arm64"] = go_packages(sing_box, "./experimental/libbox", "ios", "arm64", 1,
                                             f"{ios_tags},ios", OFFLINE_GO)
    included = {}
    metadata = {}
    for target, modules in targets.items():
        env = copilot_env if target.startswith("copilot-") else OFFLINE_GO
        add_go_modules(archive, modules, env, expected, mod_sums, included, metadata)
    for env in (OFFLINE_GO, copilot_env):
        cache = go_cache(env)
        for key in sorted(mod_sums):
            add_go_metadata(archive, key, cache, mod_sums, metadata)
    versions = {}
    for key in metadata:
        module, version = key.rsplit("@", 1)
        versions.setdefault(escape_go(module), set()).add(version)
    for module, available in sorted(versions.items()):
        add_bytes(archive, f"ThirdPartySources/go-proxy/{module}/@v/list", ("\n".join(sorted(available)) + "\n").encode())
    manifest = {
        "source_archives": sources,
        "go_modules": included,
        "go_metadata": metadata,
        "go_targets": {target: sorted(modules) for target, modules in targets.items()},
    }
    add_bytes(archive, "ThirdPartySources/inventory.json", (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode())


def main():
    parser = argparse.ArgumentParser(description="Pack AAUV source and cached build dependency sources for review.")
    parser.add_argument("output", nargs="?", type=Path, default=ROOT / "build/dist/AAUV-source.tar.gz")
    output = parser.parse_args().output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".aauv-source-", delete=False) as temp:
        stage = Path(temp.name)
        try:
            with gzip.GzipFile(filename="", mode="wb", fileobj=temp, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w|") as archive:
                    assemble(archive)
            temp.close()
            stage.replace(output)
        finally:
            stage.unlink(missing_ok=True)
    print(output)


if __name__ == "__main__":
    main()
