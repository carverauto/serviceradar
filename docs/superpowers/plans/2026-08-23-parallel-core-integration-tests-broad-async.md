# Broad Async Core Integration Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the exact-SHA BuildBuddy ordinary integration lifecycle p95 by at least 50% versus the controlled before cohort, keep the after p95 at 90 seconds or less, and report whether the 60% stretch is reached, with no isolation regression.

**Architecture:** Use exactly one async BEAM at frozen cap eight plus one through seven deterministic serial BEAM lanes at cap one. Each lane receives its own disposable `sr_core_test_<run>_<lane>` clone on `srql-fixtures`; demo and production databases are forbidden. Inventory every selected ExUnit module plus zero-selected source, run transaction-owned async modules in the async lane, reserve `serial_0` for fixed-external sources, and place remaining serial sources by deterministic LPT before any timing. Pin every Repo pool at 12, permit at most eight test BEAMs and 96 configured pool slots, and fail closed when fixture capacity cannot fund the topology. CPU diagnostics and authoritative cohorts use that frozen source map; there is no topology challenger matrix.

**Tech Stack:** Elixir 1.19, ExUnit, Ecto SQL Sandbox, Ash, Bazel/Starlark, Python `unittest`, Rust integration-database lifecycle targets, BuildBuddy Workflows.

**Spec:** `openspec/changes/parallelize-core-integration-tests/` (`proposal.md`, `design.md`, `benchmark.md`, `tasks.md`, and `specs/integration-test-execution/spec.md`)

## Global Constraints

- Work only in `/Users/mfreeman/src/serviceradar-wt-parallel-integration-tests` on `proposal/parallelize-integration-tests`.
- Use exactly one async lane at cap 8 and one through seven serial lanes at cap 1. `serial_0` is reserved for `fixed_external`; `load_only` sources run in no ordinary lane.
- Give every lane one disposable `sr_core_test_<run>_<lane>` clone on `srql-fixtures`. Demo and production databases are forbidden.
- Keep each lane pool at 12 and no more than eight test BEAMs / 96 configured pool slots. Calculate `safe_pool_budget = min(96, floor(0.90 * usable_client_slots))` and `serial_lanes = min(serial_source_count, max(1, floor(safe_pool_budget / 12) - 1))`; fail before provisioning if one async and one serial lane cannot be funded.
- Any pool headroom is only for processes supervised inside a test BEAM; it is never capacity reserved for deployed applications.
- Freeze the source map and lane count before CPU timing or cohorts. Later measurements cannot retune membership, caps, or lane count.
- Keep every integration Repo pool at exactly 12 throughout cap, CPU, topology, and cohort comparisons.
- Stage the broad async set through a complete observed `max_cases: 2` wave before raising the frozen async lane cap to 8.
- Every selected ExUnit module must have one unique disposition row; a zero-selected source gets one `load_only` sentinel, and every selected row in a retained source must share one async/serial mode.
- Never mark unboxed, DDL, `TRUNCATE`, materialized-view, fixed-external, Application-global, Oban-global, unfiltered telemetry/PubSub, fixed-registry, unmanaged-child, or true multi-connection behavior async.
- Do not add or extend a shell script. New executable behavior is a Bazel target.
- Do not read generated Bazel output. Consume targets, runfiles, BuildBuddy logs, and checked-in evidence only.
- Use `apply_patch` for edits, strict RED/GREEN TDD for behavior, and `--flaky_test_attempts=1` for every safety or acceptance wave.
- Keep built-in ExUnit slowest reporting out of all timed/gating runs; profiling uses a separate non-cohort trace at `max_cases: 1`.
- Do not push until the user authorizes the exact feature-branch refspec. Never push to `staging`.

## File Map

- `elixir/serviceradar_core/test/support/test_support.ex`: idempotent startup, cap parser, and Sandbox helpers.
- `elixir/serviceradar_core/test/test_helper.exs`: one-time suite configuration and expanded runner marker.
- `elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs`: startup and cap RED/GREEN regressions.
- `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`: exhaustive machine-readable async/serial/load-only inventory.
- `elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md`: human semantic evidence for promotions and blockers.
- `ci_heavy_gate_contract_test.py`: source-disposition, startup, runner, workflow, and topology drift checks.
- `elixir/serviceradar_core/test/support/integration_selection_formatter.ex`: stable selected identity output as `module|test_name`.
- `build/integration_selection_equivalence_test.py`: Bazel-owned two-run all-source versus pruned-source equivalence orchestration.
- `build/integration_shards.bzl`: lane cap/pool environment, dispositions, capacity preflight, and deterministic placement.
- `build/integration_shards_test.bzl`: deterministic placement, disposition, capacity, and source-map tests.
- `elixir/serviceradar_core/BUILD.bazel`: production async and serial lane targets.
- `rust/integration-db/BUILD.bazel`: exact database provisioning targets for the fixed lanes.
- `buildbuddy.yaml`: explicit CPU sizing and allowlisted benchmark topology selection.
- Audited test modules listed in Tasks 2-4: async promotions, source splits, and test-local namespace normalization.
- `openspec/changes/parallelize-core-integration-tests/{benchmark,tasks}.md`: raw diagnostic/cohort evidence and completion ledger.

## Implemented Prerequisites

The original implementation plan owns the already-built Sandbox owner split, async/unboxed guard, child allowance helper, initial two-module promotion, heavy-source extraction, cold-bootstrap move, observer, heavy BuildBuddy action, and exact-SHA release qualifier. This continuation does not rewrite those interfaces. Task 7 reruns their focused contracts and full heavy lifecycle so the new scheduling work cannot regress them.

