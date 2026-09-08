# USP 3.3 Restart-Overlap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Satisfy task 3.3's restart-overlap implementation criterion by preserving one authoritative publisher credit ledger across a NATS transport-generation restart and by fencing every send-capable transport before an empty replacement ledger can open. This makes task 0.12 group E ready for its required composed observation; it does not close group E by itself.

**Architecture:** Keep `ServiceRadar.Edge.PublisherPool` as the per-lane accountant. Change the lane to an ordered `:rest_for_one` dependency: the pool starts first and the Gnat reconnect manager starts second. Each admitted attempt records the monitor reference for the exact Gnat connection PID that `JetStreamPublisher` will use. Connection death ends matching active attempts but retains their frame and byte reservations. If the accountant dies, `:rest_for_one` first terminates the reconnect manager; because Gnat's linked inner connection can outlive that manager briefly, the replacement pool starts closed whenever the old registered connection PID still exists and admits nothing until that exact PID is observed `DOWN`. That discovery is safe only under a separately pinned topology invariant: the actual Gnat process owns the lane's registered name continuously from `Gnat.start_link(..., name: lane_name)` until that exact PID terminates, and production code never unregisters or rebinds the name while it is live. A missing lookup is not treated as a fence for a previously captured PID. If that invariant cannot be established against the pinned Gnat implementation and the production child settings, stop and replace the lookup with an exact retained-PID or synchronous transport-teardown barrier; do not ship a fail-open approximation.

**Tech Stack:** Elixir 1.19, OTP 28 supervisors/monitors, Gnat, ExUnit, Bazel/RBE, OpenSpec.

**Spec:** `openspec/changes/unify-sweep-results-proto/specs/ingestion-routing/spec.md`, task 0.12 group E and task 3.3 in `openspec/changes/unify-sweep-results-proto/tasks.md`.

## Global Constraints

- This plan implements only task 3.3's prerequisite for task 0.12 group E, **RESTART OVERLAP**. PR #4258 closed task 3.3's prerequisite for group F, **POST-HANDOFF FENCING**.
- Task 1 is a separate docs-only scope amendment and must merge before the implementation branch begins. The active implementation PR may implement the approved boundary and reconcile evidence, but it may not redefine its own acceptance boundary.
- Do not add the Stream server, general asynchronous pipelining, `ResolvedPrefix` integration, out-of-order PubAck advancement, another producer, another traffic class, benchmarks, dashboards, or a broad mutation campaign.
- Do not change branch protection, review requirements, required checks, or other repository enforcement settings. They are unrelated to this implementation.
- After this plan lands, task 3.3 remains unchecked for asynchronous issuance and delivery of out-of-order completions into the task-3.5-owned validation/contiguous-prefix seam. Task 0.12 group E also remains open until its real-NATS composed observation runs. The next active-milestone work is the Stream/composed vertical slice, not that broader debt.
- `PublisherPool` remains the only owner of the lane's frame/byte ledger. A replacement transport consumes the same remaining grant; it never receives another window.
- A transport-generation death may end an active attempt, but it does not release its publication reservation. The same publication may retry against the retained charge. Generation/restart transitions never release credits. Preserve the existing narrow handoff authorities: a newly created provisional admission proven never delivered to its caller may be abandoned, while revoking a provisional retry returns it to idle without releasing its existing charge. Active settlement continues through the existing accounting API; PubAck validation/correlation remains open under task 3.5 and is not implemented or claimed here.
- Deadline expiry, a missing PubAck, and request-owner death never fence a send-capable transport and never release a reservation.
- If the accountant dies, the downstream reconnect manager is terminated before an empty accountant restarts. Manager death is not the transport fence: if the old registered inner Gnat connection PID still exists, the replacement accountant starts in `:restart_fenced` state and refuses every admission until that exact PID is observed `DOWN`.
- The accountant-loss path relies on explicit, executable topology invariants, not on name lookup as a general liveness oracle: the Gnat connection is registered under the lane name for its entire process lifetime; no production path unregisters or rebinds that name while the PID remains live; the pinned reconnect manager cannot successfully create G2 until G1 is dead and has released the one name; and every production request PID comes from that one registered lane name. Therefore production has at most one live send-capable Gnat PID per lane. A lookup miss can mean ready only under those bound facts. If implementation or dependency inspection cannot establish them, stop and use an exact retained-PID or synchronous teardown barrier.
- Do not add gateway-local durable state. A whole accounting-epoch loss is handled by fencing all old local send capability before a fresh volatile epoch starts; later agent replay and stable broker/database identity recover the unresolved record.
- All production sends continue to use the exact captured connection PID. Never re-resolve the registered connection name after admission. Production exports only `publish_record/1`; connection/pool injection is compiled only into the test build under a separately named test entry point, so an unregistered G2 cannot be introduced through a production call.
- Tests use mailbox barriers and process monitors. No fixed sleeps may establish ordering, and a final empty-window assertion is not restart-overlap evidence.
- The final task 0.12 group-E observation must run through `//integration_tests/edge_record:vertical_slice_test`; unit tests in this plan are necessary implementation evidence but do not close group E or task 0.12 by themselves.

## File Map

- Modify `openspec/changes/unify-sweep-results-proto/specs/ingestion-routing/spec.md`: distinguish transport-generation restart from accountant loss without adding a seventh acceptance group.
- Modify `openspec/changes/unify-sweep-results-proto/tasks.md`: tighten group E, correct the dead-owner wording, and leave task 3.3 unchecked for asynchronous issuance and delivery of out-of-order completions into task 3.5's validation/contiguous-prefix seam.
- Modify `elixir/serviceradar_core/lib/serviceradar/edge/publish_window.ex`: bind attempts to a transport generation, add the pure generation-termination transition, and expose a derived generation-reference predicate for bounded monitor cleanup.
- Modify `elixir/serviceradar_core/lib/serviceradar/edge/publisher_pool.ex`: derive/monitor generation references from exact connection PIDs, apply the transition on `:DOWN`, and start closed behind any pre-existing registered connection PID after accounting loss.
- Modify `elixir/serviceradar_core/lib/serviceradar/edge/lane_supervisor.ex`: use pool-first `:rest_for_one` ordering.
- Modify `elixir/serviceradar_core/lib/serviceradar/edge/publisher_supervisor.ex`: reconcile topology documentation only; its public API and one-lane-root-per-class composition remain unchanged.
- Modify `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/jet_stream_publisher.ex`: pass the exact captured connection PID into admission.
- Modify `elixir/serviceradar_agent_gateway/config/test.exs`: enable the dependency-injection entry point only in the test build; the production API has no per-call connection or pool override.
- Modify `elixir/serviceradar_agent_gateway/BUILD.bazel`: give the production-compiled gateway app its own API-surface test and keep that file out of the ordinary test-compiled shard.
- Add `elixir/serviceradar_agent_gateway/test/production/jet_stream_publisher_prod_surface_test.exs`: assert directly against the `MIX_ENV=prod` BEAM that no injection entry point is exported.
- Modify `elixir/serviceradar_core/test/serviceradar/edge/publish_window_test.exs`: pure generation-fence and retained-charge evidence.
- Modify `elixir/serviceradar_core/test/serviceradar/edge/publisher_pool_test.exs`: monitor ordering, stale-generation, and bounded bookkeeping evidence.
- Modify `elixir/serviceradar_core/test/serviceradar/edge/publisher_pool_handoff_test.exs`: pending-admission cleanup when a generation dies.
- Rewrite the affected assertions in `elixir/serviceradar_core/test/serviceradar/edge/lane_supervisor_test.exs`: replace the obsolete crash-together model with the ordered lifetime model.
- Add `elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/jet_stream_publisher_restart_test.exs`: deterministic public-publisher frame/byte restart traces.
- Modify `elixir/serviceradar_core/test/serviceradar/edge/publisher_supervisor_test.exs`: retain the exact one-lane-root-per-class inventory under the new directional lifetime.
- Modify `elixir/serviceradar_core/test/serviceradar/nats/publisher_connections_test.exs`: replace the obsolete "one restart unit" and inseparable-pair claims while retaining exact connection ownership and cardinality checks.

