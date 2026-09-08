#!/usr/bin/env python3

import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import sys
import zipfile


ARTIFACT_TYPE = "application/vnd.serviceradar.wasm-plugin.bundle.v1+zip"
BUNDLE_MEDIA_TYPE = "application/zip"
UPLOAD_SIGNATURE_MEDIA_TYPE = "application/vnd.serviceradar.wasm-plugin.upload-signature.v1+json"
REQUIRED_ENTRIES = {"config.schema.json", "plugin.wasm", "plugin.yaml"}
ENTRY_LIMITS = {
    "config.schema.json": 4 * 1024 * 1024,
    "display_contract.json": 4 * 1024 * 1024,
    "plugin.wasm": 64 * 1024 * 1024,
    "plugin.yaml": 1024 * 1024,
}
MAX_BUNDLE_BYTES = 64 * 1024 * 1024
MAX_BUNDLE_ENTRIES = 128
MAX_RESOURCE_BYTES = 4 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 72 * 1024 * 1024
MAX_METADATA_BYTES = 1024 * 1024
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
PLUGIN_ID_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
VERSION_RE = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z][0-9A-Za-z.-]*)?$")


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", required=True)
    parser.add_argument("--bundle", required=True)
    parser.add_argument("--plugin-id", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-commit", required=True)
    return parser.parse_args()


def require_regular_file(path: Path, limit: int):
    file_stat = path.lstat()
    if not stat.S_ISREG(file_stat.st_mode):
        raise ValueError(f"not a regular file: {path}")
    if file_stat.st_size <= 0 or file_stat.st_size > limit:
        raise ValueError(f"file size is outside the allowed range: {path}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_bounded(archive: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int) -> bytes:
    if info.file_size <= 0 or info.file_size > limit:
        raise ValueError(f"bundle entry size is outside the allowed range: {info.filename}")

    chunks = []
    total = 0
    with archive.open(info, "r") as handle:
        while chunk := handle.read(min(1024 * 1024, limit + 1 - total)):
            total += len(chunk)
            if total > limit:
                raise ValueError(f"bundle entry exceeds its size limit: {info.filename}")
            chunks.append(chunk)
    if total != info.file_size:
        raise ValueError(f"bundle entry size changed while reading: {info.filename}")
    return b"".join(chunks)


def resource_limit(name: str) -> int:
    if name in ENTRY_LIMITS:
        return ENTRY_LIMITS[name]
    if name.startswith("docs/") and Path(name).suffix.lower() in {".md", ".txt"}:
        return MAX_RESOURCE_BYTES
    if name.startswith(("display/", "schemas/")) and Path(name).suffix.lower() == ".json":
        return MAX_RESOURCE_BYTES
    raise ValueError(f"unsupported bundle entry: {name}")


def validate_entry_name(name: str):
    path = Path(name)
    if (
        not name
        or name.startswith("/")
        or "\\" in name
        or any(part in {"", ".", ".."} for part in path.parts)
    ):
        raise ValueError(f"unsafe bundle entry: {name}")
    resource_limit(name)


def simple_manifest_fields(raw: bytes):
    fields = {}
    for line in raw.decode("utf-8").splitlines():
        if not line or line.startswith((" ", "\t", "-", "#")) or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if key not in {"id", "version"}:
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        if key in fields:
            raise ValueError(f"plugin.yaml contains duplicate {key}")
        fields[key] = value
    return fields


def validate_metadata(metadata_path: Path, bundle_path: Path, plugin_id: str, version: str, commit: str):
    require_regular_file(metadata_path, MAX_METADATA_BYTES)
    require_regular_file(bundle_path, MAX_BUNDLE_BYTES)

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    expected_bundle = f"{plugin_id}-{version}.zip"
    expected = {
        "artifact_type": ARTIFACT_TYPE,
        "bundle_file": expected_bundle,
        "bundle_media_type": BUNDLE_MEDIA_TYPE,
        "plugin_id": plugin_id,
        "plugin_version": version,
        "repository_name": f"wasm-plugin-{plugin_id}",
        "source_commit": commit,
        "upload_signature_media_type": UPLOAD_SIGNATURE_MEDIA_TYPE,
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(f"metadata {key} does not match the protected release input")
    if bundle_path.name != expected_bundle:
        raise ValueError("bundle path does not match the protected release input")

    digest = metadata.get("sha256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("metadata sha256 is invalid")
    if sha256_file(bundle_path) != digest:
        raise ValueError("bundle checksum does not match metadata")

    entries = metadata.get("entries")
    if not isinstance(entries, list):
        raise ValueError("metadata entries must be an array")
    archive_paths = [entry.get("archive_path") for entry in entries if isinstance(entry, dict)]
    if len(archive_paths) != len(entries) or len(archive_paths) > MAX_BUNDLE_ENTRIES:
        raise ValueError("metadata entries are invalid")
    if len(set(archive_paths)) != len(archive_paths):
        raise ValueError("metadata declares duplicate bundle entries")
    if not REQUIRED_ENTRIES.issubset(archive_paths):
        raise ValueError("metadata is missing a required external bundle entry")
    for name in archive_paths:
        if not isinstance(name, str):
            raise ValueError("metadata archive paths must be strings")
        validate_entry_name(name)


def validate_archive(bundle_path: Path, plugin_id: str, version: str):
    with zipfile.ZipFile(bundle_path, "r") as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) > MAX_BUNDLE_ENTRIES or len(set(names)) != len(names):
            raise ValueError("bundle contains too many or duplicate entries")
        if not REQUIRED_ENTRIES.issubset(names):
            raise ValueError("bundle is missing a required external plugin entry")

        contents = {}
        total_uncompressed = 0
        for info in infos:
            mode = info.external_attr >> 16
            validate_entry_name(info.filename)
            if info.is_dir() or stat.S_ISLNK(mode):
                raise ValueError(f"unsafe bundle entry: {info.filename}")
            total_uncompressed += info.file_size
            if total_uncompressed > MAX_UNCOMPRESSED_BYTES:
                raise ValueError("bundle uncompressed size exceeds its limit")
            contents[info.filename] = read_bounded(archive, info, resource_limit(info.filename))

    fields = simple_manifest_fields(contents["plugin.yaml"])
    if fields != {"id": plugin_id, "version": version}:
        raise ValueError("plugin.yaml identity does not match the protected release input")
    if not contents["plugin.wasm"].startswith(b"\x00asm"):
        raise ValueError("plugin.wasm does not have a Wasm module header")
    schema = json.loads(contents["config.schema.json"])
    if not isinstance(schema, dict):
        raise ValueError("config.schema.json must contain a JSON object")


def main():
    args = parse_args()
    if not PLUGIN_ID_RE.fullmatch(args.plugin_id):
        raise ValueError("invalid plugin id")
    if not VERSION_RE.fullmatch(args.version):
        raise ValueError("invalid plugin version")
    if not COMMIT_RE.fullmatch(args.source_commit):
        raise ValueError("invalid source commit")

    metadata_path = Path(args.metadata)
    bundle_path = Path(args.bundle)
    validate_metadata(metadata_path, bundle_path, args.plugin_id, args.version, args.source_commit)
    validate_archive(bundle_path, args.plugin_id, args.version)


if __name__ == "__main__":
    try:
        main()
    except (OSError, UnicodeError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as exc:
        print(f"error: external Wasm bundle validation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