---

### Task 1: Make suite startup concurrency-neutral

**Files:**
- Modify: `elixir/serviceradar_core/test/support/test_support.ex`
- Modify: `elixir/serviceradar_core/test/test_helper.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `BUILD.bazel`

**Interfaces:**
- Consumes: `TestSupport.start_core!/1` and the database-backed `test_helper.exs` branch.
- Produces: no-option startup that preserves Application state and one explicit suite-bootstrap configuration call.

- [ ] **Step 1: Write the startup RED tests**

Add these cases to the serial `ServiceRadar.TestSupportSandboxTest`, restoring the original setting in `on_exit`:

```elixir
test "no-option startup preserves the audit writer setting" do
  previous = Application.fetch_env(:serviceradar_core, :audit_writer_async?)
  Application.put_env(:serviceradar_core, :audit_writer_async?, true)

  on_exit(fn -> restore_env(:audit_writer_async?, previous) end)

  assert :ok = TestSupport.start_core!(sandbox_owner?: false)
  assert Application.fetch_env!(:serviceradar_core, :audit_writer_async?)
end

test "explicit startup configures synchronous audit writes" do
  previous = Application.fetch_env(:serviceradar_core, :audit_writer_async?)
  Application.put_env(:serviceradar_core, :audit_writer_async?, true)

  on_exit(fn -> restore_env(:audit_writer_async?, previous) end)

  assert :ok =
           TestSupport.start_core!(
             sandbox_owner?: false,
             synchronous_audit_writes?: true
           )

  refute Application.fetch_env!(:serviceradar_core, :audit_writer_async?)
end
```

Add private `restore_env/2` using the existing `{:ok, value} | :error` snapshot shape. Run the Bazel shard owning this source and verify the first case fails because `start_core!/1` currently overwrites the setting.

- [ ] **Step 2: Implement explicit-only global configuration**

Replace the unconditional mutation in `start_core!/1` with:

```elixir
if Keyword.has_key?(opts, :synchronous_audit_writes?) do
  Application.put_env(
    :serviceradar_core,
    :audit_writer_async?,
    not Keyword.fetch!(opts, :synchronous_audit_writes?)
  )
end
```

Change the database-backed branch in `test_helper.exs` to call:

```elixir
ServiceRadar.TestSupport.start_core!(
  sandbox_owner?: false,
  sandbox_mode: :manual,
  synchronous_audit_writes?: true
)
```

Run the focused shard again and require both cases to pass.

- [ ] **Step 3: Add startup drift assertions and verify**

In the Python contract assert that `test_helper.exs` passes `synchronous_audit_writes?: true` exactly once and `start_core!/1` guards the Application mutation with `Keyword.has_key?`.

```bash
bazel test -c opt --config=remote //:ci_heavy_gate_contract_test
git diff --check
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add elixir/serviceradar_core/test/support/test_support.ex \
  elixir/serviceradar_core/test/test_helper.exs \
  elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs \
  ci_heavy_gate_contract_test.py BUILD.bazel
git commit -m "test(elixir): make integration startup concurrency neutral"
```

---

### Task 2: Promote the nine full-module broad-wave candidates

**Files:**
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/seeder_reconciliation_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_delivery_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_grouping_integration_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/action_redemption_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/test_delivery_isolation_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/suppression_dedupe_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/remediation/dire_remediation_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_results_flow_e2e_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/agent_config_credential_delivery_test.exs`
- Modify: `elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md`
- Modify: `elixir/serviceradar_core/BUILD.bazel`
- Modify: `BUILD.bazel`
- Modify: `ci_heavy_gate_contract_test.py`

**Interfaces:**
- Consumes: idempotent suite startup and the existing narrow `ASYNC_SAFE_SRCS` contract.
- Produces: nine additional `async: true` DataCase modules representing about 574 profiled case-seconds.

- [ ] **Step 1: Declare the contract inputs and make the static contract RED**

In the core BUILD file, add a deliberately scoped `integration_contract_test_inputs` filegroup over `ALL_TEST_SRCS` plus `test/ASYNC_INTEGRATION_AUDIT.md` and `test/test_helper.exs`. Replace the root Python target's individually enumerated ordinary test inputs with that filegroup while retaining separately source-separated release-gate inputs. This makes every existing and future ordinary `*_test.exs` file a declared runfile without listing the entire tree in the root package.

Then add the nine exact paths to `ASYNC_SAFE_SRCS`. Extend `ASYNC_INTEGRATION_AUDIT.md` with caller-owned transaction, unique identifier, child-process, registry/cache cleanup, and indirect-runtime evidence for each source. Run the Bazel-owned Python contract and require RED because the modules still declare `async: false` and call redundant startup.

- [ ] **Step 2: Perform the minimal module conversions**

In each of the nine files change the declaration to:

```elixir
use ServiceRadar.DataCase, async: true
```

Delete only the redundant block:

```elixir
setup_all do
  TestSupport.start_core!()
  :ok
end
```

Remove aliases that become unused. Do not alter assertions, production APIs, workload sizes, rate-limiter semantics, or ProcessRegistry behavior; credential delivery already includes its unique `agent_uid` in the registry key.

- [ ] **Step 3: Format and run static verification**

