#!/usr/bin/env python3
"""Extracts a version-specific section from the CHANGELOG."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract release notes from the changelog for a given version.")
    parser.add_argument("version", help="Version string to locate (with or without a leading 'v').")
    parser.add_argument(
        "-c",
        "--changelog",
        default="CHANGELOG",
        help="Path to the changelog file (default: CHANGELOG).",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=pathlib.Path,
        help="Optional file path to write the extracted notes to.",
    )
    parser.add_argument(
        "--strip-heading",
        action="store_true",
        help="Remove the matching heading line from the output.",
    )
    return parser.parse_args()


def normalise_version(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("Version cannot be blank")
    return value.lstrip("vV")


def extract_section(lines: list[str], version: str) -> list[str]:
    heading_pattern = re.compile(r"^#\s+.*?\bv?{}\b".format(re.escape(version)), re.IGNORECASE)
    start_idx: int | None = None

    for idx, line in enumerate(lines):
        if heading_pattern.search(line):
            start_idx = idx
            break

    if start_idx is None:
        return []

    end_idx = len(lines)
    for idx in range(start_idx + 1, len(lines)):
        if lines[idx].startswith("# ") and not heading_pattern.search(lines[idx]):
            end_idx = idx
            break

    section = lines[start_idx:end_idx]

    # Drop leading/trailing blank lines within the slice.
    while section and not section[0].strip():
        section.pop(0)
    while section and not section[-1].strip():
        section.pop()

    return section


def main() -> int:
    args = parse_args()

    changelog_path = pathlib.Path(args.changelog)
    if not changelog_path.is_file():
        print(f"Changelog file not found: {changelog_path}", file=sys.stderr)
        return 2

    target_version = normalise_version(args.version)

    with changelog_path.open("r", encoding="utf-8") as fp:
        lines = fp.read().splitlines()

    section = extract_section(lines, target_version)
    if not section:
        print(f"No changelog entry found for version {target_version}", file=sys.stderr)
        return 3

    if args.strip_heading and section and section[0].startswith("# "):
        section = section[1:]
        while section and not section[0].strip():
            section.pop(0)

    output_text = "\n".join(section).rstrip() + "\n"

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output_text, encoding="utf-8")
    else:
        sys.stdout.write(output_text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
