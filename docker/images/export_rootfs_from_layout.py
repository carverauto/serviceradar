#!/usr/bin/env python3
"""
Generate a rootfs tarball from an OCI image layout.

This is used as a fallback when `crane export layout:<path>` is unavailable
on remote executors. The script walks the layout manifest, applies each layer
with whiteout handling, and archives the merged filesystem so downstream jobs
can reuse it identically to the `crane export` output.
"""

import argparse
import json
import os
import shutil
import sys
import tarfile
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from extract_rootfs import _apply_whiteout, _extract_member, _normalize_member_name


def _extract_layer(layer_path: str, dest: str) -> None:
    with tarfile.open(layer_path, "r:*") as archive:
        pending_links = []
        dir_perms = []
        for member in archive:
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                continue
            relpath = _normalize_member_name(member.name)
            if relpath is None:
                continue
            if _apply_whiteout(dest, relpath):
                continue
            if member.islnk():
                link_target = _normalize_member_name(member.linkname)
                if link_target is None:
                    continue
                pending_links.append((link_target, relpath))
                continue
            _extract_member(archive, member, dest, relpath, dir_perms)

        for source_rel, dest_rel in pending_links:
            source_path = os.path.join(dest, source_rel)
            target_path = os.path.join(dest, dest_rel)
            if not os.path.exists(source_path):
                continue
            parent_dir = os.path.dirname(target_path)
            if parent_dir:
                os.makedirs(parent_dir, exist_ok=True)
            if os.path.lexists(target_path):
                os.unlink(target_path)
            os.link(source_path, target_path)

        for path, mode in dir_perms:
            if os.path.exists(path):
                os.chmod(path, mode)


def _layout_layers(layout_dir: str) -> list[str]:
    index_path = os.path.join(layout_dir, "index.json")
    with open(index_path, "r", encoding="utf-8") as fh:
        index = json.load(fh)

    if not index.get("manifests"):
        raise ValueError(f"{index_path} does not contain any manifests")

    manifest_digest = index["manifests"][0]["digest"]
    algo, digest = manifest_digest.split(":", 1)
    manifest_path = os.path.join(layout_dir, "blobs", algo, digest)

    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

    layers = []
    for layer in manifest.get("layers", []):
        digest_value = layer["digest"]
        algo, hash_value = digest_value.split(":", 1)
        layers.append(os.path.join(layout_dir, "blobs", algo, hash_value))
    return layers


def _write_tarball(src_dir: str, tarball: str) -> None:
    with tarfile.open(tarball, "w") as archive:
        archive.add(src_dir, arcname=".")


def main() -> None:
    parser = argparse.ArgumentParser(description="Create a rootfs tarball from an OCI layout.")
    parser.add_argument("--layout", required=True, help="Path to the OCI layout directory.")
    parser.add_argument("--output", required=True, help="Path to the output tarball.")
    args = parser.parse_args()

    layout_dir = os.path.abspath(args.layout)
    output_path = os.path.abspath(args.output)

    work_dir = tempfile.mkdtemp(prefix="cnpg_rootfs_")
    try:
        for layer in _layout_layers(layout_dir):
            _extract_layer(layer, work_dir)
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        _write_tarball(work_dir, output_path)
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