```bash
cd elixir/serviceradar_core
mix format --check-formatted \
  test/serviceradar/notifications/seeder_reconciliation_test.exs \
  test/serviceradar/notifications/dispatcher_delivery_test.exs \
  test/serviceradar/notifications/dispatcher_grouping_integration_test.exs \
  test/serviceradar/notifications/action_redemption_test.exs \
  test/serviceradar/notifications/test_delivery_isolation_test.exs \
  test/serviceradar/notifications/suppression_dedupe_test.exs \
  test/serviceradar/inventory/remediation/dire_remediation_test.exs \
  test/serviceradar/sweep_jobs/sweep_results_flow_e2e_test.exs \
  test/serviceradar/edge/agent_config_credential_delivery_test.exs
cd ../..
bazel test -c opt --config=remote //:ci_heavy_gate_contract_test
```

Expected: PASS.

- [ ] **Step 4: Run the cap-two collision wave**

Provision fresh `s0..s7` databases with the guarded lifecycle, run all eight ordinary targets once in a single Bazel invocation with `--flaky_test_attempts=1 --nocache_test_results --noremote_upload_local_results --test_output=all`, and require every marker to report cap two, trace off, and timeouts enabled. Search the complete output for ownership errors, queue drops, deadlocks, and failures; then require two zero run-scoped observer samples and successful teardown.

If a candidate fails, preserve its row and log, return only that source to its concrete serial reason, and rerun the entire wave. A focused green module does not override a red whole-wave interaction.

- [ ] **Step 5: Commit**

```bash
git add BUILD.bazel ci_heavy_gate_contract_test.py \
  elixir/serviceradar_core/BUILD.bazel \
  elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md \
  elixir/serviceradar_core/test/serviceradar/notifications/seeder_reconciliation_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_delivery_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_grouping_integration_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/action_redemption_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/test_delivery_isolation_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/suppression_dedupe_test.exs \
  elixir/serviceradar_core/test/serviceradar/inventory/remediation/dire_remediation_test.exs \
  elixir/serviceradar_core/test/serviceradar/sweep_jobs/sweep_results_flow_e2e_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/agent_config_credential_delivery_test.exs
git commit -m "test(elixir): run audited database modules concurrently"
```

---

### Task 3: Split mixed notification and endpoint modules

**Files:**
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/endpoint_inventory_ingestor_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/inventory/endpoint_inventory_ingestor_race_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_routing_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_routing_pubsub_serial_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_edge_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_telemetry_test.exs`
- Modify: `elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `build/integration_shards.bzl`

**Interfaces:**
- Consumes: per-test Sandbox owners and exact async/serial dispositions.
- Produces: async bulk modules plus serial files containing only the unboxed freshness race and fixed-topic PubSub negative assertion.

- [ ] **Step 1: Write RED split/namespace contracts**

Add the future bulk paths to `ASYNC_SAFE_SRCS` and the endpoint-race/PubSub paths to exact required-serial sets. Extend the Python test to require the original bulk sources contain no `@tag sandbox: :unboxed` and no literal `"notifications:stream"`. Require DispatcherEdge to contain no fixed `@assignment_id` and require telemetry receives to route through `receive_matching_telemetry/4` or `refute_matching_telemetry/3`. Run the contract and observe RED. The scoped `integration_contract_test_inputs` filegroup from Task 2 declares both new companion files automatically as soon as they exist, so the Bazel-owned GREEN run does not depend on undeclared source-tree access.

- [ ] **Step 2: Extract the endpoint freshness race**

Move the complete test named `concurrent freshness observations cross the reconcile floor atomically` and only the helpers it calls into `ServiceRadar.Inventory.EndpointInventoryIngestorRaceTest`, declared:

```elixir
use ServiceRadar.DataCase, async: false
@moduletag :integration
@moduletag sandbox: :unboxed
```

Keep its two real connections, readiness messages, one-winner ordering, and `cleanup_unboxed_inventory/2` unchanged. Remove the race and now-unused helpers from the bulk file, remove redundant startup there, and declare the bulk module async.

- [ ] **Step 3: Extract the fixed PubSub negative assertion**

Move only `publishes no envelope and still records the suppression` into `ServiceRadar.Notifications.DispatcherRoutingPubSubSerialTest`. Keep the live subscription probe, literal topic, `assert_receive`, and `refute_receive` intact. Duplicate the smallest required record builders in the serial file; do not expose production-only helper APIs. The remaining routing module removes redundant startup and becomes async.

- [ ] **Step 4: Normalize DispatcherEdge identifiers**

Remove fixed `@assignment_id`. In setup create:

```elixir
assignment_id = Ash.UUID.generate()
platform_agent_uid = "k8s-agent-#{System.unique_integer([:positive])}"

{:ok,
 actor: SystemActor.system(:notification_edge_test),
 assignment_id: assignment_id,
 platform_agent_uid: platform_agent_uid}
```

Pass those values through builders and `StubTarget` process-dictionary configuration instead of module attributes or `"k8s-agent"`. Registry keys include the per-test agent UID and partition. The process that owns a Horde registration must unregister it before returning; if ownership belongs to a test-owned child, stop that child and assert bounded eventual disappearance. An `on_exit` process must never unregister on behalf of another owner. Remove redundant startup and mark the module async.

- [ ] **Step 5: Filter telemetry by test-owned IDs**

Add these private helpers to DispatcherTelemetryTest:

```elixir
defp receive_matching_telemetry(event, predicate, timeout_ms, deadline_ms \\ nil)
defp refute_matching_telemetry(event, predicate, timeout_ms)
```

The receive helper computes one monotonic deadline, ignores foreign telemetry messages, and returns the first `{measurements, metadata}` for which `predicate.(metadata)` is true. The refute helper ignores foreign events for the entire bounded interval and fails only on a matching event. Convert every assertion to filter by the alert or delivery ID created by that test. Remove redundant startup and mark the module async.

