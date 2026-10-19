# ServiceRadar Atlas scalar diversity measurements

## Scope and reproduction

This native-only experiment fixes population at 100,000 synthetic devices and
varies stored value diversity independently of a two-predicate query. It does
not establish hosted database convergence, million-device high-diversity
capacity, browser latency or end-to-end zero copy.

```sh
bazel test -c opt --config=remote \
  //elixir/web-ng/native/god_view_nif:god_view_nif_test \
  //elixir/web-ng/native/god_view_nif:bitmap_diversity_benchmark \
  --test_output=all --flaky_test_attempts=1
```

The seed is `synthetic-arithmetic-v1`: one or five invented tag fields, cyclic
values, and unavailable devices at multiples of eleven. Compact ordinals are
`n + 1`; scattered ordinals are `rotate_left(n, 16) + 1`, spreading the first
65,536 devices across 65,536 Roaring containers. Population and user predicate
count stay fixed. A separate prefix selects values starting with `g00`, up to
1,000 distinct values. Each case measures 10 warmups and 100 samples, publishes
500 devices per batch, toggles availability on 1,000 devices while eight queries
retain the preceding revision, and verifies independently calculated membership,
unsigned pages and unchanged pinned results. Every case must finish publication
and both query forms; a resource rejection cannot make the benchmark pass by
skipping the case. Samples are measurement points, not admission ceilings.

## Before the correction