---

### Task 1: Freeze the precise restart semantics in a separate docs-only amendment

**Files:**
- Modify: `openspec/changes/unify-sweep-results-proto/specs/ingestion-routing/spec.md:373`
- Modify: `openspec/changes/unify-sweep-results-proto/tasks.md:95`
- Modify: `openspec/changes/unify-sweep-results-proto/tasks.md:850`

**Interfaces:**
- Consumes: task 0.12's fixed six-group scope and PR #4258's owner/start/termination model.
- Produces: the normative distinction the code and tests below implement.

- [ ] **Step 0: Create the isolated docs branch from the current integration head**

From the primary checkout, fetch GitHub and create a no-track worktree before editing:

```bash
git fetch origin usp-01-proposal
git worktree add --no-track -b usp-33-restart-overlap-spec \
  /private/tmp/serviceradar-usp33-restart-overlap-spec origin/usp-01-proposal
ln -sfn /Users/mfreeman/src/serviceradar/.bazelrc.remote \
  /private/tmp/serviceradar-usp33-restart-overlap-spec/.bazelrc.remote
test ! -e /Users/mfreeman/src/serviceradar/.bazelrc.local || \
  ln -sfn /Users/mfreeman/src/serviceradar/.bazelrc.local \
    /private/tmp/serviceradar-usp33-restart-overlap-spec/.bazelrc.local
```

Run Steps 1-4 in that worktree. Do not edit the plan branch or an older USP worktree and then copy the files.

- [ ] **Step 1: Replace the single restart scenario with two explicit cases**

Use this behavior, preserving the existing requirement heading:

```markdown
#### Scenario: A publisher transport generation restarts with requests in flight
- **GIVEN** publication A is charged in the lane's one authoritative frame/byte ledger and may still publish through transport generation G
- **WHEN** a replacement transport generation starts
- **THEN** the replacement SHALL use that same surviving ledger and only its unoccupied grant
- **AND** it SHALL receive neither an empty window nor a second grant
- **AND** a non-terminal request completion SHALL end A's attempt only when its owner reports through `attempt_failed` that the exact synchronous request returned
- **AND** a transport fence SHALL end A's attempt only when the exact captured connection PID is observed `DOWN`, making that request incapable of further transmission even if its owner is still unwinding
- **AND** A's reservation SHALL remain charged across that transition, so a different publication cannot consume it
- **AND** a resolving settlement SHALL instead end the attempt and release the reservation under its existing outcome policy
- **AND** deadline expiry, a missing PubAck, or owner death alone SHALL NOT terminate the attempt or release the reservation
- **AND** registration or name state SHALL NOT substitute for observing the exact captured PID `DOWN` while the surviving ledger still identifies that PID

#### Scenario: Publisher accounting is lost while an old transport may publish
- **GIVEN** the authoritative lane ledger is lost while an old send-capable generation may still publish
- **WHEN** supervision replaces the ledger
- **THEN** publication SHALL remain closed until it has established that no send capability from the lost accounting epoch remains
- **AND** eventual sibling restart SHALL NOT count as that fence
- **AND** when an exact old PID is discovered, only observing that PID `DOWN` SHALL establish its termination
- **AND** when the lost ledger no longer retains an exact PID and a registered name is used to discover a pre-existing transport, a lookup miss MAY open only if the implementation pins both continuous ownership of that name until PID termination and at most one live send-capable production generation per lane
- **AND** without those two invariants, a lookup miss SHALL NOT open the replacement ledger
- **AND** only after the fence MAY an empty volatile accounting epoch open within the same authoritative grant
- **AND** any publication whose settlement evidence was lost SHALL be replayed and SHALL NOT be reported durable from the lost evidence
```

- [ ] **Step 2: Tighten task 0.12 group E without adding an acceptance group**

Replace generic "the replacement SHALL admit work" with the two observable ledger cases:

```markdown
When the ledger survives an inner transport restart, after the exact old connection PID is observed terminated the same publication SHALL be retryable on its retained charge without consuming a second credit. Only after settlement releases that publication SHALL an unrelated publication consume the returned capacity. When the ledger itself is lost, the empty replacement ledger SHALL remain closed until it establishes that no send capability from the lost epoch remains: by exact-PID `DOWN` when a PID is discovered, or by a lookup miss only under the pinned continuous-name and single-live-production-generation invariants. Only then MAY the new epoch admit replay within the original grant.
```

- [ ] **Step 3: Correct task 3.3's closure text without declaring it closed**

State all four facts together:

```markdown
RESTART OVERLAP remains open until the implementation and evidence defined here land. POST-HANDOFF FENCING's local criterion was satisfied by PR #4258. Neither task-0.12 group is accepted until its required composed observation runs. Task 3.3 remains unchecked for production asynchronous issuance and delivery of out-of-order completions into the task-3.5-owned validation/contiguous-prefix seam; that broader debt is not a seventh task-0.12 acceptance group and does not precede the active vertical slice.
```

Replace “owner death leaves the reservation charged, which (i) is what will free” with:

```markdown
Owner death alone changes nothing. A non-terminal request completion reported by its owner through `attempt_failed` ends only the attempt and retains the reservation. Exact connection-PID death is the alternative transport fence and likewise retains the reservation. A resolving settlement ends the attempt and releases the reservation under its existing policy.
```

- [ ] **Step 4: Validate the proposal**

Run:

```bash
openspec validate unify-sweep-results-proto --strict
```

Expected: `unify-sweep-results-proto` is valid. Confirm the edit did not add a seventh task-0.12 group or check task 3.3.

- [ ] **Step 5: Commit and open the normative amendment by itself**

```bash
git add openspec/changes/unify-sweep-results-proto/specs/ingestion-routing/spec.md \
  openspec/changes/unify-sweep-results-proto/tasks.md
git commit -m "docs(edge): define publisher restart accounting lifetime"
git push origin HEAD:refs/heads/usp-33-restart-overlap-spec
gh pr create --base usp-01-proposal --head usp-33-restart-overlap-spec \
  --title "docs(edge): define publisher restart accounting lifetime"
```

The PR contains only the two OpenSpec files. Wait for explicit maintainer approval and merge. Then create the implementation branch from the updated `usp-01-proposal`; do not stack implementation into the docs-only PR.