- [ ] **Step 6: Verify and commit the split wave**

Run formatting, the Python contract, the Starlark topology test, and one complete observed cap-two wave. Inject one foreign PubSub message and one foreign telemetry event in focused regressions; prove neither satisfies nor fails another test's filtered assertion. Require new files to appear exactly once across generated source sets and unsafe files to remain serial.

```bash
git add ci_heavy_gate_contract_test.py build/integration_shards.bzl \
  elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md \
  elixir/serviceradar_core/test/serviceradar/inventory/endpoint_inventory_ingestor_test.exs \
  elixir/serviceradar_core/test/serviceradar/inventory/endpoint_inventory_ingestor_race_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_routing_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_routing_pubsub_serial_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_edge_test.exs \
  elixir/serviceradar_core/test/serviceradar/notifications/dispatcher_telemetry_test.exs
git commit -m "test(elixir): split global-state integration cases"
```

---

### Task 4: Normalize the second async wave and retain hard blockers

**Files:**
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/agent_gateway_sync_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/edge/agent_gateway_sync_release_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/remote_access_sessions_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/edge/remote_access_sessions_serial_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/agent_command_bus_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/edge/agent_command_bus_status_handler_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/sync_batch_resolution_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/sync_ingestor_discovery_sources_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/hypervisor_enrichment_ingestor_db_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/inventory/identity_reconciler_merge_guard_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/scans/adhoc_scan_nats_fixture_config_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/plugins/anomaly_addon_profile_seeder_test.exs`
- Create: `elixir/serviceradar_core/test/serviceradar/plugins/anomaly_addon_profile_seeder_db_test.exs`
- Create: `elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`
- Create: `elixir/serviceradar_core/test/support/integration_selection_formatter.ex`
- Create: `build/integration_selection_equivalence_test.py`
- Modify: `elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `BUILD.bazel`
- Modify: `elixir/serviceradar_core/BUILD.bazel`
- Modify: `build/BUILD.bazel`
- Modify: `build/integration_shards.bzl`
- Modify: `build/integration_shards_test.bzl`
- Modify: `rust/integration-db/BUILD.bazel`

**Interfaces:**
- Consumes: split-file contract and filtered global-event pattern from Task 3.
- Produces: about 1,150 trace-instrumented case-seconds classified async plus an exhaustive final async/quarantine inventory. These values are relative placement weights, not wall-time forecasts.

- [ ] **Step 1: Add RED per-resource contracts**

For each candidate, add its future bulk path to `ASYNC_SAFE_SRCS` and its unsafe companion to an exact required-serial set before code edits. Extend the contract to reject whole-table RateLimiter clearing, fixed cache keys/IPs, unfiltered telemetry forwarding, module-level release-key mutation, and unboxed tags in async sources. Run RED.

- [ ] **Step 2: Split AgentGatewaySync release signing**

Move `version-bearing upsert reconciles active release target`, its Ed25519 constants, `publish_test_release/2`, and the `agent_release_public_key` snapshot/restore into serial source `agent_gateway_sync_release_test.exs` as `ServiceRadar.Edge.AgentGatewaySyncReleaseTest`. The remaining enrollment/heartbeat module removes Application mutation and redundant startup, retains unique agent IDs, and becomes async.

- [ ] **Step 3: Split RemoteAccessSessions by ownership mode**

Move `attach ticket consume is atomic under concurrent replay`, `approved access request bind rolls back losing concurrent session creates`, and all cases that mutate SSH/recording Application configuration into `remote_access_sessions_serial_test.exs` with their exact unboxed cleanup. Keep ordinary caller-owned ticket/session CRUD in the async source. Do not convert real lock races to boxed transactions.

- [ ] **Step 4: Split AgentCommandBus global workers**

Move cases that start or depend on the application-supervised `StatusHandler` result path into `agent_command_bus_status_handler_test.exs`. Replace whole RateLimiter-table cleanup in the async remainder with exact keys derived from that test's unique agent/command IDs. Every registered control session uses a unique agent UID, partition, and gateway tuple. Its owning process unregisters before returning, or its test-owned child is stopped and bounded eventual disappearance is asserted; `on_exit` does not impersonate the owner.

- [ ] **Step 5: Normalize cache and telemetry identities**

For sync batch, discovery source, and hypervisor enrichment tests, derive IP/cache keys from `System.unique_integer/1` and call only `IdentityCache.delete/1` for the exact key. For merge-guard telemetry, pass the expected merge/device identifier into a matching receive helper and ignore foreign events. Remove redundant startup and promote the safe modules.

- [ ] **Step 6: Prove hard blockers remain serial**

Add exact required-serial assertions for:

```text
composite_checks/evaluation_test.exs
composite_checks/validation/orchestrator_test.exs
edge/agent_config_generator_test.exs
edge/agent_release_manager_test.exs
inventory/remediation/armis_unmerge_test.exs
inventory/sync_ingestor_active_ip_cross_handoff_test.exs
inventory/sync_ingestor_vendor_type_test.exs
network_discovery/mapper_graph_ingestion_test.exs
observability/plugin_result_ingestor_conflict_test.exs
observability/plugin_result_slot_allocator_test.exs
```

Each eventual TSV row names its actual reason (`oban_global`, `application_env`, `unboxed`, `ddl`, `global_process`, or `multi_connection`).

- [ ] **Step 7: Split the two heterogeneous source files**

