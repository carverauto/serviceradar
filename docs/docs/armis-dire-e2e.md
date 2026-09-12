# Armis/DIRE end-to-end test

The hermetic Armis/DIRE test exercises the real faker API, Go Armis sync
driver, Core sync/results ingestion, sweep results, identity drift checks, and
the Armis northbound Oban worker. It does not require Kubernetes, NATS, an
agent, a gateway, or an Armis tenant. A disposable PostgreSQL/CNPG database is
the only external service.

## Local run

The harness requires a PostgreSQL test DSN. Provide an admin DSN as well so it
can create, migrate, inspect, and drop an isolated database for every run:

```bash
export SERVICERADAR_TEST_DATABASE_URL='postgres://user:password@localhost:5455/serviceradar?sslmode=require'
export SERVICERADAR_TEST_ADMIN_URL='postgres://admin:password@localhost:5455/postgres?sslmode=require'
export SERVICERADAR_TEST_DATABASE_CA_CERT_FILE=/path/to/root.pem
export SERVICERADAR_TEST_DATABASE_CERT=/path/to/client.pem
export SERVICERADAR_TEST_DATABASE_KEY=/path/to/client-key.pem

./scripts/test-armis-dire-e2e.sh --profile fast
```

Client certificate and key variables are needed only when the database
requires mutual TLS. `PGSSLROOTCERT`, `PGSSLCERT`, and `PGSSLKEY` are accepted
as equivalent libpq settings. The admin DSN is strongly recommended: without
it, the harness uses the supplied database directly and cannot guarantee a
fresh schema or clean up after a failed run.

The profiles are:

- `fast`: 2,500 devices, 997-device pages, deterministic IP churn, and a
  repeated fixture run.
- `scale`: 50,000 devices with the same pagination, churn, and assertions.

Use `ARMIS_E2E_FAST_DEVICES` or `ARMIS_E2E_SCALE_DEVICES` to tune a local run.
Use `ARMIS_E2E_KEEP_ARTIFACTS=1` or `--keep-artifacts` to retain successful-run
artifacts.

## Assertions

The fixture producer emits one JSONL record per normalized page and records the
source and run in `sync_meta`. The Core suite checks these cardinality
equations:

```text
fixture_updates = sum(page.count for run 0)
canonical_devices = typed_armis_identifiers = northbound_device_count
updated_count + skipped_count + error_count = device_count
error_count = 0 for a clean fixture
skipped_count = 0 for a clean fixture
```

The regression matrix additionally checks active-IP/DHCP churn, stale generic
Armis bridges, metadata disagreement, split generic/typed identifiers,
duplicate typed identifiers, multiple typed identifiers on one device, and the
same numeric Armis ID in separate sources. Armis typed identifiers are scoped
by source, so an ID such as `91001` in source A cannot select source B's device.

The suite also requires one scoped `integration_id` row per fixture device,
alongside its typed `armis_device_id` row. The identity contract and legacy
fallback are documented in the [DIRE identity model](./dire-identity-model.md#armis-integration-identity).

An `active_ip_conflict` audit entry during the churn case is expected evidence
that the old IP was reused. It is not an identity-conflict skip and must not
reduce the northbound candidate count. The test fails if any other conflict
category appears in the clean run.

## CI

The main CI workflow runs the fast profile when the SRQL fixture variables are
available. The scheduled `armis-dire-e2e` workflow runs the scale profile.
Both workflows use these repository secrets:

- `SRQL_TEST_DATABASE_URL`
- `SRQL_TEST_ADMIN_URL`

The fixture CA is fetched live from
`https://srql-fixture-ca.carverauto.dev/ca.crt`
(or `kubectl get secret srql-fixture-server-ca`). Do not store
`SRQL_TEST_DATABASE_CA_CERT` as a repository secret. The URL is LAN HTTPS
(Let's Encrypt on lan-shared-gateway), not a public VIP.

If the fixture cluster requires client certificates, provide their paths to
the runner through `SERVICERADAR_TEST_DATABASE_CERT` and
`SERVICERADAR_TEST_DATABASE_KEY` (or the corresponding `SRQL_TEST_DATABASE_*`
variables) before invoking the harness.

## Failure artifacts

Failures preserve a temporary directory printed by the harness. It contains
the generated faker configuration and log, the normalized fixture JSONL, the
producer summary, Core test output, the faker northbound capture, and the
`clean-run.json` / `identity-conflict-matrix.json` summaries written from
inside the Core test transaction. When the database connection is visible to
the shell, `integration-update-runs.txt` also contains the persisted rows.
This makes a count mismatch or unexpected identity category inspectable
without reconnecting to a live cluster.
