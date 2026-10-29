# Bounded exposure reconciliation audit

Status: approved for a disabled prototype on 2026-10-28. Prototype source is
implemented in the manual harness. The approved small-profile run passed its
implemented controls but failed the fact-comparison screen; the measured
orchestration time also exceeded its budget. See [prototype.md](prototype.md).
A later explicit approval permits one bounded small-profile diagnostic follow-up;
the fleet gate remains open. The follow-up batches sorted session-lock calls,
separates phase timings and captures source/coverage plans after measurement.
It removes repeat execution, preserves every budget and codec, and makes no
plan-dependent SQL optimization before actual evidence. See the pending
execution status in [prototype.md](prototype.md#approved-bounded-diagnostic-follow-up-not-yet-executed).

## Evidence and objective

The existing worker compares each device independently. It reads referenced
dimensions, decodes current and retained assessment after-images, hashes facts,
reads warehouse facts, records the result and evaluates readiness. The same
dimension is decoded and compared again for other devices.

The completed synthetic Decision 27 experiment measured 105, 64 and 69 seconds
for cohorts of 1, 8 and 32 devices respectively. Its best case was roughly
7,800 active facts/second, short of the fleet floor of roughly 55,600. The
32-device case still verified about 338,000 dimension rows for a fixture with
about 53,000 distinct dimensions. All tested controls passed; no fleet run or
production adoption followed. See the [report and provenance](https://agentboard.farm01.carverauto.dev/documents/220).

Source and dimension timings overlapped across two workers, so their sums are
not elapsed time. That candidate also did not exercise the complete production
orchestration/readiness path. Neither subtracting its dimension time nor
linearly extrapolating a small fixture establishes capacity.

The goal remains a fully verified daily reconciliation of 20,000 hosts and
50 million active facts within 900 seconds. Parent task 1.6 stays open until
the actual fleet gate passes. Snapshot publication and terminal maintenance
have separate gates; this proposal does not change them.

## Approved design decisions

### 1. One finite audit run, bounded cohorts, existing repair ownership

Create an audit run with a unique ID, format version, start time, 900-second
deadline, recovery fence and resumable enumeration cursor. Enumerate the same
union of source ordinals, prior checks, warehouse facts and lifecycle ordinals.
Commit each bounded enumeration checkpoint with its admitted work. A cohort
contains at most 32 device ordinals; at most two audit workers run concurrently.
Dimension, comparison and readiness work share that same two-worker budget.
Use the existing device advisory-lock namespace and acquire locks in ordinal
order. A busy device is deferred, not treated as empty or silently omitted.

Each cohort opens a finite repeatable-read source view V. Keep 30-second
statement timeouts, a 60-second total source-view deadline and pages/evidence
bounded at 500 rows. The cohort returns at most one summary per device plus a
bounded exception page. A timeout aborts that cohort's comparison. Oversized
cohorts may split deterministically; a single oversized device is deferred and
reported. Partial digests never become matched results.

The run records completion only after enumeration is exhausted and every
admitted device has a qualifying comparison. A crash after enumeration cannot
lose work; a crash after comparison but before commit repeats the comparison.
Expired runs stop admitting work and cannot mint new successful results.
Unresolved repair obligations survive run expiry in the existing durable
repair records. No new repair executor or snapshot finalizer is introduced.

### 2. Verify shared dimensions once per exact source content version

Audit the published dimension-state catalog in bounded pages. A page's finite
source view supplies the source payload; the verifier decodes it through the
existing dimension decoder and compares the actual StarRocks row using the
existing `ExposureSnapshotWarehouse.row_digest/2` contract. A successful proof
contains `(run_id, recovery_fence, kind, ordinal, source_seq,
source_content_hash, checked_at, source_view, warehouse_row_digest)`.
Before issuing a proof, require the decoded payload kind, ordinal and sequence
to agree with the dimension-state row that supplied it.

The source content hash is a version binding, not a replacement for warehouse
comparison. Add a **stored generated** hash of the dimension state's own JSONB
payload, provisionally `sha256(jsonb_send(payload))`. It is recalculated by
PostgreSQL on writes; an equal-sequence payload edit therefore cannot reuse an
old proof. It hashes only a same-row immutable value: no joins, cached current
assessment hashes, trigger-maintained cache or falsely immutable lookup UDF.

PostgreSQL documents that stored generated values are computed on writes and
generation expressions must be immutable and row-local. Its PostgreSQL 18
catalog declares `jsonb_send` and `sha256` with the immutable default. These
support the candidate expression, but the prototype must still verify it on
the supported database image. This is a versioned source-local identity;
PostgreSQL major/serialization changes invalidate all audit proofs and require
recomputing the column before audit enablement. It is not a cross-engine wire
format. Sources: [generated columns](https://www.postgresql.org/docs/18/ddl-generated-columns.html),
[function catalog](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/include/catalog/pg_proc.dat),
[catalog defaults](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/include/catalog/pg_proc.h).

The cohort's source query joins its required dimension references to source
state and proofs visible in V. Coverage includes retained assessment
publications and deletion watermarks, including terminal rows and old package
versions. Missing source dictionaries, malformed references, missing proofs,
failed proofs or a content/sequence mismatch defer affected devices. Do not
materialize a fleet-sized device/dimension edge table. Aggregate coverage while
scanning the necessary source rows; return only bounded failure keys.

A newly observed version schedules one deduplicated proof request. It cannot
become visible inside an already-open V: retry the affected cohort in a new
bounded view after verification. Unrelated cohorts continue. Existing versions
retain their proof for this run; continuously changing dimensions can defer
their dependent devices and cause a failed run, never a false match. Publish
proofs only after the actual warehouse read and source-view validation finish.

**This explicitly changes the experiment's prohibition on cross-view reuse.**
The binding is exact source content plus the audit run and recovery fence, not
sequence alone, wall-clock recency alone or a process-wide cache. No proof is
reused in another audit run.

Freshness is the oldest evidence used: preserve `dimension_checked_at` per
device as the minimum of its proofs, alongside `fact_started_at` and
`comparison_finished_at`. Readiness uses the oldest relevant time, including
the requirement that evidence follow the covering recovery generation. A
later fact comparison does not refresh an older dimension check. A new covering
snapshot can therefore require fresh dimension proofs even in the same run.

This is a bounded observational audit, not an atomic CNPG/StarRocks snapshot.
An out-of-band warehouse edit after its dimension was checked is detected by
a later audit, as an edit after an existing per-device check is today. Expose
the evidence times; do not describe the warehouse as verified at the later
completion instant. A source edit in the cohort's V invalidates a mismatched
proof even when its transition sequence did not change.

### 3. One current-fact hash; independently validate retained replay

In V, project typed current attributes directly from assessments, ordinals and
the current package-version dictionary. Retain the existing eligibility and
lifecycle rules. Validate retained publication structure, schema version,
required fields, ordinals, types and timestamps against the existing decoder
contract before normalization. Invalid inputs fail the affected comparison;
SQL casts, defaults or filtered rows must not turn them into success.

For an active current row, compare the normalized current tuple to its retained
publication field by field, then calculate `exposure-fact/v1` once. The tuple is
`device_ord, cve_ord, pkg_ord, transition_seq, device_lifecycle_seq, pkgver_ord,
state, severity_rank, cvss_score, kev, exploit_available, fix_available,
source_scope`. An active/non-active disagreement is a mismatch. Two valid
non-active rows keep the existing zero-contribution digest semantics; terminal
payload/marker verification remains owned by snapshot/retention contracts.
Do not silently broaden that contract to equality of compacted terminal rows.

Use explicit normalization for NULL, booleans/0/1, binary64 CVSS, signed zero,
signed integers and UTF-8. Equality must correspond to the existing digest's
typed values; generic JSON text equality is insufficient. No digest format,
field order, SHA-256 algorithm or modular sum change is proposed. The existing
Elixir implementation is the differential oracle, not a second tuning target.

Group count and sum modulo 2^256 by device in CNPG. StarRocks independently
computes the same digest from **actual stored columns**, not an ingestion-time
hash. Include every requested device in the result, even when either side has
zero active rows. Preserve duplicate multiplicity, source/warehouse-only keys,
lifecycle checks and independent current-versus-retained drift detection.

On mismatch, persist the existing per-device mismatch/generation floor and
invoke bounded key localization. Only fixed durable repair targets can clear
obligations. Changed content obtains a new sequence under the existing source
lock and travels through JetStream. A higher warehouse sequence clears a
repair only when the existing current-source verification proves it valid.

### 4. Batch readiness evaluation; never cache a ready verdict

Record per-device comparison results transactionally, then evaluate readiness
for up to 32 devices in one fresh bounded source view. Share identical global
subqueries and group scoped predicates by device/bucket. Preserve every
existing reason: covering snapshot and generation floor, daily comparison age,
enumeration coverage, source preparation, lifecycle/dimension coverage,
delivery journals, pending snapshot pages, repairs from any generation and
ten-minute outbox age. Normal young outbox traffic does not block completion.

This batches computation, not authority. Retain each device's distinct result
and reasons; one matched device cannot clear another's pending repair. Unknown
warehouse ordinals keep conservative journal scope. The public status query
still reads current recovery state; no cached `ready=true` flag serves it.
Fleet readiness requires complete admitted coverage and unexpired evidence.
Measure readiness costs even when a comparison is deferred or mismatched.

### 5. Fence recovery and bound control metadata

Use a persisted monotonically increasing audit recovery fence. Entering a
warehouse restore/rebuild or changing audit formats increments it and
invalidates active runs before warehouse mutation. Result/proof publication
locks and rechecks the fence, run deadline and relevant generation floor in
the commit transaction; an old worker cannot publish into a new recovery.
All restore entry points must participate before prototype adoption. An
unannounced external restore has no magical detection guarantee: daily audit
and existing recovery signals remain responsible for discovering divergence.

Audit runs and dimension proofs are Ash-backed CNPG **control metadata**.
They store identities, digests, cursors, evidence times and statuses, not copies
of exposure facts or dimension payloads. Index proof lookup by run/kind/key/
content/version and work by run/status/cursor. Keep process memory bounded by
pages and cohort width. Report database proof rows/bytes and versions per key;
run duration bounds churn, and repeated failures end the run.

Retain at most the active and latest completed run's reusable proof set. Remove
expired superseded proof pages in bounded transactions after their consumers
finish. Durable per-device checks copy their evidence times and digests, so
cleanup cannot upgrade freshness or erase repair obligations. Restore and
rollback invalidate proofs rather than making them authoritative again.

## Capacity budget and stop rules

The following are proposed allocation targets, **not measured results**. They
sum to the unchanged 900-second fleet gate. Charge actual critical-path elapsed
work once; also report inclusive phase CPU/wall time without adding overlapping
worker times as if they were elapsed time.

| Work | Fleet allocation | Early falsification check |
| --- | ---: | --- |
| Distinct dimension versions, including required rechecks | 120 s | Measure the entire catalog and live-change rechecks; count distinct versions and repeated verification |
| Current/replay validation plus CNPG and warehouse fact summaries | 600 s | 500,000 active facts at two workers must take at most 6 s; roughly 83,300 facts/s is the component target |
| Enumeration, admission, lifecycle, persistence, readiness and cleanup | 90 s | 200 devices must cost at most 0.9 s of equivalent linear work; measure fixed overhead separately |
| Retries and scheduling reserve | 90 s | Report actual retries/queue delay; do not spend reserve to conceal a failed component screen |

The former 9-second whole-smoke screen assumed all costs scaled with facts.
This proposal replaces that **early screen only** with distinct fixed/dimension
and linear components. It does not relax fleet completion. A catalog-heavy
smoke cannot prove fleet capacity, and a favorable warm cache is not a pass.

First build a disabled prototype with these counters. After separate run
authorization, use the existing synthetic fixture lifecycle and declared
capacity profile. Include cold and warm runs, distinct/version-heavy catalogs,
skewed devices, terminal references, normal live traffic and error paths.
Keep fixture construction outside the audit timer but include all audit
admission, recovery verification, readiness and cleanup. Report terminal and
catalog cardinalities with the active count. Connection usage, database CPU,
rows scanned and client memory must be captured; sampled process memory is
not peak RSS. A single favorable invocation establishes neither p95 nor fleet
capacity.

If either linear screen fails, stop before 50 million rows. Permit a correction
only for a demonstrated query-plan or implementation defect; do not start
another codec/cohort sweep or raise concurrency to disguise the miss. A passed
screen permits a fleet-run request, not the run itself. Actual fleet success
must include correctness controls and complete cleanup. Gate ownership stays
with the parent exposure change.

## Required correctness controls

| Control | Required result |
| --- | --- |
| Same-count fact corruption, missing row, warehouse-only row, empty device | Mismatch or truthful empty match; never omitted scope |
| Equal-sequence dimension content edit after proof | New content hash prevents reuse; affected scope deferred/repaired |
| New/higher dimension version and old package version referenced only by a terminal record | Exact visible version proof required; no active-only coverage shortcut |
| Edit before dimension check versus edit after it | First detected in this audit; second retains old evidence time and is detected by a later audit |
| Current assessment drifts from replay; malformed replay; missing dictionary | Failure/mismatch survives SQL aggregation and produces bounded evidence |
| Live fact changes before and after snapshot completion, including visible 40/resolved 41 | Existing visibility and higher-sequence rules win; no quiescence requirement |
| Proof arrives after V; view/statement timeout; worker dies between scan and commit | Fresh bounded retry; no partial success |
| Restore or newer covering snapshot between proof and result commit | Fence/generation recheck rejects stale evidence |
| Young ordinary outbox vs pending recovery/old outbox | Young traffic allowed; actual recovery and staleness still block |
| One failed device in a cohort; duplicate jobs; restart after cursor commit | Other scopes keep distinct outcomes; no lost coverage or double repair assignment |
| Cleanup/rollback with outstanding repairs | Reusable proofs expire; obligations and permanent markers survive |

Use existing decoder/digest tests as the oracle and extend the owning DB
integration/capacity suites. Test selection and fixture cleanup must follow
the repository test-audit and hosted-build rules. SQL equivalence, end-to-end
JetStream delivery and snapshot finalization are separate claims; synthetic
after-image comparisons alone cannot prove live delivery.

## Migration, rollout and alternatives

Prototype schema changes run only in its synthetic scratch database. Production
migration planning follows only after evidence supports adoption: generated
column backfill/lock cost, Ash metadata/resources, indexes, restore hooks and
retention cleanup all need measured validation. No warehouse grants widen.
Deployment code defaults to the existing reconciler until a separately reviewed
adoption change enables this path. Rollback fences new runs and returns to the
old worker while retaining per-device recovery state; throughput may again miss
the gate and must be reported.

Rejected for this experiment: more workers or larger unbounded cohorts; cached
fact hashes that hide current/replay drift; sequence-only dimension caches;
changing SHA-256/typed encoding again; dropping terminal references; treating
the snapshot relay as proof that warehouse content matches. These either avoid
the measured work without proving correctness, or repeat the failed approach.

The main uncertainty is whether one current hash plus normalized validation is
fast enough even after shared dimensions are removed. The failed experiment's
source cost gives no assurance it is. The small-screen stop rules make that
uncertainty cheap to resolve before another fleet attempt.

## Repository evidence

All paths below are under `elixir/serviceradar_core/lib/serviceradar/`:

- `inventory/exposure_reconciliation_comparison.ex`: independent current/replay,
  dimensions, lifecycle and warehouse comparisons in V.
- `inventory/exposure_reconciliation_digest.ex`: typed v1 count and modular sum.
- `inventory/exposure_reconciliation_worker.ex`: union enumeration, durable
  per-device mismatch state, sequenced repair and readiness after comparison.
- `inventory/exposure_readiness.ex`: current recovery predicates and freshness.
- `inventory/exposure_snapshot_worker.ex`: prerequisite and retained-reference coverage.
- `event_writer/exposure_snapshot_warehouse.ex`: normalized row comparisons and
  higher-sequence/visibility rules.
- `event_writer/processors/exposure_transitions.ex`: validation and conversion
  contract for retained after-images.