Move `ServiceRadar.Scans.AdhocScanNatsFixtureConfigTest` into `adhoc_scan_nats_fixture_config_test.exs`. Move `ServiceRadar.Plugins.AnomalyAddonProfileSeederDbTest` into `anomaly_addon_profile_seeder_db_test.exs`, leaving the async schema-only module in the original source so it can be classified `load_only` for integration selection. Preserve every assertion and target inclusion. Add a contract rejecting any ordinary source that contains both selected async and selected serial ExUnit modules; source-level lane placement is invalid until every retained source has one selected execution mode.

- [ ] **Step 8: Create the exhaustive final disposition inventory**

Create a tab-separated file with exact header:

```text
source	module	case_kind	mode	reason	evidence
```

Allowed case kinds are `data_case`, `non_data_case`, and `not_selected`; allowed modes are `async`, `serial`, and `load_only`. Create one row per selected ExUnit module; create one `module=-`, `case_kind=not_selected`, `mode=load_only`, `reason=not_selected` sentinel only when a source has no selected module. Async DataCase rows use `transaction_owner`; async non-DataCase rows use `explicit_async`. Serial reasons are `application_env`, `ddl`, `fixed_external`, `global_cache`, `global_process`, `global_pubsub`, `global_registry`, `global_telemetry`, `materialized_view`, `multi_connection`, `oban_global`, `truncate`, `unboxed`, `unmanaged_child`, or `vm_global`. Every row requires positive evidence: async DataCase evidence names its Sandbox owner/child-routing boundary; async non-DataCase evidence proves no direct or indirect unowned Repo work and no VM/external blocker (or names an equivalent explicit owner); serial evidence names the exact operation, global process, resource, or call chain and required isolation scope; load-only evidence cites the empty selected-identity manifest. Evidence may not merely restate the reason token.

Extend the Python contract to compare distinct inventory sources with the complete `ALL_TEST_SRCS` glob (excluding the already source-separated gates), and classify direct DataCase, other ExUnit, and unselected files. Parse the inventory with `csv.DictReader(..., delimiter="\t")` and require exact source-set equality, unique `(source, module)` keys, allowed values, explicit matching selected-module declarations, no mixed selected-mode source, correct fixed-resource disposition, and a one-to-one audit entry with concrete evidence for every row. A load-only sentinel is legal only when the source-selection formatter reports zero selected identities for that file. Add reason-specific static checks where a construct is detectable; indirect call chains remain explicit human-reviewed audit evidence. No `pending`, `legacy`, `unknown`, blank, or reason-only evidence is permitted. Add the TSV and formatter to the scoped `integration_contract_test_inputs` filegroup, register that filegroup on the root contract target, and make the old async/required-serial constants exact subsets of the inventory.

Add a project-owned ExUnit formatter and register a Bazel equivalence target in `build/BUILD.bazel` that emits stable selected test identities and module names under the exact integration include/exclude configuration. Run it once with `ALL_TEST_SRCS` and once with the candidate selected-source union; require exact set equality. Change `INTEGRATION_SHARD_SRCS` to partition only the distinct sources with async/serial module rows while leaving `unit_tests` on `ALL_TEST_SRCS`. `_ASYNC_SAFE_SRCS` must equal sources whose selected module rows are all async; `_ORDINARY_INTEGRATION_SRCS` must equal all distinct async/serial sources; neither may contain `load_only`. Add an exact-checked source-to-module job map so multi-module async sources contribute multiple jobs to the scheduler.

The formatter writes one sorted `module|test_name` identity for every selected test, including a selected skipped test, and rejects duplicate identities. The Bazel-owned Python equivalence target receives two declared ExUnit runner tools (all-source and pruned-source), Rust provision/teardown tools, and fixture configuration as declared inputs. It inherits `requires_shared_fixture()`, the existing local/non-cached TestRunner execution requirements, scoped credential forwarding, one fresh run-id with two owned database suffixes, and a bounded enormous-test timeout. It provisions a different fresh database suffix per runner, executes both sequentially at cap one with identical include/exclude rules and retries disabled, requires both subruns and teardowns to succeed, compares the two identity sets byte-for-byte, and always tears both databases down in `finally`. It does not call Bazel recursively, expose secrets, or read generated Bazel output paths.

Re-audit every legacy `_FIXED_EXTERNAL_RESOURCE_SRCS` entry. `fixed_external` requires concrete evidence of a mutable shared namespace, cross-BEAM negative assertion, or collision; legacy membership alone is insufficient. In particular, the read-only Proxmox API smoke source must be classified from its actual Repo/VM/external behavior rather than automatically pinned with NATS mutators.

If semantic review finds no currently enumerated serial reason, extend the reviewed taxonomy or prove the module eligible; taxonomy exhaustion never implies safety. Promote only after positive owner/no-shared-state evidence, then run the module through the cap-two wave. Do not invent a quarantine reason merely to finish the table. This task ends only when every async row has positive safety evidence and every serial row names a blocker actually reached by that module.

- [ ] **Step 9: Run and commit the second cap-two wave**

Run formatting, all static contracts, focused changed targets, and one complete observer-covered cap-two ordinary wave. Reclassify any failing source before commit; do not accept retries or increase pool/timeout values.

