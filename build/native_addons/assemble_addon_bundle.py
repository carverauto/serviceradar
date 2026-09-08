#!/usr/bin/env python3
"""Assemble a deterministic native add-on bundle (issue 3425).

Mirrors build/wasm_plugins/assemble_bundle.py but ships per-architecture native
binaries (mode 0755) alongside the manifest files (mode 0644), and records a
per-arch artifacts[] list (os/arch/archive_path/sha256) in metadata.json. The zip
is deterministic: entries sorted by archive path, timestamps zeroed to 1980.
"""

import argparse
import gzip
import hashlib
import io
import json
import re
import tarfile
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
    # Per-arch pushed-artifact tarball outputs: os/arch=out_path
    parser.add_argument("--tarball", action="append", default=[])
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


def normalize_tarballs(raw_tarballs):
    tarballs = {}
    for raw in raw_tarballs:
        platform, sep, out_path = raw.partition("=")
        if not sep:
            raise ValueError(f"invalid --tarball value: {raw}")
        os_name, _, arch = platform.partition("/")
        tarballs[(os_name, arch)] = Path(out_path)
    return tarballs


def _deterministic_tarinfo(name: str, size: int, mode: int) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name)
    info.size = size
    info.mode = mode
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.type = tarfile.REGTYPE
    return info


def write_tarball(out_path: Path, binary_name: str, binary_source: Path, file_members):
    """Produce a deterministic gzip tarball matching the agent's extractAddonTarball:
    flat single-segment entries, the binary at 0755 and manifest/config/units at 0644."""
    members = [(binary_name, binary_source, 0o755)]
    for archive_path, source_path, _executable in file_members:
        members.append((Path(archive_path).name, source_path, 0o644))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        for name, source_path, mode in sorted(members, key=lambda m: m[0]):
            data = source_path.read_bytes()
            tar.addfile(_deterministic_tarinfo(name, len(data), mode), io.BytesIO(data))
    with out_path.open("wb") as fh:
        # mtime=0 keeps the gzip header (and thus the sha256) reproducible.
        with gzip.GzipFile(fileobj=fh, mode="wb", mtime=0) as gz:
            gz.write(raw.getvalue())


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


_ELF_MACHINE_BY_ARCH = {
    "amd64": 62,  # EM_X86_64
    "arm64": 183,  # EM_AARCH64
}


def validate_artifact_binary(os_name: str, arch: str, source_path: Path):
    """Fail closed when artifact metadata disagrees with the executable."""
    if os_name != "linux":
        raise SystemExit(f"error: unsupported native add-on artifact OS: {os_name!r}")

    expected_machine = _ELF_MACHINE_BY_ARCH.get(arch)
    if expected_machine is None:
        raise SystemExit(f"error: unsupported linux native add-on artifact arch: {arch!r}")

    header = source_path.read_bytes()[:64]
    if len(header) < 20 or header[:4] != b"\x7fELF":
        raise SystemExit(
            f"error: {source_path}: expected linux/{arch} ELF executable for native "
            "add-on artifact, but file header is not ELF"
        )

    elf_class = header[4]
    endian_flag = header[5]
    if elf_class != 2:
        raise SystemExit(
            f"error: {source_path}: expected linux/{arch} 64-bit ELF executable, "
            f"got ELF class {elf_class}"
        )
    if endian_flag == 1:
        endian = "little"
    elif endian_flag == 2:
        endian = "big"
    else:
        raise SystemExit(
            f"error: {source_path}: expected linux/{arch} ELF executable, "
            f"got invalid ELF endian flag {endian_flag}"
        )

    actual_machine = int.from_bytes(header[18:20], endian)
    if actual_machine != expected_machine:
        raise SystemExit(
            f"error: {source_path}: expected linux/{arch} ELF machine "
            f"{expected_machine}, got {actual_machine}"
        )


# Enum constraints mirrored from addons/native-addon-manifest.schema.json. The
# authoritative gate is the Go validator (go/tools/addon-manifest-validator), run
# as a build/CI gate before bundling. This in-assembler check is defense-in-depth:
# it fails the bundle build closed on a structurally invalid manifest even when the
# assembler is invoked directly (raw `bazel build`), so an invalid manifest can
# never produce a bundle.
_REQUIRED_MANIFEST_FIELDS = (
    "id",
    "name",
    "version",
    "kind",
    "delivery",
    "supervision",
    "capabilities",
    "requires",
    "exec",
    "config_schema",
)
_KIND_VALUES = {"native"}
_DELIVERY_VALUES = {"compiled-in", "pushed-artifact", "os-package"}
_SUPERVISION_VALUES = {
    "config-toggle",
    "agent-sidecar",
    "systemd-service",
    "systemd-timer",
    "ephemeral-helper",
}


