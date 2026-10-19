# ServiceRadar Atlas server scale acceptance

This manual workload measures the combined current-state database source,
native index, Atlas projection, authorization, HTTP and WebSocket delivery.
It does not measure browser decoding, GPU rendering, layout calculation,
world persistence, or upstream discovery ingestion. Geometry is an invented
native world installed through `WorldCache`; canonical mappings still come
from the real paged dictionary reader.

The compact workload has not passed against the hosted database; sparse has
not run. Earlier compact attempts stopped before any viewer started: one at
diagnostic time admission, one at tile receipt authorization (an HTTP 403 on
`GET /topology/tiles/:version/3/:x/:y`) because role profiles were absent, and
one during concurrent WebSocket upgrades because the Sandbox pool was pinned,
each since corrected. The
two latest attempts reached the viewers and failed. The latest compact attempt
([BuildBuddy a692930f](https://carverauto.buildbuddy.io/invocation/a692930f-82b4-4b06-8143-b1956cac1a56),
commit 472387c7e9) seeded 1,100,000 synthetic devices with 2,200,000 addresses,
started both four-scheduler peers, upgraded 50 concurrent authenticated
sockets per server, mapped all 1,100,000 ordinals on both servers (12.0 and
13.0 seconds, 4,400,176 retained bytes each), and returned every HTTP tile
receipt. It then failed the 90-second "initial 100 views" wait. The
all-viewer report shows 47 viewers with no frame, each after 12 watches that
all returned `query_busy`; 865 of 925 watches returned `query_busy` and no
other error was reported. Native retained memory stayed near 74 MB (87 MB
peak) and sampled pins peaked at 6 of 8. No warmup, churn, replacement,
reconnect or revocation phase ran. The hosted lifecycle's clone cleanup
finished with observer, teardown and release status 0. The earlier attempt
([BuildBuddy e578c706](https://carverauto.buildbuddy.io/invocation/e578c706-e28c-410e-9542-bf79ec2ff243),
commit a8559ac3df) failed the same wait. In it and the attempt before, the
test's own fixture cleanup rolled back when deleting the 1,100,000 devices hit
its 120-second statement timeout. Cleanup now skips the per-row inventory
rollup trigger and recounts once at the end, as the seed does; the bounded
report from a692930f does not show whether that cleanup completed.

The public reason does not say which admission point refused each watch,
and no hosted measurement attributes every rejection. The code shows one cause
consistent with the report and with the database-free negative control below.
The eight-task query admission refused, without waiting, every query that
arrived while all eight tasks were busy. Each server socket schedules its
5-second refresh tick from its join, and the viewers join together, so those
ticks are likely aligned. The client backoff (1, 2, 4 and 8 seconds, then 10;
the browser uses the same schedule) would put every later retry on one of
those ticks. That alignment is inferred, not measured. A viewer without a
frame could therefore keep retrying into the refreshes of viewers already
served and lose that race on every attempt. Admission is now first-come: a
query waits for one of the same eight tasks until its own one-second deadline
and answers `query_busy` when no task frees in time. It also answers
`query_busy` immediately when all 64 waiting places hold live, unexpired
requests. A database-free test
reproduces the starvation (all 24 newcomers refused on the old admission)
and passes with the change. The earlier native fix, where admitted readers
wait out the index's short bookkeeping sections instead of failing as busy,
is kept. Task, reader, pin, memory, deadline and workload limits are
unchanged.

The next compact attempt on that admission
([BuildBuddy f909d7e6](https://carverauto.buildbuddy.io/invocation/f909d7e6-4cff-476b-b66b-71538f037537),
commit 59cbade538) failed the same wait with fewer stalled viewers: 29 had no
frame, 151 frames were delivered and 776 watches returned `query_busy`, with
no timeout or other error. Sampled pins peaked at 7 and 6 of 8, native memory
stayed under 88 MB and mailboxes held at most 3 messages. First-come admission
therefore helped but did not clear the stall. The zero timeouts do not rule
out admission expiry, because a waiter that never starts legitimately expires
as `query_busy`, not as a timeout.
Each `query_busy` is now counted by origin as the
`[:serviceradar, :topology, :bitmap_query, :busy]` telemetry event, and each
admitted query reports its queue wait and run time. The origins are admission
expiry and a full queue, an occupied stream, a full watch-task pool, each
projection step (tile-cache fetch, device ordinals, aggregate selection and
aggregate ordinals), and each native budget or lock. The replica meter adds
both to every scale report. These counters separate the refusing points the
code names; they do not by themselves explain a refusal they cannot see.

One concrete contender is reproduced but not yet confirmed as the hosted
cause. Each aggregate export holds one of only two native ordinal readers,
and every 64-tile compact view exports 64 aggregates. Eight admitted queries
exporting at once got `{:error, :busy}` from the real native gate, which
failed the whole view. An aggregate export now waits for a reader within its
own remaining query budget and still reports busy if none frees in time. The
two-reader, eight-query and one-second limits are unchanged. A database-free
native test fails on the old export and passes with the wait.

The next compact attempt
([BuildBuddy b266c89a](https://carverauto.buildbuddy.io/invocation/b266c89a-4738-4fb6-9871-2b410c1be491),
commit 507b375634) cleared the initial wait: all 100 viewers received frames.
Warmup delivered 277 frames for 372 watches, with 46 `query_busy`, 126
`query_timeout` and 109 resets; accepted-frame latency was 709, 876 and 1,003 ms
at p50, p95 and p99. The run then failed during churn. Churn writes took 10.5 to
18.0 seconds per tick (mean 13.5) against the requested 5-second cadence, so
that cadence was not achieved. Thirty-nine normal viewers stopped on the
30-second progress check: 24 after tick 16, 1 after tick 31, 2 after tick 32
and 12 after tick 34. The driver did not notice and ran to tick 60, where it
failed calling a stopped viewer. The mapping replacement started at tick 30,
but the driver failed before collecting its completion, so the run reports no
replacement result and does not validate it. The restart, reconnect and
revocation phases never ran. All 60 fifty-facet HTTP queries answered 200. Native
memory peaked at 101,036,506 bytes, pins at 8 of 8 and server RSS near 1.28 GB.
Busy origins were aggregate ordinals 90 and admission expiry 819 on the first
server, and 34 and 207 on the second. The hosted clone cleanup finished with
observer, teardown and release status 0.

The stopped viewers' own state, from the redacted crash reports, separates two
failures:

- 36 viewers held the latest revision of the server that receives no hints.
  That server changes its index only through reconciliation passes, which
  took about 3 minutes 50 seconds each, and it starts the next pass 30
  seconds after the last one ends. Each group's last frame carried the
  revision that ended a pass (4,402, then 6,603), and the viewers stopped 30
  seconds later, before the next pass published. They were current, and the
  check, which required a new revision every 30 seconds, could not pass there.
- 3 viewers on the hinted server, during the mapping replacement, made no
  progress while that server kept publishing. Each had 58 to 63
  `query_timeout` errors in about 96 watches.

Every stopped viewer had about as many resets as frames, and its only errors
were `query_timeout` and `query_busy`. So almost every periodic refresh after a
frame failed, and each failure reset the viewer instead of keeping its frame.
Two causes are visible in the code. First, the transient-failure path rechecked
the retained binding with the build's own deadline, which a timeout or an
expired admission has already spent, so the frame could never be kept. Each
such refresh became a reset and a new watch under the renderer backoff, which
adds load. Second, every socket schedules its refresh from its join. Viewers
that join together refresh as one burst on every tick, and first-come
admission serves that burst in the same order each time. The admission wait
histogram is consistent with bursts: in the first server's final sample,
admitted waits were either under 16 ms (3,257) or 256 to 1,023 ms (7,087), with
only 39 in between (28 at 16 to 31 ms, 4 at 32 to 63 ms, 4 at 64 to 127 ms
and 3 at 128 to 255 ms). The burst order is inferred from the code, not measured.

The binding recheck now gets its own one-second budget, so a transient refresh
failure keeps the frame and the next tick retries. Each socket's first refresh
falls at a random point between 5 and 10 seconds after it joins, then every 5
seconds as before, so sockets that join together no longer refresh in step.
The 15-second ACK threshold is still checked at least every 5 seconds. The
harness now judges each normal viewer against its own server: it fails when the
viewer shows no membership, or holds a revision the server superseded, for more
than 30 seconds. A sampler records when each server published each revision,
dated from the previous read so that sampling never shortens a measured lag. A
held revision counts as current only as of the sampler's last successful read,
so failed or missing reads, or an epoch the sampler never saw, cannot certify a
viewer for more than 30 seconds, and new frames for an unseen epoch do not
renew that coverage; the failure report carries the basis and the
sampler's failure count and read age. A
viewer that stops now fails the driver on its next step with the viewer's own
bounded report. The bound and the workload are unchanged.
Whether the
stall clears is unproven until the hosted compact and sparse runs pass. OpenSpec task 4.2 remains unchecked until both
distributions finish and their numbers and failures are reviewed. The
database-free harness target compiles the complete scenario and checks its
independent frame consumer, native geometry partition and isolated VM
measurements.

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

The opt-in runs before the existing diagnostic database cases. Both peer
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
before the first workflow step) only for the compact and sparse variants, and
verifies that parent is the declared runner. Ordinary diagnostics do not read
that clock. Scale warms
the database suites and selected scale target before starting the observer.
Immediately before scale execution it checks both remaining clocks. The floor
is 2,925 seconds: 2,760 for the complete Bazel command (including its unchanged
2,700-second test limit), 30 seconds for quiescence, 120 seconds for cleanup,
5 seconds of observer kill grace, and 10 seconds of status reserve. Teardown and
lease release each have a 60-second command envelope, including forced exit.
The observer's complete command is also bounded by the smaller of 3,300 seconds
and the remaining action time minus ten seconds for final status cleanup; its
five-second kill grace is inside that envelope. A stuck final sample cannot
leave the cleanup waiting beyond the action's remaining budget.
Insufficient time refuses admission and runs cleanup; it does not shorten the
scenario or count an incomplete workload as a pass.

Scale runs first, right after the guarded clones are created, so the existing
`networks_live_db_test` and `plugin_config_cli_db_test` cases cannot consume its
window. One hosted compact dispatch was refused at admission after those cases
ran first: the prelude had already used 435 seconds of observer time. Compact
seeds `serial_0` and deletes its rows, user and ordinal sequence position on
exit before those cases run there; sparse uses `serial_1`. The existing cases
still run and remain required. Before each one starts, the same two clocks are
read again, and it runs under a forced-exit envelope of whatever both deadlines
hold beyond the same 165-second quiet, cleanup and status reserve. A case that
cannot start or finish in that remainder fails the run and nothing further
starts. The limits are not raised to make every phase fit: a scale test that
uses its full 2,755-second envelope leaves roughly 300 seconds, less than an
ordinary network case has taken in hosted CI, so that run fails instead of
passing. Observer coverage includes clone creation, scale and both cases.

Local compile and database-free verification use RBE:

```sh
bazel test -c opt --config=remote \
  //elixir/web-ng:topology_bitmap_scale_harness_test --test_output=all
bazel build -c opt --config=remote --//build:enable_integration_tests \
  //elixir/web-ng:topology_bitmap_scale_acceptance
```

Do not run the database targets against a live or developer database. The
helper requires the existing scratch-database guard and verified TLS. The
acceptance test refuses to seed unless the connection is this run's disposable
clone and no `sr:atlas-scale-%` rows are already present. The exit hook closes
over that seed record, including a seed that stops early. It is a bounded
attempt of about one minute between the 2,640-second ExUnit timeout and the
2,700-second Bazel timeout. The cleanup guarantee is the guarded CI clone drop
`//rust/integration-db:teardown_db`, which drops the clone after the test. Do not
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
four ordinary schedulers and four dirty CPU schedulers each (ERTS caps dirty
CPU schedulers at the normal scheduler count). Each server's Repo uses the
production `DBConnection.ConnectionPool` with the inherited test pool size and
queue limits, not the test Sandbox: in Sandbox `:auto` mode every long-lived
WebSocket process would keep the connection it used to authenticate, pinning
the pool and turning later upgrades into HTTP 403. Before waiting for the
publishers, the driver opens 50 concurrent authenticated WebSocket upgrades per
server and requires every one to succeed. There is no
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
During ready churn, a normal client may neither show no membership nor hold
a revision its own server has superseded for more than 30 seconds. Each client
checks this even while the driver is blocked, against a sampler that dates
each server revision from the previous read. A held revision is current only
as of the sampler's last successful read, so lost sampling also fails the
bound. The driver fails on its next step when any client stops.
Cold restart is a separately bounded recovery phase; every client must
recover to the final SQL-derived population. Reconnects, cross-replica live
pagination, oversized-facet-value refusal and authority revocation are required
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
  Each report states whether the telemetry handler is still attached; a
  detached handler fails the run instead of passing on stale counters.

The final record includes accepted-frame bytes, watch-to-first-accepted-frame
latency percentiles, all
busy/timeout/error/retry counts, slow-client resets, each normal client's
maximum checked progress gap, HTTP facet latency and status counts, and
reconciliation/reconnect outcomes. The frame latency is not an end-to-end
measurement for subsequent unsolicited pushes. Driver writes and the final
independent SQL population oracle are outside the per-server query counters.
Every wait has a failure deadline; a crashed client is not automatically
restarted and hidden. When a viewer wait fails, a `wait_failed` record lists
every viewer's counters (or marks it down) and both servers' meter reports.
The record contains no session values.

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
