#!/usr/bin/env python3
"""
Extract a container rootfs tarball while respecting OCI whiteout semantics.

We need to support images that rely on overlayfs-style whiteout files to delete
directories or individual paths across layers. Using tar(1) directly can leave
whiteout markers behind and triggers "Cannot open: File exists" failures when
later entries try to replace the removed paths. This helper removes the targets
referenced by `.wh.*` files and trims opaque directories before extracting the
real payload so the resulting rootfs mirrors the container runtime view.
"""

import argparse
import os
import posixpath
import shutil
import sys
import tarfile
import traceback
from typing import Optional


def _parse_args():
    parser = argparse.ArgumentParser(
        description="Extract a rootfs tarball with whiteout handling.",
    )
    parser.add_argument("tarball", help="Path to the exported rootfs tarball.")
    parser.add_argument("destination", help="Directory to populate with the rootfs contents.")
    return parser.parse_args()


def _normalize_member_name(name: str) -> Optional[str]:
    name = name.lstrip("./")
    if not name:
        return None

    normalized = posixpath.normpath(name)
    if normalized in ("", "."):
        return None
    if normalized.startswith("../"):
        raise ValueError(f"Refusing to extract path outside destination: {name}")
    return normalized


def _remove_path(path: str) -> None:
    if not os.path.lexists(path):
        return
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)


def _safe_rmtree(path: str) -> None:
    if not os.path.exists(path):
        return

    def _onerror(func, target, exc_info):
        _, error, _ = exc_info
        if isinstance(error, FileNotFoundError):
            return
        os.chmod(target, 0o700)
        func(target)

    shutil.rmtree(path, onerror=_onerror)


def _apply_whiteout(dest: str, relpath: str) -> bool:
    basename = posixpath.basename(relpath)
    parent = posixpath.dirname(relpath)

    if basename == ".wh..wh..opq":
        target_dir = os.path.join(dest, parent)
        if os.path.isdir(target_dir):
            for entry in os.listdir(target_dir):
                _remove_path(os.path.join(target_dir, entry))
        return True

    if basename.startswith(".wh."):
        target_rel = posixpath.join(parent, basename[4:])
        target_path = os.path.join(dest, target_rel)
        if os.path.exists(target_path) or os.path.islink(target_path):
            _remove_path(target_path)
        return True

    return False


def _extract_member(archive: tarfile.TarFile, member: tarfile.TarInfo, dest: str, relpath: str, dir_perms: list[tuple[str, int]]) -> None:
    target_path = os.path.join(dest, relpath)
    parent_dir = os.path.dirname(target_path)
    if parent_dir:
        os.makedirs(parent_dir, exist_ok=True)

    if member.isdir():
        os.makedirs(target_path, exist_ok=True)
        dir_perms.append((target_path, member.mode & 0o777))
        return

    if member.issym():
        if os.path.lexists(target_path):
            os.unlink(target_path)
        os.symlink(member.linkname, target_path)
        return

    if member.isfile():
        with archive.extractfile(member) as src, open(target_path, "wb") as dst:
            shutil.copyfileobj(src, dst)
        os.chmod(target_path, member.mode & 0o777)
        return


def main():
    args = _parse_args()
    tarball = os.path.abspath(args.tarball)
    dest = os.path.abspath(args.destination)

    if os.path.exists(dest):
        _safe_rmtree(dest)
    os.makedirs(dest, exist_ok=True)

    with tarfile.open(tarball, "r:*") as archive:
        pending_links = []
        dir_perms = []
        for member in archive:
            if member.isfile() or member.isdir() or member.issym() or member.islnk():
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


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # pragma: no cover - genrule helper
        traceback.print_exc()
        print(f"extract_rootfs: {exc}", file=sys.stderr)
        sys.exit(1)
