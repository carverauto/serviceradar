#!/usr/bin/env python3
"""Boot-smoke the serviceradar-cnpg-analytics image.

Starts Postgres as UID 26 (CNPG default) with C collation + UTF8, CREATE
EXTENSION pg_duckdb, duckdb.query(), and a local Parquet COPY/read_parquet
round-trip. This is the digest-pin gate for @pgduckdb_18:

    bazel run //docker/images:cnpg_analytics_boot_smoke -- \\
        registry.carverauto.dev/serviceradar/serviceradar-cnpg-analytics:local

Load the image first with
`bazel run //docker/images:cnpg_analytics_image_amd64_tar`.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys

RUN_UID = os.environ.get("CNPG_ANALYTICS_UID", "26")
RUN_GID = os.environ.get("CNPG_ANALYTICS_GID", "26")
DEFAULT_IMAGE = "registry.carverauto.dev/serviceradar/serviceradar-cnpg-analytics:local"

INNER_SCRIPT = r"""
set -euo pipefail
export PATH=/usr/lib/postgresql/18/bin:/usr/bin:/bin
export PGDATA=/tmp/pgdata
export PGUSER=postgres
rm -rf "$PGDATA"
initdb --locale=C --encoding=UTF8 --auth=trust >/tmp/initdb.log
{
  echo "shared_preload_libraries = 'pg_duckdb'"
  echo "listen_addresses = ''"
  echo "unix_socket_directories = '/tmp'"
  echo "logging_collector = off"
} >> "$PGDATA/postgresql.conf"
pg_ctl -D "$PGDATA" -w -o "-k /tmp" start >/tmp/pg_ctl.log
psql -v ON_ERROR_STOP=1 -h /tmp -d postgres -tA <<'SQL'
SELECT datcollate FROM pg_database WHERE datname = current_database();
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
SELECT extversion FROM pg_extension WHERE extname = 'pg_duckdb';
SELECT * FROM duckdb.query('SELECT 1 AS smoke_ok');
COPY (SELECT 42 AS x) TO '/tmp/smoke.parquet' (FORMAT parquet);
SELECT count(*)::text || ':' || min(r['x'])::text FROM read_parquet('/tmp/smoke.parquet') r;
COPY (
  SELECT * FROM (VALUES
    (TIMESTAMPTZ '2026-09-14 12:00:00+00', 'gw-1', 'series-a', 10.0),
    (TIMESTAMPTZ '2026-09-14 12:01:00+00', 'gw-1', 'series-b', 20.0),
    (TIMESTAMPTZ '2026-09-14 12:02:00+00', 'gw-1', 'series-a', 30.0)
  ) AS t(ts, gateway_id, series_key, value)
) TO '/tmp/synthetic-timeseries.parquet' (FORMAT parquet);
SELECT count(*)::text || ':' || round(avg(r['value'])::numeric, 1)::text
  FROM read_parquet('/tmp/synthetic-timeseries.parquet') r;
SQL
pg_ctl -D "$PGDATA" -w stop >/tmp/pg_ctl_stop.log
"""


def _docker() -> str:
    path = shutil.which(os.environ.get("DOCKER_BIN", "docker"))
    if not path:
        raise SystemExit("docker is required for the analytics-image boot smoke")
    return path


def _run(docker: str, args: list[str], **kwargs) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [docker, *args],
        text=True,
        capture_output=True,
        check=False,
        **kwargs,
    )


def main(argv: list[str]) -> int:
    image = argv[1] if len(argv) > 1 else os.environ.get("CNPG_ANALYTICS_IMAGE", DEFAULT_IMAGE)
    docker = _docker()
    name = f"cnpg-analytics-smoke-{os.getpid()}"
    print(f"==> Boot-smoking analytics image: {image} as {RUN_UID}:{RUN_GID}")
    try:
        started = _run(
            docker,
            [
                "run",
                "-d",
                "--name",
                name,
                "--user",
                f"{RUN_UID}:{RUN_GID}",
                "--entrypoint",
                "sleep",
                image,
                "infinity",
            ],
        )
        if started.returncode != 0:
            sys.stderr.write(started.stderr)
            raise SystemExit(f"docker run failed: {started.returncode}")
        exec_proc = _run(
            docker,
            ["exec", "-u", f"{RUN_UID}:{RUN_GID}", name, "bash", "-lc", INNER_SCRIPT],
        )
        sys.stdout.write(exec_proc.stdout)
        if exec_proc.returncode != 0:
            sys.stderr.write(exec_proc.stderr)
            logs = _run(docker, ["logs", name])
            sys.stderr.write(logs.stdout)
            sys.stderr.write(logs.stderr)
            raise SystemExit(f"boot smoke failed with {exec_proc.returncode}")
        lines = [line.strip() for line in exec_proc.stdout.splitlines() if line.strip()]
        # Expected trailing query results: C, <version>, 1, 1:42, 3:20.0
        if len(lines) < 5:
            print("FAILED: unexpected psql output", file=sys.stderr)
            raise SystemExit(f"unexpected psql output: {lines!r}")
        datcollate, extversion, one, roundtrip, synthetic = lines[-5:]
        if datcollate != "C":
            print("FAILED: collation", file=sys.stderr)
            raise SystemExit(f"expected datcollate='C', got {datcollate!r}")
        if not extversion:
            print("FAILED: pg_duckdb missing", file=sys.stderr)
            raise SystemExit("pg_duckdb extension did not install")
        if one != "1":
            print("FAILED: duckdb.query", file=sys.stderr)
            raise SystemExit(f"duckdb.query returned {one!r}")
        if roundtrip != "1:42":
            print("FAILED: parquet round-trip", file=sys.stderr)
            raise SystemExit(f"parquet round-trip returned {roundtrip!r}, expected '1:42'")
        if synthetic != "3:20.0":
            print("FAILED: synthetic timeseries aggregate", file=sys.stderr)
            raise SystemExit(
                f"synthetic batch returned {synthetic!r}, expected '3:20.0' (count:avg)"
            )
        print(
            f"==> PASS: {image} boots with C collation, pg_duckdb {extversion}, "
            "Parquet round-trip, and synthetic 3-row avg=20.0"
        )
        return 0
    finally:
        _run(docker, ["rm", "-f", name])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