```bash
git add BUILD.bazel ci_heavy_gate_contract_test.py \
  build/BUILD.bazel build/integration_selection_equivalence_test.py \
  build/integration_shards.bzl build/integration_shards_test.bzl \
  elixir/serviceradar_core/BUILD.bazel rust/integration-db/BUILD.bazel \
  elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md \
  elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv \
  elixir/serviceradar_core/test/support/integration_selection_formatter.ex \
  elixir/serviceradar_core/test/serviceradar/edge/agent_gateway_sync_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/agent_gateway_sync_release_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/remote_access_sessions_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/remote_access_sessions_serial_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/agent_command_bus_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/agent_command_bus_status_handler_test.exs \
  elixir/serviceradar_core/test/serviceradar/inventory/sync_batch_resolution_test.exs \
  elixir/serviceradar_core/test/serviceradar/inventory/sync_ingestor_discovery_sources_test.exs \
  elixir/serviceradar_core/test/serviceradar/inventory/hypervisor_enrichment_ingestor_db_test.exs \
  elixir/serviceradar_core/test/serviceradar/inventory/identity_reconciler_merge_guard_test.exs \
  elixir/serviceradar_core/test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs \
  elixir/serviceradar_core/test/serviceradar/scans/adhoc_scan_nats_fixture_config_test.exs \
  elixir/serviceradar_core/test/serviceradar/plugins/anomaly_addon_profile_seeder_test.exs \
  elixir/serviceradar_core/test/serviceradar/plugins/anomaly_addon_profile_seeder_db_test.exs
git commit -m "test(elixir): isolate global integration test state"
```

---

### Task 5: Freeze the async-plus-serial production lane map

**Files:**
- Modify: `build/integration_shards.bzl`
- Modify: `build/integration_shards_test.bzl`
- Modify: `elixir/serviceradar_core/config/test.exs`
- Modify: `elixir/serviceradar_core/test/test_helper.exs`
- Modify: `elixir/serviceradar_core/BUILD.bazel`
- Modify: `ci_heavy_gate_contract_test.py`

**Interfaces:**
- Consumes: exhaustive module dispositions and same-trace module weights.
- Produces: one async cap-eight lane, capacity-bounded cap-one serial lanes, explicit pool 12, and a frozen deterministic source map.

- [ ] **Step 1: Write topology/pool RED tests**

Change Starlark assertions to require one async lane at cap 8, one through seven serial lanes at cap 1, and every integration environment to contain pool size 12. The capacity preflight SHALL calculate:

```python
"SERVICERADAR_TEST_DATABASE_POOL_SIZE": "12",
"SERVICERADAR_TEST_LANE": "async|serial_N",
```

Require `safe_pool_budget = min(96, floor(0.90 * usable_client_slots))` and `serial_lanes = min(serial_source_count, max(1, floor(safe_pool_budget / 12) - 1))`; invalid capacity fails before provisioning. Require unit targets not to inherit integration variables. Run RED.

- [ ] **Step 2: Implement frozen lanes and runner markers**

Generate exactly one async target at cap 8 and the computed serial targets at cap 1. Pass pool size 12 and lane identity through every generated target, and emit exactly one marker per integration BEAM. Every lane gets a distinct guarded disposable clone on `srql-fixtures`; never demo or production. `serial_0` is preseeded with every `fixed_external` source and `load_only` appears nowhere.

```text
SERVICERADAR_INTEGRATION_RUNNER lane=async|serial_N max_cases=8|1 schedulers=N repo_pool=12 trace=false timeouts=enabled
```

Profiling markers retain cap one, trace true, and infinite timeouts.

- [ ] **Step 3: Write deterministic placement RED tests**

Add pure Starlark helpers with these interfaces:

```python
def serial_lane_count(serial_source_count, usable_client_slots):
def place_serial_sources(serial_sources, serial_lane_names, fixed_sources):
```

The async lane contains every async source exactly once. Preseed `serial_0`, then assign remaining serial sources by descending `1 + selected_serial_module_count`, breaking ties by source path and lane name. Require exact stability for reversed/shuffled input, no mixed selected-mode source, and no `load_only` source. Run RED.

- [ ] **Step 4: Implement and freeze placement**

Add the async and serial source sets plus their frozen mapping to `build/integration_shards.bzl`. Extend the Python contract to require exact equality with the final disposition inventory and module declarations. Hash/check in the mapping before CPU timing; later traces are evidence only and cannot alter it.

- [ ] **Step 5: Run the fixed-lane safety wave**

Run the one async lane and every serial lane in one Bazel invocation with pool 12, trace off, finite timeouts, retries one, the observer active, and fresh clones. Require:

- the async marker matches cap 8, every serial marker cap 1, and all pools are 12;
- zero failed or retry-hidden targets, ownership errors, deadlocks, queue drops, or leaked processes;
- at most eight test BEAMs / 96 configured pool slots and fixture-wide peak at most 90% of usable slots;
- two zero samples before successful teardown;
- slowest/fastest non-empty serial-lane ratio at most 1.5.

- [ ] **Step 6: Commit**

```bash
git add build/integration_shards.bzl build/integration_shards_test.bzl \
  elixir/serviceradar_core/config/test.exs \
  elixir/serviceradar_core/test/test_helper.exs \
  elixir/serviceradar_core/BUILD.bazel ci_heavy_gate_contract_test.py
git commit -m "test(ci): freeze async and serial integration lanes"
```

---

### Task 6: Publish diagnostic infrastructure and select CPU

**Files:**
- Modify: `BUILD.bazel`
- Modify: `buildbuddy.yaml`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `build/integration_shards.bzl` and `build/integration_shards_test.bzl`.
- Modify: `elixir/serviceradar_core/BUILD.bazel`
- Modify: `rust/integration-db/BUILD.bazel`
- Modify: `openspec/changes/parallelize-core-integration-tests/benchmark.md`

**Interfaces:**
- Consumes: the frozen async/serial source map, pool 12, and observer lifecycle.
- Produces: an explicit CPU winner for the single production topology.

