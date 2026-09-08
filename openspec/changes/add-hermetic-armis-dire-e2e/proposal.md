# Change: Add a hermetic Armis/DIRE regression E2E harness

## Why

The current Armis coverage is split across unit tests, a database-backed
integration test with hand-built updates, and live/demo smoke tests. It does
not exercise the complete path that failed in production:

`Armis API pagination -> Armis sync mapping -> DIRE identity reconciliation ->
TCP/PING availability ingestion -> Oban northbound run -> Armis bulk writes`.

The existing faker already models a 50,000-device Armis estate and DHCP-style
IP churn, but it is primarily deployed as a Kubernetes service. That makes the
most important regression test dependent on cluster resources and leaves the
identity/write-count contract unguarded in CI. The recent incident exposed the
gap: a run can complete successfully while withholding most devices because
identity-conflict handling, stale generic identifiers, or source metadata drift
has polluted the candidate set.

## What Changes

- Add a standalone, deterministic faker-backed Armis/DIRE E2E profile that runs
  without Kubernetes, NATS, a real Armis tenant, an agent, or a gateway.
- Reuse the real faker HTTP API and northbound capture endpoint, with a
  configurable small CI fixture and a 50,000-device release/stress profile.
- Drive the actual Armis pagination/mapping contract, ingest the resulting
  updates through DIRE, ingest representative ICMP and TCP sweep results, and
  execute the real northbound runner/Oban worker against the faker.
- Add regression scenarios for DHCP churn, active-IP collisions, pagination
  boundaries, source-scoped identifiers, stale generic Armis bridges,
  metadata disagreement, multiple typed Armis IDs, idempotent reruns, and
  repair/retry behavior.
- Assert exact cardinality and accounting: every clean Armis device gets one
  northbound custom-property update, intentional conflicts are the only skips,
  no generic `integration_id` is used as an Armis identity, and persisted run
  counts agree with the captured faker operations.
- Provide one ad-hoc command that provisions/uses a disposable local test
  database, starts and tears down faker, preserves diagnostics on failure, and
  can be invoked by CI as a hermetic integration job.
- Document the fast profile, the 50,000-device profile, required local tools,
  and the failure artifacts.

## Impact

- Affected specs: new `armis-dire-e2e` capability.
- Affected code: `go/cmd/faker`, the Armis sync test harness, core integration
  tests, E2E orchestration scripts, CI workflow configuration, and test
  documentation.
- Runtime production APIs and deployment topology are unchanged. The faker's
  test/debug controls remain local test support and must not be required by
  production integrations.
- The test uses a disposable local PostgreSQL database (or an explicitly
  supplied test DSN) but never reaches a shared CNPG/Kubernetes environment.