### Task 2: Bind pure window attempts to transport generations

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/publish_window.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/publish_window_test.exs`

**Interfaces:**
- Consumes: existing publication keys, VM-unique attempt tokens, owner fencing, and `nil` as an idle-but-charged reservation.
- Produces:
  - `PublishWindow.admit/6`: `(window, key, bytes, deadline_at, owner_pid, generation_ref)`.
  - `PublishWindow.generation_terminated/2`: changes every matching active attempt to idle while retaining exact reservations and byte totals; provisional handoffs retain their existing cancellation/confirmation authority in the pool.
  - `PublishWindow.generation_referenced?/2`: derives whether any pending/active attempt still uses a monitor reference, so the pool can prune monitor state without maintaining a second fallible count.

- [ ] **Step 1: Write the retained-charge failing test**

Add a test whose essential assertions are:

```elixir
{:ok, w0} = PublishWindow.new(1, 100)
g1 = make_ref()
g2 = make_ref()

{:ok, w1, old_attempt} = PublishWindow.admit(w0, key(1), 100, 10_000, self(), g1)
{:ok, w2} = PublishWindow.activate(w1, old_attempt)
{:ok, w3} = PublishWindow.generation_terminated(w2, g1)

assert PublishWindow.outstanding_frames(w3) === 1
assert PublishWindow.outstanding_bytes(w3) === 100
assert {:error, :frame_credits_exhausted} =
         PublishWindow.admit(w3, key(2), 1, 20_000, self(), g2)

assert {:ok, w4, retry} = PublishWindow.admit(w3, key(1), 100, 20_000, self(), g2)
refute retry === old_attempt
```

Run the single test and confirm it fails because `admit/6` and `generation_terminated/2` do not exist.

- [ ] **Step 2: Write the stale-attempt failing test**

After retry activation, call `settle/4`, `attempt_failed/3`, and `rearm/4` with `old_attempt`. Assert each returns `{:error, :not_outstanding}`; do not compare an unchanged caller binding and call that state evidence, because the pure functions return no replacement state on error. Then settle `retry` and prove `key(2)` can be admitted. The process-level whole-state comparison belongs in Task 3, where a rejected call could actually mutate retained state.

- [ ] **Step 3: Extend the attempt representation and typespec**

Use one explicit shape everywhere:

```elixir
@type generation_ref :: reference()
@type attempt ::
        nil
        | {:pending, pos_integer(), pid(), generation_ref()}
        | {:active, pos_integer(), pid(), generation_ref()}
```

Update the currently stale opaque `outstanding` typespec, every pattern match, every constructor, and every existing test fixture/helper. `admit/6` must return `{:error, :generation}` unless the sixth argument is a reference. Update `PublishWindowTest`'s exact public inventory from `{:admit, 5}` to `{:admit, 6}` and add `{:generation_terminated, 2}` plus `{:generation_referenced?, 2}`. Do not keep a compatibility arity that creates an attempt without a generation.

- [ ] **Step 4: Implement the pure transition**

Implement `generation_terminated/2` as a single traversal of the bounded outstanding map:

```elixir
@spec generation_terminated(t(), generation_ref()) :: {:ok, t()}
def generation_terminated(%__MODULE__{} = w, generation_ref) when is_reference(generation_ref) do
  outstanding =
    Map.new(w.outstanding, fn
      {key, {bytes, deadline, {:active, _token, _owner, ^generation_ref}}} ->
        {key, {bytes, deadline, nil}}

      entry ->
        entry
    end)

  {:ok, %{w | outstanding: outstanding}}
end
```

Do not delete keys or decrement `bytes_outstanding` here.

Add the derived query used for cleanup:

```elixir
@spec generation_referenced?(t(), generation_ref()) :: boolean()
def generation_referenced?(%__MODULE__{} = w, generation_ref)
    when is_reference(generation_ref) do
  Enum.any?(w.outstanding, fn
    {_key, {_bytes, _deadline, {phase, _token, _owner, ^generation_ref}}}
    when phase in [:pending, :active] -> true

    _entry -> false
  end)
end
```

This predicate is derived from the bounded window. Do not add a parallel generation-use counter that can drift from the attempt tuples.

- [ ] **Step 5: Update the focused pure tests, but do not checkpoint the broken fan-out**

Run:

```bash
cd elixir/serviceradar_core
mix test --no-start test/serviceradar/edge/publish_window_test.exs
```

Expected: the pure window assertions pass, including owner fencing, expiry-reports-only, and the new generation cases. The application may still report the one known downstream arity mismatch because `PublisherPool` is migrated immediately in Task 3.

Do **not** commit here. Removing `PublishWindow.admit/5` while `PublisherPool` still calls it creates a non-buildable checkpoint. Do not add a temporary generation-less compatibility arity to make that checkpoint look green. Continue directly through Tasks 3 and 4; Task 4's final step migrates the complete call chain and changes the supervisor ordering atomically with startup-fence activation.

### Task 3: Make PublisherPool monitor exact connection generations

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/publisher_pool.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/publisher_pool_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/publisher_pool_handoff_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/publisher_supervisor_test.exs` (admission call-site migration only; topology assertions remain Task 4)
- Modify: `elixir/serviceradar_core/test/serviceradar/nats/publisher_connections_test.exs` (Bazel-safe Gnat BEAM/version and first-party ownership pin; topology prose remains Task 4)
- Modify: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/jet_stream_publisher.ex` (exact-PID admission and `:restart_fenced` classification)
- Modify: `elixir/serviceradar_agent_gateway/config/test.exs` (compile the injection seam only in tests)
- Modify: `elixir/serviceradar_agent_gateway/BUILD.bazel` (separate test- and production-compiled API-surface targets)
- Modify: `elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/jet_stream_publisher_test.exs` (existing-path API migration)
- Create: `elixir/serviceradar_agent_gateway/test/production/jet_stream_publisher_prod_surface_test.exs` (direct production-BEAM export check)

**Interfaces:**
- Consumes: `PublishWindow.generation_terminated/2` and an exact connection PID captured before admission.
- Produces:
  - `PublisherPool.admit/5`: `(pool, connection_pid, key, bytes, ack_timeout_ms)`.
  - Per-connection opaque generation references owned by the pool; callers never choose a reference. Use the monitor reference returned by `Process.monitor(connection_pid)` as the generation reference rather than minting a second unrelated token.
  - `:restart_fenced` admission refusal while a replacement pool is waiting for the exact pre-existing registered lane connection to die.

- [ ] **Step 1: Write a failing live-pool generation test**

Start a pool with one frame/100 bytes and a real controlled connection process. Admit publication A against its PID and synchronously wait until the pool records its attempt active, then terminate that PID and wait for its monitor `:DOWN` to be processed. Assert:

```elixir
assert %{outstanding_frames: 1, outstanding_bytes: 100} = PublisherPool.capacity(pool)
assert {:error, :frame_credits_exhausted} =
         PublisherPool.admit(pool, generation2, key(2), 1, 60_000)
