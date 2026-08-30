# Task 5 Report: Exact per-agent Run-now dispatch and independent status

Date: 2026-08-30

Branch: `codex/add-sweep-group-agent-selection`

Base: `f0967b76dc`

Commit subject: `feat(sweep): fan out run-now status`

## Outcome

Task 5 implements exact, best-effort Run-now fanout and independent per-command
status without changing the mapper status shape.

- A non-empty canonical `agent_ids` assignment dispatches only to those UIDs.
  Selection uses canonical four-tuple registry principals, resolves partition
  ambiguity before capability validation, then re-resolves exact live session
  evidence. It never falls back to the device partition or a legacy session.
- An empty assignment retains canonical partition-wide enumeration of all live,
  sweep-capable sessions.
- Dispatch returns successful `%{agent_id, command_id}` pairs and immediate
  `%{agent_id, reason}` failures. Zero success still returns an error, but its
  public `sweep_dispatch` envelope is broadcast first so the UI can render it.
- Persisted ACK/progress/result events are forwarded to the public
  `agent:commands` topic only after exact persistence. Raw ingress stays on
  `agent:commands:ingress`; rejected updates do not become public.
- NetworksLive keeps mapper status in its existing flat map. Sweep status is a
  separate reducer keyed by command ID, with immediate failures keyed by UID,
  monotonic member state, aggregate counts, and complete/partial/zero-success
  rendering. ACK/result events arriving before the dispatch envelope are merged
  only for authoritative command IDs. Duplicate seeds preserve progress and
  terminal state; new-run seeds replace prior members and failures; late unknown
  IDs are rejected after seeding.

## Files

Modified:

- `elixir/serviceradar_core/lib/serviceradar/agent_commands/pubsub.ex`
- `elixir/serviceradar_core/lib/serviceradar/agent_commands/status_handler.ex`
- `elixir/serviceradar_core/lib/serviceradar/edge/agent_command_bus.ex`
- `elixir/serviceradar_core/test/serviceradar/agent_commands/pubsub_result_gate_test.exs`
- `elixir/serviceradar_core/test/serviceradar/edge/agent_command_bus_registry_test.exs`
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/command_status.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/event_handlers/groups.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/infos.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/networks_live/index/view/sweep_groups.ex`
- `elixir/web-ng/test/phoenix/live/settings/networks_live_test.exs`

Created:

- `elixir/serviceradar_core/test/serviceradar/agent_commands/status_handler_public_forward_test.exs`
- `elixir/web-ng/test/serviceradar_web_ng_web/settings/networks_live_command_status_test.exs`
- `.superpowers/sdd/2026-08-30-sweep-group-agent-subsets/task-5-report.md`

`DispatchAgentCommand` was not changed: its existing success contract already
accepts `{:ok, term()}` while deliberately returning the original Ash record.

## TDD RED evidence

1. Exact dispatch RED:
   - Command: `bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_edge --test_output=errors`
   - Invocation: `1c64143f-1f60-4235-8458-ce687079c832`
   - Result: 160 tests, 6 failures. The old scalar/single-dispatch behavior did
     not satisfy selected fanout, structured partial failures, canonical
     ambiguity, or zero-success publication.
2. Public status gate RED:
   - Command: `bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_other --test_output=errors`
   - Invocation: `54dcbd2c-77a8-4dc7-8e4b-68aba634c97d`
   - Result: 792 tests, 3 failures. Persisted ACK/progress broadcasters and
     persistence-gated forwarding were missing.
3. Sweep reducer RED:
   - Command: `bazel test -c opt --config=remote //elixir/web-ng:unit_tests_serviceradar_web_ng_web --test_output=errors`
   - Invocation: `2224f6df-d439-46fb-a2b4-0135a2af9d93`
   - Result: 2 doctests and 158 tests, 4 failures. The sweep-specific begin,
     seed, reduce, and failure-format APIs were absent; the mapper-shape guard
     already passed.
4. Empty all-agent zero-success RED:
   - Same web shard.
   - Invocation: `5ea568ea-e04b-4702-9d9c-97f17889c63d`
   - Result: 2 doctests and 159 tests, 1 failure. A no-live-session envelope was
     incorrectly summarized as sent instead of an explicit dispatch error.
5. Duplicate-seed monotonicity RED:
   - Same web shard.
   - Invocation: `f568af44-a19f-4bec-aa53-61699093d80f`
   - Result: 2 doctests and 159 tests, 1 failure. Re-seeding matching command IDs
     downgraded a completed member to queued.

## GREEN evidence

1. Exact dispatch initial GREEN:
   - Core edge shard invocation: `e5973377-8bd8-4e06-932b-13ffe2c54728`
   - Result: 160 tests, 0 failures.
