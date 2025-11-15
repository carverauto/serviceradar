#!/usr/bin/env python3
"""
Overlay Debian packages into an extracted CNPG rootfs.

The TimescaleDB/AGE genrules need Postgres development headers and build tools.
This helper unpacks the data.tar.* payload from one or more .deb archives and
merges their contents into the rootfs directory.
"""

import argparse
import bz2
import gzip
import io
import lzma
import os
import posixpath
import tarfile
import traceback
from typing import BinaryIO, List, Optional, Tuple
import shutil


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Overlay .deb packages into a rootfs directory.")
    parser.add_argument("rootfs", help="Destination rootfs directory that already contains the CNPG files.")
    parser.add_argument("packages", nargs="+", help="One or more .deb archives to overlay.")
    return parser.parse_args()


def _normalize_member_name(name: str) -> Optional[str]:
    normalized = name.lstrip("./")
    if not normalized:
        return None
    normalized = posixpath.normpath(normalized)
    if normalized in ("", "."):
        return None
    if normalized.startswith("../"):
        raise ValueError(f"Refusing to write outside rootfs: {name}")
    return normalized


def _ensure_parent(path: str) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)


def _extract_member(archive: tarfile.TarFile, member: tarfile.TarInfo, dest: str, relpath: str, dir_perms: List[Tuple[str, int]]) -> None:
    target = os.path.join(dest, relpath)
    if member.isdir():
        os.makedirs(target, exist_ok=True)
        dir_perms.append((target, member.mode & 0o777))
        return
    if member.issym():
        _ensure_parent(target)
        if os.path.lexists(target):
            os.unlink(target)
        os.symlink(member.linkname, target)
        return
    if member.isfile():
        _ensure_parent(target)
        with archive.extractfile(member) as src, open(target, "wb") as dst:
            if src is None:
                raise ValueError(f"Unable to read member {member.name}")
            shutil.copyfileobj(src, dst)
        os.chmod(target, member.mode & 0o777)
        return


def _apply_hardlinks(dest: str, pending_links: List[Tuple[str, str]]) -> None:
    for source_rel, dest_rel in pending_links:
        source_path = os.path.join(dest, source_rel)
        target_path = os.path.join(dest, dest_rel)
        if not os.path.exists(source_path):
            continue
        _ensure_parent(target_path)
        if os.path.lexists(target_path):
            os.unlink(target_path)
        os.link(source_path, target_path)


def _apply_dir_perms(dir_perms: List[Tuple[str, int]]) -> None:
    for path, mode in dir_perms:
        if os.path.exists(path):
            os.chmod(path, mode)


def _extract_tar_stream(stream: BinaryIO, dest: str) -> None:
    pending_links: List[Tuple[str, str]] = []
    dir_perms: List[Tuple[str, int]] = []
    with tarfile.open(fileobj=stream, mode="r:*") as archive:
        for member in archive:
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                continue
            relpath = _normalize_member_name(member.name)
            if relpath is None:
                continue
            if member.islnk():
                link_target = _normalize_member_name(member.linkname)
                if link_target is None:
                    continue
                pending_links.append((link_target, relpath))
                continue
            _extract_member(archive, member, dest, relpath, dir_perms)

    _apply_hardlinks(dest, pending_links)
    _apply_dir_perms(dir_perms)


def _open_data_stream(filename: str, data: bytes) -> BinaryIO:
    buffer = io.BytesIO(data)
    if filename.endswith(".xz"):
        return lzma.LZMAFile(buffer)
    if filename.endswith(".gz"):
        return gzip.GzipFile(fileobj=buffer)
    if filename.endswith(".bz2"):
        return bz2.BZ2File(buffer)
    buffer.seek(0)
    return buffer


def _apply_deb_package(dest: str, package_path: str) -> None:
    with open(package_path, "rb") as deb_file:
        header = deb_file.read(8)
        if header != b"!<arch>\n":
            raise ValueError(f"{package_path} is not an ar archive")
        while True:
            entry_header = deb_file.read(60)
            if not entry_header:
                break
            if len(entry_header) != 60:
                raise ValueError(f"Corrupt ar header in {package_path}")
            name = entry_header[:16].decode("utf-8").strip()
            size_str = entry_header[48:58].decode("utf-8").strip()
            try:
                size = int(size_str)
            except ValueError as exc:
                raise ValueError(f"Invalid size in {package_path}") from exc
            data = deb_file.read(size)
            if size % 2 == 1:
                deb_file.seek(1, os.SEEK_CUR)

            normalized_name = name.rstrip("/")
            if normalized_name.startswith("data.tar"):
                stream = _open_data_stream(normalized_name, data)
                _extract_tar_stream(stream, dest)
                return
        raise ValueError(f"{package_path} is missing a data.tar payload")


def main() -> None:
    args = _parse_args()
    rootfs = os.path.abspath(args.rootfs)
    if not os.path.isdir(rootfs):
        raise ValueError(f"Rootfs directory {rootfs} does not exist")
    for package in args.packages:
        pkg_path = os.path.abspath(package)
        if not os.path.isfile(pkg_path):
            raise ValueError(f"Package {pkg_path} is not accessible")
        _apply_deb_package(rootfs, pkg_path)
    _ensure_pg_config_header(rootfs)


def _ensure_pg_config_header(rootfs: str) -> None:
    include_root = os.path.join(rootfs, "usr/include/postgresql")
    target = os.path.join(include_root, "pg_config.h")
    if os.path.exists(target) or not os.path.isdir(include_root):
        return
    candidates: List[str] = []
    for entry in sorted(os.listdir(include_root)):
        candidate = os.path.join(include_root, entry, "server", "pg_config.h")
        if os.path.isfile(candidate):
            candidates.append(candidate)
    if not candidates:
        return
    shutil.copy2(candidates[-1], target)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # pragma: no cover - genrule helper
        traceback.print_exc()
        print(f"overlay_deb_packages: {exc}")
        raise
