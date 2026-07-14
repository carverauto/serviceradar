#!/usr/bin/env python3

import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile


PLUGIN_ID_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-out", required=True)
    parser.add_argument("--sha-out", required=True)
    parser.add_argument("--metadata-out", required=True)
    parser.add_argument("--plugin-id")
    parser.add_argument("--repository-name")
    parser.add_argument("--derive-from-manifest", action="store_true")
    parser.add_argument("--source-commit")
    parser.add_argument("--source-committed-at")
    parser.add_argument("--artifact-type", required=True)
    parser.add_argument("--bundle-media-type", required=True)
    parser.add_argument("--upload-signature-media-type", required=True)
    parser.add_argument("--entry", action="append", default=[])
    return parser.parse_args()


def normalize_entries(raw_entries):
    entries = []
    archive_paths = set()
    for raw in raw_entries:
        archive_path, sep, source_path = raw.partition("=")
        if not sep:
            raise ValueError(f"invalid --entry value: {raw}")
        if not archive_path or archive_path.startswith("/") or ".." in Path(archive_path).parts:
            raise ValueError(f"unsafe bundle archive path: {archive_path}")
        if archive_path in archive_paths:
            raise ValueError(f"duplicate bundle archive path: {archive_path}")

        source = Path(source_path)
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"bundle source must be a regular file: {source}")

        archive_paths.add(archive_path)
        entries.append((archive_path, source))
    return sorted(entries, key=lambda item: item[0])


def write_zip(bundle_path: Path, entries):
    bundle_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(bundle_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for archive_path, source_path in entries:
            data = source_path.read_bytes()
            info = zipfile.ZipInfo(archive_path)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.date_time = (1980, 1, 1, 0, 0, 0)
            info.external_attr = 0o644 << 16
            zf.writestr(info, data)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def manifest_metadata(entries):
    manifest_path = next((source_path for archive_path, source_path in entries if archive_path == "plugin.yaml"), None)
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
    entries = normalize_entries(args.entry)

    manifest = manifest_metadata(entries)
    if args.derive_from_manifest:
        missing = {"id", "name", "version"} - manifest.keys()
        if missing:
            raise ValueError(f"plugin.yaml is missing: {', '.join(sorted(missing))}")
        plugin_id = manifest["id"]
        repository_name = f"wasm-plugin-{plugin_id}"
    else:
        if not args.plugin_id or not args.repository_name:
            raise ValueError("--plugin-id and --repository-name are required unless deriving from the manifest")
        plugin_id = args.plugin_id
        repository_name = args.repository_name

    if not PLUGIN_ID_RE.fullmatch(plugin_id):
        raise ValueError(f"invalid plugin id: {plugin_id}")
    if args.source_commit and not COMMIT_RE.fullmatch(args.source_commit):
        raise ValueError("--source-commit must be a lowercase 40-character Git commit")

    write_zip(bundle_path, entries)
    digest = sha256_file(bundle_path)

    sha_path.parent.mkdir(parents=True, exist_ok=True)
    sha_path.write_text(f"{digest}\n", encoding="utf-8")

    metadata = {
        "plugin_id": plugin_id,
        "plugin_name": manifest.get("name"),
        "plugin_version": manifest.get("version"),
        "repository_name": repository_name,
        "artifact_type": args.artifact_type,
        "bundle_media_type": args.bundle_media_type,
        "upload_signature_media_type": args.upload_signature_media_type,
        "bundle_file": bundle_path.name,
        "sha256": digest,
        "sha256_file": sha_path.name,
        "entries": [
            {
                "archive_path": archive_path,
                "source_path": str(source_path),
            }
            for archive_path, source_path in entries
        ],
    }
    if args.source_commit:
        metadata["source_commit"] = args.source_commit
    if args.source_committed_at:
        metadata["source_committed_at"] = args.source_committed_at
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
