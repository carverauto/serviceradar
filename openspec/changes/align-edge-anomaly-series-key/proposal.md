# Align edge anomalies to the central canonical device identity

## Why

Every disposition feature (robust peak profile, seasonal, stale-alert auto-resolve `#4288`)
must correlate an **edge anomaly** to the **central metric** it judges. That
correlation is the load-bearing precondition, and on demo it does not hold:

- Metrics carry the canonical **`sr:` device** (`device_id = sr:<target>`,
  resolved centrally from the poll target).
- Anomalies do **not**: in the last 3h, **100% of anomaly findings have an empty
  resolved `device.uid`**, and their raw `service_radar.device_uid` is the polling
  agent (`agent-dusk01`) or an unreconciled hostname (`ns01`, `k8s-…`).

So findings written under raw ids never join the canonical `sr:` device, and
device-detail shows "No anomaly findings" while the metric stream sits right there.

### What this proposal does NOT do (corrected from the first draft)

The first draft proposed making `anomaly.series_key == metric.series_key`. That is
the wrong target, on two independently-verified grounds:

1. **The metric `series_key` is not a stable identity.** It is an `md5` over typed
   fields **plus ingestion-metadata tags** (`payload_kind`, `producer_kind`,
   `source`, `producer_id`). Reproducing a real metric's key (`c7e0a780…`) from its
   stored fields failed across six candidate component sets — including with and
   without `device_id`. The key was hashed with **`device_id` empty** (a backfill
   populated the *column*, not the hash), and it folds in producer metadata an
   anomaly will never carry. (Confirmed independently by the #4289 review: blockers
   **B1** device_id-empty-hash, **M3** tags.)
2. **The disposition join already keys on `device_id`, not the hash.** The
   `profile_hour_of_week_peak` SQL groups by `device_id AS series`. The polluted
   `series_key` hash was never the actual join key.

## What changes

Align anomalies and metrics on the **canonical identity tuple they both can produce
deterministically** — `(device_id = sr:<target>, metric_name, if_index)` — and make
the disposition + liveness joins key on that, never on the `series_key` hash.

Central **already has the resolver**: `anomaly_detection_device_uid`
(`causal_signals.ex`) swaps in `target_device_ip` for SNMP and runs
`DeviceCorrelation.resolve` to the canonical `sr:` device (with a comment block
describing the exact agent-vs-target reasoning). The work is therefore:

1. **Deploy the addon fix** — root-caused (SSH to dusk01 + decoded v2 subject) to a
   **stale addon** (`serviceradar-anomaly-addon` v0.1.1, built Jun 18) that predates
   the SNMP-target-attribution fixes (`6cd7c4440` is on staging; `0422ae92e` "derive
   target from tags" is unmerged). It emits agent-identity verdicts with no
   `target_device_ip`, so the (correct, deployed) central resolver has nothing to
   resolve. Merge `0422ae92e` + rebuild/deploy the addon — not a code change.
2. **Make the join key on the canonical tuple**, type-agnostically (not SNMP-only —
   review **M2**), so the disposition feed and `#4288` liveness correlate on
   `(device_id, metric_name, if_index)`.
3. **Lock it with a parity test**: a resolved anomaly's canonical tuple equals its
   metric's, for a known SNMP series — turning the precondition into a proof.

## Impact

- Affected specs: `observability-signals` (canonical identity-join requirement).
- Affected code: `elixir/serviceradar_core` anomaly ingest (`causal_signals.ex`, and
  whichever processor actually persists the finding identity on the live path — the
  empty-`device.uid` symptom must be root-caused), plus the disposition/liveness
  query join keys. **No agent/addon change** — the edge already carries the target.
- No data migration; forward-looking. Open anomalies at cutover keep their raw id
  unless re-keyed (review **M4** — handle so they are not orphaned).
- Security posture unchanged: `agent_id` is the attested anchor; the agent-reported
  target/interface are scoped under it (the behavioral-identity rule).