assert {:ok, retry} = PublisherPool.admit(pool, generation2, key(1), 100, 60_000)
```

Use an explicit mailbox signal from the controlled connection and `Process.monitor/1`; do not wait with a sleep. Here `generation2` is an exact live connection PID, not a caller-supplied generation reference. After the test receives its own monitor `:DOWN`, synchronously wait until the pool's state shows A idle before asserting B's capacity error; monitor delivery to the test does not prove the pool has processed its independent `:DOWN`.

- [ ] **Step 2: Add failing pending-handoff coverage**

Exercise generation death while an admission is still in `state.pending` through the existing raw-`GenServer.call` test seam; the public wrapper casts confirmation immediately and cannot deterministically expose this state. Retain the `attempt_ref`, send `{:admit, connection_pid, key, bytes, ack_timeout_ms, attempt_ref}`, kill the generation, wait until the pool processes `:DOWN`, then manually cast confirmation or cancellation.

Preserve the existing handoff decision rather than erasing it on `:DOWN`: if cancellation or caller death proves a newly created admission was never delivered, `abandon/2` may still release it; a cancelled retry returns to idle without release; if confirmation wins, activate and immediately generation-fence it to idle because its connection is already dead. Assert a late confirmation cannot leave the dead generation active and the same publication can retry on a replacement connection.

Store the generation on each pending entry:

```elixir
pending[attempt_ref] = %{
  key: key,
  token: token,
  kind: kind,
  caller_pid: caller_pid,
  caller_monitor: caller_monitor,
  generation_ref: generation_ref,
  generation_status: :live | :terminated
}
```

On connection `:DOWN`, mark every matching pending handoff `generation_status: :terminated` before removing the live PID/ref lookup. Otherwise a later confirmation has no way to distinguish a dead generation after its reverse-map entry has been pruned. Do not retain a separate unbounded `dead_generations` set; the status lives only on already-bounded pending handoffs and disappears with them.

Assert `pending`, the two generation lookup maps, and the process monitor set remain bounded after repeated rotations. `Process.info(pool, :monitors)` exposes monitored PIDs, not monitor references: compare its PID multiset/count separately, and inspect the exact PID-to-ref/ref-to-PID bijection via `:sys.get_state(pool)`. The exact derived invariants are:

```elixir
map_size(pending) <= frame_credits
map_size(connections_by_pid) <= outstanding_frames
map_size(connections_by_pid) === map_size(connection_pids_by_ref)
connection_pids_by_ref ===
  Map.new(connections_by_pid, fn {pid, ref} -> {ref, pid} end)

expected_monitored_pids =
  Enum.map(Map.values(pending), & &1.caller_pid) ++
    Map.keys(connections_by_pid) ++
    startup_fence_pid_if_present

Enum.frequencies(actual_monitored_pids) ===
  Enum.frequencies(expected_monitored_pids)
```

Update the existing retry bookkeeping test: it can no longer require an empty monitor list while an attempt is active, but no monitor may survive after its generation is no longer referenced.

- [ ] **Step 3: Change the pool admission boundary**

Change the API to:

```elixir
@spec admit(GenServer.server(), pid(), PublishWindow.key(), non_neg_integer(), non_neg_integer()) ::
        {:ok, PublishWindow.reservation()} | {:error, atom()}
def admit(pool, connection_pid, key, bytes, ack_timeout_ms) when is_pid(connection_pid) do
  # existing handoff reference and timeout/revocation protocol
end
```

Inside the GenServer, map each observed connection PID to the reference returned by exactly one `Process.monitor/1` call, and index the reverse direction by that reference for `:DOWN`. Pass only the monitor reference to `PublishWindow.admit/6`. Reuse it for concurrent attempts on the same connection PID.

Extend state with explicitly separate namespaces:

```elixir
%{
  pending: %{optional(reference()) => pending_handoff()},
  connections_by_pid: %{optional(pid()) => reference()},
  connection_pids_by_ref: %{optional(reference()) => pid()},
  startup_fence: nil | %{pid: pid(), monitor: reference()}
}
```

Do not put caller-monitor refs, active-generation refs, and the startup-fence ref into one map and infer their kind from a PID or tuple shape.

The monitor reference must exist before `PublishWindow.admit/6` can consume it. For a previously unseen PID, create the monitor tentatively; if admission fails, immediately `Process.demonitor(ref, [:flush])` and do not add either lookup entry. Retain it only after successful admission, and prune it as soon as `PublishWindow.generation_referenced?/2` is false and no pending handoff names it. Otherwise repeated rejected admissions or failed retries against distinct live PIDs create unbounded monitor state outside the frame grant.

Change every production and test call site from `PublisherPool.admit/4` to `/5`, including the raw `{:admit, ...}` messages, `publisher_supervisor_test.exs`, and `JetStreamPublisher`. At the gateway boundary, pass the exact `conn_pid` already returned by `connection_for/2`, then keep the subsequent request on that same PID. Classify `:restart_fenced` as retryable `:systemic` and perform no I/O. Update `PublisherPoolTest`'s exact arity assertion from 4 to 5. Do not rely on focused compiler failures to discover this API fan-out piecemeal.

At the same time, remove per-call dependency injection from the production API. The current `publish_record(publication, opts \\ [])` makes the connection/pool singleton premise false: any caller can select an unregistered PID and alternate accountant while named G1 is live. Replace it with this shape:

```elixir
@spec publish_record(map()) ::
        {:ok, pub_ack()} | {:error, error_class()} | {:error, {:derivation, term()}}
def publish_record(publication), do: do_publish_record(publication, [])

if Application.compile_env(
     :serviceradar_agent_gateway,
     :compile_jet_stream_publisher_test_api,
     false
   ) do
  @doc false
  def publish_record_for_test(publication, opts), do: do_publish_record(publication, opts)
end

defp do_publish_record(publication, opts) do
  # existing implementation
end
```

Set `:compile_jet_stream_publisher_test_api` only in `config/test.exs`, and migrate tests to `publish_record_for_test/2`. Do not leave `publish_record/2`, `connection:` or `pools:` options reachable from the production export. Add an exact test-build function inventory asserting `publish_record/1` and `publish_record_for_test/2` are present while `publish_record/2` is absent, plus a narrow source/config assertion that the compile flag is enabled only by `config/test.exs`.

The production surface needs independent executable evidence; a successful `:erlang_app_prod` build proves only that the false branch compiles. Load `ex_unit_test` directly from `@rules_elixir//:ex_unit_test.bzl`. Add `test/production/jet_stream_publisher_prod_surface_test.exs`, exclude `test/production/**/*_test.exs` from the ordinary `unit_tests` glob, and give it a direct `ex_unit_test(name = "production_api_surface_test", ...)` target whose `srcs` contains only that file and whose only gateway application dependency is `:erlang_app_prod`, never `:erlang_app`. Do not use `ex_unit_tests` here: that macro derives suffixed shard names from the directory and would not create the exact Task-6 target. Have the standalone file call `ExUnit.start()` itself rather than loading the ordinary test helper. Against that loaded production BEAM, assert exactly:

```starlark
ex_unit_test(
    name = "production_api_surface_test",
    size = "small",
    srcs = ["test/production/jet_stream_publisher_prod_surface_test.exs"],
    deps = [":erlang_app_prod"],
)
```

```elixir
ExUnit.start()

defmodule ServiceRadarAgentGateway.JetStreamPublisherProdSurfaceTest do
  use ExUnit.Case, async: true

  alias ServiceRadarAgentGateway.JetStreamPublisher

  test "the production BEAM exports no dependency-injection entry point" do
    {:module, _} = Code.ensure_loaded(JetStreamPublisher)
    assert function_exported?(JetStreamPublisher, :publish_record, 1)
    refute function_exported?(JetStreamPublisher, :publish_record, 2)
    refute function_exported?(JetStreamPublisher, :publish_record_for_test, 2)
  end
end
```

Run this dedicated target in Task 6 as well as building `:erlang_app_prod`. Moving `publish_record_for_test/2` outside its compile-time conditional must now fail behaviorally on the production artifact. Together with the test-build inventory, this proves the controlled G1/G2 resolver in Task 5 is genuinely test-only rather than relying on an unbacked comment.

