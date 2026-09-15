#!/usr/bin/env python3
"""Copy pg_duckdb extension files out of an extracted pgduckdb image rootfs.

The analytics image is CloudNativePG's PostgreSQL 18 image plus this layer.
The official pgduckdb/pgduckdb image is a standard postgres image (UID 999)
and is not CNPG-compatible; only the extension files move across.

Fails closed if pg_duckdb.so or pg_duckdb.control is missing, so a layout
change upstream cannot silently produce an empty layer. Refuses to copy
anything whose path looks like TimescaleDB, AGE, or PostGIS.
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys

FORBIDDEN_SUBSTRINGS = ("timescaledb", "age.so", "/age/", "postgis", "pgvector")
REQUIRED_SO = "pg_duckdb.so"
REQUIRED_CONTROL = "pg_duckdb.control"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--src", required=True, help="Extracted pgduckdb image rootfs.")
    parser.add_argument("--dest", required=True, help="Layer root to populate.")
    return parser.parse_args()


def _relpath(root: str, path: str) -> str:
    return os.path.relpath(path, root)


def _forbidden(relpath: str) -> bool:
    lowered = relpath.lower()
    return any(token in lowered for token in FORBIDDEN_SUBSTRINGS)


def _copy_file(src_root: str, dest_root: str, src_path: str) -> str:
    rel = _relpath(src_root, src_path)
    if _forbidden(rel):
        raise SystemExit(f"refusing to copy forbidden path into the analytics layer: {rel}")
    dest_path = os.path.join(dest_root, rel)
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    if os.path.islink(src_path):
        if os.path.lexists(dest_path):
            os.unlink(dest_path)
        os.symlink(os.readlink(src_path), dest_path)
        return rel
    shutil.copy2(src_path, dest_path)
    return rel


def _find_named(src_root: str, filename: str) -> list[str]:
    found: list[str] = []
    for dirpath, _dirnames, filenames in os.walk(src_root):
        if filename in filenames:
            found.append(os.path.join(dirpath, filename))
    return found


def _copy_extension_sql(src_root: str, dest_root: str, control_path: str) -> list[str]:
    copied: list[str] = []
    ext_dir = os.path.dirname(control_path)
    for name in sorted(os.listdir(ext_dir)):
        if not (name.startswith("pg_duckdb") and (name.endswith(".sql") or name.endswith(".control"))):
            continue
        copied.append(_copy_file(src_root, dest_root, os.path.join(ext_dir, name)))
    return copied


def _copy_sibling_libs(src_root: str, dest_root: str, so_path: str) -> list[str]:
    copied: list[str] = []
    lib_dir = os.path.dirname(so_path)
    for name in sorted(os.listdir(lib_dir)):
        if name == REQUIRED_SO or name.startswith("libduckdb"):
            copied.append(_copy_file(src_root, dest_root, os.path.join(lib_dir, name)))
    bitcode = os.path.join(lib_dir, "bitcode")
    if os.path.isdir(bitcode):
        for dirpath, _dirnames, filenames in os.walk(bitcode):
            for name in filenames:
                if "pg_duckdb" not in name:
                    continue
                copied.append(_copy_file(src_root, dest_root, os.path.join(dirpath, name)))
    return copied


def main() -> int:
    args = _parse_args()
    src = os.path.abspath(args.src)
    dest = os.path.abspath(args.dest)
    if not os.path.isdir(src):
        raise SystemExit(f"source rootfs does not exist: {src}")
    os.makedirs(dest, exist_ok=True)

    so_matches = _find_named(src, REQUIRED_SO)
    if len(so_matches) != 1:
        raise SystemExit(
            f"expected exactly one {REQUIRED_SO} under {src}, found {len(so_matches)}: "
            f"{so_matches}"
        )
    control_matches = _find_named(src, REQUIRED_CONTROL)
    if len(control_matches) != 1:
        raise SystemExit(
            f"expected exactly one {REQUIRED_CONTROL} under {src}, found "
            f"{len(control_matches)}: {control_matches}"
        )

    copied = _copy_sibling_libs(src, dest, so_matches[0])
    copied.extend(_copy_extension_sql(src, dest, control_matches[0]))
    # De-duplicate while preserving order for the log line.
    unique = list(dict.fromkeys(copied))
    dest_so = os.path.join(dest, _relpath(src, so_matches[0]))
    dest_control = os.path.join(dest, _relpath(src, control_matches[0]))
    if not os.path.isfile(dest_so) and not os.path.islink(dest_so):
        raise SystemExit(f"copy did not produce {dest_so}")
    if not os.path.isfile(dest_control):
        raise SystemExit(f"copy did not produce {dest_control}")
    print(f"copied {len(unique)} pg_duckdb artifacts:")
    for rel in unique:
        print(f"  {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
