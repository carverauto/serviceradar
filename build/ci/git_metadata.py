import os
from pathlib import Path
import re
import subprocess


class MetadataError(ValueError):
    pass


class GitMetadata:
    def __init__(self, workspace, runner=subprocess.run):
        self.workspace = Path(workspace).resolve()
        self.runner = runner

    def git(self, *args, allowed=(0,)):
        try:
            result = self.runner(
                ["git", "-C", str(self.workspace), *args],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
        except OSError as error:
            raise MetadataError("Git is unavailable") from error
        if result.returncode not in allowed:
            raise MetadataError("Git metadata command failed")
        return result

    def verify(self, expected_commit=None):
        root = os.fsdecode(self.git("rev-parse", "--show-toplevel").stdout).rstrip("\n")
        if Path(root).resolve() != self.workspace:
            raise MetadataError("Workspace must equal the Git worktree root")
        entries = parse_index(self.git("ls-files", "--stage", "-z", "--full-name").stdout)
        if expected_commit is not None:
            if not re.fullmatch(r"[0-9a-f]{40}", expected_commit):
                raise MetadataError("Expected commit must be a full SHA")
            actual = self.git("rev-parse", "--verify", expected_commit + "^{commit}").stdout.strip()
            if actual != expected_commit.encode():
                raise MetadataError("Expected source revision is not a commit")
            self.git("diff-index", "--cached", "--quiet", expected_commit, "--")
        links = {path for path, (mode, _) in entries.items() if mode == "160000"}
        modules = entries.get(".gitmodules")
        config = b""
        if modules:
            mode, oid = modules
            if mode not in ("100644", "100755"):
                raise MetadataError("Indexed .gitmodules must be a regular file")
            result = self.git("config", "--no-includes", "--null", "--blob", oid,
                              "--get-regexp", r"^submodule\..*\.(path|url)$", allowed=(0, 1))
            config = result.stdout
        validate_mappings(links, config)
        return len(links)


def safe_path(path):
    parts = path.split("/")
    return (bool(path) and not path.startswith("-") and "\\" not in path
            and not any(ord(char) < 32 or ord(char) == 127 for char in path)
            and all(part not in ("", ".", "..") and part.lower() != ".git" for part in parts)
            and not re.match(r"^[A-Za-z]:", path))


def parse_index(data):
    entries = {}
    if data and not data.endswith(b"\0"):
        raise MetadataError("Malformed index output")
    for record in data.split(b"\0")[:-1]:
        try:
            header, raw_path = record.split(b"\t", 1)
            mode, oid, stage = header.decode("ascii").split(" ")
            path = os.fsdecode(raw_path)
        except (ValueError, UnicodeError) as error:
            raise MetadataError("Malformed index entry") from error
        if stage != "0":
            raise MetadataError("Unresolved index entries")
        if path in entries or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", oid):
            raise MetadataError("Ambiguous index entry")
        entries[path] = (mode, oid)
    return entries


def validate_mappings(links, config):
    sections = {}
    if config and not config.endswith(b"\0"):
        raise MetadataError("Malformed indexed submodule configuration")
    for record in config.split(b"\0")[:-1]:
        try:
            raw_key, value = record.split(b"\n", 1)
            key = raw_key.decode("utf-8")
            section, field = key.rsplit(".", 1)
        except (ValueError, UnicodeError) as error:
            raise MetadataError("Malformed indexed submodule configuration") from error
        if not section.startswith("submodule.") or field not in ("path", "url"):
            raise MetadataError("Unexpected submodule configuration key")
        fields = sections.setdefault(section, {})
        if field in fields:
            raise MetadataError("Duplicate submodule mapping")
        fields[field] = value
    paths = set()
    for fields in sections.values():
        if set(fields) != {"path", "url"} or not fields["url"].strip():
            raise MetadataError("Submodule requires one path and one nonempty URL")
        path = os.fsdecode(fields["path"])
        if not safe_path(path) or path in paths:
            raise MetadataError("Unsafe or ambiguous submodule path")
        paths.add(path)
    if any(not safe_path(path) for path in links) or not links.issubset(paths):
        raise MetadataError("Indexed gitlinks and submodule registrations differ")
    if any("/".join(path.split("/")[:depth]) in paths
           for path in paths for depth in range(1, len(path.split("/")))):
        raise MetadataError("Overlapping submodule paths")