2. Public status gate GREEN:
   - Core other shard invocation: `fa658e2d-9e45-4124-90ee-17f6760ecd1e`
   - Result: 792 tests, 0 failures.
3. Reducer initial GREEN:
   - Web shard invocation: `94682d8d-63da-4747-a5a2-d41341c70be2`
   - Result: 2 doctests and 158 tests, 0 failures.
4. Zero-success GREEN:
   - Web shard invocation: `7188d690-a38b-4fdd-ad97-1fdf4cd54501`
   - Result: 2 doctests and 159 tests, 0 failures.
5. Combined final core/web verification before the duplicate-seed refinement:
   - Command: `bazel test -c opt --config=remote //elixir/serviceradar_core:unit_tests_serviceradar_edge //elixir/serviceradar_core:unit_tests_serviceradar_other //elixir/web-ng:unit_tests_serviceradar_web_ng_web --test_output=errors`
   - Invocation: `9acd8928-cf52-499a-89b7-2f8d79e87e41`
   - Result: all 3 targets passed; core other and web were cache hits, core edge
     executed and passed.
6. Final duplicate-seed GREEN after the only later production-code change:
   - Web shard invocation: `f2037e5a-8496-4456-971d-09ae6ac7a1bc`
   - Result: 2 doctests and 159 tests, 0 failures.

## Mutation evidence

Each mutation was made with `apply_patch`, verified remotely, and restored with
`apply_patch` before final verification.

1. Capability filtering moved before canonical partition ambiguity:
   - Edge shard invocation: `8eee33aa-8098-4cfd-92a2-d420f9ef3574`
   - Result: 160 tests, 2 targeted failures. The tests caught both the ambiguity
     bypass and capability-missing being misclassified as offline.
2. Persisted ACK deliberately published back to ingress:
   - Core other shard invocation: `e5aa2caa-0aba-40e4-8327-2da531f7682f`
   - Result: 792 tests, 3 targeted failures. The topic-isolation assertions
     failed and the test handler visibly replayed the ACK, proving the loop
     guard is meaningful.
3. Post-seed unknown command admission deliberately enabled:
   - Web shard invocation: `2751d8ec-7911-4054-8ba2-15ace2090178`
   - Result: 2 doctests and 159 tests, 1 targeted failure. A late prior-run
     command appeared in the new run and changed the aggregate.

## Formatting and static checks

- Core touched files:
  `mix format --check-formatted lib/serviceradar/agent_commands/pubsub.ex lib/serviceradar/agent_commands/status_handler.ex lib/serviceradar/edge/agent_command_bus.ex test/serviceradar/agent_commands/pubsub_result_gate_test.exs test/serviceradar/agent_commands/status_handler_public_forward_test.exs test/serviceradar/edge/agent_command_bus_registry_test.exs`
  - Result: exit 0.
- Web touched files:
  `mix format --check-formatted lib/serviceradar_web_ng_web/live/settings/networks_live/index/command_status.ex lib/serviceradar_web_ng_web/live/settings/networks_live/index/event_handlers/groups.ex lib/serviceradar_web_ng_web/live/settings/networks_live/index/infos.ex lib/serviceradar_web_ng_web/live/settings/networks_live/index/view/sweep_groups.ex test/serviceradar_web_ng_web/settings/networks_live_command_status_test.exs test/phoenix/live/settings/networks_live_test.exs`
  - Result: exit 0.
- `git diff --check`
  - Result: exit 0.

Direct focused `mix test` was not used as evidence because the sandbox denied
Mix's local TCP socket with `:eperm`. `unbuffer` is not installed. Remote Bazel
is the repository's authoritative DB-free harness and produced the evidence
above.

## Database safety and remaining verification

No database was created, migrated, dropped, reset, queried, or otherwise
mutated during Task 5. All executed tests were the existing DB-free remote Bazel
shards.

The DB-backed LiveView coverage in
`elixir/web-ng/test/phoenix/live/settings/networks_live_test.exs` was authored
but deliberately not executed in this task because the assignment prohibited
using a database without an explicitly approved scratch database. Its runtime
verification remains for the parent verifier against the prepared migrated
scratch database. The web application and HEEx compiled successfully in the
DB-free web shard.

## Concerns

- The DB-backed LiveView test still needs its approved scratch-DB execution.
- Full repository `make test` was outside this task's focused scope; the three
  directly relevant remote shards are green.
- Remote compilation printed pre-existing web-ng architecture warnings about
  forbidden Accounts/Auth references; none point to Task 5 files.

The conventional commit hash is assigned when this report and implementation
are committed together; at handoff it is the worktree's `HEAD`.
