#!/usr/bin/env python3
"""Assemble a deterministic native add-on bundle (issue 3425).

Mirrors build/wasm_plugins/assemble_bundle.py but ships per-architecture native
binaries (mode 0755) alongside the manifest files (mode 0644), and records a
per-arch artifacts[] list (os/arch/archive_path/sha256) in metadata.json. The zip
is deterministic: entries sorted by archive path, timestamps zeroed to 1980.
"""

import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-out", required=True)
    parser.add_argument("--sha-out", required=True)
    parser.add_argument("--metadata-out", required=True)
    parser.add_argument("--addon-id", required=True)
    parser.add_argument("--repository-name", required=True)
    parser.add_argument("--artifact-type", required=True)
    parser.add_argument("--bundle-media-type", required=True)
    parser.add_argument("--upload-signature-media-type", required=True)
    # Manifest/config files (mode 0644): archive_path=source_path
    parser.add_argument("--entry", action="append", default=[])
    # Per-arch executables (mode 0755): os/arch=archive_path=source_path
    parser.add_argument("--artifact", action="append", default=[])
    return parser.parse_args()


def normalize_entries(raw_entries):
    members = []
    for raw in raw_entries:
        archive_path, sep, source_path = raw.partition("=")
        if not sep:
            raise ValueError(f"invalid --entry value: {raw}")
        members.append((archive_path, Path(source_path), False))
    return members


def normalize_artifacts(raw_artifacts):
    artifacts = []
    for raw in raw_artifacts:
        platform, sep, rest = raw.partition("=")
        if not sep:
            raise ValueError(f"invalid --artifact value: {raw}")
        archive_path, sep2, source_path = rest.partition("=")
        if not sep2:
            raise ValueError(f"invalid --artifact value: {raw}")
        os_name, _, arch = platform.partition("/")
        artifacts.append((os_name, arch, archive_path, Path(source_path)))
    return artifacts


def write_zip(bundle_path: Path, members):
    bundle_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(bundle_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for archive_path, source_path, executable in sorted(members, key=lambda m: m[0]):
            data = source_path.read_bytes()
            info = zipfile.ZipInfo(archive_path)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.date_time = (1980, 1, 1, 0, 0, 0)
            info.external_attr = (0o755 if executable else 0o644) << 16
            zf.writestr(info, data)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def manifest_metadata(members):
    manifest_path = next(
        (source_path for archive_path, source_path, _ in members if archive_path == "addon.yaml"),
        None,
    )
    if manifest_path is None:
        return {}

    metadata = {}
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        if line.startswith((" ", "\t", "-", "#")) or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip().strip("\"'")
        if key in {"id", "name", "version"} and value:
            metadata[key] = value
    return metadata


def main():
    args = parse_args()
    bundle_path = Path(args.bundle_out)
    sha_path = Path(args.sha_out)
    metadata_path = Path(args.metadata_out)

    file_members = normalize_entries(args.entry)
    artifacts = normalize_artifacts(args.artifact)
    binary_members = [
        (archive_path, source_path, True)
        for (_os, _arch, archive_path, source_path) in artifacts
    ]
    members = file_members + binary_members

    write_zip(bundle_path, members)
    digest = sha256_file(bundle_path)
    manifest = manifest_metadata(members)

    sha_path.parent.mkdir(parents=True, exist_ok=True)
    sha_path.write_text(f"{digest}\n", encoding="utf-8")

    artifact_meta = sorted(
        [
            {
                "os": os_name,
                "arch": arch,
                "archive_path": archive_path,
                "sha256": sha256_bytes(source_path.read_bytes()),
            }
            for (os_name, arch, archive_path, source_path) in artifacts
        ],
        key=lambda item: (item["os"], item["arch"]),
    )

    metadata = {
        "addon_id": args.addon_id,
        "name": manifest.get("name"),
        "version": manifest.get("version"),
        "repository_name": args.repository_name,
        "artifact_type": args.artifact_type,
        "bundle_media_type": args.bundle_media_type,
        "upload_signature_media_type": args.upload_signature_media_type,
        "bundle_file": bundle_path.name,
        "sha256_file": sha_path.name,
        "entries": sorted(
            [
                {"archive_path": archive_path, "source_path": str(source_path)}
                for archive_path, source_path, _ in members
            ],
            key=lambda item: item["archive_path"],
        ),
        "artifacts": artifact_meta,
    }
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
