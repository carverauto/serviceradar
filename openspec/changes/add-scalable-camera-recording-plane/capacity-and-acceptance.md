# Capacity model and qualification

All figures below are independently invented test targets and arithmetic
examples. They are not captured fleet data, measured capacity or product claims.
Use decimal bytes in these examples; rendered provisioning quantities must state
whether they use decimal or binary units.

## Separate the budgets

Let `R` be aggregate admitted peak encoded bytes/second, `W` the promised upload
outage seconds, `H` the measured filesystem/fragment headroom factor, `P` bounded
partial/in-flight bytes, `C` optional cache, and `M` reserved journal/control space.

- S3-mode local reservation starts at `R * W * H + P + C + M` per placement,
  with additional physical replication/failure/rebuild overhead. Archive retention
  starts at observed average bytes/second times retention duration and duty cycle.
- Local-only retention starts at the retained average media rate times the
  configured history, plus open/in-flight media, indexes, holds, exports and
  failure reserves. It cannot be sized as a short upload buffer.
- For backlog `B` and effective upload goodput `U`, drain time is `B / (U - R)`
  only when `U > R`. A recovery deadline `T` needs at least `U >= R + B/T`.
- Admission also requires per-host I/O, NIC, gateway/WAN, CPU, memory and file
  descriptor headroom, including failure placement. Aggregate free bytes do not
  prove that one replacement node can carry its assignments.
- Estimate object operations separately: sealed blocks/second, init/manifests,
  verification, retries and playback ranges. Block packing should avoid one
  object per frame or tiny fragment; measure request cost versus recovery and
  seek latency before selecting bounded block sizes.

Example: 1,000 invented streams at 3 Mbit/s produce 375 MB/s. A 30-minute outage
is 675 GB of payload; 25% illustrative headroom makes 843.75 GB before the other
reserves. Thirty days is 972 TB of payload in the durable destination, not the
S3-mode hot buffer. Replication and fault tolerance are additional costs.
A 675 GB backlog drained in one hour while that capture rate continues requires
at least 562.5 MB/s effective upload goodput before further safety margin.

## Qualification ladder

Use synthetic encoded sources and independent expected manifests at 100, 1,000
and 10,000 concurrent streams. These are qualification targets, not supported
limits. Include different profiles, keyframe cadence, audio, variable-bitrate
peaks, reconnect bursts and slow sources. Prove generator capacity separately;
multiplying a one-camera result or replaying only control messages is not a
media throughput test. Report offered/admitted/recorded rates and rejected work.

Each level must run real source ingestion, segment sealing, storage and index
publication with zero viewers; exercise viewer attach/detach concurrently. Use a
24-hour steady-state soak and separate injected-outage/catch-up phases. Store
bounded private evidence and synthetic fixture generators, not captured media.
Record limits, topology, versions, hardware classes and failure domains without
publishing real deployment identifiers. Unsupported or unexecuted levels remain
unqualified.

Before claiming a level, demonstrate:

- No unreported missing/duplicate intervals against generated ground truth;
  expected failure gaps/discontinuities are explicit and bounded by the declared
  coverage contract. Per-stream timestamps and unknown-clock cases remain honest.
- Stable bounded memory, mailbox/queue, journal and disk use; measured peak
  network/disk throughput and headroom satisfy admission reservations.
- One source/profile session and one edge-to-cloud live upload across viewers,
  with Membrane fan-out even when concurrent first viewers reach different
  replicas. Count actual source connections and live uploads, not only catalog
  rows. Reconnect, slow-viewer isolation and ownership uncertainty must not
  create duplicates; prove handoff transitions and no orphan source after stop.
- Core/control and unrelated viewer SLOs hold during recorder saturation, slow
  disk, full media reserve, failed S3 uploads, restart and optional worker failure.
- Injected crash boundaries preserve sealed blocks, immutable manifests,
  idempotent receipts and cleanup authority; invalid/stale owners cannot publish.
- S3 outage/recovery meets the selected `W` and `T`; `U <= R` produces visible
  pressure and bounded stopping rather than silent overwrite or false catch-up.
- Local-only mode makes zero object-store/SaaS requests and survives service
  restart within its declared durability contract. Prove local restore and
  authorized playback; disk loss must not be mislabeled as a recoverable cache miss.
- Customer-host WAN loss, expiry, reboot and reconciliation preserve grant and
  ownership boundaries without remote per-segment admission. Reachable S3 may
  drain while central indexing is down. Reconnect does not create a second owner.
- Hosted live and historical playback work while all inbound customer access is
  denied, using agent-initiated gateway connections. Saturated media and abandoned
  playback cannot starve control or recording. WAN loss makes remote local-only
  reads unavailable while authorized local capture continues; verified reachable
  archive reads work without the edge. Test private, cloud-unreachable S3 too.
- Archive playback starts/seeks with valid init/keyframe dependencies and bounded
  range reads rather than downloading an entire recording. Exercise repeated
  seeks, slow storage and independent viewer timelines; assert per-session and
  aggregate prefetch/cache limits and cancellation. Identical fragment reads
  share cache/fetch work within the serving scope while every cache hit enforces
  current authorization. A packed object never leaks ungranted intervals.
- Holds, export leases, deletion, credential rotation and cross-mode migration
  retain the existing security/preservation assertions in every supported mode.

Choose and record numerical acceptance SLOs for start/seal latency, maximum
coverage gap, control responsiveness, viewer degradation, recovery time and cost
before running the claimed tier. A target that merely completes without asserting
those thresholds is inconclusive. Capacity claims require measured evidence on
the actual qualified profile; hardware/GPU availability alone is not evidence.
