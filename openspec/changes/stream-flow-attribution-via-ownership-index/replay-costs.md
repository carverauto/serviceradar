# Synthetic ownership replay costs

This investigation follows the failed preliminary replay gates in
[PR #5958](https://github.com/carverauto/serviceradar/pull/5958). It
separates allocation costs from replay phases before selecting further work.
Tasks 0.2 and 0.3 remain open: the complete representative shard must still fit
200 bytes/key and replay two hours at 2.5M keys within 120 seconds.

## Fixed experiment and comparison rules

Protocol 2 keeps the original corpus, owner context, history distributions,
500-event JSON messages, eight-message pulls, file-backed NATS 2.14 broker and
four BEAM schedulers. Every numbered message, event count, final acknowledgement,
current and historical owner, duplicate/stale closure and expiry boundary still
has to pass. Capacity verdicts remain separate from ExUnit correctness.

The new counters split replay wall time into pull submission, message wait, JSON
decode, event application, acknowledgement submission and the remaining work.
Application includes base64 decoding, owner serialization/interning, interval
updates and event accounting. These are elapsed spans in the consumer process,
not CPU samples; scheduling and GC can affect every phase. Other work includes
setup, final acknowledgement settlement and instrumentation between spans.

Memory reports each ETS table, VM binary growth before and after verification,
known off-heap payload, and logical/referenced key/history byte sums. The existing
verdict still uses ETS memory plus the larger of post-verification VM binary
growth and known off-heap payload. Snapshots follow GC of the test process only.
Referenced-byte sums are diagnostics, not allocation totals: shared backing can
be counted repeatedly, and these sums do not include allocator/object overhead.
[The Erlang binary API](https://www.erlang.org/docs/28/apps/stdlib/binary.html#referenced_byte_size/1)
defines the underlying-binary measurement.

`OWNERSHIP_REPLAY_COPY` selects `none` (default), `key`, or `history`. The latter
two call `:binary.copy/1` on the decoded key or updated history before ETS insert.
Both preserve bytes. They are benchmark experiments, not production choices.
The key path otherwise retains the result of
[Elixir 1.19.4 base64 decoding](https://github.com/elixir-lang/elixir/blob/v1.19.4/lib/elixir/lib/base.ex#L821-L884).
The instrumentation and copy-mode dispatch change the measurement protocol;
protocol 2 timings must not be presented as a speedup over uninstrumented #5958.

Run one attempt per setting, sequentially on shared RBE, without a dedicated CPU
reservation. First compare 100,000 single-history keys. Promote an allocation
candidate only when unchanged reconstruction passes and memory components explain
its direction. Confirm at 2.5M keys, then probe the untouched mixed/reuse profiles.
Report slower and null attempts; do not choose favorable reruns. Timeout is 1,800
seconds with one attempt. Seed/publish, broker restart and final verification are
outside replay timing. No live data or deployment is involved.

## Hypotheses and parameter effects

| Hypothesis / factor | Discriminating result | Outcome |
| --- | --- | --- |
| Stored decoded-key representation contributes to the memory gap | Key-only copy reduces ETS/binary memory with identical bytes and reconstruction | About 107 bytes/key lower at 100k and 105 bytes/key lower at 2.5M; confirmed for the single-history corpus |
| Incremental histories account for the gap | History-only copy reduces the corresponding memory components | ETS and referenced bytes unchanged at 100k; small VM variation is inconclusive, so no combined-copy trial |
| Consumer pull/wait dominates elapsed replay | Pull/wait exceeds decode/application elapsed spans | Decode takes about 62-69% at 100k and 60-68% at scale; pull/wait spans are smaller, without attributing background transport CPU |
| Final verification accounts for the memory gap | Binary growth falls materially between the two snapshots | Less than 0.4 MB difference at 100k, insufficient to explain the roughly 11 MB key-copy delta |

The key-copy observation identifies an allocation effect in this pinned toolchain.
Logical and referenced byte totals are equal with and without copying: it is not
evidence of an oversized parent payload being retained. Exact VM representation
and allocator attribution remain unmeasured. History-only copying is retained as
a reproducible negative comparison, not an optimization recommendation.

## Attempt ledger

All attempts below use source SHA-256
`7dcbd26ec70c5b7a2af5678b17cffa162582acfd1f797cfee311f4b30a536001`.
They use the Bazel dependencies at base commit `88c5a32479`: OTP 28.1, Elixir
1.19.4, Gnat 1.18.0, Jason 1.4.5 and NATS 2.14.0 on Linux amd64.
Counts and payload bytes match across settings for the same profile and key count.
Every completed attempt passed reconstruction. Figures here are rounded;
the linked BuildBuddy output contains the synthetic raw measurements.

| Keys / profile | Copy | Replay | Memory floor/key | Key ETS | VM binary growth after verification | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| 100k / single | none | 6.5 s | 278 B | 17.6 MB | 9.9 MB | [baseline](https://carverauto.buildbuddy.io/invocation/f6f6e8d0-2976-4e89-82f4-25af8ad66eb9) |
| 100k / single | history | 6.8 s | 271 B | 17.6 MB | 9.2 MB | [history copy](https://carverauto.buildbuddy.io/invocation/f5d148b3-dea0-4a2e-9c32-4bf0efea1b0f) |
| 100k / single | key | 8.2 s | 170 B | 15.6 MB | 1.2 MB | [key copy](https://carverauto.buildbuddy.io/invocation/76975385-67eb-497b-89c7-0488a7ef0e43) |
| 2.5M / single | none | 162 s | 270 B | 440 MB | 229 MB | [scale baseline](https://carverauto.buildbuddy.io/invocation/433ade79-a04b-460f-b089-0304cdf967da) |
| 2.5M / single | key | 152 s | 164 B | 391 MB | 14 MB | [scale key copy](https://carverauto.buildbuddy.io/invocation/eed8789e-3ff8-42a7-8c90-98f1cc9c30a0) |
| 2.5M / mixed | key | 239 s | 194 B | 395 MB | 86 MB | [mixed scale](https://carverauto.buildbuddy.io/invocation/51436ecc-dedc-41c5-a78d-1f8888d1638e) |
| 2.5M / reuse | key | 432 s | 270 B | 403 MB | 267 MB | [heavy-reuse scale](https://carverauto.buildbuddy.io/invocation/67d44f61-04bc-4ef7-b3f3-b394e85ba5ee) |

Each 100k corpus contains 500,006 events in 1,001 messages and about 363 MB of
JSON. Owner tables are unchanged at about 0.11 MB each. Key-copy reduced key ETS
by about 2 MB and VM binary growth by about 9 MB. Its elapsed time increased;
this experiment has not established a replay speed improvement.

The instrumented 2.5M-key baseline passed reconstruction but exceeded replay by
about 42 seconds and memory by about 70 bytes/key. JSON decode took about 110 s
(68%), application 38 s (23%), message wait 11 s (7%), and all remaining spans
about 2 s. Both owner tables were about 2.5 MB each; verification changed binary
growth by less than 0.1 MB. Seeding about 9 GB took 277 s outside the replay timer.

At 2.5M keys, copying keys reduced key ETS by 49 MB and binary growth by 214 MB,
about 264 MB combined. Key/history bytes and owner table sizes stayed equal.
The memory floor was below 200 bytes/key, but replay still exceeded 120 s by
about 32 s. Decode took about 95 s (62%), application 34 s (23%) and wait 21 s
(14%). This single shared-RBE attempt is not a causal speedup claim: the small
key-copy attempt was slower, and seeding also varied substantially across runs.

The mixed profile also passed reconstruction, with only about 6 bytes/key below
the memory target before missing shard costs. Replay exceeded the target by
about 119 s: decode took 160 s (67%), application 63 s (26%) and wait 14 s (6%).
Its 15.2M events occupied about 11 GB of JSON; seeding took 333 s outside replay.

Heavy reuse passed reconstruction but exceeded memory by about 70 bytes/key and
replay by 312 s. Decode took about 258 s (60%), application 149 s (35%) and wait
18 s (4%). Its 23.3M events occupied about 17 GB of JSON, seeded in 490 s outside
replay. The history bytes alone grew to 264 MB. All three key-copy scale runs
still exceeded the replay target; two passing memory floors do not close the
complete-shard gate.

The seven attempts used about 40 minutes of remote ExUnit execution, including
generation, seeding, restart and verification, and about 48 GB of synthetic JSON
published across disposable brokers. No failed or retried experiment is omitted.
Formatting, repository validation and CI are separate from this research cost.

## Reproduction and remaining work

Use the existing target with a selected profile, key count and copy mode:

```sh
bazel test -c opt --config=remote \
  //elixir/serviceradar_core:ownership_replay_spike_single_test \
  --test_env=OWNERSHIP_REPLAY_KEYS=100000 \
  --test_env=OWNERSHIP_REPLAY_COPY=none \
  --test_output=all --test_timeout=1800 --flaky_test_attempts=1 \
  --nocache_test_results
```

Replace `single` with `mixed` or `reuse`, the key count with `2500000`, and copy
with `key` or `history` as needed. Default 2,500-key runs check correctness only.
Run comparison settings sequentially; a three-target invocation adds contention.

Ordinary CI also runs `ownership_replay_spike_mixed_copy_key_test` and
`ownership_replay_spike_mixed_copy_history_test` at the small default size. Their
fixed copy modes preserve coverage of the opt-in branches, with depths 1, 4 and 32
and the same close/expiry controls. No separate test file or production seam is
needed.

The allocation question is resolved for this bounded experiment: key-copy is the
best measured memory setting, and history-copy showed no structural improvement
in the single-history comparison. The next useful timing experiment should keep
the corpus and reconstruction checks fixed and compare an agreed event encoding
against the JSON baseline. Decode dominates every measured profile; this is a
reason to measure that boundary, not a production encoding decision.

No result here includes the missing expiry, snapshot, address-presence, placement,
enrichment, notification, budget, concurrency or replay-to-live shard behavior.
No production storage or wire decision is selected, and the original gates remain.
