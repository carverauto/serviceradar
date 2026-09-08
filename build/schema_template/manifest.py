"""Version-one schema identity. Only explicitly supplied files are read."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct


GROUPS = ("migration", "baseline-sql", "baseline-metadata", "helper", "construction")
MIGRATION = re.compile(r"([0-9]+)_[a-zA-Z0-9_]+\.exs\Z")
IDENTITY_DOMAIN = b"serviceradar.schema-template.v1\0"
COVERED_DOMAIN = b"serviceradar.schema-template.covered-migrations.v1\0"


def canonical_json(value):
    """UTF-8 JSON, sorted keys, compact separators, no trailing newline."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def validate_path(path):
    if (
        not isinstance(path, str)
        or not re.fullmatch(r"[A-Za-z0-9_.\-/]+", path)
        or path.startswith("/")
        or any(part in ("", ".", "..") for part in path.split("/"))
    ):
        raise ValueError(f"malformed repository-relative path: {path!r}")
    return path


def input_digest(inputs, domain=IDENTITY_DOMAIN):
    """Hash domain + u64be count + repeated (u64be path size, path, raw SHA256).

    Paths are UTF-8, sorted lexicographically; hashes decode lowercase hex to
    exactly 32 bytes. Domain includes its terminating NUL. No JSON re-encoding
    is involved, so Rust and Elixir can verify the same identity independently.
    """
    digest = hashlib.sha256(domain)
    digest.update(struct.pack(">Q", len(inputs)))
    for item in sorted(inputs, key=lambda item: item["path"]):
        path = item["path"].encode("utf-8")
        digest.update(struct.pack(">Q", len(path)))
        digest.update(path)
        digest.update(bytes.fromhex(item["sha256"]))
    return digest.hexdigest()


def build_manifest(groups):
    """Map input group names to (repository path, physical path) pairs.

    Physical paths are solely locators, so sandbox and checkout locations cannot
    influence the identity. No glob, environment lookup, or database is used.
    """
    if set(groups) != set(GROUPS):
        raise ValueError("missing or unknown input groups")
    contents = {}
    versions = {}
    for group in GROUPS:
        if not groups[group]:
            raise ValueError(f"empty {group} inputs")
        if group.startswith("baseline-") and len(groups[group]) != 1:
            raise ValueError(f"expected exactly one {group} input")
        for logical, physical in groups[group]:
            validate_path(logical)
            if logical in contents:
                raise ValueError(f"duplicate input path: {logical}")
            try:
                contents[logical] = Path(physical).read_bytes()
            except OSError as error:
                raise ValueError(f"missing or unreadable input: {logical}") from error
            if group == "migration":
                match = MIGRATION.fullmatch(PurePosixPath(logical).name)
                if not match:
                    raise ValueError(f"malformed migration path: {logical}")
                version = int(match[1])
                if not 0 < version <= 9223372036854775807:
                    raise ValueError(f"migration version outside positive bigint: {logical}")
                if version in versions:
                    raise ValueError(f"duplicate migration version {version}: {versions[version]}, {logical}")
                if not contents[logical].strip():
                    raise ValueError(f"empty migration: {logical}")
                versions[version] = logical

    metadata_path = groups["baseline-metadata"][0][0]
    sql_path = groups["baseline-sql"][0][0]
    try:
        metadata = json.loads(contents[metadata_path])
    except (ValueError, UnicodeError) as error:
        raise ValueError("malformed baseline metadata JSON") from error
    if not isinstance(metadata, dict):
        raise ValueError("baseline metadata must be an object")
    schema_file = validate_path(metadata.get("schema_file"))
    if str(PurePosixPath(metadata_path).parent / schema_file) != sql_path:
        raise ValueError("baseline schema_file does not match declared SQL input")
    if metadata.get("schema_sha256") != hashlib.sha256(contents[sql_path]).hexdigest():
        raise ValueError("baseline SQL hash mismatch")
    for field in ("version", "included_through", "postgres_major"):
        if type(metadata.get(field)) is not int or metadata[field] <= 0:
            raise ValueError(f"invalid baseline {field}")

    payload = {
        "version": 1,
        "inputs": [
            {"path": path, "sha256": hashlib.sha256(contents[path]).hexdigest()}
            for path in sorted(contents)
        ],
        "migration_versions": sorted(versions),
    }
    covered_paths = {path for version, path in versions.items() if version <= metadata["included_through"]}
    payload["covered_migrations"] = {
        "included_through": metadata["included_through"],
        "digest": input_digest(
            [item for item in payload["inputs"] if item["path"] in covered_paths],
            COVERED_DOMAIN,
        ),
    }
    digest = input_digest(payload["inputs"])
    return dict(payload, digest=digest, database="sr_tpl_" + digest[:48])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, fromfile_prefix_chars="@")
    parser.add_argument("--output", required=True)
    for group in GROUPS:
        parser.add_argument("--" + group, action="append", nargs=2, required=True)
    args = parser.parse_args(argv)
    try:
        result = build_manifest({group: getattr(args, group.replace("-", "_")) for group in GROUPS})
        Path(args.output).write_bytes(canonical_json(result))
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