[Baseline invocation](https://carverauto.buildbuddy.io/invocation/abc3a20a-de46-4cd3-a01c-d302e36e73ad)
ran the old native code from commit
`36bd3febd93790202df473c99f20e44f1e6751ce` with the new diversity fixture.
Its native subtree was `8e0b653b334fdcf2f94f0155d37bb9780f1d593b`.
It failed ten distributions because the 1,024-per-field or 4,096-total group
caps marked fields unavailable. Five fields with 900 values also disabled
availability, even though five fields with 800 values retained only 4,451,774
accounted bytes for compact ordinals. The scattered five-by-800 case hit the
real transient limit after 97,500 devices: 84,024,666 current and 159,872,378
peak accounted bytes. This distinguishes arbitrary group rejection from actual
resource pressure. That baseline used a Xeon Gold 6258R at 2.70 GHz.

After removing the group caps and correcting reservations, all sixteen cases
published, but repeated prefix unions still exceeded the one-second deadline.
That intermediate measurement is in
[invocation ce85177a](https://carverauto.buildbuddy.io/invocation/ce85177a-bc0d-48c4-923d-7b524a846df5),
with its cached output recovered in
[invocation dcb872cf](https://carverauto.buildbuddy.io/invocation/dcb872cf-8652-4e8d-909a-6ad668134384).
The native suite in that intermediate invocation also exposed one obsolete test
expectation that diverse vendors become unavailable; it is not a clean suite pass.

## Corrected index and balanced prefix unions

[Invocation a2bd3b81](https://carverauto.buildbuddy.io/invocation/a2bd3b81-bd66-44dd-a03c-14dc8fa1d088)
executed both targets remotely, with 38 native tests and all sixteen benchmark
cases passing. Hardware was a Xeon Platinum 8358P at 2.60 GHz, 30 available
threads and 176,545,000 KiB host memory. Bazel used optimized Rust builds; this
was an executed test, not a cached timing. The benchmark finished in 123.86 s.
The intermediate prefix run used the same reported CPU model, but these are
shared executors, not controlled comparative CPU experiments.

Times below are milliseconds. Memory is accounted index-owned bytes after
seeding, not RSS. Each row includes 100,000 devices and two availability groups
in addition to the listed tag groups.

| Ordinals | Fields x values | Seed ms | 500-row publish p95 | Exact query p95 | Prefix query p95 | Accounted bytes | 1% churn ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Compact | 1 x 512 | 294 | 1.489 | 0.0122 | 1.922 | 791582 | 2.741 |
| Compact | 1 x 1024 | 348 | 1.702 | 0.0100 | 2.112 | 1095198 | 4.847 |
| Compact | 1 x 4096 | 843 | 4.477 | 0.0115 | 1.540 | 2916894 | 16.857 |
| Compact | 1 x 16384 | 3742 | 23.574 | 0.0091 | 0.556 | 10203678 | 70.320 |
| Compact | 1 x 65536 | 10129 | 77.897 | 0.0038 | 0.408 | 35373598 | 263.253 |
| Compact | 5 x 800 | 1566 | 8.425 | 0.0137 | 2.821 | 4459966 | 17.041 |
| Compact | 5 x 900 | 1639 | 8.929 | 0.0112 | 2.021 | 4756466 | 19.344 |
| Compact | 5 x 4096 | 6636 | 35.354 | 0.0064 | 0.842 | 14232606 | 95.860 |
| Scattered | 1 x 512 | 2527 | 18.408 | 0.7279 | 41.990 | 27374250 | 19.268 |
| Scattered | 1 x 1024 | 2433 | 18.588 | 0.7293 | 49.408 | 27546794 | 21.693 |
| Scattered | 1 x 4096 | 3546 | 24.490 | 0.8919 | 13.642 | 28582058 | 34.364 |
| Scattered | 1 x 16384 | 8335 | 74.557 | 0.5291 | 5.762 | 32723114 | 85.489 |
| Scattered | 1 x 65536 | 19540 | 158.878 | 0.6197 | 2.654 | 49287338 | 291.771 |
| Scattered | 5 x 800 | 6699 | 48.774 | 0.8285 | 68.821 | 85761098 | 39.790 |
| Scattered | 5 x 900 | 6901 | 49.182 | 0.8505 | 73.420 | 85929598 | 43.071 |
| Scattered | 5 x 4096 | 15428 | 105.250 | 0.8559 | 47.036 | 69257898 | 129.346 |

Representative p50/p95/p99 triplets in milliseconds:

| Case | Exact query | Prefix query | 500-row publication |
| --- | --- | --- | --- |
| Compact 1 x 65536 | 0.0021 / 0.0038 / 0.0080 | 0.317 / 0.408 / 0.477 | 52.182 / 77.897 / 90.358 |
| Scattered 1 x 65536 | 0.273 / 0.620 / 0.628 | 1.438 / 2.654 / 2.892 | 97.599 / 158.878 / 172.627 |
| Scattered 5 x 900 | 0.741 / 0.850 / 1.140 | 66.513 / 73.420 / 105.682 | 32.314 / 49.182 / 55.662 |

Full per-case triplets, peak accounting and RSS/HWM samples are in the invocation
output. The largest accounted peak was 157,832,177 bytes (scattered five-by-800),
close to the unchanged 160,000,000-byte total cap. Scattered five-by-900 retained
106,166,212 bytes with eight pins, returning to 86,012,646 after closing them.
The final process HWM sample was 88,384 KiB. RSS/HWM include allocator retention
and the benchmark process, and are sampled separately from conservative native
reservations; they are not substitutes for each other.

## Interpretation and remaining acceptance

The measured representation fits these cases without a packed-postings rewrite
or facet eviction. Exact queries stay inexpensive as distinct values increase.
Publication still visits the complete value directory per batch; 65,536 scattered
values reached 158.878 ms p95 per 500 rows. Prefix cost depends on matching
postings and ordinal distribution, not just predicate count. Balanced unions
remove the repeated growing-result copies while keeping all allocation and
deadline checks. Oversized scalar values remain explicitly unavailable.

The 125,000,000-byte steady cap, 160,000,000-byte total cap, one-second native
deadline, 500-row batch, eight pins and eight readers are unchanged. These
measurements do not imply arbitrary diversity fits them. The native suite proves
atomic rejection and recovery after pressure is removed. The BEAM publisher's
progress when a blocked page precedes reclaimable deletions remains an acceptance
gap; a last-good revision must report stale progress, and restart is not proof of
automatic recovery. Hosted compact/sparse database workloads remain required.

The prior 1.1-million-device scalar experiment had only 73 groups and used a
different sparse distribution. Its
[invocation 08faa7d6](https://carverauto.buildbuddy.io/invocation/08faa7d6-c6a0-4bdd-9fda-b7be21ce662c)
is complementary population evidence, not high-diversity or current-head proof.

## Measured source provenance

The final invocation used commit `36bd3febd93790202df473c99f20e44f1e6751ce`
plus the native edits identified below. Paths are relative to
`elixir/web-ng/native/god_view_nif/`; these SHA-256 values bind every benchmark
source and its target declaration without attributing measurements to a later
unmeasured commit.

| Input | SHA-256 |
| --- | --- |
| `BUILD.bazel` | `e55b2bf26aa986cdabe92cf113d75bf028713cff9a2d4269d80174f03c306a8b` |
| `fixtures/bitmap_benchmark.rs` | `163f493d17afc81985645fc6c92e6cb21647ee31b80535c858f9d286ed649463` |
| `fixtures/bitmap_fixture.rs` | `605a1bfea03b7e32c45099646a5b172bf43f778e9f4fb8665a8e0ede813a7c6d` |
| `src/bitmap_index.rs` | `4d0a857b18f9d635279933172fd04d3871d24f8ff1b95e5708c007cdcbc2f3cf` |
| `src/bitmap_facets.rs` | `7dd0fbee1e356a4068d07dd65e2941429d1d6fa7b031b118b1948fbe9cdd896e` |
| `src/bitmap_addresses.rs` | `e429c226f01b829fd199010d92e80f0e42562beb094c0f5c36c76228d71db5fa` |
| `src/bitmap_pending.rs` | `45bb616cd3a68b147d101fb2e1cbc7c8f6af1c965e67d0e7119faf36c426cf92` |
| `src/bitmap_staging.rs` | `3d985a8b8153eb7325da3be487ab41dd7fc031c2b0b537f4999de9e63994ca36` |