- [ ] **Step 1: Add CPU action contract tests**

Add `IntegrationBenchmarkCPU2` and `IntegrationBenchmarkCPU12`; their normalized blocks differ only in `resource_requests.cpu`: `"2000m"` and `"12000m"`. Both pin pool 12, run the complete ordinary pull-request integration wildcard (the frozen async plus serial lanes and identical SRQL and other non-core integration targets), and require the exact expected SHA. Extend the harness contract to prove every other field and command block is byte-equivalent after replacing action name and CPU value. Run RED.

Add `//:integration_cpu_diagnostic_input_hash`, covering every ordinary test source, relevant BUILD/Starlark/config/helper input, observer/lifecycle implementation, runner image/pool, and normalized CPU2/CPU12 action blocks. It deliberately excludes the later production-winner CPU field while including everything that can change either diagnostic arm's work or runtime semantics.

- [ ] **Step 2: Enforce the single production topology**

Keep the authoritative `IntegrationBenchmark` as the pull-request wildcard with no topology selector. Its source map SHALL consist only of the one async cap-eight target and the computed cap-one serial targets. Contracts prove each ordinary source appears exactly once, `fixed_external` sources appear only in `serial_0`, `load_only` sources appear nowhere, every lane receives a guarded clone on `srql-fixtures`, and calculated capacity never exceeds eight BEAMs or 96 configured pool slots. No one/four/eight/hybrid manual challenger targets or runner-layout action are registered.

- [ ] **Step 3: Provision only frozen-lane databases**

Use the frozen `async` and `serial_N` suffixes. Every target declares the run-id file and core migrations. The topology contract proves provision/test suffix equality, `srql-fixtures` ownership, and teardown ownership; do not add a lifecycle shell wrapper.

- [ ] **Step 4: Commit diagnostic infrastructure**

Run every static action/topology/lifecycle contract, then commit the runnable actions before asking BuildBuddy to execute them:

```bash
git add BUILD.bazel buildbuddy.yaml ci_heavy_gate_contract_test.py \
  build/integration_shards.bzl build/integration_shards_test.bzl \
  elixir/serviceradar_core/BUILD.bazel rust/integration-db/BUILD.bazel
git commit -m "test(ci): enforce fixed integration lane topology"
```

- [ ] **Step 5: Obtain authorization and push the diagnostic commit**

BuildBuddy can only check out a published SHA. If the user has not authorized this external operation, stop and ask. Push only the explicit feature refspec:

```bash
git push github proposal/parallelize-integration-tests:refs/heads/proposal/parallelize-integration-tests
```

Verify output names the feature branch, never `staging`.

- [ ] **Step 6: Run the CPU diagnostic**

On that exact published diagnostic SHA, alternate five attempts per arm between 2-CPU and 12-CPU actions with fresh run IDs and no overlap. Record CPU request, `schedulers_online`, pool 12, wall, shard durations, connection peaks, safety results, and cleanup. Treat the pre-marker workflow scheduler count as unknown rather than inferring it from local runs. An arm is selectable only if all five attempts pass every safety/headroom gate. If neither is selectable, stop; if only one is selectable, use it. If both are selectable, select 12 CPUs only when its untrimmed median lifecycle is at least 10% lower than the 2-CPU median; otherwise select 2 CPUs.

- [ ] **Step 7: Apply and commit the CPU winner**

Set the selected explicit CPU request in production `BazelCI` and `IntegrationBenchmark`; retain the fixed CPU2/CPU12 diagnostic actions as evidence tools. Extend the contract to require the production and authoritative values to agree. Append the ten CPU rows and selection calculation to `benchmark.md`, run static contracts, and commit:

```bash
git add buildbuddy.yaml ci_heavy_gate_contract_test.py \
  openspec/changes/parallelize-core-integration-tests/benchmark.md
git commit -m "test(ci): pin integration workflow CPU"
```

Task 7 first verifies the candidate, repairs/freezes the corrected before/after lineage with this final CPU request, and publishes those immutable SHAs.

---

### Task 7: Prove the 50% result and finish repository verification

**Files:**
- Modify: `openspec/changes/parallelize-core-integration-tests/benchmark.md`
- Modify: `openspec/changes/parallelize-core-integration-tests/tasks.md`
- Modify only if evidence requires: dispositions, module flags/splits, cap, and placement weights.

**Interfaces:**
- Consumes: explicit CPU winner, frozen async-plus-serial candidate, identical benchmark harness, and exact-SHA observer evidence.
- Produces: one exact-SHA non-cohort smoke, accepted 20-row before/after cohorts, a hard BuildBuddy relative-p95 result of at least 50%, an after p95 of at most 90 seconds, a reported 60% stretch result, heavy-gate evidence, and truthful OpenSpec completion state.

- [ ] **Step 1: Run one exact-SHA BuildBuddy smoke**

If the current CPU-pinned fixed-lane candidate is not already published, obtain explicit authorization and run only `git push github proposal/parallelize-integration-tests:refs/heads/proposal/parallelize-integration-tests`; this provisional smoke publication may be superseded by the frozen history in Step 3. Record the resulting full SHA, verify that exact object exists on GitHub, and trigger exactly one synchronous, retry-disabled `IntegrationBenchmark` attempt using the request contract in `openspec/changes/parallelize-core-integration-tests/benchmark.md`: `SERVICERADAR_BENCHMARK_EXPECTED_SHA` equals that full SHA, `async` is `false`, and workflow retry is disabled. Do not pass a topology selector.

