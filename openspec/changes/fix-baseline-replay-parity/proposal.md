# Change: Make a baseline install match a replayed install

## Why
A fresh database is created from the committed schema baseline, and every migration the
baseline covers is recorded as applied without running. The baseline was a `pg_dump
--schema-only` plus TimescaleDB hypertable and continuous-aggregate registration, so two
things a covered migration does never reached a fresh install:

- **Seed rows.** Settings singletons (availability, MTR, Mapbox, NetFlow, outbound mail), the
  built-in interface classification rules, the first-party plugin repository, the fleet
  dictionary epoch and the default SNMP profile were all missing. Two of these were seeded by
  hand in `SchemaBootstrap`; the rest were not. A missing `availability_settings` row stops the
  availability expiry worker for good, because it has no watermark to advance.
- **TimescaleDB policy state.** Compression settings, compression policies and retention
  policies were missing. Hypertables whose policies no runtime owner reconciles
  (`mtr_hops`, `mtr_traces`, `bmp_routing_events`, the `survey_*` tables, the endpoint
  inventory history tables, `capacity_forecasts`) were stored uncompressed and never expired.

Nothing detected either. The fixture lifecycle replays migrations rather than loading the
baseline, and the only baseline check compared `pg_dump` schema output.

## What Changes
- The baseline generator becomes a Bazel tool, `bazel run //build/schema_baseline:generate`,
  replacing `scripts/db/generate-platform-baseline.sh`. It keeps the existing sections byte for
  byte and adds two, both read from the replayed database's catalogs:
  - compression settings, compression policies and retention policies;
  - seed data: every row the migrations left in an application table, as one `INSERT` per row,
    leaving out columns whose default is not immutable so each install generates its own ids,
    epochs and timestamps. Oban jobs and the migration ledgers are not seed data.
  It refuses to generate when the catalog holds state it does not reproduce.
- The committed baseline is regenerated at the same `included_through`; only the two new
  sections change.
- `SchemaBootstrap` no longer seeds rows of its own; the baseline carries them.
- The freshness contract test fails when a covered migration inserts literal rows the baseline
  does not carry, or configures compression or retention the baseline does not restore.
- The bootstrap integration test compares a baseline-created database with the lane's replayed
  database for TimescaleDB compression settings and policy jobs, and checks the seeded rows.
- Databases already created from a baseline without this state are repaired after startup by
  `BaselineInstallRepairWorker`, enqueued once by migration
  `20261115233000_repair_baseline_install_state` on databases the baseline created. It applies
  the current baseline's own sections: compression settings to hypertables with compression
  off, compression and retention policies where none exists, and seed rows into empty tables.
  It skips `timeseries_metrics` compression, owned by `DataRetentionWorker`
  (`enable-timeseries-compression-on-baseline-installs`), and the default SNMP profile, owned
  by `add-standard-snmp-oid-templates`.

## Impact
- Affected specs: `database-bootstrap`
- Affected code: `build/schema_baseline/`, `elixir/serviceradar_core/priv/repo/baseline/`,
  `ServiceRadar.Repo.SchemaBootstrap`, `ServiceRadar.Repo.BaselineInstallRepairWorker`,
  `build/contracts/schema_baseline_freshness_test.py`,
  `database_bootstrap_integration_test.exs`
