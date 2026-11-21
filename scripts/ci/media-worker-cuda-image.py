#!/usr/bin/env python3
"""Verify a CUDA media-worker build bundle and assemble its arm64 image with crane.

The bundle comes from `scripts/build-media-worker-cuda.sh build` on the credential-less
arm64 runner. This tool runs on the signing runner, which has no Docker daemon:

    verify <bundle> --sums-sha256 <hex>   check the bundle against the build job's output
    push <bundle> --sums-sha256 <hex> --digest-file <path>
                                          verify, write one deterministic layer, append it
                                          to the pinned Ubuntu base with `crane mutate`,
                                          check what the registry now holds, and write the
                                          pushed digest to <path>

The image is the CPU image's base (the ubuntu:24.04 index MODULE.bazel pins) plus one
layer: the binary, the CUDA runtime libraries the build collected from the pinned NVIDIA
devel image, the pinned Mozilla CA bundle, and the serviceradar (10001) user. libcuda.so.1
is not shipped: the NVIDIA container runtime injects it from the host driver.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

# Same pins as MODULE.bazel `ubuntu_noble` and `mozilla_ca_bundle`
# (build/contracts/media_worker_cuda_workflow_test.py keeps them in step).
BASE_INDEX = ("registry.carverauto.dev/mirror/library/ubuntu@"
              "sha256:d1e2e92c075e5ca139d51a140fff46f84315c0fdce203eab2807c7e495eff4f9")
CA_BUNDLE_URL = "https://curl.se/ca/cacert-2026-07-16.pem"
CA_BUNDLE_SHA256 = "3ff344e30b9b1ed2971044eabb438a08f2e2245ddb5f8ab1a3ad8b63ab4eaf91"

BINARY = "serviceradar-media-worker"
REQUIRED_LIBRARIES = ("libcublas.so.13", "libcublasLt.so.13", "libcurand.so.10",
                      "libnvrtc.so.13", "libcudart.so.13")
LIBRARY_NAME = re.compile(r"lib/lib[A-Za-z0-9_+.-]+\.so\.[0-9.]+")
LIB_DIR = "usr/local/lib/serviceradar-cuda"
CUDA_CACHE_DIR = "var/cache/serviceradar-media-worker/cuda"
UID = GID = 10001

IMAGE_ENV = {
    "LD_LIBRARY_PATH": "/" + LIB_DIR,
    "SSL_CERT_FILE": "/etc/ssl/certs/ca-certificates.crt",
    "HOME": "/home/serviceradar",
    # Point the PTX JIT cache at a path the chart can mount a writable volume on.
    # The worker logs, and keeps running, when it is not writable.
    "CUDA_CACHE_PATH": "/" + CUDA_CACHE_DIR,
    "CUDA_CACHE_MAXSIZE": "1073741824",
    # Capabilities only. NVIDIA_VISIBLE_DEVICES is left to the device plugin, so a pod
    # without a GPU allocation is never handed every GPU on the node.
    "NVIDIA_DRIVER_CAPABILITIES": "compute,utility",
}

# Same accounts as //docker/images:serviceradar_user_layer.
PASSWD = ("root:x:0:0:root:/root:/bin/sh\n"
          "serviceradar:x:10001:10001:serviceradar:/home/serviceradar:/bin/sh\n")
GROUP = "root:x:0:\nserviceradar:x:10001:\n"
ROOT_DIRS = ("etc/serviceradar/certs", "etc/serviceradar/creds",
             "var/lib/serviceradar-media-worker/models", "var/log/serviceradar")
SERVICE_DIRS = ("home/serviceradar", "var/lib/serviceradar", CUDA_CACHE_DIR)


class BundleError(Exception):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verify(bundle, sums_sha256, commit):
    """Return {relative path: sha256} after proving the bundle is what the build produced."""
    bundle = Path(bundle)
    if not re.fullmatch(r"[0-9a-f]{64}", sums_sha256 or ""):
        raise BundleError("expected SHA256SUMS digest must be 64 lowercase hex characters")
    sums = bundle / "SHA256SUMS"
    if sha256_file(sums) != sums_sha256:
        raise BundleError("SHA256SUMS does not match the digest the build job reported")
    listed = {}
    for line in sums.read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (\S+)", line)
        if not match or match[2] in listed:
            raise BundleError(f"malformed SHA256SUMS line: {line!r}")
        listed[match[2]] = match[1]
    present = {str(p.relative_to(bundle)) for p in bundle.rglob("*") if p.is_file()} - {"SHA256SUMS"}
    if present != set(listed):
        raise BundleError(f"bundle files differ from SHA256SUMS: {sorted(present ^ set(listed))}")
    for name in listed:
        if name not in (BINARY, "manifest.json") and not LIBRARY_NAME.fullmatch(name):
            raise BundleError(f"unexpected file in bundle: {name}")
    missing = [lib for lib in REQUIRED_LIBRARIES if f"lib/{lib}" not in listed]
    if BINARY not in listed or missing:
        raise BundleError(f"bundle lacks the binary or CUDA libraries: {missing}")
    for name, expected in listed.items():
        if sha256_file(bundle / name) != expected:
            raise BundleError(f"{name} does not match SHA256SUMS")
    manifest = json.loads((bundle / "manifest.json").read_text())
    if not re.fullmatch(r"[0-9a-f]{40}", commit or "") or manifest.get("commit") != commit:
        raise BundleError("manifest commit must match the expected full commit SHA")
    if manifest.get("cuda_compute_cap") != "121":
        raise BundleError("manifest must target CUDA compute capability 121")
    if manifest.get("binary", {}).get("sha256") != listed[BINARY]:
        raise BundleError("manifest.json names a different binary")
    return listed


def fetch_ca_bundle():
    with urllib.request.urlopen(CA_BUNDLE_URL, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != CA_BUNDLE_SHA256:
        raise BundleError("CA bundle checksum mismatch")
    return data


def write_layer(bundle, listed, ca_bundle, out):
    """Write a reproducible rootfs tar: fixed order, mtimes, owners and modes."""
    entries = {}  # path -> (kind, source, mode, owner)

    def directory(path, owner):
        parts = path.split("/")
        for depth in range(1, len(parts)):
            entries.setdefault("/".join(parts[:depth]), ("dir", None, 0o755, 0))
        entries[path] = ("dir", None, 0o755, owner)

    for path in ROOT_DIRS + (LIB_DIR, "usr/local/bin", "etc/ssl/certs"):
        directory(path, 0)
    for path in SERVICE_DIRS:
        directory(path, UID)
    entries["usr/local/bin/" + BINARY] = ("file", Path(bundle) / BINARY, 0o755, 0)
    for name in listed:
        if name.startswith("lib/"):
            entries[f"{LIB_DIR}/{name[4:]}"] = ("file", Path(bundle) / name, 0o644, 0)
    entries["etc/ssl/certs/ca-certificates.crt"] = ("bytes", ca_bundle, 0o644, 0)
    entries["etc/passwd"] = ("bytes", PASSWD.encode(), 0o644, 0)
    entries["etc/group"] = ("bytes", GROUP.encode(), 0o644, 0)

    with tarfile.open(out, "w", format=tarfile.PAX_FORMAT) as archive:
        for path in sorted(entries):
            kind, source, mode, owner = entries[path]
            info = tarfile.TarInfo(path)
            info.mode, info.uid, info.gid, info.mtime = mode, owner, owner, 0
            info.uname = info.gname = ""
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
            elif kind == "bytes":
                info.size = len(source)
                archive.addfile(info, io.BytesIO(source))
            else:
                info.size = source.stat().st_size
                with open(source, "rb") as handle:
                    archive.addfile(info, handle)


def crane(*args):
    return subprocess.check_output(["crane", *args], text=True).strip()


def push(bundle, sums_sha256, commit):
    listed = verify(bundle, sums_sha256, commit)
    repository = "registry.carverauto.dev/serviceradar-builds/serviceradar-media-worker-cuda"
    tag = f"{repository}:sha-{commit}"
    with tempfile.TemporaryDirectory(prefix="media-worker-cuda-") as work:
        layer = Path(work) / "layer.tar"
        write_layer(bundle, listed, fetch_ca_bundle(), layer)
        layer_digest = "sha256:" + sha256_file(layer)
        base_digest = crane("digest", "--platform", "linux/arm64", BASE_INDEX)
        base = BASE_INDEX.split("@", 1)[0] + "@" + base_digest
        command = ["mutate", base, "--append", str(layer), "--tag", tag,
                   "--entrypoint", "/usr/local/bin/" + BINARY,
                   "--user", f"{UID}:{GID}", "--workdir", "/var/lib/serviceradar",
                   "--exposed-ports", "8096/tcp",
                   "--label", "org.opencontainers.image.title=serviceradar-media-worker-cuda",
                   "--label", "org.opencontainers.image.source=https://github.com/carverauto/serviceradar",
                   "--label", f"org.opencontainers.image.revision={commit}"]
        for key, value in IMAGE_ENV.items():
            command += ["--env", f"{key}={value}"]
        crane(*command)
    # Check the registry copy, not what crane says it sent.
    digest = crane("digest", tag)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise BundleError(f"invalid pushed digest: {digest}")
    config = json.loads(crane("config", f"{repository}@{digest}"))
    if config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.revision") != commit:
        raise BundleError("pushed image revision does not match the bundle commit")
    if config.get("architecture") != "arm64" or config.get("os") != "linux":
        raise BundleError(f"pushed image is {config.get('os')}/{config.get('architecture')}, not linux/arm64")
    if config.get("config", {}).get("User") != f"{UID}:{GID}":
        raise BundleError("pushed image does not run as the serviceradar user")
    if config.get("rootfs", {}).get("diff_ids", [None])[-1] != layer_digest:
        raise BundleError("pushed image's top layer is not the layer assembled from the bundle")
    return digest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="action", required=True)
    for name in ("verify", "push"):
        command = commands.add_parser(name)
        command.add_argument("bundle")
        command.add_argument("--sums-sha256", required=True)
    commands.choices["push"].add_argument("--digest-file", required=True)
    args = parser.parse_args()
    commit = os.environ.get("GITHUB_SHA", "")
    try:
        if args.action == "verify":
            verify(args.bundle, args.sums_sha256, commit)
            print(f"bundle {args.bundle} verified")
        else:
            digest = push(args.bundle, args.sums_sha256, commit)
            Path(args.digest_file).write_text(digest + "\n")
            print(f"pushed sha-{commit} as {digest}")
    except (BundleError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"media-worker CUDA image: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