Run `rg` for both old call shapes and classify every hit before continuing:

```bash
rg -n "PublisherPool\.admit\(|\{:admit,|PublishWindow\.admit\(" \
  elixir/serviceradar_core elixir/serviceradar_agent_gateway \
  -g '*.ex' -g '*.exs'
rg -n "publish_record\([^)]*,|connection:|pools:" \
  elixir/serviceradar_agent_gateway/lib -g '*.ex'
```

Every executable `PublishWindow.admit` call must now supply a generation reference, and every executable `PublisherPool.admit` call must now supply the exact connection PID. Do not leave an old compatibility arity exported.

- [ ] **Step 4: Handle the exact connection `:DOWN`**

Maintain separate lookup maps for pending-caller monitors and connection monitors so a `:DOWN` cannot be misclassified. On exact connection death:

1. Remove the PID/reference/monitor entry.
2. Call `PublishWindow.generation_terminated/2`.
3. Mark matching provisional handoffs `generation_status: :terminated` and leave them in `state.pending` until their already-defined confirmation/cancellation/caller-death authority resolves them. A confirmation for a dead generation activates and immediately fences the attempt in the same GenServer turn; it never remains active after that turn.
4. Keep every handed-off or retried reservation and exact byte count charged. Preserve `abandon/2` only when the existing handoff protocol proves a newly created reservation was never delivered.

If an admission names a PID already dead, either refuse before admission or admit provisionally and process its already-queued `:DOWN`; in both cases no public path may perform I/O without a charged reservation. After settlement, attempt failure, cancellation, confirmation of a dead generation, or generation death, prune any generation monitor no longer referenced by a pending/active attempt.

- [ ] **Step 5: Bind the Gnat registration-lifetime invariant, then start a replacement accountant closed**

In `init/1`, resolve `PublisherLane.connection_name(class)` exactly once. If no PID is registered, start ready. If a PID is registered, monitor that exact PID and store it separately as `startup_fence: %{pid: pid, monitor: ref}`. While that field is present, every admission returns `{:error, :restart_fenced}` without creating a reservation, changing byte/frame counts, or creating another monitor. Clear it only on the matching `:DOWN`; reconnect-manager death, a name lookup failure after startup, elapsed time, and a PubAck absence are not fences.

This check is intentionally conservative for a standalone pool restart: any connection that predates its empty ledger belongs to an accounting epoch the pool cannot reconstruct. `JetStreamPublisher` must classify `:restart_fenced` as retryable `:systemic` and perform no I/O.

Do not make a one-shot `nil` lookup into an unproved fence. Before accepting this implementation, bind all parts of the topology invariant on which the ready case depends:

1. `NATSSupervisor.child_specs/3` passes `PublisherLane.connection_name(class)` as the actual Gnat process's `:name`, and the production lane owns exactly that child spec.
2. Add a Bazel-safe BEAM-structure test in `publisher_connections_test.exs`, not a `deps/gnat/...` source-file read that disappears from runfiles. It must pin the audited Gnat application version (`1.15.2` at plan-writing time), obtain both `Gnat` and `Gnat.ConnectionSupervisor` through `:code.which/1`, and require `:beam_lib.chunks(..., [:abstract_code])` to return raw abstract forms for both. Assert the facts the pinned code actually has: `Gnat.start_link/2` delegates its `opts` (and therefore `name:`) to `GenServer.start_link`; the manager's connection-attempt handler calls `Gnat.start_link/2` with `name: state.name`; its generic `{:EXIT, _pid, _reason}` handler schedules another attempt; and neither module calls `Process.unregister/1` nor `:erlang.unregister/1`. Do **not** claim that the generic handler correlates `_pid` with `state.gnat`—Gnat 1.15.2 does not. Singleton safety instead comes from the local-name collision: an extra attempt cannot successfully start/register G2 while live G1 still owns that name. A Gnat version change, stripped abstract code, or changed call graph must fail the Bazel test and force this source assumption to be re-audited, not silently inherit the old conclusion. If the compiled dependency does not expose enough abstract code under Bazel, invoke the stop rule and use the retained-PID/teardown design.
3. Every production request PID is returned by `ServiceRadar.NATS.Connection.get(PublisherLane.connection_name(class))`; the exact production child inventory contains one manager/name for the lane and no second request path with an unregistered connection.
4. A controlled process registered under the lane name remains returned by `Process.whereis/1` throughout manager teardown and until that exact process terminates; trying to register G2 under the same name while G1 is live fails, and only after G1's exact `:DOWN` may G2 acquire it.
5. No ServiceRadar production path calls `Process.unregister/1` for a `PublisherLane.connection_name/1` or otherwise rebinds that name while the PID is live. Add a narrow source/inventory assertion over the lane-connection ownership modules, not a repository-wide spelling claim.

The implementation may start ready on `nil` only under those pinned facts: if a prior production Gnat send capability were still alive, it would be the singleton generation and would still own the name. A gap after the old PID has terminated and before the new manager registers G2 is safe because the old send capability is already gone; it is not being used as evidence that an observed PID died. The simultaneous G1/G2 processes in Task 5 are a deliberately stronger controlled model for the surviving-ledger aggregate bound, not a claim that pinned Gnat creates two named connections. If any of these facts cannot be bound, stop this implementation and replace it with an exact retained-PID registry or a synchronous actual-transport teardown barrier.

Add this case to the already-`async: false` `publisher_pool_handoff_test.exs`: register a controlled old connection process under `PublisherLane.connection_name(:bulk)` before starting an unregistered replacement pool. Assert the pool records that exact PID/ref and repeated admission returns `:restart_fenced` with zero charged state. Send the pool an explicitly forged unmatched `{:DOWN, other_ref, :process, manager_pid, reason}` and compare the complete retained process state with `===` before/after; merely killing a process the pool never monitored would be vacuous. Terminate the registered connection, wait until the pool synchronously reports the fence cleared, admit against a different live PID, and prove normal capacity is restored. Clean up the registered name/process in `on_exit`; do not put this global-registration case in the async pool test module.

- [ ] **Step 6: Prove stale completions do not change state**

Use one long-lived owner worker for both the original G1 admission and the G2 retry. After the retry, assert the current attempt owner is still that exact worker PID. Through that same worker, invoke the pool's public settle/fail/rearm operations with G1's old reservation. Assert the documented stale-token error and compare `:sys.get_state(pool)` with `===` before/after. Then settle G2 normally. If different processes own G1 and G2, the test can pass only because of an owner mismatch and never exercise stale attempt/generation fencing.

- [ ] **Step 7: Run the focused pool tests**

Run:

```bash
cd elixir/serviceradar_core
mix test --no-start \
  test/serviceradar/edge/publish_window_test.exs \
  test/serviceradar/edge/publisher_pool_test.exs \
  test/serviceradar/edge/publisher_pool_handoff_test.exs \
  test/serviceradar/edge/publisher_supervisor_test.exs \
  test/serviceradar/nats/publisher_connections_test.exs
```

Expected: all pool and handoff tests pass without leaked monitors or pending entries.

Then run the existing gateway publisher test because this is the first point at which its admission call has migrated:

```bash
(cd elixir/serviceradar_agent_gateway && \
  mix test --no-start test/serviceradar_agent_gateway/jet_stream_publisher_test.exs)
```