Treat this attempt as a non-cohort smoke, not latency evidence. Require the workflow's effective HEAD to equal the requested SHA, the async marker to report cap eight, every serial marker cap one, its actual scheduler count, trace disabled, finite timeouts, Repo pool 12, and at most eight test BEAMs / 96 configured pool slots. Require suite, observer, and teardown status to be zero with no ownership error, deadlock, queue/drop signal, leaked process, or disposable-database residue. A red or censored smoke returns to the owning implementation task, produces a new candidate SHA, and must be rerun before repository verification.

- [ ] **Step 2: Run heavy and repository verification**

Run the full three-test heavy lifecycle at least three times, then run fresh:

```bash
bazel test -c opt --config=remote \
  //:ci_heavy_gate_contract_test \
  //build:integration_shards_test \
  //build/ci:wait_for_large_ingestion_gate_test \
  //rust/integration-db:serviceradar_integration_db_test
make lint
make test
git diff --check
openspec validate parallelize-core-integration-tests --strict
```

Every command must exit zero. Fixing a failure returns to the relevant implementation task and requires publishing the corrected exact SHA, rerunning the Step 1 BuildBuddy smoke, and rerunning this complete step; do not freeze or spend cohort runs on an unverified candidate.

- [ ] **Step 3: Freeze comparable before and after SHAs**

Apply the final normalized benchmark action, observer sources/rule, explicit CPU request, pool 12, full pull-request wildcard target selection, and marker format identically to the corrected before revision and final after revision. The before workload remains cap one; the after workload uses the frozen async cap-eight and serial cap-one lanes. Verify the harness hash matches exactly and the instrumentation commit is the direct parent of the first behavior change. Record full SHAs and hash.

Complete any required history repair now, replaying implementation commits without changing their final tree. Re-run Step 2 against the repaired final tree and prove the tree hash matches the verified candidate before accepting the new SHAs. Record the current remote feature-branch OID before the rewrite so the next push can use an exact lease. CPU and cohort evidence never carries from a superseded SHA. CPU evidence may carry only when `integration_cpu_diagnostic_input_hash` is identical at the published diagnostic SHA and frozen after SHA; record both SHAs and hashes. A mismatch marks all ten CPU attempts for rerun immediately after Step 4 publishes the frozen SHA.

- [ ] **Step 4: Obtain push authorization and publish only the feature ref**

If the user has not explicitly authorized the external operation, stop and ask. For a fast-forward, execute only:

```bash
git push github proposal/parallelize-integration-tests:refs/heads/proposal/parallelize-integration-tests
```

Verify output names `proposal/parallelize-integration-tests`, never `staging`.

If Step 3 rewrote already-published feature history, copy the previously observed remote OID into the task-specific `EXPECTED_FEATURE_OID`, obtain explicit authorization for the lease-protected rewrite, and use only:

```bash
test -n "$EXPECTED_FEATURE_OID"
git push \
  --force-with-lease=refs/heads/proposal/parallelize-integration-tests:$EXPECTED_FEATURE_OID \
  github \
  proposal/parallelize-integration-tests:refs/heads/proposal/parallelize-integration-tests
```

Never use an unleased force push. Verify the published before/after SHAs and harness hash through GitHub before starting diagnostics. If the frozen after SHA differs from the provisional SHA exercised in Step 1, rerun the exact Step 1 smoke against the frozen after SHA now; provisional smoke evidence never carries across a changed SHA.

If Step 3 found a CPU diagnostic-input hash mismatch, rerun five CPU2 and five CPU12 attempts now on the published frozen after SHA before the authoritative cohorts. Reapply the pre-registered selection rule. If the winner changes, stop: update the production CPU request, rerun Steps 1--3, republish with a new exact lease, and repeat this confirmation. Do not carry a CPU decision across a changed diagnostic input.

- [ ] **Step 5: Run alternating exact-SHA cohorts for the hard performance gates**

Trigger `IntegrationBenchmark` sequentially, alternating before then after, with exact expected SHA, `async: false`, and retries disabled. Do not pass a topology selector to the authoritative action. Continue until each revision has 20 consecutive successful full lifecycles. These cohorts carry both hard performance gates: relative p95 improvement of at least 50% and after p95 of at most 90 seconds; 60% is the stretch result to report. Record every started failed or censored row; a behavior fix creates a new after SHA and restarts that sequence.

- [ ] **Step 6: Evaluate the gates**

Compute untrimmed median, nearest-rank p95 (row 19), and:

```text
relative improvement = (before_p95 - after_p95) / before_p95 * 100
```

Require relative BuildBuddy p95 improvement of at least 50%, after p95 at most 90.0 seconds, 20/20 retry-free stability in both cohorts, every after serial-lane skew at most 1.5, at most eight test BEAMs / 96 configured pool slots, fixture peak at most 90% usable slots, zero ownership/deadlock/leak/cleanup failures, explicit identical CPU, and Repo pool 12. Report the exact relative improvement and whether the 60% stretch was reached. The Step 1 smoke cannot substitute for either hard cohort gate.

- [ ] **Step 7: Update evidence and commit**

Mark only tasks backed by implementation and required evidence. Append CPU, fixed-lane, smoke, cohort, connection, and heavy-gate rows to `benchmark.md`; preserve failed and superseded rows.

```bash
git add openspec/changes/parallelize-core-integration-tests/benchmark.md \
  openspec/changes/parallelize-core-integration-tests/tasks.md \
  docs/superpowers/plans/2026-08-23-parallel-core-integration-tests-broad-async.md
git commit -m "docs(openspec): record broad integration concurrency"
```

Request spec-compliance and code-quality review before opening a PR.
