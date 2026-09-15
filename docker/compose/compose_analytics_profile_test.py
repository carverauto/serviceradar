"""Source contracts for the opt-in compose analytics-store profile.

Reads docker-compose.yml (not a running stack). Fails closed if the default
path grows an analytics-head, if Timescale lands on the head, or if the
superseded postgres_fdw stitch comes back.
"""

from __future__ import annotations

from pathlib import Path
import unittest


def _read(name: str) -> str:
    here = Path(__file__).resolve().parent
    candidates = [here / name]
    for parent in here.parents:
        candidates.append(parent / name)
        candidates.append(parent / "docker" / "compose" / name)
    for cand in candidates:
        if cand.is_file() and cand.name == name:
            return cand.read_text()
    raise FileNotFoundError(name)


class ComposeAnalyticsProfileTest(unittest.TestCase):
    def setUp(self) -> None:
        self.compose = _read("docker-compose.yml")
        self.init_sql = _read("analytics-head-init.sql")

    def test_default_compose_does_not_start_analytics_head_or_minio(self) -> None:
        for service in ("analytics-head:", "analytics-head-fs:", "minio:"):
            idx = self.compose.index(service)
            window = self.compose[idx : idx + 400]
            self.assertIn("profiles:", window, msg=f"{service} must be profile-gated")

    def test_opt_in_profiles_are_analytics_and_analytics_fs(self) -> None:
        head = self._service_block("analytics-head:")
        self.assertIn("- analytics", head)
        self.assertNotIn("timescaledb", head)
        self.assertIn("shared_preload_libraries=pg_duckdb", head)
        self.assertIn("duckdb.disabled_filesystems=LocalFileSystem", head)
        fs = self._service_block("analytics-head-fs:")
        self.assertIn("- analytics-fs", fs)
        self.assertNotIn("disabled_filesystems", fs)
        self.assertIn("/var/lib/serviceradar/analytics", fs)

    def test_minio_bucket_is_analytics_not_control_plane_backups(self) -> None:
        init = self._service_block("minio-init:")
        self.assertIn("serviceradar-analytics", init)
        self.assertNotIn("serviceradar-control-plane-db-backups", init)
        self.assertNotIn("serviceradar-cold", init)

    def test_head_init_does_not_create_postgres_fdw(self) -> None:
        self.assertIn("CREATE EXTENSION IF NOT EXISTS pg_duckdb", self.init_sql)
        self.assertNotIn("CREATE EXTENSION IF NOT EXISTS postgres_fdw", self.init_sql)
        self.assertIn("analytics-head-init.sql", self.compose)

    def test_core_and_web_default_to_timescale_driver(self) -> None:
        self.assertIn(
            "SERVICERADAR_ANALYTICS_STORE_DRIVER=${SERVICERADAR_ANALYTICS_STORE_DRIVER:-timescale}",
            self.compose,
        )
        core = self._service_block("core-elx:")
        self.assertNotIn("SERVICERADAR_ANALYTICS_STORE_DRIVER=pg_duckdb", core)

    def _service_block(self, heading: str) -> str:
        idx = self.compose.index(f"\n  {heading}")
        nxt = self.compose.find("\n  ", idx + 4)
        if nxt == -1:
            return self.compose[idx:]
        # Next top-level service starts at 2-space indent + name. Skip nested
        # 4-space keys by finding "\n  <non-space>".
        pos = idx + 4
        while True:
            nxt = self.compose.find("\n  ", pos)
            if nxt == -1:
                return self.compose[idx:]
            rest = self.compose[nxt + 3 : nxt + 4]
            if rest and rest not in (" ", "\n", "-", "#"):
                return self.compose[idx:nxt]
            pos = nxt + 3


if __name__ == "__main__":
    unittest.main()
