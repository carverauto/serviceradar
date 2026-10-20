# ServiceRadar Atlas server scale acceptance

This manual workload measures the combined current-state database source,
native index, Atlas projection, authorization, HTTP and WebSocket delivery.
It does not measure browser decoding, GPU rendering, layout calculation,
world persistence, or upstream discovery ingestion. Geometry is an invented
native world installed through `WorldCache`; canonical mappings still come
from the real paged dictionary reader.

## Measured baseline after inventory rollup repair

Both distributions passed at d0505085a4 (merged in PR #5796):
[compact](https://carverauto.buildbuddy.io/invocation/5df517e0-c14a-4ac3-8bd0-32567213f953)
and [sparse](https://carverauto.buildbuddy.io/invocation/5ff088e3-e3a9-4e27-90b9-c2dc135320a0).
Each completed all 100 synthetic 11,000-device updates at the five-second
cadence. The respective mean write times were 863 and 849 ms; maxima were
1,762 and 1,825 ms. Both hosted lifecycles completed observer, teardown and
generation release with status zero.

The 5,000-entry replica UID inbox refused hints in all 100 bursts: 405,500
attempts in compact (36.86%) and 426,500 in sparse (38.77%). No payload-byte
overflow occurred; sampled queued payload peaked at 110,000 of 524,288 bytes.
That payload measurement excludes BEAM metadata. Ready hinted worker means
were 89/90 ms per dirty publication, 8.6/9.2 ms per resolution and 72/75 ms per
scan page. There was no recorded publisher contention or source error.

After churn, hinted query/wire observation bounds were 130,208/138,726 ms
for compact and 138,656/152,186 ms for sparse. The missed-hints/restarted peer
took 136,689/146,711 and 139,725/149,745 ms respectively. These are recovery
measurements; they do not establish normal commit-to-visible latency.
Task 4.2a is complete, while normal freshness and the intake/scheduling
comparison remain open.

The follow-up replaces count admission with a 3.5-MiB conservative live-term
budget plus the existing 512-KiB owned-payload bound. FIFO resolution retains
one charged 500-UID batch across retries.

Its first scheduler gave two hint/publication pairs to each scan/catalog turn,
with a 25-ms pause after every successful step. At 183be181f4 compact
([42d33632](https://carverauto.buildbuddy.io/invocation/42d33632-1eb2-4782-9670-c384612ff227))
refused no hints. Its ten committed-device probes took 1,168-2,133 ms to the
query and 6,167-7,072 ms to every normal hinted viewer. After churn, the
hinted query/wire bounds were 157/17,192 ms, against 130,208/138,726 ms
before. One complete tick took 5,155 ms (a 4,993-ms write/hint phase and a
155-ms query), so compact did not keep all 100 ticks under five seconds.

Sparse at the same commit
([51375701](https://carverauto.buildbuddy.io/invocation/51375701-3351-47e8-866b-bf69ce30207b))
failed the zero-refusal check. Every tick finished in under five seconds
(maximum 4,205 ms), and the ten probes took 1,397-3,913 ms to the query and
6,393-9,422 ms to all 45 normal hinted viewers. The hinted peer still refused
23,286 of 1,100,000 hint attempts at its 3,670,016-byte retained-memory bound:
393 at tick 60, then 4,000-5,000 in each of ticks 66-70. Tick 60 is the cold
restart of the unhinted peer. The oldest queued hint reached 11,134 ms and the
retained charge 3,669,960 bytes. The mailbox peaked at 17, and the publisher
reported no work failures or contention. In ticks 67-69 the peer completed only
12-13 hint/dirty batches per five seconds. Each dirty publication took 196-251
ms and each scan page 174-227 ms, against about 75 ms for a dirty batch in
stable ticks. Resolving a batch costs about 8 ms, so most of each cycle went
to publications, scan pages and pauses. The UIDs waiting behind that work held
the retained-memory budget.

The scheduler now resolves hints before every other turn, giving four
resolutions, two 500-row publications, one scan page and the catalog to each
cycle. A successful step reschedules without the 25-ms pause while hints are
waiting. Resolution moves UIDs into the native Roaring dirty set, which keeps
its own 512-KiB serialized bound and requests a rescan on overflow, so a
publication backlog no longer consumes the UID budget. There is still one
worker and one 500-row read at a time. Scan and catalog service stays at one
turn per eight. Compact and sparse have not yet been rerun with this change,
so the throughput fix is not verified.

## Earlier runs

The compact workload passed against the hosted database at commit 1887ee528e
(described at the end of this section). The sparse workload failed at that
commit; the later passing baseline is above. Earlier compact attempts stopped before any viewer started: one at
diagnostic time admission, one at tile receipt authorization (an HTTP 403 on
`GET /topology/tiles/:version/3/:x/:y`) because role profiles were absent, and
one during concurrent WebSocket upgrades because the Sandbox pool was pinned,
each since corrected. Two
later attempts reached the viewers and failed. The later of them
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
its 120-second statement timeout. Skipping the per-row inventory rollup
trigger was not enough; the 1daa6bc2 result below describes the removal of
that cleanup.

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

The next compact attempt
([BuildBuddy 1daa6bc2](https://carverauto.buildbuddy.io/invocation/1daa6bc2-ba0e-46e3-bd24-c7c67375f8ce),
commit 7d24b02af3) completed every workload phase and assertion: the fixture,
both servers, geometry, warmup, all 100 churn ticks with 100 fifty-facet HTTP
queries, the index restart, the mapping replacement, the combined phase and
the revocation. No viewer stalled and no wait failed. It is still not an
acceptance result. Churn writes averaged 13,035.48 ms per tick, so the requested
5-second cadence was not met. The facet HTTP queries answered 200 87 times and
503 13 times. Query latency was 237, 320 and 870 ms at p50, p95 and p99. The
combined phase delivered 23,737 frames, the largest 62,645 bytes. The largest
normal-viewer progress gap was 10,556 ms and the largest slow-viewer reset
19,654 ms. Native memory peaked at 111,676,774 bytes with 8 of 8 pins, and the
two servers' summed RSS high-water upper bound was 2,542,952,448 bytes. These
are server measurements over Gun; they exclude the browser, GPU, layout and
discovery. The test then failed in its own exit hook: deleting the 1,100,000
seeded devices from the shared `serial_0` clone hit the 120-second statement
timeout (PostgreSQL 57014), even with the inventory rollup skipped. The
code suggests per-row foreign-key and trigger work as the cause; that
attribution was not profiled separately. The body took 2,139.5
seconds and the test 2,274.5 seconds. The hosted lifecycle's clone drop
finished with suite status 3 and observer, teardown and release status 0.

Both variants now seed the run's dedicated `serial_1` clone, which
`teardown_db` drops on success or failure, and the per-test delete, the
ordinal-sequence rewind and the user delete are gone. The ordinary cases keep
an untouched `serial_0`. No statement timeout, deadline or workload limit
changed.

The compact run on that layout
([BuildBuddy de9f2325](https://carverauto.buildbuddy.io/invocation/de9f2325-6c7e-4eb5-8fd8-dea8be121fd8),
commit 1887ee528e, hosted parent 938a6d0d) passed. It emitted all 209 phase
records: the fixture, both servers, geometry, warmup, 100 churn ticks with 100
fifty-facet HTTP queries, the index restart, the mapping replacement (11,220
ms), the combined phase and the revocation. The hosted lifecycle's suites
passed and its cleanup finished with status 0. Churn writes averaged
13,851.09 ms per tick, so the 5-second cadence was again not met. The facet
queries answered 200 88 times and 503 12 times, with p50, p95 and p99 latency
of 243, 832 and 1,161 ms. Native memory peaked at 100,053,098 bytes with 8 of
8 pins. The largest normal-viewer progress gap was 20,563 ms across all
clients, including those replaced at reconnect, and 10,860 ms among the
viewers present at the end. These are
server measurements over Gun; they exclude the browser, GPU, layout and
discovery.

The sparse run at the same commit
([BuildBuddy 715453e4](https://carverauto.buildbuddy.io/invocation/715453e4-ca23-4257-a6b7-5ab9b0175bc1),
hosted parent f252d65d) failed after 92 ticks and 91 facet queries. Normal
viewer 14, on the hinted server, held index revision 12,713 for 30,514 ms after
that server had published a newer one (basis `behind`). The sampler had no
failed reads and its last read was 69 ms old, so the oracle had coverage. The
viewer had 232 frames, no resets, and only 1 `query_busy` and 3
`query_timeout` replies, all to watches. A refresh that fails on a periodic
tick keeps the frame and sends no reply, so its count was not visible in
the viewer report. Native memory peaked at 147,459,912 bytes, below the
160,000,000-byte limit, with 8 of 8 pins and mailboxes of at most 7 messages.
The lifecycle finished with suite status 3 and observer, teardown and release
status 0. The cold-restarted second server answered `index_not_ready` from
tick 61 to tick 85 while it reseeded.

The replica meters point to a likely cause, which is an inference: no
per-client trace of periodic refreshes was recorded. Through tick 76 both servers ran admitted
queries in 256 to 511 ms. From tick 77 the hinted server ran most queries
in 512 to 1,023 ms (81 to 142 a tick against 5 to 75 faster), while the other server stayed
in 256 to 511 ms once it was ready again. At the same tick the hinted server's
authorization queries slowed from 0.71 to about 0.9 ms and their pool wait
grew from 0.05 to about 0.18 ms. That is load across the whole replica, not
one slow query. Compact showed the same step on the hinted server at tick 44,
from mostly 128 to 255 ms to 256 to 1,023 ms, but there it still left room inside
the one-second deadline. A refresh that runs this close to its deadline
misses it often, keeps its frame and repeats the full build on the next tick.
That would explain how viewer 14 went 30 seconds without an accepted frame,
but the run did not record it directly.

The per-refresh cost has a concrete source in the code. Each scale tile carries about 127
device glyphs and one aggregate (128 rows; a 64-tile frame is about 62,645
bytes). `BitmapView` resolved each device glyph with its own
`TopologyAtlas.device_ordinals/3` call, so one refresh issued about 8,128
dirty-CPU NIF calls. At ten refreshes a second per server, that is roughly
81,000 calls a second on four dirty CPU schedulers, which the hinted server
shares with continuous publication. A temporary probe measured the call
pattern through the real NIF on RBE
([BuildBuddy c6111415](https://carverauto.buildbuddy.io/invocation/c6111415-341c-4878-b63b-c363d820eacd)).
It used 8,128 invented devices with sparse ordinals and 8 concurrent views on
an executor with 30 dirty schedulers. One call per device took 172 to 185 ms
per view at p50 (184 to 202 ms at p95); one call per tile took 2 to 3 ms.
The probe measures the call pattern, not a replica, and was not committed. A
replica has only four dirty schedulers, so the hosted cost is not
extrapolated from it.

`BitmapView` now resolves a tile's device glyphs in one call. A tile holds at
most 128 rows, within the call's 8,192-ID bound. Row order, the
`device_ordinals_busy` origin and the `source_changed` mapping are unchanged,
and so are the 30-second progress bound, the one-second query deadline, the
eight query tasks and 64 waiters, the two ordinal readers, the eight pins,
the memory limits and the workload. That change's later compact and sparse
results are recorded above. OpenSpec task 4.2 remains open for the wider
freshness and performance acceptance. The database-free
harness target compiles the complete scenario and checks its independent
frame consumer, native geometry partition and isolated VM measurements.

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
| `topology_bitmap_scale_compact_acceptance` | Full workload on the run's dedicated `serial_1` scratch clone. |
| `topology_bitmap_scale_sparse_acceptance` | Full workload on the run's dedicated `serial_1` scratch clone. |
| `topology_bitmap_scale_acceptance` | Manual suite naming both variants. |

The opt-in runs before the existing diagnostic database cases. Both peer
servers in one variant use the same clone. Either variant provisions `serial_1`
through the existing generation target and checks its generation digest and
run identity; the network and plugin cases keep `serial_0`, which scale never
touches. The same observer and cleanup trap
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
ran first: the prelude had already used 435 seconds of observer time. Both
variants seed only `serial_1`, so those cases run on an untouched `serial_0`.
The existing cases
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
acceptance test refuses to seed unless its shard is `serial_1`, the connection
is this run's disposable clone, and no `sr:atlas-scale-%` rows are already
present. The test does not delete its million-row seed. The only cleanup is
the guarded CI clone drop `//rust/integration-db:teardown_db`, which drops the
clone after the test whether it passed or failed. Do not
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

### Separating convergence costs

The `final_convergence` record observes both replicas concurrently after churn
has stopped. Each row names its scenario (`hinted` or
`missed_hints_and_restart`) and reports `query_ms` and `wire_ms` from that
common start. Query completion requires the final SQL-derived population;
wire completion requires every viewer on that replica, including slow viewers,
to accept that population. The combined `convergence_ms` is the largest query
wait. Wire wait includes the query wait and polling delay: it is an observation
bound, not the time of the first matching frame. These are post-churn catch-up
measurements, not normal database-commit-to-browser latency. The unhinted,
restarted replica's result must not be presented as a healthy hinted update SLA.

Publisher diagnostics are separate from query admission and database counters:

- `publisher.work` counts completed worker attempts and sums elapsed
  milliseconds by operation, index mode and outcome. These come from the
  production `[:serviceradar, :topology, :bitmap_index, :work]` event and
  remain observable during backfill and seed, when snapshots are unavailable.
  Elapsed time includes worker execution and owner delivery delay, excludes
  scheduled idle time, and is not database CPU time. Contention, failure,
  capacity deferral, timeout and cancellation are not successful publication.
- `publisher.hint_overflow` counts refused hint attempts by memory or payload byte
  limit, using `[:serviceradar, :topology, :bitmap_index, :hint_overflow]`.
  Events include the configured bound and reconciliation outcome, never device
  identities. Repeated refused IDs can be counted more than once. The meter
  survives index restarts and reports detached handlers as uninstrumented.
- Ready snapshot samples split `pending_dirty` into `pending_hints`,
  `pending_native` and `pending_publish`, and include `pending_hint_bytes`
  and the conservative `pending_hint_retained_bytes` admission charge.
  `pending_native_bytes`, `pending_native_serialized_bytes` and
  `pending_native_rescan_generation` come from native index status; a
  generation increase on a hinted replica means hints were folded into a
  rescan rather than refused.
  These are queue entries, not a distinct-device count: a device can be present
  in more than one stage. The active hint-resolution batch remains counted
  and charged until successful resolution. `pending_hint_age_ms` includes
  that batch; `pending_publish_age_ms` dates the held publication batch from
  ordinal dequeue. Native Roaring does not store per-ordinal age, so neither
  metric is the oldest work across the entire pipeline or a commit clock.
  A high sample just after a write burst does not establish sustained
  lag or overflow; use overflow events and work timings to investigate it.

Task 4.2 remains open. The next performance comparison must retain the same
five-second write cadence, separate hinted updates from reconciliation and
restart recovery, and run both compact and sparse distributions.

The new `commit_probe` records (collected in `commit_probes`) sample the first committed batch every tenth
tick on the hinted replica without blocking the write cadence. It brackets
commit between statement submission and successful database acknowledgement
on the driver's monotonic clock. An authorized query must return the specific
device's expected ordinal at its newly assigned /128 address and unavailable
state; a growing total cannot conceal its missed update. Query observation
includes the rest of that tick's write burst and 500-ms polling.

All normal viewers of the hinted replica must then have accepted a frame
with the same index epoch and a revision at least as new as that query.
This implication uses the fixture's monotonic, one-write-per-device membership
and the fact that this replica never restarts. Wire time uses accepted-frame
timestamps on the driver's clock. It is an all-viewer observation bound,
not first-frame latency or browser/GPU evidence. Slow viewers and the
deliberately unhinted/restarted replica retain their separate recovery checks.
Both observations must fit 60 seconds from commit acknowledgement. Report
elapsed time from both acknowledgement and statement submission; the actual
database commit falls between those origins. These ten probes do not measure
every device's freshness.
The hinted peer must refuse no hints during this workload and must publish
ready scan pages while churn runs; a faster visible result cannot hide inbox
overflow or removal of reconciliation service. Native pending overflow is a
second loss path that refuses nothing: past 512 KiB serialized the Roaring
dirty set is cleared and its rescan generation advances. After final
convergence, and before the oversized-facet mutation, the hinted peer's
hinted, native and publication work must drain within 60 seconds while it
keeps the index epoch and rescan generation it had before churn. The
unhinted peer restarts and misses hints by design, so it is not held to this.

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
The UID inbox adds at most 3,670,016 charged bytes, bringing those steady
component limits to 199,973,184 bytes before the small fixed owner metadata.
Its per-entry charge includes 256 bytes of queue/set/batch overhead plus
word-rounded owned payload; executable coverage compares the charge with
the VM's conservative live-term size. GC high-water and mailbox/worker copies
remain part of whole-process RSS.

Publish both successful and rejected counts. Do not describe a target that
only compiled, a native microbenchmark, or this Gun server workload as a full
browser or deployed-backend acceptance result. Physical GPU and browser
retention remain separate evidence in
[the GPU acceptance report](topology-bitmap-gpu-acceptance.md).
