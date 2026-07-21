## Context

ServiceRadar has two relevant test surfaces today:

- `go/cmd/faker` is a real HTTP Armis emulator with pagination, persisted
  devices, northbound bulk-property capture, and background IP shuffling. Its
  default dataset is 50,000 devices.
- `serviceradar_core` has database-backed DIRE and northbound integration tests,
  but those tests generally construct updates directly and do not consume the
  faker's API or assert the complete outbound population.

The production failure involved identity state accumulated across runs, so a
test that only asserts that one request succeeds is insufficient. The harness
must preserve the real page boundaries and exercise the same database-backed
identity and availability paths used by the application.

## Goals / Non-Goals

- Goals:
  - Run the closed-loop Armis/DIRE/northbound path on a developer workstation
    or a CI runner without Kubernetes.
  - Make identity and write-count failures deterministic and diagnosable.
  - Cover both a fast, repeatable CI profile and a 50,000-device scale profile.
  - Keep the faker as the only Armis HTTP dependency; never call a real Armis
    tenant from this suite.
- Non-goals:
  - Replace unit tests for the Armis HTTP client or individual DIRE policies.
  - Reproduce the full production agent/gateway/NATS deployment in this test.
  - Automatically decide how genuinely ambiguous multi-ID devices should be
    merged in production.
  - Make the live/demo database part of CI.

## Decisions

### 1. Use the real faker as a child process

The orchestrator will build or locate `serviceradar-faker`, write a temporary
configuration, start it on loopback, wait for the access-token endpoint, and
tear it down with a trap. BGP simulation is disabled. The configuration will
accept:

- device count, defaulting to a small count for normal CI and allowing 50,000
  for the scale profile;
- a generation seed so device IDs, MAC history, and fixture selection are
  reproducible;
- a fast churn profile and an explicit deterministic churn trigger for tests
  that must not depend on wall-clock timing.

The existing northbound capture/reset endpoint is the assertion surface. The
faker will expose only the minimum additional readiness/fixture controls
needed to make startup and churn deterministic; no production integration will
depend on those controls.

### 2. Separate the disposable database from cluster infrastructure

The E2E command will accept the repository's test database URL contract. When
no URL is supplied, it will start an isolated local PostgreSQL instance using
the repository's supported local container tooling, create a uniquely named
test database, run core migrations, and remove the instance/database during
cleanup. It will never discover or port-forward a Kubernetes CNPG resource.

Core tests will use `ServiceRadar.DataCase` and the existing test support, with
Oban in manual mode unless a scenario explicitly performs the worker. This
keeps identity assertions transactional while still exercising the persisted
run/history records.

### 3. Preserve the real Armis page and update contracts

The harness will use the actual Armis sync driver contract to fetch faker pages
of at most 1,000 devices. A small Go fixture producer will invoke
`syncsources/armis.NewDriver`, apply the same generic update normalization as
the runtime, and persist page/chunk metadata plus the emitted update maps to a
temporary JSONL artifact. The Elixir E2E test will ingest those chunks through
the same core result/update entry point used by sync results.

This avoids silently replacing the Go adapter with an Elixir-only JSON mapper,
while keeping the process boundary simple and making the emitted fixture
available in failure diagnostics.

### 4. Exercise availability through the inventory path

After discovery ingestion, the test will submit deterministic synthetic sweep
payloads containing both ICMP and TCP outcomes through the core sweep/results
ingestor. It will not write device availability columns directly. The fixture
will include available, unavailable, and mixed-mode records so the northbound
candidate query must use consolidated canonical state.

### 5. Make identity corruption explicit and bounded

The test data will start clean, then apply controlled database fixtures to a
small known subset:

- an old Armis generic `integration_id` bridge on a different device;
- metadata whose Armis ID disagrees with the typed identifier;
- one device carrying two typed `armis_device_id` values;
- the same typed Armis ID on two devices;
- an active-IP collision during a faker churn cycle;
- the same numeric source ID in a second source, proving source scoping.

Each fixture records the expected disposition. The test must prove that clean
devices continue to update, conflicted devices are withheld with the expected
category, and no conflict row or category-count duplication makes the run look
like thousands of additional skipped devices. The repair scenario applies only
the safe repair set, reruns the northbound worker, and verifies that repaired
devices rejoin the update population while ambiguous devices remain visible.

### 6. Test both direct and scheduled execution

The main assertions will call the runner with a real faker endpoint so failures
are easy to localize. A separate scenario will enqueue and perform the real
`ArmisNorthboundRunWorker` job in Oban test mode, then assert the persisted run
status, counts, and idempotent uniqueness behavior. This covers the Settings
UI's “run northbound now” path without requiring Phoenix or browser state.

### 7. Provide deterministic scale tiers

- `fast`: a few thousand devices, page size deliberately not dividing the
  device count, multiple churn/collision cycles, and all corruption fixtures;
- `scale`: 50,000 devices, 1,000-device pages, repeated churn, bounded
  identifier cardinality checks, and the same exact-count northbound contract.

The fast tier is suitable for every relevant CI change. The scale tier is an
ad-hoc/release gate or a scheduled CI job so normal pull requests remain
bounded while the production cardinality risk stays continuously tested.

## Risks / Trade-Offs

- Starting PostgreSQL locally adds a Docker/runtime prerequisite. Mitigation:
  accept an explicit test DSN and fail with a clear command, while keeping the
  default path self-provisioning and isolated.
- The 50,000-device tier consumes more CPU, memory, and database time.
  Mitigation: keep it opt-in or scheduled and make the fast tier cover the same
  identity transitions at smaller cardinality.
- A fixture can become coupled to table details. Mitigation: inject identity
  corruption through the existing identity/resource APIs where possible, and
  reserve raw SQL for narrowly documented legacy-row fixtures that cannot be
  created through current APIs.
- Synthetic sweep results do not measure ICMP/TCP network behavior. Mitigation:
  retain collector/sweeper unit coverage and use this suite specifically to
  validate persisted availability-to-Armis correlation.

## Migration Plan

1. Add the proposal and approve the test contract.
2. Add faker deterministic test controls and the Go fixture producer.
3. Add the core E2E scenario and disposable database orchestration.
4. Run the fast profile locally, then run the 50,000-device profile and fix
   any performance/cardinality issues it exposes.
5. Add the fast profile to CI and the scale profile to an ad-hoc/scheduled
   workflow.
6. Document artifacts, invocation, and the expected count equations.

## Open Questions

- Should the disposable PostgreSQL default use `docker run postgres` or a
  repository-owned Docker Compose profile to match local CNPG extensions?
- Should the scale tier run on every merge queue execution or on a scheduled
  workflow plus release candidates?
- Which exact persisted identity fixtures should be created through Ash APIs
  versus a dedicated test-only legacy-row helper?