Expected: the existing production publisher path compiles and passes with the exact-PID admission boundary.

- [ ] **Step 8: Hold the green API migration for the atomic topology commit**

Do not commit yet. Under the old manager-first `:one_for_all` topology, the healthy initial Gnat connection can register before the pool starts; enabling `init/1`'s startup lookup in a separate commit would then misclassify the current connection as a lost-ledger generation and fence a healthy lane until it reconnects. This race is scheduler-dependent and must never exist at a reviewable commit.

Proceed directly to Task 4. The first implementation checkpoint is Task 4 Step 5, after pool-first `:rest_for_one` and startup-fence activation are present together. Do not push the intermediate tree and do not run mutation controls against it.

### Task 4: Give accounting and transport ordered failure lifetimes

**Files:**
- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/lane_supervisor.ex`
- Modify: `elixir/serviceradar_core/lib/serviceradar/edge/publisher_supervisor.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/lane_supervisor_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/edge/publisher_supervisor_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/nats/publisher_connections_test.exs`

**Interfaces:**
- Consumes: the stable registered `PublisherPool` and the existing Gnat connection-manager child spec.
- Produces: an ordered per-lane restart dependency that preserves a live ledger on ordinary transport-manager failure and lets a replacement ledger identify a pre-existing inner connection as old; no new externally selectable lane or connection name.

- [ ] **Step 1: Replace the obsolete strategy assertions with failing lifetime assertions**

The tests must establish all of the following:

```elixir
assert flags.strategy === :rest_for_one
assert Enum.map(specs, & &1.id) === [
         PublisherPool.via(:bulk),
         PublisherLane.connection_name(:bulk)
       ]
```

Then start the lane and prove:

- killing the reconnect manager replaces it while preserving the pool PID and its charged capacity;
- killing the pool terminates the old reconnect manager before the replacement pool is started;
- with the no-listener Gnat fixture, the replacement pool has the original configured grant. Do not call the reconnect-manager PID a connection PID or claim production liveness from a fixture that never registers an inner Gnat connection; Task 5 supplies the independently controlled manager/connection liveness trace.

Use monitors and child-start signals. Delete the old assertions that a reconnect-manager failure must replace the pool. Do not infer ordering from the arrival order of monitor messages emitted by different PIDs.

- [ ] **Step 2: Implement pool-first `:rest_for_one`**

Build the child list in this exact dependency order:

```elixir
children = [
  Supervisor.child_spec(
    {PublisherPool, [class: lane, name: PublisherPool.via(lane)] ++ credits},
    id: PublisherPool.via(lane)
  )
] ++ NATSSupervisor.child_specs([PublisherLane.connection_name(lane)], settings, backoff)

Supervisor.init(children, strategy: :rest_for_one)
```

The pool starts before the manager deliberately. This does not authorize premature admission: `JetStreamPublisher` resolves the exact connection PID before calling `PublisherPool.admit/5`, so absence of a connection fails before a credit is taken. More importantly, if the prior inner Gnat PID is still registered after its manager is down, Task 3's startup fence keeps the replacement pool closed until that exact PID is `DOWN`. `:rest_for_one` alone is not the fence, and a name lookup is not a general substitute for one; the ready-on-`nil` case is permitted only by Task 3's pinned continuous-registration invariant.

This distinction comes from the pinned Gnat implementation, not a hypothetical: `Gnat.ConnectionSupervisor` is a trapping GenServer that calls `Gnat.start_link/2` for a linked inner process and has no `terminate/2` barrier awaiting that inner PID. The lane supervisor can therefore observe the manager down before the actual registered connection has processed its exit signal. Keep this fact in the topology documentation so a future cleanup does not delete the startup fence as redundant.

- [ ] **Step 3: Reconcile topology documentation and static tests**

Remove every statement that the pool and reconnect manager are one `:one_for_all` restart unit. State the directional dependency:

- transport failure preserves accounting;
- accounting failure orders downstream reconnect-manager termination before replacement accounting, while the replacement pool's exact-PID startup fence covers any linked inner Gnat process that outlives its manager;
- the accountant-loss ready case depends on the pinned fact that a live actual Gnat process keeps owning the lane name until that exact PID terminates; if that dependency changes, the topology must fail closed rather than treating lookup absence as proof;
- an ordinary inner Gnat reconnect replaces the actual connection PID, which the pool observes only when a pending/active attempt is bound to that PID; it retains no idle per-connection history;
- the supervisor strategy is not itself the proof—the production frame/byte traces in Task 5 are.

Do not rename `PublisherPool` to `LaneAccountant` in this milestone.

- [ ] **Step 4: Run the focused supervision tests**

Run:

```bash
cd elixir/serviceradar_core
mix test --no-start \
  test/serviceradar/edge/lane_supervisor_test.exs \
  test/serviceradar/edge/publisher_supervisor_test.exs \
  test/serviceradar/nats/publisher_connections_test.exs
```

Expected: the ordered lifetime and static topology tests pass. In `publisher_connections_test.exs`, replace claims that connection and window are inseparable or share one restart unit; retain the exact facts that each lane root owns one of each and no shared/plain NATS supervisor starts lane connections.

- [ ] **Step 5: Commit Tasks 2-4 as one green topology/API change**

```bash
git add elixir/serviceradar_core/lib/serviceradar/edge/publish_window.ex \
  elixir/serviceradar_core/lib/serviceradar/edge/publisher_pool.ex \
  elixir/serviceradar_core/lib/serviceradar/edge/lane_supervisor.ex \
  elixir/serviceradar_core/lib/serviceradar/edge/publisher_supervisor.ex \
  elixir/serviceradar_core/test/serviceradar/edge/publish_window_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/publisher_pool_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/publisher_pool_handoff_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/lane_supervisor_test.exs \
  elixir/serviceradar_core/test/serviceradar/edge/publisher_supervisor_test.exs \
  elixir/serviceradar_core/test/serviceradar/nats/publisher_connections_test.exs \
  elixir/serviceradar_agent_gateway/config/test.exs \
  elixir/serviceradar_agent_gateway/BUILD.bazel \
  elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/jet_stream_publisher.ex \
  elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/jet_stream_publisher_test.exs \
  elixir/serviceradar_agent_gateway/test/production/jet_stream_publisher_prod_surface_test.exs
git commit -m "fix(edge): preserve publisher accounting across transport generations"
```

This is the first implementation checkpoint. It must compile as a whole, contain no generation-less admission path, and never expose startup-fence lookup under the old manager-first topology. Inspect `git status --short` immediately afterward; no Task-2/3/4 source or test may remain uncommitted.

### Task 5: Bind the production publisher to the monitored generation

**Files:**
- Review: `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/jet_stream_publisher.ex` (the exact-PID call migration landed atomically in Task 3)
- Modify: `elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/jet_stream_publisher_test.exs`
- Create: `elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/jet_stream_publisher_restart_test.exs`

**Interfaces:**
- Consumes: the exact connection PID already resolved before admission and `PublisherPool.admit/5`.
- Produces: test-build-only `publish_record_for_test/2` traces through the same private pipeline as production `publish_record/1`, keeping one ledger authoritative across ordinary old/new connections and keeping a replacement ledger closed behind any send-capable connection from a lost epoch.

- [ ] **Step 1: Build a deterministic controlled connection test double**

The double must expose two independently controlled processes—the reconnect manager and the actual request-serving connection—and implement the project-owned connection API used by the publisher:

```elixir
manager_pid :: pid()
connection_pid :: pid()
get(connection_name) :: {:ok, connection_pid}
request(connection_pid, subject, payload, opts) :: {:ok, message} | {:error, reason}
```

Implement `request/4` in two stages, matching the property that matters in Gnat: writing/subscribing through the connection and waiting for the PubAck are not one connection-owned blocking call. First make a short call to the generation process that records the request, returns an opaque request reference, and sends the test process:

```elixir
{:request_started, generation_pid, request_ref, publisher_pid, subject, payload}
```

Then let the publisher caller wait independently for `{request_ref, result}` from the test controller. Killing the generation must **not** release that wait automatically. The test decides when to deliver the transport error, which lets it prove that the pool's independent connection monitor—not owner-reported `attempt_failed/2`—made the reservation retryable. The controller can also deliver a valid PubAck after the old accountant is gone, which is the accountant-loss interval the production return path must classify as non-durable.

Keep the generation GenServer responsive: its short `handle_call` records the request and replies with the wait reference immediately; it also serves synchronous history queries and additional requests while publisher callers wait outside it. Do not retain the original caller's `from` and return `{:noreply, state}` for the whole PubAck wait. That tempting fake dies with G1 and immediately wakes the publisher caller, allowing owner-reported failure to mask a broken generation-`DOWN` transition. Do not collapse manager and connection into one PID: their non-atomic termination is the accountant-loss defect. Use messages/monitors only; do not use `Process.sleep/1` to infer that a request started.

The controlled resolver must also support an explicit barriered switch from G1 to G2 while G1 remains alive. That is test-only authority used to expose simultaneous old/new generations; production still resolves its named Gnat connection normally. A trace that kills G1 before G2 can be selected never measures overlap and is insufficient.

Each controlled generation must retain an ordered request history and expose it through a synchronous query. After every refused B/D call, query both G1 and G2 and prove the refused publication appears in neither history. Do not use `refute_receive` as the no-I/O proof: request notifications and publisher results come from different senders, so mailbox absence is timing-sensitive and can pass before a late request notification arrives.

- [ ] **Step 2: Write the exact frame-credit restart trace**

With one frame credit:

1. Start A and wait for `{:request_started, g1, ...}`.
2. Assert the stable pool reports one outstanding frame. Read the pool state synchronously: `connections_by_pid[g1]` must be the exact generation reference carried by A's active window attempt, and no G2 reference may appear. This binds mediation before owner-reported failure can mask a wrong connection association.
3. While G1 remains alive and A's request is still blocked, start G2 and atomically switch the controlled resolver so new publisher calls receive G2. Keep the pool PID unchanged.
4. Offer distinct publication B through `publish_record_for_test/2`. Assert it returns `{:error, :capacity}` and no request for B was recorded on either G1 or G2. This is the overlap measurement: two live generations share one ledger and cannot together exceed its grant.
5. Terminate G1 while the original A publisher caller remains blocked behind the controlled reply barrier. Wait until the pool has processed its own exact connection `:DOWN`, and assert A's reservation remains charged but its attempt is idle. Only after observing that state, release the original A caller with its transport error; assert the late owner report cannot change or release the retained reservation.
6. Retry A on G2. Ack and settle it on its retained charge.
7. Offer B again. Assert B reaches G2 and succeeds.

Pin the exact ordered trace, not a count of failures. A false-success admission followed by an unrelated failure must not satisfy it.

- [ ] **Step 3: Write the independent byte-credit trace**

Use frame grant 3 and byte grant 100:

- A consumes 80 bytes on G1 and remains blocked.
- While G1 is still live, switch new calls to G2. Start `publish_record_for_test(C, opts)` in its own task, wait for `{:request_started, g2, ...}`, and assert the pool reports exactly two outstanding frames/100 bytes while both requests remain blocked. C cannot be called inline because the controlled connection intentionally withholds its reply.
- A 1-byte D or 30-byte B is refused specifically for byte capacity and performs no I/O on either generation while frame capacity remains.
- Terminate G1 while A's original publisher caller remains held behind the controlled reply barrier, and wait until the pool has processed its `:DOWN`; A remains charged at 80. Release the old caller only afterward and prove its late owner report leaves that accounting unchanged.
- Ack G2 and await C; settling C still leaves B refused while A retains 80.
- Retrying and settling A returns the bytes; B then reaches G2.

After each completed or refused publisher operation, read `PublisherPool.capacity(pool)` synchronously and pin its exact frame/byte values plus the exact refusal reason. `publish_record_for_test/2` returns no window state. This catches a fix that preserves frame count but resets byte accounting.

- [ ] **Step 4: Re-verify the exact PID at the production boundary**

Task 3 already changed the admission call after the existing `connection_for/2` step atomically with the public arity migration:

```elixir
PublisherPool.admit(pool, conn_pid, key, byte_size(bytes), timeout_of(opts))
```

Keep `request/5` on that same `conn_pid`. Do not introduce an option or public arity that accepts a caller-selected generation reference.

Verify through the controlled double that `{:error, :restart_fenced}` from admission remains `{:error, :systemic}`. It is a transient lane restart, not a malformed publication, and request I/O must not occur. Do not make another production edit here unless the new public trace exposes a real defect.

- [ ] **Step 5: Add the accountant-loss trace**

At unit level, put the real `PublisherPool` child and the two-process controlled transport child under the same pool-first `:rest_for_one` ordering; Task 4's exact production child inventory binds that ordering to `LaneSupervisor`.

Hold A after `request_started` on G1, then kill the pool. This trace uses the ordinary registered `PublisherPool.via(lane)` lookup—never a `pools:` override or a captured old pool PID. The controlled connection module may be injected, but its `get/1` must resolve the requested registered lane name and return that process; it may not accept a caller-selected generation PID. Drive and assert these phases explicitly:

1. The controlled manager enters termination while G1 remains alive. The old pool is gone and there is no replacement pool yet. Deliver a valid PubAck for the original A request through the controller, explicitly await that original publisher task, and require `{:error, :systemic}`: the broker reply cannot be reported durable because the accountant that authorized A is gone. Assert `Process.whereis(PublisherPool.via(lane)) === nil`, then offer B through the test-only publisher entry point. It returns retryable `:systemic` with no request.
2. Let the manager exit but deliberately keep its linked-like inner G1 alive and registered. Wait until `Process.whereis(PublisherPool.via(lane))` returns a new PID, assert it is the exact replacement pool being inspected, and assert that pool reports its exact `startup_fence` on G1. Offer B without a pool override. It again returns `:systemic`, performs no request, and leaves the empty replacement accounting unchanged. This call must reach the replacement pool's fence; a call against the dead old pool is not evidence.
3. Terminate G1 and wait both for G1 `:DOWN` and for the replacement pool to synchronously report no startup fence. Let the replacement manager install G2. Replay A first and assert it reaches G2, succeeds, and is not reported durable from the lost G1 evidence. With the one-frame grant, offer B only after A settles; assert B then reaches G2 and succeeds. Publishing only unrelated B would leave the required replay path untested.

After both refusals in phases 1 and 2, synchronously query the controlled generations' request histories and assert B is absent. Do not substitute mailbox silence. Do not infer causal order from monitor messages emitted by different PIDs; query the supervisor/pool state at each barrier. State explicitly that this controlled unit trace is not the final real-Gnat proof: task 0.12 repeats it against real NATS in `vertical_slice_test`. Neither an unbound lookup miss nor permanent refusal is sufficient; the lookup path is admissible only with the continuous-registration invariant pinned in Tasks 3 and 4.

- [ ] **Step 6: Run the gateway tests under more than one seed**

Run:

```bash
cd elixir/serviceradar_agent_gateway
mix test --no-start test/serviceradar_agent_gateway/jet_stream_publisher_test.exs \
  test/serviceradar_agent_gateway/jet_stream_publisher_restart_test.exs --seed 1
