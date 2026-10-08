"""Fail when a merge would give one migrations directory two Ecto migrations.

Parallel pull requests each pass against the staging tip they branched from.
The duplicate appears only after both have merged: the same version prefix,
the same Elixir module name, or the same file bytes under two names. Ecto
then refuses to migrate, and schema-manifest generation fails for later
pull requests.

This check builds the merge of ``--base`` (latest ``origin/staging``) and
``--head`` and scans that tree. Comparing a commit with itself scans that
commit, so a clean staging push passes and a duplicate that just landed fails.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_DIRECTORY = "elixir/serviceradar_core/priv/repo/migrations"
_MAX_VERSION = 9223372036854775807
_FILENAME = re.compile(r"([0-9]+)_[a-zA-Z0-9_]+\.exs\Z")
_MODULE = re.compile(r"(?m)^defmodule\s+([A-Za-z_][A-Za-z0-9_.]*)\s+do\b")
_TREE_ID = re.compile(r"[0-9a-f]{40,64}\Z")


def find_collisions(files: dict[str, bytes]) -> list[str]:
    """Return one message per colliding version, module, or byte-identical set.

    ``files`` maps a repository-relative path to its raw bytes and contains
    one migrations directory. An empty list means that directory can migrate.
    """
    messages: list[str] = []
    by_version: dict[int, list[str]] = {}
    by_module: dict[str, list[str]] = {}
    by_digest: dict[str, list[str]] = {}

    for path in sorted(files):
        body = files[path]
        match = _FILENAME.fullmatch(_filename(path))
        if match is None:
            messages.append(f"malformed migration path: {path}")
            continue
        version = int(match.group(1))
        if not 0 < version <= _MAX_VERSION:
            messages.append(f"migration version outside positive bigint: {path}")
            continue
        if not body.strip():
            messages.append(f"empty migration: {path}")
            continue
        by_version.setdefault(version, []).append(path)
        by_digest.setdefault(hashlib.sha256(body).hexdigest(), []).append(path)
        try:
            text = body.decode("utf-8")
        except UnicodeError:
            messages.append(f"migration is not utf-8: {path}")
            continue
        modules = _MODULE.findall(text)
        if len(modules) != 1:
            kind = "missing" if not modules else "declares multiple modules"
            messages.append(f"migration module {kind}: {path}")
            continue
        by_module.setdefault(modules[0], []).append(path)

    for version, paths in by_version.items():
        if len(paths) > 1:
            messages.append(f"duplicate migration version {version}: {_join(paths)}")
    for module, paths in by_module.items():
        if len(paths) > 1:
            messages.append(f"duplicate migration module {module}: {_join(paths)}")
    for digest, paths in by_digest.items():
        if len(paths) > 1:
            messages.append(f"duplicate migration contents {digest}: {_join(paths)}")
    return sorted(messages)


def check_merge(repo: str | Path, base: str, head: str, directory: str = DEFAULT_DIRECTORY) -> list[str]:
    """Scan the merge of ``base`` and ``head`` for collisions under ``directory``."""
    files, conflicts = merged_migration_files(repo, base, head, directory)
    messages = find_collisions(files)
    messages.extend(f"migration merge conflict: {path}" for path in conflicts)
    return sorted(messages)


def merged_migration_files(
    repo: str | Path, base: str, head: str, directory: str = DEFAULT_DIRECTORY
) -> tuple[dict[str, bytes], list[str]]:
    """Return ``(path -> bytes, conflict paths)`` for the merged directory."""
    tree, conflicts = _merge_tree(repo, base, head)
    files = {
        path: body
        for path, body in _tree_files(repo, tree, directory).items()
        if path.endswith(".exs")
    }
    relevant = sorted(path for path in conflicts if _under(directory, path))
    return files, relevant


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--directory", default=DEFAULT_DIRECTORY)
    args = parser.parse_args(argv)
    try:
        messages = check_merge(args.repo, args.base, args.head, args.directory)
    except (OSError, RuntimeError) as error:
        print(f"migration collision check failed: {error}", file=sys.stderr)
        return 2
    if not messages:
        return 0
    for message in messages:
        print(message, file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::error::{message}", file=sys.stderr)
    return 1


def _join(paths: list[str]) -> str:
    return ", ".join(sorted(paths))


def _filename(path: str) -> str:
    return path.rsplit("/", 1)[-1]


def _under(directory: str, path: str) -> bool:
    directory = directory.strip("/")
    return path == directory or path.startswith(directory + "/")


def _merge_tree(repo: str | Path, base: str, head: str) -> tuple[str, list[str]]:
    proc = subprocess.run(
        ["git", "-C", str(repo), "merge-tree", "--write-tree", "--name-only", base, head],
        capture_output=True,
        check=False,
    )
    if proc.returncode not in (0, 1):
        detail = proc.stderr.decode(errors="replace").strip()
        raise RuntimeError(detail or f"git merge-tree failed ({proc.returncode})")
    stdout = proc.stdout.decode(errors="replace")
    lines = stdout.splitlines()
    if not lines or _TREE_ID.fullmatch(lines[0]) is None:
        raise RuntimeError(f"git merge-tree returned no tree id: {stdout!r}")
    paths: list[str] = []
    for line in lines[1:]:
        if line.startswith("CONFLICT"):
            marker = "Merge conflict in "
            index = line.rfind(marker)
            if index != -1:
                paths.append(line[index + len(marker) :].strip())
            continue
        if not line or line.startswith("Auto-merging "):
            continue
        paths.append(line.strip())
    return lines[0], sorted(set(paths))


def _tree_files(repo: str | Path, tree: str, directory: str) -> dict[str, bytes]:
    listed = _git(repo, "ls-tree", "-r", "-z", tree, "--", directory)
    oid_by_path: dict[str, str] = {}
    for record in listed.split(b"\0"):
        if not record:
            continue
        meta, raw_path = record.split(b"\t", 1)
        oid_by_path[raw_path.decode()] = meta.split(b" ")[-1].decode()
    return _cat_blobs(repo, oid_by_path)


def _cat_blobs(repo: str | Path, oid_by_path: dict[str, str]) -> dict[str, bytes]:
    if not oid_by_path:
        return {}
    paths = sorted(oid_by_path)
    payload = b"".join(oid_by_path[path].encode() + b"\n" for path in paths)
    data = _git(repo, "cat-file", "--batch", input=payload)
    files: dict[str, bytes] = {}
    for path in paths:
        try:
            header, data = data.split(b"\n", 1)
        except ValueError as error:
            raise RuntimeError(f"truncated cat-file output for {path}") from error
        parts = header.decode().split()
        if len(parts) < 3 or parts[1] != "blob":
            raise RuntimeError(f"unexpected cat-file header for {path}: {header!r}")
        size = int(parts[2])
        blob, data = data[:size], data[size:]
        if not data.startswith(b"\n"):
            raise RuntimeError(f"cat-file framing broken for {path}")
        data = data[1:]
        files[path] = blob
    if data:
        raise RuntimeError("trailing cat-file output")
    return files


def _git(repo: str | Path, *args: str, input: bytes | None = None) -> bytes:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        input=input,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode(errors="replace").strip()
        raise RuntimeError(detail or f"git {' '.join(args)} failed ({proc.returncode})")
    return proc.stdout


if __name__ == "__main__":
    sys.exit(main())
