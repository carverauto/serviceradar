#!/usr/bin/env python3

import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-out", required=True)
    parser.add_argument("--sha-out", required=True)
    parser.add_argument("--metadata-out", required=True)
    parser.add_argument("--plugin-id", required=True)
    parser.add_argument("--repository-name", required=True)
    parser.add_argument("--artifact-type", required=True)
    parser.add_argument("--bundle-media-type", required=True)
    parser.add_argument("--entry", action="append", default=[])
    return parser.parse_args()


def normalize_entries(raw_entries):
    entries = []
    for raw in raw_entries:
        archive_path, sep, source_path = raw.partition("=")
        if not sep:
            raise ValueError(f"invalid --entry value: {raw}")
        entries.append((archive_path, Path(source_path)))
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


def main():
    args = parse_args()
    bundle_path = Path(args.bundle_out)
    sha_path = Path(args.sha_out)
    metadata_path = Path(args.metadata_out)
    entries = normalize_entries(args.entry)

    write_zip(bundle_path, entries)
    digest = sha256_file(bundle_path)

    sha_path.parent.mkdir(parents=True, exist_ok=True)
    sha_path.write_text(f"{digest}\n", encoding="utf-8")

    metadata = {
        "plugin_id": args.plugin_id,
        "repository_name": args.repository_name,
        "artifact_type": args.artifact_type,
        "bundle_media_type": args.bundle_media_type,
        "bundle_file": bundle_path.name,
        "sha256_file": sha_path.name,
        "entries": [
            {
                "archive_path": archive_path,
                "source_path": str(source_path),
            }
            for archive_path, source_path in entries
        ],
    }
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
