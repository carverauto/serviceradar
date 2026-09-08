#!/usr/bin/env python3
"""
Sync Bazel npm __links repos after pnpm-lock changes.

Updates:
  - the explicit use_repo(npm, ...) block in MODULE.bazel under the
    "Expose select npm package repositories..." comment
  - @npm__...__links load statements in web/BUILD.bazel

How it works:
  1) Ensures Bazel has generated @npm repos (builds //web:node_modules if needed).
  2) Reads the generated @npm defs.bzl to discover actual npm__...__links repo names.
  3) Rewrites web/BUILD.bazel loads to the discovered names.
  4) Rewrites the MODULE.bazel use_repo block to match web/BUILD.bazel.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "MODULE.bazel"
WEB_BUILD = ROOT / "web" / "BUILD.bazel"


def run(cmd: List[str]) -> str:
    proc = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(cmd)}\n{proc.stderr}")
    return proc.stdout.strip()


def bazel_output_base() -> Path:
    return Path(run(["bazel", "info", "output_base"]))


def ensure_npm_generated(output_base: Path) -> Path:
    defs = output_base / "external" / "aspect_rules_js++npm+npm" / "defs.bzl"
    if defs.exists():
        return defs
    # Generate @npm repos.
    print("Generating @npm repos via bazel build //web:node_modules ...", file=sys.stderr)
    run(["bazel", "build", "//web:node_modules"])
    if not defs.exists():
        raise RuntimeError(f"expected generated defs at {defs} but not found")
    return defs


def parse_generated_links(defs_path: Path) -> List[str]:
    text = defs_path.read_text(encoding="utf-8")
    repos: List[str] = []
    # Matches: load("@@...+npm__pkg__ver__links//:defs.bzl", ...)
    for m in re.finditer(r'load\("@@[^"]*?(npm__[^"]+__links)//:defs\.bzl"', text):
        repos.append(m.group(1))
    # Deduplicate while preserving order.
    seen = set()
    out = []
    for r in repos:
        if r not in seen:
            out.append(r)
            seen.add(r)
    return out


def parse_repo_parts(repo: str) -> Optional[Tuple[str, str]]:
    m = re.match(r"^npm__(.+?)__(.+?)__links$", repo)
    if not m:
        return None
    return m.group(1), m.group(2)


def base_version(ver_peer: str) -> str:
    return ver_peer.split("_", 1)[0]


def semver_key(v: str) -> Tuple:
    # Best-effort semver-ish key: digits split by '.'; remainder is tie-breaker.
    parts = re.split(r"[.\-+]", v)
    nums = []
    rest = []
    for p in parts:
        if p.isdigit():
            nums.append(int(p))
        else:
            rest.append(p)
    return tuple(nums + rest)


def build_pkg_index(generated: Iterable[str]) -> Dict[str, List[str]]:
    index: Dict[str, List[str]] = {}
    for repo in generated:
        parts = parse_repo_parts(repo)
        if not parts:
            continue
        pkg, ver_peer = parts
        index.setdefault(pkg, []).append(repo)
    return index


def choose_repo_for_pkg(pkg: str, old_ver_peer: str, candidates: List[str]) -> str:
    if len(candidates) == 1:
        return candidates[0]
    old_base = base_version(old_ver_peer)
    exact_base = [c for c in candidates if parse_repo_parts(c) and base_version(parse_repo_parts(c)[1]) == old_base]
    pool = exact_base or candidates
    # Prefer highest base version.
    pool_sorted = sorted(
        pool,
        key=lambda c: semver_key(base_version(parse_repo_parts(c)[1] if parse_repo_parts(c) else "")),
        reverse=True,
    )
    return pool_sorted[0]


def update_web_build(generated_links: List[str], check: bool) -> List[str]:
    text = WEB_BUILD.read_text(encoding="utf-8")
    index = build_pkg_index(generated_links)

    def repl(m: re.Match) -> str:
        old_repo = m.group(1)
        parts = parse_repo_parts(old_repo)
        if not parts:
            return m.group(0)
        pkg, old_ver_peer = parts
        candidates = index.get(pkg)
        if not candidates:
            return m.group(0)
        new_repo = choose_repo_for_pkg(pkg, old_ver_peer, candidates)
        return m.group(0).replace(old_repo, new_repo)

    new_text = re.sub(r'"@?(npm__[^"]+__links)//:defs\.bzl"', repl, text)
    if new_text != text:
        if check:
            raise SystemExit("web/BUILD.bazel is out of date; run without --check to update")
        WEB_BUILD.write_text(new_text, encoding="utf-8")
        print(f"Updated {WEB_BUILD.relative_to(ROOT)}")

    # Return referenced repos after update.
    referenced = re.findall(r'"@?(npm__[^"]+__links)//:defs\.bzl"', new_text)
    # Deduplicate preserving order.
    seen = set()
    ordered = []
    for r in referenced:
        if r not in seen:
            ordered.append(r)
            seen.add(r)
    return ordered


def update_module_use_repo(
    referenced_links: List[str], generated_links: List[str], check: bool
) -> None:
    text = MODULE.read_text(encoding="utf-8")
    marker = "# Expose select npm package repositories required for Next.js build tooling."
    marker_idx = text.find(marker)
    if marker_idx == -1:
        raise RuntimeError("could not find npm expose marker in MODULE.bazel")

    # Find the use_repo block following the marker.
    after = text[marker_idx:]
    block_re = re.compile(
        r"(# Expose select npm package repositories required for Next\.js build tooling\.\nuse_repo\(\n\s*npm,\n)(?P<body>(?:\s*\"[^\"]+\",\n)+)(\)\n)",
        re.M,
    )
    m = block_re.search(after)
    if not m:
        raise RuntimeError("could not parse use_repo(npm, ...) block after marker")

    body_start = marker_idx + m.start("body")
    body_end = marker_idx + m.end("body")
    existing_body = text[body_start:body_end]
    existing_repos = re.findall(r'"([^"]+)"', existing_body)

    index = build_pkg_index(generated_links)

    def normalize_repo(repo: str) -> str:
        parts = parse_repo_parts(repo)
        if not parts:
            return repo
        pkg, old_ver_peer = parts
        candidates = index.get(pkg)
        if not candidates:
            return repo
        return choose_repo_for_pkg(pkg, old_ver_peer, candidates)

    desired: List[str] = []
    seen = set()
    # Preserve existing order, but update names to current generated repos.
    for repo in existing_repos:
        updated = normalize_repo(repo)
        if updated not in seen:
            desired.append(updated)
            seen.add(updated)
    # Ensure all repos referenced by web/BUILD are present.
    for repo in referenced_links:
        updated = normalize_repo(repo)
        if updated not in seen:
            desired.append(updated)
            seen.add(updated)

    new_body = "".join(f'    "{r}",\n' for r in desired)

    if existing_body != new_body:
        if check:
            raise SystemExit("MODULE.bazel npm use_repo block is out of date; run without --check to update")
        text = text[:body_start] + new_body + text[body_end:]
        MODULE.write_text(text, encoding="utf-8")
        print(f"Updated {MODULE.relative_to(ROOT)}")


def main() -> int:
    print(
        "Legacy Next.js Bazel npm link sync is disabled; serviceradar-web is deprecated.",
        file=sys.stderr,
    )
    return 1

    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="only check, do not write")
    args = ap.parse_args()

    output_base = bazel_output_base()
    defs = ensure_npm_generated(output_base)
    generated_links = parse_generated_links(defs)
    if not generated_links:
        raise RuntimeError(f"no npm __links repos parsed from {defs}")

    referenced_links = update_web_build(generated_links, check=args.check)
    update_module_use_repo(referenced_links, generated_links, check=args.check)

    print("NPM __links repos are in sync.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise
