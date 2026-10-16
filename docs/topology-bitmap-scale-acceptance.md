# ServiceRadar Atlas server scale acceptance

This manual workload measures the combined current-state database source,
native index, Atlas projection, authorization, HTTP and WebSocket delivery.
It does not measure browser decoding, GPU rendering, layout calculation,
world persistence, or upstream discovery ingestion. Geometry is an invented
native world installed through `WorldCache`; canonical mappings still come
from the real paged dictionary reader.

The workload is implemented but has not run against the hosted database.
OpenSpec task 4.2 remains unchecked until both distributions finish and their
numbers and failures are reviewed. The database-free harness target compiles
the complete scenario and checks its independent frame consumer, native
geometry partition and isolated VM measurements.

## Run through the existing hosted lifecycle

After the branch has passed review and is pushed, dispatch the existing
`WebNgDbDiagnostic` action against its exact branch and commit. Set the
ExecuteWorkflow environment override `SERVICERADAR_TOPOLOGY_BITMAP_SCALE` to `compact` or
`sparse`, one distribution per dispatch. Empty or `0` disables the workload.
Other values, including `both`, fail. The diagnostic keeps its existing network
and plugin database cases. Full `BazelCI` correctness gates the PR separately;
no additional provisioning action or script is involved.

The targets are:

| Target under `//elixir/web-ng` | Purpose |
| --- | --- |
| `topology_bitmap_scale_harness_test` | Database-free harness validation; regular unit gate. |
| `topology_bitmap_scale_compact_acceptance` | Full workload on the existing `serial_0` scratch clone. |
| `topology_bitmap_scale_sparse_acceptance` | Full workload on the existing `serial_1` scratch clone. |
| `topology_bitmap_scale_acceptance` | Manual suite naming both variants. |

The opt-in runs after the existing diagnostic database cases. Both peer
servers in one variant use the same clone: compact uses the existing `serial_0`;
sparse provisions `serial_1` through the existing generation target and checks
its generation digest and run identity. The same observer and cleanup trap
own connection measurement, teardown and lease release. Each server uses
eight database connections, and the driver uses eight. The observer admits
24 slots for scale and retains its ordinary 15-slot setting otherwise.

The observer limit increases from 1,800 to 3,300 seconds only for this opt-in.
The existing 7,200-second generation lease already covers one run; there is
no extra renewal. The selected Bazel test has a 2,700-second (45-minute) limit.
The ExUnit scenario has 2,640 seconds, reserving a minute for peer teardown.
The hosted runner was observed enforcing a one-hour `free_tier_limit`; this
is why scale runs in the smaller diagnostic action, not after the full
BazelCI workload. Schema preparation, compilation and diagnostic cases still
consume outer time. ExecuteWorkflow cannot override that timeout. A timeout
is a failed, incomplete measurement, never evidence of acceptance.

The diagnostic reads the parent runner's process-start clock (including checkout
before the first workflow step), verifies that parent is the declared runner,
and warms
the database suites and selected scale target before starting the observer.
Immediately before scale execution it checks both remaining clocks: 2,760
seconds for the complete Bazel command (including its unchanged 2,700-second
test limit), 30 seconds for quiescence and 120 seconds for cleanup. Teardown and
lease release each have a 60-second command envelope, including forced exit.
The observer's complete command is also bounded by the smaller of 3,300 seconds
and the remaining action time minus ten seconds for final status cleanup; its
five-second kill grace is inside that envelope. A stuck final sample cannot
leave the cleanup waiting beyond the action's remaining budget.
Insufficient time refuses admission and runs cleanup; it does not shorten the
scenario or count an incomplete workload as a pass. Observer coverage still
includes the earlier database suites and clone creation.

Local compile and database-free verification use RBE:

```sh
bazel test -c opt --config=remote \
  //elixir/web-ng:topology_bitmap_scale_harness_test --test_output=all
bazel build -c opt --config=remote --//build:enable_integration_tests \
  //elixir/web-ng:topology_bitmap_scale_acceptance
```

Do not run the database targets against a live or developer database. The
helper requires the existing scratch-database guard and verified TLS. Do not
rerun a completed variant in a dirty clone: fixture IDs intentionally collide
and fail rather than silently reuse prior state.

## Declared workload

Each variant creates 100,000 infrastructure devices and 1,000,000 endpoint
devices, with two assigned addresses per device. The primary address is unique
under `2001:db8:1::/48`, using the bijection `(n * 7919) mod 1100000` for
nonmonotonic address ownership. A current interface row supplies the shared
IPv4 address `198.51.100.7`. This preserves the production unique active primary
address constraint while exercising shared interface membership. All values are
invented. Eight vendors, ten regions, eight VLANs and fifty cohort values
exercise scalar facets. A separate fixture marker excludes preexisting
scratch records from the expected population.

Compact ordinals start above existing allocations with stride one. Sparse
ordinals start at or above 2^31 with stride seven. In each 500-row transaction,
the fixture creates new inactive canonical devices, assigns their invented
sparse dictionary ordinals, then activates them through the real lifecycle
triggers. This happens before indexing or mapping and never reassigns an
existing identity or tombstone. The sequence is advanced after bootstrap.
Sparse means separated high IDs, not a uniform sample of the entire u32 space.

Two isolated BEAM VMs run the production source publishers and endpoint, with
four ordinary schedulers and eight dirty CPU schedulers each. There is no
mock query source or alternate publisher. Geometry covers 64 tiles, each with
127 device glyphs and one aggregate. All views cover those tiles; row counts
must add up to the exact matching population, including zero matches.

After all 100 Gun WebSocket clients receive an accepted frame, 100 ticks
update one percent of the entire population each, targeting a five-second
cadence. Every device changes availability and its primary address once,
preserving its unique suffix under the replacement `2001:db8:2::/48` prefix.
Only server A receives post-commit hints. Server B must reconcile through its
ordinary scans, including after its publisher is stopped and restarted at
tick 60. That is an owner/index restart, not a pod or VM restart. Tick 30
starts a mapping replacement concurrently with the continuing writes and
views. The report includes actual tick work time; slow database writes are
not disguised as meeting the requested cadence.

The four-term view query selects unavailable fixture devices, their IPv6
range and a literal region prefix. One real HTTP request per tick additionally
asks for fifty exact cohort facets. Counts must partition the same result.
The driver records successful HTTP percentiles separately from rejected
requests, and requires some successful fifty-facet responses. Existing native
benchmarks own the native-only latency thresholds.

Ninety clients acknowledge immediately. Ten delay ACKs for 25 seconds and
must each observe a reset by 21 seconds: the production 15-second threshold
is checked on a five-second tick, with one second of scheduling allowance.
Normal clients must receive a fresh accepted revision within 30 seconds
during ready churn, checked by each client even while the driver is blocked.
Cold restart is a separately bounded recovery phase; every client must
recover to the final SQL-derived population. Reconnects, cross-replica live
pagination, facet-cardinality refusal and authority revocation are required
before the scenario can finish. Separate HTTP predicates must find every
replacement primary address and none of the removed primary addresses; the
shared interface IPv4 predicate must still select the complete population.
Revocation checks compare each client's forbidden counter with its value before
deactivation, so a historical close cannot satisfy the new denial.

Gun emulates the production renderer's transient-error retry schedule:
1, 2, 4, 8, then at most 10 seconds, with the standard 10-second Phoenix push
timeout. Successful watches stay subscribed and use the production server's
five-second tick. Resets use the same capped retry schedule. Rebinding a watch
retains the failure count; only an accepted complete frame resets it. The harness
does not repeatedly send successful watches to manufacture throughput.
Compression is disabled, matching the current production endpoint; negotiated
compression has its own independent transport probe.

Reconnects deliberately close the Gun connection abruptly; they do not prove
a normal WebSocket close handshake. Final teardown stops each server supervisor
and waits for its peer VM's `DOWN` notification. The existing database observer
owns verification that fixture connections are released.

## Reading the evidence

Each `TOPOLOGY_BITMAP_SCALE` JSON line is a phase, tick or measurement, with
no SQL parameters, cookies, tokens or database URLs. Preserve the BuildBuddy
invocation, exact commit, selected distribution and complete failure output.
The machine record includes OTP/Elixir versions, architecture, scheduler
counts and cgroup limits when available. Rust uses the repository's pinned
Bazel toolchain; retain the invocation's resolved build configuration.

Each server samples once per second and reports:

- Actual process RSS and kernel high-water RSS; total BEAM and binary memory;
  process and mailbox counts. Kernel high water catches peaks between samples.
- Native reservation bytes and their peak, query pins, pending dirty work,
  and the current canonical mapping's bytes. Missing native or mapping
  observations are explicit; final observations must be available.
- Repo telemetry query counts, returned rows, query/decode/queue microseconds,
  grouped by address cursor, dictionary, inventory, authority and other work.
  These are client-observed database costs, not database CPU or physical I/O.

The final record includes accepted-frame bytes, watch-to-first-accepted-frame
latency percentiles, all
busy/timeout/error/retry counts, slow-client resets, each normal client's
maximum checked progress gap, HTTP facet latency and status counts, and
reconciliation/reconnect outcomes. The frame latency is not an end-to-end
measurement for subsequent unsolicited pushes. Driver writes and the final
independent SQL population oracle are outside the per-server query counters.
Every wait has a failure deadline; a crashed client is not automatically
restarted and hidden.

Memory terms are intentionally separate. Native reservations include active
scratch work; they are not pure retained index memory. A sample's current
mapping is not all retained mappings: native lifetime permits independently
bound them to two 32-MiB resources. The native steady cap of 125,000,000 bytes,
two mappings and the four-MiB prefix catalog total 196,303,168 bytes, while
active native reservations can reach 160,000,000 bytes. Source pages, geometry,
BEAM binaries, socket buffers, existing prefix tries and allocator overhead
are included in whole-process RSS, not in that component budget. The cluster
RSS sample sums the two latest readings; the sum of their kernel high-water
values is a conservative upper bound, not a simultaneous observed peak.

Publish both successful and rejected counts. Do not describe a target that
only compiled, a native microbenchmark, or this Gun server workload as a full
browser or deployed-backend acceptance result. Physical GPU and browser
retention remain separate evidence in
[the GPU acceptance report](topology-bitmap-gpu-acceptance.md).