mix test --no-start test/serviceradar_agent_gateway/jet_stream_publisher_test.exs \
  test/serviceradar_agent_gateway/jet_stream_publisher_restart_test.exs --seed 1701
```

Expected: both seeds pass with identical logical traces.

- [ ] **Step 7: Commit the green production-path implementation before mutation controls**

```bash
git add elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/jet_stream_publisher_test.exs \
  elixir/serviceradar_agent_gateway/test/serviceradar_agent_gateway/jet_stream_publisher_restart_test.exs
git commit -m "fix(edge): preserve lane grants across publisher generations"
```

If the public traces exposed a genuine production defect and the source changed, inspect and add that exact source path explicitly before committing; do not stage it pre-emptively.

The committed baseline is mandatory. Do not use `git restore` for mutation work while Task 5 is uncommitted; that exact pattern has already destroyed valid work in this workstream.

- [ ] **Step 8: Run only the three load-bearing negative controls**

Demonstrate, one at a time, that the tests fail if:

1. generation termination deletes A's reservation or decrements its byte count;
2. replacement-pool startup ignores the still-live registered G1 and admits B before G1 is `DOWN`;
3. admission is deliberately bound to a different live PID such as G2 while `request/5` still uses captured G1. Reject an undefined-arity or compile failure. The frame trace must fail behaviorally at its pre-kill mediation assertion: `connections_by_pid` and A's active attempt must name G1's exact reference, not G2's. Do not rely on the later request failure, because owner-reported `attempt_failed/2` could idle the reservation and mask the wrong generation binding.

Confirm each edit applied before running it. Restore only the mutated file from the committed Task-5 baseline after each run, then run `git status --porcelain=v1` and require completely empty output before the next mutation; `git diff --quiet` alone misses staged and untracked mutations. These are non-vacuity controls for group E, not a mutation-score campaign. Do not add neighboring probes after all three fail for the named reason.

- [ ] **Step 9: Record the three measured failures without amending production**

Put the exact failing test/reason for each control in the PR body or Task 6 evidence reconciliation. Do not claim a score, do not add a mutation table to production files, and do not amend the green Task-5 commit unless restoring the controls exposed a real source/test defect.

### Task 6: Reconcile claims and run the actual repository gates

**Files:**
- Review all files changed by Tasks 1-5.
- Do not add files solely to restate evidence.

**Interfaces:**
- Consumes: the complete restart implementation and focused evidence.
- Produces: a reviewable PR that satisfies task 3.3's local restart-overlap implementation criterion without claiming the future composed group-E target or broader task 3.3.

- [ ] **Step 1: Search for stale lifecycle claims by concept**

Search for all of these concepts, not only one exact sentence:

```bash
rg -n ":one_for_all|one restart unit|restarts both|fresh pool|empty window|restart overlap|generation.*release|owner death.*free|task 3\.3" \
  elixir/serviceradar_core/lib/serviceradar/edge \
  elixir/serviceradar_core/test/serviceradar/edge \
  elixir/serviceradar_agent_gateway/lib \
  elixir/serviceradar_agent_gateway/test \
  openspec/changes/unify-sweep-results-proto
```

Classify every hit. Remove contradictory claims; preserve historical text that is explicitly labelled as prior behavior.

- [ ] **Step 2: Format and run focused Bazel gates**

Run:

```bash
(cd elixir/serviceradar_core && mix format --check-formatted)
(cd elixir/serviceradar_agent_gateway && mix format --check-formatted)
bazel test -c opt --config=remote \
  //elixir/serviceradar_core:unit_tests_serviceradar_edge \
  //elixir/serviceradar_core:unit_tests_serviceradar_other \
  //elixir/serviceradar_agent_gateway:unit_tests_serviceradar_agent_gateway \
  //elixir/serviceradar_agent_gateway:production_api_surface_test
bazel build -c opt --config=remote \
  //elixir/serviceradar_agent_gateway:erlang_app_prod
```

Expected: all four test targets pass and the production app builds. `unit_tests_serviceradar_other` is included because it owns the NATS publisher-connection topology test. The dedicated production-surface target loads only the `:erlang_app_prod` gateway artifact and proves `publish_record_for_test/2` is absent; the prod build alone would not prove that export constraint.

- [ ] **Step 3: Run strict proposal and diff validation**

Run:

```bash
openspec validate unify-sweep-results-proto --strict
git fetch origin usp-01-proposal
git diff --check "$(git merge-base HEAD origin/usp-01-proposal)"..HEAD
git diff --check
```

Expected: all commands exit zero. The merge-base range checks the committed PR diff; the bare command separately checks any still-uncommitted reconciliation. Running only the bare command after the implementation commits would be vacuous.

- [ ] **Step 4: Run the whole repository gate**

Run:

```bash
make test
```

Expected: Bazel's complete non-integration unit sweep passes. Read the final result; do not infer success from a still-running invocation.

- [ ] **Step 5: Record the exact stopping point**

The PR summary must say:

```text
Task 3.3's local restart-overlap criterion now has implementation-level frame and byte evidence. Task 0.12 group E remains open until its composed observation runs in //integration_tests/edge_record:vertical_slice_test. Task 3.3 remains unchecked for asynchronous issuance and delivery of out-of-order completions into the task-3.5-owned validation/contiguous-prefix seam; that debt is not a seventh task-0.12 group. The next active-milestone work is the Stream/composed vertical slice.
```

Do not append the deferred async pipeline to this PR.

- [ ] **Step 6: Commit any final reconciliation**

Run `git status --short`, inspect every path, and stage only the exact reconciliations made in this step. Do not use a directory-wide `git add`; it can absorb unrelated or generated work. Then commit:

```bash
git commit -m "docs(edge): reconcile restart-overlap evidence"
```

If Step 6 has no diff, do not create an empty commit.

## Plan Self-Review

- Spec coverage: tasks 1-5 cover the two restart cases, retained-charge retry, frame and byte axes, exact production PID binding, accountant loss, and positive post-fence liveness at implementation level; composed acceptance remains in the vertical slice.
- Scope coverage: no task adds the Stream server, async pipeline, `ResolvedPrefix` integration, another traffic class, benchmark, dashboard, or seventh acceptance group.
- Type consistency: `PublisherPool.admit/5` accepts an exact connection PID; the pool derives `generation_ref`; `PublishWindow.admit/6` consumes that ref; `generation_terminated/2` returns attempts to idle without releasing reservations.
- Evidence quality: every ordering assertion uses a message or monitor; the frame and byte traces identify the exact operation and reason; final empty state is never used as the sole proof.
- Stopping rule: after this plan, proceed to task 0.12's Stream/composed vertical slice while group E remains open for its real-NATS observation and task 3.3 remains unchecked for asynchronous issuance and delivery of out-of-order completions into task 3.5's validation/contiguous-prefix seam.