def validate_manifest(members):
    """Fail closed before bundling on a structurally invalid addon.yaml.

    Enforces required top-level fields and the kind/delivery/supervision enums.
    Raises SystemExit (non-zero) with the offending reason on any violation.
    """
    manifest_path = next(
        (source_path for archive_path, source_path, _ in members if archive_path == "addon.yaml"),
        None,
    )
    if manifest_path is None:
        raise SystemExit("error: bundle is missing an addon.yaml manifest")

    doc = load_manifest_yaml(manifest_path)
    if not isinstance(doc, dict):
        raise SystemExit(f"error: {manifest_path}: manifest is not a YAML mapping")

    errors = []
    for field in _REQUIRED_MANIFEST_FIELDS:
        if field not in doc or doc[field] in (None, "", [], {}):
            errors.append(f"missing required field: {field}")

    if doc.get("kind") is not None and doc["kind"] not in _KIND_VALUES:
        errors.append(f"unknown kind: {doc['kind']!r} (allowed: {sorted(_KIND_VALUES)})")
    if doc.get("delivery") is not None and doc["delivery"] not in _DELIVERY_VALUES:
        errors.append(f"unknown delivery: {doc['delivery']!r} (allowed: {sorted(_DELIVERY_VALUES)})")
    if doc.get("supervision") is not None and doc["supervision"] not in _SUPERVISION_VALUES:
        errors.append(
            f"unknown supervision: {doc['supervision']!r} (allowed: {sorted(_SUPERVISION_VALUES)})"
        )

    if errors:
        joined = "\n  - ".join(errors)
        raise SystemExit(
            f"error: {manifest_path}: invalid add-on manifest; refusing to bundle:\n  - {joined}"
        )


def load_manifest_yaml(manifest_path: Path):
    text = manifest_path.read_text(encoding="utf-8")
    try:
        import yaml  # noqa: PLC0415 - optional when available in the action env.
    except ImportError:  # pragma: no cover - environment-specific.
        return parse_manifest_top_level(text)

    return yaml.safe_load(text)


def parse_manifest_top_level(text: str) -> dict:
    """Parse enough YAML for native add-on manifest validation.

    This fallback intentionally handles only top-level scalar keys and marks
    top-level lists/maps as present. The authoritative schema validation still
    happens in the Go manifest validator; this assembler only needs a
    dependency-free fail-closed check for required fields and simple enums.
    """
    doc = {}
    current_key = None

    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue

        if raw_line.startswith((" ", "\t")):
            if current_key and doc.get(current_key) in (None, "", [], {}):
                doc[current_key] = True
            continue

        key, sep, value = raw_line.partition(":")
        if not sep:
            current_key = None
            continue

        current_key = key.strip()
        value = _strip_inline_comment(value.strip()).strip()
        if value in {"", "|", ">-", ">"}:
            doc[current_key] = True
            continue

        doc[current_key] = value.strip("\"'")

    return doc


def _strip_inline_comment(value: str) -> str:
    """Drop a trailing YAML comment from an unquoted scalar value.

    YAML treats `#` as a comment only at the start of a token or when preceded by
    whitespace, so `pushed-artifact   # ...` is the scalar `pushed-artifact`. The
    PyYAML path already does this; this keeps the dependency-free fallback parser
    from being stricter than the authoritative Go validator. Quoted scalars are
    left untouched (the manifest enums are unquoted).
    """
    if value[:1] in ("\"", "'"):
        return value
    match = re.search(r"(^|\s)#", value)
    return value[: match.start()] if match else value


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
    tarballs = normalize_tarballs(args.tarball)
    binary_members = [
        (archive_path, source_path, True)
        for (_os, _arch, archive_path, source_path) in artifacts
    ]
    members = file_members + binary_members

    # Fail closed before producing any bundle output on an invalid manifest.
    validate_manifest(members)
    for os_name, arch, _archive_path, source_path in artifacts:
        validate_artifact_binary(os_name, arch, source_path)

    write_zip(bundle_path, members)
    digest = sha256_file(bundle_path)
    manifest = manifest_metadata(members)

    sha_path.parent.mkdir(parents=True, exist_ok=True)
    sha_path.write_text(f"{digest}\n", encoding="utf-8")

    # Produce the per-arch pushed-artifact tarball (flat: binary + manifest/config/units)
    # the agent fetches and extracts; record its name + sha256 alongside the bare binary.
    tarball_meta = {}
    for (os_name, arch, archive_path, source_path) in artifacts:
        out_path = tarballs.get((os_name, arch))
        if out_path is None:
            continue
        binary_name = Path(archive_path).name
        write_tarball(out_path, binary_name, source_path, file_members)
        tarball_meta[(os_name, arch)] = (out_path.name, sha256_file(out_path))

    artifact_meta = []
    for (os_name, arch, archive_path, source_path) in artifacts:
        entry = {
            "os": os_name,
            "arch": arch,
            "archive_path": archive_path,
            "sha256": sha256_bytes(source_path.read_bytes()),
        }
        if (os_name, arch) in tarball_meta:
            tarball_file, tarball_sha256 = tarball_meta[(os_name, arch)]
            entry["tarball_file"] = tarball_file
            entry["tarball_sha256"] = tarball_sha256
        artifact_meta.append(entry)
    artifact_meta.sort(key=lambda item: (item["os"], item["arch"]))

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
