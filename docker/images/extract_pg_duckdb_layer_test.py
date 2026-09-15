"""Unit tests for extract_pg_duckdb_layer.py."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("extract_pg_duckdb_layer.py")


def _run(src: Path, dest: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--src", str(src), "--dest", str(dest)],
        capture_output=True,
        text=True,
        check=False,
    )


def _write(path: Path, content: str = "x") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


class ExtractPgDuckdbLayerTest(unittest.TestCase):
    def test_copies_so_control_sql_and_optional_libduckdb(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            dest = Path(tmp) / "dest"
            _write(src / "usr/lib/postgresql/18/lib/pg_duckdb.so", "so")
            _write(src / "usr/lib/postgresql/18/lib/libduckdb.so", "duck")
            _write(src / "usr/share/postgresql/18/extension/pg_duckdb.control", "control")
            _write(src / "usr/share/postgresql/18/extension/pg_duckdb--1.1.1.sql", "sql")
            _write(src / "usr/share/postgresql/18/extension/unrelated.control", "nope")
            result = _run(src, dest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((dest / "usr/lib/postgresql/18/lib/pg_duckdb.so").is_file())
            self.assertTrue((dest / "usr/lib/postgresql/18/lib/libduckdb.so").is_file())
            self.assertTrue(
                (dest / "usr/share/postgresql/18/extension/pg_duckdb.control").is_file()
            )
            self.assertTrue(
                (dest / "usr/share/postgresql/18/extension/pg_duckdb--1.1.1.sql").is_file()
            )
            self.assertFalse(
                (dest / "usr/share/postgresql/18/extension/unrelated.control").exists()
            )

    def test_fails_when_so_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            dest = Path(tmp) / "dest"
            _write(src / "usr/share/postgresql/18/extension/pg_duckdb.control", "control")
            result = _run(src, dest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("pg_duckdb.so", result.stderr)

    def test_refuses_forbidden_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            dest = Path(tmp) / "dest"
            _write(src / "usr/lib/postgresql/18/lib/pg_duckdb.so", "so")
            _write(src / "usr/share/postgresql/18/extension/pg_duckdb.control", "control")
            # A malicious/mis-extracted rootfs that also carries Timescale.
            os.symlink(
                "timescaledb.so",
                src / "usr/lib/postgresql/18/lib/pg_duckdb_timescaledb_alias",
            )
            # The copy walk only picks pg_duckdb.so / libduckdb* / pg_duckdb*.
            # Drop a timescaledb-named sibling that the lib copier would take
            # if the filter were wrong: libduckdb-timescaledb.so
            _write(src / "usr/lib/postgresql/18/lib/libduckdb-timescaledb.so", "nope")
            result = _run(src, dest)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("forbidden", result.stderr)


if __name__ == "__main__":
    unittest.main()
